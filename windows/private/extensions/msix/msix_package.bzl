"""Implementation of the `msix_package` rule."""

MsixPackageInfo = provider(
    doc = "An MSIX (or APPX) package, built by `msix_package`.",
    fields = {
        "package": "File: the unsigned `.msix` (or `.appx`) package.",
    },
)

def _msix_package_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name + ".msix")

    args = ctx.actions.args()
    args.add("pack")
    args.add("-d", ctx.file.layout_dir.path)
    args.add("-p", out)

    ctx.actions.run(
        executable = ctx.executable.makemsix,
        arguments = [args],
        inputs = [ctx.file.layout_dir],
        outputs = [out],
        mnemonic = "MsixPack",
        progress_message = "Packing MSIX package %{output}",
        toolchain = None,
    )

    return [
        DefaultInfo(files = depset([out])),
        MsixPackageInfo(package = out),
    ]

msix_package = rule(
    implementation = _msix_package_impl,
    doc = """Packs a directory into an MSIX (or APPX) package with `makemsix pack -d <layout> -p <package>`.

The package content (its "layout") is the `layout_dir` directory, packaged as is. It must have an
`AppxManifest.xml` at its root, makemsix validates it and generates `AppxBlockMap.xml` and
`[Content_Types].xml`.

Inputs are only read: their permissions and timestamps are never modified. File
permissions are not recorded in the package, the MSIX format does not store them.

The package is not signed, sign it with `signtool` before installing it on Windows.

Limitations, inherited from makemsix:

- the package is not reproducible: makemsix stamps entries with the current time, and orders
  them by the modification time of the layout files;
- the layout must not contain symlinked directories;
- a source directory given as `layout_dir` is packaged with everything it contains on disk, prefer a
  tree artifact.

Example:

```starlark
load("@windows_support//windows:msix.bzl", "msix_package")

msix_package(
    name = "my_app",
    layout_dir = ":my_app_layout",
)
```

The rule provides `MsixPackageInfo`, with the package.
""",
    provides = [MsixPackageInfo],
    attrs = {
        "layout_dir": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = """The layout directory, packaged as is: a tree artifact (`ctx.actions.declare_directory`) or a source
directory. It must have an `AppxManifest.xml` at its root.""",
        ),
        "makemsix": attr.label(
            default = "@msix_packaging//:makemsix",
            executable = True,
            cfg = "exec",
            doc = "The makemsix tool.",
        ),
        "out": attr.string(
            doc = "Name of the package file, defaults to `<name>.msix`. Use the `.appx` extension for an APPX package.",
        ),
    },
)
