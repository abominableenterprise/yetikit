using System.Linq;
using NUnit.Framework;
using UnityEditor.Compilation;
using UnityEditor.PackageManager;

namespace YetiKit.Lab.Tests
{
    public sealed class PassthroughIsolationTests
    {
        [Test]
        public void OptionalAssemblyRequiresBothPackagesAndCoreDoesNotReferenceIt()
        {
            var packages = PackageInfo.GetAllRegisteredPackages();
            bool Has(string name) => packages.Any(package => package.name == name);
            var assemblies = CompilationPipeline.GetAssemblies();
            var core = assemblies.Single(assembly => assembly.name == "YetiKit.Lab");
            Assert.That(core.assemblyReferences.Select(assembly => assembly.name),
                HasNoOptionalDependencies());
            Assert.That(assemblies.Any(assembly => assembly.name == "YetiKit.Lab.Passthrough"),
                Is.EqualTo(Has("com.unity.xr.arfoundation") && Has("com.unity.xr.meta-openxr")));
        }

        static NUnit.Framework.Constraints.Constraint HasNoOptionalDependencies() =>
            Does.Not.Contain("YetiKit.Lab.Passthrough").And.Not.Contain("Unity.XR.ARFoundation");
    }
}
