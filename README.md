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

# Warning: using the generated `@msvc_runtime` repository requires the machine to have the right to use the MSVC runtime, see section below for more information.
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

The generated repositories expose their resolved version information as public Starlark constants:

```starlark
load(
    "@msvc_runtime//:versions.bzl",
    "MSVC_COMPATIBILITY_VERSION",
    "MSVC_TOOLSET_VERSION",
    "VC_REDIST_VERSION",
)
load(
    "@windows_sdk//:versions.bzl",
    "WINDOWS_SDK_INCLUDE_VERSION",
    "WINDOWS_SDK_VERSION",
)
```

`MSVC_TOOLSET_VERSION` is the selected `Contents/VC/Tools/MSVC/<version>` directory. `MSVC_COMPATIBILITY_VERSION` is the corresponding compiler version accepted by Clang's `-fms-compatibility-version`. `VC_REDIST_VERSION` is discovered independently because the redistributable payload may have a different build version. `WINDOWS_SDK_VERSION` is the selected NuGet package version, while `WINDOWS_SDK_INCLUDE_VERSION` is discovered from the extracted include tree.

### About `msvc_runtime` license requirement

Using files from the generated `@msvc_runtime` repository requires the machine using the `windows` module to have the right to use the MSVC (Microsoft Visual Studio C+) runtime headers and libraries.
This is guarded by the user-defined `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA` environment variable.

To use `@msvc_runtime` targets:

1. ensure that your machine is legally allowed to use the MSVC runtime
2. set the environment variable `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA` to `1`, e.g. via `--repo_env=BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA=1`

See https://visualstudio.microsoft.com/license-terms for more information.

### VC redistributable DLLs

`@msvc_runtime` also exposes the Visual C++ redistributable runtime DLLs (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140*.dll`, `concrt140.dll`, `vcomp140.dll`, `vcamp140.dll`, ...), which binaries built against the dynamic CRT (`/MD`) need at runtime:

- `@msvc_runtime//:vc_redist` — release redist DLLs for the target platform (selects between the targets below)
- `@msvc_runtime//:vc_redist_x64` / `@msvc_runtime//:vc_redist_arm64` — per-architecture release redist DLLs
- `@msvc_runtime//:vc_redist_debug` (and `:vc_redist_debug_x64` / `:vc_redist_debug_arm64`) — debug CRT DLLs (`vcruntime140d.dll`, `msvcp140d.dll`, ...), needed to run binaries built against the debug CRT (`/MDd`). ⚠️ These are **not redistributable** per the Visual Studio license: use them for development and testing only, never ship them.

For example, to package the redist DLLs next to a binary:

```starlark
load("@rules_pkg//pkg:zip.bzl", "pkg_zip")

pkg_zip(
    name = "my_app_dist",
    srcs = [
        ":my_app",
        "@msvc_runtime//:vc_redist",
    ],
)
```

Notes:

- the redist DLLs only exist for the `x64`, `x86` and `arm64` architectures (no VC redistributable exists for `arm` or `arm64ec`, the latter uses the x64/arm64 redists)
- only the desktop flavor of the redist is exposed, the `onecore` flavor is not kept

### Tool binaries

By default only headers and libraries are kept. Set `include_binaries = True` to also keep the tools:

```starlark
msvc_runtime.configure(
  msvc_version = "14.50.35717",
  include_binaries = True,
)

windows_sdk.configure(
    windows_sdk_version = "10.0.26100.7705",
    include_binaries = True,
)
```

- `@msvc_runtime//:msvc_tools_<host>_<target>` — `Contents/VC/Tools/MSVC/<version>/bin/Host<host>/<target>` (`cl.exe`, `link.exe`, `lib.exe`, ...)
- `@windows_sdk//:winsdk_bin_<host>` — `base/c/bin/<version>/<host>` (`rc.exe`, `mt.exe`, ...)

Both follow the `architectures` attribute: `<host>` and `<target>` are taken from it, so list the build machine architecture there too.
A target is empty if the downloaded packages do not ship that host.

The tools are not statically linked. The DLLs they need besides Windows system DLLs (`c1.dll`, `c2.dll`, `mspdb140.dll`, `vcruntime140.dll`, `msvcp140.dll`, `rcdll.dll`, ...) ship in the same directory, and Windows loads them from the directory of the executable.
So depend on the whole filegroup (e.g. as `tools` of an action) and run the executable from its location in it, do not copy it out alone.

## Limitations

Sadly, that module is not perfect, there are several major limitations:

- Case-sensitive systems are poorly supported by the inefficient `transformations` attribute, we plan to support `vfsoverlay` configuration in the future [see #3](https://github.com/hermeticbuild/windows_support/issues/3)
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

This is an example on how case-sensitive filesystems can be supported.
This example does two things:

- naively lowercases (while keeping originals) headers and libraries files, either by symlinking (if supported) or copying them
- transforms (while keeping originals) to some cased variant observed in some C sources in the wild, either by symlinking (if supported) or copying them

```starlark
windows_sdk = use_extension("@windows_support//windows:extensions.bzl", "windows_sdk")
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
