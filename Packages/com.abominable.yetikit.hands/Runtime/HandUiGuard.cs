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
                var dz = b.z - a.z;
                if (Mathf.Abs(dz) < 1e-7f) continue;
                var t = -a.z / dz;
                if (t < 0f || t > 1f || t >= nearest) continue;
                var point = Vector3.Lerp(a, b, t);
                if (!rect.rect.Contains(new Vector2(point.x, point.y))) continue;
                nearest = t;
                hit = Vector3.Lerp(from, to, t);
            }
            return !float.IsPositiveInfinity(nearest);
        }
    }
}
