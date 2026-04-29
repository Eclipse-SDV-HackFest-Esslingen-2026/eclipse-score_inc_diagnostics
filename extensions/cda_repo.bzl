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

# Directory paths of workspace members that get a standard rust_library BUILD file.
# Keep in sync with the manifests list in MODULE.bazel.
# cda-main, comm-mbedtls/mbedtls-sys, and integration-tests are handled separately.
_LIB_DIRS = [
    "cda-build",
    "cda-comm-doip",
    "cda-comm-uds",
    "cda-core",
    "cda-database",
    "cda-health",
    "cda-interfaces",
    "cda-plugin-security",
    "cda-sovd",
    "cda-sovd-interfaces",
    "cda-tracing",
    "comm-mbedtls/mbedtls-rs",
]

# ---------------------------------------------------------------------------
# Cargo.toml / Cargo.lock parsing helpers
# ---------------------------------------------------------------------------

def _is_new_toml_section(line):
    """Return True if line opens a new TOML section (table or array-of-tables)."""
    s = line.strip()
    return s.startswith("[") and "]" in s and not s.startswith("#")

def _is_toml_section(line, name):
    """Return True if line opens the TOML section [name]."""
    return line.strip() == "[" + name + "]"

def _toml_package_name(content):
    """Return the value of `name` from the [package] section of a Cargo.toml."""
    in_pkg = False
    for line in content.split("\n"):
        s = line.strip()
        if _is_toml_section(line, "package"):
            in_pkg = True
        elif _is_new_toml_section(line):
            in_pkg = False
        elif in_pkg and s.startswith("name") and "=" in s:
            return s.partition("=")[2].strip().strip('"').strip("'")
    return None

def _toml_workspace_path_map(content):
    """Parse [workspace.dependencies] and return {dep_name: dir_path} for path-based entries.

    Handles lines such as:
      cda-interfaces = { path = "cda-interfaces" }
      sovd-interfaces = { path = "cda-sovd-interfaces" }
    External crates (no `path =`) are ignored.
    """
    in_section = False
    result = {}
    for line in content.split("\n"):
        s = line.strip()
        if _is_toml_section(line, "workspace.dependencies"):
            in_section = True
        elif _is_new_toml_section(line):
            in_section = False
        elif in_section and 'path = "' in s and not s.startswith("#"):
            dep_name = s.split("=")[0].strip()
            start = s.find('path = "') + len('path = "')
            end = s.find('"', start)
            if start > 0 and end > start:
                result[dep_name] = s[start:end]
    return result

def _toml_workspace_dep_names(content):
    """Return dep names from [dependencies] that carry `workspace = true`.

    Optional deps (feature-gated) are excluded — they are only needed when a
    specific Cargo feature is enabled and cannot be added unconditionally.
    Stops at the next TOML section header, so [dev-dependencies] and
    [build-dependencies] entries are excluded.
    """
    in_section = False
    names = []
    seen = {}
    for line in content.split("\n"):
        s = line.strip()
        if _is_toml_section(line, "dependencies"):
            in_section = True
        elif _is_new_toml_section(line):
            in_section = False
        elif in_section and "workspace" in s and "true" in s and not s.startswith("#"):
            if "optional" in s:
                continue
            dep_name = s.split("=")[0].strip()
            if dep_name and dep_name not in seen:
                names.append(dep_name)
                seen[dep_name] = True
    return names

def _lock_crate_version(content, crate_name):
    """Return the first resolved version of `crate_name` found in Cargo.lock."""
    matched_name = False
    for line in content.split("\n"):
        s = line.strip()
        if s == "[[package]]":
            matched_name = False
        elif s.startswith("name = "):
            matched_name = (s[len("name = "):].strip().strip('"') == crate_name)
        elif matched_name and s.startswith("version = "):
            return s[len("version = "):].strip().strip('"')
    return None

def _format_list(items):
    """Format a list of strings for embedding in a generated BUILD file."""
    if not items:
        return "[]"
    inner = ",\n        ".join(['"' + item + '"' for item in items])
    return "[\n        " + inner + ",\n    ]"

# ---------------------------------------------------------------------------
# BUILD file templates
# ---------------------------------------------------------------------------

_LIB_BUILD_TEMPLATE = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//rust:defs.bzl", "rust_library")

