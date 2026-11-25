"""Managed project inputs, stock Compose resolution and owner-local acquisition."""

import argparse
import asyncio
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

EMPTY, MISSING = 10, 11
DEFAULT_VARIANT = {"arm64": "v8", "amd64": "v1"}


def matches(ref, platform):
    inspect = ["podman", "image", "inspect", "--", ref]
    found = subprocess.run(inspect, capture_output=True, text=True)
    if found.returncode:
        return False
    (image,) = json.loads(found.stdout)
    os_name, arch, *variant = platform.split("/")
    if (os_name, arch) != (image["Os"], image["Architecture"]):
        return False
    if not variant:
        return True
    # Podman 5.8 inspect omits Variant. Read the selected ID's OCI config,
    # never a registry reference; ordinary os/arch requirements need no read.
    config = subprocess.check_output(
        ["skopeo", "inspect", "--config", "containers-storage:@" + image["Id"]]
    )
    actual = json.loads(config).get("variant") or DEFAULT_VARIANT.get(arch)
    return variant == [actual]


def cached(ref, platform, native):
    # Common case: one local inspect, no subprocess per container replica.
    if platform == native and matches(ref, platform):
        return True
    status = subprocess.run(["podman", "image", "exists", "--", ref]).returncode
    if status == 1:
        return False
    if status:
        sys.exit(f"cannot query owner image store for {ref} (status {status})")
    # Select the manifest instance locally. An architecture mismatch can be a
    # Podman warning rather than an error, so verify the selected ID as well.
    select = ["podman", "pull", "--policy=never", f"--platform={platform}", "--", ref]
    found = subprocess.run(select, capture_output=True, text=True)
    if not found.returncode and matches(found.stdout.strip(), platform):
        return True
    sys.exit(
        f"{ref}: cached image cannot supply {platform}; use distinct platform digests"
    )


def acquire(action, remote):
    if action == "list":
        print(
            json.dumps([{"image": r, "platform": p or None} for r, p in sorted(remote)])
        )
        return 0
    if not remote:
        return EMPTY if action == "probe" else 0
    native = os.environ["NIX_PODMAN_NATIVE_PLATFORM"]
    targets = sorted({(ref, platform or native) for ref, platform in remote})

    def tag_key(ref):
        # A registry port is not a tag. Digests have no implicit latest tag.
        return ref if "@" in ref or ":" in ref.rsplit("/", 1)[-1] else ref + ":latest"

    variants = {}
    for ref, platform in targets:
        variants.setdefault(tag_key(ref), set()).add(platform)
    missing = {}
    for ref, platform in targets:
        if not cached(ref, platform, native):
            needs = variants[tag_key(ref)]
            # An explicit OCI baseline satisfies the unqualified platform too.
            # Fetch the stricter requirement; retain both postconditions.
            os_arch = "/".join(platform.split("/")[:2])
            arch = os_arch.rsplit("/", 1)[-1]
            baseline = f"{os_arch}/{DEFAULT_VARIANT.get(arch, '')}"
            if baseline in needs and needs <= {os_arch, baseline}:
                platform = baseline
            elif len(needs) > 1:
                sys.exit(f"{ref}: use distinct platform digests for {sorted(needs)}")
            missing.setdefault(platform, set()).add(ref)
    if action == "probe" or not missing:
        return MISSING if missing else 0
    for index, (platform, names) in enumerate(missing.items()):
        refs = sorted(names)
        # Short-name resolution and registry aliases belong to Podman. A
        # preceding platform batch may have populated this name indirectly.
        if index:
            refs = [ref for ref in refs if not cached(ref, platform, native)]
        if refs:
            flags = [] if platform == native else [f"--platform={platform}"]
            if subprocess.run(
                ["podman", "pull", "--policy=missing", *flags, "--", *refs]
            ).returncode:
                return 1
    for ref, platform in targets:
        if not cached(ref, platform, native):
            sys.exit(f"{ref}: missing after successful pull")
    return 0


