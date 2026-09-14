#!/usr/bin/env python3
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path


VERSION_RE = re.compile(r"^v?([0-9]+(?:[._-][0-9]+)*)(.*)$")
TIMESCALE_PG_TAG_RE = re.compile(
    r"^pg([0-9]+(?:[._-][0-9]+)*)-ts([0-9]+(?:[._-][0-9]+)*)(.*)$"
)
STABLE_BUILD_TAG_RE = re.compile(r"^stable-([0-9]+)(?:-([0-9]+))?$")
RELEASE_TAG_REPOSITORIES = {
    ("ghcr.io", "immich-app/immich-machine-learning"): ("immich-app/immich", ""),
    ("ghcr.io", "immich-app/immich-server"): ("immich-app/immich", ""),
    ("docker.stirlingpdf.com", "stirlingtools/stirling-pdf"): (
        "Stirling-Tools/Stirling-PDF",
        "v",
    ),
}
EVEN_MINOR_STABLE_REPOSITORIES = {
    ("registry-1.docker.io", "library/nginx"),
    ("docker.io", "library/nginx"),
}
IMAGE_DECLARATION_RE = re.compile(
    r'^\s*(?:(?:[A-Za-z0-9_.-]+\.)?image|["\']image["\'])\s*[:=]'
)


@dataclass(frozen=True)
class ImageCheck:
    ref: str
    display_name: str
    current: str
    latest: str | None
    state: str
    error: str = ""


@dataclass(frozen=True)
class TextEdit:
    path: Path
    start: int
    end: int
    replacement: str


if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def positive_integer(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Report or update declared Podman Compose image pins."
    )
    parser.add_argument("--jobs", "-j", type=positive_integer, default=16)
    parser.add_argument("--report", action="store_true", help="report without writing")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="resolve and validate updates without writing",
    )
    parser.add_argument("--ansi", action="store_true")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    args = parser.parse_args(argv)
    if args.report and args.dry_run:
        parser.error("--report and --dry-run are mutually exclusive")
    if args.ansi:
        args.color = "always"
    return args


def use_color(color_mode):
    if color_mode == "always":
        return True
    if color_mode == "never":
        return False
    return sys.stdout.isatty()


def update_line(line, color):
    if color:
        return f"- \033[1;38;2;232;170;117m{line}\033[0m"
    return f"- {line}"


def attention_line(line, color):
    if color:
        return f"- \033[1;38;2;255;150;150m{line}\033[0m"
    return f"- {line}"


def title_line(line, color):
    if color:
        return f"\033[1;38;2;255;255;255m{line}\033[0m"
    return line


def boundary_prefix(line, color):
    if color:
        return f"\033[38;2;151;190;205m{line}\033[0m"
    return line


def floating_line(line, color):
    if color:
        return f"- \033[1;38;2;215;215;215m{line}\033[0m"
    return f"- {line}"


