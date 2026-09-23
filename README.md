# Nexs-Scratch-Ledger

**Universal Signed Incremental Ledger** — a self-contained, hardened append-only ledger implemented in a single Python file, using Ed25519 signatures, Argon2id key derivation, and a signed hash chain.

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Security Model](#security-model)
  - [Threat Model](#threat-model)
  - [What Is Protected](#what-is-protected)
  - [What Is Not Protected](#what-is-not-protected)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Interactive Mode](#interactive-mode)
  - [Identity Modes](#identity-modes)
  - [Environment Variables](#environment-variables)
- [Workspace Layout](#workspace-layout)
- [Trust Anchors](#trust-anchors)
- [Architecture](#architecture)
  - [Manifest](#manifest)
  - [Ledger Blocks](#ledger-blocks)
  - [Segments](#segments)
  - [Hash Chain](#hash-chain)
  - [Crash Recovery](#crash-recovery)
  - [Dataset Layer](#dataset-layer)
  - [External Resources](#external-resources)
- [Key Derivation](#key-derivation)
- [Append Performance Contract](#append-performance-contract)
- [Benchmark / Regression Harness](#benchmark--regression-harness)
- [Self-Test Suite](#self-test-suite)
- [Public API Reference](#public-api-reference)
- [Configuration Constants](#configuration-constants)
- [Extending the Ledger](#extending-the-ledger)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Overview

Nexs-Scratch-Ledger is a **signed incremental ledger** designed to be:

- **Tamper-evident**: every committed operation is Ed25519-signed and chained to its predecessor via SHA-256.
- **Self-contained**: one authoritative Python file, no framework, no hidden magic.
- **Portable**: JSON on disk, readable with any text editor, verifiable without running the program.
- **Fail-closed**: missing cryptographic dependencies abort the program instead of silently falling back to weaker primitives.
- **Incremental**: writes are append-only, and the commit path is **O(1)** with respect to the number of already-committed operations.

It is intended for local-first applications that need an auditable, signable record of events: pricing engines, inventory systems, configuration trackers, audit logs, and any scenario where "who wrote what, when, and can we prove it was not changed afterwards" matters.

The bundled demo application computes age- and date-based discounts, but the ledger core is generic: the demonstration is only one of many possible workloads built on top of `PREF_commit_operation()`.

---

## Key Features

| Feature | Description |
|---|---|
| **Ed25519 signatures** | Every ledger block and the manifest are signed with Ed25519. |
| **Argon2id key derivation** | The 32-byte signing seed is derived at runtime from username + password + program hash using memory-hard Argon2id (m=64 MiB, t=3, p=1). |
| **Hash-chained append log** | Each block commits to the previous block's `chain_hash`; the manifest pins the current chain tip. |
| **Signed manifest** | Program hash, runtime fingerprint, extension list, segment state, and counters live in a signed manifest. |
| **External trust anchors** | Pin a workspace's public key out-of-band; TOFU is optional and can be disabled entirely. |
| **Crash recovery** | Complete-but-uncommitted tails are adopted; incomplete final frames are truncated; ambiguous states halt the program. |
| **Generic dataset layer** | Signed, revisioned, checkpointed JSON dataset mutations on top of the block ledger. |
| **External resource binding** | Content-addressed descriptors for external JSON and read-only SQLite files. |
| **Bilingual UI** | Italian / English interface, auto-detected from the keyboard layout, overrideable at runtime. |
| **Hash-allow-listed extensions** | Optional Python plugins gated by exact SHA-256 allow-listing. |
| **Advisory file locking** | POSIX `flock` / Windows `msvcrt.locking` to prevent accidental concurrent writers. |

---

## Security Model

### Threat Model

Nexs-Scratch-Ledger protects against:

- **Post-hoc modification** of committed ledger data.
- **Unauthorized writes** by parties who do not know the credentials.
- **Silent truncation** or rollback of the ledger tail.
- **Path traversal** and unsafe filesystem targets crafted inside the manifest.
- **Cross-program replay**: seeds derived under one program hash do not authenticate under another.
- **Substitution attacks** on pinned public keys via external trust anchors.

### What Is Protected

- **Integrity and authenticity** of every committed block and the manifest.
- **Credential-gated write access** to a workspace.
- **Program/runtime identity binding**: reads still work when the program changes, but writes are disabled.
- **External resource integrity** through content-addressed descriptors stored in signed payloads.

### What Is Not Protected

- **Confidentiality**: on-disk data is plain JSON. This is integrity/authenticity, not encryption. Use full-disk or filesystem-level encryption if confidentiality is required.
- **Availability**: a hostile process with filesystem access can delete files. The signed chain detects this at next open, but does not prevent it.
- **The lock file as a security boundary**: the workspace lock is **advisory only**. A careless or hostile process that does not cooperate can still mutate files. Integrity is enforced by signatures, not by the lock.
- **TOFU window**: by default, the first time a workspace is opened its public key is pinned on trust-on-first-use. Deployments that require strict pinning must set `NEXS_REQUIRE_ANCHOR=1` and pre-distribute anchors.

---

## Requirements

- **Python 3.10+** (uses `datetime.fromisoformat` with timezone-aware parsing, `pathlib.Path.as_uri`, `str.removeprefix`-style idioms, and modern typing).
- **cryptography ≥ 41** — Ed25519 signing.
- **argon2-cffi ≥ 23** — Argon2id key derivation.

Optional (only needed when using the corresponding features):

- `sqlite3` (bundled with Python) — for external SQLite resources.
- Platform-specific keyboard-layout probes (`gsettings`, `setxkbmap`, `localectl`, `defaults`, PowerShell `Get-WinUserLanguageList`) — used best-effort for language detection.

Missing cryptographic dependencies cause the program to **fail closed** at import time.

---

## Installation

```bash
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install "cryptography>=41" "argon2-cffi>=23"
```

Place `main.py` in the directory where workspaces will be created. Optional:

- `extensions/` — directory for hash-allow-listed Python extensions.
- `external/` — directory for external data resources.
- `trust_anchors/` — default trust-anchor directory (see [Trust Anchors](#trust-anchors)).

---

## Quick Start

```bash
python3 main.py
```

On first boot you will be asked for a language, then for credentials (leave both blank for generic mode), then whether to create or load a workspace.

---

## Usage

### Interactive Mode

```bash
python3 main.py
```

Flow:

1. Keyboard language is detected; you may override it.
2. Credentials are collected. Username and password must be **both** filled or **both** blank.
3. A workspace is created or loaded.
4. Committed history is displayed.
5. If authorized, the demo discount session starts and each operation is signed and appended.

### Identity Modes

| Mode | Input | Effect |
|---|---|---|
| **Generic** | blank username **and** blank password | Key derived from `0 + program_hash`. Publicly reconstructable — **does not provide secret authenticity**. Useful for read-mostly or demo workspaces. |
| **User** | non-empty username **and** non-empty password | Key derived from normalized username + password + program hash via Argon2id. |

Mixing (only one non-empty) is rejected and re-prompted.

### Environment Variables

| Variable | Effect |
|---|---|
| `NEXS_TRUST_ANCHOR_DIR` | Absolute path to the trust-anchor directory. Must be absolute. Defaults to `<program_dir>/trust_anchors`. |
| `NEXS_REQUIRE_ANCHOR` | Set to `1`, `true`, `yes`, or `on` to disable TOFU: workspace creation aborts if the anchor cannot be persisted, and opening aborts if no anchor exists. |

---

## Workspace Layout

```
workspace_dir/
├── manifest.json               # Signed workspace manifest
├── segments/
│   ├── 000000000001.nxsb       # Append-only ledger segment
│   └── 000000000002.nxsb
├── .staging/                   # Reserved for future staging operations
└── .workspace.lock             # Advisory lock (POSIX flock / Windows msvcrt)
```

Logical workspace names are never used as filesystem paths. Instead, the physical directory name is `nxsl_<sha256(logical_name)[:48]>.nxsl`, which removes any possibility of path traversal.

---

## Trust Anchors

A trust anchor pins a workspace's Ed25519 public key out-of-band. When an anchor exists for a logical workspace name, the manifest's public key **must** match it, or `PREF_load_manifest` raises and the workspace is refused.

Anchor files live in the trust-anchor directory and are JSON documents:

```json
{
  "schema_version": 1,
  "workspace_name": "<logical name>",
  "public_key_ed25519": "<base64>",
  "created_utc": "<ISO-8601, timezone-aware>"
}
```

Filename: `nxsl_<sha256(normalized_name)[:48]>.anchor`.

**Hardened deployments** should relocate the trust-anchor directory outside the program tree:

```bash
export NEXS_TRUST_ANCHOR_DIR=/etc/nexs/trust_anchors
export NEXS_REQUIRE_ANCHOR=1
```

On Windows: `%PROGRAMDATA%\Nexs\trust_anchors`.

When `NEXS_REQUIRE_ANCHOR=1`, missing anchors are hard failures, not TOFU opportunities.

---

## Architecture

### Manifest

The manifest is the workspace's signed header. It contains:

- Protocol name, schema version, ledger ID.
- Logical name and creation timestamp.
- **Program identity**: program version, program hash, runtime fingerprint, Python implementation/version.
- **Extension list**: `{file, sha256}` descriptors for allow-listed Python extensions.
- **Credentials metadata**: `credential_mode` (`generic` / `user`) and `username_fingerprint`.
- **Ledger counters**: `operation_count`, `next_operation_number`, `last_chain_hash`.
- **Segment descriptors**: numbered list of `{segment_number, file, rows, committed_offset, sealed, sha256}`.
- **Public read key**: a non-secret SHA-256 that fingerprints the ledger/program context.
- **`manifest_signature`**: Ed25519 signature over the canonical JSON of the manifest without the signature field.

Validation order on load:

1. Parse JSON.
2. **Verify Ed25519 signature** over the unsigned body.
3. Enforce the external trust anchor, if one exists.
4. Validate structural schema.
5. Verify the derived public read key.

Signature verification happens **before** structural parsing, so malformed-but-signed content is rejected at the cryptographic layer.

### Ledger Blocks

Each committed operation is a single JSON object serialized on one line:

```json
{
  "schema_version": 4,
  "program_hash": "<sha256>",
  "runtime_fingerprint": "<sha256>",
  "operation_number": 1,
  "started_utc": "2026-01-01T00:00:00+00:00",
  "ended_utc":   "2026-01-01T00:00:01+00:00",
  "operation_type": "discount_example",
  "payload": { "...": "..." },
  "previous_chain_hash": "<sha256>",
  "block_hash": "<sha256>",
  "chain_hash": "<sha256>",
  "signature": "<base64 ed25519>"
}
```

- `block_hash` = SHA-256 of the canonical JSON of the body (without `block_hash`, `chain_hash`, `signature`).
- `chain_hash` = SHA-256 of `previous_chain_hash || block_hash`.
- `signature` = Ed25519 signature over the canonical JSON of the block **including** `block_hash` and `chain_hash`, but excluding `signature`.

### Segments

The ledger is split into segments of up to `PREF_MAX_ROWS_PER_SEGMENT` (default 100,000) rows. Segment files are named `000000000001.nxsb`, `000000000002.nxsb`, ...

Each segment has:

- `rows` — number of committed blocks in the segment.
- `committed_offset` — byte length of the committed prefix.
- `sealed` — true once the segment is full.
- `sha256` — hash of the whole file once sealed, `null` otherwise.

The manifest's `current_segment` always equals the number of segments.

### Hash Chain

```
genesis_hash = "0" * 64
chain_hash[1] = sha256(genesis_hash  || block_hash[1])
chain_hash[n] = sha256(chain_hash[n-1] || block_hash[n])
```

The manifest's `last_chain_hash` is the tip. Full-chain verification (`PREF_verify_full_chain`) walks every committed byte, checks every block's signature, hash, and numbering, and compares the recomputed tip and operation count against the manifest.

### Crash Recovery

On open (write-enabled only), recovery runs in two phases:

1. **Orphan segment recovery**: only the single immediate next segment is considered. Extra files that are not the immediate successor cause a hard failure.
2. **Tail recovery inside the current segment**:
   - A complete, valid, and correctly-numbered tail is **adopted** and the manifest is re-signed.
   - A complete frame followed by an incomplete frame is **truncated** at the start of the incomplete frame.
   - A complete-but-unauthentic frame is a **hard failure**; the program refuses to continue.
   - A partial first frame that cannot be attributed to a valid block is truncated.

Recovery is **never performed in read-only mode**: an uncommitted tail is reported and left untouched.

### Dataset Layer

A signed, revisioned, checkpointed JSON mutation layer sits on top of the block ledger.

- **Genesis**: `dataset_genesis` creates a dataset with `revision = 0` and a signed snapshot. Only one genesis per `dataset_id` is allowed.
- **Statements**: `dataset_statement` carries `{command, path, value}` where `command ∈ {set, delete, append}`. The caller must supply the current revision and a dataset whose canonical hash matches the signed ledger tip. The statement is applied, the result hash is recomputed, and both are signed into the block.
- **Checkpoints**: every `PREF_DATASET_CHECKPOINT_INTERVAL` revisions, `dataset_checkpoint` signs a full snapshot for fast replay.

`PREF_replay_dataset_ledger()` rebuilds a dataset strictly from the signed operation sequence, verifying revision continuity and every hash.

### External Resources

External files (JSON, SQLite) are bound into a signed payload via descriptors:

```json
{
  "path": "external/data.json",
  "sha256": "<file hash>",
  "size": 123
}
```

- Paths are restricted to `<program_dir>/external/`.
- Symlinks are rejected.
- Files are read through a single stable file descriptor; `stat` is compared before and after to detect races.
- SQLite is opened with `mode=ro` and `PRAGMA query_only=ON`.
- `PREF_attach_external_resources()` consumes the pending registry, so stale descriptors cannot leak into a later payload.

---

## Key Derivation

The signing seed (32 bytes) is derived in two stages:

1. **Identity digest**

   - *Generic mode*: `sha256("NEXS-GENERIC-WRITE|0|" || program_hash)`.
   - *User mode*: `sha256("NEXS-USER-WRITE|" || normalized_username || 0x00 || password || 0x00 || program_hash)`.

   The plaintext password never reaches the KDF; only its SHA-256 digest does. The `program_hash` is bound into the digest itself so that the same credentials on two different program versions produce unrelated seeds.

2. **Argon2id**

   - `secret = identity_digest`
   - `salt = sha256("NEXS-ARGON2-SALT|" || program_hash)`
   - `time_cost = 3`, `memory_cost = 65536 KiB`, `parallelism = 1`, `hash_len = 32`, `type = Argon2id`

The derived seed is **never written to disk**. It lives only in process memory for the duration of the session.

---

## Append Performance Contract

`PREF_append_block()` is **O(1)** with respect to the number of already-committed operations.

Full-chain verification is an **opening-time** operation performed once by `PREF_open_workspace()`. Re-verifying the full chain on every append would turn the commit path into O(n²) and is unnecessary because:

- The workspace is held under an advisory exclusive lock.
- The on-disk manifest is re-read and its signature re-verified by `PREF_load_manifest()` before any write.
- The new block's `previous_chain_hash` is checked against the signed manifest `last_chain_hash`, so it can only extend the exact chain verified at open time.
- The next `PREF_open_workspace()` call reruns full-chain verification and will detect any post-hoc tampering.

---

## Benchmark / Regression Harness

`test.py` loads `main.py` as a module, creates a temporary signed workspace, commits *N* signed operations, verifies the full chain warm and cold, and prints timing statistics.

```bash
python3 test.py           # default: 100 operations
python3 test.py 10000     # 10,000 operations
```

The harness **never touches** the real workspace or trust-anchor directories: both are redirected into a tempdir.

On completion, the harness asks whether to export the debug directory next to the current working directory (`nexs_debug_<utc-timestamp>/`). Useful for post-mortem inspection of a failed or suspicious run.

Typical output:

```
====================================================================
Nexs-Scratch-Ledger  ->  test.py
====================================================================
Operations requested : 10000
Program version      : Nexs-Scratch-Ledger/4+0123456789abcdef
Program hash         : 9b1c...
Runtime fingerprint  : 8a7d...
--------------------------------------------------------------------
Creating signed workspace ...
  workspace        : /tmp/nexs_test_.../workspaces/nxsl_....nxsl
  public key       : cD2f...
  read key         : 4f9e...
--------------------------------------------------------------------
Committing 10000 signed operations ...
  ...     1000/10000  ( 4200.5 ops/s, ETA   2.1s)
  ...
--------------------------------------------------------------------
Verifying committed chain (in-memory manifest) ...
Cold reload from disk ...
====================================================================
RESULTS
====================================================================
  Operations committed     : 10000
  Commit time              : 2.381 s (4200.5 ops/s, 0.24 ms/op)
  Full verify (warm)       : 0.912 s
  Cold reload+verify       : 1.104 s
  Segments used            : 1  (sealed: 0)
  Ledger bytes             : 4218931
  Manifest bytes           : 1187
  Last chain hash          : 5c3a...
  Manifest operation_count : 10000
  Manifest next_op_number  : 10001
====================================================================
TEST PASSED
====================================================================
```

---

## Self-Test Suite

Run the built-in comprehensive self-test with:

```bash
python3 main.py --self-test
```

The suite exercises (among others):

- Function naming/namespace invariants and duplicate-definition detection.
- Bilingual translation table consistency.
- Static analysis of literal `PREF_translate` calls and direct `PREF_*` calls.
- Argon2id determinism, program-hash binding, and credential validation.
- Signature round-trips and tamper rejection.
- Dataset application, immutability, hashing, replay, and rejection of malformed statements.
- Trust-anchor directory layout, idempotent creation, mismatch rejection, and strict parsing.
- Workspace creation, credential authorization, wrong-password denial, runtime mismatch read-only behavior.
- Segment rollover, orphan adoption, complete-tail adoption, incomplete-frame truncation.
- Atomic writes, symlink rejection, path-traversal rejection, and manifest signature gate.
- External JSON and SQLite resource loading, symlink rejection, and read-only enforcement.
- JSON canonicalization limits (depth, integer size, string size, container size).
- `NEXS_REQUIRE_ANCHOR` behavior.

The suite runs **more than 100 atomic checks** and aborts on the first failure.

---

## Public API Reference

All public symbols use the `PREF_` prefix. Highlights:

### Identity and key management

- `PREF_compute_runtime_identity()` — fingerprint the program, its extensions, Python runtime.
- `PREF_derive_private_seed(username, password, program_hash)` — Argon2id-derive the 32-byte seed.
- `PREF_public_key_from_seed(seed)` — raw Ed25519 public key.
- `PREF_sign_bytes(seed, data)` / `PREF_verify_signature(pubkey, data, sig_b64)`.
- `PREF_make_public_read_key(program_hash, runtime_fingerprint, ledger_id)`.

### Workspace lifecycle

- `PREF_create_workspace(logical_name, directory, credentials, identity, *, persist_anchor=True)` → `(workspace, manifest, seed)`.
- `PREF_load_manifest(workspace, logical_name)` → `(manifest, public_key)`.
- `PREF_open_workspace(workspace, logical_name, credentials, identity, *, perform_recovery=True, announce=True)` → `(manifest, public_key, write_allowed, seed_or_None)`.
- `PREF_authorize_workspace_write(manifest, identity, credentials, public_key)` → `(allowed, seed_or_None, reason)`.
- `PREF_exclusive_workspace_lock(workspace)` — context manager providing the advisory lock.

### Ledger writing

- `PREF_commit_operation(workspace, manifest, seed, public_key, operation_type, payload, started, ended)` → `block`.
- `PREF_build_block(...)`, `PREF_append_block(...)` — lower-level primitives.
- `PREF_verify_full_chain(workspace, manifest, public_key)` → `verified_count`.
- `PREF_read_all_operations(workspace, manifest)` → `[block, ...]`.

### Dataset layer

- `PREF_create_dataset_genesis(workspace, manifest, seed, public_key, dataset_id, dataset)` → `(state, block)`.
- `PREF_commit_dataset_statement(workspace, manifest, seed, public_key, dataset_id, revision, dataset, statement)` → `(state, block)`.
- `PREF_commit_dataset_checkpoint(workspace, manifest, seed, public_key, dataset_id, revision, dataset)` → `block`.
- `PREF_replay_dataset_ledger(operations, dataset_id)` → `(state, revision)`.
- `PREF_dataset_apply_statement(dataset, statement)` → `new_dataset`.

### External resources

- `PREF_load_verified_json(path)` → `(value, descriptor)`.
- `PREF_open_readonly_sqlite(path)` → `(connection, descriptor)`.
- `PREF_describe_external_resource(path)` → `descriptor`.
- `PREF_attach_external_resources(payload)` → `payload_with_descriptors`.

### Trust anchors

- `PREF_load_trust_anchors()` → `{normalized_name: public_key}`.
- `PREF_persist_trust_anchor(logical_name, public_key)` → `path`.
- `PREF_enforce_trust_anchor(logical_name, public_key)` → `"pinned_ok"` / `"unpinned"`.

### Utilities

- `PREF_canonical_json(value)` — bounded, canonical, sorted, ASCII-only JSON bytes.
- `PREF_sha256_bytes(data)` / `PREF_sha256_text(text)`.
- `PREF_hash_file_streaming(path)` — race-resistant file hashing.
- `PREF_write_atomic(path, content)` — atomic replace with durable fsync (POSIX).

---

## Configuration Constants

Key tunables at the top of `main.py`:

| Constant | Default | Purpose |
|---|---|---|
| `PREF_SCHEMA_VERSION` | `4` | On-disk protocol version. |
| `PREF_ARGON2_TIME_COST` | `3` | Argon2id iterations. |
| `PREF_ARGON2_MEMORY_COST_KIB` | `65536` | Argon2id memory (64 MiB). |
| `PREF_ARGON2_PARALLELISM` | `1` | Argon2id lanes. |
| `PREF_MAX_ROWS_PER_SEGMENT` | `100_000` | Segment rollover threshold. |
| `PREF_MAX_BLOCK_BYTES` | `8 MiB` | Maximum serialized block (incl. newline). |
| `PREF_MAX_MANIFEST_BYTES` | `4 MiB` | Maximum manifest size. |
| `PREF_MAX_RESOURCE_BYTES` | `64 MiB` | Maximum external resource size. |
| `PREF_MAX_JSON_DEPTH` | `64` | JSON nesting limit. |
| `PREF_MAX_JSON_CONTAINER_ITEMS` | `100_000` | Per-container limit. |
| `PREF_MAX_JSON_STRING_CHARS` | `1_000_000` | Per-string limit. |
| `PREF_MAX_JSON_INTEGER_BITS` | `4096` | Integer magnitude limit. |
| `PREF_MAX_WORKSPACE_NAME_CHARS` | `128` | Logical name length limit. |
| `PREF_MAX_OPERATIONS_PER_SESSION` | `1_000_000` | Demo session cap. |
| `PREF_DATASET_CHECKPOINT_INTERVAL` | `100` | Revisions between automatic checkpoints. |
| `PREF_MAX_TRUST_ANCHORS` | `10_000` | Anchor-directory entry cap. |

---

## Extending the Ledger

### Adding trusted Python extensions

1. Create `<program_dir>/extensions/mymodule.py`.
2. Compute its SHA-256.
3. Add an entry to `PREF_TRUSTED_EXTENSION_HASHES`:

   ```python
   PREF_TRUSTED_EXTENSION_HASHES = {
       "mymodule.py": "<exact sha256>",
   }
   ```

4. In `mymodule.py`, expose a registry of `PREF_*` functions:

   ```python
   def PREF_my_hook(payload: dict) -> dict:
       ...
       return {"processed": True}

   PREF_FUNCTIONS = {
       "PREF_my_hook": PREF_my_hook,
   }
   ```

Extensions run **in the same interpreter** as the main program with full process privileges. Only hash-allow-listed, reviewed code should ever be registered.

### Using the ledger for a non-demo workload

Replace `PREF_run_discount_session()` with your own driver that calls `PREF_commit_operation()` with your `operation_type` and `payload`. The payload must be JSON-canonicalizable and bounded; `PREF_require_json_value()` is enforced before any write.

---

## Troubleshooting

**`CRITICAL: the 'cryptography' package is required...`**
Install it: `pip install "cryptography>=41"`.

**`CRITICAL: the 'argon2-cffi' package is required...`**
Install it: `pip install "argon2-cffi>=23"`.

**`ERROR: mandatory trust anchor is not available for this workspace.`**
`NEXS_REQUIRE_ANCHOR=1` is set but no anchor exists. Either create the anchor via normal first-time creation, or distribute an anchor file for this workspace.

**`Mismatch del trust anchor: la chiave pubblica del workspace non corrisponde alla chiave fissata.`**
The pinned key differs from the manifest's key. Investigate: either the workspace was replaced, or the anchor is stale. Do **not** delete the anchor without confirming the correct key out-of-band.

**`CRITICAL ERROR: complete tail is not authentic; the program stops.`**
A complete-looking frame at the end of a segment failed signature verification. This is a hard integrity signal — the file has been tampered with, or a hostile process appended garbage. Inspect the file; do not truncate blindly.

**`Workspace is already open by another process.`**
Another cooperating instance holds the advisory lock. Wait or close it.

**`Read-only mode: data can be verified and displayed, but not modified.`**
Credentials were wrong, or the program/runtime fingerprint differs from the manifest. This is expected behavior; the workspace is opened read-only, which preserves integrity.

---

## License

This program is free software; you can redistribute it and/or modify it under the terms of the **GNU General Public License** as published by the Free Software Foundation; either **version 2** of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

Copyright (C) 2025 olmox001 — <https://github.com/olmox001>