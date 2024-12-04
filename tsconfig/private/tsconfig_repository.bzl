"""
Tsconfig repository rule.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")

def _resolve_extends(pnpm_lock_importers, tsconfig_from_path, extends):
    """
    Resolve a path from tsconfig's "extends" field.
    """
    tsconfig_from_dir = paths.dirname(tsconfig_from_path)
    if extends.startswith("."):
        return paths.normalize(paths.join(tsconfig_from_dir, extends))

    package_name = "/".join(extends.split("/")[0:2]) if extends.startswith("@") else extends[0]
    package_submodule = extends.removeprefix(package_name + "/") if extends.startswith(package_name + "/") else ""

    importer = pnpm_lock_importers[tsconfig_from_dir] if tsconfig_from_dir in pnpm_lock_importers else fail("Could not find package {tsconfig_from_dir} in pnpm-lock.yaml".format(tsconfig_from_dir = tsconfig_from_dir))

    dependencies = importer["dependencies"] if "dependencies" in importer else {}
    dev_dependencies = importer["devDependencies"] if "devDependencies" in importer else {}
    for (name, details) in dependencies.items() + dev_dependencies.items():
        if name == package_name:
            version = details["version"]
            if not version.startswith("link:"):
                fail()

            # At the limit this should read package.json and respect "exports"…
            return paths.normalize(paths.join(tsconfig_from_dir, version.removeprefix("link:"), package_submodule))

    fail("Failed to resolve '\"extends\": \"{extends}\"' from {tsconfig_from_path}".format(extends = extends, tsconfig_from_path = tsconfig_from_path))

def _decode_json_with_comments(contents):
    """
    Decode a JSON string with '//' comments

    TODO: Handle '/* */' style comments and '//' comments at the end of lines. Sure would be easier
    if starlark supported regular expressions…
    """
    return json.decode("\n".join([line for line in contents.split("\n") if not line.strip().startswith("//")]))

def _merge_tsconfigs(base, child):
    """
    Implement tsconfig "extends".
    """
    if base == None:
        merged = dict(child)
        merged.pop("extends", None)
        return merged

    merged = dict(base)

    # Project references are not extended
    merged.pop("references", None)

    for (key, value) in child.items():
        if key not in merged or key in ["files", "include", "exclude"]:
            merged[key] = value
        elif type(value) == "dict":
            merged[key] = dict(merged[key]) if key in merged else {}
            merged[key].update(value.items())
        else:
            fail()

    merged.pop("extends", None)
    return merged

def _tsconfig_repository(rctx):
    """
    Tsconfig repository rule.
    """

    # Read pnpm-lock.yaml for information about in-repo packages
    pnpm_lock_path = rctx.workspace_root.get_child(rctx.attr.pnpm_lock)
    rctx.watch(pnpm_lock_path)
    res = rctx.execute([rctx.path(Label("@yq//:yq")), "-ojson", ".importers", pnpm_lock_path], working_directory = str(rctx.workspace_root))
    if res.return_code != 0:
        fail("Failed to parse {pnpm_lock_path}:\n{stderr}".format(pnpm_lock_path = pnpm_lock_path, stderr = res.stderr))
    pnpm_lock_importers = json.decode(res.stdout)

    # Load all of the tsconfig.json files and flatten them
    tsconfig_raw_cache = {}
    tsconfig_flattened_cache = {}
    for (pkg, _) in pnpm_lock_importers.items():
        pkg = "" if pkg == "." else pkg
        tsconfig_path = paths.join(pkg, "tsconfig.json")
        if not rctx.workspace_root.get_child(tsconfig_path).exists:
            continue

        # Starlark doesn't support recursion, so we have to do this iteratively with a max depth
        extends = []
        for _ in range(rctx.attr.max_depth):
            extends.append(tsconfig_path)
            if not tsconfig_path in tsconfig_raw_cache:
                tsconfig_raw_cache[tsconfig_path] = _decode_json_with_comments(rctx.read(rctx.workspace_root.get_child(tsconfig_path)))
            tsconfig = tsconfig_raw_cache[tsconfig_path]

            if "extends" in tsconfig:
                tsconfig_path = _resolve_extends(pnpm_lock_importers, tsconfig_path, tsconfig["extends"])
            else:
                tsconfig_path = None
                break

        if tsconfig_path != None:
            fail("Max 'extends' depth of {max_depth} exceeded".format(max_depth = rctx.attr.max_depth))

        # Flatten and resolve tsconfig files
        base_tsconfig = None
        for tsconfig_path in reversed(extends):
            if tsconfig_path in tsconfig_flattened_cache:
                base_tsconfig = tsconfig_flattened_cache[tsconfig_path]
            else:
                tsconfig = tsconfig_raw_cache[tsconfig_path]
                tsconfig_flattened_cache[tsconfig_path] = _merge_tsconfigs(base_tsconfig, tsconfig)
                base_tsconfig = tsconfig_flattened_cache[tsconfig_path]

    rctx.file("WORKSPACE.bazel", "")
    rctx.file(
        "defs.bzl",
        """
_cache = json.decode(\"\"\"{tsconfig_flattened_cache}\"\"\")

def load_tsconfig(tsconfig_path):
    \"\"\"Load a flattened tsconfig\"\"\"

    if tsconfig_path not in _cache:
        fail("Could not find tsconfig: %s" % tsconfig_path)
    return _cache[tsconfig_path]
        """.format(tsconfig_flattened_cache = json.encode(tsconfig_flattened_cache)).strip(),
    )

    for key in tsconfig_flattened_cache.keys():
        rctx.file(
            paths.replace_extension(key, ".bzl"),
            """
load("//:defs.bzl", "load_tsconfig")

tsconfig = load_tsconfig("{key}")
            """.format(key = key).strip(),
        )

    for buildBazel in (depset([paths.join(paths.dirname(k), "BUILD.bazel") for k in tsconfig_flattened_cache.keys()] + ["BUILD.bazel"]).to_list()):
        rctx.file(buildBazel, "")

tsconfig_repository = repository_rule(
    implementation = _tsconfig_repository,
    attrs = {
        "pnpm_lock": attr.string(default = "pnpm-lock.yaml"),
        "max_depth": attr.int(default = 10),
    },
)
