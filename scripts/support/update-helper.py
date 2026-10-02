#!/usr/bin/env python3
"""Support scripts/update.sh: source reports and offline child-ref maintenance.

report-sources performs read-only external version lookups. child-refs checks or
writes wrapper URLs against root original refs; locks keep exact revisions.
Common child inputs are required; optional Crane is synchronized only when
already declared. These modes never invoke one another.
"""

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


# External source reporting

VERSION_RE = re.compile(r"^v?([0-9]+(?:[._-][0-9]+)*)(.*)$")
SUPPORTED_KINDS = {
    "github-branch",
    "github-tags",
    "gitlab-tags",
    "registry-tags",
}


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


def report_sources(args):
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


# Offline child input-ref maintenance

INPUTS = ("nixpkgs", "flake-utils", "crane")
REVISION = re.compile(r"[0-9a-f]{40}")
# A small lexical scanner, not a Nix evaluator. Comments and strings cannot
# masquerade as helper imports or input assignments. Offsets preserve formatting.
TOKEN = re.compile(
    r'(?P<comment>\#[^\n]*|/\*[\s\S]*?\*/)'
    r'|(?P<string>"(?:\\[\s\S]|[^"\\])*"|\'\'[\s\S]*?\'\')'
    r'|(?P<path>\.{1,2}/[^\s;(){}\[\],"\']+)'
    r'|(?P<identifier>[A-Za-z_][A-Za-z0-9_\'\-]*)'
    r'|(?P<symbol>[^\s])'
)


def nix_tokens(text):
    return [match for match in TOKEN.finditer(text) if match.lastgroup != "comment"]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def root_urls(root):
    """Resolve root input edges and return ORIGINAL GitHub URLs, not locked revs.

    Require matching original/locked source identities and immutable locked
    revisions. Crane must name a version tag; root nixpkgs a NixOS release
    branch (nixos-YY.05 or nixos-YY.11). This is an offline structural check,
    not an upstream ref lookup.
    """
    lock = read_json(root / "flake.lock")
    try:
        nodes = lock["nodes"]
        roots = nodes[lock["root"]]["inputs"]
        urls = {}
        for name in INPUTS:
            node = roots[name]
            if not isinstance(node, str):
                raise ValueError(f"root input {name} must have a locked node")
            original = nodes[node]["original"]
            locked = nodes[node]["locked"]
            for source in (original, locked):
                if source.get("type") != "github":
                    raise ValueError(f"unsupported source for {name}: require github")
                for field in ("owner", "repo"):
                    if not isinstance(source.get(field), str) or not re.fullmatch(
                        r"[A-Za-z0-9_.-]+", source[field]
                    ):
                        raise ValueError(f"invalid {name} source {field}")
            if any(original[key].lower() != locked[key].lower() for key in ("owner", "repo")):
                raise ValueError(f"{name} original/locked GitHub provenance mismatch")
            if not isinstance(locked.get("rev"), str) or not REVISION.fullmatch(locked["rev"]):
                raise ValueError(f"{name} requires an exact locked revision")
            if not isinstance(locked.get("narHash"), str) or not locked["narHash"]:
                raise ValueError(f"{name} requires a locked narHash")
            ref = original.get("ref")
            rev = original.get("rev")
            if name in ("crane", "nixpkgs"):
                expected = ("ipetkov", "crane") if name == "crane" else ("nixos", "nixpkgs")
                if (original["owner"].lower(), original["repo"].lower()) != expected:
                    raise ValueError(f"unexpected {name} GitHub source")
                policy = (
                    r"v[0-9]+\.[0-9]+\.[0-9]+" if name == "crane" else r"nixos-[0-9]{2}\.(05|11)"
                )
                if rev is not None or not isinstance(ref, str) or not re.fullmatch(policy, ref):
                    kind = (
                        "version tag (vX.Y.Z)" if name == "crane" else "NixOS release branch"
                    )
                    raise ValueError(
                        f"{name} original must use a {kind}, not a revision/default ref"
                    )
            elif rev is not None:
                if ref is not None or not isinstance(rev, str) or not REVISION.fullmatch(rev):
                    raise ValueError(f"invalid {name} original revision/ref")
                if rev != locked["rev"]:
                    raise ValueError(f"{name} original/locked revision mismatch")
            if ref is not None and (
                not isinstance(ref, str) or not re.fullmatch(r"[A-Za-z0-9_.+/-]+", ref)
            ):
                raise ValueError(f"invalid {name} original ref")
            suffix = ref if ref is not None else rev
            urls[name] = f"github:{original['owner']}/{original['repo']}"
            if suffix is not None:
                urls[name] += f"/{suffix}"
        return urls
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError(f"malformed root input lock: {error}") from error


