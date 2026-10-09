using System;
using System.Collections.Generic;
using Jamaica.World;

namespace Jamaica.Simulation
{
    public enum FidelityTier { Aggregate, PersistentBackground, StrategicActive, LocalAgent, PhysicsInteraction, Hero }
    public sealed class EntityState
    {
        public readonly EntityId Id;
        public GlobalPosition Position;
        public long Version;
        public double OdometerMetres;
        public FidelityTier Tier;
        public EntityState(EntityId id, GlobalPosition position) { Id = id; Position = position; Tier = FidelityTier.PersistentBackground; }
    }
    public sealed class EntityStore
    {
        private readonly Dictionary<EntityId, EntityState> entities = new Dictionary<EntityId, EntityState>();
        public int Count { get { return entities.Count; } }
        public void Add(EntityState entity) { entities.Add(entity.Id, entity); }
        public EntityState Get(EntityId id) { return entities[id]; }
        public void Move(EntityId id, GlobalPosition position, long expectedVersion)
        {
            EntityState entity = entities[id];
            if (entity.Version != expectedVersion) throw new InvalidOperationException("DB_VERSION_CONFLICT");
            entity.OdometerMetres += entity.Position.DistanceXZ(position); entity.Position = position; entity.Version++;
        }
        public void SetTier(EntityId id, FidelityTier tier) { entities[id].Tier = tier; }
    }
    public sealed class EventScheduler
    {
        private sealed class Item { public long Tick, Sequence; public string Id; public Action Execute; }
        private sealed class Order : IComparer<Item>
        { public int Compare(Item a, Item b) { int c = a.Tick.CompareTo(b.Tick); return c == 0 ? a.Sequence.CompareTo(b.Sequence) : c; } }
        private readonly SortedSet<Item> queue = new SortedSet<Item>(new Order());
        private readonly Dictionary<string, Item> byId = new Dictionary<string, Item>();
        private long sequence;
        public long Now { get; private set; }
        public long Failed { get; private set; }
        public int Count { get { return queue.Count; } }
        public Action<string> DeadLetter;
        public void Schedule(string id, long tick, Action execute)
        {
            if (string.IsNullOrWhiteSpace(id) || execute == null || tick < Now) throw new ArgumentException("SIM_INVALID_EVENT");
            if (byId.ContainsKey(id)) throw new InvalidOperationException("SIM_DUPLICATE_EVENT");
            var item = new Item { Id = id, Tick = tick, Execute = execute, Sequence = sequence++ }; queue.Add(item); byId.Add(id, item);
        }
        public bool Cancel(string id) { Item item; if (!byId.TryGetValue(id, out item)) return false; byId.Remove(id); queue.Remove(item); return true; }
        public int Advance(long target, int budget = 1024)
        {
            if (target < Now || budget <= 0) throw new ArgumentException("SIM_CLOCK_OR_BUDGET");
            int count = 0;
            while (queue.Count > 0 && queue.Min.Tick <= target && count < budget)
            {
                Item item = queue.Min; queue.Remove(item); byId.Remove(item.Id); Now = item.Tick;
                try { item.Execute(); } catch { Failed++; DeadLetter?.Invoke(item.Id); }
                count++;
            }
            // Never move the clock past pending due events when a frame budget is exhausted.
            if (queue.Count == 0 || queue.Min.Tick > target) Now = target;
            return count;
        }
    }
}
