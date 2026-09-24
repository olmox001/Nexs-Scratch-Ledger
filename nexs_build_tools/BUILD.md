# Nexs Ledger hardened release build system
## This module is under development; the build tool is not yet ready! Do not use for releases; use only for its own development.

This kit builds `main.py` without modifying the trusted application source. The only transformation occurs in a disposable source copy so the compiled executable can expose the internal `--build-identity` query used by the release verifier. The normal application entry path remains unchanged.

The hardening model is defense-in-depth: fail-closed validation, explicit trust boundaries, stable-descriptor file reads, deterministic packaging, provenance, checksum manifests, dependency closure and independent post-build verification. This is not a formal military or security certification.

## Target matrix

The release matrix contains eight independent artifacts:

- `macos-x86_64` — Intel 64-bit macOS, including Apple Silicon hosts using Rosetta 2
- `macos-arm64` — Apple Silicon
- `linux-x86_64` — Linux with glibc
- `linux-aarch64` — Linux ARM64 with glibc
- `linux-musl-x86_64` — Linux x86-64 with musl
- `linux-musl-aarch64` — Linux ARM64 with musl
- `windows-x86_64` — Windows x64 with MSVC/UCRT
- `windows-arm64` — Windows ARM64 with MSVC/UCRT

POSIX never fabricates PE executables. Linux architecture/libc combinations that do not match the host are built inside isolated Docker/Podman target environments. Windows is built natively through PowerShell or the corresponding GitHub Actions runner. The current GitHub-hosted runner labels are `macos-15-intel`, `macos-15`, `ubuntu-24.04`, `ubuntu-24.04-arm`, `windows-2025-vs2026`, and `windows-11-vs2026-arm`; the Windows ARM64 VS 2026 image is currently generally available.

## CPython and dependencies

The build baseline is CPython 3.12.x. The exact Python-package graph is pinned in `requirements-build.txt`:

```text
Nuitka==4.2.2
cryptography==48.0.1
cffi==2.1.1
pycparser==2.23
ordered-set==4.1.0
setuptools==83.0.0
argon2-cffi==23.1.0
argon2-cffi-bindings==21.2.0
```

Nuitka 4.2.2 is handled as a trusted source distribution rather than being accepted through a generic sdist rule. The exact PyPI source archive is pinned by SHA-256 in `nexs_build_core.py`, and the build uses `--no-build-isolation` after the pinned setuptools bootstrap so the compiler build cannot silently fetch another build dependency. Nuitka's standalone mode creates a self-contained distribution directory; this kit deliberately does not use onefile because the application relies on normal filesystem semantics such as `__file__`.

`setuptools==83.0.0` is pinned explicitly. This prevents an uncontrolled build backend from entering the compiler build environment. The wheelhouse is downloaded first, catalogued, hash-checked and then installed with `--no-index --find-links --no-deps`. `pip check` and exact package-version verification run after installation.

The default package index is `https://pypi.org/simple`. Any custom HTTPS index requires the explicit `NEXS_ALLOW_CUSTOM_PIP_INDEX=1` opt-in. This keeps the normal build path closed against accidental `PIP_*` injection while allowing a deliberately trusted private mirror.

## musl support

The two musl targets use target-native Alpine containers. The pinned default image is:

```text
python:3.12.14-alpine3.24@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a
```

The glibc Linux builder uses:

```text
python:3.12.14-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254
```

Both are versioned by tag and pinned by digest by default. `NEXS_REQUIRE_PINNED_IMAGE=1` is therefore fail-closed. The container is checked for the expected machine and dynamic loader before compilation, and the provenance records image reference, resolved digest and image ID.

The dependency catalogue checks musl wheels against `musllinux_*` compatibility and rejects glibc-only `manylinux_*` wheels for musl targets. This follows the platform-tag model defined for musllinux wheels.

## Standalone package and binary pair

Each target contains exactly:

```text
Windows: nexs_ledger.exe + test.py
Unix:    nexs_ledger    + test.py
```

