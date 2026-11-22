#!/usr/bin/env python3
"""Offline regressions for the release consumer's dependency set."""

import json
from pathlib import Path
import runpy
import tempfile
import unittest

GENERATOR = runpy.run_path(Path(__file__).with_name("release-consumer-manifest.py"))
KIT = GENERATOR["KIT"]
PLAYTEST = KIT + "playtest"
CORE = KIT + "core"
IMAGE = "com.unity.modules.imageconversion"
JSON = "com.unity.modules.jsonserialize"
PHYSICS = "com.unity.modules.physics"


class ConsumerManifestTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "README.md").write_text(
            f"# Kit\n\n## Modules\n\n| [playtest](Packages/{PLAYTEST}/README.md) | available |\n"
            f"\n## Other\n\n[unlisted](Packages/{KIT}unlisted/README.md)\n",
            encoding="utf-8",
        )
        self.package(PLAYTEST, {CORE: "0.3.1", "com.unity.fixture": "1.2.3"})
        self.package(CORE, {IMAGE: "1.0.0", JSON: "1.0.0"})
        self.package(KIT + "unlisted", {PHYSICS: "1.0.0"})
        host = self.root / "Host/Packages"
        host.mkdir(parents=True)
        (host / "manifest.json").write_text(json.dumps({"dependencies": {PHYSICS: "1.0.0"}}))
        (host / "packages-lock.json").write_text(json.dumps({"dependencies": {IMAGE: {}}}))

    def package(self, name, deps):
        path = self.root / "Packages" / name
        path.mkdir(parents=True, exist_ok=True)
        (path / "package.json").write_text(json.dumps({"name": name, "dependencies": deps}))

    def manifest(self):
        names = GENERATOR["advertised_packages"](self.root)
        return GENERATOR["consumer_manifest"](self.root, names)["dependencies"]

    def test_only_advertised_packages_and_their_declared_local_closure(self):
        self.assertEqual(self.manifest(), {
            PLAYTEST: f"file:{self.root.resolve() / 'Packages' / PLAYTEST}",
            CORE: f"file:{self.root.resolve() / 'Packages' / CORE}",
            IMAGE: "1.0.0",
            JSON: "1.0.0",
        })

    def test_removing_a_declaration_drops_the_builtin_even_if_locked_in_host(self):
        before = self.manifest()
        self.assertEqual(before.pop(IMAGE), "1.0.0")
        self.package(CORE, {JSON: "1.0.0"})
        self.assertEqual(self.manifest(), before)

    def test_checkout_advertises_resolvable_packages(self):
        root = GENERATOR["ROOT"]
        names = GENERATOR["advertised_packages"](root)
        manifest = GENERATOR["consumer_manifest"](root, names)["dependencies"]
        self.assertTrue(all(manifest[name].startswith("file:") for name in names))


if __name__ == "__main__":
    unittest.main()
