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
_VFSOVERLAY_PATH = "vfsoverlay.yaml"

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

def _keep_exposed_windows_sdk_files(repository_ctx, sysroot_dir, include_version, architectures):
    _keep_only_children(repository_ctx, repository_ctx.path(sysroot_dir), ["base"] + architectures)
    _keep_only_children(repository_ctx, repository_ctx.path("{}/base".format(sysroot_dir)), ["c"])
    _keep_only_children(repository_ctx, repository_ctx.path("{}/base/c".format(sysroot_dir)), ["Include"])
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
    return "https://www.nuget.org/api/v2/package/{}/{}".format(package_name, version.lower())

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

def _yaml_quote(value):
    return "\"{}\"".format(value.replace("\\", "\\\\").replace("\"", "\\\""))

def _fail_on_vfsoverlay_casefold_collisions(files):
    collision_by_folded_path = {}
    for rel_path in sorted(files):
        folded_rel_path = rel_path.lower()
        collision = collision_by_folded_path.get(folded_rel_path)
        if collision != None and collision != rel_path:
            fail(
                "cannot generate a case-insensitive Windows SDK vfsoverlay because these published paths only differ by case: '{}' and '{}'".format(
                    collision,
                    rel_path,
                ),
            )
        collision_by_folded_path[folded_rel_path] = rel_path

def _write_vfsoverlay(repository_ctx):
    sysroot = repository_ctx.path(_SYSROOT_DIR)
    if not sysroot.exists:
        repository_ctx.file(
            _VFSOVERLAY_PATH,
            "\n".join([
                "version: 0",
                "case-sensitive: false",
                "overlay-relative: true",
                "root-relative: overlay-dir",
                "roots: []",
                "",
            ]),
        )
        return

    all_files = []
    _collect_files_recursive(sysroot, all_files)
    all_rel_files = sorted([_relative_to_repo_root(repository_ctx, f) for f in all_files])
    _fail_on_vfsoverlay_casefold_collisions(all_rel_files)

    lines = [
        "version: 0",
        "case-sensitive: false",
        "overlay-relative: true",
        "root-relative: overlay-dir",
        "roots:",
    ]
    for rel_path in all_rel_files:
        lines.append("  - type: file")
        lines.append("    name: {}".format(_yaml_quote(rel_path)))
        lines.append("    external-contents: {}".format(_yaml_quote(rel_path)))
    lines.append("")
    repository_ctx.file(_VFSOVERLAY_PATH, "\n".join(lines))

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

    _keep_exposed_windows_sdk_files(repository_ctx, _SYSROOT_DIR, include_version, requested_architectures)
    _write_vfsoverlay(repository_ctx)

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
}

_WINDOWS_SDK_REPOSITORY_ATTRS = _WINDOWS_SDK_ATTR | {
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
    root_tags = []
    non_root_tags = []
    for mod in module_ctx.modules:
        if mod.is_root:
            root_tags.extend(mod.tags.configure)
        else:
            non_root_tags.extend(mod.tags.configure)

    if len(root_tags) > 1:
        fail("Only one windows_sdk.configure(...) tag is supported in the root module.")
    if root_tags:
        return root_tags[0]
    if non_root_tags:
        return non_root_tags[0]
    return struct(
        windows_sdk_version = "",
        windows_sdk_integrity = {},
        architectures = _DEFAULT_ARCHITECTURES,
    )

def _windows_sdk_extension_impl(module_ctx):
    config = _read_configure_tag(module_ctx)

    repository_name = "windows_sdk"
    _windows_sdk_repository(
        name = repository_name,
        windows_sdk_version = config.windows_sdk_version,
        windows_sdk_integrity = config.windows_sdk_integrity,
        architectures = config.architectures,
    )

    return module_ctx.extension_metadata(
        root_module_direct_deps = [repository_name],
        root_module_direct_dev_deps = [],
    )

windows_sdk = module_extension(
    implementation = _windows_sdk_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = _WINDOWS_SDK_ATTR),
    },
    doc = "Windows SDK extension backed by public NuGet packages.",
)
