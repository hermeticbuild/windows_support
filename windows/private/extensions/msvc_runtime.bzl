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
_ARCH_TO_REDIST_PACKAGE = {
    "arm": None,  # no modern desktop redist package
    "arm64": "Microsoft.VisualCpp.CRT.Redist.ARM64",
    "arm64ec": None,  # arm64ec binaries run against the x64/arm64 redists
    "x64": "Microsoft.VisualCpp.CRT.Redist.X64",
    "x86": "Microsoft.VisualCpp.CRT.Redist.X86",
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
        packages_by_id[pkg.get("id", "").lower()] = pkg

    pending = []
    for arch in architectures:
        component = _ARCH_TO_MSVC_COMPONENT.get(arch)
        if component == None:
            fail("unknown architecture {}, do not know the correct MSVC tools package".format(arch))
        if component.lower() not in packages_by_id:
            fail("failed to find Visual Studio package {} in installer manifest".format(component))
        pending.append(component.lower())

        # The desktop VC redist packages are not reliably part of the tools
        # components' dependency closure, request them explicitly.
        redist_package = _ARCH_TO_REDIST_PACKAGE.get(arch)
        if redist_package:
            if redist_package.lower() not in packages_by_id:
                fail("failed to find VC redist package {} in installer manifest".format(redist_package))
            pending.append(redist_package.lower())

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
                next_frontier.extend(sorted([dep.lower() for dep in dependencies]))
            else:
                next_frontier.extend(sorted([dep.lower() for dep in dependencies.keys()]))
        frontier = next_frontier

    vctools_packages = {}
    for package_id in sorted(selected.keys()):
        pkg = selected[package_id]
        if pkg.get("type", "").lower() != "vsix":
            continue
        payloads = pkg.get("payloads", [])
        if not payloads:
            fail("package {} has no payloads".format(package_id))
        vctools_packages[pkg.get("id", "")] = pkg

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

def _is_dotted_version(name):
    parts = name.split(".")
    for part in parts:
        if not part.isdigit():
            return False
    return len(parts) > 1

def _msvc_compatibility_version(msvc_version):
    """Converts an MSVC 14.x toolset version to its 19.x compiler version."""
    parts = msvc_version.split(".")
    if len(parts) != 3 or parts[0] != "14" or not _is_dotted_version(msvc_version):
        fail("cannot derive the MSVC compiler compatibility version from toolset version {}: expected 14.<minor>.<build>".format(msvc_version))
    return "19.{}.{}".format(parts[1], parts[2])

def _discover_redist_version(repository_ctx, sysroot_dir):
    """Returns the version directory name under Contents/VC/Redist/MSVC, if any.

    The redist version differs from the MSVC tools version (e.g. redist
    14.50.35710 for tools 14.50.35717), so it has to be discovered from the
    extracted payloads. Non-version directories (e.g. `v145`, which holds the
    standalone `vc_redist.<arch>.exe` installers) are ignored.
    """
    redist_msvc_dir = repository_ctx.path("{}/Contents/VC/Redist/MSVC".format(sysroot_dir))
    if not redist_msvc_dir.exists or not redist_msvc_dir.is_dir:
        return None
    versions = [
        _basename(entry)
        for entry in redist_msvc_dir.readdir()
        if entry.is_dir and _is_dotted_version(_basename(entry))
    ]
    if len(versions) > 1:
        fail("expected exactly one version directory under Contents/VC/Redist/MSVC in the extracted MSVC payloads, found: {}".format(sorted(versions)))
    return versions[0] if versions else None

def _redist_architectures(architectures):
    return [arch for arch in architectures if _ARCH_TO_REDIST_PACKAGE.get(arch)]

def _keep_exposed_runtime_files(repository_ctx, sysroot_dir, msvc_version, architectures, redist_version):
    sysroot_path = repository_ctx.path(sysroot_dir)
    contents_dir = repository_ctx.path("{}/Contents".format(sysroot_dir))
    vc_dir = repository_ctx.path("{}/Contents/VC".format(sysroot_dir))
    tools_dir = repository_ctx.path("{}/Contents/VC/Tools".format(sysroot_dir))
    msvc_dir = repository_ctx.path("{}/Contents/VC/Tools/MSVC".format(sysroot_dir))

    _keep_only_children(repository_ctx, sysroot_path, ["Contents"])
    _keep_only_children(repository_ctx, contents_dir, ["VC"])
    _keep_only_children(repository_ctx, vc_dir, ["Tools", "Redist"] if redist_version else ["Tools"])
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

    if redist_version:
        redist_architectures = _redist_architectures(architectures)
        _keep_only_children(
            repository_ctx,
            repository_ctx.path("{}/Contents/VC/Redist".format(sysroot_dir)),
            ["MSVC"],
        )
        _keep_only_children(
            repository_ctx,
            repository_ctx.path("{}/Contents/VC/Redist/MSVC".format(sysroot_dir)),
            [redist_version],
        )

        _keep_only_children(
            repository_ctx,
            repository_ctx.path("{}/Contents/VC/Redist/MSVC/{}".format(sysroot_dir, redist_version)),
            redist_architectures + ["debug_nonredist"],
        )
        _keep_only_children(
            repository_ctx,
            repository_ctx.path("{}/Contents/VC/Redist/MSVC/{}/debug_nonredist".format(sysroot_dir, redist_version)),
            redist_architectures,
        )

# Parts of the MSVC tree that toolchains put on their include and library
# search paths. Copying them when the repository is fetched lets a toolchain
# depend on them as source directories instead of copying them in a build action.
_SUBSET_HEADERS = {
    "com_support_include": [
        "comdef.h",
        "comdefsp.h",
        "comip.h",
        "comutil.h",
    ],
    "vcruntime_include": [
        "CodeAnalysis/sourceannotations.h",
        "concurrencysal.h",
        "crtdefs.h",
        "eh.h",
        "ehdata.h",
        "ehdata_forceinclude.h",
        "ehdata_values.h",
        "excpt.h",
        "sal.h",
        "setjmp.h",
        "setjmpex.h",
        "threads.h",
        "vadefs.h",
        "vcruntime.h",
        "vcruntime_exception.h",
        "vcruntime_new.h",
        "vcruntime_new_debug.h",
        "vcruntime_string.h",
        "vcruntime_startup.h",
        "vcruntime_typeinfo.h",
    ],
}

_SUBSET_LIBRARIES = {
    "com": [
        "comsupp.lib",
        "comsuppw.lib",
    ],
    "common": [
        "exe_initialize_mta.lib",
        "iso_stdio_wide_specifiers.lib",
        "legacy_stdio_definitions.lib",
        "legacy_stdio_wide_specifiers.lib",
        "oldnames.lib",
    ],
    "dynamic": [
        "msvcprt.lib",
        "msvcrt.lib",
        "vcruntime.lib",
    ],
    "static": [
        "libcmt.lib",
        "libcpmt.lib",
        "libvcruntime.lib",
    ],
}

def _write_subsets(repository_ctx, sysroot_dir, msvc_version, architectures):
    msvc_dir = "{}/Contents/VC/Tools/MSVC/{}".format(sysroot_dir, msvc_version)
    copies = {}
    for subset, headers in _SUBSET_HEADERS.items():
        for header in headers:
            copies["subsets/{}/{}".format(subset, header)] = "{}/include/{}".format(msvc_dir, header)
    for arch in architectures:
        if arch not in ["x64", "arm64"]:
            continue
        for subset, libraries in _SUBSET_LIBRARIES.items():
            for library in libraries:
                copies["subsets/lib/{}/{}/{}".format(arch, subset, library)] = "{}/lib/{}/{}".format(msvc_dir, arch, library)
    for dst, src in copies.items():
        if repository_ctx.path(src).exists:
            repository_ctx.file(dst, repository_ctx.read(src), executable = False, legacy_utf8 = False)

def _msvc_runtime_repository_impl(repository_ctx):
    _check_msvc_license_requirements(repository_ctx)

    sysroot_dir = "sysroot"

    architectures = repository_ctx.attr.architectures
    if not architectures:
        fail("no architectures specified")
    msvc_version = repository_ctx.attr.msvc_version
    if not msvc_version:
        fail("msvc_version must be set")
    msvc_compatibility_version = _msvc_compatibility_version(msvc_version)

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

    redist_version = _discover_redist_version(repository_ctx, sysroot_dir)
    redist_architectures = _redist_architectures(architectures)
    if redist_architectures and not redist_version:
        fail("failed to find Contents/VC/Redist/MSVC/<version> in extracted MSVC payloads for architectures {}".format(redist_architectures))
    _keep_exposed_runtime_files(repository_ctx, sysroot_dir, msvc_version, architectures, redist_version)
    _write_subsets(repository_ctx, sysroot_dir, msvc_version, architectures)

    repository_ctx.file(
        "versions.bzl",
        content = '''"""Resolved MSVC runtime version information.

Generated by windows_support; do not edit.
"""

MSVC_TOOLSET_VERSION = {msvc_toolset_version}
MSVC_COMPATIBILITY_VERSION = {msvc_compatibility_version}
VC_REDIST_VERSION = {vc_redist_version}
'''.format(
            msvc_toolset_version = repr(msvc_version),
            msvc_compatibility_version = repr(msvc_compatibility_version),
            vc_redist_version = repr(redist_version),
        ),
    )

    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr._build_file,
        substitutions = {
            "__MSVC_RUNTIME_DIR__": sysroot_dir,
            "__MSVC_VERSION__": msvc_version,
            # The sentinel value makes the redist globs match nothing when no
            # redist is available (e.g. arm/arm64ec-only configurations).
            "__VC_REDIST_VERSION__": redist_version if redist_version else "unavailable",
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
    non_root_tag = None

    for mod in module_ctx.modules:
        configure_tags = [tag for tag in mod.tags.configure]
        if len(configure_tags) > 1:
            fail("Only one msvc_runtime.configure(...) tag is supported per module.")

        if not configure_tags:
            continue

        if mod.is_root:
            return configure_tags[0]

        non_root_tag = configure_tags[0]

    if non_root_tag != None:
        return non_root_tag

    fail("Missing msvc_runtime.configure(...): set msvc_runtime.configure(...) in your MODULE.bazel")

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

    metadata_kwargs = {
        "facts": {_INSTALLER_MANIFEST_FACTS_KEY: installer_manifest},
    }
    if module_ctx.root_module_has_non_dev_dependency:
        metadata_kwargs["root_module_direct_deps"] = [repository_name]
        metadata_kwargs["root_module_direct_dev_deps"] = []
    else:
        metadata_kwargs["root_module_direct_deps"] = []
        metadata_kwargs["root_module_direct_dev_deps"] = [repository_name]

    return module_ctx.extension_metadata(
        **metadata_kwargs
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
