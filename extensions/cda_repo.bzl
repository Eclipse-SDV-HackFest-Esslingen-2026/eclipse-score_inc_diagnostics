# *******************************************************************************
# Copyright (c) 2025 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0
# *******************************************************************************

"""Module extension: fetches the Classic Diagnostic Adapter at a pinned commit.

The external source is never modified — all Bazel knowledge lives in this file.
"""

# Helper to generate a rust_library BUILD file with explicit workspace deps.
def _lib_build(crate_name, workspace_deps = []):
    if workspace_deps:
        formatted = ",\n        ".join(['"' + d + '"' for d in workspace_deps])
        deps = "all_crate_deps() + [\n        " + formatted + "\n    ]"
    else:
        deps = "all_crate_deps()"

    return (
        'load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")\n' +
        'load("@rules_rust//rust:defs.bzl", "rust_library")\n' +
        "\n" +
        "rust_library(\n" +
        '    name = "' + crate_name + '",\n' +
        '    srcs = glob(["src/**/*.rs"]),\n' +
        "    aliases = aliases(),\n" +
        '    crate_name = "' + crate_name + '",\n' +
        "    deps = " + deps + ",\n" +
        "    proc_macro_deps = all_crate_deps(proc_macro = True),\n" +
        '    edition = "2024",\n' +
        '    visibility = ["//visibility:public"],\n' +
        ")\n"
    )

# Per-crate BUILD content with explicit workspace-member deps.
# (all_crate_deps() only returns external registry crates, not workspace members)
_LIB_BUILDS = {
    "cda-build": _lib_build("cda_build"),
    "cda-interfaces": _lib_build("cda_interfaces"),
    "cda-tracing": _lib_build("cda_tracing", [
        "//cda-build:cda_build",
    ]),
    "cda-database": _lib_build("cda_database", [
        "//cda-build:cda_build",
        "//cda-interfaces:cda_interfaces",
    ]),
    "cda-plugin-security": _lib_build("cda_plugin_security", [
        "//cda-database:cda_database",
        "//cda-interfaces:cda_interfaces",
        "//cda-sovd-interfaces:sovd_interfaces",
    ]),
    "cda-sovd-interfaces": _lib_build("sovd_interfaces", [
        "//cda-interfaces:cda_interfaces",
    ]),
    "cda-comm-uds": _lib_build("cda_comm_uds", [
        "//cda-interfaces:cda_interfaces",
    ]),
    "cda-comm-doip": _lib_build("cda_comm_doip", [
        "//cda-interfaces:cda_interfaces",
        "//comm-mbedtls/mbedtls-rs:mbedtls_rs",
        "//comm-mbedtls/mbedtls-sys:mbedtls_sys",
    ]),
    "cda-sovd": _lib_build("cda_sovd", [
        "//cda-build:cda_build",
        "//cda-interfaces:cda_interfaces",
        "//cda-plugin-security:cda_plugin_security",
        "//cda-sovd-interfaces:sovd_interfaces",
        "//cda-tracing:cda_tracing",
    ]),
    "cda-core": _lib_build("cda_core", [
        "//cda-database:cda_database",
        "//cda-interfaces:cda_interfaces",
        "//cda-plugin-security:cda_plugin_security",
    ]),
    "cda-health": _lib_build("cda_health", [
        "//cda-interfaces:cda_interfaces",
        "//cda-sovd:cda_sovd",
    ]),
    "comm-mbedtls/mbedtls-rs": _lib_build("mbedtls_rs", [
        "//comm-mbedtls/mbedtls-sys:mbedtls_sys",
    ]),
}


_CDA_MAIN_BUILD = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//cargo:defs.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library")

# The upstream build.rs is replaced by a sandbox-safe version (see cda_repo.bzl).
cargo_build_script(
    name = "build_script",
    srcs = ["build.rs"],
    deps = all_crate_deps(build = True),
    proc_macro_deps = all_crate_deps(build_proc_macro = True),
    edition = "2024",
)

# Workspace-member crates are not returned by all_crate_deps() — list explicitly.
_WORKSPACE_DEPS = [
    "//cda-comm-doip:cda_comm_doip",
    "//cda-comm-uds:cda_comm_uds",
    "//cda-core:cda_core",
    "//cda-database:cda_database",
    "//cda-health:cda_health",
    "//cda-interfaces:cda_interfaces",
    "//cda-plugin-security:cda_plugin_security",
    "//cda-sovd:cda_sovd",
    "//cda-tracing:cda_tracing",
]

rust_library(
    name = "opensovd_cda_lib",
    srcs = glob(["src/**/*.rs"], exclude = ["src/main.rs"]),
    aliases = aliases(),
    crate_name = "opensovd_cda_lib",
    deps = all_crate_deps() + _WORKSPACE_DEPS + [":build_script"],
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)

