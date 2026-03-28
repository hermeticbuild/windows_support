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
msvc_runtime = use_extension("@windows//windows:extensions.bzl", "msvc_runtime")
msvc_runtime.configure(
  msvc_version = "14.50.35717",  # Ensures that this exact version is in the installer manifest of the Visual Studio channel used
)
use_repo(msvc_runtime, "msvc_runtime")

windows_sdk = use_extension("@windows//windows:extensions.bzl", "windows_sdk")
windows_sdk.configure(
    windows_sdk_version = "10.0.26100.7705",
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

## Limitations

Sadly, that module is not perfect, there are several major limitations:

- Case-sensitive systems are poorly supported by the inefficient `transformations` attribute, we plan to support `vfsoverlay` configuration in the future [see #3](https://github.com/ArchangelX360/windows-bcr/issues/3)
- The specified MSVC runtime version must be present in the Visual Studio installer manifest specified or resolved from the Visual Studio channel, it cannot be any version
- Declaring multiple repositories for multiple versions of the MSVC runtime to coexist is unsupported
- Declaring multiple repositories for multiple versions of the Windows SDK to coexist is unsupported

## Reproducibility

Visual Studio installer manifest URL is resolved from the channel URL specified by `visual_studio_channel_url` (defaulting to `https://aka.ms/vs/stable/channel`).
That URL resolution is cached in your `MODULE.bazel.lock` to ensure reproducibility.

However, alternatively you could set the Visual Studio installer manifest URL and integrity manually to avoid channel resolution:

```starlark
bazel_dep(name = "windows", version = "0.0.1")

msvc_runtime = use_extension("@windows//windows:extensions.bzl", "msvc_runtime")
msvc_runtime.configure(
  msvc_version = "14.50.35717",
  visual_studio_installer_manifest_url = "https://download.visualstudio.microsoft.com/download/pr/fdc37f6e-59f6-4054-838a-b476eeaa6ec3/1d82370739911457e0a2f6be15d8b5f569531b352b2eabb961429eea1e99e356/VisualStudio.vsman",
  visual_studio_installer_manifest_integrity = "sha256-qOhU+p8/uurCfXME4pfxZg1xN0ATid61fPeYPzPBb+8=",
)
use_repo(msvc_runtime, "msvc_runtime")

windows_sdk = use_extension("@windows//windows:extensions.bzl", "windows_sdk")
windows_sdk.configure(
    windows_sdk_version = "10.0.26100.7705",
    windows_sdk_integrity = {
      "Microsoft.Windows.SDK.CPP": "sha256-/0VWYL7gcadEcVqWZWZvopwHaBV509gVlZqe7FpVZCQ=",
      "Microsoft.Windows.SDK.CPP.x64": "sha256-rWzpD/lAEGmdKVSLPCseUsieuBFD4hmRVdmlw4ABtSs=",
      "Microsoft.Windows.SDK.CPP.arm64": "sha256-A7wMA9Q5zvhQdLvNQl+dXTptO0Z5Z6zSHaO6bf7q+mc="
    },
)
use_repo(windows_sdk, "windows_sdk")
```

## Case-sensitive filesystem support

This is an example on how case-sensitive filesystems can be supported.
This example does two things:

- naively lowercases (while keeping originals) headers and libraries files, either by symlinking (if supported) or copying them
- transforms (while keeping originals) to some cased variant observed in some C sources in the wild, either by symlinking (if supported) or copying them

```starlark
windows_sdk = use_extension("@windows//windows:extensions.bzl", "windows_sdk")
windows_sdk.configure(
    windows_sdk_version = "10.0.26100.7705",
    transformations = {
        "base/c/Include/10.0.26100.0/shared/driverspecs.h": "base/c/Include/10.0.26100.0/shared/DriverSpecs.h",
        "base/c/Include/10.0.26100.0/shared/specstrings.h": "base/c/Include/10.0.26100.0/shared/SpecStrings.h",
        "base/c/Include/10.0.26100.0/um/ole2.h": "base/c/Include/10.0.26100.0/um/Ole2.h",
        "base/c/Include/10.0.26100.0/um/olectl.h": "base/c/Include/10.0.26100.0/um/OleCtl.h",
        "**/*.h": "lowercase",
        "**/*.lib": "lowercase",
        "**/*.Lib": "lowercase",
    },
)
use_repo(windows_sdk, "windows_sdk")
```

## Acknowledgements

- The resolution logic is heavily inspired by [lorenz/winsysroot](https://github.com/lorenz/winsysroot), thank you Lorenz!
