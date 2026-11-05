using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using NUnit.Framework;
using YetiKit.Core;
using YetiKit.Core.Editor;
using UnityEditor;
using UnityEngine;
using UnityEngine.TestTools;

namespace YetiKit.Core.Tests
{
    public class BuildStampTests
    {
        Func<string, string> git, env;
        readonly Dictionary<string, string> vars = new Dictionary<string, string>();
        readonly List<string> calls = new List<string>();
        static readonly DateTime Utc = new DateTime(2026, 11, 1, 12, 0, 0, DateTimeKind.Utc);

        [SetUp]
        public void SetUp()
        {
            git = BuildStamp.Git; env = BuildStamp.Env;
            vars.Clear(); calls.Clear();
            BuildStamp.Env = k => vars.TryGetValue(k, out var v) ? v : null;
            BuildStamp.Git = a =>
            {
                calls.Add(a);
                if (a.StartsWith("rev-list")) return "141\n";
                if (a.StartsWith("rev-parse")) return "d3050c5\n";
                return "Merge pull request #229 from a/b" + ReleaseNotes.Field + "Capture: hold to talk" + ReleaseNotes.Record;
            };
        }

        [TearDown]
        public void TearDown()
        {
            BuildStamp.Git = git; BuildStamp.Env = env;
            BuildStamp.Remove();
        }

        [Test]
        public void TheNumberAndShaComeFromGitAndTheNotesFromTheLastMerges()
        {
            var info = BuildStamp.Collect(Utc);
            Assert.AreEqual("b141-d3050c5", info.Id);
            Assert.AreEqual("2026-11-01T12:00:00Z", info.Date);
            CollectionAssert.AreEqual(new[] { "Capture: hold to talk" }, info.Notes);
            StringAssert.EndsWith(" -n 8 HEAD", calls[2]);
        }

        [Test]
        public void TheNotesFileWinsAndThePreviousShaLimitsTheMerges()
        {
            var file = Path.Combine(Path.GetTempPath(), "notes-" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                File.WriteAllText(file, "- Who's playing\n- Build number\n");
                vars[BuildStamp.NotesEnv] = file;
                CollectionAssert.AreEqual(new[] { "Who's playing", "Build number" }, BuildStamp.Collect(Utc).Notes);
                vars[BuildStamp.NotesEnv] = "";
                vars[BuildStamp.PrevShaEnv] = "abc1234";
                BuildStamp.Collect(Utc);
                StringAssert.EndsWith(" abc1234..HEAD", calls[calls.Count - 1]);
            }
            finally { File.Delete(file); }
        }

        [TestCase("")]
        [TestCase(" \r\n\t\n")]
        [TestCase("# intentionally no notes\n  # another comment\n")]
        public void AnExplicitEmptyNotesFileDoesNotFallBackToMerges(string text)
        {
            var file = Path.GetTempFileName();
            try
            {
                File.WriteAllText(file, text);
                vars[BuildStamp.NotesEnv] = file;
                vars[BuildStamp.PrevShaEnv] = "abc1234";
                Assert.IsEmpty(BuildStamp.Collect(Utc).Notes);
                Assert.AreEqual(2, calls.Count, "only the number and SHA queries, never a merge query");
            }
            finally { File.Delete(file); }
        }

        [Test]
        public void AnUnreadableNotesFileStillFallsBackToMerges()
        {
            vars[BuildStamp.NotesEnv] = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "missing.txt");
            LogAssert.Expect(LogType.Warning, new System.Text.RegularExpressions.Regex("cannot read YETIKIT_WHATS_NEW"));
            CollectionAssert.AreEqual(new[] { "Capture: hold to talk" }, BuildStamp.Collect(Utc).Notes);
            StringAssert.EndsWith(" -n 8 HEAD", calls[2]);
        }

        [TestCase(null, true)]
        [TestCase("", false)]
        [TestCase("\n", false)]
        public void OnlyAFailedPreviousShaQueryRetriesTheLastEightMerges(string rangeResult, bool retries)
        {
            vars[BuildStamp.PrevShaEnv] = "abc1234";
            var original = BuildStamp.Git;
            BuildStamp.Git = a =>
            {
                if (!a.EndsWith("abc1234..HEAD")) return original(a);
                calls.Add(a);
                return rangeResult;
            };
            var notes = BuildStamp.Collect(Utc).Notes;
            Assert.AreEqual(retries ? 4 : 3, calls.Count);
            StringAssert.EndsWith(" abc1234..HEAD", calls[2]);
            if (retries)
            {
                StringAssert.EndsWith(" -n 8 HEAD", calls[3]);
                CollectionAssert.AreEqual(new[] { "Capture: hold to talk" }, notes);
            }
            else Assert.IsEmpty(notes, "a successful empty range must remain empty");
        }

        [Test]
        public void AFailedRangeAndFailedFallbackLeaveEmptyNotes()
        {
            vars[BuildStamp.PrevShaEnv] = "abc1234";
            var original = BuildStamp.Git;
            BuildStamp.Git = a =>
            {
                if (!a.StartsWith("log ")) return original(a);
                calls.Add(a);
                return null;
            };
            Assert.IsEmpty(BuildStamp.Collect(Utc).Notes);
            Assert.AreEqual(4, calls.Count, "only one fallback attempt");
        }

