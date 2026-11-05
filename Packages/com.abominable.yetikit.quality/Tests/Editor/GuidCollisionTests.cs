using System;
using System.IO;
using NUnit.Framework;
using YetiKit.Quality.Editor;

namespace YetiKit.Quality.Tests
{
    public class GuidCollisionTests
    {
        const string GuidText = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        string folder;

        [SetUp] public void SetUp()
        {
            // Keep raw, duplicate metadata outside Assets so Unity never imports it.
            folder = Path.Combine(Path.GetTempPath(), "QualityGuid-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
        }

        [TearDown] public void TearDown() => Directory.Delete(folder, true);

        static void WriteMeta(string directory, string name = "asset.meta")
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, name), "guid: " + GuidText + "\n");
        }

        [Test] public void RepeatedCanonicalRootCountsEachFileOnce()
        {
            WriteMeta(folder);
            Assert.IsEmpty(GuidCollisionCheck.Find(folder, folder, Path.Combine(folder, ".")));
        }

        [Test] public void RootAndSubfolderCountEachFileOnce()
        {
            var subfolder = Path.Combine(folder, "Sub");
            WriteMeta(subfolder);
            // Include both orders and trailing separators in root canonicalization.
            Assert.IsEmpty(GuidCollisionCheck.Find(subfolder, folder + Path.DirectorySeparatorChar));
            Assert.IsEmpty(GuidCollisionCheck.Find(folder, subfolder));
        }

        [TestCase(false)]
        [TestCase(true)]
        public void CaseInsensitiveRootsCountEachFileOnce(bool overlapping)
        {
            var upper = Path.Combine(folder, "X", "Dir");
            var lower = Path.Combine(folder, "x", "dir");
            WriteMeta(Path.Combine(upper, "Sub"));
            WriteMeta(Path.Combine(lower, "Sub"));
            // These are distinct physical files on Linux, aliases under the injected identity.
            var second = overlapping ? Path.Combine(lower, "Sub") : lower;
            Assert.IsEmpty(GuidCollisionCheck.Find(StringComparer.OrdinalIgnoreCase, upper, second));
        }

        [Test] public void CaseInsensitiveFileKeysDeduplicateWithinOneRoot()
        {
            WriteMeta(folder, "Asset.meta");
            WriteMeta(folder, "asset.meta");
            Assert.IsEmpty(GuidCollisionCheck.Find(StringComparer.OrdinalIgnoreCase, folder));
        }

        [Test] public void DistinctFilesWithDuplicateGuidStillCollide()
        {
            WriteMeta(folder, "a.meta");
            WriteMeta(folder, "b.meta");
            var result = GuidCollisionCheck.Find(StringComparer.OrdinalIgnoreCase, folder, folder);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].guid, Is.EqualTo(GuidText));
            Assert.That(result[0].paths, Is.EquivalentTo(new[]
            {
                Path.Combine(folder, "a.meta").Replace(Path.DirectorySeparatorChar, '/'),
                Path.Combine(folder, "b.meta").Replace(Path.DirectorySeparatorChar, '/')
            }));
        }

        [Test] public void OrdinalRootsKeepCaseDistinctFilesAndSiblingPrefixes()
        {
            var upper = Path.Combine(folder, "Dir");
            var lower = Path.Combine(folder, "dir");
            WriteMeta(upper);
            if (File.Exists(Path.Combine(lower, "asset.meta")))
                Assert.Ignore("Requires a case-sensitive filesystem.");
            WriteMeta(lower);
            var sibling = Path.Combine(folder, "Directory");
            WriteMeta(sibling);
            var result = GuidCollisionCheck.Find(upper, lower, sibling);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].paths.Length, Is.EqualTo(3));
        }
    }
}
