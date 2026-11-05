using System;
using System.IO;
using System.Diagnostics;
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

        [TestCase(true)]
        [TestCase(false)]
        public void CaseProbeOverridesPlatformDefaultPerRoot(bool defaultIgnoreCase)
        {
            var sensitive = Path.Combine(folder, "Sensitive");
            var insensitive = Path.Combine(folder, "Insensitive");
            WriteMeta(sensitive, "Asset.meta");
            WriteMeta(sensitive, "asset.meta");
            WriteMeta(insensitive, "Asset.meta");
            WriteMeta(insensitive, "asset.meta");
            var result = GuidCollisionCheck.Find(defaultIgnoreCase,
                path => path == sensitive ? false : path == insensitive ? true : (bool?)null,
                sensitive, insensitive);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].paths.Length, Is.EqualTo(3), "Only the insensitive root aliases its case variants.");
        }

        [Test] public void FilesystemProbeDistinguishesCaseVariantsAndLinkAliases()
        {
            var upper = Path.Combine(folder, "Probe");
            var flipped = Path.Combine(folder, "pROBE");
            Directory.CreateDirectory(upper);
            if (Directory.Exists(flipped))
            {
                Assert.That(GuidPathIdentity.IgnoresCase(upper), Is.True);
                return;
            }
            Assert.That(GuidPathIdentity.IgnoresCase(upper), Is.False);
            Directory.CreateDirectory(flipped);
            Assert.That(GuidPathIdentity.IgnoresCase(upper), Is.False, "Two real directories are not case aliases.");
            Directory.Delete(flipped);
            Link(upper, flipped);
            Assert.That(GuidPathIdentity.IgnoresCase(upper), Is.False, "A separate symlink entry does not change filesystem case sensitivity.");
            Assert.That(GuidPathIdentity.Canonical(flipped), Is.EqualTo(GuidPathIdentity.Canonical(upper)));
        }

        [Test] public void PublicFindKeepsCaseDistinctFilesOnSensitiveVolume()
        {
            WriteMeta(folder, "Asset.meta");
            if (File.Exists(Path.Combine(folder, "asset.meta")))
                Assert.Ignore("Requires a case-sensitive filesystem.");
            WriteMeta(folder, "asset.meta");
            var result = GuidCollisionCheck.Find(folder);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].paths.Length, Is.EqualTo(2));
        }

        [TestCase(true, 1)]
        [TestCase(false, 2)]
        public void InconclusiveProbeFallsBackToPlatform(bool defaultIgnoreCase, int pathCount)
        {
            WriteMeta(folder, "Asset.meta");
            WriteMeta(folder, "asset.meta");
            var result = GuidCollisionCheck.Find(defaultIgnoreCase, _ => null, folder);
            Assert.That(result.Count, Is.EqualTo(pathCount == 1 ? 0 : 1));
        }

        void Link(string target, string alias)
        {
            if (UnityEngine.Application.platform != UnityEngine.RuntimePlatform.LinuxEditor)
                Assert.Ignore("Real symlink fixture requires Linux.");
            using (var process = Process.Start(new ProcessStartInfo("ln", "-s \"" + target + "\" \"" + alias + "\"")
                { UseShellExecute = false }))
            {
                process.WaitForExit();
                Assert.That(process.ExitCode, Is.Zero);
            }
        }

        [Test] public void LinkedRootsAndAncestorComponentsCountEachFileOnce()
        {
            var target = Path.Combine(folder, "Target");
            var sub = Path.Combine(target, "Sub");
            var alias = Path.Combine(folder, "Alias");
            WriteMeta(sub);
            Link(target, alias);
            Assert.IsEmpty(GuidCollisionCheck.Find(alias, target));
            Assert.IsEmpty(GuidCollisionCheck.Find(target, alias));
            Assert.IsEmpty(GuidCollisionCheck.Find(Path.Combine(alias, "Sub"), sub));
            WriteMeta(sub, "other.meta");
            var result = GuidCollisionCheck.Find(alias, target);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].paths.Length, Is.EqualTo(2), "Real collisions survive alias deduplication.");
        }

        [Test, Timeout(10000)] public void LinkedSubfoldersAndCyclesAreVisitedOnce()
        {
            var target = Path.Combine(folder, "Target");
            WriteMeta(target);
            Link(target, Path.Combine(folder, "Alias"));
            Link(folder, Path.Combine(target, "Cycle"));
            Assert.IsEmpty(GuidCollisionCheck.Find(folder));
            WriteMeta(folder, "other.meta");
            var result = GuidCollisionCheck.Find(folder);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].paths.Length, Is.EqualTo(2));
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
