using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Jamaica.World;

namespace Jamaica.Streaming
{
    public enum StreamLayer { Terrain, Roads }
    public enum StreamState { Requested, Loading, ReadyCPU, Active, Failed }
    public readonly struct StreamKey : IEquatable<StreamKey>
    {
        public readonly CellId Cell;
        public readonly StreamLayer Layer;
        public StreamKey(CellId cell, StreamLayer layer) { Cell = cell; Layer = layer; }
        public bool Equals(StreamKey other) { return Cell.Equals(other.Cell) && Layer == other.Layer; }
        public override bool Equals(object obj) { return obj is StreamKey && Equals((StreamKey)obj); }
        public override int GetHashCode() { return Cell.GetHashCode() * 397 ^ (int)Layer; }
        public override string ToString() { return Cell + "/" + Layer; }
    }
    public interface IArtifactSource
    {
        bool Contains(StreamKey key);
        Task<byte[]> LoadAsync(StreamKey key, CancellationToken cancellation);
    }
    public static class ArtifactIntegrity
    {
        public static string Hash(byte[] bytes)
        { using (var sha = SHA256.Create()) return "sha256:" + BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
        public static void Verify(byte[] data, long size, string hash)
        { if (data == null || data.LongLength != size || Hash(data) != hash) throw new InvalidOperationException("ARTIFACT_INTEGRITY"); }
    }
    public sealed class StreamRequest
    {
        public readonly StreamKey Key;
        public readonly double Priority, Deadline;
        public StreamRequest(StreamKey key, double priority, double deadline) { Key = key; Priority = priority; Deadline = deadline; }
    }
    public sealed class StreamingMetrics
    {
        public int Active, Loading, Queued, PeakEntries;
        public long Requested, Activated, Evicted, Cancelled, Failed, DeadlineMisses, DownloadedBytes;
    }
    public sealed class CellStreamer : IDisposable
    {
        private sealed class Entry
        {
            public StreamRequest Request; public StreamState State; public CancellationTokenSource Cancel;
            public Task<byte[]> Task; public double RetryAt, StartedAt; public int Attempts; public bool LateReported;
        }
        private readonly IArtifactSource source;
        private readonly Dictionary<StreamKey, Entry> entries = new Dictionary<StreamKey, Entry>();
        private bool disposed;
        public readonly StreamingMetrics Metrics = new StreamingMetrics();
        public int Concurrency = 4, IntegrationBudget = 2, Capacity = 128;
        public double LoadTimeoutSeconds = 10;
        public Action<StreamKey, byte[]> Activate;
        public Func<StreamKey, bool> CanActivate;
        public Action<StreamKey> Deactivate;
        public Action<StreamKey, string> Failure;
        public CellStreamer(IArtifactSource source) { this.source = source; }
        public bool IsActive(StreamKey key) { Entry e; return entries.TryGetValue(key, out e) && e.State == StreamState.Active; }
        public bool PhysicsReady(CellId cell) { return IsActive(new StreamKey(cell, StreamLayer.Terrain)) && IsActive(new StreamKey(cell, StreamLayer.Roads)); }
        public int Count { get { return entries.Count; } }

