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

## Reproducibility

Visual Studio installer manifest is resolved from the channel URL specified by `visual_studio_channel_url` (defaulting to `https://aka.ms/vs/stable/channel`).
The result of this resolution is cached in your `MODULE.bazel.lock` to ensure subsequent reproducibility.

However, alternatively you could set:

```starlark
bazel_dep(name = "windows", version = "0.0.1")

visual_studio_installer_manifest_url = ""
visual_studio_installer_manifest_integrity = ""

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
