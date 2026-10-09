using System;
using System.Globalization;

namespace Jamaica.World
{
    public readonly struct GlobalPosition
    {
        public readonly double East, North, Height;
        public GlobalPosition(double east, double north, double height = 0)
        {
            if (!Finite(east) || !Finite(north) || !Finite(height))
                throw new ArgumentException("GEO_NONFINITE_POSITION");
            East = east; North = north; Height = height;
        }
        public static bool Finite(double x) { return !double.IsNaN(x) && !double.IsInfinity(x); }
        public double DistanceXZ(GlobalPosition other)
        { double e = East - other.East, n = North - other.North; return Math.Sqrt(e * e + n * n); }
    }

    public readonly struct EntityId : IEquatable<EntityId>
    {
        public readonly Guid Value;
        public EntityId(Guid value) { if (value == Guid.Empty) throw new ArgumentException("DB_EMPTY_ENTITY_ID"); Value = value; }
        public static EntityId Parse(string text) { return new EntityId(Guid.ParseExact(text, "D")); }
        public override string ToString() { return Value.ToString("D"); }
        public bool Equals(EntityId other) { return Value.Equals(other.Value); }
        public override bool Equals(object obj) { return obj is EntityId && Equals((EntityId)obj); }
        public override int GetHashCode() { return Value.GetHashCode(); }
    }

    public enum CellLevel { M8 = 8000, W1 = 1000, D250 = 250, D125 = 125 }
    public readonly struct CellId : IEquatable<CellId>, IComparable<CellId>
    {
        public readonly CellLevel Level;
        public readonly long X, N;
        public CellId(CellLevel level, long x, long north)
        {
            if (!Enum.IsDefined(typeof(CellLevel), level)) throw new ArgumentException("GEO_CELL_LEVEL");
            Level = level; X = x; N = north;
        }
        public CellId Parent(CellLevel parent)
        {
            int ratio = (int)parent / (int)Level;
            if (ratio < 1 || (int)parent % (int)Level != 0) throw new ArgumentException("GEO_PARENT_LEVEL");
            return new CellId(parent, FloorDiv(X, ratio), FloorDiv(N, ratio));
        }
        public static long FloorDiv(long n, long d)
        {
            if (d <= 0) throw new ArgumentOutOfRangeException(nameof(d));
            long q = n / d, r = n % d; return r < 0 ? q - 1 : q;
        }
        public static CellId Parse(string text)
        {
            string[] p = (text ?? "").Split(':'); CellLevel level; long x, n;
            if (p.Length != 4 || p[0] != "JM" || !Enum.TryParse(p[1], out level)
                || !Enum.IsDefined(typeof(CellLevel), level)
                || !long.TryParse(p[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out x)
                || !long.TryParse(p[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out n))
                throw new FormatException("GEO_CELL_ID");
            var result = new CellId(level, x, n);
            if (result.ToString() != text) throw new FormatException("GEO_NONCANONICAL_CELL_ID");
            return result;
        }
        public override string ToString() { return string.Format(CultureInfo.InvariantCulture, "JM:{0}:{1}:{2}", Level, X, N); }
        public bool Equals(CellId other) { return Level == other.Level && X == other.X && N == other.N; }
        public override bool Equals(object obj) { return obj is CellId && Equals((CellId)obj); }
        public override int GetHashCode() { unchecked { return (((int)Level * 397) ^ X.GetHashCode()) * 397 ^ N.GetHashCode(); } }
        public int CompareTo(CellId other) { int c = Level.CompareTo(other.Level); if (c == 0) c = X.CompareTo(other.X); return c == 0 ? N.CompareTo(other.N) : c; }
    }

    public sealed class WorldGrid
    {
        public readonly double AnchorEast, AnchorNorth;
        public WorldGrid(double east, double north)
        {
            if (!GlobalPosition.Finite(east) || !GlobalPosition.Finite(north)) throw new ArgumentException("GEO_GRID_ANCHOR");
            AnchorEast = east; AnchorNorth = north;
        }
        public CellId At(GlobalPosition p, CellLevel level = CellLevel.W1)
        {
            double x = Math.Floor((p.East - AnchorEast) / (int)level), n = Math.Floor((p.North - AnchorNorth) / (int)level);
            // Bound indices so every integer remains exactly representable as float64.
            if (Math.Abs(x) > 4503599627370495d || Math.Abs(n) > 4503599627370495d) throw new OverflowException("GEO_INDEX_RANGE");
            return new CellId(level, (long)x, (long)n);
        }
        public GlobalPosition Minimum(CellId cell) { return new GlobalPosition(AnchorEast + cell.X * (double)(int)cell.Level, AnchorNorth + cell.N * (double)(int)cell.Level); }
    }

    public sealed class OriginFrame
    {
        public GlobalPosition Origin { get; private set; }
        public int Revision { get; private set; }
        public OriginFrame(GlobalPosition origin) { Origin = origin; }
        public GlobalPosition Local(GlobalPosition global) { return new GlobalPosition(global.East - Origin.East, global.North - Origin.North, global.Height - Origin.Height); }
        public GlobalPosition Global(GlobalPosition local) { return new GlobalPosition(local.East + Origin.East, local.North + Origin.North, local.Height + Origin.Height); }
        // Returned delta is added to ALL registered local roots exactly once.
        public GlobalPosition Rebase(GlobalPosition next)
        { var delta = new GlobalPosition(Origin.East - next.East, Origin.North - next.North, Origin.Height - next.Height); Origin = next; Revision++; return delta; }
    }

    public interface ICoordinateTransform
    {
        string SourceCrs { get; }
        string TargetCrs { get; }
        GlobalPosition Transform(GlobalPosition point);
    }
}
