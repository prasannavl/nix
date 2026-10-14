#!/usr/bin/env python3
"""Generate a bounded G4 test workspace, without invoking Cargo or a builder.

The lock lists declared local dependencies, not resolved compilation units.
Expected role/output values are test expectations, not producer evidence.
Importing this module and calling build_files perform no filesystem I/O.
"""

import argparse
from contextlib import ExitStack
import ctypes
import errno
import os
from pathlib import Path
import shutil
import tomllib


REPOSITORY_ROOT = Path(__file__).absolute().parents[4]
TMP_ROOT = REPOSITORY_ROOT / "tmp"
VARIANTS = ("baseline", "rust-edit", "manifest-edit", "lock-edit")
MEMBER_PATHS = tuple(
    f"members/{member}"
    for member in ("app", "branch", "build-helper", "dev-helper", "leaf", "macro", "peer")
)
APP_PACKAGE_NAME = "g4-app"
EXPECTED_STDOUT = {
    variant: (
        f"source={'leaf-v2' if variant == 'rust-edit' else 'leaf-v1'};"
        "target=normal;build=input-v1:build+macro;macro=build+macro\n"
    )
    for variant in VARIANTS
}
EXPECTED_TARGET_ROLES = "normal"
EXPECTED_TEST_TARGET_ROLES = "normal+dev"
EXPECTED_HOST_ROLES = "build+macro"


def _package_manifest(member: str) -> str:
    return (
        "[package]\n"
        f'name = "g4-{member}"\n'
        'version = "0.1.0"\n'
        'edition = "2021"\n'
    )


def _leaf_dependency(feature: str) -> str:
    return (
        'g4-leaf = { path = "../leaf", version = "0.1.0", '
        f'default-features = false, features = ["{feature}"] }}\n'
    )


def _declared_lock(files: dict[str, str]) -> str:
    """Encode the dependency union of these bounded local Cargo declarations.

    This deliberately does not claim Cargo feature, role or unit resolution.
    No Cargo command is needed to create this dependency-free lockfile.
    """
    packages = []
    for member_path in MEMBER_PATHS:
        manifest = tomllib.loads(files[f"{member_path}/Cargo.toml"])
        package = manifest["package"]
        dependencies = set()
        for scope in ("dependencies", "build-dependencies", "dev-dependencies"):
            dependencies.update(manifest.get(scope, {}))
        packages.append((package["name"], package["version"], sorted(dependencies)))

    lines = [
        "# Generated from this test fixture's declared local dependency union.",
        "# Not a resolved feature/role/unit graph or producer qualification.",
        "version = 4",
    ]
    for name, version, dependencies in sorted(packages):
        lines.extend(["", "[[package]]", f'name = "{name}"', f'version = "{version}"'])
        if dependencies:
            lines.append("dependencies = [")
            lines.extend(f' "{dependency}",' for dependency in dependencies)
            lines.append("]")
    return "\n".join(lines) + "\n"


