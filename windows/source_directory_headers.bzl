"""Headers exposed as one source directory with their DirectoryInfo."""

load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")

def _source_directory_headers_impl(ctx):
    return [
        ctx.attr.directory[DirectoryInfo],
        DefaultInfo(files = ctx.attr.source_directory[DefaultInfo].files),
    ]

source_directory_headers = rule(
    implementation = _source_directory_headers_impl,
    doc = "Returns the DirectoryInfo of `directory` and the single source directory of `source_directory`.",
    attrs = {
        "directory": attr.label(mandatory = True, providers = [DirectoryInfo], doc = "Directory whose DirectoryInfo is forwarded."),
        "source_directory": attr.label(mandatory = True, doc = "Filegroup holding the same directory as a source directory."),
    },
    provides = [DirectoryInfo],
    cfg = config.none(),
)
