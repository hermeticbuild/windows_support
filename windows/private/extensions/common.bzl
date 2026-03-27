"""Shared helpers for the extracted Windows module extensions."""

DEFAULT_VS_CHANNEL_URL = "https://aka.ms/vs/stable/channel"
DEFAULT_ARCHITECTURES = ["x64", "arm64"]
_WINARCHIVE_TOOLS_VERSION = "v0.0.1"
_REPO_URL = "https://github.com/ArchangelX360/winarchive-tools/releases/download/{}/winarchive-tools-{}"
_DEFAULT_WINARCHIVE_TOOLS_URLS = {
    "darwin_amd64": _REPO_URL.format(_WINARCHIVE_TOOLS_VERSION, "darwin-amd64"),
    "darwin_arm64": _REPO_URL.format(_WINARCHIVE_TOOLS_VERSION, "darwin-arm64"),
    "linux_amd64": _REPO_URL.format(_WINARCHIVE_TOOLS_VERSION, "linux-amd64"),
    "linux_arm64": _REPO_URL.format(_WINARCHIVE_TOOLS_VERSION, "linux-arm64"),
    "windows_amd64": _REPO_URL.format(_WINARCHIVE_TOOLS_VERSION, "windows-amd64.exe"),
    "windows_arm64": _REPO_URL.format(_WINARCHIVE_TOOLS_VERSION, "windows-arm64.exe"),
}
_DEFAULT_WINARCHIVE_TOOLS_INTEGRITY = {
    "darwin_amd64": "sha256-iil0YAPxbY4o7GZN5nei11Rzxj2OeEqSwBCXaqW8nuM=",
    "darwin_arm64": "sha256-qTcgdjuEowqonG1J7U7P4lzInRkAYM6/8X8N6dYQc34=",
    "linux_amd64": "sha256-w8BYFD8nrCJqoZZQFQQXKY2W5G85jfyzNsHF+QONt5c=",
    "linux_arm64": "sha256-uLWXB/Fy5BEBjLxfGswQLxnO19WeeF4Iw7nQ/5Sgu7c=",
    "windows_amd64": "sha256-L+GzYfR3dBDvFoY2vx6hP4MWFWSV9ozr5FdmfIvaaF8=",
    "windows_arm64": "sha256-eYuZhS4YCACovPpw0yzjtEXg3j96rFCtrwpOtKCmMFw=",
}

INSTALLER_MANIFEST_DOWNLOADS_DIR = "installer_manifest_downloads"
INSTALLER_MANIFEST_FACTS_KEY = "visual_studio_installer_manifest_v1"

_VISUAL_STUDIO_MANIFEST_COMPONENT = "Microsoft.VisualStudio.Manifests.VisualStudio"

_COMMON_ATTR = {
    "winarchive_tools_urls": attr.string_dict(
        doc = "Optional map from <os>_<arch> to prebuilt winarchive-tools binary URL. If not set, pinned defaults are used.",
    ),
    "winarchive_tools_integrity": attr.string_dict(
        doc = "Optional map from <os>_<arch> to winarchive-tools binary SRI integrity.",
    ),
    "architectures": attr.string_list(
        default = DEFAULT_ARCHITECTURES,
        doc = "Architectures to extract from the resolved runtime or SDKs",
    ),
}

