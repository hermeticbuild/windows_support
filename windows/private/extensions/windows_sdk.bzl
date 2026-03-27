"""bzlmod extension for assembling a Windows SDK repository."""

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "update_attrs")
load(":common.bzl", "COMMON_MODULE_EXTENSION_ATTR", "COMMON_REPOSITORY_ATTR", "DEFAULT_ARCHITECTURES", "DEFAULT_VS_CHANNEL_URL", "INSTALLER_MANIFEST_FACTS_KEY", "download_installer_manifest", "ensure_winarchive_tools_binary", "resolve_installer_manifest_from_module_facts", "run_winarchive_tools")

_DEFAULT_SLIM = True
WINSDK_DIR = "Windows Kits"
WINSDK_SPACELESS_DIR = WINSDK_DIR.replace(" ", "")
_CASE_SENSITIVITY_PROBE = ".windows_sdk_case_sensitivity_probe"

def _normalize_relpath(path):
    return path.replace("\\", "/")

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
    repo_root = str(repository_ctx.path("."))
    abs_path = _normalize_relpath(str(path))
    repo_root = _normalize_relpath(repo_root)
    if abs_path.startswith(repo_root + "/"):
        return abs_path[len(repo_root) + 1:]
    return abs_path

def _repository_fs_is_case_sensitive(repository_ctx):
    probe_path = repository_ctx.path(_CASE_SENSITIVITY_PROBE)
    if not probe_path.exists:
        # Keep the probe hidden so generated BUILD globs do not pick it up.
        repository_ctx.file(_CASE_SENSITIVITY_PROBE, "")
    return not repository_ctx.path(_CASE_SENSITIVITY_PROBE.upper()).exists

def _apply_windows_sysroot_transformations(repository_ctx, winarchive_tools_dir):
    transformations = repository_ctx.attr.windows_sysroot_transformations
    if not transformations:
        return

    sysroot = repository_ctx.path(winarchive_tools_dir)
    if not sysroot.exists:
        return
    if not _repository_fs_is_case_sensitive(repository_ctx):
        # print("Skipping windows sysroot transformations on a case-insensitive filesystem")
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

def _create_winsdk_spaceless_alias(repository_ctx, winarchive_tools_dir):
    source_dir = "{}/{}".format(winarchive_tools_dir, WINSDK_DIR)
    alias_dir = "{}/{}".format(winarchive_tools_dir, WINSDK_SPACELESS_DIR)
    if repository_ctx.path(source_dir).exists and not repository_ctx.path(alias_dir).exists:
        repository_ctx.symlink(source_dir, alias_dir)

def _select_windows_sdk_package(installer_manifest, windows_sdk_version):
    suffix = "SDK_" + windows_sdk_version
    for pkg in installer_manifest.get("packages", []):
        pkg_id = pkg.get("id", "")
        if pkg_id.startswith("Win") and pkg_id.endswith(suffix):
            return pkg
    fail("failed to find Windows SDK package for version {}, are you sure this version is available in the resolved/specified Visual Studio installer URL?".format(windows_sdk_version))

def _should_keep_winsdk_path(out_path, has_arch, slim):
    parts = out_path.replace("\\", "/").split("/")
    if len(parts) < 4 or parts[0] != WINSDK_DIR:
        return False

    if parts[2].lower() == "include":
        if not slim:
            return True
        dot_idx = out_path.rfind(".")
        slash_idx = out_path.rfind("/")
        ext = "" if dot_idx == -1 or dot_idx < slash_idx else out_path[dot_idx:].lower()
        return ext in ["", ".h", ".hpp", ".c", ".cpp"]

    if parts[2].lower() != "lib" or len(parts) < 6 or not has_arch.get(parts[5].lower(), False):
        return False
    if not slim:
        return True

    dot_idx = out_path.rfind(".")
    slash_idx = out_path.rfind("/")
    ext = "" if dot_idx == -1 or dot_idx < slash_idx else out_path[dot_idx:].lower()
    return ext in [".lib", ".obj"]

def _record_winsdk_versions(out_path, include_versions_seen, lib_versions_seen):
    parts = out_path.replace("\\", "/").split("/")
    if len(parts) < 4:
        return
    if parts[2].lower() == "include":
        include_versions_seen[parts[3]] = True
    elif parts[2].lower() == "lib":
        lib_versions_seen[parts[3]] = True

