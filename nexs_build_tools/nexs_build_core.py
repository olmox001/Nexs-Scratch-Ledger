#!/usr/bin/env python3
"""Shared hardened build/release logic for Nexs-Scratch-System.

This module is intentionally stdlib-only. It is used by both POSIX and
PowerShell wrappers so archive/catalogue semantics and binary verification do
not diverge between hosts.
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import gzip
import hashlib
import json
import os
import re
import secrets
import stat
import struct
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

CATALOGUE_SCHEMA = 4
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_FILE_BYTES = 1024 * 1024 * 1024
MAX_DEPENDENCY_WHEEL_BYTES = 256 * 1024 * 1024
MAX_ARCHIVE_BYTES = 4 * 1024 * 1024 * 1024
MAX_ARCHIVE_FILES = 200_000
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 8 * 1024 * 1024 * 1024
# Nuitka 4.2.2 is currently published on PyPI as an sdist only. The exact
# source artifact is trusted by SHA-256 and is intentionally not accepted by
# generic source-distribution rules. This prevents silently replacing the
# compiler source with another artifact carrying the same version.
TRUSTED_SOURCE_DISTS: dict[tuple[str, str, str], str] = {
    ("nuitka", "4.2.2", "nuitka-4.2.2.tar.gz"): "29c1bfb6f53154e620b38cf6167cbb03f54043f6e08ef7d3f2d5080a95df7e0d",
}
SOURCE_IDENTITY_MARKER = '    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":'
BUILD_IDENTITY_INSERT = (
    '    if len(sys.argv) > 1 and sys.argv[1] == "--build-identity":\n'
    '        identity = PREF_compute_runtime_identity()\n'
    '        print(json.dumps(identity, ensure_ascii=True, sort_keys=True, separators=(",", ":")))\n'
    '        return\n\n'
)

TARGETS: dict[str, dict[str, str]] = {
    "macos-x86_64": {"os": "macos", "arch": "x86_64", "libc": "apple", "format": "macho"},
    "macos-arm64": {"os": "macos", "arch": "arm64", "libc": "apple", "format": "macho"},
    "linux-x86_64": {"os": "linux", "arch": "x86_64", "libc": "glibc", "format": "elf"},
    "linux-aarch64": {"os": "linux", "arch": "aarch64", "libc": "glibc", "format": "elf"},
    "linux-musl-x86_64": {"os": "linux", "arch": "x86_64", "libc": "musl", "format": "elf"},
    "linux-musl-aarch64": {"os": "linux", "arch": "aarch64", "libc": "musl", "format": "elf"},
    "windows-x86_64": {"os": "windows", "arch": "x86_64", "libc": "ucrt-msvc", "format": "pe"},
    "windows-arm64": {"os": "windows", "arch": "arm64", "libc": "ucrt-msvc", "format": "pe"},
}


class BuildError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise BuildError(message)


def canonical_json(value: Any) -> bytes:
    try:
        raw = json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise BuildError("Unable to encode canonical JSON.") from exc
    if len(raw) > MAX_JSON_BYTES:
        raise BuildError("Canonical JSON exceeds configured limit.")
    return raw


def _lstat(path: Path, label: str) -> os.stat_result:
    try:
        return path.lstat()
    except OSError as exc:
        raise BuildError(f"Unable to inspect {label}: {path}") from exc


def _is_reparse_or_link(st: os.stat_result) -> bool:
    if stat.S_ISLNK(st.st_mode):
        return True
    # Windows reparse points include junctions and other filesystem links that
    # are not necessarily reported as POSIX symlinks.
    return bool(getattr(st, "st_file_attributes", 0) & 0x0400)


def _stat_identity(st: os.stat_result) -> tuple[int, int, int, int, int]:
    """Return metadata that should remain stable during a verified file read."""
    return (
        getattr(st, "st_dev", 0),
        getattr(st, "st_ino", 0),
        getattr(st, "st_size", 0),
        getattr(st, "st_mtime_ns", 0),
        getattr(st, "st_ctime_ns", 0),
    )


def ensure_no_link_ancestors(path: Path, stop_at: Path | None = None, label: str = "path") -> None:
    """Reject symlink/reparse ancestors up to an optional trusted directory."""
    current = path.absolute()
    stop = stop_at.absolute() if stop_at is not None else None
    while True:
        try:
            st = current.lstat()
        except OSError as exc:
            raise BuildError(f"Unable to inspect {label} ancestor: {current}") from exc
        if _is_reparse_or_link(st):
            raise BuildError(f"{label} contains a symlink/reparse ancestor: {current}")
        if stop is not None and current == stop:
            return
        parent = current.parent
        if parent == current:
            return
        current = parent


def ensure_regular(path: Path, label: str) -> None:
    st = _lstat(path, label)
    if _is_reparse_or_link(st) or not stat.S_ISREG(st.st_mode):
        raise BuildError(f"{label} is missing, non-regular, or a link/reparse point: {path}")


def ensure_directory(path: Path, label: str, *, allow_create: bool = False) -> None:
    try:
        if allow_create and not path.exists():
            path.mkdir(parents=True, exist_ok=True)
        st = _lstat(path, label)
    except OSError as exc:
        raise BuildError(f"Unable to inspect/create {label}: {path}") from exc
    if _is_reparse_or_link(st) or not stat.S_ISDIR(st.st_mode):
        raise BuildError(f"Directory is missing, non-directory, or a link/reparse point for {label}: {path}")


def _open_readonly_stable(path: Path) -> tuple[int, os.stat_result]:
    """Open a regular file without following links and defeat path-swap races."""
    pre = _lstat(path, "file")
    if _is_reparse_or_link(pre) or not stat.S_ISREG(pre.st_mode):
        raise BuildError(f"File is missing, non-regular, or a link/reparse point: {path}")
    flags = (os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_BINARY", 0))
    try:
        fd = os.open(os.fspath(path), flags)
    except OSError as exc:
        raise BuildError(f"Unable to open file safely: {path}") from exc
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise BuildError(f"Opened object is not regular: {path}")
        if _stat_identity(pre) != _stat_identity(opened):
            raise BuildError(f"File changed between path validation and open: {path}")
        return fd, opened
    except Exception:
        os.close(fd)
        raise


def read_bounded(path: Path, maximum: int) -> bytes:
    if type(maximum) is not int or maximum < 0:
        raise BuildError("File read limit must be a non-negative integer.")
    ensure_regular(path, "file")
    fd, initial = _open_readonly_stable(path)
    try:
        if initial.st_size > maximum:
            raise BuildError(f"File exceeds configured limit: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, maximum - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise BuildError(f"File exceeds configured limit: {path}")
            chunks.append(chunk)
        final = os.fstat(fd)
        if _stat_identity(initial) != _stat_identity(final):
            raise BuildError(f"File changed while being read: {path}")
        return b"".join(chunks)
    finally:
        os.close(fd)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path, maximum: int = MAX_FILE_BYTES) -> str:
    if type(maximum) is not int or maximum < 0:
        raise BuildError("File hash limit must be a non-negative integer.")
    ensure_regular(path, "file")
    fd, initial = _open_readonly_stable(path)
    digest = hashlib.sha256()
    total = 0
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise BuildError(f"File exceeds configured hash limit: {path}")
            digest.update(chunk)
        final = os.fstat(fd)
        if _stat_identity(initial) != _stat_identity(final):
            raise BuildError(f"File changed while being hashed: {path}")
    except OSError as exc:
        raise BuildError(f"Unable to hash file: {path}") from exc
    finally:
        os.close(fd)
    return digest.hexdigest()


def stable_file_record(path: Path, maximum: int = MAX_FILE_BYTES) -> dict[str, Any]:
    """Return a hash/size record from one stable file descriptor."""
    if type(maximum) is not int or maximum < 0:
        raise BuildError("File record limit must be a non-negative integer.")
    ensure_regular(path, "file")
    fd, initial = _open_readonly_stable(path)
    digest = hashlib.sha256()
    total = 0
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise BuildError(f"File exceeds configured hash limit: {path}")
            digest.update(chunk)
        final = os.fstat(fd)
        if _stat_identity(initial) != _stat_identity(final):
            raise BuildError(f"File changed while being hashed: {path}")
        if total != initial.st_size:
            raise BuildError(f"File size changed while being hashed: {path}")
    except OSError as exc:
        raise BuildError(f"Unable to hash file: {path}") from exc
    finally:
        os.close(fd)
    return {"sha256": digest.hexdigest(), "size": total}


def sync_regular_file(path: Path) -> None:
    """Synchronize one generated regular file before it is atomically published."""
    ensure_regular(path, "generated file")
    flags = (os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
             | getattr(os, "O_BINARY", 0))
    try:
        fd = os.open(os.fspath(path), flags)
    except OSError as exc:
        raise BuildError(f"Unable to open generated file for synchronization: {path}") from exc
    try:
        initial = os.fstat(fd)
        if not stat.S_ISREG(initial.st_mode):
            raise BuildError(f"Generated file is not regular: {path}")
        os.fsync(fd)
        final = os.fstat(fd)
        if _stat_identity(initial) != _stat_identity(final):
            raise BuildError(f"Generated file changed during synchronization: {path}")
    except OSError as exc:
        raise BuildError(f"Unable to synchronize generated file: {path}") from exc
    finally:
        os.close(fd)


def validate_relative(path_text: str) -> str:
    if not isinstance(path_text, str) or not path_text or "\x00" in path_text or "\\" in path_text:
        raise BuildError(f"Unsafe relative path: {path_text!r}")
    p = PurePosixPath(path_text)
    canonical = p.as_posix()
    if (p.is_absolute() or any(part in ("", ".", "..") for part in p.parts)
            or canonical != path_text or canonical.startswith("/") or canonical.endswith("/")):
        raise BuildError(f"Unsafe or non-canonical relative path: {path_text!r}")
    for part in p.parts:
        if len(part) > 255 or any(ord(ch) < 32 or ord(ch) == 127 for ch in part):
            raise BuildError(f"Unsafe relative path component: {path_text!r}")
        if part.endswith((" ", ".")) or ":" in part:
            raise BuildError(f"Relative path is not portable across Windows filesystems: {path_text!r}")
        reserved = part.split(".", 1)[0].upper()
        if reserved in {"CON", "PRN", "AUX", "NUL"} or re.fullmatch(r"(?:COM|LPT)[1-9]", reserved):
            raise BuildError(f"Windows-reserved path component: {path_text!r}")
    return canonical


def validate_version(version: str) -> str:
    if not isinstance(version, str) or not version or len(version) > 64:
        raise BuildError("Invalid release version.")
    parts = version.split(".")
    if len(parts) != 4 or any(not part.isdigit() for part in parts):
        raise BuildError("Release version must be N.N.N.N.")
    if any(len(part) > 10 for part in parts):
        raise BuildError("Release version component is too long.")
    return version


# ---------------------------------------------------------------------------
# Dynamic .gitignore support (aligned with generate_build_manifests.{sh,ps1})
# ---------------------------------------------------------------------------

_GITIGNORE_INVARIANTS: tuple[str, ...] = ("build", "release", ".git", ".venv", "__pycache__")
_GITIGNORE_NEVER_EXCLUDE: frozenset[str] = frozenset({"BUILD_KIT_SHA256SUMS", "BUILD_TOOLS_SHA256SUMS"})


def _read_gitignore_patterns(root_dir: Path) -> list[str]:
    """Read `<root>/.gitignore` and return its active patterns.

    Returns an empty list when the file is missing, unreadable, a symlink, or
    not a regular file. Comment lines, blank lines, and negated patterns are
    dropped. Trailing whitespace is removed.
    """
    gitignore = root_dir / ".gitignore"
    try:
        st = gitignore.lstat()
    except FileNotFoundError:
        return []
    except OSError:
        return []
    if _is_reparse_or_link(st) or not stat.S_ISREG(st.st_mode):
        return []
    try:
        raw = read_bounded(gitignore, MAX_JSON_BYTES)
    except BuildError:
        return []
    patterns: list[str] = []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        stripped = line.rstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("!"):
            continue
        patterns.append(stripped)
    return patterns


def _gitignore_match(rel_posix: str, pattern: str) -> bool:
    """Match a single .gitignore pattern against a POSIX relative path."""
    if not pattern:
        return False
    p = pattern
    if p.startswith("/"):
        p = p[1:]
    if p.endswith("/"):
        p = p[:-1]
    if not p:
        return False

    if "/" in p:
        # Path pattern: match against the full relative path, plus common
        # suffixes so patterns like "docs/*.tmp" work at any depth.
        if (fnmatch.fnmatchcase(rel_posix, p)
                or fnmatch.fnmatchcase(rel_posix, f"{p}/*")
                or fnmatch.fnmatchcase(rel_posix, f"*/{p}")
                or fnmatch.fnmatchcase(rel_posix, f"*/{p}/*")):
            return True
        return False

    # Basename pattern: match any path component.
    for component in rel_posix.split("/"):
        if fnmatch.fnmatchcase(component, p):
            return True
    return False


def _effective_ignore_patterns(root_dir: Path) -> list[str]:
    """Return the merged .gitignore + invariants list for ``root_dir``."""
    user_patterns = _read_gitignore_patterns(root_dir)
    merged: list[str] = list(user_patterns)
    for pattern in _GITIGNORE_INVARIANTS:
        if pattern not in merged:
            merged.append(pattern)
    return merged


def _is_gitignore_excluded(rel_posix: str, patterns: list[str]) -> bool:
    """Return True when ``rel_posix`` should be skipped by audit functions.

    The two anchors BUILD_KIT_SHA256SUMS / BUILD_TOOLS_SHA256SUMS are never
    excluded so that the kit↔tools binding stays verifiable.
    """
    basename = rel_posix.rsplit("/", 1)[-1]
    if basename in _GITIGNORE_NEVER_EXCLUDE:
        return False
    for pattern in patterns:
        if _gitignore_match(rel_posix, pattern):
            return True
    return False


def iter_tree(root: Path) -> Iterable[tuple[str, Path]]:
    ensure_directory(root, "package")
    root_real = root.resolve(strict=True)
    seen_real_dirs: set[Path] = {root_real}
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        dirs.sort()
        files.sort()
        safe_dirs: list[str] = []
        for name in dirs:
            child = current_path / name
            st = _lstat(child, "package directory")
            if _is_reparse_or_link(st) or not stat.S_ISDIR(st.st_mode):
                raise BuildError(f"Package contains unsafe directory: {child}")
            real = child.resolve(strict=True)
            try:
                if os.path.commonpath([os.fspath(root_real), os.fspath(real)]) != os.fspath(root_real):
                    raise BuildError(f"Package directory escapes package root: {child}")
            except ValueError as exc:
                raise BuildError(f"Package directory has incompatible path semantics: {child}") from exc
            if real in seen_real_dirs:
                raise BuildError(f"Package directory alias detected: {child}")
            seen_real_dirs.add(real)
            safe_dirs.append(name)
        dirs[:] = safe_dirs
        for name in files:
            child = current_path / name
            ensure_regular(child, "package file")
            rel = validate_relative(child.relative_to(root).as_posix())
            yield rel, child


def validate_source(source: Path) -> str:
    ensure_regular(source, "source")
    data = read_bounded(source, MAX_FILE_BYTES)
    try:
        text = data.decode("utf-8")
        ast.parse(text, filename=str(source))
    except (UnicodeDecodeError, SyntaxError) as exc:
        raise BuildError(f"Source is not valid UTF-8 Python: {source}") from exc
    return sha256_bytes(data)


def prepare_source(source: Path, output: Path) -> None:
    source_hash_before = validate_source(source)
    raw_source = read_bounded(source, MAX_FILE_BYTES)
    try:
        text = raw_source.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"Source is not valid UTF-8 Python: {source}") from exc
    if text.count(SOURCE_IDENTITY_MARKER) != 1:
        raise BuildError("Build identity insertion marker must occur exactly once in the source.")
    prepared = text.replace(SOURCE_IDENTITY_MARKER, BUILD_IDENTITY_INSERT + SOURCE_IDENTITY_MARKER, 1)
    try:
        ast.parse(prepared, filename=str(output))
    except SyntaxError as exc:
        raise BuildError("Prepared source failed syntax validation.") from exc
    if output.is_symlink() or (output.exists() and not output.is_file()):
        raise BuildError(f"Unsafe prepared-source destination: {output}")
    _write_atomic_bytes(output, prepared.encode("utf-8"), 0o600)
    if stable_file_record(source)["sha256"] != source_hash_before:
        raise BuildError("Source changed during preparation.")
    ensure_regular(output, "prepared source")


def parse_identity(raw: bytes) -> dict[str, Any]:
    try:
        identity = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError("Build identity JSON is invalid.") from exc
    if not isinstance(identity, dict):
        raise BuildError("Build identity must be a JSON object.")
    required = {
        "schema_version", "program_version", "program_hash", "extensions",
        "python_implementation", "python_version", "runtime_fingerprint",
        "program_version_hash", "program_path",
    }
    if set(identity) != required:
        raise BuildError("Build identity field set is invalid.")
    if type(identity["schema_version"]) is not int or identity["schema_version"] != 4:
        raise BuildError("Build identity schema version is invalid.")
    for key in ("program_hash", "runtime_fingerprint"):
        value = identity[key]
        if not isinstance(value, str) or len(value) != 64:
            raise BuildError(f"Invalid identity hash: {key}")
        try:
            bytes.fromhex(value)
        except ValueError as exc:
            raise BuildError(f"Invalid identity hash: {key}") from exc
    if not isinstance(identity["program_version"], str) or not identity["program_version"]:
        raise BuildError("Build identity program_version is invalid.")
    # main.py sets this field from sys.implementation.name, which the Python
    # spec guarantees is the lowercase "cpython" (unlike platform.python_implementation(),
    # which is capitalized and used instead for the separate build-provenance record below).
    if identity["python_implementation"] != "cpython":
        raise BuildError("Build identity is not CPython.")
    if not isinstance(identity["python_version"], str) or not identity["python_version"].startswith("3.12."):
        raise BuildError("Build identity Python version is not CPython 3.12.x.")
    if identity["program_version_hash"] != f'{identity["program_version"]}+{identity["runtime_fingerprint"][:16]}':
        raise BuildError("Build identity program_version_hash binding is invalid.")
    if not isinstance(identity["program_path"], str) or not identity["program_path"]:
        raise BuildError("Build identity program_path is invalid.")
    validate_relative(identity["program_path"].replace(os.sep, "/"))
    extensions = identity["extensions"]
    if not isinstance(extensions, list) or len(extensions) > 256:
        raise BuildError("Build identity extensions field is invalid.")
    for extension in extensions:
        if not isinstance(extension, dict) or set(extension) != {"file", "sha256"}:
            raise BuildError("Build identity extension descriptor is invalid.")
        validate_relative(extension["file"].replace(os.sep, "/"))
        digest = extension["sha256"]
        if not isinstance(digest, str) or len(digest) != 64:
            raise BuildError("Build identity extension hash is invalid.")
        try:
            bytes.fromhex(digest)
        except ValueError as exc:
            raise BuildError("Build identity extension hash is invalid.") from exc
    return identity


def target_metadata(target: str) -> dict[str, str]:
    if not isinstance(target, str):
        raise BuildError(f"Unsupported target type: {type(target).__name__}")
    try:
        return dict(TARGETS[target]) | {"target": target}
    except KeyError as exc:
        raise BuildError(f"Unsupported target: {target}") from exc


def _elf_interpreter(data: bytes) -> str | None:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise BuildError("Not an ELF binary.")
    if data[4] != 2 or data[5] != 1:
        raise BuildError("Only ELF64 little-endian binaries are supported.")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    if phentsize < 56:
        raise BuildError("ELF program-header entry size is invalid.")
    interp: str | None = None
    for index in range(phnum):
        off = phoff + index * phentsize
        if off + 56 > len(data):
            raise BuildError("ELF program header exceeds file bounds.")
        p_type = struct.unpack_from("<I", data, off)[0]
        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_filesz = struct.unpack_from("<Q", data, off + 32)[0]
        if p_type == 3:
            end = p_offset + p_filesz
            if end > len(data):
                raise BuildError("ELF interpreter exceeds file bounds.")
            raw = data[p_offset:end].split(b"\x00", 1)[0]
            try:
                interp = raw.decode("ascii")
            except UnicodeDecodeError as exc:
                raise BuildError("ELF interpreter is not ASCII.") from exc
            break
    return interp


def detect_elf_arch(data: bytes) -> str:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise BuildError("Not an ELF binary.")
    if data[4] != 2 or data[5] != 1:
        raise BuildError("Only ELF64 little-endian binaries are supported.")
    machine = struct.unpack_from("<H", data, 18)[0]
    try:
        return {0x3E: "x86_64", 0xB7: "aarch64"}[machine]
    except KeyError as exc:
        raise BuildError(f"Unsupported ELF machine: 0x{machine:04x}") from exc


def detect_pe_arch(data: bytes) -> str:
    if len(data) < 64 or data[:2] != b"MZ":
        raise BuildError("Not a PE executable.")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if offset + 6 > len(data) or data[offset:offset + 4] != b"PE\x00\x00":
        raise BuildError("Invalid PE header.")
    machine = struct.unpack_from("<H", data, offset + 4)[0]
    try:
        return {0x8664: "x86_64", 0xAA64: "arm64"}[machine]
    except KeyError as exc:
        raise BuildError(f"Unsupported PE machine: 0x{machine:04x}") from exc


def detect_macho_arch(data: bytes) -> str:
    if len(data) < 8:
        raise BuildError("Mach-O file is too small.")
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in {0xCAFEBABE, 0xCAFEBABF, 0xBEBAFECA, 0xBFBAFECA}:
        raise BuildError("Universal/fat Mach-O is forbidden in per-architecture packages.")
    if magic not in {0xFEEDFACF, 0xCFFAEDFE}:
        raise BuildError("Not a 64-bit Mach-O binary.")
    endian = ">" if magic == 0xFEEDFACF else "<"
    cputype = struct.unpack_from(endian + "I", data, 4)[0]
    try:
        return {0x01000007: "x86_64", 0x0100000C: "arm64"}[cputype]
    except KeyError as exc:
        raise BuildError(f"Unsupported Mach-O CPU type: 0x{cputype:08x}") from exc


def verify_elf_libc_contract(data: bytes, target: str) -> None:
    """Reject obvious libc ABI contamination between glibc and musl payloads."""
    meta = target_metadata(target)
    if meta["format"] != "elf":
        return
    if meta["libc"] == "musl":
        forbidden = (b"GLIBC_", b"GLIBCXX_", b"ld-linux-", b"libc.so.6", b"libpthread.so.0", b"librt.so.1", b"libdl.so.2")
        hit = next((marker for marker in forbidden if marker in data), None)
        if hit is not None:
            raise BuildError(f"ELF payload contains a glibc ABI marker for musl target {target}: {hit!r}")
    elif meta["libc"] == "glibc":
        forbidden = (b"ld-musl-", b"libc.musl-")
        hit = next((marker for marker in forbidden if marker in data), None)
        if hit is not None:
            raise BuildError(f"ELF payload contains a musl ABI marker for glibc target {target}: {hit!r}")


def verify_binary_format(data: bytes, target: str, *, main_executable: bool = False) -> None:
    meta = target_metadata(target)
    expected_arch = meta["arch"]
    if meta["format"] == "elf":
        verify_elf_libc_contract(data, target)
        if detect_elf_arch(data) != expected_arch:
            raise BuildError(f"ELF architecture mismatch for {target}.")
        if main_executable:
            if meta["libc"] == "glibc":
                expected_interp = "/lib64/ld-linux-x86-64.so.2" if expected_arch == "x86_64" else "/lib/ld-linux-aarch64.so.1"
            elif meta["libc"] == "musl":
                expected_interp = "/lib/ld-musl-x86_64.so.1" if expected_arch == "x86_64" else "/lib/ld-musl-aarch64.so.1"
            else:
                raise BuildError(f"ELF target has unsupported libc contract: {target}")
            actual_interp = _elf_interpreter(data)
            if actual_interp != expected_interp:
                raise BuildError(f"ELF interpreter mismatch for {target}: expected {expected_interp!r}, got {actual_interp!r}")
    elif meta["format"] == "pe":
        if detect_pe_arch(data) != expected_arch:
            raise BuildError(f"PE architecture mismatch for {target}.")
    else:
        if detect_macho_arch(data) != expected_arch:
            raise BuildError(f"Mach-O architecture mismatch for {target}.")


def _requirement_rows(requirements_file: Path) -> dict[str, str]:
    rows: dict[str, str] = {}
    for raw in read_bounded(requirements_file, MAX_JSON_BYTES).decode("utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "[" in line or "<" in line or ">" in line or ";" in line or "@" in line:
            raise BuildError(f"Requirements must use exact package==version pins: {line!r}")
        if line.count("==") != 1:
            raise BuildError(f"Requirement is not an exact pin: {line!r}")
        name, version = (part.strip() for part in line.split("==", 1))
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", version):
            raise BuildError(f"Invalid exact requirement: {line!r}")
        key = re.sub(r"[-_.]+", "-", name).lower()
        if key in rows:
            raise BuildError(f"Duplicate requirement: {name}")
        rows[key] = version
    if not rows:
        raise BuildError("Requirements file contains no exact pins.")
    return rows


def _wheel_metadata(path: Path) -> tuple[str, str, list[str]]:
    """Read one bounded wheel METADATA and WHEEL manifest without extraction.

    Modern wheels (setuptools >= 80, pip >= 24) may ship nested
    ``*.dist-info`` directories for vendored dependencies. The primary
    metadata is always the root-level ``<name>-<version>.dist-info`` directory
    whose stem is closest to the wheel filename distribution. This function
    selects the correct candidate rather than rejecting any wheel that happens
    to contain a single, differently named dist-info directory.
    """
    ensure_regular(path, "dependency wheel")
    size = path.stat().st_size
    if size > MAX_DEPENDENCY_WHEEL_BYTES:
        raise BuildError(f"Dependency wheel exceeds configured size limit: {path.name}")

    # PEP 427 filename: {dist}-{ver}(-{build})?-{py}-{abi}-{plat}.whl
    stem = path.name[:-4] if path.name.lower().endswith(".whl") else path.name
    filename_parts = stem.split("-")
    if len(filename_parts) < 5:
        raise BuildError(f"Invalid wheel filename: {path.name}")
    expected_dist = re.sub(r"[-_.]+", "-", filename_parts[0]).lower()

    try:
        with zipfile.ZipFile(path, "r") as zf:
            infos = zf.infolist()
            if len(infos) > MAX_ARCHIVE_FILES:
                raise BuildError(f"Dependency wheel has too many entries: {path.name}")
            seen: set[str] = set()
            candidates: dict[str, dict[str, str]] = {}
            for info in infos:
                unix_type = (info.external_attr >> 16) & 0o170000
                dos_attributes = info.external_attr & 0xFFFF
                dos_directory = bool(dos_attributes & 0x0010)
                is_directory = info.is_dir() or unix_type == stat.S_IFDIR or (unix_type == 0 and dos_directory)
                raw_name = info.filename.rstrip("/") if is_directory else info.filename
                name = validate_relative(raw_name)
                if name in seen:
                    raise BuildError(f"Dependency wheel contains duplicate member: {path.name}:{name}")
                seen.add(name)
                if unix_type == stat.S_IFLNK:
                    raise BuildError(f"Dependency wheel contains symbolic-link member: {path.name}:{name}")
                if unix_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise BuildError(f"Dependency wheel contains non-regular member: {path.name}:{name}")
                if is_directory:
                    if info.file_size != 0:
                        raise BuildError(f"Dependency wheel directory member has non-zero size: {path.name}:{name}")
                    continue
                if info.file_size > MAX_FILE_BYTES:
                    raise BuildError(f"Dependency wheel member is too large: {path.name}:{name}")

                parts_name = name.split("/")
                # Only consider root-level ``<dist>.dist-info/{METADATA,WHEEL}``.
                # Nested vendored dist-info directories (2+ slashes) are
                # intentionally ignored.
                if len(parts_name) != 2:
                    continue
                dist_dir, leaf = parts_name
                if not dist_dir.endswith(".dist-info") or leaf not in ("METADATA", "WHEEL"):
                    continue
                candidates.setdefault(dist_dir, {})[leaf] = name

            chosen: str | None = None
            if len(candidates) == 1:
                only = next(iter(candidates))
                if {"METADATA", "WHEEL"} <= set(candidates[only]):
                    chosen = only
            if chosen is None:
                # Prefer the dist-info whose stem matches the wheel filename.
                for dist_dir in sorted(candidates):
                    entries = candidates[dist_dir]
                    if not ({"METADATA", "WHEEL"} <= set(entries)):
                        continue
                    stem_local = dist_dir[:-len(".dist-info")]
                    normalized = re.sub(r"[-_.]+", "-", stem_local).lower()
                    if normalized == expected_dist or normalized.startswith(expected_dist + "-"):
                        chosen = dist_dir
                        break
            if chosen is None:
                # Last resort: any dist-info that provides both files.
                for dist_dir in sorted(candidates):
                    if {"METADATA", "WHEEL"} <= set(candidates[dist_dir]):
                        chosen = dist_dir
                        break
            if chosen is None:
                raise BuildError(f"Wheel has invalid METADATA/WHEEL layout: {path.name}")

            entries = candidates[chosen]
            metadata_raw = zf.read(zf.getinfo(entries["METADATA"]))
            wheel_raw = zf.read(zf.getinfo(entries["WHEEL"]))
    except (OSError, zipfile.BadZipFile, KeyError) as exc:
        raise BuildError(f"Unable to inspect dependency wheel: {path.name}") from exc

    try:
        metadata_text = metadata_raw.decode("utf-8")
        wheel_text = wheel_raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"Dependency wheel metadata is not UTF-8: {path.name}") from exc
    headers: dict[str, str] = {}
    for line in metadata_text.splitlines():
        if not line.strip() or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        if key in {"Name", "Version"}:
            headers[key] = value.strip()
    wheel_version: str | None = None
    tags: list[str] = []
    for line in wheel_text.splitlines():
        if not line.strip() or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        if key == "Wheel-Version":
            wheel_version = value
        elif key == "Tag":
            tags.append(value)
    if set(headers) != {"Name", "Version"} or any(not headers[k] for k in headers):
        raise BuildError(f"Dependency wheel METADATA lacks Name/Version: {path.name}")
    if wheel_version is None or not re.fullmatch(r"1\.\d+", wheel_version) or not tags:
        raise BuildError(f"Dependency wheel WHEEL metadata is malformed: {path.name}")
    for tag in tags:
        if not re.fullmatch(r"[A-Za-z0-9_.+]+-[A-Za-z0-9_.+]+-[A-Za-z0-9_.+]+", tag):
            raise BuildError(f"Dependency wheel contains malformed Tag: {path.name}")
    return headers["Name"], headers["Version"], tags


def _wheel_platforms(filename: str) -> set[str]:
    if not filename.endswith(".whl"):
        raise BuildError(f"Not a wheel filename: {filename}")
    parts = filename[:-4].split("-")
    if len(parts) < 5:
        raise BuildError(f"Invalid wheel filename: {filename}")
    return set(parts[-1].split("."))


def _wheel_tag_platforms(tags: list[str]) -> set[str]:
    platforms: set[str] = set()
    for tag in tags:
        parts = tag.split("-")
        if len(parts) != 3:
            raise BuildError(f"Invalid wheel compatibility tag: {tag}")
        platforms.add(parts[2])
    return platforms


def _platforms_compatible(platforms: set[str], target: str) -> bool:
    meta = TARGETS[target]
    if "any" in platforms:
        return True
    if meta["os"] == "windows":
        return ("win_amd64" in platforms) if meta["arch"] == "x86_64" else ("win_arm64" in platforms)
    if meta["os"] == "macos":
        if meta["arch"] == "x86_64":
            return any(tag.endswith("_x86_64") or tag.endswith("_universal2") for tag in platforms if tag.startswith("macosx_"))
        return any(tag.endswith("_arm64") or tag.endswith("_universal2") for tag in platforms if tag.startswith("macosx_"))
    if meta["libc"] == "musl":
        suffix = "_x86_64" if meta["arch"] == "x86_64" else "_aarch64"
        return any(tag.startswith("musllinux_") and tag.endswith(suffix) for tag in platforms)
    suffix = "_x86_64" if meta["arch"] == "x86_64" else "_aarch64"
    return any(tag.startswith("manylinux") and tag.endswith(suffix) for tag in platforms) or ("linux" + suffix) in platforms


def wheel_platform_compatible(filename: str, target: str | None) -> bool:
    """Check wheel filename platform tags against the concrete release target."""
    if target is None:
        return True
    target_metadata(target)
    return _platforms_compatible(_wheel_platforms(filename), target)


def _source_distribution_metadata(path: Path) -> tuple[str, str]:
    """Parse a PEP 625-style simple source distribution filename."""
    name = path.name
    if not name.endswith(".tar.gz"):
        raise BuildError(f"Unsupported source dependency artifact: {name}")
    stem = name[:-7]
    if "." not in stem:
        raise BuildError(f"Invalid source distribution filename: {name}")
    package, version = stem.rsplit("-", 1)
    package = package.replace("_", "-").replace(".", "-").lower()
    if not package or not version:
        raise BuildError(f"Invalid source distribution filename: {name}")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", package):
        raise BuildError(f"Invalid source distribution package name: {name}")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", version):
        raise BuildError(f"Invalid source distribution version: {name}")
    return package, version


def _trusted_source_distribution(path: Path, expected_package: str, expected_version: str) -> dict[str, Any]:
    package, version = _source_distribution_metadata(path)
    if package != expected_package or version != expected_version:
        raise BuildError(f"Source distribution identity mismatch: {path.name}")
    key = (package, version, path.name.lower())
    expected_hash = TRUSTED_SOURCE_DISTS.get(key)
    if expected_hash is None:
        raise BuildError(f"Untrusted source distribution: {path.name}")
    record = stable_file_record(path, MAX_DEPENDENCY_WHEEL_BYTES)
    if record["sha256"] != expected_hash:
        raise BuildError(f"Trusted source distribution hash mismatch: {path.name}")
    return {
        "artifact_type": "sdist",
        "filename": path.name,
        "package": package,
        "normalized_package": package,
        "version": version,
        "platform_tags": [],
        "sha256": record["sha256"],
        "size": record["size"],
    }


def catalogue_dependencies(wheelhouse: Path, requirements_file: Path, output: Path, target: str | None = None) -> dict[str, Any]:
    ensure_directory(wheelhouse, "dependency artifact wheelhouse")
    ensure_regular(requirements_file, "build requirements")
    requirements = _requirement_rows(requirements_file)
    artifacts: list[dict[str, Any]] = []
    covered: set[str] = set()
    entries = sorted(wheelhouse.iterdir(), key=lambda p: p.name)
    if not entries:
        raise BuildError("Dependency artifact wheelhouse is empty.")
    for path in entries:
        if path.is_symlink() or not path.is_file():
            raise BuildError(f"Unsafe dependency artifact entry: {path.name}")
        lower_name = path.name.lower()
        if lower_name.endswith(".whl"):
            name, version, wheel_tags = _wheel_metadata(path)
            if not wheel_platform_compatible(path.name, target):
                raise BuildError(f"Dependency wheel is incompatible with target {target}: {path.name}")
            if target is not None:
                inner_platforms = _wheel_tag_platforms(wheel_tags)
                if not _platforms_compatible(inner_platforms, target):
                    raise BuildError(f"Inner WHEEL Tag is incompatible with target {target}: {path.name}")
                outer_platforms = _wheel_platforms(path.name)
                if not (inner_platforms & outer_platforms) and "any" not in inner_platforms:
                    raise BuildError(f"Wheel filename/platform metadata mismatch: {path.name}")
            normalized = re.sub(r"[-_.]+", "-", name).lower()
            record = stable_file_record(path, MAX_DEPENDENCY_WHEEL_BYTES)
            artifact = {
                "artifact_type": "wheel",
                "filename": path.name,
                "package": name,
                "normalized_package": normalized,
                "version": version,
                "platform_tags": sorted(wheel_tags),
                "sha256": record["sha256"],
                "size": record["size"],
            }
        elif lower_name.endswith(".tar.gz"):
            package, version = _source_distribution_metadata(path)
            artifact = _trusted_source_distribution(path, package, version)
        else:
            raise BuildError(f"Unsupported dependency artifact present: {path.name}")
        normalized = artifact["normalized_package"]
        if normalized not in requirements or requirements[normalized] != artifact["version"]:
            raise BuildError(f"Dependency artifact is not an exact pinned requirement: {path.name}")
        if normalized in covered:
            raise BuildError(f"Multiple artifacts satisfy one pinned package: {normalized}")
        covered.add(normalized)
        artifacts.append(artifact)
    missing = sorted(set(requirements) - covered)
    if missing:
        raise BuildError(f"Required pinned dependency artifacts are missing: {missing}")
    catalogue = {
        "schema": 3,
        "target": target,
        "requirements_sha256": sha256_file(requirements_file),
        "requirements": dict(sorted(requirements.items())),
        "artifacts": artifacts,
    }
    _write_atomic_bytes(output, canonical_json(catalogue) + b"\n", 0o600)
    return catalogue


def parse_dependency_catalogue(raw: bytes, label: str, target: str | None = None) -> dict[str, Any]:
    """Validate exact wheel/sdist dependency provenance embedded in a package."""
    if len(raw) > MAX_JSON_BYTES:
        raise BuildError(f"Dependency catalogue exceeds configured size limit: {label}")
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"Invalid dependency catalogue JSON: {label}") from exc
    if not isinstance(data, dict) or set(data) != {"schema", "target", "requirements_sha256", "requirements", "artifacts"}:
        raise BuildError(f"Dependency catalogue field set is invalid: {label}")
    if data["schema"] != 3:
        raise BuildError(f"Unsupported dependency catalogue schema: {label}")
    if data["target"] is not None and not isinstance(data["target"], str):
        raise BuildError(f"Dependency catalogue target type is invalid: {label}")
    if target is not None and data["target"] != target:
        raise BuildError(f"Dependency catalogue target mismatch: {label}")
    if data["target"] is not None:
        target_metadata(data["target"])
    digest = data["requirements_sha256"]
    if not isinstance(digest, str) or len(digest) != 64:
        raise BuildError(f"Invalid dependency requirements hash: {label}")
    try:
        bytes.fromhex(digest)
    except ValueError as exc:
        raise BuildError(f"Invalid dependency requirements hash: {label}") from exc
    requirements = data["requirements"]
    if not isinstance(requirements, dict) or not requirements:
        raise BuildError(f"Dependency requirements are empty or malformed: {label}")
    if list(requirements) != sorted(requirements):
        raise BuildError(f"Dependency requirement map is not canonically ordered: {label}")
    for name, version in requirements.items():
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
            raise BuildError(f"Invalid dependency requirement package name: {label}")
        if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", version):
            raise BuildError(f"Invalid dependency requirement version: {label}")
    artifacts = data["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise BuildError(f"Dependency artifact catalogue is empty or malformed: {label}")
    required_fields = {"artifact_type", "filename", "package", "normalized_package", "version", "platform_tags", "sha256", "size"}
    seen: set[str] = set()
    artifact_filenames: list[str] = []
    packages: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != required_fields:
            raise BuildError(f"Invalid dependency artifact descriptor: {label}")
        if artifact["artifact_type"] not in {"wheel", "sdist"}:
            raise BuildError(f"Invalid dependency artifact type: {label}")
        for key in ("filename", "package", "normalized_package", "version"):
            if not isinstance(artifact[key], str):
                raise BuildError(f"Invalid dependency artifact descriptor types: {label}")
        filename = validate_relative(artifact["filename"].replace(os.sep, "/"))
        if filename in seen:
            raise BuildError(f"Duplicate dependency artifact filename: {label}:{filename}")
        seen.add(filename)
        artifact_filenames.append(filename)
        normalized = re.sub(r"[-_.]+", "-", artifact["package"].lower())
        if artifact["normalized_package"] != normalized:
            raise BuildError(f"Dependency artifact normalized package mismatch: {label}:{filename}")
        if normalized not in requirements or requirements[normalized] != artifact["version"]:
            raise BuildError(f"Dependency artifact is not an exact pinned requirement: {label}:{filename}")
        tags = artifact["platform_tags"]
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise BuildError(f"Invalid dependency artifact platform tags: {label}:{filename}")
        if artifact["artifact_type"] == "wheel":
            if not filename.endswith(".whl") or not tags:
                raise BuildError(f"Invalid dependency wheel descriptor: {label}:{filename}")
            for tag in tags:
                if not re.fullmatch(r"[A-Za-z0-9_.+]+-[A-Za-z0-9_.+]+-[A-Za-z0-9_.+]+", tag):
                    raise BuildError(f"Malformed dependency wheel platform tag: {label}:{filename}")
            wheel_platform_compatible(filename, data["target"])
            if not _platforms_compatible(_wheel_tag_platforms(tags), data["target"]):
                raise BuildError(f"Dependency wheel inner platform tags are incompatible: {label}:{filename}")
        else:
            if not filename.lower().endswith(".tar.gz") or tags:
                raise BuildError(f"Invalid source-distribution descriptor: {label}:{filename}")
        digest = artifact["sha256"]
        if not isinstance(digest, str) or len(digest) != 64:
            raise BuildError(f"Invalid dependency artifact hash: {label}:{filename}")
        try:
            bytes.fromhex(digest)
        except ValueError as exc:
            raise BuildError(f"Invalid dependency artifact hash: {label}:{filename}") from exc
        if artifact["artifact_type"] == "sdist":
            trusted = TRUSTED_SOURCE_DISTS.get((normalized, artifact["version"], filename.lower()))
            if trusted is None or digest.lower() != trusted:
                raise BuildError(f"Untrusted source-distribution descriptor: {label}:{filename}")
        if type(artifact["size"]) is not int or artifact["size"] <= 0 or artifact["size"] > MAX_DEPENDENCY_WHEEL_BYTES:
            raise BuildError(f"Invalid dependency artifact size: {label}:{filename}")
        packages.append(normalized)
    if artifact_filenames != sorted(artifact_filenames):
        raise BuildError(f"Dependency artifact list is not canonically ordered: {label}")
    if len(packages) != len(set(packages)):
        raise BuildError(f"Dependency catalogue contains multiple artifacts for one pinned package: {label}")
    if set(packages) != set(requirements):
        raise BuildError(f"Dependency catalogue artifact/requirement set mismatch: {label}")
    return data


def emit_hashed_requirements(catalogue_file: Path, requirements_file: Path, output: Path, target: str | None = None) -> None:
    """Emit a pip --require-hashes lock only for the exact requirements that were catalogued."""
    ensure_regular(catalogue_file, "dependency catalogue")
    ensure_regular(requirements_file, "build requirements")
    catalogue = parse_dependency_catalogue(read_bounded(catalogue_file, MAX_JSON_BYTES), str(catalogue_file), target)
    actual_requirements_hash = sha256_file(requirements_file)
    if actual_requirements_hash != catalogue["requirements_sha256"]:
        raise BuildError("Build requirements changed after dependency catalogue generation.")
    requirements = _requirement_rows(requirements_file)
    by_package: dict[str, dict[str, Any]] = {a["normalized_package"]: a for a in catalogue["artifacts"]}
    if set(by_package) != set(requirements):
        raise BuildError("Dependency catalogue cannot produce a complete hash-locked requirements file.")
    lines = [
        f'{package}=={requirements[package]} --hash=sha256:{by_package[package]["sha256"].lower()}'
        for package in sorted(requirements)
    ]
    _write_atomic_bytes(output, ("\n".join(lines) + "\n").encode("ascii"), 0o600)


def validate_provenance(provenance: dict[str, Any], target: str, version: str, label: str = "build provenance") -> dict[str, Any]:
    """Validate the immutable provenance contract embedded into a binary catalogue."""
    if not isinstance(provenance, dict):
        raise BuildError(f"Build provenance must be an object: {label}")
    required = {"schema", "builder", "target", "release_version", "source_date_epoch", "python", "host", "compiler", "container", "dependency_catalogue"}
    if set(provenance) != required:
        raise BuildError(f"Build provenance field set is invalid: {label}")
    if provenance["schema"] != 1:
        raise BuildError(f"Unsupported build provenance schema: {label}")
    if provenance["builder"] not in {"nexs_build_release.sh", "nexs_build_release.ps1"}:
        raise BuildError(f"Untrusted build provenance builder: {label}")
    if provenance["target"] != target or provenance["release_version"] != version:
        raise BuildError(f"Build provenance target/version binding mismatch: {label}")
    if type(provenance["source_date_epoch"]) is not int or provenance["source_date_epoch"] < 0:
        raise BuildError(f"Invalid SOURCE_DATE_EPOCH in build provenance: {label}")

    python = provenance["python"]
    if not isinstance(python, dict) or set(python) != {"version", "implementation", "executable_sha256"}:
        raise BuildError(f"Invalid Python provenance descriptor: {label}")
    if python["implementation"] != "CPython" or not isinstance(python["version"], str) or not python["version"].startswith("3.12."):
        raise BuildError(f"Build provenance Python runtime is not CPython 3.12.x: {label}")
    for field, expected_len in (("executable_sha256", 64),):
        value = python[field]
        if not isinstance(value, str) or len(value) != expected_len:
            raise BuildError(f"Invalid Python provenance hash: {label}")
        try:
            bytes.fromhex(value)
        except ValueError as exc:
            raise BuildError(f"Invalid Python provenance hash: {label}") from exc

    host = provenance["host"]
    if not isinstance(host, dict) or set(host) != {"os", "arch", "libc"}:
        raise BuildError(f"Invalid host provenance descriptor: {label}")
    target_meta = target_metadata(target)
    if host["os"] != target_meta["os"] or host["arch"] != target_meta["arch"] or host["libc"] != target_meta["libc"]:
        raise BuildError(f"Build provenance host does not match target environment: {label}")

    compiler = provenance["compiler"]
    if not isinstance(compiler, dict) or set(compiler) != {"path", "version", "sha256"}:
        raise BuildError(f"Invalid compiler provenance descriptor: {label}")
    if not isinstance(compiler["path"], str) or not compiler["path"] or not isinstance(compiler["version"], str) or not compiler["version"]:
        raise BuildError(f"Invalid compiler provenance fields: {label}")
    if not isinstance(compiler["sha256"], str) or len(compiler["sha256"]) != 64:
        raise BuildError(f"Invalid compiler provenance hash: {label}")
    try:
        bytes.fromhex(compiler["sha256"])
    except ValueError as exc:
        raise BuildError(f"Invalid compiler provenance hash: {label}") from exc

    container = provenance["container"]
    if target_meta["os"] == "linux" and target in {"linux-aarch64", "linux-musl-aarch64", "linux-x86_64", "linux-musl-x86_64"}:
        if container is not None:
            if not isinstance(container, dict) or set(container) != {"image", "digest", "image_id"}:
                raise BuildError(f"Invalid Linux container provenance descriptor: {label}")
            for key in ("image", "digest", "image_id"):
                if not isinstance(container[key], str) or not container[key]:
                    raise BuildError(f"Invalid Linux container provenance field: {label}")
            if not re.fullmatch(r"[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}", container["image"], re.IGNORECASE):
                raise BuildError(f"Linux provenance image is not digest-pinned: {label}")
            if container["digest"] != container["image"] .split("@", 1)[1]:
                raise BuildError(f"Linux provenance image digest mismatch: {label}")
        else:
            # Local Linux builds are allowed, but the host tuple above must match exactly.
            pass
    elif container is not None:
        raise BuildError(f"Non-Linux provenance unexpectedly contains a container descriptor: {label}")

    dep = provenance["dependency_catalogue"]
    if not isinstance(dep, dict) or set(dep) != {"path", "sha256"}:
        raise BuildError(f"Invalid dependency provenance descriptor: {label}")
    if dep["path"] != "BUILD_DEPENDENCY_CATALOGUE.json" or not isinstance(dep["sha256"], str) or len(dep["sha256"]) != 64:
        raise BuildError(f"Invalid dependency provenance binding: {label}")
    try:
        bytes.fromhex(dep["sha256"])
    except ValueError as exc:
        raise BuildError(f"Invalid dependency provenance hash: {label}") from exc
    return provenance


def package_catalogue(package: Path, target: str, version: str, source: Path, identity_file: Path, provenance: dict[str, Any] | None = None) -> dict[str, Any]:
    validate_version(version)
    target_metadata(target)
    ensure_directory(package, "standalone package")
    source_hash = validate_source(source)
    identity = parse_identity(read_bounded(identity_file, MAX_JSON_BYTES))
    if identity["program_hash"] != source_hash:
        raise BuildError("Runtime program_hash does not match the unmodified source hash.")
    dependency_path = package / "BUILD_DEPENDENCY_CATALOGUE.json"
    ensure_regular(dependency_path, "embedded dependency catalogue")
    parse_dependency_catalogue(read_bounded(dependency_path, MAX_JSON_BYTES), str(dependency_path), target)

    files: list[dict[str, Any]] = []
    for rel, path in iter_tree(package):
        if rel == "BINARY_CATALOGUE.json":
            continue
        record = stable_file_record(path)
        files.append({
            "relative_path": rel,
            "sha256": record["sha256"],
            "size": record["size"],
        })
    files.sort(key=lambda x: x["relative_path"])
    if len(files) > MAX_ARCHIVE_FILES:
        raise BuildError("Package contains too many files.")

    is_windows = target.startswith("windows-")
    executable_names = ["nexs_ledger.exe"] if is_windows else ["nexs_ledger"]
    exe_entries: list[dict[str, Any]] = []
    for name in executable_names:
        path = package / name
        ensure_regular(path, f"required executable {name}")
        data = read_bounded(path, MAX_FILE_BYTES)
        verify_binary_format(data, target, main_executable=True)
        exe_entries.append({
            "name": name,
            "sha256": sha256_bytes(data),
            "size": len(data),
            "internal_program_hash": identity["program_hash"],
            "runtime_fingerprint": identity["runtime_fingerprint"],
            "program_version_hash": identity["program_version_hash"],
        })

    prov = provenance if provenance is not None else {}
    validate_provenance(prov, target, version)
    binding = {
        "schema": CATALOGUE_SCHEMA,
        "release_version": version,
        "target": target_metadata(target),
        "source": {"path": source.name, "sha256": source_hash},
        "internal_identity": identity,
        "provenance": prov,
        "executables": exe_entries,
        "files": files,
    }
    catalogue = dict(binding)
    catalogue["catalogue_binding_sha256"] = sha256_bytes(canonical_json(binding))
    _write_atomic_bytes(package / "BINARY_CATALOGUE.json", canonical_json(catalogue) + b"\n", 0o600)
    return catalogue


def _atomic_replace(temp_path: Path, destination: Path) -> None:
    try:
        os.replace(temp_path, destination)
        if os.name != "nt":
            directory_fd = os.open(os.fspath(destination.parent), os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except OSError as exc:
        raise BuildError(f"Atomic replacement failed: {destination}") from exc


def _write_atomic_bytes(destination: Path, content: bytes, mode: int = 0o600) -> None:
    ensure_directory(destination.parent, "atomic-write parent", allow_create=True)
    ensure_no_link_ancestors(destination.parent, label="atomic-write path")
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise BuildError(f"Unsafe atomic-write destination: {destination}")
    temp = destination.parent / f'.{destination.name}.{secrets.token_hex(16)}.tmp'
    try:
        flags = (os.O_CREAT | os.O_EXCL | os.O_WRONLY
                 | getattr(os, "O_NOFOLLOW", 0)
                 | getattr(os, "O_CLOEXEC", 0)
                 | getattr(os, "O_BINARY", 0))
        fd = os.open(os.fspath(temp), flags, mode)
        try:
            if hasattr(os, "fchmod"):
                os.fchmod(fd, mode)
            offset = 0
            while offset < len(content):
                written = os.write(fd, content[offset:])
                if written <= 0:
                    raise BuildError("Atomic write made no progress.")
                offset += written
            os.fsync(fd)
        finally:
            os.close(fd)
        _atomic_replace(temp, destination)
    except Exception:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def deterministic_zip(package: Path, out: Path) -> None:
    ensure_directory(package, "package")
    ensure_directory(out.parent, "archive destination", allow_create=True)
    if out.exists() or out.is_symlink():
        if out.is_symlink() or not out.is_file():
            raise BuildError(f"Unsafe ZIP destination: {out}")
    temp = out.parent / f'.{out.name}.{secrets.token_hex(16)}.tmp'
    directories: set[str] = set()
    file_entries: list[tuple[str, Path]] = []
    for rel, path in iter_tree(package):
        file_entries.append((rel, path))
        for parent in PurePosixPath(rel).parents:
            if str(parent) != ".":
                directories.add(parent.as_posix() + "/")
    entries = [(name, package / name.rstrip("/"), True) for name in sorted(directories)]
    entries += [(rel, path, False) for rel, path in file_entries]
    try:
        with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, strict_timestamps=True) as zf:
            zf.comment = b""
            for rel, path, is_dir in sorted(entries, key=lambda item: (item[0], 1 if item[2] else 2)):
                info = zipfile.ZipInfo(rel)
                info.date_time = (1980, 1, 1, 0, 0, 0)
                info.create_system = 3
                info.extra = b""
                info.comment = b""
                info.flag_bits = 0
                if is_dir:
                    info.compress_type = zipfile.ZIP_STORED
                    info.external_attr = (0o40755 << 16) | 0x10
                    zf.writestr(info, b"")
                else:
                    mode = stat.S_IMODE(_lstat(path, "package file").st_mode) & 0o777
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = mode << 16
                    zf.writestr(info, read_bounded(path, MAX_FILE_BYTES))
        ensure_regular(temp, "generated ZIP temporary file")
        if temp.stat().st_size > MAX_ARCHIVE_BYTES:
            raise BuildError("Generated ZIP exceeds archive size limit.")
        sync_regular_file(temp)
        _atomic_replace(temp, out)
    finally:
        temp.unlink(missing_ok=True)


def _tar_add_stable_file(tf: tarfile.TarFile, rel: str, path: Path) -> None:
    fd, initial = _open_readonly_stable(path)
    try:
        info = tarfile.TarInfo(rel)
        info.type = tarfile.REGTYPE
        info.size = initial.st_size
        info.mode = stat.S_IMODE(initial.st_mode) & 0o777
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        with os.fdopen(fd, "rb", closefd=True) as handle:
            tf.addfile(info, handle)
            final = os.fstat(handle.fileno())
            if _stat_identity(initial) != _stat_identity(final):
                raise BuildError(f"Package file changed while being archived: {path}")
        fd = -1
    except OSError as exc:
        raise BuildError(f"Unable to archive package file: {path}") from exc
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass


def deterministic_targz(package: Path, out: Path) -> None:
    ensure_directory(package, "package")
    ensure_directory(out.parent, "archive destination", allow_create=True)
    if out.exists() or out.is_symlink():
        if out.is_symlink() or not out.is_file():
            raise BuildError(f"Unsafe tar.gz destination: {out}")
    temp_tar = out.parent / f'.{out.name}.{secrets.token_hex(16)}.tar.tmp'
    temp_out = out.parent / f'.{out.name}.{secrets.token_hex(16)}.tmp'
    try:
        directories: set[str] = set()
        file_entries: list[tuple[str, Path]] = []
        for rel, path in iter_tree(package):
            file_entries.append((rel, path))
            for parent in PurePosixPath(rel).parents:
                if str(parent) != ".":
                    directories.add(parent.as_posix())
        with tarfile.open(temp_tar, "w", format=tarfile.GNU_FORMAT) as tf:
            for rel in sorted(directories):
                info = tarfile.TarInfo(rel)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                tf.addfile(info)
            for rel, path in sorted(file_entries):
                _tar_add_stable_file(tf, rel, path)
        with temp_tar.open("rb") as src, temp_out.open("wb") as dst, gzip.GzipFile(fileobj=dst, mode="wb", filename="", mtime=0) as gz:
            while True:
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                gz.write(chunk)
            dst.flush()
            os.fsync(dst.fileno())
        if temp_out.stat().st_size > MAX_ARCHIVE_BYTES:
            raise BuildError("Generated tar.gz exceeds archive size limit.")
        _atomic_replace(temp_out, out)
    finally:
        temp_tar.unlink(missing_ok=True)
        temp_out.unlink(missing_ok=True)


def archive_package(package: Path, target: str, version: str, out_dir: Path) -> Path:
    validate_version(version)
    target_metadata(target)
    ensure_directory(package, "package")
    ensure_directory(out_dir, "archive destination", allow_create=True)
    suffix = ".zip" if TARGETS[target]["os"] == "windows" else ".tar.gz"
    out = out_dir / f"{target}-{version}{suffix}"
    if suffix == ".zip":
        deterministic_zip(package, out)
    else:
        deterministic_targz(package, out)
    return out


def parse_catalogue_bytes(raw: bytes, label: str) -> dict[str, Any]:
    if len(raw) > MAX_JSON_BYTES:
        raise BuildError(f"Catalogue exceeds configured size limit: {label}")
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"Invalid catalogue JSON: {label}") from exc
    if not isinstance(data, dict) or data.get("schema") != CATALOGUE_SCHEMA:
        raise BuildError(f"Unsupported catalogue schema: {label}")
    required = {"schema", "release_version", "target", "source", "internal_identity", "provenance", "executables", "files", "catalogue_binding_sha256"}
    if set(data) != required:
        raise BuildError(f"Catalogue field set mismatch: {label}")
    if not isinstance(data["release_version"], str) or not data["release_version"]:
        raise BuildError(f"Invalid catalogue release version: {label}")
    validate_version(data["release_version"])
    if not isinstance(data["target"], dict) or set(data["target"]) != {"os", "arch", "libc", "format", "target"}:
        raise BuildError(f"Invalid catalogue target descriptor: {label}")
    if not isinstance(data["target"]["target"], str):
        raise BuildError(f"Invalid catalogue target name: {label}")
    target_metadata(data["target"]["target"])
    if data["target"] != target_metadata(data["target"]["target"]):
        raise BuildError(f"Catalogue target descriptor mismatch: {label}")
    if not isinstance(data["source"], dict) or set(data["source"]) != {"path", "sha256"}:
        raise BuildError(f"Invalid catalogue source descriptor: {label}")
    if not isinstance(data["source"]["path"], str) or not isinstance(data["source"]["sha256"], str):
        raise BuildError(f"Invalid catalogue source descriptor types: {label}")
    validate_relative(data["source"]["path"].replace(os.sep, "/"))
    if not isinstance(data["source"]["sha256"], str) or len(data["source"]["sha256"]) != 64:
        raise BuildError(f"Invalid catalogue source hash: {label}")
    try:
        bytes.fromhex(data["source"]["sha256"])
    except ValueError as exc:
        raise BuildError(f"Invalid catalogue source hash: {label}") from exc
    if not isinstance(data["internal_identity"], dict):
        raise BuildError(f"Invalid catalogue internal identity: {label}")
    parse_identity(canonical_json(data["internal_identity"]))
    if data["source"]["sha256"] != data["internal_identity"]["program_hash"]:
        raise BuildError(f"Catalogue source hash is not bound to internal program identity: {label}")
    validate_provenance(data["provenance"], data["target"]["target"], data["release_version"], label)
    expected_exec_fields = {"name", "sha256", "size", "internal_program_hash", "runtime_fingerprint", "program_version_hash"}
    if not isinstance(data["executables"], list) or len(data["executables"]) != 1:
        raise BuildError(f"Invalid catalogue executable list: {label}")
    expected_names = {"nexs_ledger.exe"} if data["target"]["os"] == "windows" else {"nexs_ledger"}
    seen_execs: set[str] = set()
    identity = data["internal_identity"]
    executable_names_in_order: list[str] = []
    for executable in data["executables"]:
        if not isinstance(executable, dict) or set(executable) != expected_exec_fields:
            raise BuildError(f"Invalid executable descriptor: {label}")
        name = executable["name"]
        if not isinstance(name, str) or name not in expected_names or name in seen_execs:
            raise BuildError(f"Invalid or duplicate executable name: {label}:{name}")
        seen_execs.add(name)
        executable_names_in_order.append(name)
        if not isinstance(executable["sha256"], str) or len(executable["sha256"]) != 64:
            raise BuildError(f"Invalid executable hash: {label}:{name}")
        bytes.fromhex(executable["sha256"])
        if type(executable["size"]) is not int or executable["size"] <= 0:
            raise BuildError(f"Invalid executable size: {label}:{name}")
        if executable["internal_program_hash"] != identity["program_hash"] or executable["runtime_fingerprint"] != identity["runtime_fingerprint"] or executable["program_version_hash"] != identity["program_version_hash"]:
            raise BuildError(f"Executable/internal identity binding mismatch: {label}:{name}")
    expected_order = ["nexs_ledger.exe"] if data["target"]["os"] == "windows" else ["nexs_ledger"]
    if executable_names_in_order != expected_order:
        raise BuildError(f"Executable catalogue ordering is non-canonical: {label}")
    if not isinstance(data["files"], list) or len(data["files"]) > MAX_ARCHIVE_FILES:
        raise BuildError(f"Invalid catalogue file list: {label}")
    seen_files: set[str] = set()
    file_paths_in_order: list[str] = []
    for entry in data["files"]:
        if not isinstance(entry, dict) or set(entry) != {"relative_path", "sha256", "size"}:
            raise BuildError(f"Invalid catalogue file descriptor: {label}")
        if not isinstance(entry["relative_path"], str):
            raise BuildError(f"Invalid catalogue file path type: {label}")
        rel = validate_relative(entry["relative_path"].replace(os.sep, "/"))
        if rel == "BINARY_CATALOGUE.json" or rel in seen_files:
            raise BuildError(f"Invalid or duplicate catalogue file path: {label}:{rel}")
        seen_files.add(rel)
        file_paths_in_order.append(rel)
        if not isinstance(entry["sha256"], str) or len(entry["sha256"]) != 64:
            raise BuildError(f"Invalid catalogue file hash: {label}:{rel}")
        bytes.fromhex(entry["sha256"])
        if type(entry["size"]) is not int or entry["size"] < 0:
            raise BuildError(f"Invalid catalogue file size: {label}:{rel}")
    if file_paths_in_order != sorted(file_paths_in_order):
        raise BuildError(f"Catalogue file list is not canonically ordered: {label}")
    binding = dict(data)
    expected = binding.pop("catalogue_binding_sha256", None)
    if not isinstance(expected, str) or len(expected) != 64:
        raise BuildError(f"Invalid catalogue binding hash: {label}")
    try:
        bytes.fromhex(expected)
    except ValueError as exc:
        raise BuildError(f"Invalid catalogue binding hash: {label}") from exc
    if sha256_bytes(canonical_json(binding)) != expected:
        raise BuildError(f"Catalogue binding mismatch: {label}")
    return data


def archive_members(archive: Path) -> dict[str, bytes]:
    """Read an archive from one stable descriptor and reject unsafe members."""
    ensure_regular(archive, "release archive")
    fd, initial = _open_readonly_stable(archive)
    if initial.st_size > MAX_ARCHIVE_BYTES:
        os.close(fd)
        raise BuildError(f"Archive exceeds size limit: {archive}")
    archive_name = archive.name.lower()
    if archive_name.endswith(".zip"):
        archive_format = "zip"
    elif archive_name.endswith(".tar.gz"):
        archive_format = "targz"
    else:
        os.close(fd)
        raise BuildError(f"Unsupported release archive extension: {archive.name}")
    result: dict[str, bytes] = {}
    try:
        with os.fdopen(fd, "rb", closefd=True) as source:
            fd = -1
            if archive_format == "zip":
                try:
                    with zipfile.ZipFile(source, "r") as zf:
                        infos = zf.infolist()
                        if len(infos) > MAX_ARCHIVE_FILES:
                            raise BuildError("ZIP contains too many entries.")
                        seen: set[str] = set(); total = 0
                        for info in infos:
                            raw_name = info.filename.rstrip("/") if info.is_dir() else info.filename
                            name = validate_relative(raw_name)
                            if name in seen:
                                raise BuildError(f"Duplicate ZIP member: {name}")
                            seen.add(name)
                            if info.is_dir():
                                continue
                            unix_mode = (info.external_attr >> 16) & 0o170000
                            if unix_mode not in (0, 0o100000):
                                raise BuildError(f"ZIP member has non-regular Unix type: {name}")
                            if info.file_size > MAX_FILE_BYTES:
                                raise BuildError(f"ZIP member is too large: {name}")
                            total += info.file_size
                            if total > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                                raise BuildError("ZIP uncompressed payload exceeds configured total limit.")
                            data = zf.read(info)
                            if len(data) != info.file_size:
                                raise BuildError(f"ZIP member size mismatch: {name}")
                            result[name] = data
                except zipfile.BadZipFile as exc:
                    raise BuildError(f"Invalid ZIP archive: {archive}") from exc
            else:
                try:
                    with tarfile.open(fileobj=source, mode="r:gz") as tf:
                        members = tf.getmembers()
                        if len(members) > MAX_ARCHIVE_FILES:
                            raise BuildError("TAR contains too many entries.")
                        seen: set[str] = set(); total = 0
                        for member in members:
                            raw_name = member.name.rstrip("/") if member.isdir() else member.name
                            name = validate_relative(raw_name)
                            if name in seen:
                                raise BuildError(f"Duplicate TAR member: {name}")
                            seen.add(name)
                            if member.isdir():
                                continue
                            if not member.isreg():
                                raise BuildError(f"TAR member is not regular: {name}")
                            if member.size > MAX_FILE_BYTES:
                                raise BuildError(f"TAR member is too large: {name}")
                            total += member.size
                            if total > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                                raise BuildError("TAR uncompressed payload exceeds configured total limit.")
                            extracted = tf.extractfile(member)
                            if extracted is None:
                                raise BuildError(f"Unable to read TAR member: {name}")
                            data = extracted.read(MAX_FILE_BYTES + 1)
                            if len(data) != member.size:
                                raise BuildError(f"TAR member size mismatch: {name}")
                            result[name] = data
                except tarfile.TarError as exc:
                    raise BuildError(f"Invalid tar.gz archive: {archive}") from exc
            final = os.fstat(source.fileno())
            if _stat_identity(initial) != _stat_identity(final):
                raise BuildError(f"Archive changed while being read: {archive}")
    except OSError as exc:
        raise BuildError(f"Unable to inspect archive safely: {archive}") from exc
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
    return result


def verify_archive(archive: Path, target: str, version: str) -> dict[str, Any]:
    validate_version(version)
    target_metadata(target)
    files = archive_members(archive)
    cat_raw = files.get("BINARY_CATALOGUE.json")
    if cat_raw is None:
        raise BuildError(f"Archive lacks BINARY_CATALOGUE.json: {archive}")
    dependency_raw = files.get("BUILD_DEPENDENCY_CATALOGUE.json")
    if dependency_raw is None:
        raise BuildError(f"Archive lacks BUILD_DEPENDENCY_CATALOGUE.json: {archive}")
    parse_dependency_catalogue(dependency_raw, str(archive), target)
    catalogue = parse_catalogue_bytes(cat_raw, str(archive))
    if catalogue["release_version"] != version or catalogue["target"]["target"] != target:
        raise BuildError(f"Archive catalogue target/version mismatch: {archive}")
    if catalogue["target"] != target_metadata(target):
        raise BuildError(f"Archive target metadata mismatch: {archive}")
    if catalogue["source"]["sha256"] != catalogue["internal_identity"]["program_hash"]:
        raise BuildError(f"Archive source/internal identity mismatch: {archive}")
    dependency_provenance = catalogue["provenance"]["dependency_catalogue"]
    if dependency_provenance["sha256"] != sha256_bytes(dependency_raw):
        raise BuildError(f"Archive dependency catalogue provenance hash mismatch: {archive}")

    expected_files = {entry["relative_path"] for entry in catalogue["files"]}
    expected_files.add("BINARY_CATALOGUE.json")
    expected_files.add("BUILD_DEPENDENCY_CATALOGUE.json")
    if set(files) != expected_files:
        raise BuildError("Archive file-set differs from its catalogue.")
    for entry in catalogue["files"]:
        data = files[entry["relative_path"]]
        if len(data) != entry["size"] or sha256_bytes(data) != entry["sha256"]:
            raise BuildError(f"Archive file hash/size mismatch: {entry['relative_path']}")

    expected_execs = {"nexs_ledger.exe"} if target.startswith("windows-") else {"nexs_ledger"}
    executable_entries = {entry["name"]: entry for entry in catalogue["executables"]}
    if set(executable_entries) != expected_execs:
        raise BuildError("Executable catalogue set is invalid.")
    for name in sorted(expected_execs):
        data = files[name]
        verify_binary_format(data, target, main_executable=True)
        digest = sha256_bytes(data)
        if digest != executable_entries[name]["sha256"]:
            raise BuildError(f"Executable hash mismatch: {name}")

    # Every native payload is architecture-checked. Magic detection is primary
    # so a malicious native object cannot evade verification by using an unusual
    # filename such as ``libfoo.so.1``; suffix detection remains a secondary
    # contract for known native filenames.
    native_magic = {b"\x7fELF", b"MZ", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    for path, data in files.items():
        if path == "BINARY_CATALOGUE.json":
            continue
        suffix = Path(path).suffix.lower()
        is_native_name = suffix in {".so", ".dylib", ".dll", ".pyd", ".exe"} or ".so." in path.lower()
        if data[:4] in native_magic or is_native_name:
            verify_binary_format(data, target, main_executable=path in expected_execs)
    return catalogue


def assemble_release(stage_dir: Path, version: str) -> dict[str, Any]:
    validate_version(version)
    ensure_directory(stage_dir, "release staging")
    packages: list[Path] = []
    for candidate in sorted(stage_dir.iterdir()):
        if candidate.name not in TARGETS:
            continue
        st = _lstat(candidate, "release staging target")
        if _is_reparse_or_link(st) or not stat.S_ISDIR(st.st_mode):
            raise BuildError(f"Release staging target is not a real directory: {candidate}")
        packages.append(candidate)
    if not packages:
        raise BuildError("No target packages found in release staging.")
    for package in packages:
        for _rel, child in iter_tree(package):
            _ = child

    archives: list[Path] = []
    for package in packages:
        archive = archive_package(package, package.name, version, stage_dir)
        archives.append(archive)

    targets = [
        {"target": package.name, "filename": archive.name, "sha256": sha256_file(archive)}
        for package, archive in zip(packages, archives)
    ]
    release_catalogue = {
        "schema": CATALOGUE_SCHEMA,
        "release_version": version,
        "targets": targets,
        "created_by": "nexs_build_core",
    }
    _write_atomic_bytes(stage_dir / "RELEASE_CATALOGUE.json", canonical_json(release_catalogue) + b"\n", 0o600)

    executables: list[dict[str, Any]] = []
    for package in packages:
        catalogue = parse_catalogue_bytes(read_bounded(package / "BINARY_CATALOGUE.json", MAX_JSON_BYTES), str(package / "BINARY_CATALOGUE.json"))
        for executable in catalogue["executables"]:
            executables.append({"target": package.name, **executable})
    executables.sort(key=lambda x: (x["target"], x["name"]))
    binary_hash_catalogue = {
        "schema": CATALOGUE_SCHEMA,
        "release_version": version,
        "executables": executables,
    }
    _write_atomic_bytes(stage_dir / "BINARY_HASH_CATALOGUE.json", canonical_json(binary_hash_catalogue) + b"\n", 0o600)

    lines = []
    for path in sorted(archives + [stage_dir / "RELEASE_CATALOGUE.json", stage_dir / "BINARY_HASH_CATALOGUE.json"], key=lambda p: p.name):
        lines.append(f"{sha256_file(path)}  {path.name}")
    _write_atomic_bytes(stage_dir / "SHA256SUMS", ("\n".join(lines) + "\n").encode("ascii"), 0o600)
    return release_catalogue


def assemble_archives(archives_dir: Path, release_dir: Path, version: str) -> dict[str, Any]:
    validate_version(version)
    ensure_directory(archives_dir, "archive input")
    ensure_directory(release_dir, "release root", allow_create=True)
    selected: list[tuple[str, Path]] = []
    for path in sorted(archives_dir.iterdir()):
        try:
            st = path.lstat()
        except OSError as exc:
            raise BuildError(f"Unable to inspect archive input: {path}") from exc
        if _is_reparse_or_link(st) or not stat.S_ISREG(st.st_mode):
            continue
        for target in TARGETS:
            suffix = ".zip" if TARGETS[target]["os"] == "windows" else ".tar.gz"
            if path.name == f"{target}-{version}{suffix}":
                verify_archive(path, target, version)
                selected.append((target, path))
                break
    if not selected:
        raise BuildError("No verified target archives were found for this release.")
    if len({target for target, _ in selected}) != len(selected):
        raise BuildError("Duplicate target archive detected.")
    rows: list[dict[str, str]] = []
    for target, source in sorted(selected):
        destination = release_dir / source.name
        if destination.exists() or destination.is_symlink():
            raise BuildError(f"Release destination already exists: {destination}")
        _write_atomic_bytes(destination, read_bounded(source, MAX_ARCHIVE_BYTES), 0o600)
        rows.append({"target": target, "filename": destination.name, "sha256": sha256_file(destination)})
    release_catalogue = {"schema": CATALOGUE_SCHEMA, "release_version": version, "targets": rows, "created_by": "nexs_build_core"}
    release_catalogue_path = release_dir / f"RELEASE_CATALOGUE-{version}.json"
    binary_hash_path = release_dir / f"BINARY_HASH_CATALOGUE-{version}.json"
    sums_path = release_dir / f"SHA256SUMS-{version}"
    _write_atomic_bytes(release_catalogue_path, canonical_json(release_catalogue) + b"\n", 0o600)
    binaries: list[dict[str, Any]] = []
    for target, source in sorted(selected):
        cat = verify_archive(source, target, version)
        for executable in cat["executables"]:
            binaries.append({"target": target, **executable})
    binaries.sort(key=lambda x: (x["target"], x["name"]))
    _write_atomic_bytes(binary_hash_path, canonical_json({"schema": CATALOGUE_SCHEMA, "release_version": version, "executables": binaries}) + b"\n", 0o600)
    sum_lines = [f"{sha256_file(path)}  {path.name}" for path in sorted([*release_dir.glob(f"*-{version}.zip"), *release_dir.glob(f"*-{version}.tar.gz"), release_catalogue_path, binary_hash_path], key=lambda p: p.name)]
    _write_atomic_bytes(sums_path, ("\n".join(sum_lines) + "\n").encode("ascii"), 0o600)
    return release_catalogue


def verify_release(release_dir: Path, version: str, require_all: bool) -> dict[str, Any]:
    validate_version(version)
    ensure_directory(release_dir, "release root")
    release_catalogue_path = release_dir / f"RELEASE_CATALOGUE-{version}.json"
    binary_hash_path = release_dir / f"BINARY_HASH_CATALOGUE-{version}.json"
    sums_path = release_dir / f"SHA256SUMS-{version}"
    for path in (release_catalogue_path, binary_hash_path, sums_path):
        ensure_regular(path, "release metadata")

    try:
        release_catalogue = json.loads(read_bounded(release_catalogue_path, MAX_JSON_BYTES).decode("utf-8"))
        binary_hash_catalogue = json.loads(read_bounded(binary_hash_path, MAX_JSON_BYTES).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError("Release catalogue JSON is invalid.") from exc
    if release_catalogue.get("schema") != CATALOGUE_SCHEMA or release_catalogue.get("release_version") != version:
        raise BuildError("Release catalogue schema/version mismatch.")
    if set(binary_hash_catalogue) != {"schema", "release_version", "executables"}:
        raise BuildError("Binary hash catalogue field set is invalid.")
    if binary_hash_catalogue.get("schema") != CATALOGUE_SCHEMA or binary_hash_catalogue.get("release_version") != version or not isinstance(binary_hash_catalogue.get("executables"), list):
        raise BuildError("Binary hash catalogue schema/version is invalid.")
    if set(release_catalogue) != {"schema", "release_version", "targets", "created_by"} or not isinstance(release_catalogue.get("targets"), list):
        raise BuildError("Release catalogue field set is invalid.")
    if not isinstance(release_catalogue.get("created_by"), str) or release_catalogue["created_by"] != "nexs_build_core":
        raise BuildError("Release catalogue creator is invalid.")
    for row in release_catalogue["targets"]:
        if not isinstance(row, dict) or set(row) != {"target", "filename", "sha256"}:
            raise BuildError("Release catalogue target row is invalid.")
        if not isinstance(row["target"], str) or row["target"] not in TARGETS:
            raise BuildError("Release catalogue target is invalid.")
        expected_filename = f'{row["target"]}-{version}{".zip" if TARGETS[row["target"]]["os"] == "windows" else ".tar.gz"}'
        if not isinstance(row["filename"], str) or row["filename"] != expected_filename:
            raise BuildError("Release catalogue target filename is invalid.")
        if not isinstance(row["sha256"], str) or len(row["sha256"]) != 64:
            raise BuildError("Release catalogue target hash is invalid.")
        bytes.fromhex(row["sha256"])
    targets = [row["target"] for row in release_catalogue["targets"]]
    if len(targets) != len(set(targets)):
        raise BuildError("Release catalogue contains duplicate targets.")
    target_set = set(targets)
    if not target_set <= set(TARGETS):
        raise BuildError("Release contains an unsupported target.")
    if require_all and target_set != set(TARGETS):
        raise BuildError(f"Release target matrix incomplete: {sorted(target_set)}")

    archive_names = {row["filename"] for row in release_catalogue["targets"]}
    expected_names = archive_names | {release_catalogue_path.name, binary_hash_path.name, sums_path.name}
    observed_all: set[str] = set()
    for child in release_dir.iterdir():
        if child.is_symlink():
            raise BuildError(f"Release root contains a symlink: {child.name}")
        if not child.is_file():
            raise BuildError(f"Release root contains an unexpected directory/special entry: {child.name}")
        observed_all.add(child.name)
    observed_version_names = {name for name in observed_all if version in name}
    if observed_version_names != expected_names:
        raise BuildError("Unexpected or stale files detected for this release version.")

    binary_rows: list[dict[str, Any]] = []
    for row in sorted(release_catalogue["targets"], key=lambda x: x["target"]):
        target = row["target"]
        if target not in TARGETS:
            raise BuildError("Unsupported target in release catalogue.")
        archive = release_dir / row["filename"]
        ensure_regular(archive, "release archive")
        if sha256_file(archive) != row["sha256"]:
            raise BuildError(f"Release archive hash mismatch: {archive.name}")
        catalogue = verify_archive(archive, target, version)
        for executable in catalogue["executables"]:
            binary_rows.append({"target": target, **executable})
    binary_rows.sort(key=lambda x: (x["target"], x["name"]))

    expected_binary_catalogue = {
        "schema": CATALOGUE_SCHEMA,
        "release_version": version,
        "executables": binary_rows,
    }
    if binary_hash_catalogue != expected_binary_catalogue:
        raise BuildError("Binary hash catalogue does not match package catalogues.")

    parsed_sums: dict[str, str] = {}
    for line in read_bounded(sums_path, MAX_JSON_BYTES).decode("ascii").splitlines():
        if not line:
            continue
        if "\t" in line or line.startswith(" ") or line.endswith(" "):
            raise BuildError("Invalid SHA256SUMS whitespace.")
        fields = line.split("  ", 1)
        if len(fields) != 2 or len(fields[0]) != 64:
            raise BuildError("Invalid SHA256SUMS line.")
        try:
            bytes.fromhex(fields[0])
        except ValueError as exc:
            raise BuildError("Invalid SHA256SUMS digest.") from exc
        name = validate_relative(fields[1])
        if name in parsed_sums:
            raise BuildError(f"Duplicate SHA256SUMS entry: {name}")
        parsed_sums[name] = fields[0]
    expected_sum_names = archive_names | {release_catalogue_path.name, binary_hash_path.name}
    if set(parsed_sums) != expected_sum_names:
        raise BuildError("SHA256SUMS file-set mismatch.")
    for name, expected in parsed_sums.items():
        if sha256_file(release_dir / name) != expected:
            raise BuildError(f"SHA256SUMS verification failed: {name}")
    return {"targets": sorted(target_set), "archives": len(archive_names), "binaries": len(binary_rows)}


def audit_kit(root_dir: Path, checksum_file: Path) -> None:
    """Verify the entire durable build-kit tree against the root checksum manifest.

    Exclusion rules are computed dynamically from ``<root>/.gitignore``
    (when present) merged with the project invariants
    (``build``, ``release``, ``.git``, ``.venv``, ``__pycache__``). The two
    anchors BUILD_KIT_SHA256SUMS / BUILD_TOOLS_SHA256SUMS are never excluded.
    """
    ensure_directory(root_dir, "build kit root")
    ensure_regular(checksum_file, "build-kit checksum catalogue")
    expected: dict[str, str] = {}
    for line in read_bounded(checksum_file, MAX_JSON_BYTES).decode("ascii").splitlines():
        if not line:
            continue
        if "\t" in line or line.startswith(" ") or line.endswith(" "):
            raise BuildError("Invalid build-kit checksum whitespace.")
        fields = line.split("  ", 1)
        if len(fields) != 2 or len(fields[0]) != 64:
            raise BuildError("Invalid build-kit checksum entry.")
        try:
            bytes.fromhex(fields[0])
        except ValueError as exc:
            raise BuildError("Invalid build-kit SHA-256.") from exc
        rel = validate_relative(fields[1].replace(os.sep, "/"))
        if rel in expected:
            raise BuildError(f"Duplicate build-kit checksum entry: {rel}")
        expected[rel] = fields[0].lower()

    patterns = _effective_ignore_patterns(root_dir)
    actual: dict[str, str] = {}
    skip_top_level = {"build", "release", ".git", ".venv"}
    for current, dirs, files in os.walk(root_dir, topdown=True, followlinks=False):
        current_path = Path(current)
        kept_dirs: list[str] = []
        for name in sorted(dirs):
            child = current_path / name
            st = _lstat(child, "build-kit directory")
            if _is_reparse_or_link(st):
                raise BuildError(f"Build-kit directory is a symlink/reparse point: {child}")
            if not stat.S_ISDIR(st.st_mode):
                raise BuildError(f"Build-kit directory entry is not a directory: {child}")
            rel_dir = child.relative_to(root_dir).as_posix()
            if name == "__pycache__" or _is_gitignore_excluded(rel_dir, patterns):
                continue
            if current_path == root_dir and name in skip_top_level:
                continue
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in list(files):
            child = current_path / name
            if current_path == root_dir and name == checksum_file.name:
                continue
            ensure_regular(child, "build-kit file")
            rel = validate_relative(child.relative_to(root_dir).as_posix())
            if _is_gitignore_excluded(rel, patterns):
                continue
            actual[rel] = sha256_file(child)
    if set(actual) != set(expected):
        raise BuildError(f"Build-kit checksum file-set mismatch; missing={sorted(set(expected)-set(actual))} extra={sorted(set(actual)-set(expected))}")
    for rel, digest in expected.items():
        if actual[rel] != digest:
            raise BuildError(f"Build-kit checksum mismatch: {rel}")


def audit_tools(tools_dir: Path, checksum_file: Path) -> None:
    """Verify the build-tool tree against its checksum manifest.

    Uses the same dynamic .gitignore-driven exclusion logic as ``audit_kit``.
    """
    ensure_directory(tools_dir, "build tools")
    ensure_regular(checksum_file, "build-tool checksum catalogue")
    expected: dict[str, str] = {}
    for line in read_bounded(checksum_file, MAX_JSON_BYTES).decode("ascii").splitlines():
        if not line:
            continue
        if "\t" in line or line.startswith(" ") or line.endswith(" "):
            raise BuildError("Invalid build-tool checksum whitespace.")
        parts = line.split("  ", 1)
        if len(parts) != 2 or len(parts[0]) != 64:
            raise BuildError("Invalid build-tool checksum entry.")
        try:
            bytes.fromhex(parts[0])
        except ValueError as exc:
            raise BuildError("Invalid build-tool SHA-256.") from exc
        name = validate_relative(parts[1])
        if name in expected:
            raise BuildError(f"Duplicate build-tool checksum entry: {name}")
        expected[name] = parts[0]

    patterns = _effective_ignore_patterns(tools_dir)
    actual: dict[str, str] = {}
    for current, dirs, files in os.walk(tools_dir, topdown=True, followlinks=False):
        current_path = Path(current)
        dirs.sort(); files.sort()
        kept_dirs: list[str] = []
        for name in dirs:
            if name == "__pycache__":
                continue
            child = current_path / name
            st = _lstat(child, "build-tool directory")
            if _is_reparse_or_link(st) or not stat.S_ISDIR(st.st_mode):
                raise BuildError(f"Unsafe build-tool directory entry: {child}")
            rel_dir = child.relative_to(tools_dir).as_posix()
            if _is_gitignore_excluded(rel_dir, patterns):
                continue
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            child = current_path / name
            if name == checksum_file.name and current_path == tools_dir:
                continue
            ensure_regular(child, "build-tool file")
            rel = validate_relative(child.relative_to(tools_dir).as_posix())
            if _is_gitignore_excluded(rel, patterns):
                continue
            actual[rel] = sha256_file(child)
    if set(actual) != set(expected):
        raise BuildError(f"Build-tool checksum file-set mismatch; missing={sorted(set(expected)-set(actual))} extra={sorted(set(actual)-set(expected))}")
    for name, expected_hash in expected.items():
        if actual[name] != expected_hash:
            raise BuildError(f"Build-tool checksum mismatch: {name}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="nexs_build_core")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("validate-source"); p.add_argument("--source", type=Path, required=True)
    p = sub.add_parser("prepare-source"); p.add_argument("--source", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("catalogue-package"); p.add_argument("--package", type=Path, required=True); p.add_argument("--target", required=True); p.add_argument("--version", required=True); p.add_argument("--source", type=Path, required=True); p.add_argument("--identity", type=Path, required=True); p.add_argument("--provenance", type=Path)
    p = sub.add_parser("archive-package"); p.add_argument("--package", type=Path, required=True); p.add_argument("--target", required=True); p.add_argument("--version", required=True); p.add_argument("--output-dir", type=Path, required=True)
    p = sub.add_parser("assemble-release"); p.add_argument("--stage", type=Path, required=True); p.add_argument("--version", required=True)
    p = sub.add_parser("verify-archive"); p.add_argument("--archive", type=Path, required=True); p.add_argument("--target", required=True); p.add_argument("--version", required=True)
    p = sub.add_parser("assemble-archives"); p.add_argument("--archives", type=Path, required=True); p.add_argument("--release", type=Path, required=True); p.add_argument("--version", required=True)
    p = sub.add_parser("verify-release"); p.add_argument("--release", type=Path, required=True); p.add_argument("--version", required=True); p.add_argument("--require-all", action="store_true")
    p = sub.add_parser("audit-kit"); p.add_argument("--root", type=Path, required=True); p.add_argument("--checksums", type=Path, required=True)
    p = sub.add_parser("audit-tools"); p.add_argument("--tools-dir", type=Path, required=True); p.add_argument("--checksums", type=Path, required=True)
    p = sub.add_parser("catalogue-dependencies"); p.add_argument("--wheelhouse", type=Path, required=True); p.add_argument("--requirements", type=Path, required=True); p.add_argument("--output", type=Path, required=True); p.add_argument("--target", choices=sorted(TARGETS))
    p = sub.add_parser("emit-hashed-requirements"); p.add_argument("--catalogue", type=Path, required=True); p.add_argument("--requirements", type=Path, required=True); p.add_argument("--output", type=Path, required=True); p.add_argument("--target", choices=sorted(TARGETS))
    args = parser.parse_args(argv)
    if args.command == "validate-source":
        print(validate_source(args.source)); return 0
    if args.command == "prepare-source":
        prepare_source(args.source, args.output); return 0
    if args.command == "catalogue-package":
        provenance = None
        if args.provenance:
            provenance = json.loads(read_bounded(args.provenance, MAX_JSON_BYTES).decode("utf-8"))
        package_catalogue(args.package, args.target, args.version, args.source, args.identity, provenance); return 0
    if args.command == "archive-package":
        print(archive_package(args.package, args.target, args.version, args.output_dir)); return 0
    if args.command == "assemble-release":
        print(json.dumps(assemble_release(args.stage, args.version), sort_keys=True)); return 0
    if args.command == "verify-archive":
        verify_archive(args.archive, args.target, args.version); print("archive verified"); return 0
    if args.command == "assemble-archives":
        print(json.dumps(assemble_archives(args.archives, args.release, args.version), sort_keys=True)); return 0
    if args.command == "verify-release":
        print(json.dumps(verify_release(args.release, args.version, args.require_all), sort_keys=True)); return 0
    if args.command == "audit-kit":
        audit_kit(args.root, args.checksums); return 0
    if args.command == "audit-tools":
        audit_tools(args.tools_dir, args.checksums); return 0
    if args.command == "catalogue-dependencies":
        catalogue_dependencies(args.wheelhouse, args.requirements, args.output, args.target); return 0
    if args.command == "emit-hashed-requirements":
        emit_hashed_requirements(args.catalogue, args.requirements, args.output, args.target); return 0
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (BuildError, OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"[nexs-build-core][ERROR] {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
