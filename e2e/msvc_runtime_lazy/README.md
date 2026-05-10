# msvc_runtime lazy EULA e2e

This e2e registers the `msvc_runtime` module extension without setting `BAZEL_MSVC_RUNTIME_VISUAL_STUDIO_EULA`.
It verifies that ordinary project targets still build when they do not reference `@msvc_runtime`.