def build_files(variant: str = "baseline") -> dict[str, bytes]:
    """Return relative file paths and bytes for one deterministic test scenario."""
    if variant not in VARIANTS:
        raise ValueError(f"unknown fixture variant: {variant}")

    root_manifest = '[workspace]\nresolver = "2"\nmembers = [\n'
    root_manifest += "".join(f'    "{member_path}",\n' for member_path in MEMBER_PATHS)
    root_manifest += "]\n"
    files = {"Cargo.toml": root_manifest}
    for member_path in MEMBER_PATHS:
        member = member_path.removeprefix("members/")
        files[f"{member_path}/Cargo.toml"] = _package_manifest(member)

    files["members/leaf/Cargo.toml"] += (
        '\n[features]\ndefault = []\nnormal = []\nbuild = []\nmacro = []\ndev = []\n'
    )
    files["members/branch/Cargo.toml"] += "\n[dependencies]\n" + _leaf_dependency("normal")
    for member, feature in (("build-helper", "build"), ("macro", "macro"), ("dev-helper", "dev")):
        files[f"members/{member}/Cargo.toml"] += "\n[dependencies]\n" + _leaf_dependency(feature)
    files["members/macro/Cargo.toml"] += "\n[lib]\nproc-macro = true\n"
    files["members/app/Cargo.toml"] += (
        '\n[dependencies]\n'
        'g4-branch = { path = "../branch", version = "0.1.0" }\n'
        'g4-macro = { path = "../macro", version = "0.1.0" }\n'
        '\n[build-dependencies]\n'
        'g4-build-helper = { path = "../build-helper", version = "0.1.0" }\n'
        '\n[dev-dependencies]\n'
        'g4-dev-helper = { path = "../dev-helper", version = "0.1.0" }\n'
    )

    files["members/leaf/src/lib.rs"] = '''pub fn source_marker() -> &'static str {
    "leaf-v1"
}

pub fn role_label() -> String {
    let mut roles: Vec<&str> = Vec::new();
    if cfg!(feature = "normal") {
        roles.push("normal");
    }
    if cfg!(feature = "build") {
        roles.push("build");
    }
    if cfg!(feature = "macro") {
        roles.push("macro");
    }
    if cfg!(feature = "dev") {
        roles.push("dev");
    }
    roles.join("+")
}
'''
    files["members/branch/src/lib.rs"] = '''pub fn source_marker() -> &'static str {
    g4_leaf::source_marker()
}

pub fn role_label() -> String {
    g4_leaf::role_label()
}
'''
    for member in ("build-helper", "dev-helper"):
        files[f"members/{member}/src/lib.rs"] = '''pub fn role_label() -> String {
    g4_leaf::role_label()
}
'''
    files["members/macro/src/lib.rs"] = '''extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro]
pub fn host_marker(_input: TokenStream) -> TokenStream {
    let marker = g4_leaf::role_label();
    format!("{:?}", marker).parse().expect("host marker is a Rust string literal")
}
'''
    files["members/app/build-input.txt"] = "input-v1\n"
    files["members/app/build.rs"] = '''fn main() {
    let input = std::fs::read_to_string("build-input.txt").expect("checked-in build input");
    let marker = input.trim();
    assert_eq!(marker, "input-v1");
    println!("cargo:rerun-if-changed=build-input.txt");
    println!("cargo:rustc-env=G4_BUILD_MARKER={}:{}", marker, g4_build_helper::role_label());
}
'''
    files["members/app/src/main.rs"] = '''const BUILD_MARKER: &str = env!("G4_BUILD_MARKER");
const MACRO_MARKER: &str = g4_macro::host_marker!();

fn main() {
    println!(
        "source={};target={};build={};macro={}",
        g4_branch::source_marker(),
        g4_branch::role_label(),
        BUILD_MARKER,
        MACRO_MARKER,
    );
}

#[cfg(test)]
mod tests {
    use super::{BUILD_MARKER, MACRO_MARKER};

    #[test]
    fn target_dev_features_are_separate_from_host_features() {
        assert_eq!(g4_branch::role_label(), "normal+dev");
        assert_eq!(g4_dev_helper::role_label(), "normal+dev");
        assert_eq!(BUILD_MARKER, "input-v1:build+macro");
        assert_eq!(MACRO_MARKER, "build+macro");
    }
}
'''
    files["members/peer/src/lib.rs"] = '''pub fn peer_marker() -> &'static str {
    "peer-v1"
}
'''

    if variant == "rust-edit":
        path = "members/leaf/src/lib.rs"
        files[path] = files[path].replace('"leaf-v1"', '"leaf-v2"')
    elif variant == "manifest-edit":
        files["members/leaf/Cargo.toml"] += "unused-local-probe = []\n"

    files["expected-output.txt"] = EXPECTED_STDOUT[variant]
    files["Cargo.lock"] = _declared_lock(files)
    if variant == "lock-edit":
        # A legitimate global lock-byte edit, not a semantic resolution change.
        files["Cargo.lock"] += "\n# lock-edit: global freshness probe, no resolution change.\n"
    return {path: content.encode("utf-8") for path, content in files.items()}