rust_library(
    name = "{crate_name}",
    srcs = glob(["src/**/*.rs"]),
    aliases = aliases(),
    crate_name = "{crate_name}",
    deps = all_crate_deps() + {extra_deps},
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)
"""

# build.rs in cda-main uses `chrono` which crate_universe omits from the
# resolved build-deps for workspace members; it is added explicitly here.
# SOURCE_DATE_EPOCH / SOURCE_GIT_SHA are provided so build.rs does not
# attempt git calls inside Bazel's sandbox.
_CDA_MAIN_BUILD_TEMPLATE = """\
load("@cda_crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rust//cargo:defs.bzl", "cargo_build_script")
load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library")

cargo_build_script(
    name = "build_script",
    srcs = ["build.rs"],
    deps = all_crate_deps(build = True) + ["@cda_crates//:chrono-{chrono_version}"],
    proc_macro_deps = all_crate_deps(build_proc_macro = True),
    edition = "2024",
    build_script_env = {{
        "SOURCE_DATE_EPOCH": "0",
        "SOURCE_GIT_SHA": "unknown",
    }},
)

rust_library(
    name = "opensovd_cda_lib",
    srcs = glob(["src/**/*.rs"], exclude = ["src/main.rs"]),
    aliases = aliases(),
    crate_name = "opensovd_cda_lib",
    deps = all_crate_deps() + [":build_script"] + {workspace_deps},
    proc_macro_deps = all_crate_deps(proc_macro = True),
    edition = "2024",
    visibility = ["//visibility:public"],
)

rust_binary(
    name = "opensovd_cda",
    srcs = ["src/main.rs"],
    aliases = aliases(),
    deps = all_crate_deps() + [":opensovd_cda_lib", ":build_script"] + {workspace_deps},
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

# ---------------------------------------------------------------------------
# Repository rule implementation
# ---------------------------------------------------------------------------

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

    # Parse the workspace root Cargo.toml once to build:
    #   dep_to_dir:   {dep_name -> dir_path}  from [workspace.dependencies]
    #   dir_to_crate: {dir_path -> crate_name} derived from each member's [package] name
    root_toml = rctx.read("Cargo.toml")
    lockfile = rctx.read("Cargo.lock")

    dep_to_dir = _toml_workspace_path_map(root_toml)

    dir_to_crate = {}
    for dep_name, dir_path in dep_to_dir.items():
        pkg_name = _toml_package_name(rctx.read(dir_path + "/Cargo.toml"))
        if pkg_name:
            dir_to_crate[dir_path] = pkg_name.replace("-", "_")

    # Set of dirs that have a rust_library BUILD — the only ones we emit dep labels for.
    # Feature-gated workspace crates (e.g. mbedtls-sys under the `mbedtls` feature) are
    # intentionally excluded to avoid unconditionally pulling in expensive or
    # network-dependent build scripts.
    lib_dirs_set = {d: True for d in _LIB_DIRS}

    # Generate BUILD files for standard library crates.
    # Intra-workspace deps are derived from each crate's [dependencies] section.
    for dir_path in _LIB_DIRS:
        crate_name = dir_to_crate.get(dir_path)
        if not crate_name:
            # Fallback: derive from the directory basename
            crate_name = dir_path.split("/")[-1].replace("-", "_")

        ws_dep_names = _toml_workspace_dep_names(rctx.read(dir_path + "/Cargo.toml"))
        extra_labels = []
        for dep_name in ws_dep_names:
            dep_dir = dep_to_dir.get(dep_name)
            if dep_dir and dep_dir in dir_to_crate and dep_dir in lib_dirs_set:
                extra_labels.append(
                    "//" + dep_dir + ":" + dir_to_crate[dep_dir],
                )

        rctx.file(
            dir_path + "/BUILD.bazel",
            _LIB_BUILD_TEMPLATE.format(
                crate_name = crate_name,
                extra_deps = _format_list(extra_labels),
            ),
        )

    # cda-main: rust_library + rust_binary with a build script.
    # Workspace deps are derived from cda-main's [dependencies] section.
    main_ws_dep_names = _toml_workspace_dep_names(rctx.read("cda-main/Cargo.toml"))
    main_ws_labels = []
    for dep_name in main_ws_dep_names:
        dep_dir = dep_to_dir.get(dep_name)
        if dep_dir and dep_dir in dir_to_crate and dep_dir in lib_dirs_set:
            main_ws_labels.append(
                "//" + dep_dir + ":" + dir_to_crate[dep_dir],
            )

    chrono_version = _lock_crate_version(lockfile, "chrono")
    rctx.file(
        "cda-main/BUILD.bazel",
        _CDA_MAIN_BUILD_TEMPLATE.format(
            chrono_version = chrono_version,
            workspace_deps = _format_list(main_ws_labels),
        ),
    )

    # mbedtls-sys: library with a heavy build.rs (cmake + cc)
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