        [Test]
        public void EnvironmentVariableNamesCanBeOverridden()
        {
            vars["CUSTOM_PREV_SHA"] = "abc1234";
            BuildStamp.Collect(Utc, notesEnv: "CUSTOM_WHATS_NEW", prevShaEnv: "CUSTOM_PREV_SHA");
            StringAssert.EndsWith(" abc1234..HEAD", calls[2]);
        }

        [TestCase("not-a-sha")]
        [TestCase("abc")]
        public void AnInvalidPreviousShaUsesTheDefaultQueryDirectly(string prev)
        {
            vars[BuildStamp.PrevShaEnv] = prev;
            BuildStamp.Collect(Utc);
            Assert.AreEqual(3, calls.Count);
            StringAssert.EndsWith(" -n 8 HEAD", calls[2]);
        }

        [Test]
        public void GitFailingIsBuildZeroAndAWarningNeverAFailure()
        {
            BuildStamp.Git = _ => null;
            LogAssert.Expect(LogType.Warning, new System.Text.RegularExpressions.Regex("git failed"));
            var info = BuildStamp.Collect(Utc);
            Assert.AreEqual(0, info.Number);
            Assert.IsFalse(info.Known);
            Assert.IsEmpty(info.Notes);
        }

        [Test]
        public void TheStampedBuildSeesTheVersionAndFileAndEverythingIsPutBack()
        {
            var version = PlayerSettings.bundleVersion;
            var code = PlayerSettings.Android.bundleVersionCode;
            string during = null, json = null;
            var duringCode = 0;
            var resourcesExisted = Directory.Exists("Assets/Resources");
            using (BuildStamp.For(new BuildInfo(141, "d3050c5", Utc, new[] { "a note" })))
            {
                during = PlayerSettings.bundleVersion;
                duringCode = PlayerSettings.Android.bundleVersionCode;
                json = File.ReadAllText(BuildStamp.AssetPath);
            }
            Assert.AreEqual("1.0.141", during);
            Assert.AreEqual(141, duringCode);
            Assert.AreEqual("b141-d3050c5", BuildInfo.Parse(json).Id);
            Assert.AreEqual(version, PlayerSettings.bundleVersion, "restored");
            Assert.AreEqual(code, PlayerSettings.Android.bundleVersionCode, "restored");
            Assert.IsFalse(File.Exists(BuildStamp.AssetPath), "the generated file is gone");
            if (!resourcesExisted)
                Assert.IsFalse(AssetDatabase.IsValidFolder("Assets/Resources"), "no empty folder left behind");
        }

