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
