"""bzlmod extension for assembling an MSVC runtime repository."""

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "update_attrs")

_DEFAULT_ARCHITECTURES = ["x64", "arm64"]
_DEFAULT_VS_CHANNEL_URL = "https://aka.ms/vs/stable/channel"
_INSTALLER_MANIFEST_DOWNLOADS_DIR = "installer_manifest_downloads"
_INSTALLER_MANIFEST_FACTS_KEY = "visual_studio_installer_manifest_v1"
_MSVC_RUNTIME_VISUAL_STUDIO_EULA_ENV = "BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA"
_VISUAL_STUDIO_MANIFEST_COMPONENT = "Microsoft.VisualStudio.Manifests.VisualStudio"
_ARCH_TO_MSVC_COMPONENT = {
    "arm": "Microsoft.VisualStudio.Component.VC.Tools.ARM",
    "arm64": "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
    "arm64ec": "Microsoft.VisualStudio.Component.VC.Tools.ARM64EC",
    "x64": "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "x86": "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
}

def _check_msvc_license_requirements(ctx):
    approval = ctx.getenv(_MSVC_RUNTIME_VISUAL_STUDIO_EULA_ENV)
    if approval not in ["1", "yes", "y", "true"]:
        fail("""
            MSVC license check failed, to resolve that failure please:
              1. ensure that your machine is legally allowed to use the MSVC runtime
              2. set the environment variable `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA` to `1`, e.g. via `--repo_env=BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA=1`

            See https://visualstudio.microsoft.com/license-terms for more information.
        """)

def _resolve_installer_manifest_from_module_facts(
        module_ctx,
        visual_studio_channel_url,
        visual_studio_installer_manifest_url,
        visual_studio_installer_manifest_integrity,
        key):
    """Resolves the Visual Studio installer manifest from Bazel module facts if existing, or from passed URLs if not.

    Args:
      module_ctx: Module context
      visual_studio_channel_url: Visual Studio channel URL from which to resolve the Visual Studio installer manifest URL, if not specified
      visual_studio_installer_manifest_url: Visual Studio installer manifest URL
      visual_studio_installer_manifest_integrity: (optional) Visual Studio installer manifest integrity
      key: Module fact key from which to retrieve/store the resolution result

    Returns:
      A struct containing the downloaded Visual Studio installer manifest in a form of a resolved Bazel module fact
    """

    cached = module_ctx.facts.get(key)
    requested = {
        "visual_studio_channel_url": visual_studio_channel_url,
        "visual_studio_installer_manifest_url": visual_studio_installer_manifest_url,
        "visual_studio_installer_manifest_integrity": visual_studio_installer_manifest_integrity,
    }
    if cached != None and cached.get("requested") == requested:
        return cached
    else:
        if not visual_studio_installer_manifest_url:  # if there is not user-defined Visual Studio installer URL, we derive it from the channel instead
            download_infos = _resolve_installer_manifest_download_info_from_channel(module_ctx, visual_studio_channel_url)
        else:
            download_infos = struct(
                url = visual_studio_installer_manifest_url,
                integrity = visual_studio_installer_manifest_integrity,
            )
        return {
            "request": requested,
            "url": download_infos.url,
            "integrity": download_infos.integrity,
        }

def _resolve_installer_manifest_download_info_from_channel(module_ctx, channel_url):
    channel_manifest = _download_json(
        module_ctx,
        channel_url,
        "{}/channel_manifest.json".format(_INSTALLER_MANIFEST_DOWNLOADS_DIR),
    ).decoded_struct

    for item in channel_manifest.get("channelItems", []):
        if item.get("id", "") != _VISUAL_STUDIO_MANIFEST_COMPONENT:
            continue
        payloads = item.get("payloads", [])
        if not payloads:
            fail("channel manifest entry {} has no payloads".format(_VISUAL_STUDIO_MANIFEST_COMPONENT))
        vc_manifest_component_package = payloads[0]
        visual_studio_installer_manifest_url = vc_manifest_component_package.get("url", "")
        if not visual_studio_installer_manifest_url:
            fail("channel manifest entry {} is missing the expected payload url".format(_VISUAL_STUDIO_MANIFEST_COMPONENT))
        return struct(
            url = visual_studio_installer_manifest_url,
            integrity = "",  # TODO: `use vc_manifest_component_package.get("sha256", ""),` + conversion to Bazel integrity, when Microsoft fixes their channel feed...
        )

    fail("failed to find installer manifest URL in Visual Studio channel manifest")

