using System;
using UnityEngine;
using YetiKit.Interaction;

namespace YetiKit.Lab
{
    [Serializable]
    internal sealed class GripOverrideDocument
    {
        public int v;
        public GripProfile profile;

        internal static bool TryRead(string body, out GripProfile profile)
        {
            profile = null;
            if (body == null) return true;
            try
            {
                var doc = JsonUtility.FromJson<GripOverrideDocument>(body);
                if (doc == null || doc.v != 1 || !Valid(doc.profile)) return false;
                profile = doc.profile;
                return true;
            }
            catch (ArgumentException) { return false; }
        }

        internal static string Write(GripProfile profile) => profile == null ? null
            : JsonUtility.ToJson(new GripOverrideDocument { v = 1, profile = profile });

        internal static bool Valid(GripProfile profile)
        {
            if (profile == null) return false;
            var s = profile.spec;
            return Enum.IsDefined(typeof(GripKind), s.kind) && float.IsFinite(s.radius) && s.radius >= 0f &&
                Finite(s.center) && Finite(s.shift) && Finite(s.thumbAt) && Finite(s.keepClear) && Finite(s.indexAt) &&
                Finite(s.axis) && Finite(s.palm) && Finite(s.handUp) && Finite(s.handForward) &&
                (s.IsOriented ? Basis(s.handUp, s.handForward) : Basis(s.axis, s.palm));
        }

        static bool Basis(Vector3 up, Vector3 forward) => up.normalized != Vector3.zero &&
            Vector3.Cross(up.normalized, forward.normalized).sqrMagnitude > 1e-6f;

        static bool Finite(Vector3 v) => float.IsFinite(v.x) && float.IsFinite(v.y) && float.IsFinite(v.z);
    }
}
