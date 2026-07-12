"""Hash-bound static and running-process code identity on macOS."""

from __future__ import annotations

import ctypes
import hashlib
import os
from pathlib import Path
import platform
import stat
import struct
from typing import Mapping, Sequence


class MacOSCodeIdentityError(RuntimeError):
    """A static or dynamic macOS code identity failed closed."""


_CORE_FOUNDATION = ctypes.CDLL(
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
)
_SECURITY = ctypes.CDLL(
    "/System/Library/Frameworks/Security.framework/Security"
)
_CF_INDEX = ctypes.c_long
_CF_NUMBER_SINT32 = 3
_CF_NUMBER_SINT64 = 4
_CF_STRING_UTF8 = 0x08000100
_SEC_CS_SIGNING_INFORMATION = 1 << 1
_SEC_CS_DYNAMIC_INFORMATION = 1 << 3
_SEC_CS_NO_NETWORK_ACCESS = 1 << 29
_CS_VALID = 0x00000001
_CS_ADHOC = 0x00000002
_CS_GET_TASK_ALLOW = 0x00000004
_CS_INVALID_ALLOWED = 0x00000020
_CS_KILL = 0x00000200
_CS_KILLED = 0x01000000
_CS_NO_UNTRUSTED_HELPERS = 0x02000000
_CS_DEBUGGED = 0x10000000
_CS_SIGNED = 0x20000000
_CPU_TYPE_ARM64 = 0x0100000C
_MH_EXECUTE = 2
_LC_CODE_SIGNATURE = 0x1D
_CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
_CSMAGIC_CODEDIRECTORY = 0xFADE0C02
_CSSLOT_CODEDIRECTORY = 0
_CSSLOT_ALTERNATE_CODEDIRECTORIES = frozenset(range(0x1000, 0x1005))
_HASHES = {
    1: ("sha1", 20),
    2: ("sha256", 32),
    3: ("sha256", 20),
    4: ("sha384", 48),
}


def _configure_symbols() -> None:
    _CORE_FOUNDATION.CFNumberCreate.restype = ctypes.c_void_p
    _CORE_FOUNDATION.CFNumberCreate.argtypes = (
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_void_p,
    )
    _CORE_FOUNDATION.CFNumberGetValue.restype = ctypes.c_bool
    _CORE_FOUNDATION.CFNumberGetValue.argtypes = (
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_void_p,
    )
    _CORE_FOUNDATION.CFDictionaryCreateMutable.restype = ctypes.c_void_p
    _CORE_FOUNDATION.CFDictionaryCreateMutable.argtypes = (
        ctypes.c_void_p,
        _CF_INDEX,
        ctypes.c_void_p,
        ctypes.c_void_p,
    )
    _CORE_FOUNDATION.CFDictionarySetValue.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
    )
    _CORE_FOUNDATION.CFDictionaryGetValue.restype = ctypes.c_void_p
    _CORE_FOUNDATION.CFDictionaryGetValue.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
    )
    _CORE_FOUNDATION.CFDataGetLength.restype = _CF_INDEX
    _CORE_FOUNDATION.CFDataGetLength.argtypes = (ctypes.c_void_p,)
    _CORE_FOUNDATION.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_ubyte)
    _CORE_FOUNDATION.CFDataGetBytePtr.argtypes = (ctypes.c_void_p,)
    _CORE_FOUNDATION.CFArrayGetCount.restype = _CF_INDEX
    _CORE_FOUNDATION.CFArrayGetCount.argtypes = (ctypes.c_void_p,)
    _CORE_FOUNDATION.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
    _CORE_FOUNDATION.CFArrayGetValueAtIndex.argtypes = (
        ctypes.c_void_p,
        _CF_INDEX,
    )
    _CORE_FOUNDATION.CFStringGetCString.restype = ctypes.c_bool
    _CORE_FOUNDATION.CFStringGetCString.argtypes = (
        ctypes.c_void_p,
        ctypes.c_char_p,
        _CF_INDEX,
        ctypes.c_uint32,
    )
    _CORE_FOUNDATION.CFURLCreateFromFileSystemRepresentation.restype = (
        ctypes.c_void_p
    )
    _CORE_FOUNDATION.CFURLCreateFromFileSystemRepresentation.argtypes = (
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_ubyte),
        _CF_INDEX,
        ctypes.c_bool,
    )
    _CORE_FOUNDATION.CFRelease.argtypes = (ctypes.c_void_p,)
    _SECURITY.SecStaticCodeCreateWithPath.restype = ctypes.c_int32
    _SECURITY.SecStaticCodeCreateWithPath.argtypes = (
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_void_p),
    )
    _SECURITY.SecStaticCodeCheckValidity.restype = ctypes.c_int32
    _SECURITY.SecStaticCodeCheckValidity.argtypes = (
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
    )
    _SECURITY.SecCodeCopyGuestWithAttributes.restype = ctypes.c_int32
    _SECURITY.SecCodeCopyGuestWithAttributes.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_void_p),
    )
    _SECURITY.SecCodeCheckValidity.restype = ctypes.c_int32
    _SECURITY.SecCodeCheckValidity.argtypes = (
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
    )
    _SECURITY.SecCodeCopySigningInformation.restype = ctypes.c_int32
    _SECURITY.SecCodeCopySigningInformation.argtypes = (
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_void_p),
    )


