#!/usr/bin/env python3
import json
import re
import signal
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
VERSION_RE = re.compile(r"^v?([0-9]+(?:[._-][0-9]+)*)(.*)$")

PACKAGES = [
    {
        "name": "awl",
        "path": "pkgs/ext/awl/default.nix",
        "kind": "gitlab-tags",
        "project": "davical-project/awl",
        "prefix": "r",
    },
    {
        "name": "bulwarkmail",
        "path": "pkgs/ext/bulwarkmail/default.nix",
        "kind": "github-tags",
        "owner": "bulwarkmail",
        "repo": "webmail",
    },
    {
        "name": "kanidm-server",
        "path": "pkgs/ext/kanidm-server/default.nix",
        "kind": "registry-tags",
        "registry": "registry-1.docker.io",
        "repository": "kanidm/server",
    },
    {
        "name": "mirofish",
        "path": "pkgs/ext/mirofish/default.nix",
        "kind": "github-branch",
        "owner": "666ghj",
        "repo": "MiroFish",
        "branch": "main",
    },
    {
        "name": "stalwart-server",
        "path": "pkgs/ext/stalwart-server/default.nix",
        "kind": "github-tags",
        "owner": "stalwartlabs",
        "repo": "stalwart",
    },
    {
        "name": "z-push",
        "path": "pkgs/ext/z-push/default.nix",
        "kind": "github-tags",
        "owner": "Z-Hub",
        "repo": "Z-Push",
    },
]


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
            print("Usage: report-pkgs-ext.py [--jobs N] [--ansi|--color=WHEN]")
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
    color_code = "1;38;2;232;170;117"
    if color:
        return f"- \033[{color_code}m{line}\033[0m"
    return f"- {line}"


def attention_line(line, color):
    if color:
        return f"- \033[1;38;2;255;150;150m{line}\033[0m"
    return f"- {line}"


def request_json(url, token=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def current_version(path):
    text = (REPO_ROOT / path).read_text()
    match = re.search(r'^\s*version = "([^"]+)";', text, re.MULTILINE)
    if match:
        return match.group(1)
    return None


def current_rev(path):
    text = (REPO_ROOT / path).read_text()
    match = re.search(r'^\s*rev = "([^"]+)";', text, re.MULTILINE)
    if match:
        return match.group(1)
    return None


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


def github_tags(owner, repo):
    data = request_json(f"https://api.github.com/repos/{owner}/{repo}/tags?per_page=100")
    return [tag["name"] for tag in data if tag.get("name")]


def github_branch_rev(owner, repo, branch):
    data = request_json(f"https://api.github.com/repos/{owner}/{repo}/commits/{branch}")
    return data.get("sha", "")[:12]


def gitlab_tags(project):
    encoded = urllib.parse.quote(project, safe="")
    data = request_json(f"https://gitlab.com/api/v4/projects/{encoded}/repository/tags?per_page=100")
    return [tag["name"] for tag in data if tag.get("name")]


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


def registry_tags(repository):
    token = dockerhub_token(repository)
    data = request_json(
        f"https://registry-1.docker.io/v2/{repository}/tags/list",
        token,
    )
    return data.get("tags") or []


def latest_version(pkg, current):
    kind = pkg["kind"]
    if kind == "github-tags":
        tags = [normalize_tag(tag) for tag in github_tags(pkg["owner"], pkg["repo"])]
        return latest_comparable_tag(current, tags)
    if kind == "gitlab-tags":
        tags = [
            normalize_tag(tag, pkg.get("prefix", ""))
            for tag in gitlab_tags(pkg["project"])
        ]
        return latest_comparable_tag(current, tags)
    if kind == "registry-tags":
        return latest_comparable_tag(current, registry_tags(pkg["repository"]))
    if kind == "github-branch":
        return github_branch_rev(pkg["owner"], pkg["repo"], pkg["branch"])
    return current


def report_package(pkg, color):
    current = current_version(pkg["path"])
    if pkg["kind"] == "github-branch":
        current = (current_rev(pkg["path"]) or current or "")[:12]
    if not current:
        return f"- {pkg['name']}: unknown [latest]"

    try:
        latest = latest_version(pkg, current)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        latest = current

    if latest == current:
        return f"- {pkg['name']}: {current} [latest]"
    line = f"{pkg['name']}: {current} -> {latest}"
    if is_attention_update(current, latest):
        return attention_line(line, color)
    return update_line(line, color)


def main():
    jobs, color_mode = parse_args()
    color = use_color(color_mode)
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [executor.submit(report_package, pkg, color) for pkg in PACKAGES]
        for future in as_completed(futures):
            print(future.result(), flush=True)


if __name__ == "__main__":
    main()
