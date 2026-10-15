"""Rules for MSIX packages.

Packs a directory into an MSIX (or APPX) package with `makemsix`.
"""

load(
    "//windows/private/extensions/msix:msix_package.bzl",
    _MsixPackageInfo = "MsixPackageInfo",
    _msix_package = "msix_package",
)

MsixPackageInfo = _MsixPackageInfo
msix_package = _msix_package