def run_nix_eval():
    expr = (
        "cfgs: builtins.mapAttrs "
        "(_: cfg: { "
        "hostName = cfg.config.networking.hostName; "
        'stackName = cfg._module.specialArgs.stack.stackName or ""; '
        "repoSource = toString cfg._module.specialArgs.inputs.self.outPath; "
        "definitions = map "
        "(definition: { "
        "file = definition.file; "
        "instances = builtins.mapAttrs "
        "(_: stack: builtins.attrNames (stack.instances or {})) "
        "definition.value; "
        '}) cfg.options.services."podman-compose".definitionsWithLocations; '
        "podmanSources = builtins.mapAttrs "
        "(_: stack: builtins.mapAttrs "
        "(_: inst: { "
        "source = inst.renderedSource or inst.source; "
        "sourcePath = if builtins.isPath inst.source then toString inst.source else null; "
        "}) stack.instances) "
        'cfg.config.services."podman-compose"; '
        "}) cfgs"
    )
    result = subprocess.run(
        [
            "nix",
            "--no-warn-dirty",
            "eval",
            "--json",
            "--apply",
            expr,
            ".#nixosConfigurations",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip() or "Failed to evaluate podman-compose sources"
        )
    return json.loads(result.stdout)


def images_from_yaml_text(text):
    images = []
    for line in text.splitlines():
        match = re.match(r"^\s*image:\s*['\"]?([^'\"\s]+)['\"]?\s*$", line)
        if match:
            images.append(match.group(1))
    return images


def images_from_source(source):
    if source is None:
        return []
    if isinstance(source, str):
        return images_from_yaml_text(source)
    if not isinstance(source, dict):
        return []

    services = source.get("services")
    if not isinstance(services, dict):
        return []

    images = []
    for service in services.values():
        if isinstance(service, dict) and isinstance(service.get("image"), str):
            images.append(service["image"])
    return images


def reportable_image(image):
    return not image.startswith("localhost/nix-local/")


def collect_images_by_context_and_instance(sources):
    contexts = {}
    for host_key, host in sources.items():
        if not isinstance(host, dict):
            continue
        host_name = host.get("hostName") or host_key
        stack_name = host.get("stackName") or ""
        podman_stacks = host.get("podmanSources") or {}
        if not isinstance(podman_stacks, dict):
            continue
        for podman_stack, instances in podman_stacks.items():
            if not isinstance(instances, dict):
                continue
            context = (stack_name, host_name, podman_stack)
            context_instances = contexts.setdefault(context, {})
            for instance_name, instance in instances.items():
                if not isinstance(instance, dict):
                    continue
                images = set(
                    filter(reportable_image, images_from_source(instance.get("source")))
                )
                if images:
                    context_instances[instance_name] = sorted(images)
    return {
        context: dict(sorted(instances.items()))
        for context, instances in contexts.items()
        if instances
    }


def local_source_file(path, repo_source, repo_root):
    if not path or not repo_source:
        return None
    try:
        relative = Path(path).relative_to(repo_source)
    except ValueError:
        return None
    local_path = repo_root / relative
    if local_path.is_dir():
        local_path = local_path / "default.nix"
    if not local_path.is_file():
        return None
    return local_path


def collect_source_files_by_context_and_instance(sources, repo_root):
    contexts = {}
    for host_key, host in sources.items():
        if not isinstance(host, dict):
            continue
        host_name = host.get("hostName") or host_key
        stack_name = host.get("stackName") or ""
        repo_source = host.get("repoSource") or ""

        for definition in host.get("definitions") or []:
            if not isinstance(definition, dict):
                continue
            source_file = local_source_file(
                definition.get("file"), repo_source, repo_root
            )
            if source_file is None:
                continue
            for podman_stack, instance_names in (
                definition.get("instances") or {}
            ).items():
                context = (stack_name, host_name, podman_stack)
                context_instances = contexts.setdefault(context, {})
                for instance_name in instance_names:
                    context_instances.setdefault(instance_name, set()).add(source_file)

        for podman_stack, instances in (host.get("podmanSources") or {}).items():
            if not isinstance(instances, dict):
                continue
            context = (stack_name, host_name, podman_stack)
            context_instances = contexts.setdefault(context, {})
            for instance_name, instance in instances.items():
                if not isinstance(instance, dict):
                    continue
                source_file = local_source_file(
                    instance.get("sourcePath"), repo_source, repo_root
                )
                if source_file is not None:
                    context_instances.setdefault(instance_name, set()).add(source_file)

    return {
        context: {
            instance_name: sorted(source_files)
            for instance_name, source_files in sorted(instances.items())
        }
        for context, instances in contexts.items()
        if instances
    }


def parse_image_ref(ref):
    image = ref
    digest = None
    if "@" in image:
        image, digest = image.rsplit("@", 1)

    slash = image.rfind("/")
    colon = find_tag_separator(image)
    if colon > slash:
        name = image[:colon]
        tag = image[colon + 1 :]
    else:
        name = image
        tag = "latest"

    parts = name.split("/", 1)
    if len(parts) == 1 or (
        "." not in parts[0] and ":" not in parts[0] and parts[0] != "localhost"
    ):
        registry = "registry-1.docker.io"
        repository = f"library/{name}" if len(parts) == 1 else name
    else:
        registry = parts[0]
        repository = parts[1]
        if registry in {"docker.io", "registry-1.docker.io"} and "/" not in repository:
            repository = f"library/{repository}"

    display_name = name
    return registry, repository, display_name, tag, digest


def find_tag_separator(image):
    separator = -1
    parameter_depth = 0
    idx = 0
    while idx < len(image):
        if image.startswith("${", idx):
            parameter_depth += 1
            idx += 2
            continue
        char = image[idx]
        if char == "}" and parameter_depth > 0:
            parameter_depth -= 1
        elif char == ":" and parameter_depth == 0:
            separator = idx
        idx += 1
    return separator


def request_json(url, token=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def dockerhub_token(repository):
    url = "https://auth.docker.io/token?" + urllib.parse.urlencode(
        {
            "service": "registry.docker.io",
            "scope": f"repository:{repository}:pull",
        }
    )
    return request_json(url).get("token")


def ghcr_token(repository):
    url = "https://ghcr.io/token?" + urllib.parse.urlencode(
        {"scope": f"repository:{repository}:pull"}
    )
    try:
        return request_json(url).get("token")
    except urllib.error.HTTPError:
        return None


def quay_tags(repository):
    namespace, _, repo = repository.partition("/")
    if not namespace or not repo:
        return []
    url = f"https://quay.io/api/v1/repository/{namespace}/{repo}/tag/?limit=100&page=1&onlyActiveTags=true"
    data = request_json(url)
    return [tag["name"] for tag in data.get("tags", []) if tag.get("name")]


def latest_release_tag(registry, repository):
    release_source = RELEASE_TAG_REPOSITORIES.get((registry, repository))
    if release_source is None:
        return None
    source_repository, strip_prefix = release_source
    data = request_json(
        f"https://api.github.com/repos/{source_repository}/releases/latest"
    )
    tag = data.get("tag_name")
    if isinstance(tag, str) and tag:
        if strip_prefix and tag.startswith(strip_prefix):
            return tag[len(strip_prefix) :]
        return tag
    return None


def registry_tags(registry, repository):
    if registry == "localhost":
        return []
    if registry in {"docker.io", "registry-1.docker.io"}:
        token = dockerhub_token(repository)
        data = request_json(
            f"https://registry-1.docker.io/v2/{repository}/tags/list", token
        )
        return data.get("tags") or []
    if registry == "ghcr.io":
        token = ghcr_token(repository)
        data = request_json(f"https://ghcr.io/v2/{repository}/tags/list", token)
        return data.get("tags") or []
    if registry == "quay.io":
        return quay_tags(repository)

    data = request_json(f"https://{registry}/v2/{repository}/tags/list")
    return data.get("tags") or []


def version_parts(version):
    return tuple(int(part) for part in re.split(r"[._-]", version))


def timescale_pg_tag_parts(tag):
    match = TIMESCALE_PG_TAG_RE.match(tag)
    if not match:
        return None
    pg_version, timescale_version, suffix = match.groups()
    pg_parts = version_parts(pg_version)
    timescale_parts = version_parts(timescale_version)
    return pg_parts, timescale_parts, suffix


def latest_timescale_pg_tag(current, tags):
    current_parts = timescale_pg_tag_parts(current)
    if current_parts is None:
        return None

    current_pg_parts, current_timescale_parts, current_suffix = current_parts
    comparable = []
    for tag in tags:
        candidate_parts = timescale_pg_tag_parts(tag)
        if candidate_parts is None:
            continue
        pg_parts, timescale_parts, suffix = candidate_parts
        if suffix != current_suffix:
            continue
        if not pg_parts or pg_parts[0] != current_pg_parts[0]:
            continue
        if len(pg_parts) != len(current_pg_parts):
            continue
        if len(timescale_parts) != len(current_timescale_parts):
            continue
        comparable.append(((pg_parts, timescale_parts), tag))

    if not comparable:
        return current
    latest_parts, latest_tag = max(comparable)
    if latest_parts <= (current_pg_parts, current_timescale_parts):
        return current
    return latest_tag


def stable_build_tag_parts(tag):
    match = STABLE_BUILD_TAG_RE.match(tag)
    if not match:
        return None
    build, revision = match.groups()
    return int(build), int(revision or 0)


def latest_stable_build_tag(current, tags):
    current_parts = stable_build_tag_parts(current)
    if current_parts is None:
        return None

    comparable = [
        (parts, tag)
        for tag in tags
        if (parts := stable_build_tag_parts(tag)) is not None
    ]
    if not comparable:
        return current
    latest_parts, latest_tag = max(comparable)
    if latest_parts <= current_parts:
        return current
    return latest_tag


def latest_comparable_tag(current, tags):
    timescale_latest = latest_timescale_pg_tag(current, tags)
    if timescale_latest is not None:
        return timescale_latest

    stable_build_latest = latest_stable_build_tag(current, tags)
    if stable_build_latest is not None:
        return stable_build_latest

    match = VERSION_RE.match(current)
    if not match:
        return None

    current_version, suffix = match.groups()
    current_parts = version_parts(current_version)
    comparable = []
    for tag in tags:
        candidate = VERSION_RE.match(tag)
        if not candidate:
            continue
        version, candidate_suffix = candidate.groups()
        if candidate_suffix != suffix:
            continue
        parts = version_parts(version)
        if len(parts) != len(current_parts):
            continue
        comparable.append((parts, tag))

    if not comparable:
        return current
    latest_parts, latest_tag = max(comparable)
    if latest_parts <= current_parts:
        return current
    return latest_tag


def repository_tags_for_policy(registry, repository, tags):
    if (registry, repository) not in EVEN_MINOR_STABLE_REPOSITORIES:
        return tags

    stable_tags = []
    for tag in tags:
        match = VERSION_RE.match(tag)
        if not match or match.group(2):
            continue
        parts = version_parts(match.group(1))
        if len(parts) >= 2 and parts[1] % 2 == 0:
            stable_tags.append(tag)
    return stable_tags


def is_variable_tag(tag):
    return "$" in tag


def is_floating_tag(tag):
    return tag in {"latest", "main", "alpine", "release", "rocm", "stable"} or re.match(
        r"^pg[0-9]+$", tag
    )


def is_attention_update(current, latest):
    current_match = VERSION_RE.match(current)
    latest_match = VERSION_RE.match(latest)
    if not current_match or not latest_match:
        return False
    current_parts = version_parts(current_match.group(1))
    latest_parts = version_parts(latest_match.group(1))
    if not current_parts or not latest_parts:
        return False
    if latest_parts[0] > current_parts[0]:
        return True
    if (
        current_parts[0] == 0
        and latest_parts[0] == 0
        and not current_match.group(2)
        and not latest_match.group(2)
        and len(current_parts) > 1
        and len(latest_parts) > 1
        and len(current_parts) > 2
        and len(latest_parts) > 2
        and latest_parts[1] > current_parts[1]
    ):
        return True
    return False


def latest_known_tag(registry, repository, tag):
    release_tag = latest_release_tag(registry, repository)
    if release_tag is not None:
        return latest_comparable_tag(tag, [release_tag])
    tags = repository_tags_for_policy(
        registry,
        repository,
        registry_tags(registry, repository),
    )
    return latest_comparable_tag(tag, tags)


def inspect_image(ref):
    registry, repository, display_name, tag, digest = parse_image_ref(ref)
    if digest is not None:
        return ImageCheck(ref, display_name, tag, None, "digest")

    if is_variable_tag(tag):
        return ImageCheck(ref, display_name, tag, None, "variable")
    if is_floating_tag(tag):
        return ImageCheck(ref, display_name, tag, None, "floating")
    try:
        latest = latest_known_tag(registry, repository, tag)
    except Exception as error:
        return ImageCheck(ref, display_name, tag, None, "failed", str(error))

    if latest is None:
        return ImageCheck(ref, display_name, tag, None, "uncomparable")
    if latest == tag:
        return ImageCheck(ref, display_name, tag, latest, "latest")
    return ImageCheck(ref, display_name, tag, latest, "update")


def format_image_check(check, color):
    if check.state == "digest":
        _, _, _, _, digest = parse_image_ref(check.ref)
        return f"- {check.display_name}: {check.current}@{digest} [digest pinned]"
    if check.state == "variable":
        return floating_line(
            f"{check.display_name}: {check.current} [variable tag]", color
        )
    if check.state == "floating":
        return floating_line(
            f"{check.display_name}: {check.current} [floating tag]", color
        )
    if check.state == "failed":
        return attention_line(
            f"{check.display_name}: {check.current} [check failed: {check.error}]",
            color,
        )
    if check.state == "uncomparable":
        return f"- {check.display_name}: {check.current} [no comparable tags]"
    if check.state == "latest":
        return f"- {check.display_name}: {check.current} [latest]"

    line = f"{check.display_name}: {check.current} -> {check.latest}"
    if is_attention_update(check.current, check.latest):
        return attention_line(line, color)
    return update_line(line, color)


def image_report_line(ref, color):
    return format_image_check(inspect_image(ref), color)


def prefix_image_report_line(line, instance_name, color):
    if not line.startswith("- "):
        return line
    return f"- {boundary_prefix(instance_name, color)} | {line[2:]}"


def image_context_key(context):
    stack_name, host_name, podman_stack = context
    has_stack = bool(stack_name)
    return (has_stack, stack_name, host_name, podman_stack)


def format_context(context):
    stack_name, host_name, podman_stack = context
    if not stack_name:
        return ""
    return f"{stack_name} | {host_name} | {podman_stack}"


def inspect_images(contexts, jobs):
    refs = sorted(
        {
            ref
            for instances in contexts.values()
            for images in instances.values()
            for ref in images
        }
    )
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        checks = executor.map(inspect_image, refs)
    return dict(zip(refs, checks, strict=True))


def print_inventory(contexts, checks, color):
    first_context = True
    for context in sorted(contexts, key=image_context_key):
        header = format_context(context)
        if not first_context:
            print("", flush=True)
        first_context = False
        if header:
            print(title_line(header, color), flush=True)
        for instance_name, images in contexts[context].items():
            for ref in images:
                print(
                    prefix_image_report_line(
                        format_image_check(checks[ref], color), instance_name, color
                    ),
                    flush=True,
                )


def image_reference_spans(content, ref):
    spans = []
    offset = 0
    for line in content.splitlines(keepends=True):
        if IMAGE_DECLARATION_RE.match(line) and not line.lstrip().startswith("#"):
            index = line.find(ref)
            while index >= 0:
                spans.append((offset + index, offset + index + len(ref)))
                index = line.find(ref, index + len(ref))
        offset += len(line)
    return spans


def quoted_token_spans(content, token):
    pattern = re.compile(rf'(?P<quote>["\']){re.escape(token)}(?P=quote)')
    return [(match.start() + 1, match.end() - 1) for match in pattern.finditer(content)]


def replacement_ref(check):
    registry, repository, display_name, _, digest = parse_image_ref(check.ref)
    del registry, repository
    if digest is not None or check.latest is None:
        raise ValueError(f"{check.ref}: image is not updateable")
    return f"{display_name}:{check.latest}"


def candidate_edits(check, source_files, contents):
    if not source_files:
        raise ValueError(f"{check.ref}: no local owning source file")

    replacement = replacement_ref(check)
    exact_matches = {}
    for path in source_files:
        content = contents.setdefault(path, path.read_text())
        spans = image_reference_spans(content, check.ref)
        if spans:
            exact_matches[path] = spans

    if len(exact_matches) > 1:
        paths = ", ".join(str(path) for path in sorted(exact_matches))
        raise ValueError(f"{check.ref}: declaration is ambiguous across {paths}")
    if exact_matches:
        path, spans = next(iter(exact_matches.items()))
        return [TextEdit(path, start, end, replacement) for start, end in spans]

    quoted_ref_matches = []
    for path in source_files:
        content = contents.setdefault(path, path.read_text())
        quoted_ref_matches.extend(
            (path, start, end) for start, end in quoted_token_spans(content, check.ref)
        )
    if len(quoted_ref_matches) > 1:
        raise ValueError(
            f"{check.ref}: quoted declaration is ambiguous across owning sources"
        )
    if quoted_ref_matches:
        path, start, end = quoted_ref_matches[0]
        return [TextEdit(path, start, end, replacement)]

    tag_matches = []
    for path in source_files:
        content = contents.setdefault(path, path.read_text())
        tag_matches.extend(
            (path, start, end)
            for start, end in quoted_token_spans(content, check.current)
        )
    if len(tag_matches) != 1:
        raise ValueError(
            f"{check.ref}: expected one quoted {check.current!r} pin in owning sources, "
            f"found {len(tag_matches)}"
        )
    path, start, end = tag_matches[0]
    return [TextEdit(path, start, end, check.latest)]


def plan_updates(contexts, source_files, checks):
    contents = {}
    edits = {}
    errors = []
    candidate_cache = {}

    for context in sorted(contexts, key=image_context_key):
        for instance_name, images in contexts[context].items():
            owning_files = source_files.get(context, {}).get(instance_name, [])
            for ref in images:
                check = checks[ref]
                if check.state != "update":
                    continue
                cache_key = (ref, check.latest, tuple(owning_files))
                if cache_key not in candidate_cache:
                    try:
                        candidate_cache[cache_key] = candidate_edits(
                            check, owning_files, contents
                        )
                    except (OSError, ValueError) as error:
                        candidate_cache[cache_key] = error
                result = candidate_cache[cache_key]
                if isinstance(result, Exception):
                    location = format_context(context)
                    errors.append(f"{location} | {instance_name}: {result}")
                    continue
                for edit in result:
                    key = (edit.path, edit.start, edit.end)
                    previous = edits.get(key)
                    if (
                        previous is not None
                        and previous.replacement != edit.replacement
                    ):
                        errors.append(
                            f"{edit.path}: conflicting replacements for "
                            f"{contents[edit.path][edit.start : edit.end]!r}"
                        )
                    else:
                        edits[key] = edit

    return list(edits.values()), contents, sorted(set(errors))


def updated_contents(edits, originals):
    grouped = {}
    for edit in edits:
        grouped.setdefault(edit.path, []).append(edit)

    updates = {}
    for path, path_edits in grouped.items():
        content = originals[path]
        ordered = sorted(path_edits, key=lambda item: item.start)
        for previous, current in zip(ordered, ordered[1:]):
            if current.start < previous.end:
                raise RuntimeError(f"{path}: overlapping image pin replacements")
        for edit in reversed(ordered):
            if content[edit.start : edit.end] == edit.replacement:
                continue
            content = content[: edit.start] + edit.replacement + content[edit.end :]
        updates[path] = content
    return updates


def stage_content(path, content):
    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, path.stat().st_mode & 0o777)
    except Exception:
        os.unlink(temporary)
        raise
    return Path(temporary)


def apply_updates(edits, originals, dry_run=False):
    updates = updated_contents(edits, originals)
    for path, original in originals.items():
        if path in updates and path.read_text() != original:
            raise RuntimeError(f"{path}: changed while updates were being resolved")
    if dry_run:
        return len(updates)

    staged = {}
    try:
        for path, content in updates.items():
            staged[path] = stage_content(path, content)
    except Exception:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)
        raise

    replaced = []
    try:
        for path in sorted(staged):
            os.replace(staged[path], path)
            replaced.append(path)
    except Exception as error:
        rollback_errors = []
        for path in reversed(replaced):
            try:
                os.replace(stage_content(path, originals[path]), path)
            except Exception as rollback_error:
                rollback_errors.append(f"{path}: {rollback_error}")
        detail = "; ".join(rollback_errors)
        if detail:
            raise RuntimeError(
                f"update failed: {error}; rollback failed: {detail}"
            ) from error
        raise RuntimeError(f"update failed and was rolled back: {error}") from error
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)
    return len(updates)


def repository_root():
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.strip())


def main():
    args = parse_args()
    color = use_color(args.color)
    try:
        sources = run_nix_eval()
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    contexts = collect_images_by_context_and_instance(sources)
    checks = inspect_images(contexts, args.jobs)
    print_inventory(contexts, checks, color)

    failed = [check for check in checks.values() if check.state == "failed"]
    if failed:
        return 1
    if args.report:
        return 0

    source_files = collect_source_files_by_context_and_instance(
        sources, repository_root()
    )
    edits, originals, errors = plan_updates(contexts, source_files, checks)
    if errors:
        print("", file=sys.stderr)
        for error in errors:
            print(f"Update error: {error}", file=sys.stderr)
        return 1
    if not edits:
        print("\nNo Podman image updates.")
        return 0

    try:
        changed_files = apply_updates(edits, originals, args.dry_run)
    except (OSError, RuntimeError) as error:
        print(f"Update error: {error}", file=sys.stderr)
        return 1

    action = "Would update" if args.dry_run else "Updated"
    print(f"\n{action} {len(edits)} image pin(s) in {changed_files} file(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