def _select_requested_windows_sdk_version(versions, requested_version, field_name):
    if not versions:
        fail("no {} matched requested Windows SDK {}".format(field_name, requested_version))
    if requested_version + ".0" in versions:
        return requested_version + ".0"
    if requested_version in versions:
        return requested_version
    if len(versions) == 1:
        return versions[0]
    fail("unable to choose {} from {} using requested windows_sdk_version {}".format(field_name, versions, requested_version))

def _windows_sdk_repository_impl(repository_ctx):
    winarchive_tools = ensure_winarchive_tools_binary(repository_ctx, "windows_sdk")
    winarchive_tools_dir = "sysroot"

    architectures = repository_ctx.attr.architectures
    if not architectures:
        fail("no architectures specified")
    has_arch = {}
    for arch in architectures:
        has_arch[arch] = True

    installer_manifest = download_installer_manifest(
        repository_ctx,
        repository_ctx.attr.installer_manifest_url,
        repository_ctx.attr.installer_manifest_integrity,
    )
    sdk_package = _select_windows_sdk_package(installer_manifest.decoded_struct, repository_ctx.attr.windows_sdk_version)

    cab_payloads = {}
    all_downloaded_payloads_have_sha256 = True
    pending_msi_downloads = []
    msi_paths = []
    for payload in sdk_package.get("payloads", []):
        file_name = payload.get("fileName", "").replace("\\", "/")
        if file_name.lower().endswith(".cab"):
            cab_payloads[file_name.split("/")[-1].lower()] = payload
            continue
        if not file_name.lower().endswith(".msi"):
            continue

        local_path = "winarchive_tools_msis/{}".format(file_name)
        msi_paths.append(local_path)
        download_kwargs = {
            "url": [payload["url"]],
            "output": local_path,
            "block": False,
        }
        if payload.get("sha256", ""):
            download_kwargs["sha256"] = payload["sha256"]
        else:
            all_downloaded_payloads_have_sha256 = False
        pending_msi_downloads.append(repository_ctx.download(**download_kwargs))

    for token in pending_msi_downloads:
        token.wait()

    include_versions_seen = {}
    lib_versions_seen = {}
    pending_cab_downloads = []
    downloaded_cab_paths = {}
    extraction_specs = []

    for index, msi_path in enumerate(msi_paths):
        msi_info_path = "winarchive_tools_specs/windows_sdk_msi_info_{}.json".format(index)
        run_winarchive_tools(
            repository_ctx,
            winarchive_tools.path,
            ["msi-info", "--input", msi_path, "--out", msi_info_path],
            "winarchive-tools msi-info {}".format(msi_path),
        )
        msi_info = json.decode(repository_ctx.read(msi_info_path), default = None)
        if msi_info == None:
            fail("winarchive-tools msi-info {} returned invalid JSON in {}".format(msi_path, msi_info_path))

        layout_entries = []
        for archive_path in sorted(msi_info.get("file_map", {}).keys()):
            output_path = msi_info["file_map"][archive_path]
            if not _should_keep_winsdk_path(output_path, has_arch, repository_ctx.attr.slim):
                continue
            layout_entries.append({
                "archive_path": archive_path,
                "output_path": output_path,
            })
            _record_winsdk_versions(output_path, include_versions_seen, lib_versions_seen)

        if not layout_entries:
            continue

        layout_path = "winarchive_tools_specs/windows_sdk_{}.json".format(index)
        repository_ctx.file(layout_path, json.encode({"entries": layout_entries}))

        cab_names_seen = {}
        cab_paths = []
        for cab_name in sorted(msi_info.get("cab_files", [])):
            cab_name_lower = cab_name.lower()
            if not cab_name_lower or cab_names_seen.get(cab_name_lower, False):
                continue
            cab_names_seen[cab_name_lower] = True

            cab_payload = cab_payloads.get(cab_name_lower)
            if cab_payload == None:
                fail("failed to locate CAB payload {} in Windows SDK package {}".format(cab_name, sdk_package.get("id", "")))

            cab_file_name = cab_payload.get("fileName", "").replace("\\", "/")
            local_path = "winarchive_tools_downloads/winsdk/{}".format(cab_file_name)
            cab_paths.append(local_path)
            if downloaded_cab_paths.get(local_path, False):
                continue

            download_kwargs = {
                "url": [cab_payload["url"]],
                "output": local_path,
                "block": False,
            }
            if cab_payload.get("sha256", ""):
                download_kwargs["sha256"] = cab_payload["sha256"]
            else:
                all_downloaded_payloads_have_sha256 = False
            pending_cab_downloads.append(repository_ctx.download(**download_kwargs))
            downloaded_cab_paths[local_path] = True

        extraction_specs.append(struct(cab_paths = cab_paths, layout_path = layout_path))

    for token in pending_cab_downloads:
        token.wait()

    for spec in extraction_specs:
        args = ["cab-extract", "--layout", spec.layout_path, "--out-dir", winarchive_tools_dir]
        for cab_path in spec.cab_paths:
            args.extend(["--cab", cab_path])
        run_winarchive_tools(repository_ctx, winarchive_tools.path, args, "winarchive-tools cab-extract")

    _apply_windows_sysroot_transformations(repository_ctx, winarchive_tools_dir)
    _create_winsdk_spaceless_alias(repository_ctx, winarchive_tools_dir)

    include_versions = sorted(include_versions_seen.keys())
    lib_versions = sorted(lib_versions_seen.keys())
    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr._build_file,
        substitutions = {
            "__WINARCHIVE_TOOLS_DIR__": winarchive_tools_dir,
            "__WINSDK_SPACELESS_DIR__": WINSDK_SPACELESS_DIR,
            "__WINSDK_INCLUDE_VERSION__": _select_requested_windows_sdk_version(include_versions, repository_ctx.attr.windows_sdk_version, "windows_sdk_include_versions"),
            "__WINSDK_LIB_VERSION__": _select_requested_windows_sdk_version(lib_versions, repository_ctx.attr.windows_sdk_version, "windows_sdk_lib_versions"),
        },
    )

    if all_downloaded_payloads_have_sha256 and repository_ctx.attr.installer_manifest_integrity != "":
        return repository_ctx.repo_metadata(reproducible = True)
    else:
        reproducibility_overrides = {}
        if installer_manifest.integrity != repository_ctx.attr.installer_manifest_integrity:
            reproducibility_overrides["installer_manifest_integrity"] = installer_manifest.integrity
        return repository_ctx.repo_metadata(
            reproducible = False,
            attrs_for_reproducibility = update_attrs(
                repository_ctx.attr,
                _WINDOWS_SDK_REPOSITORY_ATTRS.keys(),
                reproducibility_overrides,
            ),
        )

