# Bazel `windows_support` module

> ⚠️ **Warning:** Repository under construction, some extensions APIs and their behavior may change without notice

Hermetic provider of Windows headers and libraries for native compilation in Bazel.
Currently available:

- Microsoft Visual C++ (MSVC) runtime
- Microsoft Windows SDK

It allows to build native code targeting Windows MSVC, from Linux, macOS or Windows using Bazel.

## Installation

```starlark
bazel_dep(name = "windows_support", version = "0.0.1")

# Warning: using `msvc_runtime` extension requires the machine to have the right to use the MSVC runtime, see section below for more information.
msvc_runtime = use_extension("@windows_support//windows:extensions.bzl", "msvc_runtime")
msvc_runtime.configure(
  msvc_version = "14.50.35717",
)
use_repo(msvc_runtime, "msvc_runtime")

windows_sdk = use_extension("@windows_support//windows:extensions.bzl", "windows_sdk")
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

- Case-sensitive systems require LLVM-based consuming toolchains to opt into the exported `@windows_sdk//:vfsoverlay` input; non-LLVM toolchains are unsupported
- The specified MSVC runtime version must be present in the Visual Studio installer manifest specified or resolved from the Visual Studio channel, it cannot be any version
- Declaring multiple repositories for multiple versions of the MSVC runtime to coexist is unsupported
- Declaring multiple repositories for multiple versions of the Windows SDK to coexist is unsupported

## Reproducibility

Visual Studio installer manifest URL is resolved from the channel URL specified by `visual_studio_channel_url` (defaulting to `https://aka.ms/vs/stable/channel`).
That URL resolution is cached in your `MODULE.bazel.lock` to ensure reproducibility.

However, alternatively you could set the Visual Studio installer manifest URL and integrity manually to avoid channel resolution:

```starlark
bazel_dep(name = "windows_support", version = "0.0.1")

msvc_runtime = use_extension("@windows_support//windows:extensions.bzl", "msvc_runtime")
msvc_runtime.configure(
  msvc_version = "14.50.35717",
  visual_studio_installer_manifest_url = "https://download.visualstudio.microsoft.com/download/pr/fdc37f6e-59f6-4054-838a-b476eeaa6ec3/1d82370739911457e0a2f6be15d8b5f569531b352b2eabb961429eea1e99e356/VisualStudio.vsman",
  visual_studio_installer_manifest_integrity = "sha256-qOhU+p8/uurCfXME4pfxZg1xN0ATid61fPeYPzPBb+8=",
)
use_repo(msvc_runtime, "msvc_runtime")

windows_sdk = use_extension("@windows_support//windows:extensions.bzl", "windows_sdk")
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

`@windows_sdk` exports a case-insensitive LLVM VFS overlay at `@windows_sdk//:vfsoverlay`.
It mirrors every published file in the exposed `sysroot` and lets Clang/lld resolve the SDK as if the tree were case-insensitive, without mutating the repository contents.

The overlay is relocatable and is generated after the SDK output is pruned, so it only references files that are part of the public repository surface.
If two published SDK paths differ only by case, repository fetching fails because a case-insensitive overlay would be ambiguous.

Consuming toolchains need to add `@windows_sdk//:vfsoverlay` as an action input and pass it to LLVM tools on case-sensitive hosts, for example with Clang's `-vfsoverlay <path>`.

This is the module configuration:

```starlark
windows_sdk = use_extension("@windows_support//windows:extensions.bzl", "windows_sdk")
windows_sdk.configure(
    windows_sdk_version = "10.0.26100.7705",
)
use_repo(windows_sdk, "windows_sdk")
```

## Acknowledgements

- The resolution logic is heavily inspired by [lorenz/winsysroot](https://github.com/lorenz/winsysroot), thank you Lorenz!