_configure_symbols()


def _security_key(name: str) -> int:
    try:
        value = ctypes.c_void_p.in_dll(_SECURITY, name).value
    except ValueError as error:
        raise MacOSCodeIdentityError(
            "Security.framework key is unavailable: {}".format(name)
        ) from error
    if not value:
        raise MacOSCodeIdentityError(
            "Security.framework key is null: {}".format(name)
        )
    return int(value)


_KEYS = {
    name: _security_key(name)
    for name in (
        "kSecGuestAttributePid",
        "kSecCodeInfoCdHashes",
        "kSecCodeInfoDigestAlgorithms",
        "kSecCodeInfoFlags",
        "kSecCodeInfoIdentifier",
        "kSecCodeInfoStatus",
        "kSecCodeInfoUnique",
    )
}


def _check_status(status: int, operation: str) -> None:
    if status != 0:
        raise MacOSCodeIdentityError(
            "{} failed with OSStatus {}".format(operation, status)
        )


def _dictionary_value(dictionary: int, key: str) -> int:
    value = _CORE_FOUNDATION.CFDictionaryGetValue(
        dictionary,
        _KEYS[key],
    )
    if not value:
        raise MacOSCodeIdentityError(
            "macOS code identity lacks {}".format(key)
        )
    return int(value)


def _data_hex(value: int) -> str:
    length = int(_CORE_FOUNDATION.CFDataGetLength(value))
    if length <= 0:
        raise MacOSCodeIdentityError("macOS code identity contains empty data")
    pointer = _CORE_FOUNDATION.CFDataGetBytePtr(value)
    if not pointer:
        raise MacOSCodeIdentityError("macOS code identity data is inaccessible")
    return bytes(pointer[index] for index in range(length)).hex()


def _number(value: int) -> int:
    result = ctypes.c_int64()
    if not _CORE_FOUNDATION.CFNumberGetValue(
        value,
        _CF_NUMBER_SINT64,
        ctypes.byref(result),
    ):
        raise MacOSCodeIdentityError("macOS code identity number is invalid")
    return int(result.value)


def _string(value: int) -> str:
    size = 4096
    buffer = ctypes.create_string_buffer(size)
    if not _CORE_FOUNDATION.CFStringGetCString(
        value,
        buffer,
        size,
        _CF_STRING_UTF8,
    ):
        raise MacOSCodeIdentityError("macOS code identity string is invalid")
    return buffer.value.decode("utf-8", "strict")


def _data_array(dictionary: int, key: str) -> list[str]:
    array = _dictionary_value(dictionary, key)
    count = int(_CORE_FOUNDATION.CFArrayGetCount(array))
    if count <= 0:
        raise MacOSCodeIdentityError("macOS code identity hash array is empty")
    return [
        _data_hex(
            int(_CORE_FOUNDATION.CFArrayGetValueAtIndex(array, index))
        )
        for index in range(count)
    ]


