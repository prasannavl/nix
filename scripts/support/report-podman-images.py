#!/usr/bin/env python3
import json
import re
import signal
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


VERSION_RE = re.compile(r"^v?([0-9]+(?:[._-][0-9]+)*)(.*)$")

if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def parse_args():
    jobs = 16
    color_mode = "auto"
    args = sys.argv[1:]
    idx = 0
    while idx < len(args):
        arg = args[idx]
        if arg in {"--jobs", "-j"}:
            if idx + 1 >= len(args):
                die(f"Missing value for {arg}")
            try:
                jobs = int(args[idx + 1])
            except ValueError:
                die("--jobs must be a positive integer")
            if jobs < 1:
                die("--jobs must be a positive integer")
            idx += 2
            continue
        if arg == "--ansi":
            color_mode = "always"
            idx += 1
            continue
        if arg == "--color":
            color_mode = "always"
            idx += 1
            continue
        if arg.startswith("--color="):
            color_mode = arg.split("=", 1)[1]
            idx += 1
            continue
        if arg in {"--help", "-h"}:
            print("Usage: report-podman-images.py [--jobs N] [--ansi|--color=WHEN]")
            sys.exit(0)
        die(f"Unknown argument: {arg}")
    if color_mode not in {"auto", "always", "never"}:
        die("--color must be one of: auto, always, never")
    return jobs, color_mode


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


def floating_line(line, color):
    if color:
        return f"- \033[1;38;2;215;215;215m{line}\033[0m"
    return f"- {line}"


def run_nix_eval():
    expr = (
        "cfgs: builtins.mapAttrs "
        "(_: cfg: { "
        "hostName = cfg.config.networking.hostName; "
        "stackName = cfg._module.specialArgs.stack.stackName or \"\"; "
        "podmanSources = builtins.mapAttrs "
        "(_: stack: builtins.mapAttrs "
        "(_: inst: inst.source) stack.instances) "
        "cfg.config.services.\"podman-compose\"; "
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
        die(result.stderr.strip() or "Failed to evaluate podman-compose sources")
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


def collect_images_by_context(sources):
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
            images = contexts.setdefault(context, set())
            for source in instances.values():
                images.update(images_from_source(source))
    return {
        context: sorted(images)
        for context, images in contexts.items()
        if images
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
    url = (
        "https://auth.docker.io/token?"
        + urllib.parse.urlencode(
            {
                "service": "registry.docker.io",
                "scope": f"repository:{repository}:pull",
            }
        )
    )
    return request_json(url).get("token")


def ghcr_token(repository):
    url = (
        "https://ghcr.io/token?"
        + urllib.parse.urlencode({"scope": f"repository:{repository}:pull"})
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


def latest_comparable_tag(current, tags):
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


def is_variable_tag(tag):
    return "$" in tag


def is_floating_tag(tag):
    return tag in {"latest", "main", "alpine", "release", "rocm"} or re.match(
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


def image_report_line(ref, color):
    registry, repository, display_name, tag, digest = parse_image_ref(ref)
    if digest is not None:
        return f"- {display_name}: {tag}@{digest} [latest]"

    if is_variable_tag(tag):
        return floating_line(f"{display_name}: {tag} [variable tag]", color)
    if is_floating_tag(tag):
        return floating_line(f"{display_name}: {tag} [floating tag]", color)
    try:
        tags = registry_tags(registry, repository)
        latest = latest_comparable_tag(tag, tags)
    except Exception:
        latest = tag

    if latest is None:
        return f"- {display_name}: {tag} [latest]"
    if latest == tag:
        return f"- {display_name}: {tag} [latest]"
    line = f"{display_name}: {tag} -> {latest}"
    if is_attention_update(tag, latest):
        return attention_line(line, color)
    return update_line(line, color)


def image_context_key(context):
    stack_name, host_name, podman_stack = context
    has_stack = bool(stack_name)
    return (has_stack, stack_name, host_name, podman_stack)


def format_context(context):
    stack_name, host_name, podman_stack = context
    if not stack_name:
        return ""
    return f"{stack_name} | {host_name} | {podman_stack}"


def main():
    jobs, color_mode = parse_args()
    color = use_color(color_mode)
    contexts = collect_images_by_context(run_nix_eval())
    first_context = True
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        for context in sorted(contexts, key=image_context_key):
            header = format_context(context)
            if not first_context:
                print("", flush=True)
            first_context = False
            if header:
                print(title_line(header, color), flush=True)
            futures = [
                executor.submit(image_report_line, image, color)
                for image in contexts[context]
            ]
            for future in as_completed(futures):
                print(future.result(), flush=True)


if __name__ == "__main__":
    main()
