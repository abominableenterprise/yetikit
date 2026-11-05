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
            RequireCaseSensitiveFiles(sensitive);
            WriteMeta(sensitive, "asset.meta");
            WriteMeta(insensitive, "Asset.meta");
            WriteMeta(insensitive, "asset.meta");
            var result = GuidCollisionCheck.Find(defaultIgnoreCase,
                path => path == sensitive ? false : path == insensitive ? true : (bool?)null,
                sensitive, insensitive);
            Assert.That(result.Count, Is.EqualTo(1));
            Assert.That(result[0].paths.Length, Is.EqualTo(3), "Only the insensitive root aliases its case variants.");
        }

        [Test] public void FilesystemProbeUsesContentsNotParentSpelling()
        {
            var root = Path.Combine(folder, "Probe");
            Directory.CreateDirectory(root);
            Assert.That(GuidPathIdentity.IgnoresCase(root), Is.Null, "An empty root provides no evidence about its contents.");
            WriteMeta(root, "Asset.meta");
            Assert.That(GuidPathIdentity.IgnoresCase(root), Is.EqualTo(File.Exists(Path.Combine(root, "ASSET.META"))));
        }

        [Test] public void CaseEvidenceInsideRootOverridesPlatformFallback()
        {
            // Content evidence must win even when the platform fallback assumes case aliases.
            var root = Path.Combine(folder, "Probe");
            Directory.CreateDirectory(root);
            WriteMeta(root, "Asset.meta");
            RequireCaseSensitiveFiles(root);
            WriteMeta(root, "asset.meta");
            var result = GuidCollisionCheck.Find(true, path => GuidPathIdentity.IgnoresCase(path), root);
            Assert.That(result[0].paths.Length, Is.EqualTo(2));
        }

        [Test] public void LinkedTraversalReprobesDirectoryCaseIdentity()
        {
            var source = Path.Combine(folder, "Source");
            var target = Path.Combine(folder, "Target");
            Directory.CreateDirectory(source);
            WriteMeta(target, "Asset.meta");
            RequireCaseSensitiveFiles(target);
            WriteMeta(target, "asset.meta");
            WriteMeta(Path.Combine(target, "Dir"));
            WriteMeta(Path.Combine(target, "dir"));
            Link(target, Path.Combine(source, "Alias"));
            foreach (var roots in new[] { new[] { source }, new[] { source, target }, new[] { target, source } })
            {
                var result = GuidCollisionCheck.Find(true, path => path == source ? true : false, roots);
                Assert.That(result.Count, Is.EqualTo(1));
                Assert.That(result[0].paths.Length, Is.EqualTo(4), "A linked sensitive subtree preserves distinct files and directories.");
            }
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

        [Test] public void CaseDistinctFixtureGuardSkipsWhenLowercasePathAlreadyExists()
        {
            WriteMeta(folder);
            Assert.Throws<IgnoreException>(() => RequireCaseSensitiveFiles(folder));
        }

        static void RequireCaseSensitiveFiles(string directory)
        {
            if (File.Exists(Path.Combine(directory, "asset.meta")))
                Assert.Ignore("Requires a case-sensitive filesystem.");
        }

        [TestCase(true, 1)]
        [TestCase(false, 2)]
        public void InconclusiveProbeFallsBackToPlatform(bool defaultIgnoreCase, int pathCount)
        {
            WriteMeta(folder, "Asset.meta");
            RequireCaseSensitiveFiles(folder);
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