def _number_array(dictionary: int, key: str) -> list[int]:
    array = _dictionary_value(dictionary, key)
    count = int(_CORE_FOUNDATION.CFArrayGetCount(array))
    if count <= 0:
        raise MacOSCodeIdentityError(
            "macOS code identity digest algorithm array is empty"
        )
    return [
        _number(int(_CORE_FOUNDATION.CFArrayGetValueAtIndex(array, index)))
        for index in range(count)
    ]


def _signing_information(code: int, *, dynamic: bool) -> Mapping[str, object]:
    information = ctypes.c_void_p()
    flags = _SEC_CS_SIGNING_INFORMATION
    if dynamic:
        flags |= _SEC_CS_DYNAMIC_INFORMATION
    _check_status(
        _SECURITY.SecCodeCopySigningInformation(
            code,
            flags,
            ctypes.byref(information),
        ),
        "SecCodeCopySigningInformation",
    )
    try:
        static_flags = _number(
            _dictionary_value(information.value, "kSecCodeInfoFlags")
        )
        result = {
            "unique_cdhash": _data_hex(
                _dictionary_value(information.value, "kSecCodeInfoUnique")
            ),
            "all_cdhashes": _data_array(
                information.value,
                "kSecCodeInfoCdHashes",
            ),
            "digest_algorithms": _number_array(
                information.value,
                "kSecCodeInfoDigestAlgorithms",
            ),
            "static_code_flags": static_flags,
            "signing_kind": "ad_hoc" if static_flags & _CS_ADHOC else "cms",
            "identifier": _string(
                _dictionary_value(information.value, "kSecCodeInfoIdentifier")
            ),
        }
        if dynamic:
            result["dynamic_status_flags"] = _number(
                _dictionary_value(information.value, "kSecCodeInfoStatus")
            )
        return result
    finally:
        _CORE_FOUNDATION.CFRelease(information)


def _bounded_range(offset: int, size: int, limit: int, label: str) -> tuple[int, int]:
    if offset < 0 or size < 0 or offset > limit or size > limit - offset:
        raise MacOSCodeIdentityError("{} is out of bounds".format(label))
    return offset, offset + size


def _active_macho_slice(payload: bytes) -> tuple[int, int, str]:
    if len(payload) < 4:
        raise MacOSCodeIdentityError("Mach-O file is truncated")
    magic = payload[:4]
    if magic in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}:
        is_64 = magic == b"\xca\xfe\xba\xbf"
        if len(payload) < 8:
            raise MacOSCodeIdentityError("fat Mach-O header is truncated")
        count = struct.unpack_from(">I", payload, 4)[0]
        record_size = 32 if is_64 else 20
        _bounded_range(8, count * record_size, len(payload), "fat architecture table")
        matches = []
        occupied = [(0, 8 + count * record_size)]
        for index in range(count):
            cursor = 8 + index * record_size
            if is_64:
                cpu_type, _, offset, size, _, _ = struct.unpack_from(
                    ">iiQQII",
                    payload,
                    cursor,
                )
            else:
                cpu_type, _, offset, size, _ = struct.unpack_from(
                    ">iiIII",
                    payload,
                    cursor,
                )
            start, end = _bounded_range(
                int(offset),
                int(size),
                len(payload),
                "fat Mach-O slice",
            )
            for other_start, other_end in occupied:
                if max(start, other_start) < min(end, other_end):
                    raise MacOSCodeIdentityError("fat Mach-O slices overlap")
            occupied.append((start, end))
            if cpu_type == _CPU_TYPE_ARM64:
                matches.append((start, end - start, "arm64"))
        if len(matches) != 1:
            raise MacOSCodeIdentityError(
                "fat Mach-O must contain exactly one active arm64 slice"
            )
        return matches[0]
    if magic == b"\xcf\xfa\xed\xfe":
        endian = "<"
        expected_cpu = struct.unpack_from("<i", payload, 4)[0]
    elif magic == b"\xfe\xed\xfa\xcf":
        endian = ">"
        expected_cpu = struct.unpack_from(">i", payload, 4)[0]
    else:
        raise MacOSCodeIdentityError("only thin Mach-O64 or fat Mach-O is supported")
    if expected_cpu != _CPU_TYPE_ARM64:
        raise MacOSCodeIdentityError("thin Mach-O is not arm64")
    return 0, len(payload), "arm64"