COMMON_REPOSITORY_ATTR = _COMMON_ATTR | {
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

# Attributes used for the installer manifest resolution
COMMON_MODULE_EXTENSION_ATTR = _COMMON_ATTR | {
    "visual_studio_channel_url": attr.string(
        default = DEFAULT_VS_CHANNEL_URL,
        doc = "Visual Studio release channel URL used to resolve the installer manifest, use `visual_studio_installer_manifest_url` and `visual_studio_installer_manifest_integrity` for reproducibility instead",
    ),
    "visual_studio_installer_manifest_url": attr.string(
        doc = "Override URL for the Visual Studio installer manifest, if set the installer manifest will not be resolved from a query to `visual_studio_channel_url`",
    ),
    "visual_studio_installer_manifest_integrity": attr.string(
        doc = "Optional SRI integrity for the downloaded Visual Studio installer manifest.",
    ),
}

def resolve_installer_manifest_from_module_facts(
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
    channel_manifest = download_json(
        module_ctx,
        channel_url,
        "{}/channel_manifest.json".format(INSTALLER_MANIFEST_DOWNLOADS_DIR),
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

def download_installer_manifest(module_ctx, installer_manifest_url, installer_manifest_integrity):
    """Downloads the Visual Studio installer manifest.

    Args:
      module_ctx: Module context.
      installer_manifest_url: URL of the Visual Studio installer manifest
      installer_manifest_integrity: Optional integrity of the Visual Studio installer manifest against which to check the downloaded file content

    Returns:
      The Visual Studio installer manifest as a struct from the decoded JSON
    """

    return download_json(
        module_ctx,
        installer_manifest_url,
        "{}/installer_manifest.json".format(INSTALLER_MANIFEST_DOWNLOADS_DIR),
        installer_manifest_integrity,
    )

def ensure_winarchive_tools_binary(repository_ctx, extension_name):
    """Downloads the host winarchive-tools binary for an extension.

    Args:
      repository_ctx: Repository rule context with winarchive-tools attrs.
      extension_name: Name of the calling extension for error reporting.

    Returns:
      A struct containing the downloaded binary path and reproducibility attrs.
    """

    host_key = _host_key(repository_ctx)
    winarchive_tools_urls = repository_ctx.attr.winarchive_tools_urls if repository_ctx.attr.winarchive_tools_urls else _DEFAULT_WINARCHIVE_TOOLS_URLS
    winarchive_tools_integrity = repository_ctx.attr.winarchive_tools_integrity if repository_ctx.attr.winarchive_tools_integrity else _DEFAULT_WINARCHIVE_TOOLS_INTEGRITY
    winarchive_tools_url = winarchive_tools_urls.get(host_key, "")
    if not winarchive_tools_url:
        fail("winarchive-tools is required. Provide winarchive_tools_urls[\"{}\"] in {}.configure(...).".format(host_key or "<os>_<arch>", extension_name))

    if host_key == "windows_amd64" or host_key == "windows_arm64":
        winarchive_tools_binary_name = "winarchive-tools.exe"
    else:
        winarchive_tools_binary_name = "winarchive-tools"

    winarchive_tools_path = repository_ctx.path(winarchive_tools_binary_name)
    download_kwargs = {
        "url": [winarchive_tools_url],
        "output": winarchive_tools_path,
        "executable": True,
    }
    if winarchive_tools_integrity.get(host_key, ""):
        download_kwargs["integrity"] = winarchive_tools_integrity[host_key]
    download_info = repository_ctx.download(**download_kwargs)

    return struct(
        integrity = download_info.integrity,
        path = winarchive_tools_path,
    )

def run_winarchive_tools(repository_ctx, winarchive_tools_path, args, description):
    """Runs winarchive-tools and fails with a detailed error on non-zero exit.

    Args:
      repository_ctx: Repository rule context used to execute the tool.
      winarchive_tools_path: Path to the downloaded winarchive-tools binary.
      args: Command-line arguments forwarded to winarchive-tools.
      description: Human-readable command description for failure messages.

    Returns:
      The successful result from repository_ctx.execute().
    """

    result = repository_ctx.execute([str(winarchive_tools_path)] + args)
    if result.return_code != 0:
        fail("{} failed with exit code {}.\nstdout:\n{}\nstderr:\n{}".format(description, result.return_code, result.stdout, result.stderr))
    return result

def _host_key(repository_ctx):
    os_name = repository_ctx.os.name.lower()
    arch = repository_ctx.os.arch.lower()

    if os_name.startswith("mac os"):
        os_token = "darwin"
    elif os_name.startswith("linux"):
        os_token = "linux"
    elif os_name.startswith("windows"):
        os_token = "windows"
    else:
        os_token = ""

    if arch in ["arm64", "aarch64"]:
        arch_token = "arm64"
    elif arch in ["x86_64", "amd64"]:
        arch_token = "amd64"
    else:
        arch_token = ""

    if not os_token or not arch_token:
        return ""
    return os_token + "_" + arch_token

def download_json(module_ctx, url, output, integrity = ""):
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