# Compatibility for callers of the old API; URLs now preserve original refs.
locked_urls = root_urls


def uses_repository_helper(path, root):
    """Recognize shared library paths even through a helper-variable alias.

    Any lexical code path into lib/flake is repository-bound, regardless of
    helper name or call syntax. Comments and strings do not count.
    """
    library = root.resolve() / "lib/flake"
    for token in nix_tokens(path.read_text()):
        if token.lastgroup == "path":
            imported = Path(os.path.abspath(path.parent / token.group()))
            if imported.is_relative_to(library):
                return True
    return False


def discover_wrappers(root):
    """Discover repository-bound flake.nix files under pkgs, without a registry.

    Ignore .git everywhere. At a source boundary (a directory containing
    default.nix, Cargo.toml or package.json), also prune node_modules, target,
    dist and .direnv before symlink checks. These generated children are not
    owned wrappers, even when they contain flakes or point outside pkgs.
    Boundaries are identified by marker files, not ancestor directory names:
    a real pkgs/tools/target or pkgs/tools/dist package is still discovered.

    Elsewhere reject symlink directories (rather than silently omitting their
    wrappers) and symlink flake files, even for in-tree targets. This prevents
    escapes and duplicate writes. Independent external flakes stay untouched.
    """
    root = root.resolve()
    packages = root / "pkgs"
    if packages.is_symlink() or not packages.is_dir():
        raise ValueError("missing or unsafe child package directory: pkgs")

    def walk_error(error):
        raise error

    discovered = []
    for directory, dirs, files in os.walk(packages, followlinks=False, onerror=walk_error):
        parent = Path(directory)
        ignored = {".git"}
        if any(marker in files for marker in ("default.nix", "Cargo.toml", "package.json")):
            ignored.update(("node_modules", "target", "dist", ".direnv"))
        # Mutate os.walk's traversal list before validating symlinks. Also
        # exclude dangling generated symlinks, which os.walk lists as files.
        dirs[:] = [name for name in dirs if name not in ignored]
        files = [name for name in files if name not in ignored]
        for name in dirs + files:
            entry = parent / name
            if entry.is_symlink() and (
                name in dirs or name == "flake.nix" or not entry.is_file()
            ):
                raise ValueError(f"unsafe symlink path: {entry.relative_to(root)}")
        # A flake.nix directory is not a valid wrapper either.
        if "flake.nix" not in files and "flake.nix" not in dirs:
            continue
        path = parent / "flake.nix"
        relative = path.relative_to(root)
        if (
            path.is_symlink()
            or not path.is_file()
            or not path.resolve().is_relative_to(packages)
        ):
            raise ValueError(f"missing or unsafe child wrapper: {relative}")
        if uses_repository_helper(path, root):
            if len(relative.parts) < 3:
                raise ValueError(f"invalid child wrapper path: {relative}")
            discovered.append(path)
    if not discovered:
        raise ValueError("no repository-bound child wrappers discovered under pkgs")
    return sorted(discovered)


