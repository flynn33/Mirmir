from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPOSITORY_ROOT / "Scripts/inject-ash-p06-release.sh"
FILENAMES = (
    "lut-manifest-v3.json",
    "locked-compiler-input-v2.json",
    "locked-mapping.json",
    "direct2x.ashlut",
    "direct3over2.ashlut",
    "native-lut-parity-manifest-v3.json",
)


class P08ReleaseInjectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "release"
        self.source.mkdir()
        for index, filename in enumerate(FILENAMES):
            (self.source / filename).write_bytes(f"member-{index}\n".encode())
        self.target = self.root / "build"
        self.temp = self.root / "temp"
        self.target.mkdir()
        self.temp.mkdir()
        self.destination = (
            self.target / "Mirmir.app/Contents/Resources/ASH/LockedV3"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, source: Path | str | None) -> subprocess.CompletedProcess[str]:
        environment = {
            **os.environ,
            "TARGET_BUILD_DIR": os.fspath(self.target),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Mirmir.app/Contents/Resources",
            "TARGET_TEMP_DIR": os.fspath(self.temp),
        }
        environment.pop("MIRMIR_P08_P06_RELEASE_ROOT", None)
        if source is not None:
            environment["MIRMIR_P08_P06_RELEASE_ROOT"] = os.fspath(source)
        return subprocess.run(
            [os.fspath(SCRIPT)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )

    def test_unset_source_removes_stale_destination_and_staging(self) -> None:
        self.destination.mkdir(parents=True)
        (self.destination / "stale").write_bytes(b"stale")
        staging = self.temp / "ASH-LockedV3"
        staging.mkdir()
        (staging / "stale").write_bytes(b"stale")

        result = self._run(None)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())
        self.assertFalse(staging.exists())

    def test_relative_and_symlink_source_roots_are_rejected(self) -> None:
        relative = self._run("release")
        self.assertNotEqual(relative.returncode, 0)
        self.assertIn("must be an absolute path", relative.stderr)

        linked = self.root / "linked-release"
        linked.symlink_to(self.source, target_is_directory=True)
        symlink = self._run(linked)
        self.assertNotEqual(symlink.returncode, 0)
        self.assertIn("non-symlink directory", symlink.stderr)

    def test_missing_extra_and_symlink_members_are_rejected(self) -> None:
        missing_root = self.root / "missing"
        shutil.copytree(self.source, missing_root)
        (missing_root / FILENAMES[0]).unlink()
        missing = self._run(missing_root)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("member is absent", missing.stderr)

        extra_root = self.root / "extra"
        shutil.copytree(self.source, extra_root)
        (extra_root / "unauthorized.bin").write_bytes(b"extra")
        extra = self._run(extra_root)
        self.assertNotEqual(extra.returncode, 0)
        self.assertIn("unauthorized member", extra.stderr)

        symlink_root = self.root / "symlink-member"
        shutil.copytree(self.source, symlink_root)
        member = symlink_root / FILENAMES[1]
        member.unlink()
        member.symlink_to(self.source / FILENAMES[1])
        symlink = self._run(symlink_root)
        self.assertNotEqual(symlink.returncode, 0)
        self.assertIn("member is absent", symlink.stderr)

    def test_hard_linked_member_is_rejected(self) -> None:
        linked_root = self.root / "hard-linked-member"
        shutil.copytree(self.source, linked_root)
        member = linked_root / FILENAMES[2]
        second_link = self.root / "second-link"
        os.link(member, second_link)

        result = self._run(linked_root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple hard links", result.stderr)

    def test_rejected_source_removes_stale_destination_and_staging(self) -> None:
        self.destination.mkdir(parents=True)
        (self.destination / "stale").write_bytes(b"stale")
        staging = self.temp / "ASH-LockedV3"
        staging.mkdir()
        (staging / "stale").write_bytes(b"stale")
        missing_root = self.root / "missing-with-stale-output"
        shutil.copytree(self.source, missing_root)
        (missing_root / FILENAMES[0]).unlink()

        result = self._run(missing_root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("member is absent", result.stderr)
        self.assertFalse(self.destination.exists())
        self.assertFalse(staging.exists())

    def test_successful_copy_is_exact_and_replaces_stale_bytes(self) -> None:
        self.destination.mkdir(parents=True)
        (self.destination / "stale").write_bytes(b"stale")

        result = self._run(self.source)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(path.name for path in self.destination.iterdir()),
            sorted(FILENAMES),
        )
        for filename in FILENAMES:
            self.assertEqual(
                (self.destination / filename).read_bytes(),
                (self.source / filename).read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()
