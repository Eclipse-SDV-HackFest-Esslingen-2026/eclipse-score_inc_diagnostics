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

"""Module extension to fetch the Classic Diagnostic Adapter repository."""

# Standard library crates: directory path -> crate name (underscored)
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

# NOTE: mbedtls-sys build.rs downloads and compiles mbedTLS 4.0.0 via cmake.
# This cargo_build_script may require network access and cmake/cc toolchain
# configuration to work in Bazel's sandbox.
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

    # Root BUILD file - export Cargo manifest files
    rctx.file("BUILD.bazel", """\
exports_files([
    "Cargo.toml",
    "Cargo.lock",
])
""")

    # Standard library crates
    for dir_path, crate_name in _LIB_CRATES.items():
        rctx.file(
            dir_path + "/BUILD.bazel",
            _LIB_BUILD_TEMPLATE.format(crate_name = crate_name),
        )

    # cda-main: binary + library with build.rs
    rctx.file("cda-main/BUILD.bazel", _CDA_MAIN_BUILD)

    # mbedtls-sys: library with heavy build.rs (cmake + cc)
    rctx.file("comm-mbedtls/mbedtls-sys/BUILD.bazel", _MBEDTLS_SYS_BUILD)

    # integration-tests: not built via Bazel
    rctx.file("integration-tests/BUILD.bazel", "# Integration tests - not built via Bazel\n")

    # Parent package for nested crates
    rctx.file("comm-mbedtls/BUILD.bazel", "")

_cda_repo_rule = repository_rule(
    implementation = _cda_repo_rule_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = ""),
    },
)

def _cda_ext_impl(module_ctx):
    _cda_repo_rule(
        name = "classic_diagnostic_adapter",
        url = "https://github.com/eclipse-opensovd/classic-diagnostic-adapter/archive/refs/heads/main.tar.gz",
        strip_prefix = "classic-diagnostic-adapter-main",
    )

cda_ext = module_extension(
    implementation = _cda_ext_impl,
)
