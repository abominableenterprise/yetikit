using System;
using System.Text;
using UnityEngine;

namespace YetiKit.Playtest
{
    /// <summary>
    /// The flight recorder's JSON Lines writer (pure, allocation-free): one object per line, numbers rounded and
    /// written without trailing zeros (positions 1 mm, quaternions 4 decimals, speeds 2, times 3), NaN/∞ as null.
    /// Keys are compile-time constants (never escaped); string values are escaped.
    /// </summary>
    public static class JsonLine
    {
        public const int TimeDecimals = 3, PosDecimals = 3, RotDecimals = 4, SpeedDecimals = 2;
        static readonly long[] Pow10 = { 1, 10, 100, 1000, 10000, 100000, 1000000 };

        /// <summary><c>{"t":&lt;t&gt;,"k":"&lt;kind&gt;"</c>: every line starts like this.</summary>
        public static StringBuilder Begin(StringBuilder sb, double t, string kind)
        {
            sb.Append("{\"t\":");
            Num(sb, t, TimeDecimals);
            sb.Append(",\"k\":");
            Str(sb, kind);
            return sb;
        }

        /// <summary>Close the object and the line.</summary>
        public static void End(StringBuilder sb) => sb.Append("}\n");

        /// <summary><c>,"key":</c> (a constant key: no escaping).</summary>
        public static StringBuilder Key(StringBuilder sb, string key) => sb.Append(",\"").Append(key).Append("\":");

        public static void Field(StringBuilder sb, string key, double v, int decimals) => Num(Key(sb, key), v, decimals);
        public static void Field(StringBuilder sb, string key, long v) => Int(Key(sb, key), v);
        public static void Field(StringBuilder sb, string key, string v) => Str(Key(sb, key), v);
        public static void Field(StringBuilder sb, string key, bool v) => Key(sb, key).Append(v ? "true" : "false");

        /// <summary>A number rounded to <paramref name="decimals"/> (0..6), shortest form: 1.5, 2, -0.001, 0.</summary>
        public static StringBuilder Num(StringBuilder sb, double v, int decimals)
        {
            if (double.IsNaN(v) || double.IsInfinity(v)) return sb.Append("null");
            var scaled = Math.Round(v * Pow10[decimals], MidpointRounding.AwayFromZero);
            if (Math.Abs(scaled) > 9e15) return sb.Append(v.ToString("R", System.Globalization.CultureInfo.InvariantCulture));
            var n = (long)scaled;
            if (n == 0) return sb.Append('0');
            if (n < 0) { sb.Append('-'); n = -n; }
            var p = Pow10[decimals];
            Digits(sb, n / p, 1);
            var frac = n % p;
            if (frac == 0) return sb;
            var width = decimals;
            while (frac % 10 == 0) { frac /= 10; width--; }
            sb.Append('.');
            return Digits(sb, frac, width);
        }

        /// <summary>An integer.</summary>
        public static StringBuilder Int(StringBuilder sb, long v)
        {
            if (v < 0) { sb.Append('-'); v = -v; }
            return Digits(sb, v, 1);
        }

        // v ≥ 0 in decimal, left-padded with zeros to at least minWidth digits.
        static StringBuilder Digits(StringBuilder sb, long v, int minWidth)
        {
            Span<char> buf = stackalloc char[20];
            var i = buf.Length;
            do { buf[--i] = (char)('0' + v % 10); v /= 10; } while (v > 0);
            while (buf.Length - i < minWidth) buf[--i] = '0';
            for (; i < buf.Length; i++) sb.Append(buf[i]);
            return sb;
        }

        /// <summary>A JSON string (null as <c>null</c>), escaped.</summary>
        public static StringBuilder Str(StringBuilder sb, string s)
        {
            if (s == null) return sb.Append("null");
            sb.Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < ' ')
                        {
                            sb.Append("\\u00").Append(Hex(c >> 4)).Append(Hex(c & 15));
                        }
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"');
        }

        static char Hex(int n) => (char)(n < 10 ? '0' + n : 'a' + n - 10);

        /// <summary>px,py,pz (no brackets), 1 mm.</summary>
        public static StringBuilder Pos(StringBuilder sb, Vector3 p)
        {
            Num(sb, p.x, PosDecimals).Append(',');
            Num(sb, p.y, PosDecimals).Append(',');
            return Num(sb, p.z, PosDecimals);
        }

        /// <summary>qx,qy,qz,qw (no brackets), 4 decimals.</summary>
        public static StringBuilder Rot(StringBuilder sb, Quaternion q)
        {
            Num(sb, q.x, RotDecimals).Append(',');
            Num(sb, q.y, RotDecimals).Append(',');
            Num(sb, q.z, RotDecimals).Append(',');
            return Num(sb, q.w, RotDecimals);
        }

        /// <summary>vx,vy,vz (no brackets), speeds 2 decimals.</summary>
        public static StringBuilder Vel(StringBuilder sb, Vector3 v)
        {
            Num(sb, v.x, SpeedDecimals).Append(',');
            Num(sb, v.y, SpeedDecimals).Append(',');
            return Num(sb, v.z, SpeedDecimals);
        }

        /// <summary>[px,py,pz,qx,qy,qz,qw].</summary>
        public static StringBuilder Pose7(StringBuilder sb, Vector3 p, Quaternion q)
        {
            sb.Append('[');
            Pos(sb, p).Append(',');
            return Rot(sb, q).Append(']');
        }

        /// <summary>[x,y,z] at 1 mm (or speed decimals for a velocity: use <see cref="Vel"/>).</summary>
        public static StringBuilder Vec3(StringBuilder sb, Vector3 v, int decimals)
        {
            sb.Append('[');
            Num(sb, v.x, decimals).Append(',');
            Num(sb, v.y, decimals).Append(',');
            return Num(sb, v.z, decimals).Append(']');
        }
    }
}