def _checked_output(output: str | os.PathLike[str]) -> Path:
    """Reject unsafe lexical destinations before any filesystem inspection."""
    raw_path = os.fspath(output)
    if not raw_path or "\x00" in raw_path:
        raise ValueError("output must be a nonempty directory path")
    requested = Path(raw_path)
    if any(part == ".." or part == "secrets" or part.endswith(".key") for part in requested.parts):
        raise ValueError("output must not contain traversal, secrets or key paths")
    destination = Path(os.path.abspath(requested))
    if not destination.is_relative_to(TMP_ROOT) or destination == TMP_ROOT:
        raise ValueError(f"output must be a fresh directory beneath {TMP_ROOT}")
    return destination


def _create_stage(parent: int) -> str:
    """Create a private sibling; never reuse or clean a colliding entry."""
    for _attempt in range(8):
        name = f".g4-fixture-stage-{os.urandom(12).hex()}"
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
        except FileExistsError:
            continue
        return name
    raise FileExistsError("could not allocate a fresh fixture staging directory")


def _publish_noreplace(parent: int, stage: str, destination: str) -> None:
    """Atomically publish on Linux, failing closed if no-replace is unavailable.

    Ordinary rename is not a fallback: it can replace an empty directory that
    appeared after the initial destination check.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameat2 = libc.renameat2
    except AttributeError as error:
        raise OSError(errno.ENOSYS, "Linux renameat2 is required") from error
    renameat2.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    rename_noreplace = 1  # Linux RENAME_NOREPLACE, not RENAME_EXCHANGE.
    result = renameat2(
        parent, os.fsencode(stage), parent, os.fsencode(destination), rename_noreplace
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), destination)


def materialize(output: str | os.PathLike[str], variant: str = "baseline") -> Path:
    """Publish a complete fresh fixture below repository tmp, never overwrite.

    Parents must already exist. Directory-relative, no-follow operations reject
    symlink parents and keep writes relative to opened directories. Write into
    an owned private sibling, then publish with Linux atomic no-replace rename.
    Failures remove only that stage, leaving the destination absent or untouched.
    This generator grants no authority to run builds, including Nix daemon work.
    """
    destination = _checked_output(output)
    files = build_files(variant)
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with ExitStack() as directories:
        def open_directory(name: str | Path, parent: int | None = None) -> int:
            descriptor = os.open(name, directory_flags, dir_fd=parent)
            directories.callback(os.close, descriptor)
            return descriptor

        parent = open_directory(REPOSITORY_ROOT)
        relative_parts = destination.relative_to(REPOSITORY_ROOT).parts
        for part in relative_parts[:-1]:
            parent = open_directory(part, parent)
        destination_name = relative_parts[-1]
        try:
            os.stat(destination_name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise FileExistsError(errno.EEXIST, "destination already exists", destination_name)

        stage = _create_stage(parent)
        published = False
        try:
            owned_root = open_directory(stage, parent)
            created_directories = {"": owned_root}
            for relative_path, content in files.items():
                parts = Path(relative_path).parts
                current = owned_root
                for index, part in enumerate(parts[:-1], start=1):
                    prefix = "/".join(parts[:index])
                    if prefix not in created_directories:
                        os.mkdir(part, mode=0o700, dir_fd=current)
                        created_directories[prefix] = open_directory(part, current)
                    current = created_directories[prefix]
                file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                descriptor = os.open(parts[-1], file_flags, 0o600, dir_fd=current)
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(content)
            _publish_noreplace(parent, stage, destination_name)
            published = True
        finally:
            if not published:
                shutil.rmtree(stage, dir_fd=parent)
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="fresh directory under repository tmp")
    parser.add_argument("--variant", choices=VARIANTS, default="baseline")
    arguments = parser.parse_args(argv)
    try:
        destination = materialize(arguments.output, arguments.variant)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
