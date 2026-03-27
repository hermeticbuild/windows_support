# windows-bcr

> ⚠️ **Warning:** Repository under construction, some extensions APIs and their behavior may change without notice

Hermetic provider of Windows headers and libraries for native compilation in Bazel.
Currently available:

- Microsoft Visual C++ (MSVC) runtime
- Microsoft Windows SDK

It allows to build native code targeting Windows MSVC, from Linux, macOS or Windows using Bazel.

## Installation

```starlark
bazel_dep(name = "windows", version = "0.0.1")

# Warning: using `msvc_runtime` extension requires the machine to have the right to use the MSVC runtime, see section below for more information.
msvc_runtime = use_extension("@windows//windows/extensions.bzl", "msvc_runtime")
msvc_runtime.configure(
  msvc_version = "14.50.35717",  # Ensures that this exact version is in the installer manifest of the Visual Studio channel used
)
use_repo(msvc_runtime, "msvc_runtime")

windows_sdk = use_extension("@windows//windows/extensions.bzl", "windows_sdk")
windows_sdk.configure(
    windows_sdk_version = "10.0.26100",
)
use_repo(windows_sdk, "windows_sdk")
```

### About `msvc_runtime` license requirement

The `msvc_runtime` extension requires the machine using the `windows` module to have the right to use the MSVC (Microsoft Visual Studio C+) runtime headers and libraries.
This is guarded by the user-defined `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA` environment variable.

To use the `msvc_runtime` extension:

1. ensure that your machine is legally allowed to use the MSVC runtime
2. set the environment variable `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA` to `1`, e.g. via `--repo_env=BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA=1`

See https://visualstudio.microsoft.com/license-terms for more information.

## Reproducibility

Visual Studio installer manifest URL is resolved from the channel URL specified by `visual_studio_channel_url` (defaulting to `https://aka.ms/vs/stable/channel`).
That URL resolution is cached in your `MODULE.bazel.lock` to ensure reproducibility.

However, alternatively you could set the Visual Studio installer manifest URL and integrity manually to avoid channel resolution:

```starlark
bazel_dep(name = "windows", version = "0.0.1")

visual_studio_installer_manifest_url = "https://download.visualstudio.microsoft.com/download/pr/fdc37f6e-59f6-4054-838a-b476eeaa6ec3/1d82370739911457e0a2f6be15d8b5f569531b352b2eabb961429eea1e99e356/VisualStudio.vsman"
visual_studio_installer_manifest_integrity = "a8e854fa9f3fbaeac27d7304e297f1660d7137401389deb57cf7983f33c16fef"

msvc_runtime = use_extension("@windows//windows/extensions.bzl", "msvc_runtime")
msvc_runtime.configure(
  msvc_version = "14.50.35717",  # Ensures that this exact version is in the installer manifest of the Visual Studio channel used
  visual_studio_installer_manifest_url = visual_studio_installer_manifest_url,
  visual_studio_installer_manifest_integrity = visual_studio_installer_manifest_integrity,
)
use_repo(msvc_runtime, "msvc_runtime")

windows_sdk = use_extension("@windows//windows/extensions.bzl", "windows_sdk")
windows_sdk.configure(
  windows_sdk_version = "10.0.26100",
  visual_studio_installer_manifest_url = visual_studio_installer_manifest_url,
  visual_studio_installer_manifest_integrity = visual_studio_installer_manifest_integrity,
)
use_repo(windows_sdk, "windows_sdk")
```

## Acknowledgements

- The resolution logic is heavily inspired by [lorenz/winsysroot](https://github.com/lorenz/winsysroot), thank you Lorenz!