`nexs_ledger` (or `nexs_ledger.exe`) is the single compiled application binary. There is no second, byte-identical "test_ledger" copy of it: an earlier revision shipped one purely to have a differently-named file to run `--self-test` against a second time, which verified nothing beyond what verifying `nexs_ledger` itself already proved. `test.py` is bundled alongside it as plain, uncompiled data (via Nuitka `--include-data-files`, the same mechanism used to embed `main.py`'s own source for hash binding) so it is never compiled together with `main.py`.

`test.py`'s `--binary PATH [--source PATH]` mode drives the packaged binary out-of-process through its own `--self-test` and `--build-identity` entry points, and — when `--source` is given — checks the reported `program_hash` against that source file. The build runs this exactly once per target, after compilation, instead of the previous three self-test invocations per target (source pre-check, duplicate-binary self-test, main self-test); the pre-compile source self-test (`main.py --self-test`, run directly against the disposable source copy before spending time compiling) is kept because it is a distinct, useful fail-fast check, not a repeat of the same work.

The per-target `BINARY_CATALOGUE.json` binds the single binary's hash to the internal program hash, runtime fingerprint and program-version hash (catalogue schema 4; schema 3 and earlier recorded the now-removed `test_ledger`/`test_ledger.exe` pair). The final `BINARY_HASH_CATALOGUE-VERSION.json` is generated only from per-target catalogues that passed complete archive verification.

## Stable file and archive handling

The shared verifier reads trusted files through a single descriptor, rejects symlinks/reparse points, checks regular-file type and compares the initial/final descriptor metadata. Windows binary descriptors explicitly request `O_BINARY` so raw archive/hash reads cannot receive text-mode translation.

ZIP and TAR.GZ creation is deterministic: sorted members, normalized metadata, fixed archive timestamps, fixed gzip metadata and explicit synchronization of temporary archive files before atomic publication. Archive verification rejects path traversal, duplicate members, non-regular TAR members, unsafe ZIP Unix types, oversized compressed payloads and archive mutation during reading.

The build-core implementation is the single archive/catalogue authority used by both Bash and PowerShell, preventing platform-specific verifier drift.

## Development virtualenv trust model

`build_release.sh`/`build_release.ps1` delegate creation of the project's own
development virtualenv (`./.venv`, distinct from the disposable per-target
build venv under `./build/*/venv`) to `setup_env.sh`/`setup_env.ps1`, then
verify the resulting interpreter before using it to run `test.py` and import
`main.py`.

The verification differs by platform because `python -m venv` itself differs
by platform:

- **POSIX (`setup_env.sh` / `build_release.sh`).** `venv` always creates
  `.venv/bin/python` as a symlink chain (e.g. `python -> python3 ->
  /usr/bin/python3`); this is standard library behavior, not a project
  choice, and happens on every macOS/Linux install. `build_release.sh`
  therefore does **not** use the generic "reject any symlink"
  `require_regular()` check on this path — that would (and previously did)
  reject every normal venv. Instead it uses a dedicated
  `require_venv_python()` check that resolves the full symlink chain and
  validates the properties that actually matter: the chain terminates, the
  resolved target is a real executable regular file, and it does not resolve
  into a world-writable shared location (`/tmp`, `/var/tmp`, `/dev/shm`).
  The `.venv` directory itself is still required not to be a symlink, which
  preserves the original defense against `NEXS_DEV_VENV_DIR` being pointed
  somewhere untrusted via a redirected directory.
- **Windows (`setup_env.ps1` / `build_release.ps1`).** `venv` copies the
  interpreter binary into `.venv\Scripts\python.exe` by default on Windows
  rather than linking it, so `Assert-File`'s reparse-point rejection is
  correct as-is and needs no equivalent adjustment.

All other `require_regular`/`Assert-File`/`ensure_regular` checks throughout
the toolchain (checksum manifests, `main.py`/`test.py`, the build core,
the compiled `nexs_ledger` binary, dependency wheels) are checks
on artifacts that are genuinely expected to be plain regular files, and are
unaffected by this distinction.

## Build isolation and cleanup

`SOURCE_DATE_EPOCH` controls deterministic archive timestamps and defaults to `0`. Build state is confined to `./build`, with all Python/pip/Nuitka temporary state forced under `./build/.tmp`. The build directory is deleted before work begins and removed again on normal or exceptional exit unless `NEXS_KEEP_BUILD=1` is explicitly requested. A cleanup failure is itself a build failure.

Container builds run with dropped Linux capabilities and `no-new-privileges`. Only the disposable target context is mounted. System dependencies are installed only when the selected targets actually need a native host toolchain; pure container builds do not require unnecessary host package installation.

## Release layout

For example, version `0.0.1.0` creates separate artifacts such as:

```text
macos-x86_64-0.0.1.0.tar.gz
macos-arm64-0.0.1.0.tar.gz
linux-x86_64-0.0.1.0.tar.gz
linux-aarch64-0.0.1.0.tar.gz
linux-musl-x86_64-0.0.1.0.tar.gz
linux-musl-aarch64-0.0.1.0.tar.gz
windows-x86_64-0.0.1.0.zip
windows-arm64-0.0.1.0.zip
```

The release root also contains:

```text
RELEASE_CATALOGUE-0.0.1.0.json
BINARY_HASH_CATALOGUE-0.0.1.0.json
SHA256SUMS-0.0.1.0
```

Existing release versions are never overwritten. `release/` is durable; `build/` is disposable.

## Supply-chain trust

`BUILD_KIT_SHA256SUMS` covers the complete durable kit. `BUILD_TOOLS_SHA256SUMS` covers the build-tool tree. The wrappers independently verify the root checksum manifest before importing the build core, and the core verifies the complete tree again before and after compilation. The build-tool self-test independently verifies the trusted core hash before importing it.

The dependency graph is closed after download: the expected versions come from `requirements-build.txt`, the downloaded wheel/sdist artefacts are catalogued, Nuitka's trusted sdist has an exact pinned SHA-256, and installation occurs only from the local wheelhouse.

The GitHub Actions workflow pins action commits, disables persisted checkout credentials, limits job runtimes and uploads only archives that have already passed independent archive verification.

## Verification

`test.py` runs at least 280 atomic checks and is the build-kit verification source at the project root. The current suite covers:

- the complete eight-target matrix, including both glibc and musl Linux targets;
- ELF, PE and Mach-O architecture validation and Linux dynamic-loader validation;
- wheel/musllinux metadata and target compatibility;
- exact trusted Nuitka source-distribution hashing;
- archive traversal, duplicate-entry, unsafe-type and mutation rejection;
- deterministic archive creation;
- source immutability and build-identity binding;
- checksum-tree exactness, symlink/reparse rejection and AST duplicate-function detection;
- static checks on Bash, PowerShell and GitHub Actions hardening.

The actual application self-test is also executed before and after packaging: once against the source (fail-fast, before compilation) and once against the compiled binary itself, via `test.py --binary`, after compilation. In the development environment used to prepare this kit, The completed build-harness suite is the authoritative verification and must be rerun on every modified kit.

## Commands

POSIX:

```sh
./nexs_build_tools/build_release.sh -V 0.0.1.0 -t linux-x86_64
./nexs_build_tools/build_release.sh -V 0.0.1.0 -t linux-musl-x86_64
./nexs_build_tools/build_release.sh -V 0.0.1.0 -t linux-musl-aarch64
./nexs_build_tools/build_release.sh -V 0.0.1.0 --host-only
```

Windows:

```powershell
.\nexs_build_tools\build_release.ps1 -V 0.0.1.0 -HostOnly
.\nexs_build_tools\build_release.ps1 -V 0.0.1.0 -Target windows-arm64 -NoPublish -ArtifactOut C:\trusted-artifacts
```

Verification:

```sh
./nexs_build_tools/verify_release.sh -V 0.0.1.0 --require-all
```

```powershell
.\nexs_build_tools\verify_release.ps1 -V 0.0.1.0 -RequireAll
```

## CI matrix

`.github/workflows/build-release.yml` builds all eight targets independently, verifies every target archive before upload, then reconstructs the final release only from those verified archives. The final CI stage requires the complete eight-target matrix. Current GitHub-hosted ARM64 and Intel runner labels used by the workflow are verified against GitHub's runner documentation.
