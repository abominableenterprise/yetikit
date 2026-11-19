using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Geometry queries against registered collider-free world UI.</summary>
    public static class HandUiGuard
    {
        public static readonly List<RectTransform> Rects = new List<RectTransform>();

        public static bool Near(Vector3 point, float radius)
        {
            foreach (var rect in Rects)
                if (rect && rect.gameObject.activeInHierarchy && Distance(rect, point) <= radius) return true;
            return false;
        }

        public static float Distance(RectTransform rect, Vector3 point)
        {
            var local = rect.InverseTransformPoint(point);
            var bounds = rect.rect;
            var closest = new Vector3(Mathf.Clamp(local.x, bounds.xMin, bounds.xMax),
                Mathf.Clamp(local.y, bounds.yMin, bounds.yMax), 0f);
            return Vector3.Distance(rect.TransformPoint(closest), point);
        }

        /// <summary>First two-sided UI surface on a finite segment, without adding physics blockers.</summary>
        public static bool Intersect(Vector3 from, Vector3 to, out Vector3 hit)
        {
            hit = default;
            var nearest = float.PositiveInfinity;
            foreach (var rect in Rects)
            {
                if (!rect || !rect.gameObject.activeInHierarchy) continue;
                var a = rect.InverseTransformPoint(from);
                var b = rect.InverseTransformPoint(to);
                if (!IntersectRect(a, b, rect.rect, out var t) || t >= nearest) continue;
                nearest = t;
                hit = Vector3.Lerp(from, to, t);
            }
            return !float.IsPositiveInfinity(nearest);
        }

        static bool IntersectRect(Vector3 a, Vector3 b, Rect bounds, out float t)
        {
            const float planeEpsilon = 1e-6f;
            var delta = b - a;
            if (Mathf.Abs(a.z) <= planeEpsilon && Mathf.Abs(b.z) <= planeEpsilon)
            {
                // Clip the segment's [0, 1] parameter interval to the two in-plane slabs.
                t = 0f;
                var exit = 1f;
                return Clip(a.x, delta.x, bounds.xMin, bounds.xMax, ref t, ref exit)
                    && Clip(a.y, delta.y, bounds.yMin, bounds.yMax, ref t, ref exit);
            }

            t = 0f;
            if (delta.z == 0f) return false;
            t = -a.z / delta.z;
            if (t < 0f || t > 1f) return false;
            var point = a + delta * t;
            return bounds.Contains(new Vector2(point.x, point.y));
        }

        static bool Clip(float start, float delta, float min, float max, ref float enter, ref float exit)
        {
            if (delta == 0f) return start >= min && start <= max;
            var a = (min - start) / delta;
            var b = (max - start) / delta;
            enter = Mathf.Max(enter, Mathf.Min(a, b));
            exit = Mathf.Min(exit, Mathf.Max(a, b));
            return enter <= exit;
        }
    }
}