def _download_installer_manifest(module_ctx, installer_manifest_url, installer_manifest_integrity):
    return _download_json(
        module_ctx,
        installer_manifest_url,
        "{}/installer_manifest.json".format(_INSTALLER_MANIFEST_DOWNLOADS_DIR),
        installer_manifest_integrity,
    )

def _download_json(module_ctx, url, output, integrity = ""):
    """Downloads the JSON pointed by the given URL to the given output path.

    Args:
      module_ctx: Module context
      url: A URL pointing to a JSON file
      output: the path where the downloaded JSON will be written
      integrity: the integrity against which to check the downloaded content

    Returns:
      A struct the decoded JSON, and the integrity
    """

    download_kwargs = {
        "url": url,
        "output": output,
    }
    if integrity:
        download_kwargs["integrity"] = integrity
    download_info = module_ctx.download(**download_kwargs)
    decoded = json.decode(module_ctx.read(output), default = None)
    if decoded == None:
        fail("failed to decode JSON downloaded from {} to {}".format(url, output))
    return struct(
        integrity = download_info.integrity,
        decoded_struct = decoded,
    )

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

def _basename(path):
    path_str = str(path).replace("\\", "/")
    return path_str[path_str.rfind("/") + 1:]

def _keep_only_children(repository_ctx, directory, child_names):
    if not directory.exists or not directory.is_dir:
        return
    allowed = {name: True for name in child_names}
    for entry in directory.readdir():
        if allowed.get(_basename(entry), False):
            continue
        repository_ctx.delete(entry)

def _keep_exposed_runtime_files(repository_ctx, sysroot_dir, msvc_version, architectures):
    sysroot_path = repository_ctx.path(sysroot_dir)
    contents_dir = repository_ctx.path("{}/Contents".format(sysroot_dir))
    vc_dir = repository_ctx.path("{}/Contents/VC".format(sysroot_dir))
    tools_dir = repository_ctx.path("{}/Contents/VC/Tools".format(sysroot_dir))
    msvc_dir = repository_ctx.path("{}/Contents/VC/Tools/MSVC".format(sysroot_dir))

    _keep_only_children(repository_ctx, sysroot_path, ["Contents"])
    _keep_only_children(repository_ctx, contents_dir, ["VC"])
    _keep_only_children(repository_ctx, vc_dir, ["Tools"])
    _keep_only_children(repository_ctx, tools_dir, ["MSVC"])
    _keep_only_children(repository_ctx, msvc_dir, [msvc_version])
    _keep_only_children(
        repository_ctx,
        repository_ctx.path("{}/Contents/VC/Tools/MSVC/{}".format(sysroot_dir, msvc_version)),
        ["include", "lib"],
    )
    _keep_only_children(
        repository_ctx,
        repository_ctx.path("{}/Contents/VC/Tools/MSVC/{}/lib".format(sysroot_dir, msvc_version)),
        architectures,
    )

def _msvc_runtime_repository_impl(repository_ctx):
    _check_msvc_license_requirements(repository_ctx)

    sysroot_dir = "sysroot"

    architectures = repository_ctx.attr.architectures
    if not architectures:
        fail("no architectures specified")
    msvc_version = repository_ctx.attr.msvc_version
    if not msvc_version:
        fail("msvc_version must be set")

    installer_manifest = _download_installer_manifest(
        repository_ctx,
        repository_ctx.attr.installer_manifest_url,
        repository_ctx.attr.installer_manifest_integrity,
    )
    packages = _collect_vctools_packages(installer_manifest.decoded_struct, repository_ctx.attr.architectures)

    # Download/extract VSIX packages to look for the MSVC runtime pieces

    all_downloaded_payloads_have_sha256 = True
    pending_vsix_downloads = []
    vsix_paths = []
    for package_id in packages.keys():
        pkg = packages[package_id]
        payloads = pkg.get("payloads", [])
        payload = payloads[0]
        file_name = _basename(payload.get("fileName", ""))
        if not file_name.lower().endswith(".zip"):
            file_name = file_name + ".zip"
        local_path = "msvc_runtime_downloads/vctools/{}/{}".format(package_id.replace("\\", "_").replace("/", "_").replace(":", "_"), file_name)
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

    for vsix_path in vsix_paths:
        repository_ctx.extract(vsix_path, output = sysroot_dir)

    requested_version_dir = repository_ctx.path("{}/Contents/VC/Tools/MSVC/{}".format(sysroot_dir, msvc_version))
    if not requested_version_dir.exists or not requested_version_dir.is_dir:
        fail("failed to find Contents/VC/Tools/MSVC/{} in extracted MSVC payloads".format(msvc_version))
    _keep_exposed_runtime_files(repository_ctx, sysroot_dir, msvc_version, architectures)

    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr._build_file,
        substitutions = {
            "__MSVC_RUNTIME_DIR__": sysroot_dir,
            "__MSVC_VERSION__": msvc_version,
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
                _MSVC_RUNTIME_REPOSITORY_ATTRS.keys(),
                reproducibility_overrides,
            ),
        )

