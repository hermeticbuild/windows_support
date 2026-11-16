"""Rules for MSIX and APPX packages.

Packs a directory into an MSIX package with `msix_package`, or an APPX package with `appx_package`,
both running `makemsix`.
"""

load(
    "//windows/private/extensions/msix:msix_package.bzl",
    _MsixPackageInfo = "MsixPackageInfo",
    _appx_package = "appx_package",
    _msix_package = "msix_package",
)

MsixPackageInfo = _MsixPackageInfo
appx_package = _appx_package
msix_package = _msix_package
