using System;
using UnityEngine;

namespace YetiKit.Lab
{
    /// <summary>Pack props in rows along world +X and +Z, keeping their authored rotation.</summary>
    static class GripLabLayout
    {
        const float Gap = 0.12f, SurfaceClearance = 0.002f;

        public static void Arrange(GripLabSlot[] slots, Vector3 origin, float width)
        {
            var left = -width / 2 + Gap;
            var x = left;
            var z = Gap;
            var rowDepth = 0f;
            Physics.SyncTransforms();
            foreach (var slot in slots)
            {
                var bounds = BoundsOf(slot);
                if (x > left && x + bounds.size.x > width / 2 - Gap)
                {
                    x = left;
                    z += rowDepth + Gap;
                    rowDepth = 0;
                }
                var corner = origin + new Vector3(x, SurfaceClearance, z);
                slot.SetHome(new Pose(slot.transform.position + corner - bounds.min, slot.transform.rotation));
                x += bounds.size.x + Gap;
                rowDepth = Mathf.Max(rowDepth, bounds.size.z);
            }
        }

        static Bounds BoundsOf(GripLabSlot slot)
        {
            var bounds = new Bounds();
            var found = false;
            foreach (var collider in slot.Solids)
            {
                if (!collider || !collider.enabled || !collider.gameObject.activeInHierarchy) continue;
                if (found) bounds.Encapsulate(collider.bounds);
                else bounds = collider.bounds;
                found = true;
            }
            if (!found) throw new InvalidOperationException("Lab props need at least one enabled solid collider on their body.");
            return bounds;
        }
    }
}