def input_statements(tokens):
    """Split the one conventional inputs block at non-nested semicolons.

    This only balances lexical delimiters; it does not interpret Nix expressions.
    Unsupported declarations are rejected by update_wrapper, not normalized.
    """
    anchors = [
        index + 2 for index in range(len(tokens) - 2)
        if [token.group() for token in tokens[index:index + 3]] == ["inputs", "=", "{"]
    ]
    if len(anchors) != 1:
        raise ValueError("cannot locate unique child inputs block")
    opening = anchors[0]
    statements, statement, closing = [], [], []
    delimiters = {"{": "}", "(": ")", "[": "]"}
    for index in range(opening + 1, len(tokens)):
        token = tokens[index]
        value = token.group()
        if value == "}" and not closing:
            if statement:
                raise ValueError("unterminated child input declaration")
            if index + 1 == len(tokens) or tokens[index + 1].group() != ";":
                raise ValueError("unterminated child inputs block; require closing };")
            return tokens[opening], statements
        if value in delimiters:
            closing.append(delimiters[value])
        elif value in delimiters.values():
            if not closing or closing.pop() != value:
                raise ValueError("unbalanced child inputs block")
        statement.append(token)
        if value == ";" and not closing:
            statements.append(statement)
            statement = []
    raise ValueError("unterminated child inputs block")


def update_wrapper(text, urls):
    _, statements = input_statements(nix_tokens(text))
    assignments = {name: [] for name in urls}
    # Reject unsupported forms BEFORE deciding an input is absent. In particular,
    # grouped/quoted/inherited Crane must not be treated as an absent input.
    for statement in statements:
        first = statement[0]
        name = first.group()
        if name == "inherit" or first.lastgroup == "string" or name == "$":
            raise ValueError("unsupported quoted/dynamic/inherited input declaration")
        if name not in assignments:
            continue
        if [token.group() for token in statement[:4]] != [name, ".", "url", "="]:
            raise ValueError(f"unsupported {name} input declaration; require {name}.url")
        if (
            len(statement) != 6
            or statement[4].lastgroup != "string"
            or not statement[4].group().startswith('"')
            or "${" in statement[4].group()
        ):
            raise ValueError(f"{name} input must have a literal URL")
        assignments[name].append(statement[4])
    edits = []
    for name, url in urls.items():
        matches = assignments[name]
        if len(matches) > 1:
            raise ValueError(f"ambiguous {name} input")
        if matches:
            token = matches[0]
            edits.append((token.start(), token.end(), f'"{url}"'))
        elif name != "crane":
            raise ValueError(f"missing {name} input")
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def sync_child_refs(args):
    try:
        urls = root_urls(args.root)
        # Validate and prepare ALL wrappers before writing any of them.
        updates = []
        wrappers = discover_wrappers(args.root)
        for path in wrappers:
            text = path.read_text()
            updated = update_wrapper(text, urls)
            if updated != text:
                updates.append((path, updated))
        for path, updated in updates:
            if args.write:
                path.write_text(updated)
            relative = path.relative_to(args.root.resolve())
            print(f"{'updated' if args.write else 'stale'}: {relative}")
    except (ValueError, OSError) as error:
        print(f"update-helper child-refs: {error}", file=sys.stderr)
        return 2
    if args.check and updates:
        print(
            "Run python3 scripts/support/update-helper.py child-refs --write "
            "after changing root input refs."
        )
        return 1
    print(f"{len(wrappers)} child build input refs match root flake.lock original sources.")
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    report = commands.add_parser(
        "report-sources", help="Report external source versions (read-only)"
    )
    report.add_argument("sources", nargs="+", type=Path)
    report.add_argument("--jobs", "-j", type=int, default=16)
    report.add_argument("--ansi", action="store_true")
    report.add_argument("--color", choices=("auto", "always", "never"), default="auto")

    refs = commands.add_parser(
        "child-refs", help="Check or synchronize declared child input refs (offline)"
    )
    refs.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    mode = refs.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")

    args = parser.parse_args(argv)
    if args.command == "report-sources":
        if args.jobs < 1:
            report.error("--jobs must be a positive integer")
        if args.ansi:
            args.color = "always"
    return args


def main(argv=None):
    args = parse_args(argv)
    if args.command == "report-sources":
        # Keep the old reporter's pipeline behavior out of offline ref checks
        # and module imports used by callers/tests.
        if hasattr(signal, "SIGPIPE"):
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        return report_sources(args)
    return sync_child_refs(args)


if __name__ == "__main__":
    raise SystemExit(main())
