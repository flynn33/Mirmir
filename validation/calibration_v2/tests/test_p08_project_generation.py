from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class P08ProjectGenerationTests(unittest.TestCase):
    def test_generated_p08_target_is_unhosted_and_release_app_is_isolated(self) -> None:
        xcodegen = shutil.which("xcodegen")
        if xcodegen is None:
            self.skipTest("xcodegen is not installed")

        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            result = subprocess.run(
                [
                    xcodegen,
                    "--no-env",
                    "--spec",
                    str(REPOSITORY_ROOT / "project.yml"),
                    "--project",
                    str(destination),
                    "--project-root",
                    str(REPOSITORY_ROOT),
                ],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            project = (
                destination / "Mirmir.xcodeproj/project.pbxproj"
            ).read_text(encoding="utf-8")
            scheme = (
                destination
                / "Mirmir.xcodeproj/xcshareddata/xcschemes/Mirmir P08.xcscheme"
            ).read_text(encoding="utf-8")

        p08_target = self._native_target(project, "MirmirP08Tests")
        self.assertRegex(p08_target, r"dependencies = \(\s*\);")
        p08_configurations = self._target_configurations(
            project, p08_target, "MirmirP08Tests"
        )
        self.assertEqual(set(p08_configurations), {"Debug", "Release"})
        for settings in p08_configurations.values():
            self.assertIn('BUNDLE_LOADER = "";', settings)
            self.assertNotIn("TEST_HOST", settings)

        self.assertNotIn('BlueprintName = "Mirmir"', scheme)
        self.assertNotIn('BuildableName = "Mirmir.app"', scheme)
        self.assertIn('BlueprintName = "MirmirP08Tests"', scheme)

        app_target = self._native_target(project, "Mirmir")
        app_configurations = self._target_configurations(
            project, app_target, "Mirmir"
        )
        self.assertNotIn("ENABLE_TESTABILITY = YES", app_configurations["Release"])
        phases = re.search(
            r"buildPhases = \((?P<phases>.*?)\n\s*\);",
            app_target,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(phases)
        phase_text = phases.group("phases")
        self.assertIn("Resources", phase_text)
        self.assertNotIn("Inject Exact P06 ASH Release", phase_text)
        self.assertNotIn(
            'shellScript = "\\\"${SRCROOT}/Scripts/inject-ash-p06-release.sh\\\"";',
            project,
        )

    def _native_target(self, project: str, name: str) -> str:
        match = re.search(
            rf"^[ \t]*[A-F0-9]{{24}} /\* {re.escape(name)} \*/ = \{{\n"
            rf"[ \t]*isa = PBXNativeTarget;(?P<body>.*?)^\t\t\}};",
            project,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, f"native target is absent: {name}")
        return match.group("body")

    def _target_configurations(
        self,
        project: str,
        target: str,
        name: str,
    ) -> dict[str, str]:
        list_match = re.search(
            rf"buildConfigurationList = ([A-F0-9]{{24}}) /\* "
            rf"Build configuration list for PBXNativeTarget \"{re.escape(name)}\" \*/;",
            target,
        )
        self.assertIsNotNone(list_match)
        list_id = list_match.group(1)
        configuration_list = re.search(
            rf"^\t\t{list_id} /\* .*? \*/ = \{{(?P<body>.*?)^\t\t\}};",
            project,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(configuration_list)
        rows = re.findall(
            r"([A-F0-9]{24}) /\* (Debug|Release) \*/",
            configuration_list.group("body"),
        )
        configurations: dict[str, str] = {}
        for configuration_id, configuration_name in rows:
            block = re.search(
                rf"^\t\t{configuration_id} /\* {configuration_name} \*/ = \{{\n"
                rf"\t\t\tisa = XCBuildConfiguration;\n"
                rf"\t\t\tbuildSettings = \{{(?P<settings>.*?)\n\t\t\t\}};\n"
                rf"\t\t\tname = {configuration_name};",
                project,
                flags=re.MULTILINE | re.DOTALL,
            )
            self.assertIsNotNone(block)
            configurations[configuration_name] = block.group("settings")
        return configurations


if __name__ == "__main__":
    unittest.main()
