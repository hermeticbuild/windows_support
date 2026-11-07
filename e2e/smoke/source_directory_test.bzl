"""Checks that the Windows SDK include targets are source directories."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")

def _source_directory_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    if len(files) == 1:
        asserts.true(env, files[0].is_source, files[0].path + " is not a source file")
        asserts.equals(env, target[DirectoryInfo].path, files[0].path)
    return analysistest.end(env)

source_directory_test = analysistest.make(_source_directory_test_impl)
