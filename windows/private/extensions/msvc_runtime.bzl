"""bzlmod extension for assembling an MSVC runtime repository."""

load(":common.bzl", "COMMON_MODULE_EXTENSION_ATTR", "COMMON_REPOSITORY_ATTR", "DEFAULT_ARCHITECTURES", "DEFAULT_VS_CHANNEL_URL", "ensure_winarchive_tools_binary", "resolve_installer_manifest_from_module_facts", "run_winarchive_tools")

_MSVC_RUNTIME_FACTS_KEY = "msvc_runtime_v1"
_MSVC_RUNTIME_FACTS_SCHEMA_VERSION = 2

_ARCH_TO_MSVC_COMPONENT = {
    "arm": "Microsoft.VisualStudio.Component.VC.Tools.ARM",
    "arm64": "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
    "arm64ec": "Microsoft.VisualStudio.Component.VC.Tools.ARM64EC",
    "x64": "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "x86": "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
}

def _check_msvc_license_requirements(module_ctx):
    approval = module_ctx.getenv("BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA")
    if approval != 1 and approval != "1" and approval != "yes" and approval != "y" and approval != "true":
        fail("""
            MSVC license check failed, to resolve that failure please:
              1. ensure that your machine is legally allowed to use the MSVC runtime
              2. set the environment variable `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA` to `1`, e.g. via `--repo_env=BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA=1`

            See https://visualstudio.microsoft.com/license-terms for more information.
        """)

def _collect_vctools_packages(installer_manifest, architectures):
    packages_by_id = {}
    for pkg in installer_manifest.get("packages", []):
        packages_by_id[pkg.get("id", "")] = pkg

    pending = []
    for arch in architectures:
        component = _ARCH_TO_MSVC_COMPONENT.get(arch)
        if component == None:
            fail("unknown architecture {}, do not know the correct MSVC tools package".format(arch))
        if component not in packages_by_id:
            fail("failed to find Visual Studio package {} in installer manifest".format(component))
        pending.append(component)

    selected = {}
    seen = {}
    frontier = pending
    for _ in range(len(packages_by_id)):
        if not frontier:
            break
        next_frontier = []
        for package_id in frontier:
            if seen.get(package_id, False):
                continue
            seen[package_id] = True
            pkg = packages_by_id.get(package_id)
            if pkg == None:
                continue
            selected[package_id] = pkg
            dependencies = pkg.get("dependencies", {})
            if type(dependencies) == "list":
                next_frontier.extend(sorted(dependencies))
            else:
                next_frontier.extend(sorted(dependencies.keys()))
        frontier = next_frontier

    vctools_packages = {}
    for package_id in sorted(selected.keys()):
        pkg = selected[package_id]
        if pkg.get("type", "").lower() != "vsix":
            continue
        payloads = pkg.get("payloads", [])
        if not payloads:
            fail("package {} has no payloads".format(package_id))
        vctools_packages[package_id] = pkg

    return vctools_packages

def _vctools_output_info(archive_path, has_arch):
    if not archive_path.startswith("Contents/VC/Tools/MSVC/"):
        return None

    parts = archive_path.split("/")
    if len(parts) < 6 or parts[5].lower() not in ["include", "lib"]:
        return None
    if parts[5].lower() == "lib" and (len(parts) < 7 or not has_arch.get(parts[6].lower(), False)):
        return None

    return struct(
        output_path = archive_path[len("Contents/"):],
        version = parts[4],
    )

