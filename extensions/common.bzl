"""Shared helpers for the extracted Windows module extensions."""

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

_VISUAL_STUDIO_MANIFEST_COMPONENT = "Microsoft.VisualStudio.Manifests.VisualStudio"

_COMMON_ATTR = {
    "winarchive_tools_urls": attr.string_dict(
        default = {},
        doc = "Optional map from <os>_<arch> to prebuilt winarchive-tools binary URL. If not set, pinned defaults are used.",
    ),
    "winarchive_tools_integrity": attr.string_dict(
        default = {},
        doc = "Optional map from <os>_<arch> to winarchive-tools binary SRI integrity.",
    ),
    "architectures": attr.string_list(
        default = ["x64", "arm64"],
        doc = "Architectures to extract from the resolved runtime or SDKs",
    ),
}

COMMON_REPOSITORY_ATTR = _COMMON_ATTR | {
    "installer_manifest_json": attr.string(
        doc = "Compacted JSON representing the resolved Visual Studio installer manifest subset used by the repositories",
    ),
}

# Attributes used for the installer manifest resolution
COMMON_MODULE_EXTENSION_ATTR = _COMMON_ATTR | {
    "visual_studio_channel_url": attr.string(
        default = "https://aka.ms/vs/stable/channel",
        doc = "Visual Studio release channel URL used to resolve the installer manifest, use `visual_studio_installer_manifest_url` and `visual_studio_installer_manifest_integrity` for reproducibility instead",
    ),
    "visual_studio_installer_manifest_url": attr.string(
        doc = "Override URL for the Visual Studio installer manifest, if set the installer manifest will not be resolved from a query to `visual_studio_channel_url`",
    ),
    "visual_studio_installer_manifest_integrity": attr.string(
        doc = "Optional SRI integrity for the downloaded Visual Studio installer manifest.",
    ),
}

def resolve_installer_manifest_from_module_facts(module_ctx, config, key, schema_version):
    """Resolves the Visual Studio installer manifest from Bazel module facts if existing, or from passed URLs if not.

    Args:
      module_ctx: Module context
      config: Configuration containing either the Visual Studio installer manifest URL and integrity, or the Visual Studio channel URL from which to resolve the Visual Studio installer manifest URL

    Returns:
      A struct containing the downloaded Visual Studio installer manifest in a form of a resolved Bazel module fact
    """

    cached = module_ctx.facts.get(key)
    requested = {
        "visual_studio_installer_manifest_integrity": config.visual_studio_installer_manifest_integrity,
        "visual_studio_installer_manifest_url": config.visual_studio_installer_manifest_url,
        "visual_studio_channel_url": config.visual_studio_channel_url,
    }
    if cached != None and cached.get("schema_version") == schema_version and cached.get("requested") == requested:
        return cached
    else:
        installer_manifest = _resolve_installer_manifest(module_ctx, config, "windows_sdk_resolution")
        resolution = {
            "installer_manifest_url": installer_manifest.url,
            "installer_manifest_integrity": installer_manifest.integrity,
            "installer_manifest": installer_manifest.json,
            "schema_version": schema_version,
        }
        resolution["requested"] = requested
        return resolution

def _compact_payload(payload):
    compact = {
        "fileName": payload["fileName"],
        "url": payload["url"],
    }
    if payload.get("sha256", ""):
        compact["sha256"] = payload["sha256"]
    return compact

def _compact_installer_manifest_package(pkg):
    compact = {
        "id": pkg.get("id", ""),
        "payloads": [_compact_payload(payload) for payload in pkg.get("payloads", [])],
    }
    if pkg.get("type", ""):
        compact["type"] = pkg["type"]
    if pkg.get("dependencies", {}):
        compact["dependencies"] = sorted(pkg["dependencies"].keys())
    return compact

def _compact_installer_manifest(installer_manifest):
    return {
        "packages": [_compact_installer_manifest_package(pkg) for pkg in installer_manifest.get("packages", [])],
    }

def _resolve_installer_manifest(module_ctx, config, output_dir):
    if config.visual_studio_installer_manifest_url:
        installer_manifest = download_json(
            module_ctx,
            config.visual_studio_installer_manifest_url,
            "{}/installer_manifest.json".format(output_dir),
            config.visual_studio_installer_manifest_integrity,
        )
        visual_studio_installer_manifest_url = config.visual_studio_installer_manifest_url
    else:
        channel_manifest = download_json(
            module_ctx,
            config.visual_studio_channel_url,
            "{}/channel_manifest.json".format(output_dir),
        ).json

        found = False
        for item in channel_manifest.get("channelItems", []):
            if item.get("id", "") != _VISUAL_STUDIO_MANIFEST_COMPONENT:
                continue
            payloads = item.get("payloads", [])
            if not payloads:
                fail("channel manifest entry {} has no payloads".format(_VISUAL_STUDIO_MANIFEST_COMPONENT))
            visual_studio_installer_manifest_url = payloads[0].get("url", "")
            if not visual_studio_installer_manifest_url:
                fail("channel manifest entry {} has no payload url".format(_VISUAL_STUDIO_MANIFEST_COMPONENT))
            installer_manifest = download_json(
                module_ctx,
                visual_studio_installer_manifest_url,
                "{}/installer_manifest.json".format(output_dir),
            )
            found = True
            break
        if not found:
            fail("failed to find installer manifest URL in Visual Studio channel manifest")

    return struct(
        url = visual_studio_installer_manifest_url,
        integrity = installer_manifest.integrity,
        json = _compact_installer_manifest(installer_manifest.json),
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
        json = decoded,
    )
