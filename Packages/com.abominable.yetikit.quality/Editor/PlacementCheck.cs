using System;
using UnityEngine;

namespace YetiKit.Quality.Editor
{
    /// <summary>Root-local placement contract; zero forward/tolerance select +Z and 0.02 root units (metres).</summary>
    public struct PlacementSpec
    {
        public Vector3 forward;
        public float tolerance;
        public bool trunkRim;
    }

    public struct PlacementResult
    {
        /// <summary>Minimum y in (+X,+Z), (-X,+Z), (+X,-Z), (-X,-Z); axes belong to both sides.</summary>
        public float[] lowestPerQuadrant;
        /// <summary>Largest absolute quadrant minimum, or absolute highest sector minimum in rim mode.</summary>
        public float maxGap;
        public float forwardErrorDegrees;
        public bool Pass;
        public string Reason;
    }

    /// <summary>Read-only validation of mesh vertices relative to the root pivot's y=0 plane.</summary>
    public static class PlacementCheck
    {
        /// <summary>
        /// Includes inactive child MeshFilters and SkinnedMeshRenderers (shared mesh, undeformed bind geometry).
        /// Root placement/scale is ignored; child transforms are applied. Each mesh transform's local +Z must
        /// match declared root-local forward within one degree. This is an authoring-axis contract, NOT semantic
        /// front detection: baked backwards geometry with unchanged axes cannot be detected.
        /// Rim mode uses ALL vertices, no inferred trunk radius: minimum y in each of 12 half-open XZ sectors
        /// starting at +Z, then their highest minimum must be within tolerance of zero. Other sectors may dip
        /// arbitrarily below zero (roots). Supply a base-only model if foliage/overhangs would pollute sectors;
        /// this metric does not identify a physical trunk rim. Empty sectors fail; vertices on the Y axis do not
        /// fill sectors. Invalid input fails with a reason; maxGap is infinity until grounding can be evaluated.
        /// </summary>
        public static PlacementResult Check(GameObject prefabOrModel, PlacementSpec spec)
        {
            var result = new PlacementResult
            {
                lowestPerQuadrant = new[] { float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity },
                maxGap = float.PositiveInfinity,
                Reason = "Missing model."
            };
            if (!prefabOrModel) return result;
            if (!Finite(spec.tolerance) || spec.tolerance < 0 || !Finite(spec.forward))
            { result.Reason = "Invalid spec: forward must be finite and tolerance non-negative and finite."; return result; }
            var forward = spec.forward;
            if (forward.Equals(Vector3.zero)) forward = Vector3.forward;
            // Scale before normalization so very large/small finite declarations remain valid directions.
            forward /= Mathf.Max(Mathf.Abs(forward.x), Mathf.Abs(forward.y), Mathf.Abs(forward.z));
            forward.Normalize();
            var tolerance = spec.tolerance == 0 ? 0.02f : spec.tolerance;
            var root = prefabOrModel.transform;
            if (!Finite(root.localToWorldMatrix.determinant) || root.localToWorldMatrix.determinant == 0)
            { result.Reason = "Invalid root transform: non-finite or singular."; return result; }
            var lows = new float[12];
            for (var i = 0; i < lows.Length; i++) lows[i] = float.PositiveInfinity;
            var count = 0;
            bool Accumulate(Mesh mesh, Transform transform)
            {
                if (!mesh) { result.Reason = "Missing shared mesh."; return false; }
                var toRoot = root.worldToLocalMatrix * transform.localToWorldMatrix;
                var axis = toRoot.MultiplyVector(Vector3.forward);
                if (!Finite(axis) || axis.sqrMagnitude < 1e-12f)
                { result.Reason = "Invalid mesh forward transform."; return false; }
                result.forwardErrorDegrees = Mathf.Max(result.forwardErrorDegrees, Vector3.Angle(axis, forward));
                Vector3[] vertices;
                try { vertices = mesh.vertices; }
                catch (UnityException) { result.Reason = "Mesh vertices are not accessible."; return false; }
                if (vertices.Length == 0) { result.Reason = "Mesh has no vertices."; return false; }
                foreach (var vertex in vertices)
                {
                    var v = toRoot.MultiplyPoint3x4(vertex);
                    if (!Finite(v)) { result.Reason = "Mesh has non-finite transformed vertices."; return false; }
                    for (var q = 0; q < 4; q++)
                        if (v.x * ((q & 1) == 0 ? 1 : -1) >= 0 && v.z * ((q & 2) == 0 ? 1 : -1) >= 0)
                            result.lowestPerQuadrant[q] = Mathf.Min(result.lowestPerQuadrant[q], v.y);
                    if (v.x != 0 || v.z != 0)
                    {
                        var sector = (int)(Mathf.Repeat(Mathf.Atan2(v.x, v.z) * Mathf.Rad2Deg, 360) / 30) % 12;
                        lows[sector] = Mathf.Min(lows[sector], v.y);
                    }
                    count++;
                }
                return true;
            }
            foreach (var filter in prefabOrModel.GetComponentsInChildren<MeshFilter>(true))
                if (!Accumulate(filter.sharedMesh, filter.transform)) return result;
            foreach (var skin in prefabOrModel.GetComponentsInChildren<SkinnedMeshRenderer>(true))
                if (!Accumulate(skin.sharedMesh, skin.transform)) return result;
            if (count == 0) { result.Reason = "No mesh vertices found."; return result; }
            var minima = spec.trunkRim ? lows : result.lowestPerQuadrant;
            var highest = float.NegativeInfinity;
            var gap = 0f;
            foreach (var low in minima)
            {
                if (float.IsPositiveInfinity(low))
                { result.Reason = spec.trunkRim ? "Missing rim sector vertices." : "Missing quadrant vertices."; return result; }
                highest = Mathf.Max(highest, low);
                gap = Mathf.Max(gap, Mathf.Abs(low));
            }
            result.maxGap = spec.trunkRim ? Mathf.Abs(highest) : gap;
            result.Pass = result.maxGap <= tolerance && result.forwardErrorDegrees <= 1f;
            result.Reason = result.maxGap > tolerance ? "Grounding gap exceeds tolerance."
                : result.forwardErrorDegrees > 1f ? "Mesh +Z differs from declared forward by more than one degree." : "";
            return result;
        }

        static bool Finite(float v) => !float.IsNaN(v) && !float.IsInfinity(v);
        static bool Finite(Vector3 v) => Finite(v.x) && Finite(v.y) && Finite(v.z);
    }
}