def _code_signature_range(
    payload: bytes,
    slice_offset: int,
    slice_size: int,
) -> tuple[int, int]:
    _bounded_range(slice_offset, 32, len(payload), "Mach-O64 header")
    magic = payload[slice_offset : slice_offset + 4]
    if magic == b"\xcf\xfa\xed\xfe":
        endian = "<"
    elif magic == b"\xfe\xed\xfa\xcf":
        endian = ">"
    else:
        raise MacOSCodeIdentityError("active slice is not Mach-O64")
    values = struct.unpack_from(endian + "IiiIIIII", payload, slice_offset)
    _, cpu_type, _, file_type, command_count, command_size, _, _ = values
    if cpu_type != _CPU_TYPE_ARM64 or file_type != _MH_EXECUTE:
        raise MacOSCodeIdentityError("Mach-O slice is not an arm64 executable")
    command_start = slice_offset + 32
    _, command_end = _bounded_range(
        command_start,
        command_size,
        slice_offset + slice_size,
        "Mach-O load commands",
    )
    cursor = command_start
    signatures = []
    for _ in range(command_count):
        if cursor > command_end - 8:
            raise MacOSCodeIdentityError("Mach-O load command is truncated")
        command, size = struct.unpack_from(endian + "II", payload, cursor)
        if size < 8 or size % 8 != 0 or size > command_end - cursor:
            raise MacOSCodeIdentityError("Mach-O load command size is invalid")
        if command == _LC_CODE_SIGNATURE:
            if size < 16:
                raise MacOSCodeIdentityError("LC_CODE_SIGNATURE is truncated")
            data_offset, data_size = struct.unpack_from(
                endian + "II",
                payload,
                cursor + 8,
            )
            start, end = _bounded_range(
                slice_offset + data_offset,
                data_size,
                slice_offset + slice_size,
                "embedded code signature",
            )
            signatures.append((start, end - start))
        cursor += size
    if cursor != command_end or len(signatures) != 1:
        raise MacOSCodeIdentityError(
            "Mach-O must contain exactly one bounded LC_CODE_SIGNATURE"
        )
    return signatures[0]


def _code_directory_minimum(version: int) -> int:
    if version < 0x20000:
        raise MacOSCodeIdentityError("CodeDirectory version is unsupported")
    if version >= 0x20600:
        return 108
    if version >= 0x20500:
        return 96
    if version >= 0x20400:
        return 88
    if version >= 0x20300:
        return 64
    if version >= 0x20200:
        return 52
    if version >= 0x20100:
        return 48
    return 44


def _parse_code_directory(blob: bytes) -> Mapping[str, object]:
    if len(blob) < 44:
        raise MacOSCodeIdentityError("CodeDirectory is truncated")
    (
        magic,
        length,
        version,
        flags,
        hash_offset,
        identifier_offset,
        special_slots,
        code_slots,
        _,
    ) = struct.unpack_from(">9I", blob, 0)
    hash_size, hash_type = struct.unpack_from(">BB", blob, 36)
    if magic != _CSMAGIC_CODEDIRECTORY or length != len(blob):
        raise MacOSCodeIdentityError("CodeDirectory length or magic differs")
    minimum = _code_directory_minimum(version)
    if len(blob) < minimum:
        raise MacOSCodeIdentityError("CodeDirectory version fields are truncated")
    algorithm = _HASHES.get(hash_type)
    if algorithm is None or hash_size != algorithm[1]:
        raise MacOSCodeIdentityError("CodeDirectory hash algorithm is unsupported")
    special_bytes = special_slots * hash_size
    code_bytes = code_slots * hash_size
    if hash_offset < special_bytes:
        raise MacOSCodeIdentityError("CodeDirectory special-slot arithmetic underflows")
    _bounded_range(
        hash_offset - special_bytes,
        special_bytes + code_bytes,
        len(blob),
        "CodeDirectory hash table",
    )
    if identifier_offset < minimum or identifier_offset >= len(blob):
        raise MacOSCodeIdentityError("CodeDirectory identifier offset is invalid")
    terminator = blob.find(b"\x00", identifier_offset)
    if terminator < 0:
        raise MacOSCodeIdentityError("CodeDirectory identifier is unterminated")
    try:
        identifier = blob[identifier_offset:terminator].decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise MacOSCodeIdentityError("CodeDirectory identifier is not UTF-8") from error
    if not identifier:
        raise MacOSCodeIdentityError("CodeDirectory identifier is empty")
    digest = hashlib.new(algorithm[0], blob).digest()
    return {
        "algorithm": hash_type,
        "cdhash": digest[:20].hex(),
        "flags": flags,
        "identifier": identifier,
    }


