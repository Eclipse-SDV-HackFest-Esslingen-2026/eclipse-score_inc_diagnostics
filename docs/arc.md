# Architecture Concept: External Projects as S-Core Modules

## Status

Draft — v0.1 (Hackfest 2026)

---

## 1. Problem Statement

Eclipse S-Core modules are developed within the `eclipse-score` GitHub organisation,
following its toolchain, build system (Bazel), and quality standards.
External projects — such as
[`eclipse-opensovd/classic-diagnostic-adapter`](https://github.com/eclipse-opensovd/classic-diagnostic-adapter)
— live in separate organisations, have their own build systems (Cargo), and cannot simply
be copied or forked into S-Core.

**Goal:** Make an external project buildable with the S-Core toolchain and integratable
into the
[reference integration](https://github.com/eclipse-score/reference_integration)
**without** modifying or owning the external repository.

---

## 2. Constraints

| Constraint | Rationale |
|---|---|
| External repo is **read-only** (reference only) | No forking, no ownership transfer |
| External source must remain unmodified | Preserve upstream's commit history and governance |
| Builds must be **reproducible** | Fixed commit SHA, no floating branch heads |
| S-Core toolchain must be used | Ferrocene (Rust), LLVM (C++), as defined in `score_toolchains_rust` / `toolchains_llvm` |
| Integration follows the `reference_integration` module pattern | `known_good.json` + `bazel_dep` + `git_override` |

---

## 3. Solution Overview

The solution introduces an **Adapter Module** pattern: a dedicated S-Core incubation
repository (`inc_diagnostics`) acts as the integration layer between the external project
and S-Core. It owns all the Bazel glue code, but never touches the external source.

```
┌─────────────────────────────────────────────────────────────────────┐
│  reference_integration                                              │
│                                                                     │
│  known_good.json  ──►  bazel_dep(inc_diagnostics)                  │
│                         git_override(commit = <sha>)               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ MODULE.bazel
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  inc_diagnostics  (Adapter Module — this repo)                     │
│                                                                     │
│  MODULE.bazel        declares: score_toolchains_rust, rules_rust   │
│  extensions/         repository_rule to fetch external source      │
│  src/                S-Core facing API / wrapper targets           │
│  tests/              validation tests using S-Core test infra      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ archive_override / http_archive
                               │ (fixed commit SHA + sha256)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  eclipse-opensovd/classic-diagnostic-adapter  (External, untouched)│
│                                                                     │
│  Cargo.toml / Cargo.lock    upstream source                        │
│  src/                       upstream source                        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Detailed Design

### 4.1 External Source Fetching (`extensions/cda_repo.bzl`)

A Bazel `repository_rule` downloads a **fixed commit archive** of the external project
and injects synthetic `BUILD.bazel` files.
The external source is never modified — all Bazel knowledge lives in the rule.

```
repository_rule
  url    = "https://github.com/eclipse-opensovd/classic-diagnostic-adapter/
             archive/<commit-sha>.tar.gz"
  sha256 = "<hash>"          # ensures reproducibility and integrity
  strip_prefix = "classic-diagnostic-adapter-<commit-sha>"
```

The rule generates `BUILD.bazel` files for each crate in the workspace so that
`rules_rust` can consume them without any changes to the upstream `Cargo.toml`.

### 4.2 Cargo Dependency Resolution

The upstream `Cargo.lock` is used directly via `crate_universe` (from `rules_rust`).
This guarantees that the exact same crate versions as in the upstream project are used:

```starlark
crate.from_cargo(
    name = "cda_crates",
    cargo_lockfile = "@classic_diagnostic_adapter//:Cargo.lock",
    manifests    = [ ... ],   # all workspace members
)
```

### 4.3 S-Core Toolchain Usage

The adapter module declares the same toolchain dependencies as all other S-Core modules
in its `MODULE.bazel`:

```starlark
bazel_dep(name = "score_toolchains_rust", version = "x.y.z")
register_toolchains("@score_toolchains_rust//toolchains/ferrocene:all")
```

This enforces that the external source is compiled with Ferrocene (the safety-qualified
Rust compiler) instead of the upstream's default toolchain.

### 4.4 Public API Surface (`src/`)

The `src/` directory exposes **S-Core-facing Bazel targets** that consumers reference.
These targets are thin wrappers or re-exports of the underlying external crate targets:

```
//src:opensovd_cda        →  @classic_diagnostic_adapter//cda-main:opensovd_cda
//src:cda_lib             →  @classic_diagnostic_adapter//cda-main:opensovd_cda_lib
```

Consumers in the reference integration only depend on `//src:*` labels, never on
`@classic_diagnostic_adapter` directly. This decouples the integration from internal
naming details of the external project.

### 4.5 Version Pinning Strategy

| Aspect | Mechanism |
|---|---|
| External source version | Commit SHA in `cda_repo.bzl` URL |
| Integrity check | `sha256` attribute in repository_rule |
| S-Core module version | Git tag + `known_good.json` entry |
| Bazel registry entry | `MODULE.bazel` `version` field |

Floating branch references (e.g. `refs/heads/main`) are **explicitly forbidden**
for production builds. A dedicated update process (script or workflow) bumps
the pinned SHA when a new upstream release is validated.

---

## 5. Integration into `reference_integration`

### 5.1 `known_good.json` Entry

```json
"score_inc_diagnostics": {
    "repo": "https://github.com/eclipse-score/inc_diagnostics.git",
    "hash": "<commit-sha>",
    "metadata": {
        "code_root_path": "//src/...",
        "langs": ["rust"]
    }
}
```

### 5.2 Generated `MODULE.bazel` Fragment

The `update_module_from_known_good.py` script generates this in
`bazel_common/score_modules_target_sw.MODULE.bazel`:

```starlark
bazel_dep(name = "score_inc_diagnostics")
git_override(
    module_name = "score_inc_diagnostics",
    commit      = "<sha>",
    remote      = "https://github.com/eclipse-score/inc_diagnostics.git",
)
```

### 5.3 Showcase / Deployment Target

A `showcases/` entry in the reference integration demonstrates the CDA running
inside a target image (e.g. `autosd_x86_64`), validating the full toolchain path
from source to deployable binary.

---

## 6. Open Issues / Next Steps

| # | Topic | Priority |
|---|---|---|
| 1 | Replace floating `refs/heads/main` URL with pinned commit SHA + sha256 | High |
| 2 | Add `MODULE.bazel` to `inc_diagnostics` with correct `name` and `version` | High |
| 3 | Publish `inc_diagnostics` to the S-Core Bazel registry | Medium |
| 4 | Define the public `//src:*` API surface | Medium |
| 5 | Add entry to `reference_integration/known_good.json` | Medium |
| 6 | CI workflow for upstream version bump validation | Low |
| 7 | Evaluate `mbedtls-sys` build script (cmake download) in sandbox | High |
| 8 | ~~Replace host-system OpenSSL with a Bazel-managed static dependency~~ | ✅ Done |

---

## 7. Alternatives Considered

### Fork the external repository
Rejected — creates a maintenance burden and governance conflict.
The external project has its own committer community.

### Publish external project to S-Core Bazel registry directly
Rejected — requires the external project to adopt Bazel modules natively.
This adapter pattern bridges the gap without requiring upstream changes.

### Use `git_submodule`
Rejected — not compatible with Bazel's hermetic fetch model and creates
ambiguous ownership of build rules.

---

## 8. Implementation Findings (HackFest 2026)

During the HackFest implementation the following deviations from the original concept
were discovered and resolved.

### 8.1 Ferrocene incompatible with `time-macros 0.2.27`

The architecture assumed `score_toolchains_rust` (Ferrocene) as the Rust toolchain.
In practice, the CDA dependency tree pulls in `time-macros 0.2.27`, which uses the
nightly-only `proc_macro_span` feature unavailable in Ferrocene.

**Resolution:** The adapter module uses **standard Rust 1.88.0** via the `rules_rust`
toolchain extension instead of Ferrocene.  
Adopting Ferrocene remains a long-term goal once upstream reduces the nightly dependency.

```starlark
rust = use_extension("@rules_rust//rust:extensions.bzl", "rust")
rust.toolchain(edition = "2024", versions = ["1.88.0"])
```

### 8.2 Workspace-member deps absent from `all_crate_deps()`

`crate_universe`'s `all_crate_deps()` macro only returns external registry crates.
Cross-crate dependencies within the CDA workspace (e.g. `cda-core` depending on
`cda-interfaces`) are **not** included automatically.

**Resolution:** Every injected `BUILD.bazel` explicitly lists workspace-member deps:

```starlark
# example for cda-sovd
deps = all_crate_deps() + [
    "//cda-build:cda_build",
    "//cda-interfaces:cda_interfaces",
    "//cda-plugin-security:cda_plugin_security",
    "//cda-sovd-interfaces:sovd_interfaces",
    "//cda-tracing:cda_tracing",
],
```

This requires analysing every `Cargo.toml` workspace dependency manually and encoding
it in `_LIB_BUILDS` inside `extensions/cda_repo.bzl`.

### 8.3 Starlark `.format()` silently drops `load()` lines

When building the `BUILD.bazel` content via a template string, Starlark's `.format()`
method silently stripped any `load()` statement that contained an `@`-label
(e.g. `load("@cda_crates//:defs.bzl", ...)`).

**Resolution:** All BUILD content is assembled via **string concatenation** rather than
`.format()`:

```starlark
return (
    'load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")\n' +
    'load("@rules_rust//rust:defs.bzl", "rust_library")\n' +
    ...
)
```

### 8.4 `cda-main/build.rs` calls `git` — unavailable in Bazel sandbox

The upstream `build.rs` executes `git rev-parse HEAD` and `git log` to embed version
metadata. Bazel's hermetic sandbox blocks network and process access, causing the build
script to fail.

**Resolution:** The `repository_rule` replaces `cda-main/build.rs` with a
sandbox-compatible stub that writes fixed values derived from the pinned commit SHA:

```rust
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-env=BUILD_DATE=2026-04-28T00:00:00Z");
    println!("cargo:rustc-env=GIT_COMMIT_HASH=ce3a566");
}
```

### 8.5 `mbedtls-sys` downloads mbedTLS source at build time

`comm-mbedtls/mbedtls-sys/build.rs` attempts to download the mbedTLS 4.0.0 source
archive via HTTP during the build script. This fails in the Bazel sandbox (no network).

**Resolution:** The `repository_rule` pre-fetches mbedTLS 4.0.0 into the external
repository directory before any build action runs:

```starlark
rctx.download_and_extract(
    url    = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.0.0/mbedtls-4.0.0.tar.bz2",
    sha256 = "2f3a47f7b3a541ddef450e4867eeecb7ce2ef7776093f3a11d6d43ead6bf2827",
    output = "comm-mbedtls/mbedtls-sys/mbedtls-4.0.0",
    stripPrefix = "mbedtls-4.0.0",
)
```

The pre-fetched directory is declared as `data` in the `cargo_build_script` rule so
Bazel includes it in the sandbox. `MBEDTLS_SKIP_PATCH=1` prevents the build script from
applying patches (which also require network or external tools).

### 8.6 `env!("CARGO_MANIFEST_DIR")` resolves to compile-time path, not sandbox path

`mbedtls-sys/build.rs` uses `env!("CARGO_MANIFEST_DIR")` — a compile-time macro —
to locate the mbedTLS source directory. In Bazel, this path is baked in during
*compilation of the build script*, but the build script *executes* in a different
sandbox directory where the declared `data` files are actually available.

**Resolution:** The `repository_rule` patches `build.rs` after extraction to replace
the compile-time macro with a runtime environment variable lookup:

```rust
// Before (upstream):
let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

// After (patched by cda_repo.bzl):
let manifest_dir = PathBuf::from(
    std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set")
);
```

Bazel sets `CARGO_MANIFEST_DIR` correctly at runtime in the build script's execution
environment, pointing to the sandbox directory where the `data` files reside.

### 8.8 `openssl-sys` resolved hermetisch via vendored `openssl-src`

Der CDA zieht `openssl = "0.10"` und `tokio-openssl = "0.6.5"` als Abhängigkeiten.
`openssl-sys` sucht standardmäßig OpenSSL via `pkg-config` auf dem Host — was den
Bazel-Build nicht-hermetisch und vom Betriebssystem abhängig macht.

Das `Cargo.lock` enthielt bereits `openssl-src 300.5.4+3.5.4` (OpenSSL 3.5.4 als
Rust-Crate), das `openssl-sys` über das Feature `vendored` nutzen kann.

**Lösung:** `crate.annotation()` in `MODULE.bazel` setzt `OPENSSL_VENDORED=1` und
`OPENSSL_STATIC=1` als `build_script_env` für `openssl-sys`. Damit kompiliert
`openssl-src` OpenSSL vollständig aus Quellen — keine Host-Installation erforderlich:

```starlark
crate.annotation(
    crate = "openssl-sys",
    build_script_env = {
        "OPENSSL_STATIC": "1",
        "OPENSSL_VENDORED": "1",
    },
)
```

Die `--action_env=OPENSSL_*` Einträge wurden aus `.bazelrc` entfernt.
Die OpenSSL-Version ist durch `Cargo.lock` auf **3.5.4** gepinnt und reproduzierbar.

### 8.7 Summary of resolved open issues from §6

| §6 item | Status |
|---|---|
| Pinned commit SHA + sha256 | ✅ Implemented (`_CDA_COMMIT`, `_CDA_SHA256` constants) |
| `MODULE.bazel` with correct name/version | ✅ `score_inc_diagnostics` v0.1.0 |
| Public `//src:*` API surface | ✅ `alias` targets in `src/BUILD` |
| `mbedtls-sys` cmake build in sandbox | ✅ Resolved via pre-fetch + build.rs patch |
| Host-system OpenSSL dependency | ✅ Resolved via vendored `openssl-src` (see §8.8) |
| S-CORE Bazel registry | ⏳ Pending (post-HackFest) |
| `reference_integration/known_good.json` entry | ⏳ Pending (post-HackFest) |
| CI workflow for upstream bump | ⏳ Pending (post-HackFest) |
