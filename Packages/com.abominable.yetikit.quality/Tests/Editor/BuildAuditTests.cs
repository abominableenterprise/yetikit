using System;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.Build;
using YetiKit.Quality.Editor;

namespace YetiKit.Quality.Tests
{
    public class BuildAuditTests
    {
        [TearDown] public void TearDown() => BuildAuditHook.Disable();
        [TestCase("Consumer.Dev.Tools")]
        [TestCase("YetiKit.Playtest")]
        [TestCase("YetiKit.Lab.Editor")]
        public void DefaultRulesRejectDevAssemblies(string assembly) =>
            Assert.That(BuildAudit.Check(new[] { assembly }, Array.Empty<string>(), new BuildAuditRules()).Count, Is.EqualTo(1));

        [Test] public void MicIsAllowedButUnlistedPermissionIsRejected()
        {
            var rules = new BuildAuditRules { allowedPermissions = new[] { "android.permission.RECORD_AUDIO" } };
            Assert.IsEmpty(BuildAudit.Check(new[] { "Consumer.Runtime" }, rules.allowedPermissions, rules));
            var violations = BuildAudit.Check(Array.Empty<string>(), new[] { "android.permission.CAMERA" }, rules);
            Assert.That(violations.Count, Is.EqualTo(1));
            StringAssert.Contains("CAMERA", violations[0]);
        }
        [Test] public void CustomDenyListsAreApplied()
        {
            var rules = new BuildAuditRules
            {
                forbiddenAssemblyPrefixes = new[] { "Consumer.Diagnostics" },
                forbiddenPermissions = new[] { "camera" }, allowedPermissions = new[] { "camera" }
            };
            Assert.IsEmpty(BuildAudit.Check(new[] { "Consumer.Runtime" }, new[] { "camera", "network" }, rules));
            Assert.That(BuildAudit.Check(new[] { "Consumer.Diagnostics.Tools" }, Array.Empty<string>(), rules).Count, Is.EqualTo(1));
        }
        [Test] public void HookRejectsReleaseButNotDevelopmentAndCanBeDisabled()
        {
            var hook = new BuildAuditHook();
            var assemblies = new[] { "Library/PlayerScriptAssemblies/Consumer.Dev.dll" };
            Assert.That(hook.OnFilterAssemblies(BuildOptions.None, assemblies), Is.SameAs(assemblies));
            BuildAuditHook.Enable(new BuildAuditRules());
            Assert.DoesNotThrow(() => hook.OnFilterAssemblies(BuildOptions.Development, assemblies));
            Assert.Throws<BuildFailedException>(() => hook.OnFilterAssemblies(BuildOptions.None, assemblies));
            BuildAuditHook.Disable();
            Assert.DoesNotThrow(() => hook.OnFilterAssemblies(BuildOptions.None, assemblies));
        }
    }
}