def _parse_macho_code_identity(payload: bytes) -> Mapping[str, object]:
    slice_offset, slice_size, architecture = _active_macho_slice(payload)
    signature_offset, signature_size = _code_signature_range(
        payload,
        slice_offset,
        slice_size,
    )
    signature = payload[signature_offset : signature_offset + signature_size]
    if len(signature) < 12:
        raise MacOSCodeIdentityError("embedded signature SuperBlob is truncated")
    magic, length, count = struct.unpack_from(">III", signature, 0)
    if (
        magic != _CSMAGIC_EMBEDDED_SIGNATURE
        or length < 12
        or length > len(signature)
        or any(signature[length:])
    ):
        raise MacOSCodeIdentityError("embedded signature SuperBlob differs")
    signature = signature[:length]
    _bounded_range(12, count * 8, len(signature), "SuperBlob index")
    occupied = [(0, 12 + count * 8)]
    code_directories = []
    seen_slots = set()
    seen_offsets = set()
    for index in range(count):
        slot, offset = struct.unpack_from(">II", signature, 12 + index * 8)
        if slot in seen_slots or offset in seen_offsets:
            raise MacOSCodeIdentityError("SuperBlob index is duplicated")
        seen_slots.add(slot)
        seen_offsets.add(offset)
        _bounded_range(offset, 8, len(signature), "SuperBlob child header")
        _, child_length = struct.unpack_from(">II", signature, offset)
        start, end = _bounded_range(
            offset,
            child_length,
            len(signature),
            "SuperBlob child",
        )
        for other_start, other_end in occupied:
            if max(start, other_start) < min(end, other_end):
                raise MacOSCodeIdentityError("SuperBlob children overlap")
        occupied.append((start, end))
        child_magic = struct.unpack_from(">I", signature, offset)[0]
        if child_magic == _CSMAGIC_CODEDIRECTORY:
            if slot != _CSSLOT_CODEDIRECTORY and slot not in (
                _CSSLOT_ALTERNATE_CODEDIRECTORIES
            ):
                raise MacOSCodeIdentityError("CodeDirectory uses an invalid slot")
            code_directories.append(
                _parse_code_directory(signature[start:end])
            )
    if not code_directories:
        raise MacOSCodeIdentityError("embedded signature has no CodeDirectory")
    pairs = sorted(
        (int(row["algorithm"]), str(row["cdhash"]))
        for row in code_directories
    )
    if len(pairs) != len(set(pairs)):
        raise MacOSCodeIdentityError("CodeDirectory algorithm/hash pair is duplicated")
    flags = {int(row["flags"]) for row in code_directories}
    identifiers = {str(row["identifier"]) for row in code_directories}
    if len(flags) != 1 or len(identifiers) != 1:
        raise MacOSCodeIdentityError("CodeDirectory identities disagree")
    static_flags = next(iter(flags))
    return {
        "architecture": architecture,
        "all_cdhashes": [value for _, value in pairs],
        "digest_algorithms": [algorithm for algorithm, _ in pairs],
        "static_code_flags": static_flags,
        "signing_kind": "ad_hoc" if static_flags & _CS_ADHOC else "cms",
        "identifier": next(iter(identifiers)),
    }