_WINDOWS_SDK_ATTR = {
    "windows_sdk_version": attr.string(
        doc = "Windows SDK version requested from the installer manifest.",
    ),
    "slim": attr.bool(
        default = _DEFAULT_SLIM,
        doc = "Whether to keep only the slim Windows SDK subset.",
    ),
    "windows_sysroot_transformations": attr.string_dict(
        default = {},
        doc = "Map of source path patterns to transformations. Supports exact paths and `**/*.ext` patterns. Use value `lowercase` to create lowercase aliases. On case-insensitive filesystems these transformations are skipped because case-only aliases cannot be materialized.",
    ),
}

_WINDOWS_SDK_REPOSITORY_ATTRS = COMMON_REPOSITORY_ATTR | _WINDOWS_SDK_ATTR | {
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
        slim = _DEFAULT_SLIM,
        windows_sysroot_transformations = {},
        winarchive_tools_urls = {},
        winarchive_tools_integrity = {},
        architectures = DEFAULT_ARCHITECTURES,
        visual_studio_channel_url = DEFAULT_VS_CHANNEL_URL,
        visual_studio_installer_manifest_url = "",
        visual_studio_installer_manifest_integrity = "",
    )

def _windows_sdk_extension_impl(module_ctx):
    config = _read_configure_tag(module_ctx)

    installer_manifest = resolve_installer_manifest_from_module_facts(
        module_ctx,
        config.visual_studio_channel_url,
        config.visual_studio_installer_manifest_url,
        config.visual_studio_installer_manifest_integrity,
        INSTALLER_MANIFEST_FACTS_KEY,
    )

    _windows_sdk_repository(
        name = "windows_sdk",
        winarchive_tools_urls = config.winarchive_tools_urls,
        winarchive_tools_integrity = config.winarchive_tools_integrity,
        architectures = config.architectures,
        windows_sdk_version = config.windows_sdk_version,
        slim = config.slim,
        windows_sysroot_transformations = config.windows_sysroot_transformations,
        installer_manifest_url = installer_manifest["url"],
        installer_manifest_integrity = installer_manifest["integrity"],
    )

    return module_ctx.extension_metadata(
        facts = {INSTALLER_MANIFEST_FACTS_KEY: installer_manifest},
        root_module_direct_deps = ["windows_sdk"],
        root_module_direct_dev_deps = [],
    )

windows_sdk = module_extension(
    implementation = _windows_sdk_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = COMMON_MODULE_EXTENSION_ATTR | _WINDOWS_SDK_ATTR),
    },
    doc = "Windows SDK extension.",
)