_MSVC_RUNTIME_ATTR = {
    "architectures": attr.string_list(
        default = _DEFAULT_ARCHITECTURES,
        doc = "Architectures to extract from the resolved MSVC runtime components",
    ),
    "msvc_version": attr.string(
        doc = "Required expected MSVC tools version. Only files under Contents/VC/Tools/MSVC/<msvc_version> are extracted.",
    ),
    "installer_manifest_url": attr.string(
        doc = "URL of the resolved/specified Visual Studio installer manifest",
    ),
    "installer_manifest_integrity": attr.string(
        doc = "Optional integrity of the resolved/specified Visual Studio installer manifest",
    ),
    "installer_manifest_sha256": attr.string(
        doc = "Optional integrity (as sha256 hash) of the resolved/specified Visual Studio installer manifest",
    ),
}

_MSVC_RUNTIME_REPOSITORY_ATTRS = _MSVC_RUNTIME_ATTR | {
    "_build_file": attr.label(
        allow_single_file = True,
        default = ":msvc_runtime.BUILD.bazel",
    ),
}

_msvc_runtime_repository = repository_rule(
    implementation = _msvc_runtime_repository_impl,
    attrs = _MSVC_RUNTIME_REPOSITORY_ATTRS,
    environ = [_MSVC_RUNTIME_VISUAL_STUDIO_EULA_ENV],
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
        architectures = _DEFAULT_ARCHITECTURES,
        visual_studio_channel_url = _DEFAULT_VS_CHANNEL_URL,
        visual_studio_installer_manifest_url = "",
        visual_studio_installer_manifest_integrity = "",
    )

def _msvc_runtime_extension_impl(module_ctx):
    config = _read_configure_tag(module_ctx)

    installer_manifest = _resolve_installer_manifest_from_module_facts(
        module_ctx,
        config.visual_studio_channel_url,
        config.visual_studio_installer_manifest_url,
        config.visual_studio_installer_manifest_integrity,
        _INSTALLER_MANIFEST_FACTS_KEY,
    )

    repository_name = "msvc_runtime"
    _msvc_runtime_repository(
        name = repository_name,
        msvc_version = config.msvc_version,
        architectures = config.architectures,
        installer_manifest_url = installer_manifest["url"],
        installer_manifest_integrity = installer_manifest["integrity"],
    )

    return module_ctx.extension_metadata(
        facts = {_INSTALLER_MANIFEST_FACTS_KEY: installer_manifest},
        root_module_direct_deps = [repository_name],
        root_module_direct_dev_deps = [],
    )

msvc_runtime = module_extension(
    implementation = _msvc_runtime_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = _MSVC_RUNTIME_ATTR | {
            "visual_studio_channel_url": attr.string(
                default = _DEFAULT_VS_CHANNEL_URL,
                doc = "Visual Studio release channel URL used to resolve the installer manifest, use `visual_studio_installer_manifest_url` and `visual_studio_installer_manifest_integrity` for reproducibility instead",
            ),
            "visual_studio_installer_manifest_url": attr.string(
                doc = "Override URL for the Visual Studio installer manifest, if set the installer manifest will not be resolved from a query to `visual_studio_channel_url`",
            ),
            "visual_studio_installer_manifest_integrity": attr.string(
                doc = "Optional SRI integrity for the downloaded Visual Studio installer manifest.",
            ),
        }),
    },
    doc = "MSVC runtime extension.",
)