def _read_stable_regular(path: Path) -> bytes:
    if not path.is_absolute():
        raise MacOSCodeIdentityError("code identity path must be absolute")
    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise MacOSCodeIdentityError("code identity path is not a regular file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise MacOSCodeIdentityError("code identity file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    final = os.lstat(path)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if stable(before) != stable(opened) or stable(before) != stable(after) or stable(before) != stable(final):
        raise MacOSCodeIdentityError("code identity file changed while reading")
    return b"".join(chunks)


def _security_static_information(path: Path) -> Mapping[str, object]:
    encoded = os.fsencode(path)
    raw = (ctypes.c_ubyte * len(encoded)).from_buffer_copy(encoded)
    url = _CORE_FOUNDATION.CFURLCreateFromFileSystemRepresentation(
        None,
        raw,
        len(encoded),
        False,
    )
    if not url:
        raise MacOSCodeIdentityError("code identity URL cannot be created")
    code = ctypes.c_void_p()
    try:
        _check_status(
            _SECURITY.SecStaticCodeCreateWithPath(
                url,
                0,
                ctypes.byref(code),
            ),
            "SecStaticCodeCreateWithPath",
        )
        _check_status(
            _SECURITY.SecStaticCodeCheckValidity(
                code,
                _SEC_CS_NO_NETWORK_ACCESS,
                None,
            ),
            "SecStaticCodeCheckValidity",
        )
        return dict(_signing_information(code.value, dynamic=False))
    finally:
        if code.value:
            _CORE_FOUNDATION.CFRelease(code)
        _CORE_FOUNDATION.CFRelease(url)


def static_code_identity(path: Path) -> Mapping[str, object]:
    """Bind same-FD Mach-O CodeDirectories to Security.framework identity."""

    if not path.is_absolute():
        raise MacOSCodeIdentityError("code identity path must be absolute")
    before = os.lstat(path)
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or stat.S_IMODE(before.st_mode) & 0o111 == 0
    ):
        raise MacOSCodeIdentityError(
            "code identity path is not a singular executable file"
        )
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or opened.st_nlink != 1
        ):
            raise MacOSCodeIdentityError("code identity file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
        parsed = _parse_macho_code_identity(payload)
        security = _security_static_information(path)
        after = os.fstat(descriptor)
        final = os.lstat(path)
    finally:
        os.close(descriptor)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_nlink,
        stat.S_IMODE(value.st_mode),
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if (
        stable(before) != stable(opened)
        or stable(before) != stable(after)
        or stable(before) != stable(final)
        or len(payload) != before.st_size
    ):
        raise MacOSCodeIdentityError("code identity file changed during inspection")
    parsed_pairs = sorted(
        zip(parsed["digest_algorithms"], parsed["all_cdhashes"])
    )
    security_pairs = sorted(
        zip(security["digest_algorithms"], security["all_cdhashes"])
    )
    if (
        parsed_pairs != security_pairs
        or security.get("unique_cdhash") not in parsed["all_cdhashes"]
        or any(
            parsed.get(field) != security.get(field)
            for field in (
                "static_code_flags",
                "signing_kind",
                "identifier",
            )
        )
    ):
        raise MacOSCodeIdentityError(
            "same-FD Mach-O and Security.framework identities differ"
        )
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "macos_code_identity_v1",
        "architecture": parsed["architecture"],
        "file_sha256": hashlib.sha256(payload).hexdigest(),
        "unique_cdhash": security["unique_cdhash"],
        "all_cdhashes": [value for _, value in parsed_pairs],
        "digest_algorithms": [algorithm for algorithm, _ in parsed_pairs],
        "static_code_flags": parsed["static_code_flags"],
        "signing_kind": parsed["signing_kind"],
        "identifier": parsed["identifier"],
    }


def dynamic_code_identity(pid: int) -> Mapping[str, object]:
    """Validate and return the kernel-bound identity of one running PID."""

    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise MacOSCodeIdentityError("running code PID is invalid")
    pid_value = ctypes.c_int32(pid)
    number = _CORE_FOUNDATION.CFNumberCreate(
        None,
        _CF_NUMBER_SINT32,
        ctypes.byref(pid_value),
    )
    attributes = _CORE_FOUNDATION.CFDictionaryCreateMutable(
        None,
        0,
        None,
        None,
    )
    if not number or not attributes:
        if number:
            _CORE_FOUNDATION.CFRelease(number)
        if attributes:
            _CORE_FOUNDATION.CFRelease(attributes)
        raise MacOSCodeIdentityError("running code attributes cannot be created")
    code = ctypes.c_void_p()
    try:
        _CORE_FOUNDATION.CFDictionarySetValue(
            attributes,
            _KEYS["kSecGuestAttributePid"],
            number,
        )
        _check_status(
            _SECURITY.SecCodeCopyGuestWithAttributes(
                None,
                attributes,
                0,
                ctypes.byref(code),
            ),
            "SecCodeCopyGuestWithAttributes",
        )
        _check_status(
            _SECURITY.SecCodeCheckValidity(
                code,
                _SEC_CS_NO_NETWORK_ACCESS,
                None,
            ),
            "SecCodeCheckValidity",
        )
        return _signing_information(code.value, dynamic=True)
    finally:
        if code.value:
            _CORE_FOUNDATION.CFRelease(code)
        _CORE_FOUNDATION.CFRelease(attributes)
        _CORE_FOUNDATION.CFRelease(number)


