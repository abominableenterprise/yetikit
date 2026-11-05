using System.Linq;
using NUnit.Framework;
using YetiKit.Core;
using YetiKit.Core.Editor;

namespace YetiKit.Core.Tests
{
    public class ReleaseNotesTests
    {
        const string F = ReleaseNotes.Field, R = ReleaseNotes.Record;

        [Test]
        public void ANotesFileGivesOneBulletPerLine()
        {
            var notes = ReleaseNotes.FromText("- Pick who's playing\r\n\n  * Build number\n# a comment\nWhat's new\n\u2022 dots too\n");
            CollectionAssert.AreEqual(new[] { "Pick who's playing", "Build number", "What's new", "dots too" }, notes);
        }

        [Test]
        public void MergeSubjectsBecomeThePullRequestTitles()
        {
            var log = "Merge pull request #229 from example/feature" + F + "Capture: hold to talk\n\nlonger text\n" + R +
                      "\nMerge branch 'main' into feature" + F + R +
                      "\nImproved object pooling" + F + R +
                      "\nMerge pull request #7 from x/y" + F + "\n\n" + R;
            CollectionAssert.AreEqual(new[] { "Capture: hold to talk", "Improved object pooling" }, ReleaseNotes.FromMerges(log));
        }

        [Test]
        public void AtMostTwelveBulletsOf120Chars()
        {
            var text = string.Join("\n", Enumerable.Range(0, 20).Select(i => "- note " + i + " " + new string('x', 200)));
            var notes = ReleaseNotes.FromText(text);
            Assert.AreEqual(BuildInfo.MaxNotes, notes.Length);
            Assert.IsTrue(notes.All(n => n.Length == BuildInfo.MaxNoteLength && n.EndsWith("\u2026")));
            Assert.IsEmpty(ReleaseNotes.FromMerges(null));
        }
    }
}