rust_binary(
    name = "opensovd_cda",
    srcs = ["src/main.rs"],
    aliases = aliases(),
    deps = all_crate_deps() + _WORKSPACE_DEPS + [":opensovd_cda_lib", ":build_script"],
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)
"""

_MBEDTLS_SYS_BUILD = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//cargo:defs.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_library")

# mbedtls-4.0.0 was pre-fetched by the repository_rule.
# Declare it (and supporting files) as data so Bazel puts them in the sandbox.
# MBEDTLS_DIR points to the mbedtls-4.0.0 directory via $(execpath)/..:
#   $(execpath mbedtls-4.0.0/CMakeLists.txt) -> .../mbedtls-4.0.0/CMakeLists.txt
#   /..(parent) -> .../mbedtls-4.0.0/
cargo_build_script(
    name = "build_script",
    srcs = ["build.rs"],
    deps = all_crate_deps(build = True),
    proc_macro_deps = all_crate_deps(build_proc_macro = True),
    edition = "2024",
    data = glob([
        "mbedtls-4.0.0/**",
        "patches/**",
        "csrc/**",
        "wrapper.h",
    ]),
    build_script_env = {
        "MBEDTLS_SKIP_PATCH": "1",
    },
)

rust_library(
    name = "mbedtls_sys",
    srcs = glob(["src/**/*.rs"]),
    aliases = aliases(),
    crate_name = "mbedtls_sys",
    deps = all_crate_deps() + [":build_script"],
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)
"""

def _cda_repo_rule_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.url,
        sha256 = rctx.attr.sha256,
        stripPrefix = rctx.attr.strip_prefix,
    )

    # Root BUILD — expose Cargo manifests for crate_universe
    rctx.file("BUILD.bazel", """\
exports_files([
    "Cargo.toml",
    "Cargo.lock",
])
""")

    # Inject synthetic BUILD files for each library crate
    for dir_path, build_content in _LIB_BUILDS.items():
        rctx.file(dir_path + "/BUILD.bazel", build_content)

    rctx.file("cda-main/BUILD.bazel", _CDA_MAIN_BUILD)
    rctx.file("comm-mbedtls/mbedtls-sys/BUILD.bazel", _MBEDTLS_SYS_BUILD)
    rctx.file("comm-mbedtls/BUILD.bazel", "")
    rctx.file("integration-tests/BUILD.bazel", "# not built via Bazel\n")

    # Pre-fetch mbedTLS 4.0.0 into the location the build.rs expects.
    # Without this, build.rs would try to download it at compile time (no network in sandbox).
    rctx.download_and_extract(
        url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.0.0/mbedtls-4.0.0.tar.bz2",
        sha256 = "2f3a47f7b3a541ddef450e4867eeecb7ce2ef7776093f3a11d6d43ead6bf2827",
        output = "comm-mbedtls/mbedtls-sys/mbedtls-4.0.0",
        stripPrefix = "mbedtls-4.0.0",
    )

    # Patch mbedtls-sys/build.rs: replace the compile-time env!("CARGO_MANIFEST_DIR")
    # with a runtime std::env::var() call. The compile-time macro bakes in a path
    # that differs from the actual sandbox path at build-script execution time.
    original_build_rs = rctx.read("comm-mbedtls/mbedtls-sys/build.rs")
    patched_build_rs = original_build_rs.replace(
        'PathBuf::from(env!("CARGO_MANIFEST_DIR"))',
        'PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set"))',
    )
    rctx.file("comm-mbedtls/mbedtls-sys/build.rs", patched_build_rs)

    # Replace build.rs with a Bazel-sandbox-compatible version that embeds
    # the pinned commit SHA and date as constants instead of calling git.
    rctx.file("cda-main/build.rs", """\
// SPDX-License-Identifier: Apache-2.0
// Bazel-sandbox replacement generated by extensions/cda_repo.bzl.
// The upstream build.rs calls `git` which is unavailable in the sandbox.
// This version embeds the pinned commit SHA and date as compile-time constants.
fn main() {{
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-env=BUILD_DATE={build_date}");
    println!("cargo:rustc-env=GIT_COMMIT_HASH={commit_hash}");
}}
""".format(
        build_date = rctx.attr.build_date,
        commit_hash = rctx.attr.commit_hash,
    ))

_cda_repo_rule = repository_rule(
    implementation = _cda_repo_rule_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = ""),
        "commit_hash": attr.string(default = "unknown"),
        "build_date": attr.string(default = "1970-01-01T00:00:00Z"),
    },
)

# Pinned commit: ce3a566c52898fd7f6c1bd4076ca26544f292b42
# Message: ci: pin protoc version to 34.1 in CI workflows (2026-04-28)
_CDA_COMMIT = "ce3a566c52898fd7f6c1bd4076ca26544f292b42"
_CDA_SHA256 = "1c830c4cc54ff46dc392b33102015e9825133585882252b3edec497e84979066"

def _cda_ext_impl(module_ctx):
    _cda_repo_rule(
        name = "classic_diagnostic_adapter",
        url = "https://github.com/eclipse-opensovd/classic-diagnostic-adapter/archive/{}.tar.gz".format(_CDA_COMMIT),
        sha256 = _CDA_SHA256,
        strip_prefix = "classic-diagnostic-adapter-{}".format(_CDA_COMMIT),
        commit_hash = _CDA_COMMIT[:7],
        build_date = "2026-04-28T00:00:00Z",
    )

cda_ext = module_extension(
    implementation = _cda_ext_impl,
)
