"""
Extensions for bzlmod.
"""

# load(":repositories.bzl", "tsconfig_repository")

def _tsconfig_impl(ctx):
    # tsconfig_repository(name = "tsconfig")
    return ctx.extension_metadata()

tsconfig = module_extension(
    implementation = _tsconfig_impl,
)
