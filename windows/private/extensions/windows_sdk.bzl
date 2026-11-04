"""bzlmod extension for assembling a Windows SDK repository from public NuGet packages."""

load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "update_attrs")

_DEFAULT_ARCHITECTURES = ["x64", "arm64"]
_SYSROOT_DIR = "sysroot"
_COMMON_PACKAGE = "Microsoft.Windows.SDK.CPP"
_ARCH_PACKAGES = {
    "arm64": "Microsoft.Windows.SDK.CPP.arm64",
    "x64": "Microsoft.Windows.SDK.CPP.x64",
}
_CASE_SENSITIVITY_PROBE = ".windows_sdk_case_sensitivity_probe"

def _basename(path):
    path_str = str(path).replace("\\", "/")
    return path_str[path_str.rfind("/") + 1:]

def _normalize_relpath(path):
    return path.replace("\\", "/")

def _keep_only_children(repository_ctx, directory, child_names):
    if not directory.exists or not directory.is_dir:
        return
    allowed = {name: True for name in child_names}
    for entry in directory.readdir():
        if allowed.get(_basename(entry), False):
            continue
        repository_ctx.delete(entry)

def _keep_exposed_windows_sdk_files(repository_ctx, sysroot_dir, include_version, architectures, host_tools):
    _keep_only_children(repository_ctx, repository_ctx.path(sysroot_dir), ["base"] + architectures)
    _keep_only_children(repository_ctx, repository_ctx.path("{}/base".format(sysroot_dir)), ["c"])
    _keep_only_children(repository_ctx, repository_ctx.path("{}/base/c".format(sysroot_dir)), ["Include", "bin"] if host_tools else ["Include"])
    if host_tools:
        _keep_only_children(repository_ctx, repository_ctx.path("{}/base/c/bin".format(sysroot_dir)), [include_version])
        _keep_only_children(repository_ctx, repository_ctx.path("{}/base/c/bin/{}".format(sysroot_dir, include_version)), host_tools)
    _keep_only_children(repository_ctx, repository_ctx.path("{}/base/c/Include".format(sysroot_dir)), [include_version])
    _keep_only_children(
        repository_ctx,
        repository_ctx.path("{}/base/c/Include/{}".format(sysroot_dir, include_version)),
        ["ucrt", "shared", "um", "winrt"],
    )

    seen_architectures = {}
    for arch in architectures:
        if seen_architectures.get(arch, False):
            continue
        seen_architectures[arch] = True
        _keep_only_children(repository_ctx, repository_ctx.path("{}/{}".format(sysroot_dir, arch)), ["c"])
        _keep_only_children(repository_ctx, repository_ctx.path("{}/{}/c".format(sysroot_dir, arch)), ["ucrt", "um"])
        _keep_only_children(repository_ctx, repository_ctx.path("{}/{}/c/ucrt".format(sysroot_dir, arch)), [arch])
        _keep_only_children(repository_ctx, repository_ctx.path("{}/{}/c/um".format(sysroot_dir, arch)), [arch])

def _windows_sdk_package_url(package_name, version):
    pkg_id = package_name.lower()
    pkg_version = version.lower()
    return "https://api.nuget.org/v3-flatcontainer/{id}/{ver}/{id}.{ver}.nupkg".format(
        id = pkg_id,
        ver = pkg_version,
    )

def _integrity_for_package(integrity_by_package, package_name):
    return integrity_by_package.get(package_name, integrity_by_package.get(package_name, ""))

def _download_and_extract_package(repository_ctx, package_name, version, output_dir, integrity):
    urls = [_windows_sdk_package_url(package_name, version)]
    download_kwargs = {
        "url": urls,
        "output": output_dir,
        "type": "nupkg",
        "canonical_id": get_default_canonical_id(repository_ctx, urls),
    }
    if integrity:
        download_kwargs["integrity"] = integrity
    return repository_ctx.download_and_extract(**download_kwargs)

def _list_directory_names(path):
    if not path.exists:
        return []

    names = []
    for entry in path.readdir():
        if entry.is_dir:
            names.append(_basename(entry))
    return sorted(names)

def _select_single_version(versions, field_name):
    if not versions:
        fail("no {} found in extracted Windows SDK NuGet package".format(field_name))
    if len(versions) != 1:
        fail("expected exactly one {}, got {}".format(field_name, versions))
    return versions[0]

def _matches_lowercase_transformation(src_rel, src_pattern):
    if src_pattern.startswith("**/*."):
        return src_rel.endswith(src_pattern[len("**/*"):])
    return src_rel == src_pattern or src_rel.endswith("/" + src_pattern)

def _lowercase_basename(path):
    slash_idx = path.rfind("/")
    if slash_idx == -1:
        return path.lower()
    return path[:slash_idx + 1] + path[slash_idx + 1:].lower()