def _msvc_runtime_repository_impl(repository_ctx):
    winarchive_tools = ensure_winarchive_tools_binary(repository_ctx, "msvc_runtime")
    winarchive_tools_dir = "sysroot"

    architectures = repository_ctx.attr.architectures
    if not architectures:
        fail("no architectures specified")
    has_arch = {}
    for arch in architectures:
        has_arch[arch] = True

    installer_manifest_json = json.decode(repository_ctx.attr.installer_manifest_json, default = None)
    if installer_manifest_json == None:
        fail("failed to decode `@msvc_runtime` `installer_manifest_json`")
    packages = _collect_vctools_packages(installer_manifest_json, repository_ctx.attr.architectures)

    # Download/extract VSIX packages to look for the MSVC runtime pieces

    all_downloaded_payloads_have_sha256 = True
    pending_vsix_downloads = []
    vsix_paths = []
    for package_id in packages.keys():
        pkg = packages[package_id]
        payloads = pkg.get("payloads", [])
        payload = payloads[0]
        file_name = payload.get("fileName", "").replace("\\", "/")
        local_path = "winarchive_tools_downloads/vctools/{}/{}".format(package_id.replace("\\", "_").replace("/", "_").replace(":", "_"), file_name)
        vsix_paths.append(local_path)

        download_kwargs = {
            "url": [payload["url"]],
            "output": local_path,
            "block": False,
        }
        if payload.get("sha256", ""):
            download_kwargs["sha256"] = payload["sha256"]
        else:
            all_downloaded_payloads_have_sha256 = False
        pending_vsix_downloads.append(repository_ctx.download(**download_kwargs))

    for token in pending_vsix_downloads:
        token.wait()

    msvc_versions_seen = {}
    for index, vsix_path in enumerate(vsix_paths):
        listing_path = "winarchive_tools_specs/msvc_runtime_listing_{}.json".format(index)
        run_winarchive_tools(
            repository_ctx,
            winarchive_tools.path,
            ["zip-list", "--input", vsix_path, "--out", listing_path],
            "winarchive-tools zip-list {}".format(vsix_path),
        )
        listing = json.decode(repository_ctx.read(listing_path), default = None)
        if listing == None:
            fail("winarchive-tools zip-list {} returned invalid JSON in {}".format(vsix_path, listing_path))

        layout_entries = []
        for archive_path in listing.get("entries", []):
            output_info = _vctools_output_info(archive_path, has_arch)
            if output_info == None:
                continue
            layout_entries.append({
                "archive_path": archive_path,
                "output_path": output_info.output_path,
            })
            msvc_versions_seen[output_info.version] = True

        if not layout_entries:
            continue

        layout_path = "winarchive_tools_specs/msvc_runtime_{}.json".format(index)
        repository_ctx.file(layout_path, json.encode({"entries": layout_entries}))
        run_winarchive_tools(
            repository_ctx,
            winarchive_tools.path,
            ["zip-extract", "--input", vsix_path, "--layout", layout_path, "--out-dir", winarchive_tools_dir],
            "winarchive-tools zip-extract {}".format(vsix_path),
        )

    msvc_versions = sorted(msvc_versions_seen.keys())
    if len(msvc_versions) != 1:
        fail("expected exactly one MSVC version, got {}".format(msvc_versions))
    if repository_ctx.attr.msvc_version and repository_ctx.attr.msvc_version != msvc_versions[0]:
        fail("resolved MSVC version {} does not match requested msvc_version {}".format(msvc_versions[0], repository_ctx.attr.msvc_version))

    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr._build_file,
        substitutions = {
            "__WINARCHIVE_TOOLS_DIR__": winarchive_tools_dir,
            "__MSVC_VERSION__": msvc_versions[0],
        },
    )

    return repository_ctx.repo_metadata(reproducible = all_downloaded_payloads_have_sha256)

_MSVC_RUNTIME_ATTR = {
    "msvc_version": attr.string(
        default = "",
        doc = "Optional expected MSVC tools version. If set, extraction fails when the resolved payloads contain a different version.",
    ),
}

_msvc_runtime_repository = repository_rule(
    implementation = _msvc_runtime_repository_impl,
    attrs = COMMON_REPOSITORY_ATTR | _MSVC_RUNTIME_ATTR | {
        "_build_file": attr.label(
            allow_single_file = True,
            default = ":msvc_runtime.BUILD.bazel",
        ),
    },
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
        fail("Only one msvc_runtime.configure(...) tag is supported in the root module.")
    if root_tags:
        return root_tags[0]
    if non_root_tags:
        return non_root_tags[0]
    return struct(
        msvc_version = "",
        winarchive_tools_urls = {},
        winarchive_tools_integrity = {},
        architectures = DEFAULT_ARCHITECTURES,
        visual_studio_channel_url = DEFAULT_VS_CHANNEL_URL,
        visual_studio_installer_manifest_url = "",
        visual_studio_installer_manifest_integrity = "",
    )

def _msvc_runtime_extension_impl(module_ctx):
    config = _read_configure_tag(module_ctx)
    _check_msvc_license_requirements(module_ctx)

    facts = resolve_installer_manifest_from_module_facts(module_ctx, config, _MSVC_RUNTIME_FACTS_KEY, _MSVC_RUNTIME_FACTS_SCHEMA_VERSION)

    _msvc_runtime_repository(
        name = "msvc_runtime",
        msvc_version = config.msvc_version,
        winarchive_tools_urls = config.winarchive_tools_urls,
        winarchive_tools_integrity = config.winarchive_tools_integrity,
        architectures = config.architectures,
        installer_manifest_json = json.encode(facts["installer_manifest"]),
    )

    return module_ctx.extension_metadata(
        facts = {_MSVC_RUNTIME_FACTS_KEY: facts},
        root_module_direct_deps = ["msvc_runtime"],
        root_module_direct_dev_deps = [],
    )

msvc_runtime = module_extension(
    implementation = _msvc_runtime_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = COMMON_MODULE_EXTENSION_ATTR | _MSVC_RUNTIME_ATTR),
    },
    doc = "MSVC runtime extension.",
)