        [TestCase(0)] // directory creation failed before producing anything
        [TestCase(1)] // write failed, leaving an unimported partial file
        [TestCase(2)] // import failed after the file was written
        public void ASetupFailureRestoresBothVersionsAndRemovesPartialAssets(int stage)
        {
            var version = PlayerSettings.bundleVersion;
            var code = PlayerSettings.Android.bundleVersionCode;
            var resourcesExisted = Directory.Exists("Assets/Resources");
            var generatedExisted = Directory.Exists("Assets/Resources/Generated");
            var failure = new IOException("injected setup failure");
            Action setup = () =>
            {
                Assert.AreEqual("1.0.141", PlayerSettings.bundleVersion);
                Assert.AreEqual(141, PlayerSettings.Android.bundleVersionCode);
                if (stage > 0)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(BuildStamp.AssetPath));
                    File.WriteAllText(BuildStamp.AssetPath, stage == 1 ? "{partial" : "{}");
                }
                if (stage == 2)
                    AssetDatabase.ImportAsset(BuildStamp.AssetPath, ImportAssetOptions.ForceSynchronousImport);
                throw failure;
            };
            var method = typeof(BuildStamp).GetMethod("Stamp", BindingFlags.Static | BindingFlags.NonPublic);
            Assert.IsNotNull(method);
            var thrown = Assert.Throws<TargetInvocationException>(() => method.Invoke(null,
                new object[] { new BuildInfo(141, "d3050c5", Utc, null), setup, BuildStamp.AssetPath }));
            Assert.AreSame(failure, thrown.InnerException, "the original setup exception is rethrown");
            Assert.AreEqual(version, PlayerSettings.bundleVersion);
            Assert.AreEqual(code, PlayerSettings.Android.bundleVersionCode);
            Assert.IsFalse(File.Exists(BuildStamp.AssetPath));
            Assert.IsFalse(File.Exists(BuildStamp.AssetPath + ".meta"));
            if (!generatedExisted) Assert.IsFalse(Directory.Exists("Assets/Resources/Generated"));
            if (!resourcesExisted) Assert.IsFalse(Directory.Exists("Assets/Resources"));
        }

        [Test]
        public void AConsumerCanChooseItsGeneratedAssetPath()
        {
            const string path = "Assets/CoreStampTest/Resources/BuildInfo.json";
            try
            {
                using (BuildStamp.For(new BuildInfo(141, "d3050c5", Utc, null), path))
                {
                    Assert.IsTrue(File.Exists(path));
                    Assert.AreEqual(141, BuildInfo.Parse(File.ReadAllText(path)).Number);
                    Assert.IsFalse(File.Exists(BuildStamp.AssetPath));
                }
                Assert.IsFalse(Directory.Exists("Assets/CoreStampTest"));
            }
            finally { AssetDatabase.DeleteAsset("Assets/CoreStampTest"); }
        }

        [TestCase("../outside.json")]
        [TestCase("Assets/../outside.json")]
        [TestCase("Assets//outside.json")]
        [TestCase("Assets/stamp.txt")]
        public void InvalidStampPathsFailBeforeChangingSettings(string path)
        {
            var version = PlayerSettings.bundleVersion;
            Assert.Throws<ArgumentException>(() => BuildStamp.For(new BuildInfo(), path));
            Assert.Throws<ArgumentException>(() => BuildStamp.Remove(path));
            Assert.AreEqual(version, PlayerSettings.bundleVersion);
        }

        [Test]
        public void AThrowingBuildStillRestores()
        {
            var version = PlayerSettings.bundleVersion;
            Assert.Throws<InvalidOperationException>(() =>
            {
                using (BuildStamp.For(new BuildInfo(141, "d3050c5", Utc, null)))
                    throw new InvalidOperationException();
            });
            Assert.AreEqual(version, PlayerSettings.bundleVersion);
            Assert.IsFalse(File.Exists(BuildStamp.AssetPath));
        }
    }

    // Exercise actual pipes and process termination, not just a mocked Git delegate.
    public class BuildStampProcessTests
    {
        static string Run(string command, int timeoutMilliseconds)
        {
            var psi = new ProcessStartInfo("/bin/sh", "-c \"" + command.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            var method = typeof(BuildStamp).GetMethod("RunProcess", BindingFlags.Static | BindingFlags.NonPublic);
            Assert.IsNotNull(method);
            return (string)method.Invoke(null, new object[] { psi, timeoutMilliseconds });
        }

        [SetUp]
        public void RequiresPosixShell() => Assume.That(File.Exists("/bin/sh"), "real pipe tests require /bin/sh");

        [Test]
        public void LargeStdoutAndStderrAreBothDrainedWithoutDeadlock()
        {
            var line = new string('o', 128);
            var command = "i=0; while [ $i -lt 2048 ]; do printf '" + line + "'; printf '" + line + "' >&2; i=$((i+1)); done";
            Assert.AreEqual(new string('o', 128 * 2048), Run(command, 5000));
        }

        [TestCase("printf 'success'", "success")]
        [TestCase("exit 0", "")]
        [TestCase("printf 'not success'; printf 'failure' >&2; exit 7", null)]
        public void ExitStatusDistinguishesSuccessIncludingEmptyOutputFromFailure(string command, string expected)
        {
            Assert.AreEqual(expected, Run(command, 5000));
        }

        [TestCase(false)]
        [TestCase(true)]
        public void AStalledGitIsKilledWithinTheDeadlineAndCollectFallsBackToBuildZero(bool closeStdout)
        {
            var pidFile = Path.GetTempFileName();
            var git = BuildStamp.Git;
            var env = BuildStamp.Env;
            Process process = null;
            try
            {
                // exec keeps the recorded PID: no orphan sleep child when the deadline kills it.
                var command = "echo $$ > '" + pidFile.Replace("'", "'\\''") + "'; " +
                    (closeStdout ? "exec 1>&-; " : "printf 'partial'; ") + "exec sleep 4";
                var clock = Stopwatch.StartNew();
                Assert.IsNull(Run(command, 500));
                Assert.Less(clock.ElapsedMilliseconds, 3000, "the timeout must include waiting for redirected output");
                var pid = int.Parse(File.ReadAllText(pidFile).Trim());
                try { process = Process.GetProcessById(pid); }
                catch (ArgumentException) { /* already reaped */ }
                if (process != null) Assert.IsTrue(process.WaitForExit(2000), "the timed-out process must be killed");

                BuildStamp.Git = _ => Run("exec sleep 4", 100);
                BuildStamp.Env = _ => null;
                LogAssert.Expect(LogType.Warning, new System.Text.RegularExpressions.Regex("git failed"));
                clock.Restart();
                var info = BuildStamp.Collect(DateTime.UtcNow);
                Assert.AreEqual(0, info.Number);
                Assert.IsFalse(info.Known);
                Assert.IsEmpty(info.Notes);
                Assert.Less(clock.ElapsedMilliseconds, 3000, "timeouts must let the build continue");
            }
            finally
            {
                BuildStamp.Git = git;
                BuildStamp.Env = env;
                if (process != null)
                {
                    if (!process.HasExited) process.Kill();
                    process.Dispose();
                }
                File.Delete(pidFile);
            }
        }
    }
}
