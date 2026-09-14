#!/usr/bin/env python3
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


VERSION_RE = re.compile(r"^v?([0-9]+(?:[._-][0-9]+)*)(.*)$")
SUPPORTED_KINDS = {
    "github-branch",
    "github-tags",
    "gitlab-tags",
    "registry-tags",
}


if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Report external package pins from sources.nix files."
    )
    parser.add_argument("sources", nargs="+", type=Path)
    parser.add_argument("--jobs", "-j", type=int, default=16)
    parser.add_argument("--ansi", action="store_true")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be a positive integer")
    if args.ansi:
        args.color = "always"
    return args


def use_color(mode):
    if mode == "always":
        return True
    if mode == "never":
        return False
    return sys.stdout.isatty()


def styled_line(line, color, attention=False):
    if not color:
        return f"- {line}"
    color_code = "1;38;2;255;150;150" if attention else "1;38;2;232;170;117"
    return f"- \033[{color_code}m{line}\033[0m"


def request_json(url, token=None):
    headers = {"Accept": "application/json", "User-Agent": "pvl-update-report"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def load_sources(path):
    result = subprocess.run(
        ["nix", "eval", "--json", "--file", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or "nix eval failed"
        raise RuntimeError(f"{path}: {detail}")
    try:
        sources = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{path}: invalid nix eval JSON: {error}") from error
    if not isinstance(sources, dict):
        raise RuntimeError(f"{path}: sources.nix must evaluate to an attribute set")
    return sources


def load_packages(paths):
    packages = []
    for path in paths:
        for name, source in load_sources(path).items():
            if not isinstance(source, dict):
                raise RuntimeError(f"{path}: {name} must be an attribute set")
            kind = source.get("kind")
            if kind not in SUPPORTED_KINDS:
                supported = ", ".join(sorted(SUPPORTED_KINDS))
                raise RuntimeError(
                    f"{path}: {name} has unsupported report kind {kind!r}; "
                    f"expected one of: {supported}"
                )
            packages.append((name, source))
    return packages


def normalize_tag(tag, prefix=""):
    if prefix and tag.startswith(prefix):
        return tag[len(prefix) :]
    if tag.startswith("v"):
        return tag[1:]
    return tag


def version_parts(version):
    return tuple(int(part) for part in re.split(r"[._-]", version))


def latest_comparable_tag(current, tags):
    match = VERSION_RE.match(current)
    if not match:
        return current
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


def is_attention_update(current, latest):
    current_match = VERSION_RE.match(current)
    latest_match = VERSION_RE.match(latest)
    if not current_match or not latest_match:
        return False
    current_parts = version_parts(current_match.group(1))
    latest_parts = version_parts(latest_match.group(1))
    if latest_parts[0] > current_parts[0]:
        return True
    return (
        current_parts[0] == 0
        and latest_parts[0] == 0
        and not current_match.group(2)
        and not latest_match.group(2)
        and len(current_parts) > 2
        and len(latest_parts) > 2
        and latest_parts[1] > current_parts[1]
    )


def github_tags(source):
    data = request_json(
        f"https://api.github.com/repos/{source['owner']}/{source['repo']}/tags?per_page=100",
        os.environ.get("GITHUB_TOKEN"),
    )
    prefix = source.get("tagPrefix", "")
    return [normalize_tag(tag["name"], prefix) for tag in data if tag.get("name")]


def github_branch_rev(source):
    data = request_json(
        f"https://api.github.com/repos/{source['owner']}/{source['repo']}/commits/{source['ref']}",
        os.environ.get("GITHUB_TOKEN"),
    )
    return data["sha"][:12]


def gitlab_tags(source):
    project = urllib.parse.quote(source["project"], safe="")
    data = request_json(
        f"https://gitlab.com/api/v4/projects/{project}/repository/tags?per_page=100"
    )
    prefix = source.get("tagPrefix", "")
    return [normalize_tag(tag["name"], prefix) for tag in data if tag.get("name")]


def dockerhub_token(repository):
    query = urllib.parse.urlencode(
        {
            "service": "registry.docker.io",
            "scope": f"repository:{repository}:pull",
        }
    )
    return request_json(f"https://auth.docker.io/token?{query}")["token"]


def registry_tags(source):
    registry = source["registry"]
    repository = source["repository"]
    token = dockerhub_token(repository) if registry == "registry-1.docker.io" else None
    data = request_json(f"https://{registry}/v2/{repository}/tags/list", token)
    return data.get("tags") or []


def current_value(source):
    if source["kind"] == "github-branch":
        return source["rev"][:12]
    return source["version"]


def latest_value(source, current):
    kind = source["kind"]
    if kind == "github-branch":
        return github_branch_rev(source)
    if kind == "github-tags":
        return latest_comparable_tag(current, github_tags(source))
    if kind == "gitlab-tags":
        return latest_comparable_tag(current, gitlab_tags(source))
    if kind == "registry-tags":
        return latest_comparable_tag(current, registry_tags(source))
    raise RuntimeError(f"unsupported report kind: {kind}")


def report_package(name, source, color):
    current = current_value(source)
    try:
        latest = latest_value(source, current)
    except (
        KeyError,
        RuntimeError,
        TimeoutError,
        urllib.error.HTTPError,
        urllib.error.URLError,
    ) as error:
        return styled_line(f"{name}: {current} [check failed: {error}]", color, True), False
    if latest == current:
        return f"- {name}: {current} [latest]", True
    return styled_line(
        f"{name}: {current} -> {latest}",
        color,
        is_attention_update(current, latest),
    ), True


def main():
    args = parse_args()
    try:
        packages = load_packages(args.sources)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1

    color = use_color(args.color)
    status = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {
            executor.submit(report_package, name, source, color): name
            for name, source in packages
        }
        results = []
        for future in as_completed(futures):
            line, ok = future.result()
            results.append((futures[future], line))
            if not ok:
                status = 1
    for _, line in sorted(results):
        print(line)
    return status


if __name__ == "__main__":
    sys.exit(main())
