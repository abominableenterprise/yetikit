using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using YetiKit.Quality.Editor;

namespace YetiKit.Quality.Tests
{
    public class PlacementCheckTests
    {
        GameObject root;
        readonly List<Mesh> meshes = new List<Mesh>();
        [SetUp] public void SetUp() => root = new GameObject("Placement fixture");
        [TearDown] public void TearDown()
        {
            Object.DestroyImmediate(root);
            foreach (var mesh in meshes) Object.DestroyImmediate(mesh);
            meshes.Clear();
        }
        GameObject Cube(Vector3 position, Vector3 scale)
        {
            var child = GameObject.CreatePrimitive(PrimitiveType.Cube);
            child.transform.SetParent(root.transform, false);
            child.transform.localPosition = position;
            child.transform.localScale = scale;
            return child;
        }
        MeshFilter Vertices(Vector3[] vertices)
        {
            var mesh = new Mesh { vertices = vertices };
            meshes.Add(mesh);
            var filter = root.AddComponent<MeshFilter>();
            filter.sharedMesh = mesh;
            return filter;
        }
        [TestCase(0f, true)]
        [TestCase(0.05f, false)]
        [TestCase(-0.05f, false)]
        public void CubeUsesDefaultToleranceAndPivotPlane(float offset, bool pass)
        {
            Cube(new Vector3(0, 0.5f + offset, 0), Vector3.one);
            var result = PlacementCheck.Check(root, default);
            Assert.AreEqual(pass, result.Pass, result.Reason);
            Assert.That(result.maxGap, Is.EqualTo(Mathf.Abs(offset)).Within(0.00001f));
            Assert.That(result.lowestPerQuadrant, Has.All.EqualTo(offset).Within(0.00001f));
        }
        [Test]
        public void BenchDetectsOneShortLeg()
        {
            Cube(new Vector3(0, 1.1f, 0), new Vector3(2, 0.2f, 2));
            for (var q = 0; q < 4; q++)
                Cube(new Vector3((q & 1) == 0 ? 0.7f : -0.7f, 0.5f + (q == 0 ? 0.03f : 0),
                    (q & 2) == 0 ? 0.7f : -0.7f), new Vector3(0.1f, 1, 0.1f));
            var result = PlacementCheck.Check(root, default);
            Assert.IsFalse(result.Pass);
            Assert.That(result.maxGap, Is.EqualTo(0.03f).Within(0.00001f));
        }
        [Test]
        public void FacingChecksMeshAxesNotSemanticGeometry()
        {
            Cube(Vector3.up * 0.5f, Vector3.one).transform.localRotation = Quaternion.Euler(0, 180, 0);
            var result = PlacementCheck.Check(root, new PlacementSpec { forward = Vector3.forward });
            Assert.IsFalse(result.Pass);
            Assert.That(result.forwardErrorDegrees, Is.EqualTo(180).Within(0.01f));
            Assert.IsTrue(PlacementCheck.Check(root, new PlacementSpec { forward = Vector3.back }).Pass);
        }
        [Test]
        public void InactiveNestedMeshesUseRootLocalTransforms()
        {
            var child = Cube(Vector3.up * 0.5f, Vector3.one);
            var group = new GameObject("Group");
            group.transform.SetParent(root.transform, false);
            group.transform.localPosition = Vector3.up;
            child.transform.SetParent(group.transform, true);
            group.SetActive(false);
            root.transform.SetPositionAndRotation(new Vector3(10, 20, 30), Quaternion.Euler(15, 70, 5));
            root.transform.localScale = Vector3.one * 2;
            Assert.IsTrue(PlacementCheck.Check(root, default).Pass);
        }
        [TestCase(0f)]
        [TestCase(0.05f)]
        [TestCase(-0.05f)]
        public void LargeWorldCoordinatesDoNotChangeRootLocalGrounding(float gap)
        {
            var child = Cube(Vector3.up * (0.5f + gap), Vector3.one);
            var group = new GameObject("Nested inactive group");
            group.transform.SetParent(root.transform, false);
            group.transform.localPosition = Vector3.up * 0.25f;
            group.transform.localRotation = Quaternion.Euler(0, 30, 0);
            child.transform.SetParent(group.transform, false);
            child.transform.localPosition -= Vector3.up * 0.25f;
            child.transform.localRotation = Quaternion.Euler(0, -30, 0);
            group.SetActive(false);
            var origin = PlacementCheck.Check(root, default);
            Assert.That(origin.Pass, Is.EqualTo(gap == 0), origin.Reason);
            root.transform.position = new Vector3(100000, 1048576, 100000);
            var distant = PlacementCheck.Check(root, default);
            Assert.That(distant.Pass, Is.EqualTo(origin.Pass));
            Assert.That(distant.maxGap, Is.EqualTo(origin.maxGap).Within(0.000001f));
            Assert.That(distant.lowestPerQuadrant, Is.EqualTo(origin.lowestPerQuadrant).Within(0.000001f));
            Assert.That(distant.forwardErrorDegrees, Is.EqualTo(origin.forwardErrorDegrees).Within(0.000001f));
        }

        [TestCase(0f, true)]
        [TestCase(0.05f, false)]
        [TestCase(-0.05f, false)]
        public void RimUsesHighestSectorMinimumAndPermitsLowerRoots(float rim, bool pass)
        {
            var vertices = new Vector3[12];
            for (var s = 0; s < 12; s++)
            {
                var angle = (s * 30 + 15) * Mathf.Deg2Rad;
                vertices[s] = new Vector3(Mathf.Sin(angle), s == 0 ? rim : -0.3f, Mathf.Cos(angle));
            }
            Vertices(vertices);
            var result = PlacementCheck.Check(root, new PlacementSpec { trunkRim = true });
            Assert.AreEqual(pass, result.Pass, result.Reason);
            Assert.That(result.maxGap, Is.EqualTo(Mathf.Abs(rim)).Within(0.00001f));
            Assert.IsFalse(PlacementCheck.Check(root, default).Pass, "ordinary grounding disallows buried roots");
        }
        [Test]
        public void MissingGeometryAndCoverageFailClearly()
        {
            StringAssert.Contains("Missing", PlacementCheck.Check(null, default).Reason);
            StringAssert.Contains("No mesh", PlacementCheck.Check(root, default).Reason);
            var filter = root.AddComponent<MeshFilter>();
            StringAssert.Contains("Missing shared mesh", PlacementCheck.Check(root, default).Reason);
            Object.DestroyImmediate(filter);
            Vertices(new[] { Vector3.one });
            StringAssert.Contains("quadrant", PlacementCheck.Check(root, default).Reason);
            StringAssert.Contains("sector", PlacementCheck.Check(root, new PlacementSpec { trunkRim = true }).Reason);
        }
        [Test]
        public void InvalidSpecsFailAndPositiveToleranceCanBeOverridden()
        {
            Cube(Vector3.up * 0.55f, Vector3.one);
            foreach (var tolerance in new[] { -1f, float.NaN, float.PositiveInfinity })
                StringAssert.Contains("Invalid spec", PlacementCheck.Check(root, new PlacementSpec { tolerance = tolerance }).Reason);
            StringAssert.Contains("Invalid spec", PlacementCheck.Check(root,
                new PlacementSpec { forward = new Vector3(float.NaN, 0, 1) }).Reason);
            Assert.IsTrue(PlacementCheck.Check(root, new PlacementSpec { tolerance = 0.06f }).Pass);
        }
    }
}
