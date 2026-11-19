using System;
using System.IO;
using System.Linq;
using Game.Dev;
using NUnit.Framework;
using UnityEngine;
using YetiKit.Playtest;

namespace YetiKit.Starter.HostTests
{
    public sealed class StarterPhotoStorageTests
    {
        sealed class Interrupted : Exception { }

        [Test]
        public void NextSnapRecoversAnInterruptedPair()
        {
            InSnapDirectory(directory =>
            {
                string first = null, second = null;
                Assert.Throws<Interrupted>(() => StarterPhoto.SavePair(directory, new byte[] { 1 }, default, (path, bytes) =>
                {
                    if (first == null)
                    {
                        FileChunkStore.WriteAtomic(path, bytes);
                        first = path;
                        return;
                    }

                    second = path;
                    File.WriteAllBytes(second + FileChunkStore.TmpSuffix, bytes);
                    // Simulate losing the process before the second rename, skipping normal error cleanup.
                    throw new Interrupted();
                }));
                var temp = second + FileChunkStore.TmpSuffix;
                Assert.That(Directory.GetFiles(directory), Is.EquivalentTo(new[] { first, temp }));

                StarterPhoto.SavePair(directory, new byte[] { 2 }, default);

                Assert.That(Directory.GetFiles(directory).Intersect(new[] { first, temp }), Is.Empty,
                    "The next snap must remove both files left by the interruption.");
                Assert.That(Path.GetExtension(first), Is.EqualTo(".png"));
                Assert.That(Path.GetExtension(second), Is.EqualTo(".json"));
                var files = Directory.GetFiles(directory);
                Assert.That(files, Has.Length.EqualTo(2));
                var photo = files.Single(path => Path.GetExtension(path) == ".png");
                Assert.That(files, Does.Contain(Path.ChangeExtension(photo, ".json")));
                Assert.That(File.ReadAllBytes(photo), Is.EqualTo(new byte[] { 2 }));
            });
        }

        [Test]
        public void RecoveryRemovesLegacyOrphansButKeepsCompletePairsAndOtherFiles()
        {
            InSnapDirectory(directory =>
            {
                string Stem(string folder) => Path.Combine(folder, "starter-photo-" + Guid.NewGuid().ToString("N"));
                var legacy = Stem(directory);
                var tempOnly = Stem(directory) + ".png.tmp";
                var pngOnly = Stem(directory) + ".png";
                var legacyFiles = new[] { legacy + ".json", legacy + ".png.tmp", tempOnly, pngOnly };
                var complete = Stem(directory);
                var leftover = complete + ".json.tmp";
                var nested = Directory.CreateDirectory(Path.Combine(directory, "nested")).FullName;
                var preserved = new[]
                {
                    complete + ".png", complete + ".json", Path.Combine(directory, "starter-photo-not-a-snap.json"),
                    Stem(directory) + ".txt", Stem(Path.GetDirectoryName(directory)) + ".json", Stem(nested) + ".png.tmp"
                };
                foreach (var path in legacyFiles.Append(leftover).Concat(preserved)) File.WriteAllText(path, "synthetic");

                StarterPhoto.SavePair(directory, new byte[] { 1 }, default);

                Assert.That(Directory.GetFiles(directory).Intersect(legacyFiles.Append(leftover)), Is.Empty);
                foreach (var path in preserved) Assert.That(File.ReadAllText(path), Is.EqualTo("synthetic"));
            });
        }

        static void InSnapDirectory(Action<string> run)
        {
            var root = Path.Combine(Path.GetTempPath(), "starter-check-" + Guid.NewGuid().ToString("N"));
            var snaps = Directory.CreateDirectory(Path.Combine(root, "snaps"));
            try { run(snaps.FullName); }
            finally { Directory.Delete(root, true); }
        }
    }

    sealed class StarterPhotoChecks : IDisposable
    {
        readonly string directory = Path.Combine(Path.GetTempPath(), "starter-check-" + Guid.NewGuid().ToString("N"));

        public StarterPhotoChecks(StarterLab lab)
        {
            Directory.CreateDirectory(directory);
            lab.PhotoDirectory = directory;
        }

        public void AssertLocalSnap(StarterLab lab, string experiment, float effective, float authored, bool hasOverride,
            bool canPersist = true)
        {
            Assert.That(lab.PhotoStatus, Is.EqualTo("Photo saved locally."));
            var files = Directory.GetFileSystemEntries(directory);
            Assert.That(files, Has.Length.EqualTo(2), "Only a local PNG and its JSON context; no outbox or session.");
            var photo = files.Single(path => Path.GetExtension(path) == ".png");
            var metadata = Path.ChangeExtension(photo, ".json");
            Assert.That(files, Does.Contain(metadata));
            var context = JsonUtility.FromJson<StarterPhoto.Context>(File.ReadAllText(metadata));
            Assert.That(context.experiment, Is.EqualTo(experiment));
            Assert.That(context.snapTurnDegrees, Is.EqualTo(effective));
            Assert.That(context.defaultSnapTurnDegrees, Is.EqualTo(authored));
            Assert.That(context.hasOverride, Is.EqualTo(hasOverride));
            Assert.That(context.tuningPersistenceAvailable, Is.EqualTo(canPersist));

            var image = new Texture2D(2, 2);
            try
            {
                Assert.That(image.LoadImage(File.ReadAllBytes(photo)), Is.True);
                Assert.That((image.width, image.height), Is.EqualTo((768, 480)));
                var pixels = image.GetPixels32();
                Assert.That(pixels.Any(pixel => !pixel.Equals(pixels[0])), Is.True, "The synthetic room must be visible.");
            }
            finally { UnityEngine.Object.Destroy(image); }

            File.Delete(photo);
            File.Delete(metadata);
        }

        public void AssertDestinationErrors(StarterLab lab, Action click)
        {
            var missing = Path.Combine(directory, "missing");
            lab.PhotoDirectory = missing;
            click();
            Assert.That(lab.PhotoStatus, Is.EqualTo("Photo folder unavailable."));
            Assert.That(Directory.Exists(missing), Is.False);

            // A regular file cannot serve as a folder, even for an elevated test runner.
            var blocked = Path.Combine(directory, "blocked");
            File.WriteAllText(blocked, "synthetic");
            lab.PhotoDirectory = blocked;
            click();
            Assert.That(lab.PhotoStatus, Is.EqualTo("Could not write photo."));
            Assert.That(File.ReadAllText(blocked), Is.EqualTo("synthetic"));
            Assert.That(Directory.GetFileSystemEntries(directory), Is.EqualTo(new[] { blocked }));
            lab.PhotoDirectory = directory;
        }

        public void Dispose() => Directory.Delete(directory, true);
    }
}
