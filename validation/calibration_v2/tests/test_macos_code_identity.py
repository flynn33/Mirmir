from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from validation.calibration_v2.native_adapter import factory as factory_module
from validation.calibration_v2.macos_code_identity import (
    MacOSCodeIdentityError,
    _parse_macho_code_identity,
    authorize_running_code,
    dynamic_code_identity,
    static_code_identity,
)
from validation.calibration_v2.native_adapter.factory import (
    NativeAdapterError,
    _kill_process_group_and_reap,
    _popen_with_execution_gate,
    authorized_process_environment,
    run_authorized_process,
    run_authorized_pipeline,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def _code_directory(hash_type: int, identifier: str = "local.mirmir.fixture") -> bytes:
    algorithms = {1: ("sha1", 20), 2: ("sha256", 32), 3: ("sha256", 20), 4: ("sha384", 48)}
    _, hash_size = algorithms[hash_type]
    encoded = identifier.encode("utf-8") + b"\x00"
    length = 44 + len(encoded)
    return (
        struct.pack(
            ">9I4BI",
            0xFADE0C02,
            length,
            0x20000,
            2,
            length,
            44,
            0,
            0,
            0,
            hash_size,
            hash_type,
            0,
            0,
            0,
        )
        + encoded
    )


def _thin_fixture(*, alternate: bool = True) -> bytes:
    directories = [_code_directory(1)]
    slots = [0]
    if alternate:
        directories.append(_code_directory(2))
        slots.append(0x1000)
    index_size = 12 + len(directories) * 8
    offsets = []
    cursor = index_size
    for directory in directories:
        offsets.append(cursor)
        cursor += len(directory)
    superblob = struct.pack(">III", 0xFADE0CC0, cursor, len(directories))
    superblob += b"".join(
        struct.pack(">II", slot, offset)
        for slot, offset in zip(slots, offsets)
    )
    superblob += b"".join(directories)
    signature_offset = 32 + 16
    header = struct.pack(
        "<IiiIIIII",
        0xFEEDFACF,
        0x0100000C,
        0,
        2,
        1,
        16,
        0,
        0,
    )
    command = struct.pack(
        "<IIII",
        0x1D,
        16,
        signature_offset,
        len(superblob),
    )
    return header + command + superblob


def _fat_fixture(thin: bytes) -> bytes:
    table_size = 8 + 2 * 20
    x86_offset = table_size
    x86 = b"x" * 64
    arm_offset = x86_offset + len(x86)
    header = struct.pack(">II", 0xCAFEBABE, 2)
    header += struct.pack(">iiIII", 0x01000007, 3, x86_offset, len(x86), 0)
    header += struct.pack(">iiIII", 0x0100000C, 0, arm_offset, len(thin), 0)
    return header + x86 + thin


class MacOSCodeIdentityTests(unittest.TestCase):
    def test_same_fd_parser_matches_codesign_and_dynamic_identity(self) -> None:
        path = Path("/bin/sleep")
        identity = static_code_identity(path)
        completed = subprocess.run(
            ["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0)
        lines = completed.stderr.splitlines()
        cdhash = next(line.split("=", 1)[1] for line in lines if line.startswith("CDHash="))
        self.assertEqual(identity["unique_cdhash"], cdhash)
        process = subprocess.Popen([str(path), "5"])
        try:
            observed = authorize_running_code(process.pid, identity)
            self.assertEqual(observed["unique_cdhash"], cdhash)
        finally:
            process.kill()
            process.wait()

    def test_hybrid_sha_and_cdhash_substitution_is_rejected(self) -> None:
        sleep = Path("/bin/sleep")
        stand_in = Path("/usr/bin/yes")
        stand_in_security = static_code_identity(stand_in)
        forged = {
            key: stand_in_security[key]
            for key in (
                "unique_cdhash",
                "all_cdhashes",
                "digest_algorithms",
                "static_code_flags",
                "signing_kind",
                "identifier",
            )
        }
        with patch(
            "validation.calibration_v2.macos_code_identity._security_static_information",
            return_value=forged,
        ):
            with self.assertRaisesRegex(
                MacOSCodeIdentityError,
                "same-FD Mach-O and Security.framework identities differ",
            ):
                static_code_identity(sleep)

    def test_fat_and_alternate_code_directories_are_normalized(self) -> None:
        thin = _thin_fixture(alternate=True)
        parsed = _parse_macho_code_identity(thin)
        self.assertEqual(parsed["digest_algorithms"], [1, 2])
        self.assertEqual(len(parsed["all_cdhashes"]), 2)
        self.assertEqual(_parse_macho_code_identity(_fat_fixture(thin)), parsed)

        malformed = bytearray(thin)
        signature_offset = 48
        first_offset = struct.unpack_from(">I", malformed, signature_offset + 16)[0]
        struct.pack_into(">I", malformed, signature_offset + 24, first_offset)
        with self.assertRaisesRegex(MacOSCodeIdentityError, "duplicated|overlap"):
            _parse_macho_code_identity(bytes(malformed))

    def test_wrong_and_unsafe_dynamic_identity_are_rejected(self) -> None:
        expected = static_code_identity(Path("/bin/sleep"))
        process = subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL)
        try:
            with self.assertRaisesRegex(MacOSCodeIdentityError, "differs"):
                authorize_running_code(process.pid, expected)
        finally:
            process.kill()
            process.wait()

        unsafe = {
            **{
                key: expected[key]
                for key in (
                    "unique_cdhash",
                    "all_cdhashes",
                    "digest_algorithms",
                    "static_code_flags",
                    "signing_kind",
                    "identifier",
                )
            },
            "dynamic_status_flags": 0x20000001,
        }
        with patch(
            "validation.calibration_v2.macos_code_identity.dynamic_code_identity",
            return_value=unsafe,
        ):
            with self.assertRaisesRegex(MacOSCodeIdentityError, "status is unsafe"):
                authorize_running_code(123, expected)

    def test_suspended_spawn_authorizes_before_canary_and_uses_new_group(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            executable = Path("/bin/sh")
            expected = static_code_identity(executable)
            canary = root / "canary"
            retained = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            observed = {}

            def authorize(pid: int) -> None:
                state = subprocess.run(
                    ["/bin/ps", "-o", "state=", "-p", str(pid)],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                self.assertIn("T", state)
                self.assertEqual(os.getpgid(pid), pid)
                self.assertFalse(canary.exists())
                observed.update(authorize_running_code(pid, expected))

            script = (
                "echo ran > canary; "
                "dd if=/dev/fd/$MIRMIR_EXECUTION_GATE_FD bs=1 count=1 "
                "of=/dev/null 2>/dev/null; "
                "echo gate=$MIRMIR_EXECUTION_GATE_FD; "
                "/bin/ls -1 /dev/fd"
            )
            try:
                process = _popen_with_execution_gate(
                    [str(executable), "-c", script],
                    cwd=root,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=authorized_process_environment(Path("/private/tmp")),
                    pass_fds=(retained,),
                    execution_authorizer=authorize,
                )
                stdout, stderr = process.communicate()
            finally:
                os.close(retained)
            self.assertEqual(process.returncode, 0, stderr.decode("utf-8", "replace"))
            lines = stdout.decode("utf-8").splitlines()
            gate = int(lines[0].split("=", 1)[1])
            descriptors = {int(value) for value in lines[1:]}
            self.assertTrue(canary.exists())
            self.assertEqual(observed["unique_cdhash"], expected["unique_cdhash"])
            self.assertTrue({0, 1, 2, retained, gate}.issubset(descriptors))
            self.assertFalse(any(value > max(retained, gate) for value in descriptors))

    def test_wrong_spawn_identity_never_runs_canary(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            canary = root / "canary"
            expected = static_code_identity(Path("/bin/sleep"))
            with self.assertRaisesRegex(MacOSCodeIdentityError, "differs"):
                _popen_with_execution_gate(
                    ["/bin/sh", "-c", "echo ran > canary"],
                    cwd=root,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=authorized_process_environment(Path("/private/tmp")),
                    pass_fds=(),
                    execution_authorizer=lambda pid: authorize_running_code(
                        pid,
                        expected,
                    ),
                )
            self.assertFalse(canary.exists())

    def test_authorized_environment_rejects_injection(self) -> None:
        environment = dict(authorized_process_environment(Path("/private/tmp")))
        environment["DYLD_INSERT_LIBRARIES"] = "/tmp/stand-in.dylib"
        with self.assertRaisesRegex(NativeAdapterError, "environment differs"):
            _popen_with_execution_gate(
                ["/bin/cat"],
                cwd=Path("/private/tmp"),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                pass_fds=(),
                execution_authorizer=lambda pid: None,
            )

    def test_authorized_environment_rejects_user_mutable_tmpdir(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            with self.assertRaisesRegex(
                NativeAdapterError,
                "system sticky directory",
            ):
                authorized_process_environment(Path(name))

    def test_kill_cleanup_retries_eintr_and_reaps_after_esrch(self) -> None:
        with patch(
            "validation.calibration_v2.native_adapter.factory.os.killpg",
            side_effect=ProcessLookupError(),
        ), patch(
            "validation.calibration_v2.native_adapter.factory.os.waitpid",
            side_effect=[InterruptedError(), (123, 9)],
        ) as waitpid:
            _kill_process_group_and_reap(123)
        self.assertEqual(waitpid.call_count, 2)

    def test_timeout_kills_group_after_direct_child_exits(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            descendant_path = root / "descendant.pid"
            expected = static_code_identity(Path("/bin/sh"))
            with self.assertRaises(subprocess.TimeoutExpired):
                run_authorized_process(
                    [
                        "/bin/sh",
                        "-c",
                        "'/bin/sleep' 10 & echo $! > descendant.pid",
                    ],
                    cwd=root,
                    pass_fds=(),
                    execution_authorizer=lambda pid: authorize_running_code(
                        pid,
                        expected,
                    ),
                    authorized_environment=authorized_process_environment(
                        Path("/private/tmp")
                    ),
                    timeout_seconds=0.2,
                )
            descendant = int(descendant_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 2.0
            while True:
                try:
                    os.kill(descendant, 0)
                except ProcessLookupError:
                    break
                if time.monotonic() >= deadline:
                    self.fail("authorized descendant survived process-group timeout")
                time.sleep(0.01)

    def test_authorized_cwd_uses_retained_descriptor_after_path_swap(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            requested = root / "requested"
            replacement = root / "replacement"
            moved = root / "moved"
            requested.mkdir()
            replacement.mkdir()
            (requested / "marker").write_bytes(b"GOOD")
            (replacement / "marker").write_bytes(b"SWAPPED")
            expected = static_code_identity(Path("/bin/cat"))
            original_spawn = factory_module._spawn_suspended_authorized

            def swap_then_spawn(*args: object, **kwargs: object):
                requested.rename(moved)
                replacement.rename(requested)
                return original_spawn(*args, **kwargs)

            with patch.object(
                factory_module,
                "_spawn_suspended_authorized",
                side_effect=swap_then_spawn,
            ):
                result = run_authorized_process(
                    ["/bin/cat", "marker"],
                    cwd=requested,
                    pass_fds=(),
                    execution_authorizer=lambda pid: authorize_running_code(
                        pid,
                        expected,
                    ),
                    authorized_environment=authorized_process_environment(
                        Path("/private/tmp")
                    ),
                    timeout_seconds=2.0,
                )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"GOOD")

    def test_authorized_cwd_accepts_caller_retained_descriptor(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            requested = root / "requested"
            replacement = root / "replacement"
            moved = root / "moved"
            requested.mkdir()
            replacement.mkdir()
            (requested / "marker").write_bytes(b"GOOD")
            (replacement / "marker").write_bytes(b"SWAPPED")
            retained = os.open(
                requested,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            requested.rename(moved)
            replacement.rename(requested)
            expected = static_code_identity(Path("/bin/cat"))
            try:
                result = run_authorized_process(
                    ["/bin/cat", "marker"],
                    cwd_descriptor=retained,
                    pass_fds=(),
                    execution_authorizer=lambda pid: authorize_running_code(
                        pid,
                        expected,
                    ),
                    authorized_environment=authorized_process_environment(
                        Path("/private/tmp")
                    ),
                    timeout_seconds=2.0,
                )
            finally:
                os.close(retained)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"GOOD")

    def test_authorized_pipeline_never_captures_producer_stdout(self) -> None:
        identity = static_code_identity(Path("/bin/sh"))
        environment = authorized_process_environment(Path("/private/tmp"))
        observed = []

        def authorize(role: str, pid: int) -> None:
            state = subprocess.run(
                ["/bin/ps", "-o", "state=", "-p", str(pid)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.assertIn("T", state)
            observed.append(role)
            authorize_running_code(pid, identity)

        result = run_authorized_pipeline(
            ["/bin/sh", "-c", "printf secret-value"],
            ["/bin/sh", "-c", "value=$(cat); printf %s ${#value}"],
            producer_cwd=Path("/private/tmp"),
            consumer_cwd=Path("/private/tmp"),
            producer_pass_fds=(),
            consumer_pass_fds=(),
            producer_execution_authorizer=lambda pid: authorize("producer", pid),
            consumer_execution_authorizer=lambda pid: authorize("consumer", pid),
            producer_authorized_environment=environment,
            consumer_authorized_environment=environment,
            timeout_seconds=2.0,
            max_output_bytes=4096,
        )
        self.assertEqual(observed, ["producer", "consumer"])
        self.assertEqual(result.producer_returncode, 0)
        self.assertEqual(result.consumer_returncode, 0)
        self.assertEqual(result.consumer_stdout, b"12")
        self.assertFalse(hasattr(result, "producer_stdout"))

    def test_authorized_pipeline_auth_failure_runs_neither_child(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            identity = static_code_identity(Path("/bin/sh"))
            environment = authorized_process_environment(Path("/private/tmp"))
            with self.assertRaisesRegex(RuntimeError, "consumer rejected"):
                run_authorized_pipeline(
                    ["/bin/sh", "-c", "echo producer > producer-canary"],
                    ["/bin/sh", "-c", "echo consumer > consumer-canary"],
                    producer_cwd=root,
                    consumer_cwd=root,
                    producer_pass_fds=(),
                    consumer_pass_fds=(),
                    producer_execution_authorizer=lambda pid: authorize_running_code(
                        pid,
                        identity,
                    ),
                    consumer_execution_authorizer=lambda pid: (_ for _ in ()).throw(
                        RuntimeError("consumer rejected")
                    ),
                    producer_authorized_environment=environment,
                    consumer_authorized_environment=environment,
                    timeout_seconds=2.0,
                    max_output_bytes=4096,
                )
            self.assertFalse((root / "producer-canary").exists())
            self.assertFalse((root / "consumer-canary").exists())

    def test_authorized_pipeline_timeout_and_output_bound_cleanup(self) -> None:
        identity = static_code_identity(Path("/bin/sh"))
        environment = authorized_process_environment(Path("/private/tmp"))
        common = {
            "producer_cwd": Path("/private/tmp"),
            "consumer_cwd": Path("/private/tmp"),
            "producer_pass_fds": (),
            "consumer_pass_fds": (),
            "producer_execution_authorizer": lambda pid: authorize_running_code(
                pid,
                identity,
            ),
            "consumer_execution_authorizer": lambda pid: authorize_running_code(
                pid,
                identity,
            ),
            "producer_authorized_environment": environment,
            "consumer_authorized_environment": environment,
        }
        with self.assertRaises(subprocess.TimeoutExpired):
            run_authorized_pipeline(
                ["/bin/sh", "-c", "sleep 10"],
                ["/bin/sh", "-c", "cat >/dev/null"],
                timeout_seconds=0.2,
                max_output_bytes=4096,
                **common,
            )
        with self.assertRaisesRegex(NativeAdapterError, "exceeded its bound"):
            run_authorized_pipeline(
                ["/bin/sh", "-c", "printf x"],
                [
                    "/bin/sh",
                    "-c",
                    "cat >/dev/null; /usr/bin/yes x | /usr/bin/head -c 4096",
                ],
                timeout_seconds=2.0,
                max_output_bytes=64,
                **common,
            )

    def test_all_sensitive_swift_entrypoints_gate_before_arguments(self) -> None:
        paths = (
            REPOSITORY_ROOT
            / "validation/calibration_v2/native_adapter/ASHCalibrationCLIMain.swift",
            REPOSITORY_ROOT
            / "validation/calibration_v2/native_adapter/ASHCalibrationP00Main.swift",
            REPOSITORY_ROOT
            / "validation/quality/tools/production_writer/ProductionWriterMain.swift",
            REPOSITORY_ROOT
            / "validation/calibration_v2/p07/P07HoldoutFrameLoader.swift",
        )
        for path in paths:
            source = path.read_text(encoding="utf-8")
            main = source.index("static func main")
            gate = source.index("try waitForMirmirExecutionGate()", main)
            umask = source.index("Darwin.umask(0o077)", gate)
            arguments = source.index("CommandLine.arguments", main)
            self.assertLess(gate, umask, path)
            self.assertLess(umask, arguments, path)


if __name__ == "__main__":
    unittest.main()