        // All callbacks and state mutations execute on the caller thread, once per Tick.
        public void SetDesired(IEnumerable<StreamRequest> requests)
        {
            if (disposed) throw new ObjectDisposedException(nameof(CellStreamer));
            var wanted = requests.Where(r => source.Contains(r.Key)).GroupBy(r => r.Key)
                .Select(g => g.OrderByDescending(r => r.Priority).First()).OrderByDescending(r => r.Priority)
                .ThenBy(r => r.Key.Cell).ThenBy(r => r.Key.Layer).Take(Capacity).ToDictionary(r => r.Key);
            foreach (var key in entries.Keys.Where(k => !wanted.ContainsKey(k)).ToArray())
            {
                Entry e = entries[key];
                if (e.State == StreamState.Active) { Deactivate?.Invoke(key); Metrics.Evicted++; }
                CancelEntry(e); entries.Remove(key);
            }
            foreach (var request in wanted.Values)
            {
                Entry e;
                if (entries.TryGetValue(request.Key, out e))
                {
                    // Preserve the original deadline: continuously replanning must not hide late loads.
                    e.Request = new StreamRequest(request.Key, request.Priority, Math.Min(e.Request.Deadline, request.Deadline));
                }
                else { entries.Add(request.Key, new Entry { Request = request, State = StreamState.Requested }); Metrics.Requested++; }
            }
            Metrics.PeakEntries = Math.Max(Metrics.PeakEntries, entries.Count);
        }
        public void Tick(double now)
        {
            if (disposed) return;
            int integrated = 0;
            foreach (Entry e in entries.Values.OrderByDescending(e => e.Request.Priority).ToArray())
            {
                if (e.State != StreamState.Active && now > e.Request.Deadline && !e.LateReported)
                { Metrics.DeadlineMisses++; e.LateReported = true; }
                if (e.State == StreamState.Loading && !e.Task.IsCompleted && now - e.StartedAt >= LoadTimeoutSeconds)
                    Fail(e, now, "STREAM_LOAD_TIMEOUT");
                if (e.State == StreamState.Loading && e.Task.IsCompleted)
                {
                    if (e.Task.IsCanceled || e.Task.IsFaulted)
                    { if (e.Task.IsFaulted) { var observed = e.Task.Exception; } Fail(e, now, "STREAM_LOAD_FAILED"); }
                    else { e.State = StreamState.ReadyCPU; Metrics.DownloadedBytes += e.Task.Result.Length; }
                }
                if (e.State == StreamState.ReadyCPU && integrated < IntegrationBudget && (CanActivate == null || CanActivate(e.Request.Key)))
                {
                    try
                    {
                        Activate?.Invoke(e.Request.Key, e.Task.Result);
                        e.State = StreamState.Active; Metrics.Activated++; integrated++;
                        e.Task = null; e.Cancel.Dispose(); e.Cancel = null;
                    }
                    catch { Fail(e, now, "STREAM_INTEGRATION_FAILED"); }
                }
                if (e.State == StreamState.Failed && now >= e.RetryAt && e.Attempts < 3) e.State = StreamState.Requested;
            }
            int inFlight = entries.Values.Count(e => e.State == StreamState.Loading || e.State == StreamState.ReadyCPU);
            foreach (Entry e in entries.Values.Where(e => e.State == StreamState.Requested).OrderByDescending(e => e.Request.Priority).ThenBy(e => e.Request.Key.Cell))
            {
                if (inFlight >= Concurrency) break;
                e.Cancel = new CancellationTokenSource(); e.Cancel.CancelAfter(TimeSpan.FromSeconds(LoadTimeoutSeconds));
                e.Attempts++; e.State = StreamState.Loading; e.StartedAt = now;
                try { e.Task = source.LoadAsync(e.Request.Key, e.Cancel.Token); if (e.Task == null) throw new InvalidOperationException(); inFlight++; }
                catch { Fail(e, now, "STREAM_SOURCE_FAILED"); }
            }
            Metrics.Active = entries.Values.Count(e => e.State == StreamState.Active);
            Metrics.Loading = entries.Values.Count(e => e.State == StreamState.Loading || e.State == StreamState.ReadyCPU);
            Metrics.Queued = entries.Values.Count(e => e.State == StreamState.Requested);
        }
        private void Fail(Entry e, double now, string code)
        {
            CancelEntry(e); e.State = StreamState.Failed; e.RetryAt = now + Math.Pow(2, e.Attempts);
            Metrics.Failed++; Failure?.Invoke(e.Request.Key, code);
        }
        private void CancelEntry(Entry e)
        {
            if (e.Cancel != null) { e.Cancel.Cancel(); e.Cancel.Dispose(); e.Cancel = null; Metrics.Cancelled++; }
            // A late completion belongs to the retired Entry. It can never activate a new request.
            if (e.Task != null) e.Task.ContinueWith(t => { var observed = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
            e.Task = null;
        }
        public void Dispose()
        {
            if (disposed) return;
            foreach (Entry e in entries.Values) { if (e.State == StreamState.Active) Deactivate?.Invoke(e.Request.Key); CancelEntry(e); }
            entries.Clear(); disposed = true;
        }
    }
    public sealed class PredictivePlanner
    {
        private readonly WorldGrid grid;
        public int NeighborRadius = 1;
        public double WorstLoadSeconds = 2, Deceleration = 3.5, MarginMetres = 200;
        public PredictivePlanner(WorldGrid grid) { this.grid = grid; }
        public double Lookahead(double speed)
        {
            if (speed < 0 || !GlobalPosition.Finite(speed) || Deceleration <= 0) throw new ArgumentException("STREAM_SPEED_BUDGET");
            return speed * WorstLoadSeconds + speed * speed / (2 * Deceleration) + MarginMetres;
        }
        public IEnumerable<StreamRequest> Plan(GlobalPosition position, double velocityEast, double velocityNorth, double now)
        {
            double speed = Math.Sqrt(velocityEast * velocityEast + velocityNorth * velocityNorth);
            double distance = Lookahead(speed); var cells = new Dictionary<CellId, double>();
            CellId center = grid.At(position);
            for (long x = center.X - NeighborRadius; x <= center.X + NeighborRadius; x++)
                for (long n = center.N - NeighborRadius; n <= center.N + NeighborRadius; n++)
                    cells[new CellId(CellLevel.W1, x, n)] = Math.Sqrt((x - center.X) * (x - center.X) + (n - center.N) * (n - center.N)) * 1000;
            if (speed > 0.01)
            {
                int steps = (int)Math.Ceiling(distance / 250);
                for (int i = 0; i <= steps; i++)
                {
                    double d = Math.Min(distance, i * 250);
                    var cell = grid.At(new GlobalPosition(position.East + velocityEast / speed * d, position.North + velocityNorth / speed * d));
                    if (!cells.ContainsKey(cell) || d < cells[cell]) cells[cell] = d;
                }
            }
            foreach (var pair in cells.OrderBy(x => x.Value).ThenBy(x => x.Key))
                foreach (StreamLayer layer in new[] { StreamLayer.Terrain, StreamLayer.Roads })
                    yield return new StreamRequest(new StreamKey(pair.Key, layer), 100000 - pair.Value - (layer == StreamLayer.Terrain ? 0 : 0.1), now + (pair.Value == 0 ? WorstLoadSeconds : Math.Max(WorstLoadSeconds, pair.Value / Math.Max(speed, 1) - WorstLoadSeconds)));
        }
    }
}
