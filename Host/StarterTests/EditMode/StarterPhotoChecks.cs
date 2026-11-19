using System;
using System.IO;
using System.Linq;
using Game.Dev;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Starter.HostTests
{
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