def _collect_files_recursive(path, files):
    if not path.is_dir:
        files.append(path)
        return

    pending_dirs = [path]
    for _ in range(64):
        if not pending_dirs:
            return
        next_dirs = []
        for current_dir in pending_dirs:
            for entry in current_dir.readdir():
                if entry.is_dir:
                    next_dirs.append(entry)
                else:
                    files.append(entry)
        pending_dirs = next_dirs

    if pending_dirs:
        fail("windows sysroot traversal exceeded depth limit (64)")

def _relative_to_repo_root(repository_ctx, path):
    repo_root = _normalize_relpath(str(repository_ctx.path(".")))
    abs_path = _normalize_relpath(str(path))
    if abs_path.startswith(repo_root + "/"):
        return abs_path[len(repo_root) + 1:]
    return abs_path

def _repository_fs_is_case_sensitive(repository_ctx):
    probe_path = repository_ctx.path(_CASE_SENSITIVITY_PROBE)
    if not probe_path.exists:
        # Keep the probe hidden so generated BUILD globs do not pick it up.
        repository_ctx.file(_CASE_SENSITIVITY_PROBE, "")
    return not repository_ctx.path(_CASE_SENSITIVITY_PROBE.upper()).exists

def _apply_transformations(repository_ctx):
    transformations = repository_ctx.attr.transformations
    if not transformations:
        return

    sysroot = repository_ctx.path(_SYSROOT_DIR)
    if not sysroot.exists:
        return
    if not _repository_fs_is_case_sensitive(repository_ctx):
        # Case-only aliases cannot be materialized on case-insensitive filesystems.
        return

    all_files = []
    _collect_files_recursive(sysroot, all_files)
    all_rel_files = [_relative_to_repo_root(repository_ctx, f) for f in all_files]
    created = {}

    for src_pattern, transform in transformations.items():
        src_pattern = _normalize_relpath(src_pattern)
        if transform != "lowercase":
            transform = _normalize_relpath(transform)

        for src_rel in all_rel_files:
            if transform == "lowercase":
                if not _matches_lowercase_transformation(src_rel, src_pattern):
                    continue
                dst_rel = _lowercase_basename(src_rel)
            else:
                if src_rel != src_pattern and not src_rel.endswith("/" + src_pattern):
                    continue
                dst_rel = src_rel[:len(src_rel) - len(src_pattern)] + transform

            if not dst_rel or dst_rel == src_rel or created.get(dst_rel, False):
                continue
            if repository_ctx.path(dst_rel).exists:
                continue

            repository_ctx.symlink(src_rel, dst_rel)
            created[dst_rel] = True

def _windows_sdk_repository_impl(repository_ctx):
    if not repository_ctx.attr.windows_sdk_version:
        fail("windows_sdk_version must be set")

    requested_architectures = repository_ctx.attr.architectures
    if not requested_architectures:
        fail("no architectures specified")

    integrity_by_package = dict(repository_ctx.attr.windows_sdk_integrity)
    all_requested_packages_have_integrity = True

    common_integrity = _integrity_for_package(integrity_by_package, _COMMON_PACKAGE)
    common_download = _download_and_extract_package(
        repository_ctx,
        _COMMON_PACKAGE,
        repository_ctx.attr.windows_sdk_version,
        "{}/base".format(_SYSROOT_DIR),
        common_integrity,
    )
    if common_integrity == "":
        all_requested_packages_have_integrity = False
        integrity_by_package[_COMMON_PACKAGE] = common_download.integrity

    seen_architectures = {}
    for arch in requested_architectures:
        if seen_architectures.get(arch, False):
            continue
        seen_architectures[arch] = True

        package_name = _ARCH_PACKAGES.get(arch)
        if package_name == None:
            fail("unsupported Windows SDK NuGet architecture {}".format(arch))

        integrity = _integrity_for_package(integrity_by_package, package_name)
        arch_download = _download_and_extract_package(
            repository_ctx,
            package_name,
            repository_ctx.attr.windows_sdk_version,
            "{}/{}".format(_SYSROOT_DIR, arch),
            integrity,
        )
        if integrity == "":
            all_requested_packages_have_integrity = False
            integrity_by_package[package_name] = arch_download.integrity

    include_version = _select_single_version(
        _list_directory_names(repository_ctx.path("{}/base/c/Include".format(_SYSROOT_DIR))),
        "windows_sdk_include_versions",
    )

    _apply_transformations(repository_ctx)
    _keep_exposed_windows_sdk_files(repository_ctx, _SYSROOT_DIR, include_version, requested_architectures, repository_ctx.attr.host_tools)

    repository_ctx.file(
        "versions.bzl",
        content = '''"""Resolved Windows SDK version information.

Generated by windows_support; do not edit.
"""

WINDOWS_SDK_VERSION = {windows_sdk_version}
WINDOWS_SDK_INCLUDE_VERSION = {windows_sdk_include_version}
'''.format(
            windows_sdk_version = repr(repository_ctx.attr.windows_sdk_version),
            windows_sdk_include_version = repr(include_version),
        ),
    )

    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr._build_file,
        substitutions = {
            "__WINSDK_DIR__": _SYSROOT_DIR,
            "__WINSDK_INCLUDE_VERSION__": include_version,
        },
    )

    if all_requested_packages_have_integrity:
        return repository_ctx.repo_metadata(reproducible = True)
    return repository_ctx.repo_metadata(
        reproducible = False,
        attrs_for_reproducibility = update_attrs(
            repository_ctx.attr,
            _WINDOWS_SDK_REPOSITORY_ATTRS.keys(),
            {"windows_sdk_integrity": integrity_by_package},
        ),
    )

