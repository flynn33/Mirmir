"""Hash-bound Python factory for the native Swift P06 candidate runtime."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Callable, Dict, Mapping, Sequence, Tuple
import uuid

import numpy as np

from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
)
from validation.calibration_v2.release_lock import locked_compiler_input_document
from validation.calibration_v2.reference.lut_oracle import (
    ROUTES as ORACLE_ROUTES,
    parse_locked_compiler_input,
    state_conditioning_evidence,
)
from validation.calibration_v2.reference.lut_oracle_v2 import (
    canonical_compiler_input_sha256_v2,
    parse_locked_compiler_input_v2,
    validate_lut_v2,
)
from validation.calibration_v2.runner import (
    LiveHoldoutPreopenBinding,
    bind_preregistered_inputs,
    candidate_artifact_documents,
    candidate_vector_sha256,
    corpus_lock_bundle_sha256,
    shared_bank_configuration_sha256,
)
from validation.calibration_v2.shared_bank_artifacts_v2 import (
    SharedBankArtifactMaterializerV2,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _planar_to_video_range_nv12,
    _video_range_nv12_to_planar,
)


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"

_SWIFT_SOURCE_PATHS = (
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHChromaSitingV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCoordinateModelContractV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCoordinateDiagnosticRuntimeV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedPlanePolicyDiagnosticV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHGenericPhaseCompilerDiagnosticV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHVideoProfileContractV1.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialOperatorBankV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHVideoAnalyzerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHAnalysisGridV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHRiskStateDiagnosticV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHStrictJSONV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTTypesV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerSemanticsV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryFormatV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryValidationSupportV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTValidationV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTLoaderV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTLockedConfigurationJSONV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHStrictJSONV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTTypesV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerSemanticsV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryFormatV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryValidationSupportV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTValidationV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTLoaderV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTLockedConfigurationJSONV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2Validation.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2+ConfigurationValidation.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedOperatorBankV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedLUTManifestRouteV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedCandidateLUTManifestV1.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReleaseLUTManifestV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReleaseLUTManifestV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeTypesV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedSampleRuntimeV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeTypesV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedSampleRuntimeV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedFramePipelineV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedControlRuntimeV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedControlRuntimeV3.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedControlResamplerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedNonASHOutputCacheV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferenceTypesV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2+DispatchProjection.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2+NonASHCache.swift",
    "validation/calibration_v2/native_adapter/ASHCalibrationCLISupport.swift",
    "validation/calibration_v2/native_adapter/ASHCalibrationCLIProtocol.swift",
    "validation/calibration_v2/native_adapter/ASHCalibrationCLIMain.swift",
)
_COMPILE_FLAGS = (
    "-O",
    "-whole-module-optimization",
    "-swift-version",
    "5",
    "-parse-as-library",
)
_ROUTE_FILENAMES = {
    "direct-2x": "direct2x.ashlut",
    "direct-3over2": "direct3over2.ashlut",
}
_NON_ASH_RULE_COORDINATES = tuple(
    f"bias_descriptor_{descriptor_id:02d}_q8_8" for descriptor_id in range(16)
) + (
    "weight_magnitude_q8_8",
    "weight_coherence_q8_8",
    "weight_texture_q8_8",
    "weight_risk_q8_8",
    "weight_chroma_alignment_q8_8",
    "weight_orientation_cos_q8_8",
    "weight_orientation_sin_q8_8",
    "weight_noise_q8_8",
    "weight_horizontal_phase_q8_8",
    "weight_vertical_phase_q8_8",
    "weight_route_q8_8",
)
_NON_ASH_RULE_VALUES = frozenset((-384, -256, -128, 0, 128, 256, 384))
_PERSISTED_CONTROL_MODES = frozenset(
    {
        "fixed_descriptor_uniform",
        "conventional_uniform",
        "non_ash_selector_q15",
        "nearest_uniform",
        "p00_current_production_ash",
    }
)
_CONTROL_EXECUTION_PRODUCER_SOURCE_SET_V2 = (
    (
        "validation/calibration_v2/native_adapter/factory.py",
        "native_adapter_builder_session_replay",
    ),
    (
        "validation/calibration_v2/production_evaluator.py",
        "control_execution_identity_and_evaluator_interface",
    ),
    (
        "validation/calibration_v2/production_providers.py",
        "concrete_control_execution_capability_provider",
    ),
)
_CONTROL_EXECUTION_PRODUCER_DOMAIN_V2 = (
    "mirmir-p06-control-execution-producer-v2/"
    "python-implementation-source-manifest-v1"
)
_P00_COMMIT = "20dc1a9e8057d25b0430bfcd4c09e7806dc22d0a"
_P00_BACKEND_SOURCE_SHA256 = (
    "3c3a0652441fe6f1848e096358d6631c64611827f5fdfd03f5e8045b365d3343"
)
_P00_SOURCE_PATHS = (
    "Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImageFeatures.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHReferencePipeline.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeConfiguration.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift",
    "Mirmir/Modules/MediaPipeline/MediaTypes.swift",
    "Mirmir/Modules/MediaPipeline/PixelBufferBridge.swift",
    "Mirmir/Modules/UpscalerEngine/UpscaleJob.swift",
    "Mirmir/Modules/UpscalerEngine/UpscalerEngineService.swift",
    "Mirmir/Modules/MetalRendering/MetalRenderingService.swift",
    "Mirmir/Modules/MetalRendering/DefaultMetalRenderingService.swift",
    "Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift",
)
_P00_ADAPTER_PATH = "validation/calibration_v2/native_adapter/ASHCalibrationP00Main.swift"
_P00_COMPATIBILITY_BOUNDARY = {
    "scope": (
        "reopened P00 helper NV12 output before PlanarFrame conversion, "
        "control-output caching, engine-raw metrics, and container encoding"
    ),
    "method": "p00_compatibility_nominal_video_range_clip_v1",
    "nominal_y_code_range": [16, 235],
    "nominal_chroma_code_range": [16, 240],
    "evidence": (
        "bind raw and normalized payload SHA-256 values and sizes, raw and "
        "normalized per-plane code ranges, and exact six-direction clip "
        "counts in every P00 native control record"
    ),
    "already_legal_payload_no_op_required": True,
    "direct_2x_postprocess_behavior": (
        "unchanged exact 2x; compatibility normalization only clips "
        "nominal-range excursions"
    ),
    "uniform_application": (
        "apply identically to every P00 control invocation before any "
        "comparison domain is derived"
    ),
}


class NativeAdapterError(RuntimeError):
    """Native compilation, protocol, identity, or execution failed closed."""

    def __init__(self, message: str, failure_path: Path | None = None) -> None:
        super().__init__(message)
        self.failure_path = failure_path


def _plan_schema_version(plan: Mapping[str, object]) -> str:
    """Read only the version discriminator before any plan-family projection."""

    if not isinstance(plan, Mapping):
        raise NativeAdapterError("calibration plan is not a mapping")
    schema_version = plan.get("schema_version")
    if type(schema_version) is not str or schema_version not in {"1.0.0", "2.0.0"}:
        raise NativeAdapterError("calibration plan schema version is unsupported")
    return schema_version


_LIBC = ctypes.CDLL(None, use_errno=True)
_POSIX_SPAWN_START_SUSPENDED = 0x0080
_POSIX_SPAWN_CLOEXEC_DEFAULT = 0x4000
_POSIX_SPAWN_SETPGROUP = 0x0002
_AUTHORIZED_ENVIRONMENT_KEYS = frozenset({"LANG", "LC_ALL", "PATH", "TMPDIR"})


def authorized_process_environment(tmpdir: Path) -> Mapping[str, str]:
    """Return the complete injection-resistant environment for a gated child."""

    absolute = _absolute_lexical_path(tmpdir)
    if absolute != Path("/private/tmp"):
        raise NativeAdapterError(
            "authorized subprocess TMPDIR must be the system sticky directory"
        )
    for ancestor in (Path("/"), Path("/private")):
        ancestor_descriptor = _open_directory_descriptor(
            ancestor,
            create=False,
        )
        try:
            ancestor_metadata = os.fstat(ancestor_descriptor)
            if (
                ancestor_metadata.st_uid != 0
                or stat.S_IMODE(ancestor_metadata.st_mode) & 0o022
            ):
                raise NativeAdapterError(
                    "authorized subprocess TMPDIR ancestry is mutable"
                )
        finally:
            os.close(ancestor_descriptor)
    descriptor = _open_directory_descriptor(absolute, create=False)
    try:
        metadata = os.fstat(descriptor)
        if (
            metadata.st_uid != 0
            or stat.S_IMODE(metadata.st_mode) != 0o1777
            or not stat.S_ISDIR(metadata.st_mode)
        ):
            raise NativeAdapterError(
                "authorized subprocess TMPDIR ownership or mode differs"
            )
    finally:
        os.close(descriptor)
    return {
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": os.fspath(absolute),
    }


def _validate_authorized_environment(
    environment: Mapping[str, str],
) -> Mapping[str, str]:
    if (
        set(environment) != _AUTHORIZED_ENVIRONMENT_KEYS
        or environment.get("LANG") != "C"
        or environment.get("LC_ALL") != "C"
        or environment.get("PATH") != "/usr/bin:/bin:/usr/sbin:/sbin"
    ):
        raise NativeAdapterError("authorized subprocess environment differs")
    tmpdir = environment.get("TMPDIR")
    if not isinstance(tmpdir, str):
        raise NativeAdapterError("authorized subprocess TMPDIR is absent")
    expected = authorized_process_environment(Path(tmpdir))
    if expected != dict(environment):
        raise NativeAdapterError("authorized subprocess TMPDIR is unsafe")
    return expected


class AuthorizedProcess:
    """Small Popen-compatible wrapper for an authorized posix_spawn child."""

    def __init__(
        self,
        *,
        pid: int,
        stdin_descriptor: int,
        stdout_descriptor: int,
        stderr_descriptor: int,
    ) -> None:
        self.pid = pid
        self.stdin = os.fdopen(stdin_descriptor, "wb", buffering=0)
        self.stdout = os.fdopen(stdout_descriptor, "rb", buffering=0)
        self.stderr = os.fdopen(stderr_descriptor, "rb", buffering=0)
        self.returncode: int | None = None

    def poll(self) -> int | None:
        if self.returncode is not None:
            return self.returncode
        waited, status = os.waitpid(self.pid, os.WNOHANG)
        if waited == 0:
            return None
        self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            result = self.poll()
            if result is not None:
                return result
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(("authorized-posix-spawn",), timeout)
            time.sleep(0.005)

    def kill(self) -> None:
        if self.poll() is None:
            os.killpg(self.pid, signal.SIGKILL)

    def communicate(
        self,
        input_payload: bytes | None = None,
        timeout: float | None = None,
    ) -> Tuple[bytes, bytes]:
        if input_payload is not None and not isinstance(input_payload, bytes):
            raise TypeError("authorized process input must be bytes or None")
        deadline = None if timeout is None else time.monotonic() + timeout
        stdout_descriptor = self.stdout.fileno()
        stderr_descriptor = self.stderr.fileno()
        output = {
            stdout_descriptor: bytearray(),
            stderr_descriptor: bytearray(),
        }
        selector = selectors.DefaultSelector()
        input_offset = 0
        try:
            for descriptor in output:
                os.set_blocking(descriptor, False)
                selector.register(descriptor, selectors.EVENT_READ, "output")
            if self.stdin is not None and not self.stdin.closed:
                if input_payload:
                    input_descriptor = self.stdin.fileno()
                    os.set_blocking(input_descriptor, False)
                    selector.register(
                        input_descriptor,
                        selectors.EVENT_WRITE,
                        "input",
                    )
                else:
                    self.stdin.close()
            while selector.get_map():
                remaining = (
                    None
                    if deadline is None
                    else max(0.0, deadline - time.monotonic())
                )
                if remaining == 0.0:
                    raise subprocess.TimeoutExpired(
                        ("authorized-posix-spawn",),
                        timeout,
                        output=bytes(output[stdout_descriptor]),
                        stderr=bytes(output[stderr_descriptor]),
                    )
                events = selector.select(remaining)
                if not events:
                    raise subprocess.TimeoutExpired(
                        ("authorized-posix-spawn",),
                        timeout,
                        output=bytes(output[stdout_descriptor]),
                        stderr=bytes(output[stderr_descriptor]),
                    )
                for key, _ in events:
                    try:
                        if key.data == "input":
                            assert input_payload is not None
                            written = os.write(
                                key.fd,
                                input_payload[input_offset : input_offset + 1024 * 1024],
                            )
                            if written <= 0:
                                raise OSError(
                                    "authorized process input made no progress"
                                )
                            input_offset += written
                            if input_offset == len(input_payload):
                                selector.unregister(key.fd)
                                self.stdin.close()
                        else:
                            chunk = os.read(key.fd, 1024 * 1024)
                            if chunk:
                                output[key.fd].extend(chunk)
                            else:
                                selector.unregister(key.fd)
                    except (BlockingIOError, InterruptedError):
                        continue
            self.wait(
                None
                if deadline is None
                else max(0.0, deadline - time.monotonic())
            )
        except BaseException as primary_error:
            try:
                _kill_process_group_and_reap(self.pid)
                if self.returncode is None:
                    self.returncode = -signal.SIGKILL
            except BaseException as cleanup_error:
                combined = NativeAdapterError(
                    "authorized process communication and cleanup both failed"
                )
                combined.primary_error = primary_error  # type: ignore[attr-defined]
                combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
                raise combined from primary_error
            raise
        finally:
            selector.close()
            for stream in (self.stdin, self.stdout, self.stderr):
                if stream is not None and not stream.closed:
                    stream.close()
        return (
            bytes(output[stdout_descriptor]),
            bytes(output[stderr_descriptor]),
        )


def _check_spawn_result(result: int, operation: str) -> None:
    if result != 0:
        raise OSError(result, "{}: {}".format(operation, os.strerror(result)))


def _kill_process_group_and_reap(pid: int) -> None:
    kill_error: BaseException | None = None
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        try:
            os.getpgid(pid)
        except ProcessLookupError:
            pass
        else:
            kill_error = error
    except BaseException as error:
        kill_error = error
    wait_error: BaseException | None = None
    deadline = time.monotonic() + 5.0
    while True:
        try:
            waited, _ = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                break
            if time.monotonic() >= deadline:
                wait_error = TimeoutError(
                    "authorized process could not be reaped within five seconds"
                )
                break
            time.sleep(0.005)
        except InterruptedError:
            continue
        except ChildProcessError:
            break
        except BaseException as error:
            wait_error = error
            break
    if kill_error is not None and wait_error is not None:
        combined = NativeAdapterError(
            "authorized process-group kill and reap both failed"
        )
        combined.kill_error = kill_error  # type: ignore[attr-defined]
        combined.wait_error = wait_error  # type: ignore[attr-defined]
        raise combined from kill_error
    if kill_error is not None:
        raise kill_error
    if wait_error is not None:
        raise wait_error


def _spawn_suspended_authorized(
    command: Sequence[str],
    *,
    cwd_descriptor: int,
    environment: Mapping[str, str],
    pass_fds: Sequence[int],
    execution_authorizer: Callable[[int], None],
) -> AuthorizedProcess:
    if not command or not Path(command[0]).is_absolute():
        raise NativeAdapterError("authorized executable path must be absolute")
    retained = tuple(dict.fromkeys(int(value) for value in pass_fds))
    stdin_read, stdin_write = os.pipe()
    stdout_read, stdout_write = os.pipe()
    stderr_read, stderr_write = os.pipe()
    gate_read, gate_write = os.pipe()
    attributes = ctypes.c_void_p()
    actions = ctypes.c_void_p()
    attributes_initialized = False
    actions_initialized = False
    child_pid: int | None = None
    try:
        _check_spawn_result(
            _LIBC.posix_spawnattr_init(ctypes.byref(attributes)),
            "posix_spawnattr_init",
        )
        attributes_initialized = True
        _check_spawn_result(
            _LIBC.posix_spawnattr_setflags(
                ctypes.byref(attributes),
                ctypes.c_short(
                    _POSIX_SPAWN_START_SUSPENDED
                    | _POSIX_SPAWN_CLOEXEC_DEFAULT
                    | _POSIX_SPAWN_SETPGROUP
                ),
            ),
            "posix_spawnattr_setflags",
        )
        _check_spawn_result(
            _LIBC.posix_spawnattr_setpgroup(
                ctypes.byref(attributes),
                ctypes.c_int(0),
            ),
            "posix_spawnattr_setpgroup",
        )
        _check_spawn_result(
            _LIBC.posix_spawn_file_actions_init(ctypes.byref(actions)),
            "posix_spawn_file_actions_init",
        )
        actions_initialized = True
        for source, destination in (
            (stdin_read, 0),
            (stdout_write, 1),
            (stderr_write, 2),
        ):
            _check_spawn_result(
                _LIBC.posix_spawn_file_actions_adddup2(
                    ctypes.byref(actions),
                    source,
                    destination,
                ),
                "posix_spawn_file_actions_adddup2",
            )
        _check_spawn_result(
            _LIBC.posix_spawn_file_actions_addfchdir_np(
                ctypes.byref(actions),
                ctypes.c_int(cwd_descriptor),
            ),
            "posix_spawn_file_actions_addfchdir_np",
        )
        for descriptor in retained + (gate_read,):
            if descriptor < 0:
                raise NativeAdapterError("retained subprocess descriptor is invalid")
            os.fstat(descriptor)
            _check_spawn_result(
                _LIBC.posix_spawn_file_actions_addinherit_np(
                    ctypes.byref(actions),
                    descriptor,
                ),
                "posix_spawn_file_actions_addinherit_np",
            )
        child_environment = dict(environment)
        child_environment["MIRMIR_EXECUTION_GATE_FD"] = str(gate_read)
        argv_values = [os.fsencode(value) for value in command]
        env_values = [
            os.fsencode("{}={}".format(key, value))
            for key, value in child_environment.items()
        ]
        argv = (ctypes.c_char_p * (len(argv_values) + 1))(
            *argv_values,
            None,
        )
        envp = (ctypes.c_char_p * (len(env_values) + 1))(
            *env_values,
            None,
        )
        pid = ctypes.c_int()
        _check_spawn_result(
            _LIBC.posix_spawn(
                ctypes.byref(pid),
                os.fsencode(command[0]),
                ctypes.byref(actions),
                ctypes.byref(attributes),
                argv,
                envp,
            ),
            "posix_spawn",
        )
        child_pid = int(pid.value)
        for descriptor in (stdin_read, stdout_write, stderr_write, gate_read):
            os.close(descriptor)
        stdin_read = stdout_write = stderr_write = gate_read = -1
        try:
            stop_deadline = time.monotonic() + 5.0
            while True:
                waited, status = os.waitpid(
                    child_pid,
                    os.WUNTRACED | os.WNOHANG,
                )
                if waited == child_pid:
                    if not os.WIFSTOPPED(status):
                        raise NativeAdapterError(
                            "authorized child ran or exited before validation"
                        )
                    break
                if time.monotonic() >= stop_deadline:
                    raise NativeAdapterError(
                        "authorized child did not enter suspended state"
                    )
                time.sleep(0.001)
            execution_authorizer(child_pid)
            os.kill(child_pid, signal.SIGCONT)
            if os.write(gate_write, b"\xA5") != 1:
                raise NativeAdapterError(
                    "execution gate authorization made no progress"
                )
        except BaseException:
            primary_error = sys.exc_info()[1]
            try:
                _kill_process_group_and_reap(child_pid)
            except BaseException as cleanup_error:
                combined = NativeAdapterError(
                    "execution authorization and child cleanup both failed"
                )
                combined.primary_error = primary_error  # type: ignore[attr-defined]
                combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
                child_pid = None
                raise combined from primary_error
            child_pid = None
            assert primary_error is not None
            raise primary_error.with_traceback(primary_error.__traceback__)
        os.close(gate_write)
        gate_write = -1
        process = AuthorizedProcess(
            pid=child_pid,
            stdin_descriptor=stdin_write,
            stdout_descriptor=stdout_read,
            stderr_descriptor=stderr_read,
        )
        child_pid = None
        stdin_write = stdout_read = stderr_read = -1
        return process
    finally:
        if actions_initialized:
            _LIBC.posix_spawn_file_actions_destroy(ctypes.byref(actions))
        if attributes_initialized:
            _LIBC.posix_spawnattr_destroy(ctypes.byref(attributes))
        if child_pid is not None:
            try:
                _kill_process_group_and_reap(child_pid)
            except OSError:
                pass
        for descriptor in (
            stdin_read,
            stdin_write,
            stdout_read,
            stdout_write,
            stderr_read,
            stderr_write,
            gate_read,
            gate_write,
        ):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


def spawn_authorized_process(
    command: Sequence[str],
    *,
    cwd: Path | None = None,
    cwd_descriptor: int | None = None,
    pass_fds: Sequence[int],
    execution_authorizer: Callable[[int], None],
    authorized_environment: Mapping[str, str],
) -> AuthorizedProcess:
    """Spawn a stopped, identity-authorized child with an exact FD allowlist."""

    if not callable(execution_authorizer):
        raise NativeAdapterError("authorized subprocess authorizer is absent")
    if (cwd is None) == (cwd_descriptor is None):
        raise NativeAdapterError(
            "authorized subprocess requires exactly one cwd boundary"
        )
    if cwd_descriptor is None:
        assert cwd is not None
        cwd = _absolute_lexical_path(cwd)
        retained_cwd = _open_directory_descriptor(cwd, create=False)
    else:
        if (
            not isinstance(cwd_descriptor, int)
            or isinstance(cwd_descriptor, bool)
            or cwd_descriptor < 0
        ):
            raise NativeAdapterError(
                "authorized subprocess cwd descriptor is invalid"
            )
        retained_cwd = os.dup(cwd_descriptor)
        metadata = os.fstat(retained_cwd)
        if not stat.S_ISDIR(metadata.st_mode):
            os.close(retained_cwd)
            raise NativeAdapterError(
                "authorized subprocess cwd descriptor is not a directory"
            )
    try:
        environment = _validate_authorized_environment(authorized_environment)
        retained = tuple(dict.fromkeys(int(value) for value in pass_fds))
        for value in retained:
            if value < 0:
                raise NativeAdapterError("retained subprocess descriptor is invalid")
            os.fstat(value)
        return _spawn_suspended_authorized(
            command,
            cwd_descriptor=retained_cwd,
            environment=environment,
            pass_fds=retained,
            execution_authorizer=execution_authorizer,
        )
    finally:
        os.close(retained_cwd)


def run_authorized_process(
    command: Sequence[str],
    *,
    cwd: Path | None = None,
    cwd_descriptor: int | None = None,
    pass_fds: Sequence[int],
    execution_authorizer: Callable[[int], None],
    authorized_environment: Mapping[str, str],
    timeout_seconds: float,
    input_payload: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    """Run one mandatory-authorized child with bounded group cleanup."""

    if (
        not isinstance(timeout_seconds, (int, float))
        or isinstance(timeout_seconds, bool)
        or timeout_seconds <= 0
    ):
        raise NativeAdapterError("authorized subprocess timeout is invalid")
    process = spawn_authorized_process(
        command,
        cwd=cwd,
        cwd_descriptor=cwd_descriptor,
        pass_fds=pass_fds,
        execution_authorizer=execution_authorizer,
        authorized_environment=authorized_environment,
    )
    stdout, stderr = process.communicate(
        input_payload=input_payload,
        timeout=float(timeout_seconds),
    )
    assert process.returncode is not None
    return subprocess.CompletedProcess(
        list(command),
        process.returncode,
        stdout,
        stderr,
    )


@dataclass(frozen=True)
class AuthorizedPipelineResult:
    """Non-secret pipeline status; producer stdout never enters this object."""

    producer_args: Tuple[str, ...]
    producer_returncode: int
    producer_stderr: bytes
    consumer_args: Tuple[str, ...]
    consumer_returncode: int
    consumer_stdout: bytes
    consumer_stderr: bytes


@dataclass
class _PendingAuthorizedChild:
    pid: int
    gate_descriptor: int


def _retained_cwd_descriptor(
    *,
    cwd: Path | None,
    cwd_descriptor: int | None,
) -> int:
    if (cwd is None) == (cwd_descriptor is None):
        raise NativeAdapterError(
            "authorized subprocess requires exactly one cwd boundary"
        )
    if cwd_descriptor is None:
        assert cwd is not None
        return _open_directory_descriptor(
            _absolute_lexical_path(cwd),
            create=False,
        )
    if (
        not isinstance(cwd_descriptor, int)
        or isinstance(cwd_descriptor, bool)
        or cwd_descriptor < 0
    ):
        raise NativeAdapterError("authorized subprocess cwd descriptor is invalid")
    retained = os.dup(cwd_descriptor)
    if not stat.S_ISDIR(os.fstat(retained).st_mode):
        os.close(retained)
        raise NativeAdapterError(
            "authorized subprocess cwd descriptor is not a directory"
        )
    return retained


def _spawn_pending_authorized_child(
    command: Sequence[str],
    *,
    cwd_descriptor: int,
    environment: Mapping[str, str],
    pass_fds: Sequence[int],
    stdin_source: int,
    stdout_source: int,
    stderr_source: int,
    execution_authorizer: Callable[[int], None],
) -> _PendingAuthorizedChild:
    if not command or not Path(command[0]).is_absolute():
        raise NativeAdapterError("authorized executable path must be absolute")
    if not callable(execution_authorizer):
        raise NativeAdapterError("authorized subprocess authorizer is absent")
    retained = tuple(dict.fromkeys(int(value) for value in pass_fds))
    for descriptor in retained + (
        cwd_descriptor,
        stdin_source,
        stdout_source,
        stderr_source,
    ):
        if descriptor < 0:
            raise NativeAdapterError("retained subprocess descriptor is invalid")
        os.fstat(descriptor)
    gate_read, gate_write = os.pipe()
    attributes = ctypes.c_void_p()
    actions = ctypes.c_void_p()
    attributes_initialized = False
    actions_initialized = False
    child_pid: int | None = None
    try:
        _check_spawn_result(
            _LIBC.posix_spawnattr_init(ctypes.byref(attributes)),
            "posix_spawnattr_init",
        )
        attributes_initialized = True
        _check_spawn_result(
            _LIBC.posix_spawnattr_setflags(
                ctypes.byref(attributes),
                ctypes.c_short(
                    _POSIX_SPAWN_START_SUSPENDED
                    | _POSIX_SPAWN_CLOEXEC_DEFAULT
                    | _POSIX_SPAWN_SETPGROUP
                ),
            ),
            "posix_spawnattr_setflags",
        )
        _check_spawn_result(
            _LIBC.posix_spawnattr_setpgroup(
                ctypes.byref(attributes),
                ctypes.c_int(0),
            ),
            "posix_spawnattr_setpgroup",
        )
        _check_spawn_result(
            _LIBC.posix_spawn_file_actions_init(ctypes.byref(actions)),
            "posix_spawn_file_actions_init",
        )
        actions_initialized = True
        for source, destination in (
            (stdin_source, 0),
            (stdout_source, 1),
            (stderr_source, 2),
        ):
            _check_spawn_result(
                _LIBC.posix_spawn_file_actions_adddup2(
                    ctypes.byref(actions),
                    source,
                    destination,
                ),
                "posix_spawn_file_actions_adddup2",
            )
        _check_spawn_result(
            _LIBC.posix_spawn_file_actions_addfchdir_np(
                ctypes.byref(actions),
                ctypes.c_int(cwd_descriptor),
            ),
            "posix_spawn_file_actions_addfchdir_np",
        )
        for descriptor in retained + (gate_read,):
            _check_spawn_result(
                _LIBC.posix_spawn_file_actions_addinherit_np(
                    ctypes.byref(actions),
                    descriptor,
                ),
                "posix_spawn_file_actions_addinherit_np",
            )
        child_environment = dict(environment)
        child_environment["MIRMIR_EXECUTION_GATE_FD"] = str(gate_read)
        argv_values = [os.fsencode(value) for value in command]
        env_values = [
            os.fsencode("{}={}".format(key, value))
            for key, value in child_environment.items()
        ]
        argv = (ctypes.c_char_p * (len(argv_values) + 1))(
            *argv_values,
            None,
        )
        envp = (ctypes.c_char_p * (len(env_values) + 1))(
            *env_values,
            None,
        )
        pid = ctypes.c_int()
        _check_spawn_result(
            _LIBC.posix_spawn(
                ctypes.byref(pid),
                os.fsencode(command[0]),
                ctypes.byref(actions),
                ctypes.byref(attributes),
                argv,
                envp,
            ),
            "posix_spawn",
        )
        child_pid = int(pid.value)
        os.close(gate_read)
        gate_read = -1
        deadline = time.monotonic() + 5.0
        while True:
            waited, status = os.waitpid(
                child_pid,
                os.WUNTRACED | os.WNOHANG,
            )
            if waited == child_pid:
                if not os.WIFSTOPPED(status):
                    raise NativeAdapterError(
                        "authorized child ran or exited before validation"
                    )
                break
            if time.monotonic() >= deadline:
                raise NativeAdapterError(
                    "authorized child did not enter suspended state"
                )
            time.sleep(0.001)
        execution_authorizer(child_pid)
        pending = _PendingAuthorizedChild(child_pid, gate_write)
        child_pid = None
        gate_write = -1
        return pending
    except BaseException as primary_error:
        if child_pid is not None:
            try:
                _kill_process_group_and_reap(child_pid)
            except BaseException as cleanup_error:
                combined = NativeAdapterError(
                    "pipeline child authorization and cleanup both failed"
                )
                combined.primary_error = primary_error  # type: ignore[attr-defined]
                combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
                raise combined from primary_error
        raise
    finally:
        if actions_initialized:
            _LIBC.posix_spawn_file_actions_destroy(ctypes.byref(actions))
        if attributes_initialized:
            _LIBC.posix_spawnattr_destroy(ctypes.byref(attributes))
        for descriptor in (gate_read, gate_write):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


def _resume_pending_child(child: _PendingAuthorizedChild) -> None:
    try:
        os.kill(child.pid, signal.SIGCONT)
        while True:
            try:
                written = os.write(child.gate_descriptor, b"\xA5")
                break
            except InterruptedError:
                continue
        if written != 1:
            raise NativeAdapterError(
                "execution gate authorization made no progress"
            )
    finally:
        os.close(child.gate_descriptor)
        child.gate_descriptor = -1


def _cleanup_pipeline_children(
    children: Sequence[_PendingAuthorizedChild],
) -> None:
    failures: list[BaseException] = []
    for child in children:
        if child.gate_descriptor >= 0:
            try:
                os.close(child.gate_descriptor)
            except BaseException as error:
                failures.append(error)
            child.gate_descriptor = -1
        try:
            _kill_process_group_and_reap(child.pid)
        except BaseException as error:
            failures.append(error)
    if failures:
        error = NativeAdapterError("authorized pipeline cleanup failed")
        error.cleanup_errors = tuple(failures)  # type: ignore[attr-defined]
        raise error from failures[0]


def run_authorized_pipeline(
    producer_command: Sequence[str],
    consumer_command: Sequence[str],
    *,
    producer_cwd: Path | None = None,
    producer_cwd_descriptor: int | None = None,
    consumer_cwd: Path | None = None,
    consumer_cwd_descriptor: int | None = None,
    producer_pass_fds: Sequence[int],
    consumer_pass_fds: Sequence[int],
    producer_execution_authorizer: Callable[[int], None],
    consumer_execution_authorizer: Callable[[int], None],
    producer_authorized_environment: Mapping[str, str],
    consumer_authorized_environment: Mapping[str, str],
    timeout_seconds: float,
    max_output_bytes: int,
) -> AuthorizedPipelineResult:
    """Pipe authorized producer stdout directly into an authorized consumer."""

    if (
        not isinstance(timeout_seconds, (int, float))
        or isinstance(timeout_seconds, bool)
        or timeout_seconds <= 0
        or not isinstance(max_output_bytes, int)
        or isinstance(max_output_bytes, bool)
        or max_output_bytes <= 0
    ):
        raise NativeAdapterError("authorized pipeline bounds are invalid")
    producer_directory = _retained_cwd_descriptor(
        cwd=producer_cwd,
        cwd_descriptor=producer_cwd_descriptor,
    )
    try:
        consumer_directory = _retained_cwd_descriptor(
            cwd=consumer_cwd,
            cwd_descriptor=consumer_cwd_descriptor,
        )
    except BaseException:
        os.close(producer_directory)
        raise
    descriptors: list[int] = []
    children: list[_PendingAuthorizedChild] = []
    completed_normally = False
    try:
        null_input = os.open("/dev/null", os.O_RDONLY | os.O_NOFOLLOW)
        secret_read, secret_write = os.pipe()
        producer_stderr_read, producer_stderr_write = os.pipe()
        consumer_stdout_read, consumer_stdout_write = os.pipe()
        consumer_stderr_read, consumer_stderr_write = os.pipe()
        descriptors.extend(
            (
                null_input,
                secret_read,
                secret_write,
                producer_stderr_read,
                producer_stderr_write,
                consumer_stdout_read,
                consumer_stdout_write,
                consumer_stderr_read,
                consumer_stderr_write,
            )
        )
        producer_environment = _validate_authorized_environment(
            producer_authorized_environment
        )
        consumer_environment = _validate_authorized_environment(
            consumer_authorized_environment
        )
        producer = _spawn_pending_authorized_child(
            producer_command,
            cwd_descriptor=producer_directory,
            environment=producer_environment,
            pass_fds=producer_pass_fds,
            stdin_source=null_input,
            stdout_source=secret_write,
            stderr_source=producer_stderr_write,
            execution_authorizer=producer_execution_authorizer,
        )
        children.append(producer)
        consumer = _spawn_pending_authorized_child(
            consumer_command,
            cwd_descriptor=consumer_directory,
            environment=consumer_environment,
            pass_fds=consumer_pass_fds,
            stdin_source=secret_read,
            stdout_source=consumer_stdout_write,
            stderr_source=consumer_stderr_write,
            execution_authorizer=consumer_execution_authorizer,
        )
        children.append(consumer)
        for descriptor in (
            null_input,
            secret_read,
            secret_write,
            producer_stderr_write,
            consumer_stdout_write,
            consumer_stderr_write,
        ):
            os.close(descriptor)
            descriptors.remove(descriptor)
        _resume_pending_child(consumer)
        _resume_pending_child(producer)
        captured = {
            producer_stderr_read: bytearray(),
            consumer_stdout_read: bytearray(),
            consumer_stderr_read: bytearray(),
        }
        selector = selectors.DefaultSelector()
        try:
            for descriptor in captured:
                os.set_blocking(descriptor, False)
                selector.register(descriptor, selectors.EVENT_READ)
            deadline = time.monotonic() + float(timeout_seconds)
            statuses: dict[int, int] = {}
            while selector.get_map() or len(statuses) != 2:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(
                        ("authorized-pipeline",),
                        timeout_seconds,
                    )
                for key, _ in selector.select(min(remaining, 0.05)):
                    try:
                        chunk = os.read(key.fd, 1024 * 1024)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not chunk:
                        selector.unregister(key.fd)
                        continue
                    if sum(len(value) for value in captured.values()) + len(chunk) > max_output_bytes:
                        raise NativeAdapterError(
                            "authorized pipeline output exceeded its bound"
                        )
                    captured[key.fd].extend(chunk)
                for child in children:
                    if child.pid in statuses:
                        continue
                    try:
                        waited, status = os.waitpid(child.pid, os.WNOHANG)
                    except InterruptedError:
                        continue
                    if waited == child.pid:
                        statuses[child.pid] = os.waitstatus_to_exitcode(status)
            completed_normally = True
        finally:
            selector.close()
        return AuthorizedPipelineResult(
            producer_args=tuple(producer_command),
            producer_returncode=statuses[producer.pid],
            producer_stderr=bytes(captured[producer_stderr_read]),
            consumer_args=tuple(consumer_command),
            consumer_returncode=statuses[consumer.pid],
            consumer_stdout=bytes(captured[consumer_stdout_read]),
            consumer_stderr=bytes(captured[consumer_stderr_read]),
        )
    except BaseException as primary_error:
        try:
            _cleanup_pipeline_children(children)
        except BaseException as cleanup_error:
            combined = NativeAdapterError(
                "authorized pipeline and cleanup both failed"
            )
            combined.primary_error = primary_error  # type: ignore[attr-defined]
            combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
            raise combined from primary_error
        raise
    finally:
        if not completed_normally:
            for buffer_name in ("captured",):
                value = locals().get(buffer_name)
                if isinstance(value, dict):
                    for buffer in value.values():
                        if isinstance(buffer, bytearray):
                            buffer[:] = b"\x00" * len(buffer)
        for descriptor in descriptors:
            try:
                os.close(descriptor)
            except OSError:
                pass
        os.close(producer_directory)
        os.close(consumer_directory)


def _reject_duplicate_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise NativeAdapterError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _parse_json(payload: bytes, *, trailing_newline: bool) -> Mapping[str, object]:
    expected = payload
    if trailing_newline:
        if not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
            raise NativeAdapterError("native JSON response has invalid line termination")
        expected = payload[:-1]
    try:
        value = json.loads(
            expected,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                NativeAdapterError(f"nonfinite JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NativeAdapterError("native JSON is malformed") from error
    if not isinstance(value, dict) or canonical_json_bytes(value) != expected:
        raise NativeAdapterError("native JSON is not a canonical object")
    return value


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _normalize_p00_compatibility_output(
    payload: bytes,
    *,
    width: int,
    height: int,
    route: str,
) -> tuple[bytes, Mapping[str, object]]:
    if (
        route not in _ROUTE_FILENAMES
        or width <= 0
        or height <= 0
        or width % 2
        or height % 2
    ):
        raise NativeAdapterError(
            "P00 compatibility boundary has invalid route or geometry"
        )
    luma_size = width * height
    if len(payload) != luma_size * 3 // 2:
        raise NativeAdapterError(
            "P00 compatibility boundary payload size differs from geometry"
        )
    codes = np.frombuffer(payload, dtype=np.uint8).copy()
    y = codes[:luma_size]
    cb = codes[luma_size:][0::2]
    cr = codes[luma_size:][1::2]
    raw_ranges = {
        "y": [int(np.min(y)), int(np.max(y))],
        "cb": [int(np.min(cb)), int(np.max(cb))],
        "cr": [int(np.min(cr)), int(np.max(cr))],
    }
    counts = {
        "y_below_16": int(np.count_nonzero(y < 16)),
        "y_above_235": int(np.count_nonzero(y > 235)),
        "cb_below_16": int(np.count_nonzero(cb < 16)),
        "cb_above_240": int(np.count_nonzero(cb > 240)),
        "cr_below_16": int(np.count_nonzero(cr < 16)),
        "cr_above_240": int(np.count_nonzero(cr > 240)),
    }
    np.clip(y, 16, 235, out=y)
    np.clip(cb, 16, 240, out=cb)
    np.clip(cr, 16, 240, out=cr)
    normalized = codes.tobytes()
    total = sum(counts.values())
    if total == 0 and normalized != payload:
        raise NativeAdapterError(
            "P00 legal compatibility payload changed unexpectedly"
        )
    evidence = {
        **json.loads(canonical_json_bytes(_P00_COMPATIBILITY_BOUNDARY)),
        "target_route": route,
        "raw_payload_sha256": _sha256(payload),
        "raw_payload_size_bytes": len(payload),
        "normalized_payload_sha256": _sha256(normalized),
        "normalized_payload_size_bytes": len(normalized),
        "raw_code_ranges": raw_ranges,
        "normalized_code_ranges": {
            "y": [int(np.min(y)), int(np.max(y))],
            "cb": [int(np.min(cb)), int(np.max(cb))],
            "cr": [int(np.min(cr)), int(np.max(cr))],
        },
        "clipped_sample_counts": counts,
        "total_clipped_sample_count": total,
    }
    return normalized, evidence


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and value != "0" * 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _absolute_lexical_path(path: Path) -> Path:
    """Return an absolute normalized path without resolving symbolic links."""

    return Path(os.path.abspath(os.fspath(path)))


def _open_directory_descriptor(path: Path, *, create: bool) -> int:
    """Open one lexical directory chain with no symlink-following component."""

    absolute = _absolute_lexical_path(path)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(absolute.anchor, flags)
    cursor = Path(absolute.anchor)
    try:
        for part in absolute.parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            try:
                child = os.open(part, flags, dir_fd=descriptor)
            except OSError as error:
                raise NativeAdapterError(
                    f"cache path is symbolic or not a directory: {cursor / part}"
                ) from error
            metadata = os.fstat(child)
            if not stat.S_ISDIR(metadata.st_mode):
                os.close(child)
                raise NativeAdapterError(
                    f"cache path is symbolic or not a directory: {cursor / part}"
                )
            os.close(descriptor)
            descriptor = child
            cursor /= part
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _ensure_directory(path: Path) -> None:
    descriptor = _open_directory_descriptor(path, create=True)
    os.close(descriptor)


def _path_entry_exists(path: Path) -> bool:
    absolute = _absolute_lexical_path(path)
    try:
        parent = _open_directory_descriptor(absolute.parent, create=False)
    except NativeAdapterError:
        return False
    try:
        try:
            os.stat(absolute.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return False
        return True
    finally:
        os.close(parent)


def _read_regular_at(parent: int, name: str, *, display_path: Path) -> bytes:
    try:
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as error:
        raise NativeAdapterError(f"cannot inspect regular file: {display_path}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise NativeAdapterError(f"path is symbolic or not regular: {display_path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, dir_fd=parent)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
            != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        ):
            raise NativeAdapterError(f"file changed while opening: {display_path}")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
        try:
            after_path = os.stat(
                name,
                dir_fd=parent,
                follow_symlinks=False,
            )
        except OSError as error:
            raise NativeAdapterError(
                f"file changed while reading: {display_path}"
            ) from error
    finally:
        os.close(descriptor)
    if (
        not stat.S_ISREG(after.st_mode)
        or not stat.S_ISREG(after_path.st_mode)
        or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        or (
            after_path.st_dev,
            after_path.st_ino,
            after_path.st_size,
            after_path.st_mtime_ns,
        )
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    ):
        raise NativeAdapterError(f"file changed while reading: {display_path}")
    return b"".join(chunks)


def _read_regular(path: Path) -> bytes:
    absolute = _absolute_lexical_path(path)
    parent = _open_directory_descriptor(absolute.parent, create=False)
    try:
        return _read_regular_at(parent, absolute.name, display_path=absolute)
    finally:
        os.close(parent)


def _control_execution_implementation_source_sha256_v2(
    repository_root: Path,
) -> str:
    """Hash the exact authority-ordered Python producer source manifest."""

    root = _absolute_lexical_path(repository_root)
    records: list[Mapping[str, object]] = []
    observed_casefolded_paths: set[str] = set()
    for order, (path_value, role) in enumerate(
        _CONTROL_EXECUTION_PRODUCER_SOURCE_SET_V2
    ):
        relative = PurePosixPath(path_value)
        casefolded = path_value.casefold()
        if (
            relative.is_absolute()
            or relative.as_posix() != path_value
            or not relative.parts
            or any(part in {"", ".", ".."} for part in relative.parts)
            or "\\" in path_value
            or casefolded in observed_casefolded_paths
            or not role
        ):
            raise NativeAdapterError(
                "control execution producer source authority is invalid"
            )
        observed_casefolded_paths.add(casefolded)
        payload = _read_regular(root.joinpath(*relative.parts))
        if not payload:
            raise NativeAdapterError(
                "control execution producer source is empty"
            )
        records.append(
            {
                "order": order,
                "path": path_value,
                "role": role,
                "sha256": _sha256(payload),
                "size_bytes": len(payload),
            }
        )
    manifest = {
        "domain_separator": _CONTROL_EXECUTION_PRODUCER_DOMAIN_V2,
        "implementation_role": "control_execution_producer_python",
        "schema_version": "1.0.0",
        "sources": records,
    }
    return _sha256(canonical_json_bytes(manifest))


class _InheritedCorpusBoundView:
    """Read-only bound-input view exposing one explicitly inherited V1 section."""

    def __init__(self, bound: object, base_plan: Mapping[str, object]) -> None:
        documents = getattr(bound, "documents", None)
        if not isinstance(documents, Mapping):
            raise NativeAdapterError("bound input documents are absent")
        self.documents = dict(documents)
        self.documents["calibration_plan"] = dict(base_plan)
        live = getattr(bound, "live_holdout_preopen_verification", None)
        if not isinstance(live, Mapping):
            raise NativeAdapterError("live holdout preopen verification is absent")
        self.live_holdout_preopen_verification = dict(live)
        record = getattr(bound, "record", None)
        if not callable(record):
            raise NativeAdapterError("bound input record lookup is absent")
        self._record = record

    def record(self, identifier: str) -> Mapping[str, object]:
        return self._record(identifier)


def _corpus_lock_bundle_sha256_v2(
    *,
    bound: object,
    plan: Mapping[str, object],
    repository_root: Path,
) -> str:
    """Resolve only the V2 plan's hash-bound inherited corpus bundle contract."""

    inheritance = plan.get("inheritance")
    if not isinstance(inheritance, Mapping) or (
        inheritance.get("model")
        != "hash_bound_overlay_without_mutating_calibration_plan_v1"
        or inheritance.get("base_schema_version") != "1.0.0"
        or "corpus_lock_bundle_contract"
        not in inheritance.get("inherited_sections", [])
    ):
        raise NativeAdapterError("V2 corpus bundle inheritance is not authorized")
    bindings = plan.get("input_bindings")
    if not isinstance(bindings, list):
        raise NativeAdapterError("V2 calibration-plan input bindings are absent")
    matches = [
        binding
        for binding in bindings
        if isinstance(binding, Mapping) and binding.get("id") == "calibration_plan_v1"
    ]
    if len(matches) != 1:
        raise NativeAdapterError("V2 base calibration-plan binding is not singular")
    binding = matches[0]
    relative = binding.get("path")
    if type(relative) is not str:
        raise NativeAdapterError("V2 base calibration-plan path is invalid")
    path = repository_root.joinpath(*Path(relative).parts)
    payload = _read_regular(path)
    if (
        binding.get("size_bytes") != len(payload)
        or binding.get("sha256") != _sha256(payload)
    ):
        raise NativeAdapterError("V2 base calibration-plan bytes differ from binding")
    try:
        base_plan = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                NativeAdapterError(f"nonfinite base-plan JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NativeAdapterError("V2 base calibration plan is malformed") from error
    if (
        not isinstance(base_plan, dict)
        or base_plan.get("schema_version") != "1.0.0"
        or not isinstance(base_plan.get("corpus_lock_bundle_contract"), dict)
    ):
        raise NativeAdapterError("V2 inherited corpus bundle contract is absent")
    return corpus_lock_bundle_sha256(
        _InheritedCorpusBoundView(bound, base_plan)  # type: ignore[arg-type]
    )


def _candidate_metric_policy_document(bound: object) -> Mapping[str, object]:
    """Return the existing candidate metric identity without projecting bank files."""

    record = getattr(bound, "record", None)
    if not callable(record):
        raise NativeAdapterError("bound input record lookup is absent")
    document = {
        "artifact_kind": "p06_candidate_metric_policy",
        "metric_policy_seed_sha256": record("metric_policy_seed")["sha256"],
        "metric_performance_tolerances_sha256": record(
            "metric_performance_tolerances"
        )["sha256"],
        "quality_gate_policy_seed_sha256": record("quality_gate_policy_seed")[
            "sha256"
        ],
    }
    if any(not _is_sha256(value) for value in document.values() if value != document["artifact_kind"]):
        raise NativeAdapterError("candidate metric policy binding is invalid")
    return document


def _locked_compiler_input_document_v2(
    *,
    physical: Mapping[str, object],
    configuration_id: str,
    mapping_sha256: str,
    operator_bank_sha256: str,
    metric_policy_sha256: str,
    calibration_plan_sha256: str,
    corpus_lock_bundle_sha256_value: str,
) -> Mapping[str, object]:
    """Materialize the exact schema-2 compiler-input template and self-hash."""

    denominator = physical["penalty_decay_denominator"]
    if type(denominator) is not int:
        raise NativeAdapterError("V2 penalty decay denominator is not integral")
    penalty_table = [
        ((65_535 * denominator) + ((denominator + index) // 2))
        // (denominator + index)
        for index in range(256)
    ]
    document: Dict[str, object] = {
        "schema_version": "2.0.0",
        "status": "locked",
        "configuration_id": configuration_id,
        "hash_bindings": {
            "mapping_sha256": mapping_sha256,
            "operator_bank_sha256": operator_bank_sha256,
            "metric_policy_sha256": metric_policy_sha256,
            "compiler_inputs_sha256": "0" * 64,
            "calibration_plan_sha256": calibration_plan_sha256,
            "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256_value,
        },
        "canonicalization": {
            "encoding": "UTF-8",
            "object_key_order": "ascending Unicode scalar value",
            "array_order": "preserved",
            "whitespace": "none",
            "string_escaping": (
                "JSON quotation, reverse-solidus, and control escapes; "
                "non-ASCII encoded directly as UTF-8"
            ),
            "number_domain": "integers only",
            "duplicate_keys": "reject",
            "trailing_newline_in_hash_input": False,
            "hash_algorithm": "SHA-256",
            "hash_scope": (
                "complete canonical document with only "
                "/hash_bindings/compiler_inputs_sha256 omitted"
            ),
        },
        "boundary_mode": physical["boundary_mode"],
        "operator_parameters": {
            "minimum_anisotropic_magnitude_unorm15": physical[
                "minimum_anisotropic_magnitude_unorm15"
            ],
            "minimum_anisotropic_coherence_unorm15": physical[
                "minimum_anisotropic_coherence_unorm15"
            ],
            "detail_gain_q12": physical["detail_gain_q12"],
            "relaxed_limiter_alpha_q12": physical["relaxed_limiter_alpha_q12"],
            "risk_detail_suppression_unorm15": physical[
                "risk_detail_suppression_unorm15"
            ],
            "low_pass_radius_q8_8": physical["low_pass_radius_q8_8"],
            "weight_epsilon_f32_bits": 730_643_660,
        },
        "semantic_steps": {
            "orientation_sector_step": 1,
            "support_radius_step_q8_8": physical["support_radius_step_q8_8"],
            "detail_gain_step_q12": physical["detail_gain_step_q12"],
            "regularization_step_q12": physical["regularization_step_q12"],
        },
        "compiler_policy": {
            "penalty_decay_denominator": denominator,
            "penalty_to_weight_unorm16": penalty_table,
            "penalty_orientation_step": physical["penalty_orientation_step"],
            "penalty_support_step": physical["penalty_support_step"],
            "penalty_detail_step": physical["penalty_detail_step"],
            "penalty_regularization_step": physical[
                "penalty_regularization_step"
            ],
            "penalty_unsupported_support_expansion": physical[
                "penalty_unsupported_support_expansion"
            ],
            "penalty_coherent_support_reduction": physical[
                "penalty_coherent_support_reduction"
            ],
            "penalty_unsupported_detail_increase": physical[
                "penalty_unsupported_detail_increase"
            ],
            "penalty_supported_detail_reduction": physical[
                "penalty_supported_detail_reduction"
            ],
            "penalty_relaxation_under_risk": physical[
                "penalty_relaxation_under_risk"
            ],
            "penalty_phase_kernel_mismatch": physical[
                "penalty_phase_kernel_mismatch"
            ],
            "confidence_threshold_unorm16": physical[
                "confidence_threshold_unorm16"
            ],
        },
        "routes": {
            "direct_2x": {
                "route_spatial_policy_id": physical[
                    "direct_2x_route_spatial_policy_id"
                ],
                "luma_anisotropy_mode_ordinal": physical[
                    "direct_2x_luma_anisotropy_mode_ordinal"
                ],
                "chroma_anisotropy_mode_ordinal": physical[
                    "direct_2x_chroma_anisotropy_mode_ordinal"
                ],
                "luma_coordinate_policy": physical[
                    "direct_2x_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": physical[
                    "direct_2x_chroma_coordinate_policy"
                ],
                "analysis_grid_source_step": physical[
                    "direct_2x_analysis_grid_source_step"
                ],
            },
            "direct_3_over_2": {
                "route_spatial_policy_id": physical[
                    "direct_3_over_2_route_spatial_policy_id"
                ],
                "luma_anisotropy_mode_ordinal": physical[
                    "direct_3_over_2_luma_anisotropy_mode_ordinal"
                ],
                "chroma_anisotropy_mode_ordinal": physical[
                    "direct_3_over_2_chroma_anisotropy_mode_ordinal"
                ],
                "luma_coordinate_policy": physical[
                    "direct_3_over_2_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": physical[
                    "direct_3_over_2_chroma_coordinate_policy"
                ],
                "analysis_grid_source_step": physical[
                    "direct_3_over_2_analysis_grid_source_step"
                ],
            },
        },
        "temporal": {
            "enabled": False,
            "context_count": 4,
            "context_aliases_to_spatial": [1, 2, 3],
            "semantic_state": (
                "clear payload coordinate 7 and recompute coordinate 9 parity"
            ),
            "affine_anchor": "original parity-valid source state",
        },
        "source_aligned": {
            "exact": True,
            "predicate": (
                "the current plane coordinate policy is source_aligned_rational "
                "and horizontal and vertical phase indices are zero"
            ),
            "primary_message": 0,
            "primary_descriptor": 0,
            "secondary": "inactive",
            "denoising": False,
        },
        "top_two": 2,
    }
    bindings = document["hash_bindings"]
    assert isinstance(bindings, dict)
    bindings["compiler_inputs_sha256"] = canonical_compiler_input_sha256_v2(
        document
    )
    validate_schema(
        document,
        SCHEMAS_ROOT / "locked-compiler-input-v2.schema.json",
    )
    parse_locked_compiler_input_v2(document)
    return document


def _write_new(path: Path, payload: bytes, *, executable: bool = False) -> None:
    _write_new_with_durability(
        path,
        payload,
        executable=executable,
        synchronize=True,
    )


def _write_new_deferred(path: Path, payload: bytes) -> None:
    _write_new_with_durability(
        path,
        payload,
        executable=False,
        synchronize=False,
    )


def _write_new_with_durability(
    path: Path,
    payload: bytes,
    *,
    executable: bool,
    synchronize: bool,
) -> None:
    absolute = _absolute_lexical_path(path)
    parent = _open_directory_descriptor(absolute.parent, create=True)
    temporary_prefix = f".{absolute.name}.mirmir-uncommitted-"
    cleaned = _cleanup_interrupted_publications_at(
        parent,
        temporary_prefix=temporary_prefix,
        display_parent=absolute.parent,
    )
    if synchronize and cleaned:
        os.fsync(parent)
    temporary_name = temporary_prefix + uuid.uuid4().hex
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(
            temporary_name,
            flags,
            0o700 if executable else 0o600,
            dir_fd=parent,
        )
    except Exception:
        os.close(parent)
        raise
    completed = False
    descriptor_open = True
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("publication made no progress")
            offset += written
        if synchronize:
            os.fsync(descriptor)
        os.close(descriptor)
        descriptor_open = False
        try:
            os.link(
                temporary_name,
                absolute.name,
                src_dir_fd=parent,
                dst_dir_fd=parent,
                follow_symlinks=False,
            )
        except FileExistsError:
            if _read_regular_at(
                parent,
                absolute.name,
                display_path=absolute,
            ) != payload:
                raise NativeAdapterError(f"cached immutable file differs: {absolute}")
        completed = True
    finally:
        if descriptor_open:
            os.close(descriptor)
        try:
            os.unlink(temporary_name, dir_fd=parent)
        except FileNotFoundError:
            pass
        if synchronize and completed:
            os.fsync(parent)
        os.close(parent)


def _cleanup_interrupted_publications_at(
    parent: int,
    *,
    temporary_prefix: str,
    display_parent: Path,
) -> bool:
    cleaned = False
    for name in os.listdir(parent):
        if not name.startswith(temporary_prefix):
            continue
        metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise NativeAdapterError(
                f"interrupted publication entry is not regular: {display_parent / name}"
            )
        os.unlink(name, dir_fd=parent)
        cleaned = True
    return cleaned


def _cleanup_interrupted_publications(path: Path) -> None:
    absolute = _absolute_lexical_path(path)
    parent = _open_directory_descriptor(absolute.parent, create=False)
    try:
        _cleanup_interrupted_publications_at(
            parent,
            temporary_prefix=f".{absolute.name}.mirmir-uncommitted-",
            display_parent=absolute.parent,
        )
    finally:
        os.close(parent)


def _write_or_verify(path: Path, payload: bytes) -> None:
    _ensure_directory(path.parent)
    _cleanup_interrupted_publications(path)
    if _path_entry_exists(path):
        if _read_regular(path) != payload:
            raise NativeAdapterError(f"cached immutable file differs: {path}")
        return
    _write_new(path, payload)


def _popen_with_execution_gate(
    command: Sequence[str],
    *,
    pass_fds: Sequence[int],
    execution_authorizer: Callable[[int], None] | None,
    **kwargs: object,
) -> subprocess.Popen[bytes] | AuthorizedProcess:
    retained = tuple(dict.fromkeys(int(value) for value in pass_fds))
    for descriptor in retained:
        if descriptor < 0:
            raise NativeAdapterError("retained subprocess descriptor is invalid")
        os.fstat(descriptor)
    if execution_authorizer is None:
        return subprocess.Popen(
            list(command),
            pass_fds=retained,
            **kwargs,
        )
    cwd = kwargs.pop("cwd", None)
    if not isinstance(cwd, Path):
        cwd = Path(cwd) if isinstance(cwd, (str, bytes)) else None
    if cwd is None:
        raise NativeAdapterError("authorized subprocess cwd is absent")
    environment = kwargs.pop("env", None)
    if not isinstance(environment, Mapping):
        raise NativeAdapterError("authorized subprocess environment is absent")
    environment = _validate_authorized_environment(environment)
    if kwargs != {
        "stdin": subprocess.PIPE,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
    } and kwargs != {
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
    }:
        raise NativeAdapterError("authorized subprocess pipe contract differs")
    return spawn_authorized_process(
        command,
        cwd=cwd,
        authorized_environment=environment,
        pass_fds=retained,
        execution_authorizer=execution_authorizer,
    )


def _run_checked(
    command: Sequence[str],
    *,
    cwd: Path,
    pass_fds: Sequence[int] = (),
    execution_authorizer: Callable[[int], None] | None = None,
    authorized_environment: Mapping[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    if execution_authorizer is None:
        environment = dict(os.environ)
        environment.update({"LC_ALL": "C", "LANG": "C"})
    elif authorized_environment is None:
        raise NativeAdapterError("authorized subprocess environment is required")
    else:
        environment = dict(authorized_environment)
    if execution_authorizer is None:
        process = _popen_with_execution_gate(
            command,
            cwd=cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=pass_fds,
            execution_authorizer=None,
        )
        stdout, stderr = process.communicate()
        result = subprocess.CompletedProcess(
            list(command),
            process.returncode,
            stdout,
            stderr,
        )
    else:
        assert authorized_environment is not None
        result = run_authorized_process(
            command,
            cwd=cwd,
            pass_fds=pass_fds,
            execution_authorizer=execution_authorizer,
            authorized_environment=authorized_environment,
            timeout_seconds=300.0,
        )
    if result.returncode != 0:
        raise NativeAdapterError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            + result.stderr.decode("utf-8", errors="replace")
        )
    return result


def _resolve_swift_toolchain(
    repository_root: Path,
) -> tuple[str, str, Mapping[str, object]]:
    swiftc_output = _run_checked(
        ("/usr/bin/xcrun", "--find", "swiftc"),
        cwd=repository_root,
    ).stdout.decode("utf-8").strip()
    if not swiftc_output:
        raise NativeAdapterError("xcrun returned an empty Swift compiler path")
    try:
        swiftc_path = Path(swiftc_output)
        swiftc_resolved_path = swiftc_path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise NativeAdapterError("xcrun returned an invalid Swift compiler path") from error
    developer_root = next(
        (
            parent
            for parent in swiftc_resolved_path.parents
            if parent.name == "Developer" and (parent / "Toolchains").is_dir()
        ),
        None,
    )
    if developer_root is None:
        raise NativeAdapterError("Swift compiler is not inside an Apple developer root")
    try:
        swiftc_path.relative_to(developer_root / "Toolchains")
        sdk_path = (
            developer_root
            / "Platforms"
            / "MacOSX.platform"
            / "Developer"
            / "SDKs"
            / "MacOSX.sdk"
        ).resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        raise NativeAdapterError(
            "Swift compiler developer root has no valid macOS SDK"
        ) from error
    if not sdk_path.is_dir():
        raise NativeAdapterError("Swift compiler macOS SDK path is not a directory")
    sdk_settings_path = sdk_path / "SDKSettings.json"
    sdk_settings = _read_regular(sdk_settings_path)
    try:
        sdk_settings_document = json.loads(sdk_settings)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NativeAdapterError("macOS SDK settings are not valid JSON") from error
    sdk_version = sdk_settings_document.get("Version")
    if not isinstance(sdk_version, str) or not sdk_version:
        raise NativeAdapterError("macOS SDK settings have no valid version")
    swiftc = str(swiftc_path)
    swift_version = _run_checked(
        (swiftc, "--version"), cwd=repository_root
    ).stdout.decode("utf-8").rstrip("\n")
    target_info = _run_checked(
        (swiftc, "-sdk", str(sdk_path), "-print-target-info"),
        cwd=repository_root,
    ).stdout.decode("utf-8").rstrip("\n")
    toolchain = {
        "swiftc_path": swiftc,
        "swiftc_resolved_path": str(swiftc_resolved_path),
        "swift_version": swift_version,
        "target_info": target_info,
        "developer_root": str(developer_root),
        "macos_sdk": {
            "path": str(sdk_path),
            "version": sdk_version,
            "settings_path": str(sdk_settings_path),
            "settings_sha256": _sha256(sdk_settings),
            "settings_size_bytes": len(sdk_settings),
        },
    }
    return swiftc, str(sdk_path), toolchain


@dataclass(frozen=True)
class NativeExecutable:
    path: Path
    sha256: str
    source_manifest_path: Path
    source_manifest_sha256: str
    compiled_now: bool


@dataclass(frozen=True)
class P00NativeExecutable:
    path: Path
    sha256: str
    source_manifest_path: Path
    source_manifest_sha256: str
    identity: Mapping[str, object]
    adapter_source_sha256: str
    compiled_now: bool


@dataclass(frozen=True)
class NativeConfiguration:
    root: Path
    compiler_input_path: Path
    mapping_path: Path
    operator_bank_path: Path
    runtime_manifest_path: Path
    route_paths: Mapping[str, Path]
    configuration: Mapping[str, object]


@dataclass(frozen=True)
class NativeCompiledConfigurationV2:
    """Format-1.2 compilation product and calibration runtime authority."""

    root: Path
    artifact_pair_root: Path
    compiler_input_path: Path
    mapping_path: Path
    operator_bank_path: Path
    runtime_manifest_path: Path
    route_paths: Mapping[str, Path]
    compile_summary: Mapping[str, object]
    configuration: Mapping[str, object]


class NativeSwiftBuilder:
    """Content-addressed executable and route-LUT build cache."""

    def __init__(self, repository_root: Path, cache_root: Path) -> None:
        self.repository_root = repository_root.resolve(strict=True)
        self.cache_root = cache_root
        _ensure_directory(cache_root)
        self.executable = self._ensure_executable()
        self.candidate_compile_invocation_count = 0

    def _ensure_executable(self) -> NativeExecutable:
        swiftc, sdk_path, toolchain = _resolve_swift_toolchain(self.repository_root)
        source_records = []
        source_paths = []
        for relative in _SWIFT_SOURCE_PATHS:
            path = self.repository_root.joinpath(*Path(relative).parts)
            payload = _read_regular(path)
            source_paths.append(path)
            source_records.append(
                {"path": relative, "sha256": _sha256(payload), "size_bytes": len(payload)}
            )
        manifest = {
            "schema_version": "1.0.0",
            "implementation_role": "production_swift",
            "toolchain": toolchain,
            "compile_flags": [*_COMPILE_FLAGS, "-sdk", sdk_path],
            "sources": source_records,
        }
        manifest_bytes = canonical_json_bytes(manifest)
        manifest_hash = _sha256(manifest_bytes)
        root = self.cache_root / "executables" / manifest_hash
        _ensure_directory(root)
        manifest_path = root / "source-manifest.json"
        _write_or_verify(manifest_path, manifest_bytes)
        executable_path = root / "ash-calibration-cli"
        compiled_now = False
        if not executable_path.exists():
            temporary = root / f".ash-calibration-cli.{os.getpid()}.{uuid.uuid4().hex}.tmp"
            command = [
                swiftc,
                *_COMPILE_FLAGS,
                "-sdk",
                sdk_path,
                *(str(path) for path in source_paths),
                "-o",
                str(temporary),
            ]
            try:
                _run_checked(command, cwd=self.repository_root)
                os.chmod(temporary, 0o700)
                try:
                    os.link(temporary, executable_path)
                    compiled_now = True
                except FileExistsError:
                    pass
            finally:
                temporary.unlink(missing_ok=True)
        executable_bytes = _read_regular(executable_path)
        if not os.access(executable_path, os.X_OK):
            raise NativeAdapterError("cached native CLI is not executable")
        return NativeExecutable(
            path=executable_path,
            sha256=_sha256(executable_bytes),
            source_manifest_path=manifest_path,
            source_manifest_sha256=manifest_hash,
            compiled_now=compiled_now,
        )

    def ensure_configuration(
        self,
        *,
        vector: Mapping[str, object],
        plan: Mapping[str, object],
        bound: object,
    ) -> NativeConfiguration:
        if _plan_schema_version(plan) != "1.0.0":
            raise NativeAdapterError(
                "schema-2 native session construction requires an authorized "
                "candidate runtime-manifest successor"
            )
        artifacts = candidate_artifact_documents(vector, plan, bound)  # type: ignore[arg-type]
        mapping_bytes = canonical_json_bytes(artifacts["mapping"])
        operator_bytes = canonical_json_bytes(artifacts["operator_bank"])
        metric_hash = canonical_sha256(artifacts["metric_policy"])
        mapping_hash = _sha256(mapping_bytes)
        operator_hash = _sha256(operator_bytes)
        configuration_id = str(artifacts["mapping"]["configuration_id"])
        compiler_document = locked_compiler_input_document(
            vector=vector,
            plan=plan,
            configuration_id=configuration_id,
            mapping_sha256=mapping_hash,
            operator_bank_sha256=operator_hash,
            metric_policy_sha256=metric_hash,
            calibration_plan_sha256=str(bound.record("calibration_plan")["sha256"]),  # type: ignore[attr-defined]
            corpus_lock_bundle_sha256=corpus_lock_bundle_sha256(bound),  # type: ignore[arg-type]
        )
        compiler_bytes = canonical_json_bytes(compiler_document)
        compiler_hash = str(compiler_document["hash_bindings"]["compiler_inputs_sha256"])  # type: ignore[index]
        root = self.cache_root / "configurations" / compiler_hash
        _ensure_directory(root)
        compiler_path = root / "locked-compiler-input.json"
        mapping_path = root / "candidate-mapping.json"
        operator_path = root / "candidate-operator-bank.json"
        _write_or_verify(compiler_path, compiler_bytes)
        _write_or_verify(mapping_path, mapping_bytes)
        _write_or_verify(operator_path, operator_bytes)

        summary_path = root / "native-compile-summary.json"
        route_paths = {
            route: root / filename for route, filename in _ROUTE_FILENAMES.items()
        }
        if summary_path.exists():
            compile_summary = _parse_json(_read_regular(summary_path), trailing_newline=False)
        else:
            command = (
                str(self.executable.path),
                "compile-candidate",
                "--compiler-input",
                str(compiler_path),
                "--mapping",
                str(mapping_path),
                "--operator-bank",
                str(operator_path),
                "--output-directory",
                str(root),
            )
            try:
                result = _run_checked(command, cwd=self.repository_root)
            except Exception as error:
                self._preserve_failure("compile-candidate", {"error": str(error), "command": list(command)})
                raise
            compile_summary = _parse_json(result.stdout, trailing_newline=True)
            _write_new(summary_path, canonical_json_bytes(compile_summary))
            self.candidate_compile_invocation_count += 1
        self._validate_compile_summary(
            compile_summary,
            configuration_id=configuration_id,
            compiler_hash=compiler_hash,
            mapping_hash=mapping_hash,
            operator_hash=operator_hash,
            route_paths=route_paths,
        )
        runtime_manifest = self._candidate_runtime_manifest(
            configuration_id=configuration_id,
            compiler_path=compiler_path,
            compiler_bytes=compiler_bytes,
            compiler_document=compiler_document,
            compile_summary=compile_summary,
        )
        validate_schema(
            runtime_manifest,
            SCHEMAS_ROOT / "candidate-lut-runtime-manifest-v1.schema.json",
        )
        runtime_manifest_path = root / "candidate-lut-runtime-manifest.json"
        manifest_bytes = canonical_json_bytes(runtime_manifest) + b"\n"
        _write_or_verify(runtime_manifest_path, manifest_bytes)

        vector_hash = candidate_vector_sha256(vector, plan)
        shared_bank_hash = shared_bank_configuration_sha256(vector, plan)
        raw_output_contract = {
            "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
            "chroma_conversion": "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once",
            "quantization": "common_420v_round_to_nearest_even",
            "output_reopen_verification": True,
        }
        raw_output_hash = canonical_sha256(raw_output_contract)
        full_control_hash = canonical_sha256(
            {
                "candidate_vector_sha256": vector_hash,
                "shared_bank_configuration_sha256": shared_bank_hash,
                "mapping_sha256": mapping_hash,
                "operator_bank_sha256": operator_hash,
                "metric_policy_sha256": metric_hash,
                "compiler_inputs_sha256": compiler_hash,
                "raw_output_contract_sha256": raw_output_hash,
            }
        )
        rows = compile_summary["routes"]
        assert isinstance(rows, list)
        rows_by_route = {
            "direct-2x" if row["route"] == "direct_2x" else "direct-3over2": row
            for row in rows
        }
        configuration = {
            "implementation_role": "production_swift",
            "configuration_id": configuration_id,
            "serialized_candidate_vector_sha256": vector_hash,
            "candidate_vector": dict(vector),
            "mapping_seed_sha256": bound.record("mapping_seed")["sha256"],  # type: ignore[attr-defined]
            "operator_bank_seed_sha256": bound.record("operator_bank_seed")["sha256"],  # type: ignore[attr-defined]
            "metric_policy_seed_sha256": bound.record("metric_policy_seed")["sha256"],  # type: ignore[attr-defined]
            "candidate_lut_runtime_manifest_sha256": runtime_manifest["manifest_sha256"],
            "mapping_sha256": mapping_hash,
            "operator_bank_sha256": operator_hash,
            "metric_policy_sha256": metric_hash,
            "compiler_inputs_sha256": compiler_hash,
            "compiler_contract_sha256": bound.record("compiler_contract")["sha256"],  # type: ignore[attr-defined]
            "calibration_plan_sha256": bound.record("calibration_plan")["sha256"],  # type: ignore[attr-defined]
            "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256(bound),  # type: ignore[arg-type]
            "shared_bank_configuration_sha256": shared_bank_hash,
            "raw_output_contract_sha256": raw_output_hash,
            "full_control_configuration_sha256": full_control_hash,
            "candidate_artifacts": artifacts,
            "compiler_input_document": compiler_document,
            "boundary_mode": vector["boundary_mode"],
            "route_luts": {
                route: {
                    "whole_file_sha256": rows_by_route[route]["whole_file_sha256"],
                    "payload_sha256": rows_by_route[route]["payload_sha256"],
                    "luma_coordinate_policy": rows_by_route[route][
                        "luma_coordinate_policy"
                    ],
                    "chroma_coordinate_policy": rows_by_route[route][
                        "chroma_coordinate_policy"
                    ],
                    "analysis_grid_source_step": rows_by_route[route][
                        "analysis_grid_source_step"
                    ],
                }
                for route in _ROUTE_FILENAMES
            },
            "swift_cli": {
                "executable_sha256": self.executable.sha256,
                "source_manifest_sha256": self.executable.source_manifest_sha256,
            },
        }
        return NativeConfiguration(
            root=root,
            compiler_input_path=compiler_path,
            mapping_path=mapping_path,
            operator_bank_path=operator_path,
            runtime_manifest_path=runtime_manifest_path,
            route_paths=route_paths,
            configuration=configuration,
        )

    def compile_candidate(
        self,
        *,
        vector: Mapping[str, object],
        plan: Mapping[str, object],
        bound: object,
    ) -> NativeConfiguration | NativeCompiledConfigurationV2:
        """Dispatch by plan schema before entering either artifact family."""

        schema_version = _plan_schema_version(plan)
        if schema_version == "1.0.0":
            return self.ensure_configuration(vector=vector, plan=plan, bound=bound)
        return self._compile_candidate_v2(vector=vector, plan=plan, bound=bound)

    def _compile_candidate_v2(
        self,
        *,
        vector: Mapping[str, object],
        plan: Mapping[str, object],
        bound: object,
    ) -> NativeCompiledConfigurationV2:
        """Materialize, atomically publish, and compile one exact schema-2 candidate."""

        if _plan_schema_version(plan) != "2.0.0":
            raise NativeAdapterError("schema-2 compiler received another plan family")
        materializer = SharedBankArtifactMaterializerV2(self.repository_root)
        record = getattr(bound, "record", None)
        if not callable(record):
            raise NativeAdapterError("bound input record lookup is absent")
        calibration_plan_record = record("calibration_plan")
        if (
            not isinstance(calibration_plan_record, Mapping)
            or calibration_plan_record.get("sha256")
            != materializer.plan.plan_file_sha256
        ):
            raise NativeAdapterError("bound V2 calibration plan differs from authority")
        physical = materialize_candidate_vector_v2(vector, materializer.plan)
        vector_hash = candidate_vector_sha256_v2(physical, materializer.plan)
        configuration_id = f"ash-p06-{vector_hash[:24]}"
        mapping_seed_sha256 = record("mapping_seed")["sha256"]
        operator_seed_sha256 = record("operator_bank_seed")["sha256"]
        if not _is_sha256(mapping_seed_sha256) or not _is_sha256(
            operator_seed_sha256
        ):
            raise NativeAdapterError("schema-2 shared-bank seed binding is invalid")
        pair = materializer.materialize(
            physical,
            configuration_id=configuration_id,
            mapping_seed_sha256=str(mapping_seed_sha256),
            operator_bank_seed_sha256=str(operator_seed_sha256),
        )
        if pair.candidate_vector_sha256 != vector_hash:
            raise NativeAdapterError("schema-2 materialized candidate identity differs")
        pair_parent = self.cache_root / "candidate-artifact-pairs-v2"
        _ensure_directory(pair_parent)
        pair_root = pair_parent / vector_hash
        published = materializer.publish_pair(pair_root, pair)
        if published != pair:
            raise NativeAdapterError("schema-2 published artifact pair differs")
        mapping_path = pair_root / "candidate-mapping.json"
        operator_path = pair_root / "candidate-operator-bank.json"
        if (
            _read_regular(mapping_path) != pair.mapping_bytes
            or _read_regular(operator_path) != pair.operator_bank_bytes
        ):
            raise NativeAdapterError("schema-2 published artifact bytes differ")

        metric_document = _candidate_metric_policy_document(bound)
        metric_hash = canonical_sha256(metric_document)
        corpus_hash = _corpus_lock_bundle_sha256_v2(
            bound=bound,
            plan=plan,
            repository_root=self.repository_root,
        )
        compiler_document = _locked_compiler_input_document_v2(
            physical=physical,
            configuration_id=configuration_id,
            mapping_sha256=pair.mapping_sha256,
            operator_bank_sha256=pair.operator_bank_sha256,
            metric_policy_sha256=metric_hash,
            calibration_plan_sha256=materializer.plan.plan_file_sha256,
            corpus_lock_bundle_sha256_value=corpus_hash,
        )
        compiler_bytes = canonical_json_bytes(compiler_document) + b"\n"
        compiler_file_hash = _sha256(compiler_bytes)
        compiler_hash = str(
            compiler_document["hash_bindings"]["compiler_inputs_sha256"]  # type: ignore[index]
        )
        root = self.cache_root / "configurations" / compiler_hash
        _ensure_directory(root)
        compiler_path = root / "locked-compiler-input-v2.json"
        _write_or_verify(compiler_path, compiler_bytes)
        summary_path = root / "native-compile-summary.json"
        route_paths = {
            route: root / filename for route, filename in _ROUTE_FILENAMES.items()
        }
        if summary_path.exists():
            compile_summary = _parse_json(
                _read_regular(summary_path),
                trailing_newline=False,
            )
        else:
            command = (
                str(self.executable.path),
                "compile-candidate",
                "--compiler-input",
                str(compiler_path),
                "--mapping",
                str(mapping_path),
                "--operator-bank",
                str(operator_path),
                "--output-directory",
                str(root),
            )
            try:
                result = _run_checked(command, cwd=self.repository_root)
            except Exception as error:
                self._preserve_failure(
                    "compile-candidate-v2",
                    {"error": str(error), "command": list(command)},
                )
                raise
            compile_summary = _parse_json(result.stdout, trailing_newline=True)
            _write_new(summary_path, canonical_json_bytes(compile_summary))
            self.candidate_compile_invocation_count += 1
        self._validate_compile_summary(
            compile_summary,
            configuration_id=configuration_id,
            compiler_hash=compiler_hash,
            mapping_hash=pair.mapping_sha256,
            operator_hash=pair.operator_bank_sha256,
            route_paths=route_paths,
            expected_schema_version="2.0.0",
            expected_compiler_input_v2=compiler_document,
        )
        runtime_manifest = self._candidate_runtime_manifest_v2(
            configuration_id=configuration_id,
            compiler_path=compiler_path,
            compiler_bytes=compiler_bytes,
            compiler_document=compiler_document,
            compile_summary=compile_summary,
        )
        validate_schema(
            runtime_manifest,
            SCHEMAS_ROOT / "candidate-lut-runtime-manifest-v2.schema.json",
        )
        runtime_manifest_path = root / "candidate-lut-runtime-manifest-v2.json"
        _write_or_verify(
            runtime_manifest_path,
            canonical_json_bytes(runtime_manifest) + b"\n",
        )
        rows = compile_summary["routes"]
        assert isinstance(rows, list)
        rows_by_route = {
            "direct-2x" if row["route"] == "direct_2x" else "direct-3over2": row
            for row in rows
        }
        raw_output_contract = {
            "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
            "chroma_conversion": (
                "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once"
            ),
            "quantization": "common_420v_round_to_nearest_even",
            "output_reopen_verification": True,
        }
        raw_output_hash = canonical_sha256(raw_output_contract)
        full_control_hash = canonical_sha256(
            {
                "candidate_vector_sha256": vector_hash,
                "shared_bank_configuration_sha256": (
                    pair.shared_bank_configuration_sha256
                ),
                "mapping_sha256": pair.mapping_sha256,
                "operator_bank_sha256": pair.operator_bank_sha256,
                "metric_policy_sha256": metric_hash,
                "compiler_inputs_sha256": compiler_hash,
                "raw_output_contract_sha256": raw_output_hash,
            }
        )
        configuration = {
            "schema_version": "2.0.0",
            "implementation_role": "production_swift_format_1_2",
            "runtime_status": "servable_calibration_candidate",
            "configuration_id": configuration_id,
            "serialized_candidate_vector_sha256": vector_hash,
            "physical_candidate_vector": dict(physical),
            "mapping_seed_sha256": mapping_seed_sha256,
            "operator_bank_seed_sha256": operator_seed_sha256,
            "metric_policy_seed_sha256": record("metric_policy_seed")["sha256"],
            "mapping_sha256": pair.mapping_sha256,
            "operator_bank_sha256": pair.operator_bank_sha256,
            "metric_policy_sha256": metric_hash,
            "compiler_inputs_sha256": compiler_hash,
            "compiler_input_file_sha256": compiler_file_hash,
            "candidate_lut_runtime_manifest_sha256": runtime_manifest[
                "manifest_sha256"
            ],
            "compiler_contract_sha256": record("compiler_contract")["sha256"],
            "calibration_plan_sha256": materializer.plan.plan_file_sha256,
            "corpus_lock_bundle_sha256": corpus_hash,
            "shared_bank_configuration_sha256": (
                pair.shared_bank_configuration_sha256
            ),
            "raw_output_contract_sha256": raw_output_hash,
            "full_control_configuration_sha256": full_control_hash,
            "candidate_artifacts": {
                "mapping": _parse_json(pair.mapping_bytes, trailing_newline=True),
                "operator_bank": _parse_json(
                    pair.operator_bank_bytes,
                    trailing_newline=True,
                ),
                "metric_policy": metric_document,
            },
            "compiler_input_document": compiler_document,
            "boundary_mode": physical["boundary_mode"],
            "route_luts": {
                route: {
                    "whole_file_sha256": rows_by_route[route][
                        "whole_file_sha256"
                    ],
                    "payload_sha256": rows_by_route[route]["payload_sha256"],
                    "luma_coordinate_policy": rows_by_route[route][
                        "luma_coordinate_policy"
                    ],
                    "chroma_coordinate_policy": rows_by_route[route][
                        "chroma_coordinate_policy"
                    ],
                    "analysis_grid_source_step": rows_by_route[route][
                        "analysis_grid_source_step"
                    ],
                }
                for route in _ROUTE_FILENAMES
            },
            "swift_cli": {
                "executable_sha256": self.executable.sha256,
                "source_manifest_sha256": self.executable.source_manifest_sha256,
            },
        }
        return NativeCompiledConfigurationV2(
            root=root,
            artifact_pair_root=pair_root,
            compiler_input_path=compiler_path,
            mapping_path=mapping_path,
            operator_bank_path=operator_path,
            runtime_manifest_path=runtime_manifest_path,
            route_paths=route_paths,
            compile_summary=compile_summary,
            configuration=configuration,
        )

    def _validate_compile_summary(
        self,
        summary: Mapping[str, object],
        *,
        configuration_id: str,
        compiler_hash: str,
        mapping_hash: str,
        operator_hash: str,
        route_paths: Mapping[str, Path],
        expected_schema_version: str = "1.0.0",
        expected_compiler_input_v2: Mapping[str, object] | None = None,
    ) -> None:
        required = {
            "schema_version", "status", "configuration_id", "compiler_inputs_sha256",
            "mapping_sha256", "operator_bank_sha256", "routes",
            "offline_compile_invocation_count", "runtime_load_count", "native_parity_claimed",
        }
        if set(summary) != required or (
            summary["schema_version"] != expected_schema_version
            or summary["status"] != "compiled"
            or summary["configuration_id"] != configuration_id
            or summary["compiler_inputs_sha256"] != compiler_hash
            or summary["mapping_sha256"] != mapping_hash
            or summary["operator_bank_sha256"] != operator_hash
            or summary["offline_compile_invocation_count"] != 1
            or summary["runtime_load_count"] != 0
            or summary["native_parity_claimed"] is not False
        ):
            raise NativeAdapterError("native compile summary identity mismatch")
        rows = summary["routes"]
        if not isinstance(rows, list) or [row.get("route") for row in rows] != [
            "direct_2x",
            "direct_3_over_2",
        ]:
            raise NativeAdapterError("native compile route order mismatch")
        expected_row_fields = {
            "route", "route_id", "scale_numerator", "scale_denominator",
            "phase_count", "context_count", "valid_state_count",
            "luma_coordinate_policy", "chroma_coordinate_policy",
            "analysis_grid_source_step", "entry_count", "parameter_count",
            "path", "whole_file_size_bytes", "whole_file_sha256",
            "payload_sha256", "header_crc32", "payload_crc32",
        }
        if expected_schema_version == "2.0.0":
            expected_row_fields.add("plane_count")
            if expected_compiler_input_v2 is None:
                raise NativeAdapterError("schema-2 compiler validation input is absent")
            parsed_v2 = parse_locked_compiler_input_v2(expected_compiler_input_v2)
        elif expected_compiler_input_v2 is not None:
            raise NativeAdapterError("cross-version compiler validation is forbidden")
        else:
            parsed_v2 = None
        for route, row in zip(_ROUTE_FILENAMES, rows):
            if not isinstance(row, Mapping) or set(row) != expected_row_fields:
                raise NativeAdapterError(f"native compile route fields differ: {route}")
            payload = _read_regular(route_paths[route])
            if (
                row.get("whole_file_size_bytes") != len(payload)
                or row.get("whole_file_sha256") != _sha256(payload)
            ):
                raise NativeAdapterError(f"cached native LUT differs: {route}")
            if parsed_v2 is not None:
                oracle_name = (
                    "direct_2x" if route == "direct-2x" else "direct_3_over_2"
                )
                try:
                    validated = validate_lut_v2(
                        payload,
                        expected_configuration=parsed_v2,
                        expected_route=oracle_name,
                    )
                except Exception as error:
                    raise NativeAdapterError(
                        f"schema-2 independent binary validation failed: {route}"
                    ) from error
                oracle_route = validated.route
                selection = parsed_v2.routes[oracle_name]
                expected_row = {
                    "route": oracle_name,
                    "route_id": oracle_route.route_id,
                    "scale_numerator": oracle_route.scale_numerator,
                    "scale_denominator": oracle_route.scale_denominator,
                    "phase_count": oracle_route.phase_count,
                    "context_count": 4,
                    "valid_state_count": 256,
                    "plane_count": 2,
                    "luma_coordinate_policy": validated.luma_coordinate_policy,
                    "chroma_coordinate_policy": validated.chroma_coordinate_policy,
                    "analysis_grid_source_step": selection.analysis_grid_source_step,
                    "entry_count": validated.entry_count,
                    "parameter_count": validated.parameter_count,
                    "path": _ROUTE_FILENAMES[route],
                    "whole_file_size_bytes": len(payload),
                    "whole_file_sha256": validated.whole_file_sha256,
                    "payload_sha256": validated.payload_sha256,
                    "header_crc32": f"0x{validated.header_crc32:08X}",
                    "payload_crc32": f"0x{validated.payload_crc32:08X}",
                }
                if dict(row) != expected_row:
                    raise NativeAdapterError(
                        f"schema-2 native compile summary differs: {route}"
                    )

    def _candidate_runtime_manifest(
        self,
        *,
        configuration_id: str,
        compiler_path: Path,
        compiler_bytes: bytes,
        compiler_document: Mapping[str, object],
        compile_summary: Mapping[str, object],
    ) -> Mapping[str, object]:
        document: Dict[str, object] = {
            "schema_version": "1.0.0",
            "manifest_id": "mirmir-ash-candidate-route-luts-v1",
            "status": "calibration_candidate",
            "configuration_id": configuration_id,
            "compiler_input": {
                "path": compiler_path.name,
                "sha256": _sha256(compiler_bytes),
                "size_bytes": len(compiler_bytes),
            },
            "hash_bindings": dict(compiler_document["hash_bindings"]),  # type: ignore[arg-type]
            "routes": compile_summary["routes"],
            "swift_cli": {
                "executable_sha256": self.executable.sha256,
                "source_manifest_sha256": self.executable.source_manifest_sha256,
            },
            "native_parity_claimed": False,
        }
        document["manifest_sha256"] = canonical_sha256(document)
        return document

    def _candidate_runtime_manifest_v2(
        self,
        *,
        configuration_id: str,
        compiler_path: Path,
        compiler_bytes: bytes,
        compiler_document: Mapping[str, object],
        compile_summary: Mapping[str, object],
    ) -> Mapping[str, object]:
        document: Dict[str, object] = {
            "schema_version": "2.0.0",
            "manifest_id": "mirmir-ash-candidate-route-luts-v2",
            "status": "calibration_candidate",
            "configuration_id": configuration_id,
            "compiler_input": {
                "path": compiler_path.name,
                "sha256": _sha256(compiler_bytes),
                "size_bytes": len(compiler_bytes),
            },
            "hash_bindings": dict(compiler_document["hash_bindings"]),
            "routes": compile_summary["routes"],
            "swift_cli": {
                "executable_sha256": self.executable.sha256,
                "source_manifest_sha256": self.executable.source_manifest_sha256,
            },
            "native_parity_claimed": False,
        }
        document["manifest_sha256"] = canonical_sha256(document)
        return document

    def _preserve_failure(self, kind: str, document: Mapping[str, object]) -> Path:
        root = self.cache_root / "failures"
        _ensure_directory(root)
        path = root / f"{kind}-{uuid.uuid4().hex}.json"
        _write_new(path, canonical_json_bytes(document) + b"\n")
        return path


class P00NativeBuilder:
    """Extract and compile the immutable P00 backend from its pinned commit."""

    def __init__(self, repository_root: Path, cache_root: Path) -> None:
        self.repository_root = repository_root
        self.cache_root = cache_root
        self.executable = self._ensure_executable()

    def _ensure_executable(self) -> P00NativeExecutable:
        object_type = _run_checked(
            ("git", "cat-file", "-t", _P00_COMMIT),
            cwd=self.repository_root,
        ).stdout.decode("utf-8").strip()
        if object_type != "commit":
            raise NativeAdapterError("P00 pinned object is not a commit")
        tree = _run_checked(
            ("git", "rev-parse", f"{_P00_COMMIT}^{{tree}}"),
            cwd=self.repository_root,
        ).stdout.decode("utf-8").strip()
        swiftc, sdk_path, toolchain = _resolve_swift_toolchain(self.repository_root)
        extracted: list[tuple[str, bytes]] = []
        source_records = []
        for relative in _P00_SOURCE_PATHS:
            specification = f"{_P00_COMMIT}:{relative}"
            payload = _run_checked(
                ("git", "show", specification), cwd=self.repository_root
            ).stdout
            blob = _run_checked(
                ("git", "rev-parse", specification), cwd=self.repository_root
            ).stdout.decode("utf-8").strip()
            extracted.append((relative, payload))
            source_records.append(
                {
                    "path": relative,
                    "git_blob_sha1": blob,
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
        backend_record = next(
            record
            for record in source_records
            if record["path"].endswith("ASHDeterministicUpscaleBackend.swift")
        )
        if backend_record["sha256"] != _P00_BACKEND_SOURCE_SHA256:
            raise NativeAdapterError("P00 backend source SHA-256 differs from pin")
        adapter_path = self.repository_root / _P00_ADAPTER_PATH
        adapter_payload = _read_regular(adapter_path)
        compile_flags = list(_COMPILE_FLAGS)
        manifest = {
            "schema_version": "1.0.0",
            "implementation_role": "p00_commit_pinned_baseline",
            "commit": _P00_COMMIT,
            "commit_tree_sha1": tree,
            "backend_source_sha256": _P00_BACKEND_SOURCE_SHA256,
            "toolchain": toolchain,
            "compile_flags": [*compile_flags, "-sdk", sdk_path],
            "commit_sources": source_records,
            "adapter_source": {
                "path": _P00_ADAPTER_PATH,
                "sha256": _sha256(adapter_payload),
                "size_bytes": len(adapter_payload),
            },
        }
        manifest_bytes = canonical_json_bytes(manifest)
        manifest_hash = _sha256(manifest_bytes)
        root = self.cache_root / "p00" / manifest_hash
        source_root = root / "sources"
        _ensure_directory(source_root)
        manifest_path = root / "source-manifest.json"
        _write_or_verify(manifest_path, manifest_bytes)
        source_paths = []
        for relative, payload in extracted:
            path = source_root.joinpath(*Path(relative).parts)
            _write_or_verify(path, payload)
            source_paths.append(path)
        extracted_adapter = source_root.joinpath(*Path(_P00_ADAPTER_PATH).parts)
        _write_or_verify(extracted_adapter, adapter_payload)
        source_paths.append(extracted_adapter)
        executable_path = root / "ash-p00-control-cli"
        compiled_now = False
        if not executable_path.exists():
            temporary = root / f".ash-p00-control-cli.{os.getpid()}.{uuid.uuid4().hex}.tmp"
            command = [
                swiftc,
                *compile_flags,
                "-sdk",
                sdk_path,
                *(str(path) for path in source_paths),
                "-o",
                str(temporary),
            ]
            try:
                _run_checked(command, cwd=self.repository_root)
                os.chmod(temporary, 0o700)
                try:
                    os.link(temporary, executable_path)
                except FileExistsError:
                    pass
            finally:
                temporary.unlink(missing_ok=True)
            compiled_now = True
        executable_payload = _read_regular(executable_path)
        configuration = {
            "tile_size": 32,
            "top_k": 1,
            "luma_input_normalization": "raw_byte_divided_by_255",
            "luma_output_quantization": "rounded_times_255",
            "chroma_reconstruction": "nearest",
            "direct_3_over_2_postprocess": (
                "baseline_MPSImageLanczosScale_after_exact_2x"
            ),
        }
        identity: dict[str, object] = {
            "commit": _P00_COMMIT,
            "backend_source_sha256": _P00_BACKEND_SOURCE_SHA256,
            "source_manifest_sha256": manifest_hash,
            "executable_sha256": _sha256(executable_payload),
            "configuration_sha256": canonical_sha256(configuration),
            "compatibility_boundary_normalization": json.loads(
                canonical_json_bytes(_P00_COMPATIBILITY_BOUNDARY)
            ),
            **configuration,
        }
        return P00NativeExecutable(
            path=executable_path,
            sha256=str(identity["executable_sha256"]),
            source_manifest_path=manifest_path,
            source_manifest_sha256=manifest_hash,
            identity=identity,
            adapter_source_sha256=_sha256(adapter_payload),
            compiled_now=compiled_now,
        )


class P00NativeHelper:
    def __init__(
        self,
        executable: P00NativeExecutable,
        invocation_root: Path,
        *,
        pass_fds: Sequence[int] = (),
        execution_authorizer: Callable[[int], None] | None = None,
        authorized_environment: Mapping[str, str] | None = None,
    ) -> None:
        self.executable = executable
        self.invocation_root = invocation_root
        self.pass_fds = tuple(pass_fds)
        self.execution_authorizer = execution_authorizer
        self.authorized_environment = authorized_environment
        _ensure_directory(invocation_root)

    def reconstruct(
        self,
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> tuple[PlanarFrame, Mapping[str, object]]:
        payload = _planar_to_video_range_nv12(frame)
        if self.execution_authorizer is None:
            with tempfile.TemporaryDirectory(dir=self.invocation_root) as temporary:
                root = Path(temporary)
                input_path = root / "input.nv12"
                output_path = root / "output.nv12"
                _write_new(input_path, payload)
                command = self._command(
                    input_path=input_path,
                    output_path=output_path,
                    payload=payload,
                    frame=frame,
                    context=context,
                )
                result = _run_checked(command, cwd=REPOSITORY_ROOT)
                output_payload = _read_regular(output_path)
        else:
            result, output_payload = self._secure_invoke(
                payload=payload,
                frame=frame,
                context=context,
            )
        return self._validated_output(
            result=result,
            output_payload=output_payload,
            payload=payload,
            context=context,
        )

    def _command(
        self,
        *,
        input_path: Path,
        output_path: Path,
        payload: bytes,
        frame: PlanarFrame,
        context: CandidateContext,
        input_descriptor: int | None = None,
        output_descriptor: int | None = None,
    ) -> tuple[str, ...]:
        command = [
            str(self.executable.path),
            "process",
            "--input",
            str(input_path),
            "--output",
            str(output_path),
            "--input-sha256",
            _sha256(payload),
            "--width",
            str(frame.y.shape[1]),
            "--height",
            str(frame.y.shape[0]),
            "--route",
            context.target_route,
        ]
        if input_descriptor is not None and output_descriptor is not None:
            command.extend(
                (
                    "--input-fd",
                    str(input_descriptor),
                    "--output-fd",
                    str(output_descriptor),
                )
            )
        return tuple(command)

    @staticmethod
    def _descriptor_bytes(descriptor: int) -> bytes:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise NativeAdapterError("P00 retained descriptor is invalid")
        os.lseek(descriptor, 0, os.SEEK_SET)
        chunks = []
        while True:
            try:
                chunk = os.read(descriptor, 1024 * 1024)
            except InterruptedError:
                continue
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        if (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise NativeAdapterError("P00 retained descriptor changed")
        return b"".join(chunks)

    def _secure_invoke(
        self,
        *,
        payload: bytes,
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> tuple[subprocess.CompletedProcess[bytes], bytes]:
        if self.authorized_environment is None:
            raise NativeAdapterError("P00 authorized environment is absent")
        root_descriptor = _open_directory_descriptor(
            self.invocation_root,
            create=False,
        )
        case_name = ".p00-invocation-{}".format(uuid.uuid4().hex)
        case_descriptor = input_descriptor = output_descriptor = -1
        primary_error: BaseException | None = None
        try:
            os.mkdir(case_name, 0o700, dir_fd=root_descriptor)
            case_descriptor = os.open(
                case_name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=root_descriptor,
            )
            input_descriptor = os.open(
                "input.nv12",
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=case_descriptor,
            )
            output_descriptor = os.open(
                "output.nv12",
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=case_descriptor,
            )
            offset = 0
            while offset < len(payload):
                try:
                    written = os.write(input_descriptor, payload[offset:])
                except InterruptedError:
                    continue
                if written <= 0:
                    raise NativeAdapterError("P00 input write made no progress")
                offset += written
            os.fsync(input_descriptor)
            if self._descriptor_bytes(input_descriptor) != payload:
                raise NativeAdapterError("P00 retained input persistence differs")
            case_path = self.invocation_root / case_name
            input_path = case_path / "input.nv12"
            output_path = case_path / "output.nv12"
            command = self._command(
                input_path=input_path,
                output_path=output_path,
                payload=payload,
                frame=frame,
                context=context,
                input_descriptor=input_descriptor,
                output_descriptor=output_descriptor,
            )
            pass_fds = tuple(
                dict.fromkeys(
                    self.pass_fds
                    + (input_descriptor, output_descriptor)
                )
            )
            result = run_authorized_process(
                command,
                cwd_descriptor=case_descriptor,
                pass_fds=pass_fds,
                execution_authorizer=self.execution_authorizer,
                authorized_environment=self.authorized_environment,
                timeout_seconds=120.0,
            )
            if result.returncode != 0:
                raise NativeAdapterError(
                    "P00 helper failed with status {}: {}".format(
                        result.returncode,
                        result.stderr.decode("utf-8", "replace").strip(),
                    )
                )
            if self._descriptor_bytes(input_descriptor) != payload:
                raise NativeAdapterError("P00 retained input changed during execution")
            output_payload = self._descriptor_bytes(output_descriptor)
            for descriptor, path in (
                (input_descriptor, input_path),
                (output_descriptor, output_path),
            ):
                opened = os.fstat(descriptor)
                linked = os.stat(path, follow_symlinks=False)
                if (opened.st_dev, opened.st_ino) != (
                    linked.st_dev,
                    linked.st_ino,
                ):
                    raise NativeAdapterError("P00 retained output path differs")
            return result, output_payload
        except BaseException as error:
            primary_error = error
            raise
        finally:
            cleanup_error: BaseException | None = None
            for descriptor in (input_descriptor, output_descriptor):
                if descriptor >= 0:
                    try:
                        os.close(descriptor)
                    except BaseException as error:
                        cleanup_error = cleanup_error or error
            if case_descriptor >= 0:
                for name in ("input.nv12", "output.nv12"):
                    try:
                        os.unlink(name, dir_fd=case_descriptor)
                    except FileNotFoundError:
                        pass
                    except BaseException as error:
                        cleanup_error = cleanup_error or error
                try:
                    os.close(case_descriptor)
                except BaseException as error:
                    cleanup_error = cleanup_error or error
            try:
                os.rmdir(case_name, dir_fd=root_descriptor)
            except FileNotFoundError:
                pass
            except BaseException as error:
                cleanup_error = cleanup_error or error
            try:
                os.close(root_descriptor)
            except BaseException as error:
                cleanup_error = cleanup_error or error
            if cleanup_error is not None:
                if primary_error is not None:
                    combined = NativeAdapterError(
                        "P00 invocation and cleanup both failed"
                    )
                    combined.primary_error = primary_error  # type: ignore[attr-defined]
                    combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
                    raise combined from primary_error
                raise cleanup_error

    @staticmethod
    def _validated_output(
        *,
        result: subprocess.CompletedProcess[bytes],
        output_payload: bytes,
        payload: bytes,
        context: CandidateContext,
    ) -> tuple[PlanarFrame, Mapping[str, object]]:
        summary = _parse_json(result.stdout, trailing_newline=True)
        required = {
            "schema_version", "status", "route", "input_nv12_sha256",
            "output_nv12_sha256", "input_width", "input_height",
            "output_width", "output_height", "pixel_format",
            "active_plane_stride_copy", "metal_iosurface_compatible_buffers",
            "tile_size", "top_k", "p00_backend_reset_before_frame",
            "p00_prior_frame_count", "direct_3_over_2_postprocess",
            "p00_lanczos_synchronization", "process_id",
        }
        expected_postprocess = (
            "baseline_MPSImageLanczosScale_after_exact_2x"
            if context.target_route == "direct-3over2"
            else "not_applicable_exact_2x"
        )
        expected_synchronization = (
            "hash_bound_adapter_commit_then_wait_until_completed"
            if context.target_route == "direct-3over2"
            else "not_applicable"
        )
        if set(summary) != required or (
            summary["schema_version"] != "1.0.0"
            or summary["status"] != "ok"
            or summary["route"] != context.target_route
            or summary["input_nv12_sha256"] != _sha256(payload)
            or summary["output_nv12_sha256"] != _sha256(output_payload)
            or summary["output_width"] != context.y_shape[1]
            or summary["output_height"] != context.y_shape[0]
            or summary["pixel_format"] != "420v"
            or summary["active_plane_stride_copy"] is not True
            or summary["metal_iosurface_compatible_buffers"] is not True
            or summary["tile_size"] != 32
            or summary["top_k"] != 1
            or summary["p00_backend_reset_before_frame"] is not True
            or summary["p00_prior_frame_count"] != 0
            or summary["direct_3_over_2_postprocess"] != expected_postprocess
            or summary["p00_lanczos_synchronization"] != expected_synchronization
            or not isinstance(summary["process_id"], int)
            or summary["process_id"] <= 0
        ):
            raise NativeAdapterError("P00 helper output identity mismatch")
        normalized_payload, normalization = _normalize_p00_compatibility_output(
            output_payload,
            width=context.y_shape[1],
            height=context.y_shape[0],
            route=context.target_route,
        )
        output = _video_range_nv12_to_planar(
            normalized_payload,
            width=context.y_shape[1],
            height=context.y_shape[0],
        )
        enriched_summary = dict(summary)
        enriched_summary["p00_compatibility_boundary_normalization"] = normalization
        return output, enriched_summary


class NativeSwiftSession:
    def __init__(
        self,
        executable: NativeExecutable,
        configuration: NativeConfiguration | NativeCompiledConfigurationV2,
        *,
        timeout_seconds: float,
        pass_fds: Sequence[int] = (),
        execution_authorizer: Callable[[int], None] | None = None,
        authorized_environment: Mapping[str, str] | None = None,
    ) -> None:
        self.executable = executable
        self.configuration = configuration
        self.timeout_seconds = timeout_seconds
        self._lock = threading.Lock()
        self._corrective_output_bindings: dict[str, object] = {}
        self._poisoned = False
        command = (
            str(executable.path),
            "serve-candidate",
            "--compiler-input",
            str(configuration.compiler_input_path),
            "--mapping",
            str(configuration.mapping_path),
            "--operator-bank",
            str(configuration.operator_bank_path),
            "--runtime-manifest",
            str(configuration.runtime_manifest_path),
            "--direct2x-lut",
            str(configuration.route_paths["direct-2x"]),
            "--direct3over2-lut",
            str(configuration.route_paths["direct-3over2"]),
            "--source-manifest",
            str(executable.source_manifest_path),
        )
        self.process = _popen_with_execution_gate(
            command,
            cwd=REPOSITORY_ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=authorized_environment,
            pass_fds=pass_fds,
            execution_authorizer=execution_authorizer,
        )
        try:
            ready = self._readline(60.0)
            document = _parse_json(ready, trailing_newline=True)
            expected_keys = {
                "schema_version", "status", "configuration_id",
                "candidate_lut_runtime_manifest_sha256",
                "session_loaded_lut_instance_count", "per_frame_lut_load_count",
                "native_parity_claimed",
            }
            config = configuration.configuration
            if set(document) != expected_keys or (
                document["schema_version"]
                != config.get("schema_version", "1.0.0")
                or document["status"] != "ready"
                or document["configuration_id"] != config["configuration_id"]
                or document["candidate_lut_runtime_manifest_sha256"]
                != config["candidate_lut_runtime_manifest_sha256"]
                or document["session_loaded_lut_instance_count"] != 2
                or document["per_frame_lut_load_count"] != 0
                or document["native_parity_claimed"] is not False
            ):
                raise NativeAdapterError("native session ready identity mismatch")
            if execution_authorizer is not None:
                execution_authorizer(self.process.pid)
        except Exception:
            self.close()
            raise

    def request(self, document: Mapping[str, object]) -> Mapping[str, object]:
        response = self._send(document)
        required = {"schema_version", "status", "request_sha256", "frames"}
        if set(response) != required:
            raise NativeAdapterError("native batch response field set mismatch")
        return response

    def measure(self, document: Mapping[str, object]) -> Mapping[str, object]:
        response = self._send(document)
        required = {"schema_version", "status", "request_sha256", "measurement"}
        if set(response) != required or not isinstance(response["measurement"], dict):
            raise NativeAdapterError("native measurement response field set mismatch")
        return response

    def control(self, document: Mapping[str, object]) -> Mapping[str, object]:
        response = self._send(document)
        required = {"schema_version", "status", "request_sha256", "control"}
        if set(response) != required or not isinstance(response["control"], dict):
            raise NativeAdapterError("native control response field set mismatch")
        return response

    def prepare_non_ash_cache(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        response = self._send(document)
        required = {"schema_version", "status", "request_sha256", "cache"}
        if set(response) != required or not isinstance(response["cache"], dict):
            raise NativeAdapterError("native non-ASH cache response field set mismatch")
        return response

    def reconstruct_non_ash_cached(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        response = self._send(document)
        required = {
            "schema_version", "status", "request_sha256", "cached_reconstruction"
        }
        if (
            set(response) != required
            or not isinstance(response["cached_reconstruction"], dict)
        ):
            raise NativeAdapterError(
                "native cached non-ASH response field set mismatch"
            )
        return response

    def reconstruct_fixed_cached(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        response = self._send(document)
        required = {
            "schema_version", "status", "request_sha256", "cached_reconstruction"
        }
        if (
            set(response) != required
            or not isinstance(response["cached_reconstruction"], dict)
        ):
            raise NativeAdapterError(
                "native cached fixed response field set mismatch"
            )
        return response

    def diagnose_corrective_frame(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        """Run and fully reopen-validate one development corrective frame."""

        from validation.calibration_v2.corrective_native import (
            CorrectiveNativeContractError,
            capture_corrective_native_outputs,
            close_corrective_native_binding,
            cleanup_corrective_native_outputs,
            validate_corrective_native_request,
            validate_corrective_native_response,
        )

        if self._poisoned:
            raise NativeAdapterError(
                "native session is poisoned after a corrective transport failure"
            )
        binding = None
        request_sent = False
        binding_key = _sha256(canonical_json_bytes(document))
        if binding_key in self._corrective_output_bindings:
            raise NativeAdapterError(
                "native corrective request has an unreleased output transaction"
            )
        try:
            binding = validate_corrective_native_request(
                document,
                configuration=self.configuration.configuration,
                require_outputs_absent=True,
            )
            request_sent = True
            response = self._send(document)
            capture_corrective_native_outputs(binding, require_all=True)
            validated = validate_corrective_native_response(
                response,
                binding=binding,
                configuration=self.configuration.configuration,
                native_executable_sha256=self.executable.sha256,
                native_source_manifest_sha256=(
                    self.executable.source_manifest_sha256
                ),
                native_process_id=self.process.pid,
            )
            self._corrective_output_bindings[binding_key] = binding
            binding = None
            return validated
        except BaseException as primary_error:
            termination_error = None
            if request_sent and not self._poisoned:
                try:
                    self._poison_corrective_transport()
                except BaseException as error:
                    termination_error = error
            if binding is not None:
                capture_error = None
                try:
                    capture_corrective_native_outputs(
                        binding,
                        require_all=False,
                    )
                except BaseException as error:
                    capture_error = error
                cleanup_error = None
                try:
                    cleanup_corrective_native_outputs(binding)
                except BaseException as error:
                    cleanup_error = error
                finally:
                    close_corrective_native_binding(binding)
                if (
                    termination_error is not None
                    or capture_error is not None
                    or cleanup_error is not None
                ):
                    combined = NativeAdapterError(
                        "native corrective request, termination, or output recovery failed"
                    )
                    combined.primary_error = primary_error  # type: ignore[attr-defined]
                    combined.termination_error = termination_error  # type: ignore[attr-defined]
                    combined.capture_error = capture_error  # type: ignore[attr-defined]
                    combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
                    raise combined from primary_error
            elif termination_error is not None:
                combined = NativeAdapterError(
                    "native corrective request and process termination both failed"
                )
                combined.primary_error = primary_error  # type: ignore[attr-defined]
                combined.termination_error = termination_error  # type: ignore[attr-defined]
                raise combined from primary_error
            if isinstance(primary_error, CorrectiveNativeContractError):
                raise NativeAdapterError(str(primary_error)) from primary_error
            raise

    def reopen_corrective_frame_output(
        self,
        document: Mapping[str, object],
        path: Path,
        *,
        width: int,
        height: int,
    ) -> PlanarFrame:
        """Read one output through its retained transaction descriptor."""

        from validation.calibration_v2.corrective_native import (
            reopen_corrective_output_frame,
        )

        key = _sha256(canonical_json_bytes(document))
        binding = self._corrective_output_bindings.get(key)
        if binding is None:
            raise NativeAdapterError(
                "native corrective output transaction is not active"
            )
        return reopen_corrective_output_frame(
            binding,
            path,
            width=width,
            height=height,
        )

    def release_corrective_frame_outputs(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        """Sanitize captured outputs, retain stubs, and close the pinned directory."""

        from validation.calibration_v2.corrective_native import (
            close_corrective_native_binding,
            cleanup_corrective_native_outputs,
        )

        key = _sha256(canonical_json_bytes(document))
        binding = self._corrective_output_bindings.pop(key, None)
        if binding is None:
            raise NativeAdapterError(
                "native corrective output transaction is not active"
            )
        try:
            return cleanup_corrective_native_outputs(binding)
        finally:
            close_corrective_native_binding(binding)

    def _send(self, document: Mapping[str, object]) -> Mapping[str, object]:
        payload = canonical_json_bytes(document)
        with self._lock:
            if self._poisoned:
                raise NativeAdapterError(
                    "native session is poisoned after a corrective transport failure"
                )
            if self.process.poll() is not None:
                raise NativeAdapterError("native session terminated before request")
            assert self.process.stdin is not None
            self.process.stdin.write(payload + b"\n")
            self.process.stdin.flush()
            response = _parse_json(
                self._readline(self.timeout_seconds),
                trailing_newline=True,
            )
        required = {"schema_version", "status", "request_sha256"}
        if not required.issubset(response) or response["request_sha256"] != _sha256(payload):
            raise NativeAdapterError("native response request binding mismatch")
        if response["status"] != "ok":
            raise NativeAdapterError(
                f"native request rejected: {response.get('error_type')}: {response.get('message')}"
            )
        return response

    def _poison_corrective_transport(self) -> None:
        """Make a failed corrective request impossible to reuse or desynchronize."""

        self._poisoned = True
        if self.process.poll() is None:
            self.process.kill()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

    def close(self) -> None:
        recovery_errors = []
        if self._corrective_output_bindings:
            from validation.calibration_v2.corrective_native import (
                close_corrective_native_binding,
                cleanup_corrective_native_outputs,
            )

            bindings = tuple(self._corrective_output_bindings.values())
            self._corrective_output_bindings.clear()
            for binding in bindings:
                try:
                    cleanup_corrective_native_outputs(binding)
                except BaseException as error:
                    recovery_errors.append(error)
                finally:
                    close_corrective_native_binding(binding)
        if self.process.poll() is None:
            if self.process.stdin is not None and not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()
        if recovery_errors:
            error = NativeAdapterError(
                "native corrective output recovery failed while closing session"
            )
            error.cleanup_errors = tuple(recovery_errors)  # type: ignore[attr-defined]
            raise error from recovery_errors[0]

    def _readline(self, timeout: float) -> bytes:
        assert self.process.stdout is not None
        selector = selectors.DefaultSelector()
        try:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout):
                raise NativeAdapterError("native session response timed out")
            line = self.process.stdout.readline()
        finally:
            selector.close()
        if not line:
            stderr = b""
            if self.process.stderr is not None:
                stderr = self.process.stderr.read()
            raise NativeAdapterError(
                "native session closed unexpectedly: "
                + stderr.decode("utf-8", errors="replace")
            )
        return line


@dataclass(frozen=True)
class _NonASHCachedReconstructionBindings:
    cache_token: str
    cache_origin_manifest_sha256: str
    manifest: Mapping[str, object]
    rule_configuration: Mapping[str, object]
    rule_sha256: str
    output_width: int
    output_height: int
    control_request: Mapping[str, object]
    control_identity: Mapping[str, object]


class NativeCorrectiveDiagnosticCapability:
    """Owned native session for open-development corrective diagnostics only."""

    def __init__(
        self,
        *,
        session: NativeSwiftSession,
        executable: NativeExecutable,
        configuration: NativeConfiguration,
    ) -> None:
        self.session = session
        self.executable = executable
        self.native_configuration = configuration
        self.configuration = configuration.configuration
        self._closed = False

    def diagnose_corrective_frame(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        if self._closed:
            raise NativeAdapterError("native corrective capability is closed")
        return self.session.diagnose_corrective_frame(document)

    def reopen_corrective_frame_output(
        self,
        document: Mapping[str, object],
        path: Path,
        *,
        width: int,
        height: int,
    ) -> PlanarFrame:
        if self._closed:
            raise NativeAdapterError("native corrective capability is closed")
        return self.session.reopen_corrective_frame_output(
            document,
            path,
            width=width,
            height=height,
        )

    def release_corrective_frame_outputs(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        if self._closed:
            raise NativeAdapterError("native corrective capability is closed")
        return self.session.release_corrective_frame_outputs(document)

    def close(self) -> None:
        if not self._closed:
            try:
                self.session.close()
            finally:
                self._closed = True

    def __enter__(self) -> "NativeCorrectiveDiagnosticCapability":
        if self._closed:
            raise NativeAdapterError("native corrective capability is closed")
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


class NativeCandidateCallable:
    """Candidate callable that delegates every reconstruction to one Swift process."""

    def __init__(
        self,
        *,
        session: NativeSwiftSession,
        adapter_configuration_sha256: str,
        failure_root: Path,
        split: str,
        p00_helper: P00NativeHelper,
        validation_sample_lock_sha256: str,
        degradation_policy_sha256: str,
        p07_sampling_plan_manifest_sha256: str | None = None,
        p07_analytic_fixture_manifest_sha256: str | None = None,
        p07_release_bundle_manifest_sha256: str | None = None,
    ) -> None:
        self.session = session
        self.adapter_configuration_sha256 = adapter_configuration_sha256
        self.failure_root = failure_root
        self.split = split
        self.p00_helper = p00_helper
        self.validation_sample_lock_sha256 = validation_sample_lock_sha256
        self.degradation_policy_sha256 = degradation_policy_sha256
        if split == "p07_holdout":
            if not _is_sha256(p07_sampling_plan_manifest_sha256):
                raise NativeAdapterError(
                    "P07 adapter requires a sampling-plan manifest binding"
                )
            if (
                p07_analytic_fixture_manifest_sha256 is not None
                or not _is_sha256(p07_release_bundle_manifest_sha256)
            ):
                raise NativeAdapterError(
                    "P07 holdout adapter requires only its release/sample bindings"
                )
        elif split == "p07_holdout_analytic":
            if (
                p07_sampling_plan_manifest_sha256 is not None
                or not _is_sha256(p07_analytic_fixture_manifest_sha256)
                or not _is_sha256(p07_release_bundle_manifest_sha256)
            ):
                raise NativeAdapterError(
                    "P07 analytic adapter requires release/fixture bindings"
                )
        elif (
            p07_sampling_plan_manifest_sha256 is not None
            or p07_analytic_fixture_manifest_sha256 is not None
            or p07_release_bundle_manifest_sha256 is not None
        ):
            raise NativeAdapterError(
                "P07 bindings are forbidden outside a P07 split"
            )
        self._p07_sample_binding = (
            {
                "sampling_plan_manifest_sha256": (
                    p07_sampling_plan_manifest_sha256
                ),
                "frame_extraction_manifest_sha256": None,
            }
            if split == "p07_holdout"
            else None
        )
        self._p07_analytic_binding = (
            {
                "analytic_fixture_manifest_sha256": (
                    p07_analytic_fixture_manifest_sha256
                ),
                "p06_release_bundle_manifest_sha256": (
                    p07_release_bundle_manifest_sha256
                ),
                "adapter_configuration_sha256": adapter_configuration_sha256,
            }
            if split == "p07_holdout_analytic"
            else None
        )
        self._native_cache_root = _absolute_lexical_path(self.failure_root.parent)
        _ensure_directory(self._native_cache_root)
        self._native_cache_root_descriptor = _open_directory_descriptor(
            self._native_cache_root,
            create=False,
        )
        cache_root_metadata = os.fstat(self._native_cache_root_descriptor)
        self._native_cache_root_identity = (
            cache_root_metadata.st_dev,
            cache_root_metadata.st_ino,
        )
        self._records: list[dict[str, object]] = []
        self._control_records: list[dict[str, object]] = []
        self._non_ash_cache_records: list[dict[str, object]] = []
        self._fixed_cache_records: list[dict[str, object]] = []
        self._non_ash_cache_manifests: dict[str, dict[str, object]] = {}
        self._non_ash_cache_preparation_records: list[dict[str, object]] = []
        self._non_ash_cache_roots: dict[str, Path] = {}
        self._measurement_invocation_count = 0
        self._pending_control_cache_files: dict[
            Path,
            tuple[str, int, str, Path | None],
        ] = {}
        self._pending_control_cache_directories: set[Path] = set()
        self._closed = False

    def _verify_native_cache_root(self) -> None:
        pinned = os.fstat(self._native_cache_root_descriptor)
        if (
            not stat.S_ISDIR(pinned.st_mode)
            or (pinned.st_dev, pinned.st_ino) != self._native_cache_root_identity
        ):
            raise NativeAdapterError("pinned native cache root identity changed")
        current_descriptor = _open_directory_descriptor(
            self._native_cache_root,
            create=False,
        )
        try:
            current = os.fstat(current_descriptor)
            if (
                not stat.S_ISDIR(current.st_mode)
                or (current.st_dev, current.st_ino)
                != self._native_cache_root_identity
            ):
                raise NativeAdapterError("native cache root was replaced")
        finally:
            os.close(current_descriptor)

    def bind_p07_frame_extraction(
        self,
        *,
        sampling_plan_manifest_sha256: str,
        frame_extraction_manifest_sha256: str,
    ) -> None:
        """Bind the one opened extraction before any P07 pixel invocation."""

        if (
            self.split != "p07_holdout"
            or self._p07_sample_binding is None
            or self._p07_sample_binding["sampling_plan_manifest_sha256"]
            != sampling_plan_manifest_sha256
            or not _is_sha256(frame_extraction_manifest_sha256)
            or self._p07_sample_binding["frame_extraction_manifest_sha256"]
            is not None
            or self._records
            or self._control_records
            or self._non_ash_cache_records
            or self._fixed_cache_records
            or self._non_ash_cache_preparation_records
        ):
            raise NativeAdapterError(
                "P07 extraction binding is stale, repeated, or follows pixel work"
            )
        self._p07_sample_binding[
            "frame_extraction_manifest_sha256"
        ] = frame_extraction_manifest_sha256

    def _required_p07_sample_binding(self) -> Mapping[str, object] | None:
        if self.split != "p07_holdout":
            return None
        if (
            self._p07_sample_binding is None
            or not _is_sha256(
                self._p07_sample_binding.get(
                    "sampling_plan_manifest_sha256"
                )
            )
            or not _is_sha256(
                self._p07_sample_binding.get(
                    "frame_extraction_manifest_sha256"
                )
            )
        ):
            raise NativeAdapterError(
                "P07 extraction must be bound before pixel processing"
            )
        return dict(self._p07_sample_binding)

    def _attach_p07_sample_binding(
        self,
        record: Mapping[str, object],
    ) -> dict[str, object]:
        binding = self._required_p07_sample_binding()
        result = dict(record)
        analytic_binding = self._p07_analytic_binding
        result.pop("record_sha256", None)
        if binding is not None:
            result["p07_sample_binding"] = binding
        if analytic_binding is not None:
            result["p07_analytic_binding"] = dict(analytic_binding)
        result["record_sha256"] = canonical_sha256(result)
        return result

    def __call__(self, frame: PlanarFrame, context: CandidateContext) -> PlanarFrame:
        return self.reconstruct_batch(((frame, context),))[0]

    def reconstruct_batch(
        self,
        items: Sequence[Tuple[PlanarFrame, CandidateContext]],
    ) -> Tuple[PlanarFrame, ...]:
        self._verify_native_cache_root()
        if not items:
            raise NativeAdapterError("native batch must not be empty")
        self._required_p07_sample_binding()
        invocation_root = self.failure_root.parent / "invocations"
        _ensure_directory(invocation_root)
        with tempfile.TemporaryDirectory(dir=invocation_root) as temporary:
            root = Path(temporary)
            frames = []
            input_frame_hashes = []
            for index, (frame, context) in enumerate(items):
                self._validate_geometry(frame, context)
                payload = _planar_to_video_range_nv12(frame)
                input_path = root / f"input-{index}.nv12"
                output_path = root / f"output-{index}.nv12"
                _write_new(input_path, payload)
                input_frame_hash = frame_sha256(frame)
                input_frame_hashes.append(input_frame_hash)
                frames.append(
                    {
                        "request_id": f"native-{len(self._records) + index:08d}",
                        "route": context.target_route,
                        "input_path": str(input_path),
                        "input_sha256": _sha256(payload),
                        "input_width": frame.y.shape[1],
                        "input_height": frame.y.shape[0],
                        "output_path": str(output_path),
                        "output_width": context.y_shape[1],
                        "output_height": context.y_shape[0],
                        "pixel_format": "420v",
                        "matrix": "BT.709",
                        "range": "video",
                        "chroma_siting": "left",
                    }
                )
            configuration = self.session.configuration.configuration
            request = {
                "schema_version": "1.0.0",
                "operation": "process_batch",
                "configuration_id": configuration["configuration_id"],
                "compiler_inputs_sha256": configuration["compiler_inputs_sha256"],
                "frames": frames,
            }
            try:
                response = self.session.request(request)
                summaries = response["frames"]
                if not isinstance(summaries, list) or len(summaries) != len(items):
                    raise NativeAdapterError("native response frame count mismatch")
                outputs = []
                new_records = []
                for index, (summary, (_, context)) in enumerate(zip(summaries, items)):
                    if not isinstance(summary, dict):
                        raise NativeAdapterError("native summary is not an object")
                    output_path = Path(frames[index]["output_path"])
                    payload = _read_regular(output_path)
                    if summary.get("output_nv12_sha256") != _sha256(payload):
                        raise NativeAdapterError("native output hash mismatch")
                    output = _video_range_nv12_to_planar(
                        payload,
                        width=context.y_shape[1],
                        height=context.y_shape[0],
                    )
                    record = dict(summary)
                    record.update(
                        {
                            "input_frame_sha256": input_frame_hashes[index],
                            "output_frame_sha256": frame_sha256(output),
                            "adapter_configuration_sha256": self.adapter_configuration_sha256,
                            "raw_output_contract_sha256": configuration[
                                "raw_output_contract_sha256"
                            ],
                            "full_control_configuration_sha256": configuration[
                                "full_control_configuration_sha256"
                            ],
                        }
                    )
                    outputs.append(output)
                    new_records.append(self._attach_p07_sample_binding(record))
                self._records.extend(new_records)
                return tuple(outputs)
            except Exception as error:
                failure = {
                    "schema_version": "1.0.0",
                    "status": "failed",
                    "configuration_id": configuration["configuration_id"],
                    "request_sha256": canonical_sha256(request),
                    "input_nv12_sha256_values": [frame["input_sha256"] for frame in frames],
                    "error_type": type(error).__name__,
                    "message": str(error),
                }
                _ensure_directory(self.failure_root)
                failure_path = self.failure_root / f"runtime-{uuid.uuid4().hex}.json"
                _write_new(failure_path, canonical_json_bytes(failure) + b"\n")
                raise NativeAdapterError(str(error), failure_path) from error

    def runtime_records(self) -> Tuple[dict[str, object], ...]:
        return tuple(dict(record) for record in self._records)

    def prepare_non_ash_cache(
        self,
        frame: PlanarFrame,
        context: CandidateContext,
        *,
        source_asset_id: str,
        degradation_profile_id: str | None = None,
        degradation_profile_sha256: str | None = None,
    ) -> Mapping[str, object]:
        self._verify_native_cache_root()
        self._validate_geometry(frame, context)
        if (
            not isinstance(source_asset_id, str)
            or not source_asset_id
            or len(source_asset_id) > 1_024
            or (degradation_profile_id is None)
            != (degradation_profile_sha256 is None)
            or (
                degradation_profile_id is not None
                and (
                    not isinstance(degradation_profile_id, str)
                    or not degradation_profile_id
                    or len(degradation_profile_id) > 1_024
                    or not _is_sha256(degradation_profile_sha256)
                )
            )
        ):
            raise NativeAdapterError("non-ASH cache source/profile identity is invalid")
        invocation_root = self.failure_root.parent / "non-ash-cache-invocations"
        _ensure_directory(invocation_root)
        configuration = self.session.configuration.configuration
        payload = _planar_to_video_range_nv12(frame)
        input_frame_sha256 = frame_sha256(frame)
        identity: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_persisted_non_ash_cache_identity",
            "split": self.split,
            "native_executable_sha256": configuration["swift_cli"][
                "executable_sha256"
            ],
            "native_source_manifest_sha256": configuration["swift_cli"][
                "source_manifest_sha256"
            ],
            "shared_bank_configuration_sha256": configuration[
                "shared_bank_configuration_sha256"
            ],
            "route": context.target_route,
            "source_asset_id": source_asset_id,
            "degradation_profile_id": degradation_profile_id,
            "degradation_profile_sha256": degradation_profile_sha256,
            "input_frame_sha256": input_frame_sha256,
            "input_nv12_sha256": _sha256(payload),
            "input_luma_dimensions": list(frame.y.shape),
            "input_chroma_dimensions": list(frame.cb.shape),
            "output_luma_dimensions": list(context.y_shape),
            "output_chroma_dimensions": list(context.cb_shape),
        }
        p07_binding = self._required_p07_sample_binding()
        if p07_binding is not None:
            identity["p07_sample_binding"] = p07_binding
        if self._p07_analytic_binding is not None:
            identity["p07_analytic_binding"] = dict(
                self._p07_analytic_binding
            )
        identity_sha256 = canonical_sha256(identity)
        persistent_root = (
            self.failure_root.parent
            / "non-ash-output-cache-v1"
            / self.split
            / str(configuration["shared_bank_configuration_sha256"])
            / identity_sha256
        )
        self._prepare_deferred_cache_directory(
            persistent_root,
            cache_root=self.failure_root.parent / "non-ash-output-cache-v1",
        )
        origin_path = persistent_root / "origin.json"
        with tempfile.TemporaryDirectory(dir=invocation_root) as temporary:
            root = Path(temporary)
            input_path = root / "input.nv12"
            output_path = root / "unused-output.nv12"
            artifact_path = root / "cache.bin"
            _write_new(input_path, payload)
            native_frame = {
                "request_id": f"non-ash-cache-{len(self._non_ash_cache_manifests):08d}",
                "route": context.target_route,
                "input_path": str(input_path),
                "input_sha256": _sha256(payload),
                "input_width": frame.y.shape[1],
                "input_height": frame.y.shape[0],
                "output_path": str(output_path),
                "output_width": context.y_shape[1],
                "output_height": context.y_shape[0],
                "pixel_format": "420v",
                "matrix": "BT.709",
                "range": "video",
                "chroma_siting": "left",
            }
            origin: Mapping[str, object] | None = None
            request: dict[str, object]
            if _path_entry_exists(origin_path):
                origin_payload = _read_regular(origin_path)
                origin = _parse_json(
                    origin_payload,
                    trailing_newline=False,
                )
                self._validate_persisted_non_ash_origin(
                    origin,
                    identity=identity,
                    identity_sha256=identity_sha256,
                    persistent_root=persistent_root,
                )
                manifest = origin["cache_manifest"]
                assert isinstance(manifest, dict)
                artifact_path = persistent_root / str(
                    origin["cache_artifact_filename"]
                )
                artifact_payload = _read_regular(artifact_path)
                self._queue_verified_cache_file(
                    artifact_path,
                    artifact_payload,
                    role="payload",
                )
                self._queue_verified_cache_file(
                    origin_path,
                    origin_payload,
                    role="dependency_origin",
                )
                request = {
                    "schema_version": "1.0.0",
                    "operation": "import_non_ash_cache",
                    "configuration_id": configuration["configuration_id"],
                    "shared_bank_configuration_sha256": configuration[
                        "shared_bank_configuration_sha256"
                    ],
                    "cache_token": origin["cache_token"],
                    "cache_manifest": manifest,
                    "cache_artifact_path": str(
                        persistent_root / str(origin["cache_artifact_filename"])
                    ),
                    "cache_artifact_sha256": origin["cache_artifact_sha256"],
                }
            else:
                request = {
                    "schema_version": "1.0.0",
                    "operation": "prepare_non_ash_cache",
                    "configuration_id": configuration["configuration_id"],
                    "shared_bank_configuration_sha256": configuration[
                        "shared_bank_configuration_sha256"
                    ],
                    "source_asset_id": source_asset_id,
                    "degradation_profile_id": degradation_profile_id,
                    "degradation_profile_sha256": degradation_profile_sha256,
                    "input_frame_sha256": input_frame_sha256,
                    "cache_artifact_path": str(artifact_path),
                    "frame": native_frame,
                }
            try:
                response = self.session.prepare_non_ash_cache(request)
                cache = response["cache"]
                assert isinstance(cache, dict)
                token = cache.get("cache_token")
                manifest = cache.get("cache_manifest")
                native_fields = {
                    "cache_token",
                    "cache_manifest",
                    "cache_reused",
                    "cache_artifact_sha256",
                    "cache_artifact_size_bytes",
                    "preparation_analysis_grid_invocation_count",
                    "preparation_spatial_operator_evaluation_count",
                }
                if (
                    set(cache) != native_fields
                    or not _is_sha256(token)
                    or not isinstance(manifest, dict)
                    or not isinstance(cache.get("cache_reused"), bool)
                    or not _is_sha256(cache.get("cache_artifact_sha256"))
                    or not isinstance(cache.get("cache_artifact_size_bytes"), int)
                    or isinstance(cache.get("cache_artifact_size_bytes"), bool)
                    or int(cache["cache_artifact_size_bytes"]) <= 0
                ):
                    raise NativeAdapterError("native non-ASH cache envelope is invalid")
                self._validate_non_ash_cache_manifest(
                    manifest,
                    token=str(token),
                    source_asset_id=source_asset_id,
                    degradation_profile_id=degradation_profile_id,
                    degradation_profile_sha256=degradation_profile_sha256,
                    input_frame_sha256=input_frame_sha256,
                    context=context,
                    input_shape=frame.y.shape,
                )
                canonical_manifest = json.loads(canonical_json_bytes(manifest))
                cache_reused = origin is not None
                expected_analysis = 0 if cache_reused else 1
                expected_operator = 0 if cache_reused else 16
                if (
                    cache["cache_reused"] is not cache_reused
                    or cache["preparation_analysis_grid_invocation_count"]
                    != expected_analysis
                    or cache["preparation_spatial_operator_evaluation_count"]
                    != expected_operator
                ):
                    raise NativeAdapterError("native cache preparation counts differ")
                if origin is None:
                    artifact = _read_regular(artifact_path)
                    artifact_sha256 = _sha256(artifact)
                    if (
                        artifact_sha256 != cache["cache_artifact_sha256"]
                        or len(artifact) != cache["cache_artifact_size_bytes"]
                    ):
                        raise NativeAdapterError("native cache artifact binding differs")
                    artifact_filename = f"cache-{artifact_sha256}.bin"
                    persistent_artifact_path = persistent_root / artifact_filename
                    _write_or_verify(persistent_artifact_path, artifact)
                    self._queue_verified_cache_file(
                        persistent_artifact_path,
                        artifact,
                        role="payload",
                    )
                    origin_document: dict[str, object] = {
                        "schema_version": "1.0.0",
                        "artifact_kind": "p06_persisted_non_ash_cache_origin",
                        "identity": identity,
                        "identity_sha256": identity_sha256,
                        "cache_token": str(token),
                        "cache_manifest": canonical_manifest,
                        "cache_artifact_filename": artifact_filename,
                        "cache_artifact_sha256": artifact_sha256,
                        "cache_artifact_size_bytes": len(artifact),
                        "origin_configuration_id": configuration["configuration_id"],
                        "origin_native_executable_sha256": configuration["swift_cli"][
                            "executable_sha256"
                        ],
                        "origin_native_source_manifest_sha256": configuration[
                            "swift_cli"
                        ]["source_manifest_sha256"],
                    }
                    origin_document["origin_manifest_sha256"] = canonical_sha256(
                        origin_document
                    )
                    origin_payload = canonical_json_bytes(origin_document)
                    _write_or_verify(origin_path, origin_payload)
                    self._queue_verified_cache_file(
                        origin_path,
                        origin_payload,
                        role="dependency_origin",
                    )
                    origin = origin_document
                else:
                    if (
                        token != origin["cache_token"]
                        or canonical_manifest != origin["cache_manifest"]
                        or cache["cache_artifact_sha256"]
                        != origin["cache_artifact_sha256"]
                        or cache["cache_artifact_size_bytes"]
                        != origin["cache_artifact_size_bytes"]
                    ):
                        raise NativeAdapterError("reopened cache origin changed")
                assert origin is not None
                self._non_ash_cache_manifests[str(token)] = canonical_manifest
                self._non_ash_cache_roots[str(token)] = persistent_root
                preparation_record: dict[str, object] = {
                    "schema_version": "1.0.0",
                    "artifact_kind": "p06_non_ash_cache_preparation_evidence",
                    "identity_sha256": identity_sha256,
                    "cache_token": str(token),
                    "cache_origin_manifest_sha256": origin[
                        "origin_manifest_sha256"
                    ],
                    "requesting_configuration_id": configuration["configuration_id"],
                    "shared_bank_configuration_sha256": configuration[
                        "shared_bank_configuration_sha256"
                    ],
                    "cache_reused": cache_reused,
                    "preparation_analysis_grid_invocation_count": expected_analysis,
                    "preparation_spatial_operator_evaluation_count": expected_operator,
                    "cache_artifact_sha256": cache["cache_artifact_sha256"],
                    "cache_artifact_size_bytes": cache["cache_artifact_size_bytes"],
                    "feature_tensor_q15_sha256": manifest[
                        "feature_tensor_q15_sha256"
                    ],
                    "descriptor_output_frame_sha256_values": [
                        row["output_frame_sha256"]
                        for row in manifest["descriptor_outputs"]
                    ],
                }
                preparation_record = self._attach_p07_sample_binding(
                    preparation_record
                )
                self._non_ash_cache_preparation_records.append(preparation_record)
                return {
                    "cache_token": str(token),
                    "cache_manifest": json.loads(canonical_json_bytes(manifest)),
                    "cache_reused": cache_reused,
                    "preparation_analysis_grid_invocation_count": expected_analysis,
                    "preparation_spatial_operator_evaluation_count": expected_operator,
                    "cache_reopen_evidence_sha256": preparation_record["record_sha256"],
                    "cache_origin_manifest_sha256": origin[
                        "origin_manifest_sha256"
                    ],
                }
            except Exception as error:
                failure = {
                    "schema_version": "1.0.0",
                    "status": "failed",
                    "operation": "prepare_non_ash_cache",
                    "configuration_id": configuration["configuration_id"],
                    "native_request_sha256": canonical_sha256(request),
                    "source_asset_id": source_asset_id,
                    "degradation_profile_id": degradation_profile_id,
                    "degradation_profile_sha256": degradation_profile_sha256,
                    "input_frame_sha256": input_frame_sha256,
                    "input_nv12_sha256": _sha256(payload),
                    "error_type": type(error).__name__,
                    "message": str(error),
                }
                _ensure_directory(self.failure_root)
                failure_path = self.failure_root / f"non-ash-cache-{uuid.uuid4().hex}.json"
                _write_new(failure_path, canonical_json_bytes(failure) + b"\n")
                raise NativeAdapterError(str(error), failure_path) from error

    def reconstruct_non_ash_cached(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> PlanarFrame:
        self._verify_native_cache_root()
        bindings = self._non_ash_cached_reconstruction_bindings(
            cache_token,
            rule,
        )
        reopened = self._reopen_non_ash_cached(
            bindings,
            required=False,
        )
        if reopened is not None:
            return reopened
        output, output_payload, specialized_record = (
            self._invoke_non_ash_cached_recombination(bindings)
        )
        base_control_record = self._non_ash_base_control_record(
            bindings,
            specialized_record,
        )
        origin = self._publish_non_ash_reconstruction_proof(
            bindings=bindings,
            output_payload=output_payload,
            specialized_record=specialized_record,
            base_control_record=base_control_record,
        )
        decorated_record = self._decorated_control_cache_record(
            origin,
            reused=False,
            current_analysis_count=0,
            current_operator_count=0,
        )
        self._non_ash_cache_records.append(specialized_record)
        self._control_records.append(decorated_record)
        return output

    def reopen_non_ash_cached(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> PlanarFrame:
        """Verify one compact proof by recombining with the current Swift binary."""

        self._verify_native_cache_root()
        bindings = self._non_ash_cached_reconstruction_bindings(
            cache_token,
            rule,
        )
        output = self._reopen_non_ash_cached(bindings, required=True)
        assert output is not None
        return output

    def _invoke_non_ash_cached_recombination(
        self,
        bindings: _NonASHCachedReconstructionBindings,
    ) -> tuple[PlanarFrame, bytes, dict[str, object]]:
        invocation_root = self.failure_root.parent / "non-ash-cache-invocations"
        _ensure_directory(invocation_root)
        with tempfile.TemporaryDirectory(dir=invocation_root) as temporary:
            output_path = Path(temporary) / "output.nv12"
            request = {
                "schema_version": "1.0.0",
                "operation": "reconstruct_non_ash_cached",
                "cache_token": bindings.cache_token,
                "rule_configuration": dict(bindings.rule_configuration),
                "rule_sha256": bindings.rule_sha256,
                "output_path": str(output_path),
            }
            response = self.session.reconstruct_non_ash_cached(request)
            reconstruction = response["cached_reconstruction"]
            assert isinstance(reconstruction, dict)
            output_payload = _read_regular(output_path)
            native_record = self._validate_cached_reconstruction(
                reconstruction,
                output_payload=output_payload,
                output_width=bindings.output_width,
                output_height=bindings.output_height,
                expected_artifact_kind="p06_native_non_ash_cached_reconstruction",
                expected_fields={
                    "schema_version",
                    "artifact_kind",
                    "cache_token",
                    "cache_manifest_sha256",
                    "rule_configuration",
                    "rule_sha256",
                    "output_frame_sha256",
                    "target_route",
                    "stateful_lut_lookup_count",
                    "spatial_operator_recompute_count",
                    "analysis_grid_invocation_count",
                    "record_sha256",
                },
            )
            output, specialized_record = self._non_ash_specialized_record(
                bindings,
                output_payload,
            )
            if native_record != specialized_record:
                raise NativeAdapterError("cached non-ASH record binding differs")
            return output, output_payload, specialized_record

    def _non_ash_cached_reconstruction_bindings(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> _NonASHCachedReconstructionBindings:
        manifest = self._non_ash_cache_manifests.get(cache_token)
        if manifest is None or not _is_sha256(cache_token):
            raise NativeAdapterError("unknown non-ASH cache token")
        self._validate_non_ash_rule(rule)
        rule_configuration = {name: int(rule[name]) for name in _NON_ASH_RULE_COORDINATES}
        rule_sha256 = canonical_sha256(rule_configuration)
        dimensions = manifest["dimensions"]
        output_luma = dimensions.get("output_luma") if isinstance(dimensions, dict) else None
        if (
            not isinstance(output_luma, list)
            or len(output_luma) != 2
            or any(
                not isinstance(value, int)
                or isinstance(value, bool)
                or value <= 0
                or value % 2
                for value in output_luma
            )
        ):
            raise NativeAdapterError("non-ASH cached output geometry is invalid")
        output_height, output_width = output_luma
        cache_root = self._non_ash_cache_roots.get(cache_token)
        if cache_root is None:
            raise NativeAdapterError("non-ASH cache origin root is absent")
        cache_origin = _parse_json(
            _read_regular(cache_root / "origin.json"),
            trailing_newline=False,
        )
        cache_identity = cache_origin.get("identity")
        if not isinstance(cache_identity, dict):
            raise NativeAdapterError("persisted non-ASH cache identity is absent")
        identity_sha256 = canonical_sha256(cache_identity)
        configuration = self.session.configuration.configuration
        expected_root = (
            self.failure_root.parent
            / "non-ash-output-cache-v1"
            / self.split
            / str(configuration["shared_bank_configuration_sha256"])
            / identity_sha256
        )
        if cache_root != expected_root:
            raise NativeAdapterError("persisted non-ASH cache root differs")
        self._validate_persisted_non_ash_origin(
            cache_origin,
            identity=cache_identity,
            identity_sha256=identity_sha256,
            persistent_root=cache_root,
        )
        sample_binding = self._required_p07_sample_binding()
        identity_fields = {
            "schema_version",
            "artifact_kind",
            "split",
            "native_executable_sha256",
            "native_source_manifest_sha256",
            "shared_bank_configuration_sha256",
            "route",
            "source_asset_id",
            "degradation_profile_id",
            "degradation_profile_sha256",
            "input_frame_sha256",
            "input_nv12_sha256",
            "input_luma_dimensions",
            "input_chroma_dimensions",
            "output_luma_dimensions",
            "output_chroma_dimensions",
        }
        if sample_binding is not None:
            identity_fields.add("p07_sample_binding")
        if self._p07_analytic_binding is not None:
            identity_fields.add("p07_analytic_binding")
        if (
            set(cache_identity) != identity_fields
            or cache_identity.get("schema_version") != "1.0.0"
            or cache_identity.get("artifact_kind")
            != "p06_persisted_non_ash_cache_identity"
            or cache_identity.get("split") != self.split
            or cache_identity.get("native_executable_sha256")
            != configuration["swift_cli"]["executable_sha256"]
            or cache_identity.get("native_source_manifest_sha256")
            != configuration["swift_cli"]["source_manifest_sha256"]
            or cache_identity.get("shared_bank_configuration_sha256")
            != configuration["shared_bank_configuration_sha256"]
            or cache_identity.get("p07_sample_binding") != sample_binding
            or cache_identity.get("p07_analytic_binding")
            != self._p07_analytic_binding
            or cache_origin.get("cache_token") != cache_token
            or cache_origin.get("cache_manifest") != manifest
            or manifest.get("cache_manifest_sha256") != cache_token
            or manifest.get("bank_id")
            != configuration["shared_bank_configuration_sha256"]
            or not _is_sha256(cache_identity.get("input_nv12_sha256"))
        ):
            raise NativeAdapterError("persisted non-ASH cache binding differs")
        control_request = self._non_ash_control_request(
            rule_configuration,
            str(manifest["bank_id"]),
        )
        control_identity = self._control_cache_identity(
            request=control_request,
            input_frame_sha256=str(manifest["input_frame_sha256"]),
            input_nv12_sha256=str(cache_identity["input_nv12_sha256"]),
            route=str(manifest["route"]),
            input_luma_dimensions=cache_identity["input_luma_dimensions"],
            input_chroma_dimensions=cache_identity["input_chroma_dimensions"],
            output_luma_dimensions=cache_identity["output_luma_dimensions"],
            output_chroma_dimensions=cache_identity["output_chroma_dimensions"],
            non_ash_cache_token=cache_token,
            non_ash_cache_origin_manifest_sha256=str(
                cache_origin["origin_manifest_sha256"]
            ),
        )
        return _NonASHCachedReconstructionBindings(
            cache_token=cache_token,
            cache_origin_manifest_sha256=str(
                cache_origin["origin_manifest_sha256"]
            ),
            manifest=manifest,
            rule_configuration=rule_configuration,
            rule_sha256=rule_sha256,
            output_width=output_width,
            output_height=output_height,
            control_request=control_request,
            control_identity=control_identity,
        )

    def _reopen_non_ash_cached(
        self,
        bindings: _NonASHCachedReconstructionBindings,
        *,
        required: bool,
    ) -> PlanarFrame | None:
        origin_path = self._non_ash_reconstruction_proof_origin_path(bindings)
        origin_payload = self._pending_or_persisted_cache_payload(origin_path)
        if origin_payload is None:
            if required:
                raise NativeAdapterError(
                    "persisted non-ASH reconstruction proof is absent"
                )
            return None
        origin = _parse_json(origin_payload, trailing_newline=False)
        self._validate_non_ash_reconstruction_proof_origin(
            origin,
            bindings=bindings,
        )
        self._prepare_deferred_cache_directory(
            origin_path.parent,
            cache_root=(
                self.failure_root.parent / "non-ash-reconstruction-proof-v1"
            ),
        )
        if _path_entry_exists(origin_path):
            self._queue_verified_cache_file(
                origin_path,
                origin_payload,
                role="origin",
            )
        output, output_payload, specialized_record = (
            self._invoke_non_ash_cached_recombination(bindings)
        )
        base_control_record = self._non_ash_base_control_record(
            bindings,
            specialized_record,
        )
        origin_specialized = origin.get("origin_native_non_ash_cache_record")
        origin_base = origin.get("origin_native_control_record")
        if (
            origin.get("control_request") != bindings.control_request
            or origin_specialized != specialized_record
            or origin_base != base_control_record
            or origin.get("output_nv12_sha256") != _sha256(output_payload)
            or origin.get("output_size_bytes") != len(output_payload)
            or origin.get("output_frame_sha256")
            != specialized_record["output_frame_sha256"]
            or not isinstance(origin_base, dict)
            or origin_base.get("non_ash_cache_record_sha256")
            != specialized_record["record_sha256"]
        ):
            raise NativeAdapterError("persisted non-ASH reconstruction proof differs")
        decorated_record = self._decorated_control_cache_record(
            origin,
            reused=True,
            current_analysis_count=0,
            current_operator_count=0,
        )
        self._non_ash_cache_records.append(specialized_record)
        self._control_records.append(decorated_record)
        return output

    def _non_ash_specialized_record(
        self,
        bindings: _NonASHCachedReconstructionBindings,
        output_payload: bytes,
    ) -> tuple[PlanarFrame, dict[str, object]]:
        expected_size = bindings.output_width * bindings.output_height * 3 // 2
        if len(output_payload) != expected_size:
            raise NativeAdapterError("persisted non-ASH output geometry differs")
        output = _video_range_nv12_to_planar(
            output_payload,
            width=bindings.output_width,
            height=bindings.output_height,
        )
        record: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_non_ash_cached_reconstruction",
            "cache_token": bindings.cache_token,
            "cache_manifest_sha256": bindings.cache_token,
            "rule_configuration": dict(bindings.rule_configuration),
            "rule_sha256": bindings.rule_sha256,
            "output_frame_sha256": frame_sha256(output),
            "target_route": bindings.manifest["route"],
            "stateful_lut_lookup_count": 0,
            "spatial_operator_recompute_count": 0,
            "analysis_grid_invocation_count": 0,
        }
        return output, self._attach_p07_sample_binding(record)

    def _non_ash_base_control_record(
        self,
        bindings: _NonASHCachedReconstructionBindings,
        specialized_record: Mapping[str, object],
    ) -> dict[str, object]:
        parameters = bindings.control_request["parameters"]
        assert isinstance(parameters, dict)
        record: dict[str, object] = {
            "control_key": bindings.control_request["control_key"],
            "control_mode": bindings.control_request["control_mode"],
            "request_sha256": bindings.control_request["request_sha256"],
            "configuration_sha256": bindings.control_request[
                "configuration_sha256"
            ],
            "shared_bank_configuration_sha256": bindings.control_request[
                "shared_bank_configuration_sha256"
            ],
            "input_frame_sha256": bindings.manifest["input_frame_sha256"],
            "output_frame_sha256": specialized_record["output_frame_sha256"],
            "target_route": bindings.manifest["route"],
            "parameters": dict(parameters),
            "parameters_sha256": canonical_sha256(parameters),
            "non_ash_cache_record_sha256": specialized_record["record_sha256"],
        }
        return self._attach_p07_sample_binding(record)

    def _non_ash_reconstruction_proof_origin_path(
        self,
        bindings: _NonASHCachedReconstructionBindings,
    ) -> Path:
        return (
            self.failure_root.parent
            / "non-ash-reconstruction-proof-v1"
            / self.split
            / str(bindings.control_request["shared_bank_configuration_sha256"])
            / canonical_sha256(bindings.control_identity)
            / "origin.json"
        )

    def _publish_non_ash_reconstruction_proof(
        self,
        *,
        bindings: _NonASHCachedReconstructionBindings,
        output_payload: bytes,
        specialized_record: Mapping[str, object],
        base_control_record: Mapping[str, object],
    ) -> Mapping[str, object]:
        origin_path = self._non_ash_reconstruction_proof_origin_path(bindings)
        root = origin_path.parent
        cache_root = self.failure_root.parent / "non-ash-reconstruction-proof-v1"
        self._prepare_deferred_cache_directory(root, cache_root=cache_root)
        identity_sha256 = canonical_sha256(bindings.control_identity)
        specialized = json.loads(canonical_json_bytes(specialized_record))
        base_record = json.loads(canonical_json_bytes(base_control_record))
        output_nv12_sha256 = _sha256(output_payload)
        proof: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_non_ash_reconstruction_origin_proof",
            "identity_sha256": identity_sha256,
            "control_request_sha256": bindings.control_request["request_sha256"],
            "cache_token": bindings.cache_token,
            "cache_origin_manifest_sha256": (
                bindings.cache_origin_manifest_sha256
            ),
            "rule_sha256": bindings.rule_sha256,
            "input_frame_sha256": bindings.control_identity[
                "input_frame_sha256"
            ],
            "input_nv12_sha256": bindings.control_identity["input_nv12_sha256"],
            "output_frame_sha256": specialized["output_frame_sha256"],
            "output_nv12_sha256": output_nv12_sha256,
            "origin_native_non_ash_cache_record_sha256": specialized[
                "record_sha256"
            ],
            "origin_native_control_record_sha256": base_record["record_sha256"],
        }
        proof["proof_sha256"] = canonical_sha256(proof)
        origin_document: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": (
                "p06_persisted_non_ash_reconstruction_proof_origin"
            ),
            "identity": dict(bindings.control_identity),
            "identity_sha256": identity_sha256,
            "control_request": dict(bindings.control_request),
            "cache_token": bindings.cache_token,
            "cache_origin_manifest_sha256": (
                bindings.cache_origin_manifest_sha256
            ),
            "rule_configuration": dict(bindings.rule_configuration),
            "rule_sha256": bindings.rule_sha256,
            "output_nv12_sha256": output_nv12_sha256,
            "output_size_bytes": len(output_payload),
            "output_frame_sha256": specialized["output_frame_sha256"],
            "origin_native_non_ash_cache_record": specialized,
            "origin_native_control_record": base_record,
            "origin_proof": proof,
        }
        origin_document["origin_manifest_sha256"] = canonical_sha256(
            origin_document
        )
        existing_payload = self._pending_or_persisted_cache_payload(origin_path)
        if existing_payload is not None:
            existing = _parse_json(
                existing_payload,
                trailing_newline=False,
            )
            self._validate_non_ash_reconstruction_proof_origin(
                existing,
                bindings=bindings,
            )
            if existing != origin_document:
                raise NativeAdapterError(
                    "persisted non-ASH reconstruction proof changed"
                )
            return existing
        self._stage_deferred_cache_origin(
            origin_path,
            canonical_json_bytes(origin_document),
            role="origin",
        )
        staged_payload = self._pending_or_persisted_cache_payload(origin_path)
        assert staged_payload is not None
        reopened = _parse_json(staged_payload, trailing_newline=False)
        self._validate_non_ash_reconstruction_proof_origin(
            reopened,
            bindings=bindings,
        )
        if reopened != origin_document:
            raise NativeAdapterError(
                "published non-ASH reconstruction proof differs"
            )
        return reopened

    @staticmethod
    def _validate_non_ash_reconstruction_proof_origin(
        origin: Mapping[str, object],
        *,
        bindings: _NonASHCachedReconstructionBindings,
    ) -> None:
        fields = {
            "schema_version",
            "artifact_kind",
            "identity",
            "identity_sha256",
            "control_request",
            "cache_token",
            "cache_origin_manifest_sha256",
            "rule_configuration",
            "rule_sha256",
            "output_nv12_sha256",
            "output_size_bytes",
            "output_frame_sha256",
            "origin_native_non_ash_cache_record",
            "origin_native_control_record",
            "origin_proof",
            "origin_manifest_sha256",
        }
        proof_fields = {
            "schema_version",
            "artifact_kind",
            "identity_sha256",
            "control_request_sha256",
            "cache_token",
            "cache_origin_manifest_sha256",
            "rule_sha256",
            "input_frame_sha256",
            "input_nv12_sha256",
            "output_frame_sha256",
            "output_nv12_sha256",
            "origin_native_non_ash_cache_record_sha256",
            "origin_native_control_record_sha256",
            "proof_sha256",
        }
        specialized_fields = {
            "schema_version",
            "artifact_kind",
            "cache_token",
            "cache_manifest_sha256",
            "rule_configuration",
            "rule_sha256",
            "output_frame_sha256",
            "target_route",
            "stateful_lut_lookup_count",
            "spatial_operator_recompute_count",
            "analysis_grid_invocation_count",
            "record_sha256",
        }
        base_fields = {
            "control_key",
            "control_mode",
            "request_sha256",
            "configuration_sha256",
            "shared_bank_configuration_sha256",
            "input_frame_sha256",
            "output_frame_sha256",
            "target_route",
            "parameters",
            "parameters_sha256",
            "non_ash_cache_record_sha256",
            "record_sha256",
        }
        for binding_field in ("p07_sample_binding", "p07_analytic_binding"):
            if binding_field in bindings.control_identity:
                specialized_fields.add(binding_field)
                base_fields.add(binding_field)
        identity_sha256 = canonical_sha256(bindings.control_identity)
        specialized = origin.get("origin_native_non_ash_cache_record")
        base = origin.get("origin_native_control_record")
        proof = origin.get("origin_proof")
        unhashed = dict(origin)
        declared = unhashed.pop("origin_manifest_sha256", None)
        if (
            set(origin) != fields
            or origin.get("schema_version") != "1.0.0"
            or origin.get("artifact_kind")
            != "p06_persisted_non_ash_reconstruction_proof_origin"
            or origin.get("identity") != bindings.control_identity
            or bindings.control_identity.get("artifact_kind")
            != "p06_persisted_non_ash_reconstruction_proof_identity"
            or origin.get("identity_sha256") != identity_sha256
            or origin.get("control_request") != bindings.control_request
            or origin.get("cache_token") != bindings.cache_token
            or origin.get("cache_origin_manifest_sha256")
            != bindings.cache_origin_manifest_sha256
            or origin.get("rule_configuration") != bindings.rule_configuration
            or origin.get("rule_sha256") != bindings.rule_sha256
            or not _is_sha256(origin.get("output_nv12_sha256"))
            or not isinstance(origin.get("output_size_bytes"), int)
            or isinstance(origin.get("output_size_bytes"), bool)
            or int(origin["output_size_bytes"]) <= 0
            or not _is_sha256(origin.get("output_frame_sha256"))
            or not isinstance(specialized, dict)
            or not isinstance(base, dict)
            or not isinstance(proof, dict)
            or not _is_sha256(declared)
            or declared != canonical_sha256(unhashed)
        ):
            raise NativeAdapterError(
                "persisted non-ASH reconstruction proof origin is invalid"
            )
        specialized_unhashed = dict(specialized)
        specialized_declared = specialized_unhashed.pop("record_sha256", None)
        base_unhashed = dict(base)
        base_declared = base_unhashed.pop("record_sha256", None)
        proof_unhashed = dict(proof)
        proof_declared = proof_unhashed.pop("proof_sha256", None)
        request = bindings.control_request
        parameters = request.get("parameters")
        if (
            set(proof) != proof_fields
            or proof.get("schema_version") != "1.0.0"
            or proof.get("artifact_kind")
            != "p06_non_ash_reconstruction_origin_proof"
            or set(specialized) != specialized_fields
            or specialized.get("schema_version") != "1.0.0"
            or specialized.get("artifact_kind")
            != "p06_native_non_ash_cached_reconstruction"
            or specialized.get("stateful_lut_lookup_count") != 0
            or specialized.get("spatial_operator_recompute_count") != 0
            or specialized.get("analysis_grid_invocation_count") != 0
            or set(base) != base_fields
            or specialized_declared != canonical_sha256(specialized_unhashed)
            or base_declared != canonical_sha256(base_unhashed)
            or proof_declared != canonical_sha256(proof_unhashed)
            or specialized.get("cache_token") != bindings.cache_token
            or specialized.get("cache_manifest_sha256") != bindings.cache_token
            or specialized.get("rule_configuration")
            != bindings.rule_configuration
            or specialized.get("rule_sha256") != bindings.rule_sha256
            or specialized.get("target_route") != bindings.manifest.get("route")
            or specialized.get("p07_sample_binding")
            != bindings.control_identity.get("p07_sample_binding")
            or specialized.get("p07_analytic_binding")
            != bindings.control_identity.get("p07_analytic_binding")
            or specialized.get("output_frame_sha256")
            != origin["output_frame_sha256"]
            or base.get("control_key") != request.get("control_key")
            or base.get("control_mode") != request.get("control_mode")
            or base.get("request_sha256") != request.get("request_sha256")
            or base.get("configuration_sha256")
            != request.get("configuration_sha256")
            or base.get("shared_bank_configuration_sha256")
            != request.get("shared_bank_configuration_sha256")
            or base.get("input_frame_sha256")
            != bindings.control_identity.get("input_frame_sha256")
            or base.get("output_frame_sha256")
            != origin["output_frame_sha256"]
            or base.get("target_route") != bindings.manifest.get("route")
            or base.get("parameters") != parameters
            or base.get("parameters_sha256") != canonical_sha256(parameters)
            or base.get("non_ash_cache_record_sha256")
            != specialized_declared
            or base.get("p07_sample_binding")
            != bindings.control_identity.get("p07_sample_binding")
            or base.get("p07_analytic_binding")
            != bindings.control_identity.get("p07_analytic_binding")
            or proof.get("identity_sha256") != identity_sha256
            or proof.get("control_request_sha256")
            != request.get("request_sha256")
            or proof.get("cache_token") != bindings.cache_token
            or proof.get("cache_origin_manifest_sha256")
            != bindings.cache_origin_manifest_sha256
            or proof.get("rule_sha256") != bindings.rule_sha256
            or proof.get("input_frame_sha256")
            != bindings.control_identity.get("input_frame_sha256")
            or proof.get("input_nv12_sha256")
            != bindings.control_identity.get("input_nv12_sha256")
            or proof.get("output_frame_sha256")
            != origin["output_frame_sha256"]
            or proof.get("output_nv12_sha256")
            != origin["output_nv12_sha256"]
            or proof.get("origin_native_non_ash_cache_record_sha256")
            != specialized_declared
            or proof.get("origin_native_control_record_sha256") != base_declared
        ):
            raise NativeAdapterError(
                "persisted non-ASH reconstruction proof binding differs"
            )

    def reconstruct_fixed_cached(
        self,
        cache_token: str,
        descriptor_id: int,
    ) -> PlanarFrame:
        self._verify_native_cache_root()
        manifest = self._non_ash_cache_manifests.get(cache_token)
        if manifest is None or not _is_sha256(cache_token):
            raise NativeAdapterError("unknown fixed cache token")
        if (
            not isinstance(descriptor_id, int)
            or isinstance(descriptor_id, bool)
            or descriptor_id not in range(16)
        ):
            raise NativeAdapterError("cached fixed descriptor is outside 0...15")
        dimensions = manifest["dimensions"]
        assert isinstance(dimensions, dict)
        output_luma = dimensions["output_luma"]
        assert isinstance(output_luma, list)
        output_height, output_width = (int(value) for value in output_luma)
        invocation_root = self.failure_root.parent / "non-ash-cache-invocations"
        _ensure_directory(invocation_root)
        with tempfile.TemporaryDirectory(dir=invocation_root) as temporary:
            output_path = Path(temporary) / "output.nv12"
            request = {
                "schema_version": "1.0.0",
                "operation": "reconstruct_fixed_cached",
                "cache_token": cache_token,
                "descriptor_id": descriptor_id,
                "output_path": str(output_path),
            }
            response = self.session.reconstruct_fixed_cached(request)
            reconstruction = response["cached_reconstruction"]
            assert isinstance(reconstruction, dict)
            output_payload = _read_regular(output_path)
            record = self._validate_cached_reconstruction(
                reconstruction,
                output_payload=output_payload,
                output_width=output_width,
                output_height=output_height,
                expected_artifact_kind="p06_native_fixed_cached_reconstruction",
                expected_fields={
                    "schema_version",
                    "artifact_kind",
                    "cache_token",
                    "cache_manifest_sha256",
                    "descriptor_id",
                    "shared_bank_configuration_sha256",
                    "input_frame_sha256",
                    "output_frame_sha256",
                    "target_route",
                    "control_request",
                    "stateful_lut_lookup_count",
                    "spatial_operator_recompute_count",
                    "analysis_grid_invocation_count",
                    "record_sha256",
                },
            )
            expected_control = self._fixed_control_request(
                descriptor_id,
                str(manifest["bank_id"]),
            )
            descriptor_outputs = manifest["descriptor_outputs"]
            assert isinstance(descriptor_outputs, list)
            expected_output_hash = descriptor_outputs[descriptor_id]["output_frame_sha256"]
            if (
                record.get("cache_token") != cache_token
                or record.get("cache_manifest_sha256") != cache_token
                or record.get("descriptor_id") != descriptor_id
                or record.get("shared_bank_configuration_sha256") != manifest["bank_id"]
                or record.get("input_frame_sha256") != manifest["input_frame_sha256"]
                or record.get("output_frame_sha256") != expected_output_hash
                or record.get("target_route") != manifest["route"]
                or record.get("control_request") != expected_control
                or record.get("stateful_lut_lookup_count") != 0
                or record.get("spatial_operator_recompute_count") != 0
                or record.get("analysis_grid_invocation_count") != 0
            ):
                raise NativeAdapterError("cached fixed record binding differs")
            record = self._attach_p07_sample_binding(record)
            self._fixed_cache_records.append(record)
            parameters = expected_control["parameters"]
            assert isinstance(parameters, dict)
            control_record: dict[str, object] = {
                "control_key": expected_control["control_key"],
                "control_mode": "fixed_descriptor_uniform",
                "request_sha256": expected_control["request_sha256"],
                "configuration_sha256": expected_control["configuration_sha256"],
                "shared_bank_configuration_sha256": expected_control[
                    "shared_bank_configuration_sha256"
                ],
                "input_frame_sha256": manifest["input_frame_sha256"],
                "output_frame_sha256": record["output_frame_sha256"],
                "target_route": manifest["route"],
                "parameters": dict(parameters),
                "parameters_sha256": canonical_sha256(parameters),
                "fixed_cache_record_sha256": record["record_sha256"],
            }
            control_record = self._attach_p07_sample_binding(control_record)
            cache_root = self._non_ash_cache_roots[cache_token]
            cache_origin = _parse_json(
                _read_regular(cache_root / "origin.json"),
                trailing_newline=False,
            )
            cache_identity = cache_origin["identity"]
            assert isinstance(cache_identity, dict)
            control_identity = self._control_cache_identity(
                request=expected_control,
                input_frame_sha256=str(manifest["input_frame_sha256"]),
                input_nv12_sha256=str(cache_identity["input_nv12_sha256"]),
                route=str(manifest["route"]),
                input_luma_dimensions=cache_identity["input_luma_dimensions"],
                input_chroma_dimensions=cache_identity["input_chroma_dimensions"],
                output_luma_dimensions=cache_identity["output_luma_dimensions"],
                output_chroma_dimensions=cache_identity["output_chroma_dimensions"],
            )
            control_cache_reused = _path_entry_exists(self._control_output_cache_origin_path(
                expected_control,
                control_identity,
            ))
            control_origin = self._publish_control_output_cache(
                request=expected_control,
                identity=control_identity,
                output_payload=output_payload,
                output_frame_sha256=str(record["output_frame_sha256"]),
                base_control_record=control_record,
            )
            control_record = self._decorated_control_cache_record(
                control_origin,
                reused=control_cache_reused,
                current_analysis_count=0,
                current_operator_count=0,
                base_record_override=control_record,
            )
            self._control_records.append(control_record)
            return _video_range_nv12_to_planar(
                output_payload,
                width=output_width,
                height=output_height,
            )

    def non_ash_cache_records(self) -> Tuple[dict[str, object], ...]:
        return tuple(json.loads(canonical_json_bytes(record)) for record in self._non_ash_cache_records)

    def non_ash_cache_records_count(self) -> int:
        return len(self._non_ash_cache_records)

    def non_ash_cache_records_record(self, index: int) -> Mapping[str, object]:
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or index not in range(len(self._non_ash_cache_records))
        ):
            raise NativeAdapterError("non-ASH cache record index is invalid")
        return json.loads(canonical_json_bytes(self._non_ash_cache_records[index]))

    def non_ash_cache_preparation_records(self) -> Tuple[dict[str, object], ...]:
        return tuple(
            json.loads(canonical_json_bytes(record))
            for record in self._non_ash_cache_preparation_records
        )

    def non_ash_cache_preparation_records_count(self) -> int:
        return len(self._non_ash_cache_preparation_records)

    def non_ash_cache_preparation_records_record(
        self,
        index: int,
    ) -> Mapping[str, object]:
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or index not in range(len(self._non_ash_cache_preparation_records))
        ):
            raise NativeAdapterError("non-ASH preparation record index is invalid")
        return json.loads(
            canonical_json_bytes(self._non_ash_cache_preparation_records[index])
        )

    def fixed_cache_records(self) -> Tuple[dict[str, object], ...]:
        return tuple(json.loads(canonical_json_bytes(record)) for record in self._fixed_cache_records)

    def fixed_cache_records_count(self) -> int:
        return len(self._fixed_cache_records)

    def fixed_cache_records_record(self, index: int) -> Mapping[str, object]:
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or index not in range(len(self._fixed_cache_records))
        ):
            raise NativeAdapterError("fixed cache record index is invalid")
        return json.loads(canonical_json_bytes(self._fixed_cache_records[index]))

    @staticmethod
    def _non_ash_control_request(
        rule: Mapping[str, object],
        bank_id: str,
    ) -> Mapping[str, object]:
        canonical_rule = {name: int(rule[name]) for name in _NON_ASH_RULE_COORDINATES}
        rule_sha256 = canonical_sha256(canonical_rule)
        configuration_sha256 = canonical_sha256(
            {
                "rule_sha256": rule_sha256,
                "selector_id": "continuous-linear-bank-selector-q15-v1",
                "shared_bank_configuration_sha256": bank_id,
            }
        )
        request: dict[str, object] = {
            "schema_version": "1.0.0",
            "operation": "reconstruct_control",
            "control_key": "non_ash_selector",
            "control_mode": "non_ash_selector_q15",
            "configuration_sha256": configuration_sha256,
            "shared_bank_configuration_sha256": bank_id,
            "parameters": {
                "selector_id": "continuous-linear-bank-selector-q15-v1",
                "selected_rule_sha256": rule_sha256,
                "selected_rule_configuration": canonical_rule,
            },
        }
        request["request_sha256"] = canonical_sha256(request)
        return request

    def _control_cache_identity(
        self,
        *,
        request: Mapping[str, object],
        input_frame_sha256: str,
        input_nv12_sha256: str,
        route: str,
        input_luma_dimensions: Sequence[int],
        input_chroma_dimensions: Sequence[int],
        output_luma_dimensions: Sequence[int],
        output_chroma_dimensions: Sequence[int],
        non_ash_cache_token: str | None = None,
        non_ash_cache_origin_manifest_sha256: str | None = None,
    ) -> dict[str, object]:
        if (non_ash_cache_token is None) != (
            non_ash_cache_origin_manifest_sha256 is None
        ) or (
            non_ash_cache_token is not None
            and (
                not _is_sha256(non_ash_cache_token)
                or not _is_sha256(non_ash_cache_origin_manifest_sha256)
            )
        ):
            raise NativeAdapterError("specialized control cache binding is invalid")
        identity = {
            "schema_version": "1.0.0",
            "artifact_kind": (
                "p06_persisted_non_ash_reconstruction_proof_identity"
                if non_ash_cache_token is not None
                else "p06_persisted_control_output_identity"
            ),
            "split": self.split,
            "native_executable_sha256": self.session.configuration.configuration[
                "swift_cli"
            ]["executable_sha256"],
            "native_source_manifest_sha256": self.session.configuration.configuration[
                "swift_cli"
            ]["source_manifest_sha256"],
            "shared_bank_configuration_sha256": request[
                "shared_bank_configuration_sha256"
            ],
            "control_request_sha256": request["request_sha256"],
            "control_configuration_sha256": request["configuration_sha256"],
            "control_mode": request["control_mode"],
            "input_frame_sha256": input_frame_sha256,
            "input_nv12_sha256": input_nv12_sha256,
            "route": route,
            "input_luma_dimensions": list(input_luma_dimensions),
            "input_chroma_dimensions": list(input_chroma_dimensions),
            "output_luma_dimensions": list(output_luma_dimensions),
            "output_chroma_dimensions": list(output_chroma_dimensions),
        }
        if non_ash_cache_token is not None:
            identity["non_ash_cache_token"] = non_ash_cache_token
            identity["non_ash_cache_origin_manifest_sha256"] = (
                non_ash_cache_origin_manifest_sha256
            )
        p07_binding = self._required_p07_sample_binding()
        if p07_binding is not None:
            identity["p07_sample_binding"] = p07_binding
        if self._p07_analytic_binding is not None:
            identity["p07_analytic_binding"] = dict(
                self._p07_analytic_binding
            )
        return identity

    def _publish_control_output_cache(
        self,
        *,
        request: Mapping[str, object],
        identity: Mapping[str, object],
        output_payload: bytes,
        output_frame_sha256: str,
        base_control_record: Mapping[str, object],
    ) -> Mapping[str, object]:
        identity_sha256 = canonical_sha256(identity)
        root = (
            self.failure_root.parent
            / "control-output-cache-v1"
            / self.split
            / str(request["shared_bank_configuration_sha256"])
            / identity_sha256
        )
        self._prepare_deferred_control_cache_directory(root)
        output_nv12_sha256 = _sha256(output_payload)
        output_filename = f"output-{output_nv12_sha256}.nv12"
        self._write_or_verify_deferred_control_cache(
            root / output_filename,
            output_payload,
            role="payload",
        )
        origin_path = root / "origin.json"
        if _path_entry_exists(origin_path):
            origin_payload = _read_regular(origin_path)
            origin = _parse_json(origin_payload, trailing_newline=False)
            self._validate_control_cache_origin(
                origin,
                identity=identity,
                identity_sha256=identity_sha256,
                root=root,
            )
            if (
                origin["control_request"] != request
                or origin["output_nv12_sha256"] != output_nv12_sha256
                or origin["output_frame_sha256"] != output_frame_sha256
            ):
                raise NativeAdapterError("persisted control output changed")
            self._write_or_verify_deferred_control_cache(
                origin_path,
                origin_payload,
                role="origin",
            )
            return origin
        base_record = json.loads(canonical_json_bytes(base_control_record))
        if base_record.get("record_sha256") != canonical_sha256(
            {key: value for key, value in base_record.items() if key != "record_sha256"}
        ):
            raise NativeAdapterError("control cache origin record is not self-hashed")
        proof: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_control_output_cache_origin_proof",
            "identity_sha256": identity_sha256,
            "control_request_sha256": request["request_sha256"],
            "input_frame_sha256": identity["input_frame_sha256"],
            "input_nv12_sha256": identity["input_nv12_sha256"],
            "output_frame_sha256": output_frame_sha256,
            "output_nv12_sha256": output_nv12_sha256,
            "origin_native_control_record_sha256": base_record["record_sha256"],
        }
        proof["proof_sha256"] = canonical_sha256(proof)
        origin_document: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_persisted_control_output_origin",
            "identity": dict(identity),
            "identity_sha256": identity_sha256,
            "control_request": dict(request),
            "output_filename": output_filename,
            "output_nv12_sha256": output_nv12_sha256,
            "output_size_bytes": len(output_payload),
            "output_frame_sha256": output_frame_sha256,
            "origin_native_control_record": base_record,
            "origin_proof": proof,
        }
        origin_document["origin_manifest_sha256"] = canonical_sha256(origin_document)
        self._stage_deferred_cache_origin(
            origin_path,
            canonical_json_bytes(origin_document),
            role="origin",
        )
        staged_origin_payload = self._pending_or_persisted_cache_payload(origin_path)
        assert staged_origin_payload is not None
        reopened = _parse_json(staged_origin_payload, trailing_newline=False)
        self._validate_control_cache_origin(
            reopened,
            identity=identity,
            identity_sha256=identity_sha256,
            root=root,
        )
        if reopened.get("control_request") != request:
            raise NativeAdapterError("published control request differs")
        return reopened

    def _pending_or_persisted_cache_payload(self, path: Path) -> bytes | None:
        binding = self._pending_control_cache_files.get(path)
        if binding is not None and binding[3] is not None:
            return _read_regular(binding[3])
        if _path_entry_exists(path):
            return _read_regular(path)
        return None

    def _queue_verified_cache_file(
        self,
        path: Path,
        payload: bytes,
        *,
        role: str,
    ) -> None:
        if role not in {"payload", "dependency_origin", "origin"}:
            raise NativeAdapterError("deferred cache file role is invalid")
        if _read_regular(path) != payload:
            raise NativeAdapterError(f"cached immutable file differs: {path}")
        self._pending_control_cache_files[path] = (
            _sha256(payload),
            len(payload),
            role,
            None,
        )
        self._pending_control_cache_directories.add(path.parent)

    def _stage_deferred_cache_origin(
        self,
        path: Path,
        payload: bytes,
        *,
        role: str,
    ) -> None:
        if role != "origin":
            raise NativeAdapterError("staged cache file role is invalid")
        existing_binding = self._pending_control_cache_files.get(path)
        if existing_binding is not None:
            if (
                existing_binding[:3] != (_sha256(payload), len(payload), role)
                or existing_binding[3] is None
                or _read_regular(existing_binding[3]) != payload
            ):
                raise NativeAdapterError(f"staged immutable file differs: {path}")
            return
        absolute = _absolute_lexical_path(path)
        parent = _open_directory_descriptor(absolute.parent, create=True)
        staged_prefix = f".{absolute.name}.mirmir-staged-"
        try:
            _cleanup_interrupted_publications_at(
                parent,
                temporary_prefix=staged_prefix,
                display_parent=absolute.parent,
            )
        finally:
            os.close(parent)
        if _path_entry_exists(path):
            if _read_regular(path) != payload:
                raise NativeAdapterError(f"cached immutable file differs: {path}")
            self._queue_verified_cache_file(path, payload, role=role)
            return
        staged_path = absolute.parent / (staged_prefix + uuid.uuid4().hex)
        staged_parent = _open_directory_descriptor(absolute.parent, create=False)
        descriptor = os.open(
            staged_path.name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=staged_parent,
        )
        completed = False
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise OSError("staged publication made no progress")
                offset += written
            completed = True
        finally:
            os.close(descriptor)
            if not completed:
                try:
                    os.unlink(staged_path.name, dir_fd=staged_parent)
                except FileNotFoundError:
                    pass
            os.close(staged_parent)
        if _read_regular(staged_path) != payload:
            raise NativeAdapterError(f"staged immutable file differs: {path}")
        self._pending_control_cache_files[path] = (
            _sha256(payload),
            len(payload),
            role,
            staged_path,
        )
        self._pending_control_cache_directories.add(path.parent)

    @staticmethod
    def _remove_uncommitted_payload(path: Path) -> None:
        absolute = _absolute_lexical_path(path)
        parent = _open_directory_descriptor(absolute.parent, create=False)
        try:
            try:
                os.stat("origin.json", dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise NativeAdapterError(
                    f"committed cache payload differs: {absolute}"
                )
            metadata = os.stat(
                absolute.name,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise NativeAdapterError(
                    f"uncommitted cache payload is not regular: {absolute}"
                )
            os.unlink(absolute.name, dir_fd=parent)
        finally:
            os.close(parent)

    def _write_or_verify_deferred_control_cache(
        self,
        path: Path,
        payload: bytes,
        *,
        role: str,
    ) -> None:
        if role not in {"payload", "dependency_origin", "origin"}:
            raise NativeAdapterError("deferred cache file role is invalid")
        _cleanup_interrupted_publications(path)
        if _path_entry_exists(path):
            if _read_regular(path) != payload:
                if role != "payload":
                    raise NativeAdapterError(f"cached immutable file differs: {path}")
                self._remove_uncommitted_payload(path)
                _write_new_deferred(path, payload)
        else:
            _write_new_deferred(path, payload)
        self._pending_control_cache_files[path] = (
            _sha256(payload),
            len(payload),
            role,
            None,
        )
        self._pending_control_cache_directories.add(path.parent)
        if _read_regular(path) != payload:
            raise NativeAdapterError(
                f"deferred control-cache publication differs after reopen: {path}"
            )

    def _prepare_deferred_control_cache_directory(self, root: Path) -> None:
        cache_root = self.failure_root.parent / "control-output-cache-v1"
        self._prepare_deferred_cache_directory(root, cache_root=cache_root)

    def _prepare_deferred_cache_directory(
        self,
        root: Path,
        *,
        cache_root: Path,
    ) -> None:
        split_root = cache_root / self.split
        if root.parent.parent != split_root:
            raise NativeAdapterError("control-cache directory chain differs")
        directories = (
            cache_root,
            split_root,
            root.parent,
            root,
        )
        _ensure_directory(root)
        for path in directories:
            self._pending_control_cache_directories.add(path)
            self._pending_control_cache_directories.add(path.parent)

    def flush_control_cache_durability(self) -> Mapping[str, object]:
        """Commit queued cache files in dependency order and return its proof."""

        self._verify_native_cache_root()
        pending_files = sorted(
            self._pending_control_cache_files.items(),
            key=lambda item: (
                {
                    "payload": 0,
                    "dependency_origin": 1,
                    "origin": 2,
                }[item[1][2]],
                str(item[0]),
            ),
        )
        pending_directories = sorted(
            self._pending_control_cache_directories,
            key=lambda value: (len(value.parts), str(value)),
            reverse=True,
        )
        ordered_file_bindings: list[dict[str, object]] = []
        for path, binding in pending_files:
            expected_sha256, expected_size, role, staged_path = binding
            absolute = _absolute_lexical_path(path)
            source = _absolute_lexical_path(staged_path or path)
            if source.parent != absolute.parent:
                raise NativeAdapterError(
                    f"staged cache file escaped its final directory: {path}"
                )
            parent = _open_directory_descriptor(source.parent, create=False)
            try:
                before = os.stat(
                    source.name,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
                if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
                    raise NativeAdapterError(
                        f"deferred control-cache file is not regular: {path}"
                    )
                descriptor = os.open(
                    source.name,
                    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=parent,
                )
                try:
                    opened = os.fstat(descriptor)
                    if (
                        (opened.st_dev, opened.st_ino)
                        != (before.st_dev, before.st_ino)
                        or not stat.S_ISREG(opened.st_mode)
                    ):
                        raise NativeAdapterError(
                            "deferred control-cache file changed while opening: "
                            f"{path}"
                        )
                    digest = hashlib.sha256()
                    size = 0
                    while True:
                        chunk = os.read(descriptor, 1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                        size += len(chunk)
                    if digest.hexdigest() != expected_sha256 or size != expected_size:
                        raise NativeAdapterError(
                            f"deferred control-cache file binding differs: {path}"
                        )
                    os.fsync(descriptor)
                    after = os.fstat(descriptor)
                    if (
                        (after.st_dev, after.st_ino)
                        != (opened.st_dev, opened.st_ino)
                        or after.st_size != opened.st_size
                        or after.st_mtime_ns != opened.st_mtime_ns
                    ):
                        raise NativeAdapterError(
                            f"deferred control-cache file changed while syncing: {path}"
                        )
                    if staged_path is not None:
                        try:
                            os.link(
                                source.name,
                                absolute.name,
                                src_dir_fd=parent,
                                dst_dir_fd=parent,
                                follow_symlinks=False,
                            )
                        except FileExistsError:
                            if _read_regular_at(
                                parent,
                                absolute.name,
                                display_path=absolute,
                            ) != _read_regular_at(
                                parent,
                                source.name,
                                display_path=source,
                            ):
                                raise NativeAdapterError(
                                    f"staged cache final differs: {path}"
                                )
                            final_descriptor = os.open(
                                absolute.name,
                                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                                dir_fd=parent,
                            )
                            try:
                                os.fsync(final_descriptor)
                            finally:
                                os.close(final_descriptor)
                        os.unlink(source.name, dir_fd=parent)
                        self._pending_control_cache_files[path] = (
                            expected_sha256,
                            expected_size,
                            role,
                            None,
                        )
                finally:
                    os.close(descriptor)
            finally:
                os.close(parent)
            ordered_file_bindings.append(
                {
                    "path": str(absolute),
                    "role": role,
                    "sha256": expected_sha256,
                    "size_bytes": expected_size,
                }
            )
        ordered_directory_identities: list[dict[str, object]] = []
        for path in pending_directories:
            descriptor = _open_directory_descriptor(path, create=False)
            try:
                opened = os.fstat(descriptor)
                if not stat.S_ISDIR(opened.st_mode):
                    raise NativeAdapterError(
                        f"deferred control-cache directory is invalid: {path}"
                    )
                os.fsync(descriptor)
                after = os.fstat(descriptor)
                if (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino):
                    raise NativeAdapterError(
                        f"deferred control-cache directory changed while syncing: {path}"
                    )
                ordered_directory_identities.append(
                    {
                        "path": str(_absolute_lexical_path(path)),
                        "device": int(opened.st_dev),
                        "inode": int(opened.st_ino),
                    }
                )
            finally:
                os.close(descriptor)
        configuration = self.session.configuration.configuration
        record: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_control_cache_durability_commit",
            "split": self.split,
            "requesting_configuration_id": configuration["configuration_id"],
            "shared_bank_configuration_sha256": configuration[
                "shared_bank_configuration_sha256"
            ],
            "native_executable_sha256": configuration["swift_cli"][
                "executable_sha256"
            ],
            "native_source_manifest_sha256": configuration["swift_cli"][
                "source_manifest_sha256"
            ],
            "pending_file_count": len(pending_files),
            "pending_directory_count": len(pending_directories),
            "ordered_file_bindings_sha256": canonical_sha256(
                ordered_file_bindings
            ),
            "ordered_directory_identities_sha256": canonical_sha256(
                ordered_directory_identities
            ),
            "committed": True,
        }
        record["record_sha256"] = canonical_sha256(record)
        self._pending_control_cache_files.clear()
        self._pending_control_cache_directories.clear()
        return json.loads(canonical_json_bytes(record))

    def _flush_deferred_control_cache_durability(self) -> None:
        self.flush_control_cache_durability()

    def _control_output_cache_origin_path(
        self,
        request: Mapping[str, object],
        identity: Mapping[str, object],
    ) -> Path:
        return (
            self.failure_root.parent
            / "control-output-cache-v1"
            / self.split
            / str(request["shared_bank_configuration_sha256"])
            / canonical_sha256(identity)
            / "origin.json"
        )

    @staticmethod
    def _validate_control_cache_origin(
        origin: Mapping[str, object],
        *,
        identity: Mapping[str, object],
        identity_sha256: str,
        root: Path,
    ) -> bytes:
        fields = {
            "schema_version",
            "artifact_kind",
            "identity",
            "identity_sha256",
            "control_request",
            "output_filename",
            "output_nv12_sha256",
            "output_size_bytes",
            "output_frame_sha256",
            "origin_native_control_record",
            "origin_proof",
            "origin_manifest_sha256",
        }
        unhashed = dict(origin)
        declared = unhashed.pop("origin_manifest_sha256", None)
        output_sha256 = origin.get("output_nv12_sha256")
        output_filename = origin.get("output_filename")
        base_record = origin.get("origin_native_control_record")
        proof = origin.get("origin_proof")
        request = origin.get("control_request")
        request_fields = {
            "schema_version",
            "operation",
            "control_key",
            "control_mode",
            "configuration_sha256",
            "shared_bank_configuration_sha256",
            "parameters",
            "request_sha256",
        }
        proof_fields = {
            "schema_version",
            "artifact_kind",
            "identity_sha256",
            "control_request_sha256",
            "input_frame_sha256",
            "input_nv12_sha256",
            "output_frame_sha256",
            "output_nv12_sha256",
            "origin_native_control_record_sha256",
            "proof_sha256",
        }
        if (
            set(origin) != fields
            or origin.get("schema_version") != "1.0.0"
            or origin.get("artifact_kind") != "p06_persisted_control_output_origin"
            or origin.get("identity") != identity
            or origin.get("identity_sha256") != identity_sha256
            or identity_sha256 != canonical_sha256(identity)
            or not isinstance(request, dict)
            or set(request) != request_fields
            or request.get("schema_version") != "1.0.0"
            or request.get("operation") != "reconstruct_control"
            or request.get("request_sha256")
            != canonical_sha256(
                {key: value for key, value in request.items() if key != "request_sha256"}
            )
            or request.get("request_sha256")
            != identity.get("control_request_sha256")
            or request.get("configuration_sha256")
            != identity.get("control_configuration_sha256")
            or request.get("control_mode") != identity.get("control_mode")
            or request.get("shared_bank_configuration_sha256")
            != identity.get("shared_bank_configuration_sha256")
            or not _is_sha256(output_sha256)
            or output_filename != f"output-{output_sha256}.nv12"
            or not isinstance(origin.get("output_size_bytes"), int)
            or isinstance(origin.get("output_size_bytes"), bool)
            or int(origin["output_size_bytes"]) <= 0
            or not _is_sha256(origin.get("output_frame_sha256"))
            or not isinstance(base_record, dict)
            or not isinstance(proof, dict)
            or set(proof) != proof_fields
            or proof.get("schema_version") != "1.0.0"
            or proof.get("artifact_kind")
            != "p06_control_output_cache_origin_proof"
            or not _is_sha256(declared)
            or declared != canonical_sha256(unhashed)
        ):
            raise NativeAdapterError("persisted control cache origin is invalid")
        base_unhashed = dict(base_record)
        base_declared = base_unhashed.pop("record_sha256", None)
        proof_unhashed = dict(proof)
        proof_declared = proof_unhashed.pop("proof_sha256", None)
        parameters = request.get("parameters")
        if (
            base_declared != canonical_sha256(base_unhashed)
            or proof_declared != canonical_sha256(proof_unhashed)
            or proof.get("identity_sha256") != identity_sha256
            or proof.get("control_request_sha256")
            != request["request_sha256"]
            or proof.get("input_frame_sha256")
            != identity.get("input_frame_sha256")
            or proof.get("input_nv12_sha256")
            != identity.get("input_nv12_sha256")
            or proof.get("output_frame_sha256") != origin["output_frame_sha256"]
            or proof.get("output_nv12_sha256") != output_sha256
            or proof.get("origin_native_control_record_sha256") != base_declared
            or base_record.get("control_key") != request.get("control_key")
            or base_record.get("control_mode") != request.get("control_mode")
            or base_record.get("request_sha256") != request.get("request_sha256")
            or base_record.get("configuration_sha256")
            != request.get("configuration_sha256")
            or base_record.get("shared_bank_configuration_sha256")
            != request.get("shared_bank_configuration_sha256")
            or base_record.get("input_frame_sha256")
            != identity.get("input_frame_sha256")
            or base_record.get("output_frame_sha256")
            != origin.get("output_frame_sha256")
            or base_record.get("target_route") != identity.get("route")
            or base_record.get("parameters") != parameters
            or base_record.get("parameters_sha256") != canonical_sha256(parameters)
        ):
            raise NativeAdapterError("persisted control cache proof differs")
        output = _read_regular(root / str(output_filename))
        if _sha256(output) != output_sha256 or len(output) != origin["output_size_bytes"]:
            raise NativeAdapterError("persisted control cache output bytes differ")
        return output

    @staticmethod
    def _decorated_control_cache_record(
        origin: Mapping[str, object],
        *,
        reused: bool,
        current_analysis_count: int,
        current_operator_count: int,
        base_record_override: Mapping[str, object] | None = None,
    ) -> dict[str, object]:
        base = (
            base_record_override
            if base_record_override is not None
            else origin["origin_native_control_record"]
        )
        proof = origin["origin_proof"]
        assert isinstance(base, dict)
        assert isinstance(proof, dict)
        record = {key: value for key, value in base.items() if key != "record_sha256"}
        record.update(
            {
                "control_cache_reused": reused,
                "control_cache_origin_manifest_sha256": origin[
                    "origin_manifest_sha256"
                ],
                "control_cache_origin_proof_sha256": proof["proof_sha256"],
                "current_call_analysis_grid_invocation_count": current_analysis_count,
                "current_call_spatial_operator_evaluation_count": current_operator_count,
            }
        )
        record["record_sha256"] = canonical_sha256(record)
        return json.loads(canonical_json_bytes(record))

    def _reopen_control_output_cache(
        self,
        *,
        request: Mapping[str, object],
        identity: Mapping[str, object],
        context: CandidateContext,
    ) -> PlanarFrame | None:
        identity_sha256 = canonical_sha256(identity)
        root = (
            self.failure_root.parent
            / "control-output-cache-v1"
            / self.split
            / str(request["shared_bank_configuration_sha256"])
            / identity_sha256
        )
        origin_path = root / "origin.json"
        origin_payload = self._pending_or_persisted_cache_payload(origin_path)
        if origin_payload is None:
            return None
        origin = _parse_json(origin_payload, trailing_newline=False)
        output_payload = self._validate_control_cache_origin(
            origin,
            identity=identity,
            identity_sha256=identity_sha256,
            root=root,
        )
        if origin.get("control_request") != request:
            raise NativeAdapterError("persisted control request differs")
        self._prepare_deferred_control_cache_directory(root)
        self._write_or_verify_deferred_control_cache(
            root / str(origin["output_filename"]),
            output_payload,
            role="payload",
        )
        if _path_entry_exists(origin_path):
            self._queue_verified_cache_file(
                origin_path,
                origin_payload,
                role="origin",
            )
        output = _video_range_nv12_to_planar(
            output_payload,
            width=context.y_shape[1],
            height=context.y_shape[0],
        )
        if frame_sha256(output) != origin["output_frame_sha256"]:
            raise NativeAdapterError("persisted control frame hash differs")
        self._control_records.append(
            self._decorated_control_cache_record(
                origin,
                reused=True,
                current_analysis_count=0,
                current_operator_count=0,
            )
        )
        return output

    def reconstruct_control(
        self,
        request: Mapping[str, object],
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        self._verify_native_cache_root()
        self._validate_control_request(request)
        self._validate_geometry(frame, context)
        invocation_root = self.failure_root.parent / "control-invocations"
        _ensure_directory(invocation_root)
        configuration = self.session.configuration.configuration
        payload = _planar_to_video_range_nv12(frame)
        input_frame_hash = frame_sha256(frame)
        control_cache_identity = self._control_cache_identity(
            request=request,
            input_frame_sha256=input_frame_hash,
            input_nv12_sha256=_sha256(payload),
            route=context.target_route,
            input_luma_dimensions=frame.y.shape,
            input_chroma_dimensions=frame.cb.shape,
            output_luma_dimensions=context.y_shape,
            output_chroma_dimensions=context.cb_shape,
        )
        if request["control_mode"] in _PERSISTED_CONTROL_MODES:
            reopened = self._reopen_control_output_cache(
                request=request,
                identity=control_cache_identity,
                context=context,
            )
            if reopened is not None:
                return reopened
        if request["control_mode"] == "p00_current_production_ash":
            return self._reconstruct_p00_control(
                request,
                frame,
                context,
                control_cache_identity=control_cache_identity,
            )
        with tempfile.TemporaryDirectory(dir=invocation_root) as temporary:
            root = Path(temporary)
            input_path = root / "input.nv12"
            output_path = root / "output.nv12"
            _write_new(input_path, payload)
            native_frame = {
                "request_id": f"control-{len(self._control_records):08d}",
                "route": context.target_route,
                "input_path": str(input_path),
                "input_sha256": _sha256(payload),
                "input_width": frame.y.shape[1],
                "input_height": frame.y.shape[0],
                "output_path": str(output_path),
                "output_width": context.y_shape[1],
                "output_height": context.y_shape[0],
                "pixel_format": "420v",
                "matrix": "BT.709",
                "range": "video",
                "chroma_siting": "left",
            }
            native_request = {
                "schema_version": "1.0.0",
                "operation": "reconstruct_control",
                "control_request": dict(request),
                "frame": native_frame,
            }
            try:
                response = self.session.control(native_request)
                summary = response["control"]
                assert isinstance(summary, dict)
                output_payload = _read_regular(output_path)
                self._validate_control_summary(
                    summary,
                    request=request,
                    native_frame=native_frame,
                    input_payload=payload,
                    output_payload=output_payload,
                )
                output = _video_range_nv12_to_planar(
                    output_payload,
                    width=context.y_shape[1],
                    height=context.y_shape[0],
                )
                output_hash = frame_sha256(output)
                parameters = request["parameters"]
                assert isinstance(parameters, dict)
                record: dict[str, object] = {
                    "control_key": request["control_key"],
                    "control_mode": request["control_mode"],
                    "request_sha256": request["request_sha256"],
                    "configuration_sha256": request["configuration_sha256"],
                    "shared_bank_configuration_sha256": request[
                        "shared_bank_configuration_sha256"
                    ],
                    "input_frame_sha256": input_frame_hash,
                    "output_frame_sha256": output_hash,
                    "target_route": context.target_route,
                    "parameters": dict(parameters),
                    "parameters_sha256": canonical_sha256(parameters),
                }
                if request["control_mode"] in {"full_ash", "state_only"}:
                    locked_summary = summary.get("locked_runtime_summary")
                    assert isinstance(locked_summary, dict)
                    record["locked_runtime_summary"] = dict(locked_summary)
                elif request["control_mode"] == "h07_direct2x_then_lanczos3":
                    direct2_summary = summary.get("locked_runtime_summary")
                    assert isinstance(direct2_summary, dict)
                    record["h07_direct2_runtime_summary"] = dict(direct2_summary)
                    h07_summary = summary.get("h07_runtime_summary")
                    assert isinstance(h07_summary, dict)
                    record["h07_runtime_summary"] = dict(h07_summary)
                record = self._attach_p07_sample_binding(record)
                if request["control_mode"] in _PERSISTED_CONTROL_MODES:
                    origin = self._publish_control_output_cache(
                        request=request,
                        identity=control_cache_identity,
                        output_payload=output_payload,
                        output_frame_sha256=output_hash,
                        base_control_record=record,
                    )
                    record = self._decorated_control_cache_record(
                        origin,
                        reused=False,
                        current_analysis_count=(
                            1
                            if request["control_mode"]
                            in {"fixed_descriptor_uniform", "non_ash_selector_q15"}
                            else 0
                        ),
                        current_operator_count=1,
                    )
                self._control_records.append(record)
                return output
            except Exception as error:
                failure = {
                    "schema_version": "1.0.0",
                    "status": "failed",
                    "operation": "reconstruct_control",
                    "configuration_id": configuration["configuration_id"],
                    "native_request_sha256": canonical_sha256(native_request),
                    "control_request_sha256": request["request_sha256"],
                    "input_frame_sha256": input_frame_hash,
                    "input_nv12_sha256": _sha256(payload),
                    "error_type": type(error).__name__,
                    "message": str(error),
                }
                _ensure_directory(self.failure_root)
                failure_path = self.failure_root / f"control-{uuid.uuid4().hex}.json"
                _write_new(failure_path, canonical_json_bytes(failure) + b"\n")
                raise NativeAdapterError(str(error), failure_path) from error

    def control_runtime_records(self) -> Tuple[dict[str, object], ...]:
        return tuple(dict(record) for record in self._control_records)

    def control_runtime_records_count(self) -> int:
        return len(self._control_records)

    def control_runtime_records_record(self, index: int) -> Mapping[str, object]:
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or index not in range(len(self._control_records))
        ):
            raise NativeAdapterError("control runtime record index is invalid")
        return json.loads(canonical_json_bytes(self._control_records[index]))

    def p00_identity(self) -> Mapping[str, object]:
        return dict(self.p00_helper.executable.identity)

    def candidate_compiler_evidence(self) -> Mapping[str, object]:
        configuration = self.session.configuration.configuration
        compiler_document = configuration["compiler_input_document"]
        assert isinstance(compiler_document, dict)
        compiler_input = parse_locked_compiler_input(compiler_document)
        routes = []
        maximum_candidates = 0
        for target_route, oracle_name in (
            ("direct-2x", "direct_2x"),
            ("direct-3over2", "direct_3_over_2"),
        ):
            payload = _read_regular(
                self.session.configuration.route_paths[target_route]
            )
            oracle = state_conditioning_evidence(
                payload,
                expected_configuration=compiler_input,
                expected_route=ORACLE_ROUTES[oracle_name],
            )
            route_binding = configuration["route_luts"][target_route]
            if (
                oracle["whole_file_sha256"] != route_binding["whole_file_sha256"]
                or oracle["payload_sha256"] != route_binding["payload_sha256"]
            ):
                raise NativeAdapterError(
                    f"independent oracle route binding differs: {target_route}"
                )
            maximum_candidates = max(
                maximum_candidates,
                int(oracle["maximum_operator_evaluations"]),
            )
            routes.append(
                {
                    "target_route": target_route,
                    "lut_size_bytes": len(payload),
                    "lut_whole_file_sha256": _sha256(payload),
                    "lut_payload_sha256": oracle["payload_sha256"],
                    "state_conditioning_evidence": oracle,
                    "state_conditioning_evidence_sha256": canonical_sha256(oracle),
                }
            )
        document: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_candidate_compiler_evidence",
            "implementation_role": "production_swift",
            "configuration_id": configuration["configuration_id"],
            "candidate_vector_sha256": configuration[
                "serialized_candidate_vector_sha256"
            ],
            "compiler_inputs_sha256": configuration["compiler_inputs_sha256"],
            "compiler_input_document_file_sha256": _sha256(
                _read_regular(self.session.configuration.compiler_input_path)
            ),
            "candidate_lut_runtime_manifest_sha256": configuration[
                "candidate_lut_runtime_manifest_sha256"
            ],
            "native_executable_sha256": configuration["swift_cli"][
                "executable_sha256"
            ],
            "native_source_manifest_sha256": configuration["swift_cli"][
                "source_manifest_sha256"
            ],
            "routes": routes,
            "maximum_operator_evaluations": maximum_candidates,
            "holdout_accessed": False,
        }
        document["evidence_sha256"] = canonical_sha256(document)
        return json.loads(canonical_json_bytes(document))

    def _reconstruct_p00_control(
        self,
        request: Mapping[str, object],
        frame: PlanarFrame,
        context: CandidateContext,
        *,
        control_cache_identity: Mapping[str, object],
    ) -> PlanarFrame:
        self._validate_geometry(frame, context)
        parameters = request.get("parameters")
        expected_parameters = {
            "control_id": "p00-current-production-ash-baseline-v1",
            **dict(self.p00_helper.executable.identity),
            "p00_backend_reset_before_frame": True,
            "p00_prior_frame_count": 0,
        }
        if parameters != expected_parameters:
            raise NativeAdapterError("P00 request identity differs from pinned helper")
        input_hash = frame_sha256(frame)
        try:
            output, helper_summary = self.p00_helper.reconstruct(frame, context)
            compatibility_boundary = helper_summary.get(
                "p00_compatibility_boundary_normalization"
            )
            if not isinstance(compatibility_boundary, dict):
                raise NativeAdapterError(
                    "P00 helper lacks compatibility-boundary evidence"
                )
            output_hash = frame_sha256(output)
            record: dict[str, object] = {
                "control_key": request["control_key"],
                "control_mode": request["control_mode"],
                "request_sha256": request["request_sha256"],
                "configuration_sha256": request["configuration_sha256"],
                "shared_bank_configuration_sha256": request[
                    "shared_bank_configuration_sha256"
                ],
                "input_frame_sha256": input_hash,
                "output_frame_sha256": output_hash,
                "target_route": context.target_route,
                "parameters": dict(expected_parameters),
                "parameters_sha256": canonical_sha256(expected_parameters),
                "p00_commit": expected_parameters["commit"],
                "p00_backend_source_sha256": expected_parameters[
                    "backend_source_sha256"
                ],
                "p00_source_manifest_sha256": expected_parameters[
                    "source_manifest_sha256"
                ],
                "p00_executable_sha256": expected_parameters["executable_sha256"],
                "p00_configuration_sha256": expected_parameters[
                    "configuration_sha256"
                ],
                "p00_backend_reset_before_frame": True,
                "p00_prior_frame_count": 0,
                "p00_adapter_source_sha256": (
                    self.p00_helper.executable.adapter_source_sha256
                ),
                "p00_execution_compatibility_wrapper": True,
                "p00_source_byte_identical_claimed_for_adapter": False,
                "p00_lanczos_synchronization_delta": (
                    "commit_then_waitUntilCompleted_no_post_commit_handler"
                ),
                "p00_invocation_postprocess": helper_summary[
                    "direct_3_over_2_postprocess"
                ],
                "p00_compatibility_boundary_normalization": (
                    compatibility_boundary
                ),
            }
            record = self._attach_p07_sample_binding(record)
            output_payload = _planar_to_video_range_nv12(output)
            if (
                _sha256(output_payload)
                != compatibility_boundary.get("normalized_payload_sha256")
                or len(output_payload)
                != compatibility_boundary.get("normalized_payload_size_bytes")
            ):
                raise NativeAdapterError(
                    "P00 normalized output differs from compatibility evidence"
                )
            origin = self._publish_control_output_cache(
                request=request,
                identity=control_cache_identity,
                output_payload=output_payload,
                output_frame_sha256=output_hash,
                base_control_record=record,
            )
            record = self._decorated_control_cache_record(
                origin,
                reused=False,
                current_analysis_count=1,
                current_operator_count=1,
            )
            self._control_records.append(record)
            return output
        except Exception as error:
            failure = {
                "schema_version": "1.0.0",
                "status": "failed",
                "operation": "p00_current_production_ash",
                "control_request_sha256": request["request_sha256"],
                "input_frame_sha256": input_hash,
                "p00_identity": dict(self.p00_helper.executable.identity),
                "error_type": type(error).__name__,
                "message": str(error),
            }
            _ensure_directory(self.failure_root)
            failure_path = self.failure_root / f"p00-{uuid.uuid4().hex}.json"
            _write_new(failure_path, canonical_json_bytes(failure) + b"\n")
            raise NativeAdapterError(str(error), failure_path) from error

    def _validate_control_request(self, request: Mapping[str, object]) -> None:
        required = {
            "schema_version",
            "operation",
            "control_key",
            "control_mode",
            "configuration_sha256",
            "shared_bank_configuration_sha256",
            "parameters",
            "request_sha256",
        }
        parameters = request.get("parameters")
        declared = request.get("request_sha256")
        unhashed = {key: value for key, value in request.items() if key != "request_sha256"}
        configuration = self.session.configuration.configuration
        if (
            set(request) != required
            or request.get("schema_version") != "1.0.0"
            or request.get("operation") != "reconstruct_control"
            or not isinstance(request.get("control_key"), str)
            or not request["control_key"]
            or not isinstance(request.get("control_mode"), str)
            or not request["control_mode"]
            or not _is_sha256(request.get("configuration_sha256"))
            or request.get("shared_bank_configuration_sha256")
            != configuration["shared_bank_configuration_sha256"]
            or not isinstance(parameters, dict)
            or not _is_sha256(declared)
            or declared != canonical_sha256(unhashed)
        ):
            raise NativeAdapterError("native control request is invalid or stale")

    def _validate_control_summary(
        self,
        summary: Mapping[str, object],
        *,
        request: Mapping[str, object],
        native_frame: Mapping[str, object],
        input_payload: bytes,
        output_payload: bytes,
    ) -> None:
        configuration = self.session.configuration.configuration
        schema_version = configuration.get("schema_version", "1.0.0")
        native_protocol = (
            "mirmir-ash-calibration-cli-v2"
            if schema_version == "2.0.0"
            else "mirmir-ash-calibration-cli-v1"
        )
        proof = summary.get("native_invocation_proof")
        dispatch_modes = {
            "full_ash",
            "fixed_descriptor_uniform",
            "state_only",
            "non_ash_selector_q15",
            "h07_direct2x_then_lanczos3",
        }
        locked_summary = summary.get("locked_runtime_summary")
        h07_summary = summary.get("h07_runtime_summary")
        if (
            summary.get("request_id") != native_frame["request_id"]
            or summary.get("control_key") != request["control_key"]
            or summary.get("control_mode") != request["control_mode"]
            or summary.get("control_request_sha256") != request["request_sha256"]
            or summary.get("control_configuration_sha256")
            != request["configuration_sha256"]
            or summary.get("shared_bank_configuration_sha256")
            != request["shared_bank_configuration_sha256"]
            or summary.get("target_route") != native_frame["route"]
            or summary.get("input_nv12_sha256") != _sha256(input_payload)
            or summary.get("output_nv12_sha256") != _sha256(output_payload)
            or summary.get("configuration_id") != configuration["configuration_id"]
            or summary.get("candidate_lut_runtime_manifest_sha256")
            != configuration["candidate_lut_runtime_manifest_sha256"]
            or summary.get("candidate_route_lut_whole_file_sha256")
            != configuration["route_luts"][native_frame["route"]]["whole_file_sha256"]
            or summary.get("pixel_contract")
            != "bt709-video-range-420v-8bit-nv12-v1"
            or summary.get("quantization_convention")
            != "common_420v_round_to_nearest_even"
            or summary.get("production_metal_constraint_satisfied") is not False
            or not isinstance(summary.get("control_execution_proof"), dict)
            or (
                request["control_mode"] in dispatch_modes
                and not isinstance(locked_summary, dict)
            )
            or (
                request["control_mode"] not in dispatch_modes
                and locked_summary is not None
            )
            or (
                request["control_mode"] == "h07_direct2x_then_lanczos3"
                and not isinstance(h07_summary, dict)
            )
            or (
                request["control_mode"] != "h07_direct2x_then_lanczos3"
                and h07_summary is not None
            )
            or not isinstance(proof, dict)
            or proof.get("protocol") != native_protocol
            or proof.get("executable_sha256")
            != configuration["swift_cli"]["executable_sha256"]
            or proof.get("source_manifest_sha256")
            != configuration["swift_cli"]["source_manifest_sha256"]
        ):
            raise NativeAdapterError("native control summary binding mismatch")
        if isinstance(locked_summary, dict):
            runtime_route = (
                "direct-2x"
                if request["control_mode"] == "h07_direct2x_then_lanczos3"
                else str(native_frame["route"])
            )
            route_binding = configuration["route_luts"][runtime_route]
            if schema_version == "2.0.0":
                physical = configuration.get("physical_candidate_vector")
                if not isinstance(physical, dict):
                    raise NativeAdapterError(
                        "format-1.2 physical candidate identity is absent"
                    )
                route_prefix = (
                    "direct_2x"
                    if runtime_route == "direct-2x"
                    else "direct_3_over_2"
                )
                self._validate_locked_runtime_summary_v3(
                    locked_summary,
                    control_mode=str(request["control_mode"]),
                    target_route=runtime_route,
                    expected_luma_coordinate_policy=str(
                        route_binding["luma_coordinate_policy"]
                    ),
                    expected_chroma_coordinate_policy=str(
                        route_binding["chroma_coordinate_policy"]
                    ),
                    expected_luma_anisotropy_mode=physical[
                        f"{route_prefix}_luma_anisotropy_mode_ordinal"
                    ],
                    expected_chroma_anisotropy_mode=physical[
                        f"{route_prefix}_chroma_anisotropy_mode_ordinal"
                    ],
                )
            else:
                self._validate_locked_runtime_summary(
                    locked_summary,
                    control_mode=str(request["control_mode"]),
                    target_route=runtime_route,
                    expected_luma_coordinate_policy=str(
                        route_binding["luma_coordinate_policy"]
                    ),
                    expected_chroma_coordinate_policy=str(
                        route_binding["chroma_coordinate_policy"]
                    ),
                )
        if isinstance(h07_summary, dict):
            assert isinstance(locked_summary, dict)
            self._validate_h07_runtime_summary(
                h07_summary,
                direct2_summary=locked_summary,
                native_frame=native_frame,
            )

    @staticmethod
    def _validate_locked_runtime_summary_v3(
        summary: Mapping[str, object],
        *,
        control_mode: str,
        target_route: str,
        expected_luma_coordinate_policy: str,
        expected_chroma_coordinate_policy: str,
        expected_luma_anisotropy_mode: object,
        expected_chroma_anisotropy_mode: object,
    ) -> None:
        fields = {
            "schema_version",
            "luma_coordinate_policy",
            "chroma_coordinate_policy",
            "luma_anisotropy_mode_ordinal",
            "chroma_anisotropy_mode_ordinal",
            "state_histogram",
            "luma_operator_histogram",
            "chroma_operator_histogram",
            "maximum_operator_evaluations",
            "analysis_cell_count",
            "occupied_analysis_cell_count",
            "dispatch_record_count",
            "exact_decode_count",
            "corrected_decode_count",
            "rejected_decode_count",
        }
        states = summary.get("state_histogram")
        luma_operators = summary.get("luma_operator_histogram")
        chroma_operators = summary.get("chroma_operator_histogram")
        numeric_fields = [
            "luma_anisotropy_mode_ordinal",
            "chroma_anisotropy_mode_ordinal",
            "maximum_operator_evaluations",
            "analysis_cell_count",
            "occupied_analysis_cell_count",
            "dispatch_record_count",
            "exact_decode_count",
            "corrected_decode_count",
            "rejected_decode_count",
        ]
        if (
            set(summary) != fields
            or summary.get("schema_version") != "2.0.0"
            or summary.get("luma_coordinate_policy")
            != expected_luma_coordinate_policy
            or summary.get("chroma_coordinate_policy")
            != expected_chroma_coordinate_policy
            or not isinstance(states, list)
            or not states
            or not isinstance(luma_operators, list)
            or not luma_operators
            or not isinstance(chroma_operators, list)
            or not chroma_operators
            or any(
                not isinstance(summary.get(field), int)
                or isinstance(summary[field], bool)
                or int(summary[field]) < 0
                for field in numeric_fields
            )
            or summary.get("luma_anisotropy_mode_ordinal")
            != expected_luma_anisotropy_mode
            or summary.get("chroma_anisotropy_mode_ordinal")
            != expected_chroma_anisotropy_mode
            or not 0 <= int(summary["luma_anisotropy_mode_ordinal"]) <= 5
            or not 0 <= int(summary["chroma_anisotropy_mode_ordinal"]) <= 5
        ):
            raise NativeAdapterError("locked V3 runtime summary field set is invalid")

        def histogram_rows(
            rows: list[object],
            identifier: str,
            upper_bound: int,
        ) -> list[tuple[int, int]]:
            result = []
            for row in rows:
                if (
                    not isinstance(row, dict)
                    or set(row) != {identifier, "count"}
                    or not isinstance(row.get(identifier), int)
                    or isinstance(row[identifier], bool)
                    or not (0 <= int(row[identifier]) <= upper_bound)
                    or not isinstance(row.get("count"), int)
                    or isinstance(row["count"], bool)
                    or int(row["count"]) <= 0
                ):
                    raise NativeAdapterError(
                        "locked V3 runtime histogram row is invalid"
                    )
                result.append((int(row[identifier]), int(row["count"])))
            if (
                result != sorted(result)
                or len(result) != len({item[0] for item in result})
            ):
                raise NativeAdapterError(
                    "locked V3 runtime histogram is not sorted unique"
                )
            return result

        state_rows = histogram_rows(states, "state_raw_value", 511)
        luma_rows = histogram_rows(luma_operators, "descriptor_id", 15)
        chroma_rows = histogram_rows(chroma_operators, "descriptor_id", 15)
        analysis_count = int(summary["analysis_cell_count"])
        occupied_count = int(summary["occupied_analysis_cell_count"])
        dispatch_count = int(summary["dispatch_record_count"])
        phase_pair_counts = {"direct-2x": 4, "direct-3over2": 9}
        phase_pair_count = phase_pair_counts.get(target_route)
        if phase_pair_count is None:
            raise NativeAdapterError("locked V3 runtime route is invalid")
        per_plane_dispatch_count = analysis_count * phase_pair_count
        luma_operator_count = sum(count for _, count in luma_rows)
        chroma_operator_count = sum(count for _, count in chroma_rows)
        operator_count = luma_operator_count + chroma_operator_count
        decode_count = sum(
            int(summary[field])
            for field in (
                "exact_decode_count",
                "corrected_decode_count",
                "rejected_decode_count",
            )
        )
        maximum = int(summary["maximum_operator_evaluations"])
        if (
            sum(count for _, count in state_rows) != analysis_count
            or analysis_count <= 0
            or not 0 <= occupied_count <= analysis_count
            or dispatch_count != 2 * per_plane_dispatch_count
            or not (
                per_plane_dispatch_count
                <= luma_operator_count
                <= 2 * per_plane_dispatch_count
            )
            or not (
                per_plane_dispatch_count
                <= chroma_operator_count
                <= 2 * per_plane_dispatch_count
            )
            or operator_count != decode_count
            or not (1 <= maximum <= 2)
        ):
            raise NativeAdapterError("locked V3 runtime summary cardinality differs")
        if control_mode == "state_only" and (
            maximum != 1
            or luma_operator_count != per_plane_dispatch_count
            or chroma_operator_count != per_plane_dispatch_count
            or summary["corrected_decode_count"] != 0
            or summary["rejected_decode_count"] != 0
        ):
            raise NativeAdapterError(
                "state-only V3 runtime summary contains branch/decode evidence"
            )

    @staticmethod
    def _validate_locked_runtime_summary(
        summary: Mapping[str, object],
        *,
        control_mode: str,
        target_route: str,
        expected_luma_coordinate_policy: str,
        expected_chroma_coordinate_policy: str,
    ) -> None:
        fields = {
            "luma_coordinate_policy",
            "chroma_coordinate_policy",
            "state_histogram",
            "operator_histogram",
            "maximum_operator_evaluations",
            "analysis_cell_count",
            "occupied_analysis_cell_count",
            "dispatch_record_count",
            "exact_decode_count",
            "corrected_decode_count",
            "rejected_decode_count",
        }
        states = summary.get("state_histogram")
        operators = summary.get("operator_histogram")
        numeric_fields = [
            "maximum_operator_evaluations",
            "analysis_cell_count",
            "occupied_analysis_cell_count",
            "dispatch_record_count",
            "exact_decode_count",
            "corrected_decode_count",
            "rejected_decode_count",
        ]
        if (
            set(summary) != fields
            or summary.get("luma_coordinate_policy")
            != expected_luma_coordinate_policy
            or summary.get("chroma_coordinate_policy")
            != expected_chroma_coordinate_policy
            or not isinstance(states, list)
            or not states
            or not isinstance(operators, list)
            or not operators
            or any(
                not isinstance(summary.get(field), int)
                or isinstance(summary[field], bool)
                or int(summary[field]) < 0
                for field in numeric_fields
            )
        ):
            raise NativeAdapterError("locked runtime summary field set is invalid")

        def histogram_rows(
            rows: list[object],
            identifier: str,
            upper_bound: int,
        ) -> list[tuple[int, int]]:
            result = []
            for row in rows:
                if (
                    not isinstance(row, dict)
                    or set(row) != {identifier, "count"}
                    or not isinstance(row.get(identifier), int)
                    or isinstance(row[identifier], bool)
                    or not (0 <= int(row[identifier]) <= upper_bound)
                    or not isinstance(row.get("count"), int)
                    or isinstance(row["count"], bool)
                    or int(row["count"]) <= 0
                ):
                    raise NativeAdapterError("locked runtime histogram row is invalid")
                result.append((int(row[identifier]), int(row["count"])))
            if result != sorted(result) or len(result) != len({item[0] for item in result}):
                raise NativeAdapterError("locked runtime histogram is not sorted unique")
            return result

        state_rows = histogram_rows(states, "state_raw_value", 511)
        operator_rows = histogram_rows(operators, "descriptor_id", 15)
        analysis_count = int(summary["analysis_cell_count"])
        occupied_count = int(summary["occupied_analysis_cell_count"])
        dispatch_count = int(summary["dispatch_record_count"])
        phase_pair_counts = {"direct-2x": 4, "direct-3over2": 9}
        phase_pair_count = phase_pair_counts.get(target_route)
        operator_count = sum(count for _, count in operator_rows)
        decode_count = sum(
            int(summary[field])
            for field in (
                "exact_decode_count",
                "corrected_decode_count",
                "rejected_decode_count",
            )
        )
        maximum = int(summary["maximum_operator_evaluations"])
        if (
            sum(count for _, count in state_rows) != analysis_count
            or analysis_count <= 0
            or not 0 <= occupied_count <= analysis_count
            or phase_pair_count is None
            or dispatch_count != analysis_count * phase_pair_count
            or operator_count != decode_count
            or not (dispatch_count <= operator_count <= dispatch_count * 2)
            or not (1 <= maximum <= 2)
        ):
            raise NativeAdapterError("locked runtime summary cardinality differs")
        if control_mode == "state_only" and (
            maximum != 1
            or operator_count != dispatch_count
            or summary["corrected_decode_count"] != 0
            or summary["rejected_decode_count"] != 0
        ):
            raise NativeAdapterError("state-only runtime summary contains branch/decode evidence")

    @staticmethod
    def _validate_h07_runtime_summary(
        summary: Mapping[str, object],
        *,
        direct2_summary: Mapping[str, object],
        native_frame: Mapping[str, object],
    ) -> None:
        fields = {
            "schema_version",
            "artifact_kind",
            "direct2_analysis_grid_invocation_count",
            "direct2_analysis_cell_count",
            "direct2_intermediate_luma_dimensions",
            "target_luma_pixel_count",
            "direct2_operator_work_item_count",
            "lanczos3_work_item_count",
            "total_work_item_count",
            "summary_sha256",
        }
        intermediate_height = int(native_frame["input_height"]) * 2
        intermediate_width = int(native_frame["input_width"]) * 2
        target_pixel_count = int(native_frame["output_height"]) * int(
            native_frame["output_width"]
        )
        direct2_work_items = 2 * intermediate_height * intermediate_width
        lanczos3_work_items = 12 * target_pixel_count
        unhashed = dict(summary)
        declared = unhashed.pop("summary_sha256", None)
        if (
            set(summary) != fields
            or summary.get("schema_version") != "1.0.0"
            or summary.get("artifact_kind")
            != "p06_h07_direct2_lanczos3_runtime_summary"
            or summary.get("direct2_analysis_grid_invocation_count") != 1
            or summary.get("direct2_analysis_cell_count")
            != direct2_summary.get("analysis_cell_count")
            or summary.get("direct2_intermediate_luma_dimensions")
            != {"height": intermediate_height, "width": intermediate_width}
            or summary.get("target_luma_pixel_count") != target_pixel_count
            or summary.get("direct2_operator_work_item_count")
            != direct2_work_items
            or summary.get("lanczos3_work_item_count") != lanczos3_work_items
            or summary.get("total_work_item_count")
            != direct2_work_items + lanczos3_work_items
            or not _is_sha256(declared)
            or declared != canonical_sha256(unhashed)
        ):
            raise NativeAdapterError("H07 runtime work summary differs")

    def _validate_non_ash_cache_manifest(
        self,
        manifest: Mapping[str, object],
        *,
        token: str,
        source_asset_id: str,
        degradation_profile_id: str | None,
        degradation_profile_sha256: str | None,
        input_frame_sha256: str,
        context: CandidateContext,
        input_shape: Tuple[int, int],
    ) -> None:
        fields = {
            "schema_version",
            "artifact_kind",
            "bank_id",
            "route",
            "source_asset_id",
            "degradation_profile_id",
            "degradation_profile_sha256",
            "input_frame_sha256",
            "dimensions",
            "analysis_grid_invocation_count",
            "feature_tensor_q15_sha256",
            "descriptor_outputs",
            "cache_manifest_sha256",
        }
        dimensions = manifest.get("dimensions")
        descriptor_outputs = manifest.get("descriptor_outputs")
        configuration = self.session.configuration.configuration
        if (
            set(manifest) != fields
            or manifest.get("schema_version") != "1.0.0"
            or manifest.get("artifact_kind") != "p06_native_non_ash_output_cache"
            or manifest.get("bank_id")
            != configuration["shared_bank_configuration_sha256"]
            or manifest.get("route") != context.target_route
            or manifest.get("source_asset_id") != source_asset_id
            or manifest.get("degradation_profile_id") != degradation_profile_id
            or manifest.get("degradation_profile_sha256")
            != degradation_profile_sha256
            or manifest.get("input_frame_sha256") != input_frame_sha256
            or manifest.get("analysis_grid_invocation_count") != 1
            or not _is_sha256(manifest.get("feature_tensor_q15_sha256"))
            or manifest.get("cache_manifest_sha256") != token
            or not isinstance(dimensions, dict)
            or set(dimensions)
            != {"input_luma", "input_chroma", "output_luma", "output_chroma"}
            or dimensions.get("input_luma") != list(input_shape)
            or dimensions.get("input_chroma")
            != [input_shape[0] // 2, input_shape[1] // 2]
            or dimensions.get("output_luma") != list(context.y_shape)
            or dimensions.get("output_chroma") != list(context.cb_shape)
            or not isinstance(descriptor_outputs, list)
            or len(descriptor_outputs) != 16
        ):
            raise NativeAdapterError("native non-ASH cache manifest binding differs")
        for descriptor_id, row in enumerate(descriptor_outputs):
            if (
                not isinstance(row, dict)
                or set(row) != {"descriptor_id", "output_frame_sha256"}
                or row.get("descriptor_id") != descriptor_id
                or not _is_sha256(row.get("output_frame_sha256"))
            ):
                raise NativeAdapterError(
                    "native non-ASH descriptor output manifest is invalid"
                )
        unhashed = dict(manifest)
        declared = unhashed.pop("cache_manifest_sha256", None)
        if declared != canonical_sha256(unhashed) or declared != token:
            raise NativeAdapterError("native non-ASH cache manifest self-hash differs")

    @staticmethod
    def _validate_persisted_non_ash_origin(
        origin: Mapping[str, object],
        *,
        identity: Mapping[str, object],
        identity_sha256: str,
        persistent_root: Path,
    ) -> None:
        fields = {
            "schema_version",
            "artifact_kind",
            "identity",
            "identity_sha256",
            "cache_token",
            "cache_manifest",
            "cache_artifact_filename",
            "cache_artifact_sha256",
            "cache_artifact_size_bytes",
            "origin_configuration_id",
            "origin_native_executable_sha256",
            "origin_native_source_manifest_sha256",
            "origin_manifest_sha256",
        }
        unhashed = dict(origin)
        declared = unhashed.pop("origin_manifest_sha256", None)
        manifest = origin.get("cache_manifest")
        artifact_sha256 = origin.get("cache_artifact_sha256")
        artifact_filename = origin.get("cache_artifact_filename")
        if (
            set(origin) != fields
            or origin.get("schema_version") != "1.0.0"
            or origin.get("artifact_kind") != "p06_persisted_non_ash_cache_origin"
            or origin.get("identity") != identity
            or origin.get("identity_sha256") != identity_sha256
            or identity_sha256 != canonical_sha256(identity)
            or not _is_sha256(origin.get("cache_token"))
            or not isinstance(manifest, dict)
            or not _is_sha256(artifact_sha256)
            or artifact_filename != f"cache-{artifact_sha256}.bin"
            or not isinstance(origin.get("cache_artifact_size_bytes"), int)
            or isinstance(origin.get("cache_artifact_size_bytes"), bool)
            or int(origin["cache_artifact_size_bytes"]) <= 0
            or not isinstance(origin.get("origin_configuration_id"), str)
            or not origin["origin_configuration_id"]
            or origin.get("origin_native_executable_sha256")
            != identity.get("native_executable_sha256")
            or origin.get("origin_native_source_manifest_sha256")
            != identity.get("native_source_manifest_sha256")
            or not _is_sha256(declared)
            or declared != canonical_sha256(unhashed)
        ):
            raise NativeAdapterError("persisted non-ASH cache origin is invalid")
        manifest_unhashed = dict(manifest)
        manifest_declared = manifest_unhashed.pop("cache_manifest_sha256", None)
        dimensions = manifest.get("dimensions")
        if (
            manifest_declared != origin["cache_token"]
            or manifest_declared != canonical_sha256(manifest_unhashed)
            or manifest.get("bank_id")
            != identity["shared_bank_configuration_sha256"]
            or manifest.get("route") != identity["route"]
            or manifest.get("source_asset_id") != identity["source_asset_id"]
            or manifest.get("degradation_profile_id")
            != identity["degradation_profile_id"]
            or manifest.get("degradation_profile_sha256")
            != identity["degradation_profile_sha256"]
            or manifest.get("input_frame_sha256") != identity["input_frame_sha256"]
            or dimensions
            != {
                "input_luma": identity["input_luma_dimensions"],
                "input_chroma": identity["input_chroma_dimensions"],
                "output_luma": identity["output_luma_dimensions"],
                "output_chroma": identity["output_chroma_dimensions"],
            }
            or manifest.get("analysis_grid_invocation_count") != 1
            or not _is_sha256(manifest.get("feature_tensor_q15_sha256"))
            or not isinstance(manifest.get("descriptor_outputs"), list)
            or len(manifest["descriptor_outputs"]) != 16
        ):
            raise NativeAdapterError("persisted non-ASH cache manifest differs")
        artifact = _read_regular(persistent_root / str(artifact_filename))
        if (
            _sha256(artifact) != artifact_sha256
            or len(artifact) != origin["cache_artifact_size_bytes"]
        ):
            raise NativeAdapterError("persisted non-ASH cache artifact differs")

    @staticmethod
    def _validate_non_ash_rule(rule: Mapping[str, object]) -> None:
        if (
            not isinstance(rule, dict)
            or set(rule) != set(_NON_ASH_RULE_COORDINATES)
            or any(
                not isinstance(rule[name], int)
                or isinstance(rule[name], bool)
                or int(rule[name]) not in _NON_ASH_RULE_VALUES
                for name in _NON_ASH_RULE_COORDINATES
            )
        ):
            raise NativeAdapterError("non-ASH cached rule is outside the locked grid")

    @staticmethod
    def _fixed_control_request(
        descriptor_id: int,
        bank_id: str,
    ) -> Mapping[str, object]:
        configuration_sha256 = canonical_sha256(
            {
                "control_id": "fixed-descriptor-uniform-v1",
                "descriptor_id": descriptor_id,
                "shared_bank_configuration_sha256": bank_id,
            }
        )
        request: dict[str, object] = {
            "schema_version": "1.0.0",
            "operation": "reconstruct_control",
            "control_key": f"fixed_descriptor_{descriptor_id:02d}",
            "control_mode": "fixed_descriptor_uniform",
            "configuration_sha256": configuration_sha256,
            "shared_bank_configuration_sha256": bank_id,
            "parameters": {"descriptor_id": descriptor_id},
        }
        request["request_sha256"] = canonical_sha256(request)
        return request

    @staticmethod
    def _validate_cached_reconstruction(
        reconstruction: Mapping[str, object],
        *,
        output_payload: bytes,
        output_width: int,
        output_height: int,
        expected_artifact_kind: str,
        expected_fields: set[str],
    ) -> dict[str, object]:
        if (
            set(reconstruction)
            != {"cache_record", "output_nv12_sha256", "output_width", "output_height"}
            or reconstruction.get("output_nv12_sha256") != _sha256(output_payload)
            or reconstruction.get("output_width") != output_width
            or reconstruction.get("output_height") != output_height
            or len(output_payload) != output_width * output_height * 3 // 2
            or not isinstance(reconstruction.get("cache_record"), dict)
        ):
            raise NativeAdapterError("native cached reconstruction envelope differs")
        record = reconstruction["cache_record"]
        assert isinstance(record, dict)
        unhashed = dict(record)
        declared = unhashed.pop("record_sha256", None)
        output = _video_range_nv12_to_planar(
            output_payload,
            width=output_width,
            height=output_height,
        )
        if (
            set(record) != expected_fields
            or record.get("schema_version") != "1.0.0"
            or record.get("artifact_kind") != expected_artifact_kind
            or not _is_sha256(declared)
            or declared != canonical_sha256(unhashed)
            or record.get("output_frame_sha256") != frame_sha256(output)
        ):
            raise NativeAdapterError("native cached reconstruction record differs")
        return json.loads(canonical_json_bytes(record))

    def measure_dispatch_projection(
        self,
        frame: PlanarFrame,
        context: CandidateContext,
        *,
        source_asset_id: str,
        degradation_profile_id: str,
        degradation_profile_sha256: str,
    ) -> Mapping[str, object]:
        """Measure one validation case against its identical-grid CPU control."""

        if self.split != "validation":
            raise NativeAdapterError(
                "dispatch projection timing is permitted only for the validation split"
            )
        if (
            not isinstance(source_asset_id, str)
            or not source_asset_id
            or not isinstance(degradation_profile_id, str)
            or not degradation_profile_id
            or not _is_sha256(degradation_profile_sha256)
        ):
            raise NativeAdapterError("dispatch measurement identity is invalid")
        self._validate_geometry(frame, context)
        invocation_root = self.failure_root.parent / "measurement-invocations"
        _ensure_directory(invocation_root)
        configuration = self.session.configuration.configuration
        payload = _planar_to_video_range_nv12(frame)
        input_frame_hash = frame_sha256(frame)
        self._measurement_invocation_count += 1
        with tempfile.TemporaryDirectory(dir=invocation_root) as temporary:
            root = Path(temporary)
            input_path = root / "input.nv12"
            output_path = root / "output.nv12"
            _write_new(input_path, payload)
            native_frame = {
                "request_id": (
                    f"dispatch-measurement-{self._measurement_invocation_count:08d}"
                ),
                "route": context.target_route,
                "input_path": str(input_path),
                "input_sha256": _sha256(payload),
                "input_width": frame.y.shape[1],
                "input_height": frame.y.shape[0],
                "output_path": str(output_path),
                "output_width": context.y_shape[1],
                "output_height": context.y_shape[0],
                "pixel_format": "420v",
                "matrix": "BT.709",
                "range": "video",
                "chroma_siting": "left",
            }
            request = {
                "schema_version": "1.0.0",
                "operation": "measure_dispatch_projection",
                "configuration_id": configuration["configuration_id"],
                "compiler_inputs_sha256": configuration["compiler_inputs_sha256"],
                "frame": native_frame,
                "warmup_repetitions": 3,
                "measured_repetitions": 10,
            }
            try:
                response = self.session.measure(request)
                summary = response["measurement"]
                assert isinstance(summary, dict)
                output_payload = _read_regular(output_path)
                self._validate_measurement_summary(
                    summary,
                    native_frame=native_frame,
                    input_payload=payload,
                    output_payload=output_payload,
                )
                output = _video_range_nv12_to_planar(
                    output_payload,
                    width=context.y_shape[1],
                    height=context.y_shape[0],
                )
                output_hash = frame_sha256(output)
                repetitions = self._measurement_repetitions(summary["repetitions"])
                return {
                    "source_asset_id": source_asset_id,
                    "degradation_profile_id": degradation_profile_id,
                    "degradation_profile_sha256": degradation_profile_sha256,
                    "target_route": context.target_route,
                    "input_frame_sha256": input_frame_hash,
                    "full_output_sha256": output_hash,
                    "control_output_sha256": output_hash,
                    "lut_whole_file_sha256": configuration["route_luts"][
                        context.target_route
                    ]["whole_file_sha256"],
                    "measurement_domain": "native_cpu_reference_projection_not_metal",
                    "production_metal_constraint_satisfied": False,
                    "warmup_repetition_count": 3,
                    "measured_repetition_count": 10,
                    "input_bindings": self._dispatch_input_bindings(),
                    "repetitions": repetitions,
                }
            except Exception as error:
                failure = {
                    "schema_version": "1.0.0",
                    "status": "failed",
                    "operation": "measure_dispatch_projection",
                    "configuration_id": configuration["configuration_id"],
                    "request_sha256": canonical_sha256(request),
                    "source_asset_id": source_asset_id,
                    "degradation_profile_id": degradation_profile_id,
                    "degradation_profile_sha256": degradation_profile_sha256,
                    "input_frame_sha256": input_frame_hash,
                    "input_nv12_sha256": _sha256(payload),
                    "error_type": type(error).__name__,
                    "message": str(error),
                }
                _ensure_directory(self.failure_root)
                failure_path = self.failure_root / f"measurement-{uuid.uuid4().hex}.json"
                _write_new(failure_path, canonical_json_bytes(failure) + b"\n")
                raise NativeAdapterError(str(error), failure_path) from error

    def dispatch_environment(self) -> Mapping[str, object]:
        """Return the exact native host/toolchain binding for dispatch evidence."""

        source_manifest = _parse_json(
            _read_regular(self.session.executable.source_manifest_path),
            trailing_newline=False,
        )
        toolchain = source_manifest.get("toolchain")
        if not isinstance(toolchain, dict):
            raise NativeAdapterError("native source manifest toolchain is absent")
        swift_version = toolchain.get("swift_version")
        if not isinstance(swift_version, str) or not swift_version:
            raise NativeAdapterError("native source manifest Swift version is absent")

        def command_text(*command: str) -> str:
            value = _run_checked(command, cwd=REPOSITORY_ROOT).stdout.decode("utf-8").strip()
            if not value:
                raise NativeAdapterError(f"environment command returned no value: {' '.join(command)}")
            return value

        configuration = self.session.configuration.configuration
        return {
            "hardware_model": command_text("/usr/sbin/sysctl", "-n", "hw.model"),
            "chip": command_text(
                "/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"
            ),
            "logical_cpu_count": int(
                command_text("/usr/sbin/sysctl", "-n", "hw.logicalcpu")
            ),
            "physical_memory_bytes": int(
                command_text("/usr/sbin/sysctl", "-n", "hw.memsize")
            ),
            "os_version": command_text("/usr/bin/sw_vers", "-productVersion"),
            "os_build": command_text("/usr/bin/sw_vers", "-buildVersion"),
            "swift_version": swift_version,
            "xcode_version": command_text("/usr/bin/xcodebuild", "-version").replace(
                "\n", "; "
            ),
            "executable_sha256": configuration["swift_cli"]["executable_sha256"],
            "source_manifest_sha256": configuration["swift_cli"][
                "source_manifest_sha256"
            ],
        }

    def _validate_measurement_summary(
        self,
        summary: Mapping[str, object],
        *,
        native_frame: Mapping[str, object],
        input_payload: bytes,
        output_payload: bytes,
    ) -> None:
        configuration = self.session.configuration.configuration
        route = str(native_frame["route"])
        route_lut = configuration["route_luts"][route]
        proof = summary.get("native_invocation_proof")
        if (
            summary.get("request_id") != native_frame["request_id"]
            or summary.get("target_route") != route
            or summary.get("input_nv12_sha256") != _sha256(input_payload)
            or summary.get("output_nv12_sha256") != _sha256(output_payload)
            or summary.get("full_output_nv12_sha256") != _sha256(output_payload)
            or summary.get("control_output_nv12_sha256") != _sha256(output_payload)
            or summary.get("configuration_id") != configuration["configuration_id"]
            or summary.get("mapping_sha256") != configuration["mapping_sha256"]
            or summary.get("operator_bank_sha256") != configuration["operator_bank_sha256"]
            or summary.get("metric_policy_sha256") != configuration["metric_policy_sha256"]
            or summary.get("compiler_inputs_sha256")
            != configuration["compiler_inputs_sha256"]
            or summary.get("calibration_plan_sha256")
            != configuration["calibration_plan_sha256"]
            or summary.get("corpus_lock_bundle_sha256")
            != configuration["corpus_lock_bundle_sha256"]
            or summary.get("candidate_vector_sha256")
            != configuration["serialized_candidate_vector_sha256"]
            or summary.get("shared_bank_configuration_sha256")
            != configuration["shared_bank_configuration_sha256"]
            or summary.get("candidate_lut_runtime_manifest_sha256")
            != configuration["candidate_lut_runtime_manifest_sha256"]
            or summary.get("route_lut_whole_file_sha256")
            != route_lut["whole_file_sha256"]
            or summary.get("route_lut_payload_sha256") != route_lut["payload_sha256"]
            or summary.get("measurement_domain")
            != "native_cpu_reference_projection_not_metal"
            or summary.get("warmup_repetition_count") != 3
            or summary.get("measured_repetition_count") != 10
            or summary.get("production_metal_constraint_satisfied") is not False
            or summary.get("cpu_reference_analysis_traversals") != 1
            or summary.get("cpu_reference_full_frame_loop_count") != 3
            or summary.get("loaded_lut_instance_count") != 1
            or summary.get("session_loaded_lut_instance_count") != 2
            or summary.get("per_frame_lut_load_count") != 0
            or summary.get("runtime_leaf_tree_generations") != 0
            or summary.get("runtime_path_generations") != 0
            or summary.get("chroma_convention")
            != "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once"
            or summary.get("quantization_convention")
            != "common_420v_round_to_nearest_even"
            or summary.get("pixel_contract")
            != "bt709-video-range-420v-8bit-nv12-v1"
            or not isinstance(proof, dict)
            or set(proof)
            != {"protocol", "process_id", "executable_sha256", "source_manifest_sha256"}
            or proof.get("protocol") != "mirmir-ash-calibration-cli-v1"
            or not isinstance(proof.get("process_id"), int)
            or int(proof["process_id"]) <= 0
            or proof.get("executable_sha256")
            != configuration["swift_cli"]["executable_sha256"]
            or proof.get("source_manifest_sha256")
            != configuration["swift_cli"]["source_manifest_sha256"]
        ):
            raise NativeAdapterError("native dispatch measurement binding mismatch")

    @staticmethod
    def _measurement_repetitions(value: object) -> list[dict[str, object]]:
        if not isinstance(value, list) or len(value) != 10:
            raise NativeAdapterError("native dispatch measurement lacks ten repetitions")
        records: list[dict[str, object]] = []
        fields = {
            "index",
            "order",
            "full_analysis_nanoseconds",
            "full_dispatch_nanoseconds",
            "full_reconstruction_nanoseconds",
            "control_reconstruction_nanoseconds",
        }
        for index, row in enumerate(value):
            expected_order = "full_then_control" if index % 2 == 0 else "control_then_full"
            if (
                not isinstance(row, dict)
                or set(row) != fields
                or row.get("index") != index
                or row.get("order") != expected_order
            ):
                raise NativeAdapterError("native dispatch repetition order differs")
            timings = [
                row.get("full_analysis_nanoseconds"),
                row.get("full_dispatch_nanoseconds"),
                row.get("full_reconstruction_nanoseconds"),
                row.get("control_reconstruction_nanoseconds"),
            ]
            if (
                any(not isinstance(value, int) or isinstance(value, bool) for value in timings)
                or int(timings[0]) < 0
                or int(timings[1]) < 0
                or int(timings[2]) <= 0
                or int(timings[3]) <= 0
            ):
                raise NativeAdapterError("native dispatch repetition timing is invalid")
            records.append(dict(row))
        return records

    def _dispatch_input_bindings(self) -> Mapping[str, object]:
        configuration = self.session.configuration.configuration
        return {
            "configuration_id": configuration["configuration_id"],
            "candidate_vector_sha256": configuration[
                "serialized_candidate_vector_sha256"
            ],
            "shared_bank_configuration_sha256": configuration[
                "shared_bank_configuration_sha256"
            ],
            "mapping_sha256": configuration["mapping_sha256"],
            "operator_bank_sha256": configuration["operator_bank_sha256"],
            "metric_policy_sha256": configuration["metric_policy_sha256"],
            "compiler_inputs_sha256": configuration["compiler_inputs_sha256"],
            "calibration_plan_sha256": configuration["calibration_plan_sha256"],
            "corpus_lock_bundle_sha256": configuration[
                "corpus_lock_bundle_sha256"
            ],
            "validation_sample_lock_sha256": self.validation_sample_lock_sha256,
            "degradation_policy_sha256": self.degradation_policy_sha256,
            "raw_output_contract_sha256": configuration[
                "raw_output_contract_sha256"
            ],
            "full_control_configuration_sha256": configuration[
                "full_control_configuration_sha256"
            ],
        }

    def close(self) -> None:
        if self._closed:
            return
        primary_error: BaseException | None = None
        primary_traceback = None
        try:
            self._verify_native_cache_root()
            if (
                self._pending_control_cache_files
                or self._pending_control_cache_directories
            ):
                self._flush_deferred_control_cache_durability()
        except BaseException as error:
            primary_error = error
            primary_traceback = error.__traceback__
        try:
            self.session.close()
        except BaseException as error:
            if primary_error is None:
                primary_error = error
                primary_traceback = error.__traceback__
        try:
            os.close(self._native_cache_root_descriptor)
        except BaseException as error:
            if primary_error is None:
                primary_error = error
                primary_traceback = error.__traceback__
        self._closed = True
        if primary_error is not None:
            raise primary_error.with_traceback(primary_traceback)

    @staticmethod
    def _validate_geometry(frame: PlanarFrame, context: CandidateContext) -> None:
        height, width = frame.y.shape
        if (
            height <= 0
            or width <= 0
            or height % 2
            or width % 2
            or frame.cb.shape != (height // 2, width // 2)
            or frame.cr.shape != frame.cb.shape
            or not all(np.all(np.isfinite(plane)) for plane in (frame.y, frame.cb, frame.cr))
        ):
            raise NativeAdapterError("input frame is not finite even 4:2:0 geometry")
        scale_numerator, scale_denominator = (
            (2, 1) if context.target_route == "direct-2x" else (3, 2)
        )
        if (
            width * scale_numerator % scale_denominator
            or height * scale_numerator % scale_denominator
            or context.y_shape
            != (
                height * scale_numerator // scale_denominator,
                width * scale_numerator // scale_denominator,
            )
        ):
            raise NativeAdapterError("candidate context disagrees with native route geometry")


class NativeCandidateAdapterFactory:
    """Callable factory matching ``CalibrationCandidate.adapter_factory``."""

    def __init__(
        self,
        repository_root: Path,
        *,
        cache_root: Path | None = None,
        timeout_seconds: float = 900.0,
        live_holdout_preopen_binding: LiveHoldoutPreopenBinding | None = None,
        bound_inputs: object | None = None,
        validate_implementation_manifest: bool = True,
        implementation_manifest_validator: Callable[[Mapping[str, object], Path], str]
        | None = None,
        verify_bound_inputs: bool = True,
    ) -> None:
        self.repository_root = repository_root.resolve(strict=True)
        self.cache_root = cache_root or self.repository_root / ".build" / "p06-native-adapter"
        self.timeout_seconds = timeout_seconds
        if (live_holdout_preopen_binding is None) == (bound_inputs is None):
            raise NativeAdapterError(
                "provide exactly one live_holdout_preopen_binding or prevalidated bound_inputs"
            )
        self.bound = (
            bound_inputs
            if bound_inputs is not None
            else bind_preregistered_inputs(
                self.repository_root,
                live_holdout_preopen_binding=live_holdout_preopen_binding,
                validate_implementation_manifest=validate_implementation_manifest,
                implementation_manifest_validator=implementation_manifest_validator,
            )
        )
        self.plan = self.bound.documents["calibration_plan"]
        self.verify_bound_inputs = verify_bound_inputs
        self.builder = NativeSwiftBuilder(self.repository_root, self.cache_root)
        self.p00_builder = P00NativeBuilder(self.repository_root, self.cache_root)

    def authenticated_adapter_identity_v2(
        self,
        adapter: CandidateAdapter,
    ) -> Mapping[str, str]:
        """Independently reopen and bind one live format-1.2 adapter product."""

        if _plan_schema_version(self.plan) != "2.0.0":
            raise NativeAdapterError(
                "control execution producer identity requires a schema-2 plan"
            )
        callable_object = getattr(adapter, "callable", None)
        session = getattr(callable_object, "session", None)
        executable = getattr(session, "executable", None)
        configuration = getattr(adapter, "configuration", None)
        configuration_sha256 = getattr(adapter, "configuration_sha256", None)
        if (
            type(adapter) is not CandidateAdapter
            or type(callable_object) is not NativeCandidateCallable
            or type(session) is not NativeSwiftSession
            or executable is not self.builder.executable
            or not isinstance(configuration, Mapping)
            or not _is_sha256(configuration_sha256)
            or canonical_sha256(configuration) != configuration_sha256
            or callable_object.adapter_configuration_sha256
            != configuration_sha256
        ):
            raise NativeAdapterError(
                "control execution identity is not the live factory product"
            )
        swift_cli = configuration.get("swift_cli")
        if (
            not isinstance(swift_cli, Mapping)
            or set(swift_cli)
            != {"executable_sha256", "source_manifest_sha256"}
            or swift_cli.get("executable_sha256") != executable.sha256
            or swift_cli.get("source_manifest_sha256")
            != executable.source_manifest_sha256
        ):
            raise NativeAdapterError(
                "control execution native configuration identity differs"
            )

        executable_payload = _read_regular(executable.path)
        executable_metadata = os.stat(executable.path, follow_symlinks=False)
        if (
            _sha256(executable_payload) != executable.sha256
            or not stat.S_ISREG(executable_metadata.st_mode)
            or executable_metadata.st_mode & 0o111 == 0
        ):
            raise NativeAdapterError(
                "control execution native executable identity differs"
            )

        source_manifest_payload = _read_regular(executable.source_manifest_path)
        source_manifest = _parse_json(
            source_manifest_payload,
            trailing_newline=False,
        )
        swiftc, sdk_path, toolchain = _resolve_swift_toolchain(
            self.repository_root
        )
        del swiftc
        expected_source_records = []
        for path_value in _SWIFT_SOURCE_PATHS:
            relative = PurePosixPath(path_value)
            payload = _read_regular(
                self.repository_root.joinpath(*relative.parts)
            )
            expected_source_records.append(
                {
                    "path": path_value,
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
        expected_source_manifest = {
            "schema_version": "1.0.0",
            "implementation_role": "production_swift",
            "toolchain": toolchain,
            "compile_flags": [*_COMPILE_FLAGS, "-sdk", sdk_path],
            "sources": expected_source_records,
        }
        if (
            source_manifest != expected_source_manifest
            or canonical_json_bytes(source_manifest) != source_manifest_payload
            or _sha256(source_manifest_payload)
            != executable.source_manifest_sha256
        ):
            raise NativeAdapterError(
                "control execution native source manifest identity differs"
            )

        identity = {
            "adapter_configuration_sha256": str(configuration_sha256),
            "native_executable_sha256": executable.sha256,
            "native_implementation_source_sha256": (
                _control_execution_implementation_source_sha256_v2(
                    self.repository_root
                )
            ),
            "native_source_manifest_sha256": (
                executable.source_manifest_sha256
            ),
        }
        if set(identity) != {
            "adapter_configuration_sha256",
            "native_executable_sha256",
            "native_implementation_source_sha256",
            "native_source_manifest_sha256",
        } or any(not _is_sha256(value) for value in identity.values()):
            raise NativeAdapterError(
                "control execution authenticated adapter identity is invalid"
            )
        return identity

    def compile_candidate_configuration(
        self,
        vector: Mapping[str, object],
    ) -> NativeConfiguration | NativeCompiledConfigurationV2:
        """Compile the plan-selected family without claiming a schema-2 session."""

        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        compiled = self.builder.compile_candidate(
            vector=vector,
            plan=self.plan,
            bound=self.bound,
        )
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        return compiled

    def _require_native_session_authority(self) -> None:
        if _plan_schema_version(self.plan) == "2.0.0" and not (
            SCHEMAS_ROOT / "candidate-lut-runtime-manifest-v2.schema.json"
        ).is_file():
            raise NativeAdapterError(
                "schema-2 candidate runtime-manifest authority is absent"
            )

    def __call__(
        self,
        vector: Mapping[str, object],
        split: str,
    ) -> CandidateAdapter:
        if split not in {"development", "validation"}:
            raise NativeAdapterError("native P06 adapter cannot target holdout")
        self._require_native_session_authority()
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        native = self.builder.compile_candidate(
            vector=vector,
            plan=self.plan,
            bound=self.bound,
        )
        configuration_hash = canonical_sha256(native.configuration)
        session = NativeSwiftSession(
            self.builder.executable,
            native,
            timeout_seconds=self.timeout_seconds,
        )
        callable_object = NativeCandidateCallable(
            session=session,
            adapter_configuration_sha256=configuration_hash,
            failure_root=self.cache_root / "failures",
            split=split,
            p00_helper=P00NativeHelper(
                self.p00_builder.executable,
                self.cache_root / "p00-invocations",
            ),
            validation_sample_lock_sha256=str(
                self.bound.record("validation_sample_lock")["sha256"]
            ),
            degradation_policy_sha256=str(
                self.bound.record("degradation_policy")["sha256"]
            ),
        )
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        return CandidateAdapter(
            candidate_id=f"{native.configuration['configuration_id']}-native",
            configuration=native.configuration,
            configuration_sha256=configuration_hash,
            callable=callable_object,
        )

    def make_corrective_diagnostic_capability(
        self,
        vector: Mapping[str, object],
    ) -> NativeCorrectiveDiagnosticCapability:
        """Build one development-only native corrective session."""

        self._require_native_session_authority()
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        native = self.builder.ensure_configuration(
            vector=vector,
            plan=self.plan,
            bound=self.bound,
        )
        capability = NativeCorrectiveDiagnosticCapability(
            session=NativeSwiftSession(
                self.builder.executable,
                native,
                timeout_seconds=self.timeout_seconds,
            ),
            executable=self.builder.executable,
            configuration=native,
        )
        try:
            if self.verify_bound_inputs:
                self.bound.verify_unchanged()
        except BaseException:
            capability.close()
            raise
        return capability

    def make_p07_holdout_adapter(
        self,
        vector: Mapping[str, object],
        *,
        sampling_plan_manifest_sha256: str,
        p06_release_bundle_manifest_sha256: str,
    ) -> CandidateAdapter:
        """Build the frozen numeric configuration with P07-only cache identity."""

        self._require_native_session_authority()
        if (
            not _is_sha256(sampling_plan_manifest_sha256)
            or not _is_sha256(p06_release_bundle_manifest_sha256)
        ):
            raise NativeAdapterError("P07 release/sample manifest hash is invalid")
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        native = self.builder.ensure_configuration(
            vector=vector,
            plan=self.plan,
            bound=self.bound,
        )
        configuration_hash = canonical_sha256(native.configuration)
        session = NativeSwiftSession(
            self.builder.executable,
            native,
            timeout_seconds=self.timeout_seconds,
        )
        callable_object = NativeCandidateCallable(
            session=session,
            adapter_configuration_sha256=configuration_hash,
            failure_root=self.cache_root / "failures",
            split="p07_holdout",
            p00_helper=P00NativeHelper(
                self.p00_builder.executable,
                self.cache_root / "p00-invocations",
            ),
            validation_sample_lock_sha256=str(
                self.bound.record("validation_sample_lock")["sha256"]
            ),
            degradation_policy_sha256=str(
                self.bound.record("degradation_policy")["sha256"]
            ),
            p07_sampling_plan_manifest_sha256=(
                sampling_plan_manifest_sha256
            ),
            p07_release_bundle_manifest_sha256=(
                p06_release_bundle_manifest_sha256
            ),
        )
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        return CandidateAdapter(
            candidate_id=f"{native.configuration['configuration_id']}-p07-holdout",
            configuration=native.configuration,
            configuration_sha256=configuration_hash,
            callable=callable_object,
        )

    def make_p07_holdout_analytic_adapter(
        self,
        vector: Mapping[str, object],
        *,
        analytic_fixture_manifest_sha256: str,
        p06_release_bundle_manifest_sha256: str,
    ) -> CandidateAdapter:
        """Build a pre-open analytic adapter with an explicit P07 identity."""

        self._require_native_session_authority()
        if (
            not _is_sha256(analytic_fixture_manifest_sha256)
            or not _is_sha256(p06_release_bundle_manifest_sha256)
        ):
            raise NativeAdapterError("P07 release/analytic manifest hash is invalid")
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        native = self.builder.ensure_configuration(
            vector=vector,
            plan=self.plan,
            bound=self.bound,
        )
        configuration_hash = canonical_sha256(native.configuration)
        session = NativeSwiftSession(
            self.builder.executable,
            native,
            timeout_seconds=self.timeout_seconds,
        )
        callable_object = NativeCandidateCallable(
            session=session,
            adapter_configuration_sha256=configuration_hash,
            failure_root=self.cache_root / "failures",
            split="p07_holdout_analytic",
            p00_helper=P00NativeHelper(
                self.p00_builder.executable,
                self.cache_root / "p00-invocations",
            ),
            validation_sample_lock_sha256=str(
                self.bound.record("validation_sample_lock")["sha256"]
            ),
            degradation_policy_sha256=str(
                self.bound.record("degradation_policy")["sha256"]
            ),
            p07_analytic_fixture_manifest_sha256=(
                analytic_fixture_manifest_sha256
            ),
            p07_release_bundle_manifest_sha256=(
                p06_release_bundle_manifest_sha256
            ),
        )
        if self.verify_bound_inputs:
            self.bound.verify_unchanged()
        return CandidateAdapter(
            candidate_id=(
                f"{native.configuration['configuration_id']}-p07-holdout-analytic"
            ),
            configuration=native.configuration,
            configuration_sha256=configuration_hash,
            callable=callable_object,
        )


def make_native_candidate_adapter_factory(
    repository_root: Path = REPOSITORY_ROOT,
    *,
    cache_root: Path | None = None,
    timeout_seconds: float = 900.0,
    live_holdout_preopen_binding: LiveHoldoutPreopenBinding | None = None,
    bound_inputs: object | None = None,
    validate_implementation_manifest: bool = True,
    implementation_manifest_validator: Callable[[Mapping[str, object], Path], str]
    | None = None,
    verify_bound_inputs: bool = True,
) -> NativeCandidateAdapterFactory:
    """Create the production-Swift adapter factory for the P06 runner."""

    return NativeCandidateAdapterFactory(
        repository_root,
        cache_root=cache_root,
        timeout_seconds=timeout_seconds,
        live_holdout_preopen_binding=live_holdout_preopen_binding,
        bound_inputs=bound_inputs,
        validate_implementation_manifest=validate_implementation_manifest,
        implementation_manifest_validator=implementation_manifest_validator,
        verify_bound_inputs=verify_bound_inputs,
    )


def make_native_corrective_diagnostic_capability(
    repository_root: Path,
    *,
    cache_root: Path,
    bound_inputs: object,
    vector: Mapping[str, object],
    timeout_seconds: float = 900.0,
) -> NativeCorrectiveDiagnosticCapability:
    """Build only the Swift corrective capability, without a P00 backend."""

    root = repository_root.resolve(strict=True)
    if root != REPOSITORY_ROOT.resolve(strict=True):
        raise NativeAdapterError(
            "native corrective repository root differs from the loaded source tree"
        )
    verify = getattr(bound_inputs, "verify_unchanged", None)
    documents = getattr(bound_inputs, "documents", None)
    if not callable(verify) or not isinstance(documents, Mapping):
        raise NativeAdapterError(
            "native corrective capability requires immutable bound inputs"
        )
    plan = documents.get("calibration_plan")
    if not isinstance(plan, Mapping):
        raise NativeAdapterError("native corrective calibration plan is absent")
    verify()
    builder = NativeSwiftBuilder(root, cache_root.resolve())
    native = builder.ensure_configuration(
        vector=vector,
        plan=plan,
        bound=bound_inputs,
    )
    capability = NativeCorrectiveDiagnosticCapability(
        session=NativeSwiftSession(
            builder.executable,
            native,
            timeout_seconds=timeout_seconds,
        ),
        executable=builder.executable,
        configuration=native,
    )
    try:
        verify()
    except BaseException:
        capability.close()
        raise
    return capability


__all__ = [
    "NativeAdapterError",
    "NativeCandidateAdapterFactory",
    "NativeCandidateCallable",
    "NativeCompiledConfigurationV2",
    "NativeCorrectiveDiagnosticCapability",
    "make_native_corrective_diagnostic_capability",
    "make_native_candidate_adapter_factory",
]
