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

# Library crates: repo directory path -> crate name
_LIB_CRATES = {
    "cda-build": "cda_build",
    "cda-comm-doip": "cda_comm_doip",
    "cda-comm-uds": "cda_comm_uds",
    "cda-core": "cda_core",
    "cda-database": "cda_database",
    "cda-health": "cda_health",
    "cda-interfaces": "cda_interfaces",
    "cda-plugin-security": "cda_plugin_security",
    "cda-sovd": "cda_sovd",
    "cda-sovd-interfaces": "sovd_interfaces",
    "cda-tracing": "cda_tracing",
    "comm-mbedtls/mbedtls-rs": "mbedtls_rs",
}

_LIB_BUILD_TEMPLATE = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//rust:defs.bzl", "rust_library")

rust_library(
    name = "{crate_name}",
    srcs = glob(["src/**/*.rs"]),
    aliases = aliases(),
    crate_name = "{crate_name}",
    deps = all_crate_deps(),
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)
"""

_CDA_MAIN_BUILD = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//cargo:defs.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library")

cargo_build_script(
    name = "build_script",
    srcs = ["build.rs"],
    deps = all_crate_deps(build = True),
    proc_macro_deps = all_crate_deps(build_proc_macro = True),
    edition = "2024",
)

rust_library(
    name = "opensovd_cda_lib",
    srcs = glob(["src/**/*.rs"], exclude = ["src/main.rs"]),
    aliases = aliases(),
    crate_name = "opensovd_cda_lib",
    deps = all_crate_deps() + [":build_script"],
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)

rust_binary(
    name = "opensovd_cda",
    srcs = ["src/main.rs"],
    aliases = aliases(),
    deps = all_crate_deps() + [":opensovd_cda_lib"],
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)
"""

_MBEDTLS_SYS_BUILD = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//cargo:defs.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_library")

# NOTE: build.rs downloads and compiles mbedTLS via cmake — requires network + cmake.
cargo_build_script(
    name = "build_script",
    srcs = ["build.rs"],
    deps = all_crate_deps(build = True),
    proc_macro_deps = all_crate_deps(build_proc_macro = True),
    edition = "2024",
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
    for dir_path, crate_name in _LIB_CRATES.items():
        rctx.file(
            dir_path + "/BUILD.bazel",
            _LIB_BUILD_TEMPLATE.format(crate_name = crate_name),
        )

    rctx.file("cda-main/BUILD.bazel", _CDA_MAIN_BUILD)
    rctx.file("comm-mbedtls/mbedtls-sys/BUILD.bazel", _MBEDTLS_SYS_BUILD)
    rctx.file("comm-mbedtls/BUILD.bazel", "")
    rctx.file("integration-tests/BUILD.bazel", "# not built via Bazel\n")

_cda_repo_rule = repository_rule(
    implementation = _cda_repo_rule_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = ""),
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
    )

cda_ext = module_extension(
    implementation = _cda_ext_impl,
)