def project_flags(metadata, legacy_stop=False):
    from podman_compose import dotenv_to_dict

    # Only project settings belong here. Engine, files and lifecycle operations
    # are managed; arbitrary passthrough would split supervision from startup.
    parser = argparse.ArgumentParser(
        prog="composeArgs", allow_abbrev=False, add_help=False
    )
    parser.add_argument("--env-file")
    parser.add_argument("-p", "--project-name")
    parser.add_argument("--profile", action="append", default=[])
    parser.add_argument("--in-pod")
    parser.add_argument("--parallel", type=int)
    parser.add_argument("--no-ansi", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    if legacy_stop:
        # The old unit passed these options verbatim and let stock Compose read
        # its working-directory dotenv. Never use this mode to plan or start.
        parser.add_argument("--pod-args")
        flags = metadata.get("composeArgs", [])
        parser.parse_args(flags)  # refuse unprovable engine/store overrides
        return flags
    args = parser.parse_args(metadata.get("composeArgs", []))

    root = Path(metadata["workingDir"])
    staged = {Path(f["dst"]): f["src"] for f in metadata.get("stagedFiles", [])}
    files = metadata.get("composeFiles", [])
    if args.env_file is not None:
        path = root / args.env_file
        if path not in staged:
            sys.exit(f"--env-file {path} must be declared in project files")
        env = staged[path]
    else:
        entry = Path(files[0]).parent if files else root
        candidates = {
            staged[path] for path in (root / ".env", entry / ".env") if path in staged
        }
        if len(candidates) > 1:
            sys.exit("two project .env files declared; select one with --env-file")
        env = next(iter(candidates), os.devnull)
    # Stock Compose exports PODMAN_* from dotenv into its engine subprocess.
    # Direct engine calls must not acquire a different connection or store.
    if env != os.devnull and not Path(env).is_file():
        sys.exit(f"declared project env file is unavailable: {env}")
    if any(k.startswith("PODMAN_") for k in dotenv_to_dict(env)):
        sys.exit("declare PODMAN_* in serviceOverrides.environment, not dotenv")
    flags = ["--env-file", env]
    for name in ("project_name", "in_pod", "parallel"):
        value = getattr(args, name)
        if value is not None:
            flags.extend(["--" + name.replace("_", "-"), str(value)])
    for profile in args.profile:
        flags.extend(["--profile", profile])
    for name in ("no_ansi", "verbose"):
        if getattr(args, name):
            flags.append("--" + name.replace("_", "-"))
    return flags


def file_flags(files):
    return [arg for path in files for arg in ("-f", path)]


def resolve(flags, files):
    from podman_compose import podman_compose

    asyncio.run(
        podman_compose.run(
            ["--dry-run", *flags, *file_flags(files), "config", "--quiet"]
        )
    )
    return podman_compose


def managed_project(flags, files, archives, candidate_root=None):
    project = resolve(flags, files)
    if candidate_root is not None:
        # Stock appends includes to its file list and retains resolved extends
        # paths on services. Check logical paths, not linkFarm symlink targets.
        inputs = [*project.global_args.file]
        for service in project.services.values():
            if path := service.get("extends", {}).get("file"):
                inputs.append(path)
        for path in inputs:
            if not Path(os.path.abspath(path)).is_relative_to(candidate_root):
                sys.exit(
                    f"Compose input outside candidate project: {path}; "
                    "declare it in files and reference it by relative path"
                )
    services = {c["_service"]: c for c in project.containers}
    policy = {}
    for name, service in services.items():
        # Stock 1.5 hashes insertion order. Preserve the historical override.
        entry = {"pull_policy": "never", "restart": "no"}
        image = service.get("image")
        if image in archives and image != archives[image]:
            entry["image"] = archives[image]
        policy[name] = entry
    override = {"services": policy}
    # Includes can merge *after* command-line files. Validate the final model,
    # not just the generated override. Fail before touching the engine.
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as extra:
        json.dump(override, extra)
        extra.flush()
        project = resolve(flags, [*files, extra.name])
        final = {c["_service"]: c for c in project.containers}
    if project.pods:
        # pod create has no pull=never. A custom pod_args replaces even the
        # provider's default --infra=false; do not allow an unmanaged fetch.
        pod_args = project.resolve_pod_args()
        infra = [arg for arg in pod_args if arg.split("=", 1)[0] == "--infra"]
        if infra != ["--infra=false"] or any(
            arg.split("=", 1)[0] == "--infra-image" for arg in pod_args
        ):
            sys.exit(
                "managed Compose pods require --infra=false and no --infra-image in pod_args"
            )
    if services.keys() != final.keys():
        sys.exit("runtime policy changed the Compose service set")
    for name, entry in policy.items():
        image = services[name].get("image")
        expected = {
            **entry,
            "image": archives.get(image, image),
            "platform": services[name].get("platform"),
        }
        if any(final[name].get(k) != v for k, v in expected.items()):
            sys.exit(
                f"{name}: effective Compose model overrides managed image "
                "policy; list conflicting includes in entryFile instead"
            )
    return override, final.values()


def execute(action, services, archives):
    from podman_compose import is_local

    images = [c for c in services if "image" in c and c.get("x-podman.rootfs") is None]
    local = set(archives) | {c["image"] for c in images if is_local(c)}
    remote = {
        (c["image"], c.get("platform") or "") for c in images if c["image"] not in local
    }
    return acquire(action, remote)


def main(metadata, action, args):
    legacy_stop = action.startswith("legacy-stop-")
    if legacy_stop:
        action = action.removeprefix("legacy-stop-")
        if action not in {"inventory", "provider"}:
            sys.exit("invalid legacy teardown operation")
    flags = project_flags(metadata, legacy_stop)
    if action == "provider":
        program, *argv = args
        if legacy_stop:
            files = file_flags(metadata.get("composeFiles", []))
            if argv not in [
                files + tail for tail in (["stop"], ["down"], ["down", "--volumes"])
            ]:
                sys.exit(
                    "legacy invocation only supports teardown of the declared project"
                )
        os.execv(program, [program, *flags, *argv])
    if action == "inventory":
        files = metadata.get("composeFiles", [])
        os.chdir(metadata["workingDir"])
        project = resolve(flags, files)
        print(
            json.dumps(
                {
                    "project": project.project_name,
                    "workingDir": project.dirname,
                    "services": sorted({c["_service"] for c in project.containers}),
                    "containers": [c["name"] for c in project.containers],
                }
            )
        )
        return 0
    if action not in {"list", "probe", "ensure", "runtime-policy"}:
        sys.exit(f"unknown image operation: {action}")
    runtime = action == "runtime-policy"
    files = metadata.get("composeFiles" if runtime else "pullComposeFiles", [])
    if not files:
        if runtime:
            sys.exit("runtime policy requires staged Compose files")
        return acquire(action, set())
    directory = Path(
        metadata.get("workingDir" if runtime else "pullWorkingDir")
        or Path(files[0]).parent
    )
    os.chdir(directory)
    archives = {
        e[k]: e["runtimeRef"]
        for e in metadata.get("localImages", [])
        for k in ("imageRef", "loadRef", "runtimeRef")
        if e.get(k)
    }
    policy, services = managed_project(
        flags, files, archives, None if runtime else directory
    )
    if runtime:
        print(json.dumps(policy))
        return 0
    return execute(action, services, set(archives.values()))


if __name__ == "__main__":
    if sys.argv[1] in {"--ensure-native", "--verify-native"}:
        action = "ensure" if sys.argv[1] == "--ensure-native" else "probe"
        status = acquire(action, {(ref, "") for ref in sys.argv[2:]})
        if status == MISSING:
            sys.exit(f"native image missing from owner store: {sys.argv[2:]}")
        sys.exit(status)
    with open(sys.argv[1], encoding="utf-8") as source:
        sys.exit(
            main(
                json.load(source),
                sys.argv[2] if len(sys.argv) > 2 else "list",
                sys.argv[3:],
            )
        )