_HOST_TOOL_ARCHITECTURES = ["x64", "arm64"]

_WINDOWS_SDK_ATTR = {
    "architectures": attr.string_list(
        default = _DEFAULT_ARCHITECTURES,
        doc = "Architectures of the Windows SDK to download additionally to the base",
    ),
    "windows_sdk_version": attr.string(
        doc = "Windows SDK NuGet package version, e.g. `10.0.26100.7705`",
    ),
    "windows_sdk_integrity": attr.string_dict(
        default = {},
        doc = "(optional) dict from Windows SDK NuGet package ID to integrity string",
    ),
    "transformations": attr.string_dict(
        default = {},
        doc = """
            Dict of source path patterns to transformations applied when run on case-sensitive filesystems.

            Supports exact paths and `**/*.ext` patterns. Use value `lowercase` to create lowercase aliases.

            Example:
            ```
            transformations = {
                "base/c/Include/10.0.26100.0/shared/driverspecs.h": "base/c/Include/10.0.26100.0/shared/DriverSpecs.h",
                "base/c/Include/10.0.26100.0/shared/specstrings.h": "base/c/Include/10.0.26100.0/shared/SpecStrings.h",
                "base/c/Include/10.0.26100.0/um/ole2.h": "base/c/Include/10.0.26100.0/um/Ole2.h",
                "base/c/Include/10.0.26100.0/um/olectl.h": "base/c/Include/10.0.26100.0/um/OleCtl.h",
                "**/*.h": "lowercase",
                "**/*.lib": "lowercase",
                "**/*.Lib": "lowercase",
            }
            ```
        """,
    ),
}

_WINDOWS_SDK_REPOSITORY_ATTRS = _WINDOWS_SDK_ATTR | {
    "host_tools": attr.string_list(
        doc = "Host architectures whose SDK tools (rc.exe, mt.exe) are kept under base/c/bin/<version>/<host>",
    ),
    "_build_file": attr.label(
        allow_single_file = True,
        default = ":windows_sdk.BUILD.bazel",
    ),
}

_windows_sdk_repository = repository_rule(
    implementation = _windows_sdk_repository_impl,
    attrs = _WINDOWS_SDK_REPOSITORY_ATTRS,
)

def _read_configure_tag(module_ctx):
    non_root_tag = None

    for mod in module_ctx.modules:
        configure_tags = [tag for tag in mod.tags.configure]
        if len(configure_tags) > 1:
            fail("Only one windows_sdk.configure(...) tag is supported per module.")

        if not configure_tags:
            continue

        if mod.is_root:
            return configure_tags[0]

        non_root_tag = configure_tags[0]

    if non_root_tag != None:
        return non_root_tag

    fail("Missing windows_sdk.configure(...): set windows_sdk.configure(...) in your MODULE.bazel")

def _read_host_tools(module_ctx):
    hosts = []
    for mod in module_ctx.modules:
        for tag in mod.tags.host_tools:
            for host in tag.hosts:
                if host not in _HOST_TOOL_ARCHITECTURES:
                    fail("windows_sdk.host_tools: unsupported host {}, expected one of {}".format(host, _HOST_TOOL_ARCHITECTURES))
                if host not in hosts:
                    hosts.append(host)
    return sorted(hosts)

def _windows_sdk_extension_impl(module_ctx):
    config = _read_configure_tag(module_ctx)

    repository_name = "windows_sdk"
    _windows_sdk_repository(
        name = repository_name,
        windows_sdk_version = config.windows_sdk_version,
        windows_sdk_integrity = config.windows_sdk_integrity,
        transformations = config.transformations,
        architectures = config.architectures,
        host_tools = _read_host_tools(module_ctx),
    )

    if module_ctx.root_module_has_non_dev_dependency:
        return module_ctx.extension_metadata(
            root_module_direct_deps = [repository_name],
            root_module_direct_dev_deps = [],
        )
    else:
        return module_ctx.extension_metadata(
            root_module_direct_deps = [],
            root_module_direct_dev_deps = [repository_name],
        )

windows_sdk = module_extension(
    implementation = _windows_sdk_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = _WINDOWS_SDK_ATTR),
        "host_tools": tag_class(
            attrs = {
                "hosts": attr.string_list(
                    mandatory = True,
                    doc = "Host architectures (`x64`, `arm64`) whose SDK tools (rc.exe, mt.exe) are kept. Values from all modules are combined.",
                ),
            },
            doc = "Keeps the Windows SDK tools for the given hosts, exposed as `winsdk_bin_<host>`.",
        ),
    },
    doc = "Windows SDK extension backed by public NuGet packages.",
)