def authorize_running_code(
    pid: int,
    expected: Mapping[str, object],
) -> Mapping[str, object]:
    """Authorize a suspended PID only when its signed identity is exact."""

    required = {
        "schema_version",
        "artifact_kind",
        "architecture",
        "file_sha256",
        "unique_cdhash",
        "all_cdhashes",
        "digest_algorithms",
        "static_code_flags",
        "signing_kind",
        "identifier",
    }
    identity_lists_valid = (
        isinstance(expected.get("all_cdhashes"), list)
        and bool(expected["all_cdhashes"])
        and len(expected["all_cdhashes"])
        == len(set(expected["all_cdhashes"]))
        and all(
            isinstance(value, str)
            and 40 <= len(value) <= 128
            and all(character in "0123456789abcdef" for character in value)
            for value in expected["all_cdhashes"]
        )
        and isinstance(expected.get("digest_algorithms"), list)
        and len(expected["digest_algorithms"]) == len(expected["all_cdhashes"])
        and all(
            isinstance(value, int) and not isinstance(value, bool) and value in _HASHES
            for value in expected["digest_algorithms"]
        )
    )
    if (
        set(expected) != required
        or expected.get("schema_version") != "1.0.0"
        or expected.get("artifact_kind") != "macos_code_identity_v1"
        or expected.get("architecture") != platform.machine()
        or not isinstance(expected.get("file_sha256"), str)
        or len(str(expected.get("file_sha256"))) != 64
        or not isinstance(expected.get("unique_cdhash"), str)
        or expected.get("unique_cdhash") not in expected.get("all_cdhashes", [])
        or not identity_lists_valid
        or not isinstance(expected.get("static_code_flags"), int)
        or isinstance(expected.get("static_code_flags"), bool)
        or expected.get("signing_kind") not in {"ad_hoc", "cms"}
        or not isinstance(expected.get("identifier"), str)
        or not expected.get("identifier")
    ):
        raise MacOSCodeIdentityError("expected macOS code identity is invalid")
    observed = dynamic_code_identity(pid)
    for field in (
        "unique_cdhash",
        "static_code_flags",
        "signing_kind",
        "identifier",
    ):
        if observed.get(field) != expected.get(field):
            raise MacOSCodeIdentityError(
                "running macOS code identity differs: {}".format(field)
            )
    expected_pairs = sorted(
        zip(expected["digest_algorithms"], expected["all_cdhashes"])
    )
    observed_pairs = sorted(
        zip(observed["digest_algorithms"], observed["all_cdhashes"])
    )
    if expected_pairs != observed_pairs:
        raise MacOSCodeIdentityError(
            "running macOS code identity differs: algorithm/CDHash pairs"
        )
    status = observed.get("dynamic_status_flags")
    if (
        not isinstance(status, int)
        or isinstance(status, bool)
        or status & (_CS_VALID | _CS_KILL | _CS_NO_UNTRUSTED_HELPERS | _CS_SIGNED)
        != (_CS_VALID | _CS_KILL | _CS_NO_UNTRUSTED_HELPERS | _CS_SIGNED)
        or status
        & (_CS_GET_TASK_ALLOW | _CS_INVALID_ALLOWED | _CS_KILLED | _CS_DEBUGGED)
        != 0
    ):
        raise MacOSCodeIdentityError("running macOS code status is unsafe")
    return observed
