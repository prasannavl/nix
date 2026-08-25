#!/usr/bin/env python3
"""Compile a supported Compose application into rootless Quadlet units.

The compiler runs as a normal Nix build.  Its output is deliberately opaque to
Nix evaluation: Quadlet files and the collision report are consumed only by
later builds, never imported back into the evaluator or read at runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any

import yaml


ALLOWED_TOP_LEVEL = {"networks", "services"}
ALLOWED_SERVICE_KEYS = {
    "attach",
    "cap_add",
    "cap_drop",
    "command",
    "container_name",
    "depends_on",
    "devices",
    "entrypoint",
    "environment",
    "env_file",
    "expose",
    "extra_hosts",
    "group_add",
    "healthcheck",
    "image",
    "ipc",
    "mem_limit",
    "networks",
    "pids_limit",
    "ports",
    "read_only",
    "restart",
    "security_opt",
    "shm_size",
    "tmpfs",
    "ulimits",
    "user",
    "volumes",
    "working_dir",
}
SEQUENCE_KEYS = {
    "cap_add",
    "cap_drop",
    "devices",
    "env_file",
    "expose",
    "extra_hosts",
    "group_add",
    "ports",
    "security_opt",
    "tmpfs",
    "volumes",
}
PRIMITIVES = (str, int, float, bool)


class ComposeLoader(yaml.SafeLoader):
    """Safe YAML loader with Compose's YAML 1.2 boolean behavior."""


ComposeLoader.yaml_implicit_resolvers = {
    key: [
        (tag, pattern)
        for tag, pattern in resolvers
        if tag != "tag:yaml.org,2002:bool"
    ]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
ComposeLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool",
    re.compile(r"^(?:true|false)$", re.IGNORECASE),
    list("tTfF"),
)


class CompileError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise CompileError(message)


def docker_archive_tags(image_path: Path) -> list[str]:
    """Return the nonempty image tags declared by a Docker archive."""

    try:
        with tarfile.open(image_path, mode="r:*") as archive:
            manifest_file = archive.extractfile("manifest.json")
            if manifest_file is None:
                fail(f"Docker archive has no readable manifest.json: {image_path}")
            manifest = json.load(manifest_file)
    except CompileError:
        raise
    except (json.JSONDecodeError, KeyError, OSError, tarfile.TarError) as error:
        fail(f"unable to read Docker archive manifest {image_path}: {error}")

    if not isinstance(manifest, list) or not manifest:
        fail(f"Docker archive manifest must be a nonempty list: {image_path}")
    tags: list[str] = []
    for entry in manifest:
        if not isinstance(entry, dict):
            fail(f"Docker archive manifest entry must be a mapping: {image_path}")
        repo_tags = entry.get("RepoTags")
        if not isinstance(repo_tags, list):
            fail(f"Docker archive manifest entry has no RepoTags list: {image_path}")
        for tag in repo_tags:
            if not isinstance(tag, str) or not tag:
                fail(
                    f"Docker archive manifest contains an invalid image tag: {image_path}"
                )
            if tag not in tags:
                tags.append(tag)
    if not tags:
        fail(f"Docker archive contains no tagged image: {image_path}")
    return tags


def docker_archive_runtime_ref(image_path: Path, load_ref: str) -> str:
    """Resolve the archive tag that Quadlet's ImageTag must reference."""

    tags = docker_archive_tags(image_path)
    if load_ref:
        if load_ref not in tags:
            fail(
                f"Docker archive {image_path} does not contain declared image "
                f"tag {load_ref!r}; available tags: {', '.join(tags)}"
            )
        return load_ref
    if len(tags) != 1:
        fail(f"Docker archive {image_path} has ambiguous image tags: {', '.join(tags)}")
    return tags[0]


_ENVIRONMENT_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _environment_name(text: str, offset: int = 0) -> tuple[str | None, int]:
    match = _ENVIRONMENT_NAME.match(text, offset)
    if match is None:
        return None, offset
    return match.group(0), match.end()


def _parameter_end(text: str, offset: int, source: str) -> int:
    depth = 1
    index = offset
    while index < len(text):
        if text.startswith("${", index):
            depth += 1
            index += 2
            continue
        if text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    fail(f"{source}: unterminated Compose interpolation")


def _expand_parameter(expression: str, env: dict[str, str], source: str) -> str:
    name, offset = _environment_name(expression)
    if name is None:
        fail(f"{source}: invalid Compose interpolation ${{{expression}}}")
    remainder = expression[offset:]
    if not remainder:
        if name not in env:
            print(
                f"quadlet compiler: warning: {source}: Compose variable {name} "
                "is unset; substituting an empty string",
                file=os.sys.stderr,
            )
        return env.get(name, "")

    operator = remainder[:2] if remainder[:2] in (":-", ":+", ":?") else remainder[:1]
    if operator not in ("-", "+", "?", ":-", ":+", ":?"):
        fail(f"{source}: unsupported Compose interpolation ${{{expression}}}")
    argument = remainder[len(operator) :]
    present = name in env
    value = env.get(name, "")
    usable = present and value != "" if operator.startswith(":") else present
    operation = operator[-1]
    if operation == "-":
        return value if usable else interpolate(argument, env, source)
    if operation == "+":
        return interpolate(argument, env, source) if usable else ""
    if usable:
        return value
    message = interpolate(argument, env, source) if argument else f"{name} is required"
    fail(f"{source}: required Compose variable {name} is unset: {message}")


def interpolate(text: str, env: dict[str, str], source: str) -> str:
    """Expand Compose variables, including nested default/alternate expressions."""

    result: list[str] = []
    index = 0
    while index < len(text):
        if text[index] != "$":
            result.append(text[index])
            index += 1
            continue
        if index + 1 >= len(text):
            result.append("$")
            break
        following = text[index + 1]
        if following == "$":
            result.append("$")
            index += 2
            continue
        if following == "{":
            end = _parameter_end(text, index + 2, source)
            result.append(_expand_parameter(text[index + 2 : end], env, source))
            index = end + 1
            continue
        name, end = _environment_name(text, index + 1)
        if name is None:
            result.append("$")
            index += 1
            continue
        if name not in env:
            print(
                f"quadlet compiler: warning: {source}: Compose variable {name} "
                "is unset; substituting an empty string",
                file=os.sys.stderr,
            )
        result.append(env.get(name, ""))
        index = end
    return "".join(result)


def interpolate_value(value: Any, env: dict[str, str], source: str) -> Any:
    if isinstance(value, str):
        return interpolate(value, env, source)
    if isinstance(value, list):
        return [interpolate_value(item, env, source) for item in value]
    if isinstance(value, dict):
        # Compose interpolation applies to YAML values. Mapping keys are kept
        # literal; fields with arbitrary keys use their KEY=VALUE list form
        # when key interpolation is required.
        return {
            key: interpolate_value(item, env, source)
            for key, item in value.items()
        }
    return value


def _unquoted_dotenv_value(value: str) -> str:
    for index, character in enumerate(value):
        if character == "#" and index > 0 and value[index - 1].isspace():
            return value[:index].rstrip()
    return value.rstrip()


def _quoted_dotenv_value(
    lines: list[str], line_index: int, value: str, quote: str, path: str
) -> tuple[str, int]:
    result: list[str] = []
    index = 1
    while True:
        while index < len(value):
            character = value[index]
            if character == quote:
                trailer = value[index + 1 :].strip()
                if trailer and not trailer.startswith("#"):
                    fail(f"{path}:{line_index + 1}: unexpected text after quoted value")
                return "".join(result), line_index
            if character == "\\" and index + 1 < len(value):
                escaped = value[index + 1]
                if quote == '"' and escaped in {'"', "\\", "n", "r", "t"}:
                    result.append({"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped))
                    index += 2
                    continue
                if quote == "'" and escaped in {"'", "\\"}:
                    result.append(escaped)
                    index += 2
                    continue
            result.append(character)
            index += 1
        line_index += 1
        if line_index >= len(lines):
            fail(f"{path}:{line_index}: unterminated quoted value")
        result.append("\n")
        value = lines[line_index]
        index = 0


def load_dotenv(path: str | None) -> dict[str, str]:
    result: dict[str, str] = {}
    if not path:
        return result
    lines = Path(path).read_text().splitlines()
    line_index = 0
    while line_index < len(lines):
        line = lines[line_index].strip()
        if not line or line.startswith("#"):
            line_index += 1
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name_text, separator, raw_value = line.partition("=")
        name = name_text.strip()
        if _ENVIRONMENT_NAME.fullmatch(name) is None:
            fail(f"{path}:{line_index + 1}: invalid environment name {name!r}")
        if not separator:
            result.pop(name, None)
            line_index += 1
            continue
        value = raw_value.lstrip()
        if value.startswith(("'", '"')):
            quote = value[0]
            value, line_index = _quoted_dotenv_value(
                lines, line_index, value, quote, path
            )
            if quote == '"':
                value = interpolate(value, result, f"{path}:{line_index + 1}")
        else:
            value = interpolate(
                _unquoted_dotenv_value(value), result, f"{path}:{line_index + 1}"
            )
        result[name] = value
        line_index += 1
    return result


def short_syntax_target(field: str, value: Any) -> str:
    if not isinstance(value, str):
        fail(f"{field} must use short string syntax")
    parts = value.split(":")
    if field == "devices" and len(parts) == 1:
        return value
    if len(parts) < 2 or not parts[1]:
        fail(f"{field} short syntax must include a container target")
    return parts[1]


def short_port_key(value: Any) -> tuple[str, str, str, str]:
    if not isinstance(value, str):
        fail("ports must use short string syntax")
    address, separator, protocol = value.rpartition("/")
    if not separator:
        address = value
        protocol = "tcp"
    if not protocol:
        fail("port short syntax has an empty protocol")

    fields: list[str] = []
    current: list[str] = []
    bracket_depth = 0
    for character in address:
        if character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth -= 1
            if bracket_depth < 0:
                fail(f"invalid port short syntax: {value}")
        if character == ":" and bracket_depth == 0:
            fields.append("".join(current))
            current = []
        else:
            current.append(character)
    if bracket_depth != 0:
        fail(f"invalid port short syntax: {value}")
    fields.append("".join(current))

    if len(fields) == 1:
        host_ip, published, target = "", "", fields[0]
    elif len(fields) == 2:
        host_ip, published, target = "", fields[0], fields[1]
    elif len(fields) == 3:
        host_ip, published, target = fields
    else:
        fail(f"invalid port short syntax: {value}")
    if not target:
        fail(f"port short syntax has an empty container target: {value}")
    return host_ip, target, published, protocol


def unique_sequence_key(field: str, value: Any) -> Any:
    if field in ("volumes", "devices"):
        return short_syntax_target(field, value)
    if field == "ports":
        return short_port_key(value)
    if field == "extra_hosts":
        if not isinstance(value, str):
            fail("extra_hosts must use short string syntax")
        return re.split(r"[=:]", value, maxsplit=1)[0]
    return None


def merge_unique_sequence(field: str, left: list[Any], right: list[Any]) -> list[Any]:
    result = list(left)
    positions = {
        unique_sequence_key(field, value): index
        for index, value in enumerate(result)
    }
    for value in right:
        unique_key = unique_sequence_key(field, value)
        if unique_key in positions:
            result[positions[unique_key]] = value
        else:
            positions[unique_key] = len(result)
            result.append(value)
    return result


def merge_sequence(left: list[Any], right: list[Any]) -> list[Any]:
    result = list(left)
    for value in right:
        if value not in result:
            result.append(value)
    return result


def environment_mapping(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if not isinstance(value, list):
        fail("environment must be a mapping or string list")
    result: dict[str, Any] = {}
    for item in value:
        if not isinstance(item, str):
            fail("environment list entries must be strings")
        name, separator, item_value = item.partition("=")
        if _ENVIRONMENT_NAME.fullmatch(name) is None:
            fail(f"invalid environment name {name!r}")
        if not separator:
            item_value = None
        result[name] = item_value
    return result


def merge_value(key: str, left: Any, right: Any) -> Any:
    if key == "environment":
        return merge_mapping(environment_mapping(left), environment_mapping(right))
    if isinstance(left, dict) and isinstance(right, dict):
        return merge_mapping(left, right)
    if key in SEQUENCE_KEYS and isinstance(left, list) and isinstance(right, list):
        if key in ("devices", "extra_hosts", "ports", "volumes"):
            return merge_unique_sequence(key, left, right)
        return merge_sequence(left, right)
    return right


def merge_mapping(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    result = dict(left)
    for key, value in right.items():
        result[key] = merge_value(key, result[key], value) if key in result else value
    return result


def load_compose(paths: list[str], env: dict[str, str]) -> dict[str, Any]:
    merged: dict[str, Any] = {}
    for path in paths:
        try:
            document = yaml.load(Path(path).read_text(), Loader=ComposeLoader)
        except yaml.YAMLError as error:
            fail(f"{path}: invalid Compose YAML: {error}")
        if document is None:
            document = {}
        if not isinstance(document, dict):
            fail(f"{path}: Compose document must be a mapping")
        document = interpolate_value(document, env, path)
        merged = merge_mapping(merged, document)
    return merged


def primitive(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def compose_string(value: Any) -> str:
    return primitive(value)


def escape_value(value: Any) -> str:
    rendered = primitive(value)
    if "\n" in rendered:
        fail("Quadlet values must not contain newlines")
    return rendered.replace("%", "%%").replace("$", "$$")


def exec_arg(value: Any) -> str:
    return (
        json.dumps(str(value), ensure_ascii=False).replace("%", "%%").replace("$", "$$")
    )


def exec_args(values: list[Any]) -> str:
    return " ".join(exec_arg(value) for value in values)


def render_quadlet(sections: list[tuple[str, list[tuple[str, Any, bool]]]]) -> str:
    rendered: list[str] = []
    for name, entries in sections:
        if not entries:
            continue
        lines = [f"[{name}]"]
        for key, value, pre_escaped in entries:
            lines.append(f"{key}={value if pre_escaped else escape_value(value)}")
        rendered.append("\n".join(lines))
    return "\n\n".join(rendered) + "\n"


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else [value]


def string_list(service_name: str, field: str, value: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        fail(f"service {service_name} {field} must contain strings")
    return value


def sanitize_unit_part(value: str) -> str:
    return re.sub(r"[@/: ]", "-", value)


def resolve_runtime_path(working_dir: str, value: str) -> str:
    path = PurePosixPath(value if value.startswith("/") else f"{working_dir}/{value}")
    parts: list[str] = []
    for part in path.parts:
        if part in ("", "/", "."):
            continue
        if part == "..":
            if not parts:
                fail(f"relative Quadlet path escapes its working directory: {value}")
            parts.pop()
        else:
            parts.append(part)
    return "/" + "/".join(parts)


def volume_value(service_name: str, working_dir: str, value: Any) -> str:
    if not isinstance(value, str):
        fail(f"service {service_name} volumes must use short string syntax")
    parts = value.split(":")
    if len(parts) < 2:
        fail(f"service {service_name} volumes must be bind mounts")
    source, destination = parts[0], parts[1]
    if not (
        source.startswith("/") or source.startswith(".")
    ) or not destination.startswith("/"):
        fail(f"service {service_name} volumes must be absolute or relative bind mounts")
    parts[0] = resolve_runtime_path(working_dir, source)
    return ":".join(parts)


def dependency_info(
    service_name: str, value: Any, known: set[str]
) -> tuple[list[str], set[str]]:
    healthy: set[str] = set()
    if isinstance(value, list):
        dependencies = string_list(service_name, "depends_on", value)
    elif isinstance(value, dict):
        dependencies = list(value)
        for name, settings in value.items():
            if not isinstance(settings, dict) or set(settings) - {"condition"}:
                fail(f"service {service_name} depends_on contains unsupported options")
            condition = settings.get("condition", "service_started")
            if condition not in ("service_started", "service_healthy"):
                fail(
                    f"service {service_name} depends_on has unsupported condition {condition}"
                )
            if condition == "service_healthy":
                healthy.add(name)
    else:
        fail(f"service {service_name} depends_on must be a list or mapping")
    unknown = set(dependencies) - known
    if unknown:
        fail(
            f"service {service_name} depends_on references unknown services: {', '.join(sorted(unknown))}"
        )
    return dependencies, healthy


def environment_entries(
    service_name: str, value: Any, env: dict[str, str]
) -> list[tuple[str, Any, bool]]:
    entries: list[str]
    if isinstance(value, dict):
        if not all(
            isinstance(name, str) and _ENVIRONMENT_NAME.fullmatch(name)
            for name in value
        ):
            fail(f"service {service_name} environment contains an invalid name")
        if not all(
            isinstance(item, PRIMITIVES) or item is None for item in value.values()
        ):
            fail(f"service {service_name} environment must contain primitive values")
        entries = [
            f"{name}={compose_string(env[name] if item is None else item)}"
            for name, item in value.items()
            if item is not None or name in env
        ]
    elif isinstance(value, list) and all(isinstance(item, str) for item in value):
        entries = []
        for item in value:
            name, separator, item_value = item.partition("=")
            if _ENVIRONMENT_NAME.fullmatch(name) is None:
                fail(f"service {service_name} environment contains invalid name {name!r}")
            if separator:
                entries.append(f"{name}={item_value}")
            elif name in env:
                entries.append(f"{name}={env[name]}")
    else:
        fail(f"service {service_name} environment must be a mapping or string list")
    return [("Environment", exec_arg(item), True) for item in entries]


def health_entries(service_name: str, value: Any) -> list[tuple[str, Any, bool]]:
    if value is None:
        return []
    if not isinstance(value, dict) or set(value) - {
        "test",
        "interval",
        "timeout",
        "retries",
        "start_period",
    }:
        fail(f"service {service_name} healthcheck contains unsupported fields")
    test = value.get("test")
    if not isinstance(test, list) or len(test) < 2:
        fail(
            f"service {service_name} healthcheck must use CMD or CMD-SHELL list syntax"
        )
    if test[0] == "CMD-SHELL" and len(test) == 2:
        command = compose_string(test[1]).replace("\n", " ")
    elif test[0] == "CMD":
        command = json.dumps(
            [compose_string(item) for item in test[1:]], separators=(",", ":")
        )
    else:
        fail(f"service {service_name} healthcheck must use CMD or CMD-SHELL")
    result: list[tuple[str, Any, bool]] = [("HealthCmd", command, False)]
    health_fields = (
        ("interval", "HealthInterval"),
        ("timeout", "HealthTimeout"),
        ("retries", "HealthRetries"),
        ("start_period", "HealthStartPeriod"),
    )
    for field, key in health_fields:
        if field in value:
            result.append((key, value[field], False))
    # Quadlet makes the generated systemd service READY only after the
    # container healthcheck succeeds.  An unhealthy container is killed so the
    # service's systemd Restart= policy, rather than Podman, owns recovery.
    result.extend(
        [
            ("HealthOnFailure", "kill", False),
            ("Notify", "healthy", False),
        ]
    )
    return result


def validate_policy(config: dict[str, Any]) -> None:
    policy = config["policy"]
    reasons: list[str] = []
    if policy["composeArgs"]:
        reasons.append("composeArgs are Compose-provider specific")
    if policy["reloadMethod"] != "restart":
        reasons.append("signal reload is unsupported")
    if policy["removalPolicy"] != "delete":
        reasons.append('Quadlet requires removalPolicy = "delete"')
    if policy["adopt"]:
        reasons.append("adopt is unsupported for Quadlet")
    if not policy["longRunning"]:
        reasons.append("Quadlet does not support one-shot/job containers")
    if reasons:
        fail("; ".join(reasons))


def compile_bundle(config: dict[str, Any], output: Path) -> None:
    validate_policy(config)
    timeout_ready_seconds = config.get("timeoutReadySeconds")
    if (
        isinstance(timeout_ready_seconds, bool)
        or not isinstance(timeout_ready_seconds, int)
        or timeout_ready_seconds <= 0
    ):
        fail("timeoutReadySeconds must be a positive integer")
    env = load_dotenv(config.get("projectEnvFile"))
    compose = load_compose(config["composeFiles"], env)
    unexpected = set(compose) - ALLOWED_TOP_LEVEL
    if unexpected:
        fail(f"unsupported top-level keys: {', '.join(sorted(unexpected))}")
    services = compose.get("services")
    if not isinstance(services, dict) or not services:
        fail("source must declare at least one service")
    if not all(isinstance(name, str) and name for name in services):
        fail("service names must be nonempty strings")
    known = set(services)

    for target, runtime_path in config.get("envSecretRuntimePaths", {}).items():
        if target not in known:
            fail(f"envSecrets target unknown service: {target}")
        raw = services[target]
        current = raw.get("env_file", [])
        raw["env_file"] = as_list(current) + [runtime_path]

    for secret in config.get("fileSecrets", []):
        if not secret.get("mount", True):
            continue
        targets = secret.get("services")
        if targets is None:
            targets = sorted(known)
        unknown_targets = set(targets) - known
        if unknown_targets:
            fail(
                f"fileSecret {secret['name']} targets unknown services: {', '.join(sorted(unknown_targets))}"
            )
        mount = f"{secret['runtimePath']}:{secret['mountPath']}"
        if secret.get("readOnly", True):
            mount += ":ro"
        for target in targets:
            raw = services[target]
            volumes = raw.get("volumes", [])
            if not isinstance(volumes, list):
                fail(f"service {target} volumes must be a list")
            raw["volumes"] = volumes + [mount]
            additions = secret.get("environment", {})
            if additions:
                environment = raw.get("environment", {})
                if isinstance(environment, dict):
                    raw["environment"] = merge_mapping(environment, additions)
                elif isinstance(environment, list):
                    raw["environment"] = environment + [
                        f"{key}={value}" for key, value in additions.items()
                    ]
                else:
                    fail(f"service {target} environment must be a mapping or list")

    networks = compose.get("networks", {})
    if not isinstance(networks, dict) or set(networks) - {"default"}:
        fail("only the default Compose network is supported")
    default_network = networks.get("default", {}) or {}
    if not isinstance(default_network, dict) or set(default_network) - {"ipam"}:
        fail("top-level default network supports only ipam")
    ipam = default_network.get("ipam", {}) or {}
    if not isinstance(ipam, dict) or set(ipam) - {"config"}:
        fail("top-level default network ipam supports only config")
    ipam_config = ipam.get("config", []) or []
    if not isinstance(ipam_config, list) or len(ipam_config) > 1:
        fail("top-level default network supports at most one ipam.config entry")
    source_subnet = None
    if ipam_config:
        if not isinstance(ipam_config[0], dict) or set(ipam_config[0]) - {"subnet"}:
            fail("top-level default network ipam.config supports only subnet")
        source_subnet = ipam_config[0].get("subnet")
    subnet = config.get("subnet") or source_subnet
    if config.get("subnet") and source_subnet and config["subnet"] != source_subnet:
        fail("declared subnet conflicts with the Compose default network subnet")

    systemd_name = config["systemdServiceName"]
    default_project_name = config["composeProjectName"]
    if not isinstance(default_project_name, str) or not default_project_name:
        fail("composeProjectName must be a nonempty string")
    configured_project_name = env.get("COMPOSE_PROJECT_NAME")
    compose_project_name = (
        configured_project_name
        if configured_project_name
        else default_project_name.lower()
    )
    compose_project_name = re.sub(r"[^-_a-z0-9]", "", compose_project_name)
    if not compose_project_name:
        fail("Compose project name normalizes to an empty string")
    working_dir = config["workingDir"]
    etc_dir = config["etcDir"].rstrip("/")
    network_base = f"{systemd_name}-network"
    network_file = f"{network_base}.network"
    network_unit = f"{network_base}-network.service"
    network_name = f"{systemd_name}-default"
    public_unit = f"{systemd_name}.service"
    stage_unit = f"{systemd_name}-stage.service"
    network_entries = [
        ("NetworkName", network_name, False),
        ("NetworkDeleteOnStop", True, False),
    ]
    if subnet is not None:
        if not isinstance(subnet, str):
            fail("network subnet must be a string")
        network_entries.append(("Subnet", subnet, False))
    network_text = render_quadlet(
        [
            (
                "Unit",
                [
                    ("Description", f"podman network: {systemd_name}", False),
                    ("PartOf", public_unit, False),
                    ("StopWhenUnneeded", True, False),
                ],
            ),
            ("Network", network_entries),
        ]
    )

    dependencies: dict[str, list[str]] = {}
    health_waited_on: set[str] = set()
    for name, raw in services.items():
        if not isinstance(raw, dict):
            fail(f"service {name} must be a mapping")
        unknown = set(raw) - ALLOWED_SERVICE_KEYS
        if unknown:
            fail(f"service {name} has unsupported keys: {', '.join(sorted(unknown))}")
        if "attach" in raw and not isinstance(raw["attach"], bool):
            fail(f"service {name} attach must be a boolean")
        deps, healthy = dependency_info(name, raw.get("depends_on", []), known)
        dependencies[name] = deps
        health_waited_on |= healthy
    for name in sorted(health_waited_on):
        if services[name].get("healthcheck") is None:
            fail(f"service_healthy dependency target {name} has no healthcheck")

    units_dir = output / "quadlet"
    units_dir.mkdir(parents=True)
    (units_dir / network_file).write_text(network_text)
    unit_records: list[dict[str, Any]] = [
        {
            "unit": network_unit,
            "sourcePath": f"{etc_dir}/{network_file}",
            "kind": "network",
        }
    ]
    container_records: list[dict[str, Any]] = []
    declared_images: list[str] = []
    local_images: list[dict[str, Any]] = []
    local_image_by_runtime_ref: dict[str, dict[str, Any]] = {}
    for raw_entry in config.get("localImages", []):
        if (
            not isinstance(raw_entry, dict)
            or not isinstance(raw_entry.get("runtimeRef"), str)
            or not isinstance(raw_entry.get("imageTar"), str)
        ):
            fail("local image metadata must contain string runtimeRef and imageTar")
        lookup_ref = raw_entry["runtimeRef"]
        entry = dict(raw_entry)
        load_ref = entry.get("loadRef", "")
        if not isinstance(load_ref, str):
            fail("local image metadata loadRef must be a string")
        entry["runtimeRef"] = docker_archive_runtime_ref(
            Path(entry["imageTar"]), load_ref
        )
        local_images.append(entry)
        local_image_by_runtime_ref[lookup_ref] = entry
    image_files: dict[str, str] = {}

    def image_file_for(image: str) -> str:
        existing = image_files.get(image)
        if existing is not None:
            return existing
        digest = hashlib.sha256(image.encode()).hexdigest()[:12]
        image_base = f"{systemd_name}-image-{digest}"
        image_file = f"{image_base}.image"
        image_unit = f"{image_base}-image.service"
        local = local_image_by_runtime_ref.get(image)
        image_entries: list[tuple[str, Any, bool]]
        if local is None:
            image_entries = [("Image", image, False), ("Policy", "newer", False)]
            declared_images.append(image)
            kind = "remote-image"
        else:
            image_entries = [
                ("Image", f"docker-archive:{local['imageTar']}", False),
                ("ImageTag", local["runtimeRef"], False),
            ]
            kind = "local-image"
        image_text = render_quadlet(
            [
                (
                    "Unit",
                    [
                        ("Description", f"podman image: {image}", False),
                        ("PartOf", public_unit, False),
                        ("StopWhenUnneeded", True, False),
                    ],
                ),
                ("Image", image_entries),
            ]
        )
        (units_dir / image_file).write_text(image_text)
        unit_records.append(
            {
                "unit": image_unit,
                "sourcePath": f"{etc_dir}/{image_file}",
                "kind": kind,
            }
        )
        image_files[image] = image_file
        return image_file

    for name in sorted(services):
        raw = services[name]
        source_image = raw.get("image")
        if not isinstance(source_image, str) or not source_image:
            fail(f"service {name} image must resolve to a nonempty string")
        image = config.get("imageRewrites", {}).get(source_image, source_image)
        if source_image.startswith("nix-store:") and image == source_image:
            image_tar = source_image.removeprefix("nix-store:")
            image_path = Path(image_tar)
            store_name = image_path.name
            store_hash, separator, store_suffix = store_name.partition("-")
            if (
                not image_path.is_absolute()
                or image_path.parent != Path("/nix/store")
                or not separator
                or not store_suffix
                or re.fullmatch(r"[0-9a-z]{32}", store_hash) is None
                or not image_path.is_file()
            ):
                fail(
                    f"service {name} nix-store image must reference an existing "
                    f"archive file under /nix/store: {image_tar!r}"
                )
            store_hash = store_hash[:12]
            image = docker_archive_runtime_ref(image_path, "")
            local_entry = {
                "imageRef": source_image,
                "imageTar": image_tar,
                "loadRef": "",
                "runtimeRef": image,
                "storeHash": store_hash,
            }
            local_images.append(local_entry)
            local_image_by_runtime_ref[image] = local_entry
        image_file = image_file_for(image)
        container_name = raw.get(
            "container_name", f"{compose_project_name}_{name}_1"
        )
        if not isinstance(container_name, str) or not container_name:
            fail(f"service {name} container_name must be a nonempty string")
        unit_part = sanitize_unit_part(name)
        container_base = f"{systemd_name}-{unit_part}-container"
        container_file = f"{container_base}.container"
        container_unit = f"{container_base}.service"
        source_path = f"{etc_dir}/{container_file}"
        dependency_units = [
            f"{systemd_name}-{sanitize_unit_part(dep)}-container.service"
            for dep in dependencies[name]
        ]

        unit_entries: list[tuple[str, Any, bool]] = [
            ("Description", f"podman container: {systemd_name}/{name}", False),
            ("PartOf", public_unit, False),
            ("StopWhenUnneeded", True, False),
            ("Requires", stage_unit, False),
            ("After", stage_unit, False),
            ("Before", public_unit, False),
        ]
        if dependency_units:
            joined = " ".join(dependency_units)
            unit_entries.extend([("Requires", joined, False), ("After", joined, False)])

        container_entries: list[tuple[str, Any, bool]] = [
            ("Image", image_file, False),
            ("Pull", "never", False),
            ("ContainerName", container_name, False),
            ("Network", network_file, False),
            ("NetworkAlias", name, False),
        ]
        service_networks = raw.get("networks", {})
        if isinstance(service_networks, list):
            if service_networks not in ([], ["default"]):
                fail(f"service {name} references unsupported networks")
            default_settings: dict[str, Any] = {}
        elif isinstance(service_networks, dict):
            if set(service_networks) - {"default"}:
                fail(f"service {name} references unsupported networks")
            default_settings = service_networks.get("default", {}) or {}
            if not isinstance(default_settings, dict) or set(default_settings) - {
                "aliases",
                "ipv4_address",
            }:
                fail(f"service {name} default network has unsupported settings")
        else:
            fail(f"service {name} networks must be a list or mapping")
        aliases = default_settings.get("aliases", [])
        for alias in string_list(name, "network aliases", aliases):
            container_entries.append(("NetworkAlias", alias, False))
        if "ipv4_address" in default_settings:
            if not isinstance(default_settings["ipv4_address"], str):
                fail(f"service {name} static network address must be a string")
            container_entries.append(("IP", default_settings["ipv4_address"], False))

        list_fields = (
            ("ports", "PublishPort"),
            ("cap_add", "AddCapability"),
            ("cap_drop", "DropCapability"),
            ("devices", "AddDevice"),
            ("extra_hosts", "AddHost"),
            ("group_add", "GroupAdd"),
            ("tmpfs", "Tmpfs"),
            ("security_opt", None),
        )
        for field, key in list_fields:
            values = raw.get(field, [])
            values = string_list(name, field, values)
            if key:
                container_entries.extend((key, value, False) for value in values)
        exposes = raw.get("expose", [])
        if not isinstance(exposes, list) or not all(
            isinstance(value, PRIMITIVES) for value in exposes
        ):
            fail(f"service {name} expose must be a primitive list")
        container_entries.extend(("ExposeHostPort", value, False) for value in exposes)
        volumes = raw.get("volumes", [])
        if not isinstance(volumes, list):
            fail(f"service {name} volumes must be a list")
        container_entries.extend(
            ("Volume", volume_value(name, working_dir, value), False)
            for value in volumes
        )
        if "environment" in raw:
            container_entries.extend(environment_entries(name, raw["environment"], env))
        env_files = as_list(raw.get("env_file", []))
        if not all(isinstance(value, str) for value in env_files):
            fail(f"service {name} env_file must contain paths")
        container_entries.extend(
            ("EnvironmentFile", resolve_runtime_path(working_dir, value), False)
            for value in env_files
        )

        command = raw.get("command")
        if command is not None:
            if isinstance(command, str):
                try:
                    argv = shlex.split(command)
                except ValueError as error:
                    fail(f"service {name} command is invalid: {error}")
            elif isinstance(command, list) and all(
                isinstance(value, PRIMITIVES) for value in command
            ):
                argv = [compose_string(value) for value in command]
            else:
                fail(f"service {name} command must be a string or primitive argv list")
            container_entries.append(("Exec", exec_args(argv), True))
        entrypoint = raw.get("entrypoint")
        if entrypoint is not None:
            if not isinstance(entrypoint, list) or not all(
                isinstance(value, PRIMITIVES) for value in entrypoint
            ):
                fail(f"service {name} entrypoint must be a primitive argv list")
            container_entries.append(
                (
                    "Entrypoint",
                    json.dumps([compose_string(value) for value in entrypoint]),
                    False,
                )
            )

        user = raw.get("user")
        if user is not None:
            if not isinstance(user, str):
                fail(f"service {name} user must be a string")
            user_parts = user.split(":", 1)
            container_entries.append(("User", user_parts[0], False))
            if len(user_parts) == 2:
                container_entries.append(("Group", user_parts[1], False))
        working = raw.get("working_dir")
        if working is not None:
            if not isinstance(working, str) or not working.startswith("/"):
                fail(f"service {name} working_dir must be an absolute string")
            container_entries.append(("WorkingDir", working, False))
        for field, key in (
            ("mem_limit", "Memory"),
            ("pids_limit", "PidsLimit"),
            ("shm_size", "ShmSize"),
        ):
            if field in raw:
                if not isinstance(raw[field], PRIMITIVES):
                    fail(f"service {name} {field} must be a scalar")
                container_entries.append((key, raw[field], False))
        if raw.get("read_only", False):
            if not isinstance(raw["read_only"], bool):
                fail(f"service {name} read_only must be a boolean")
            container_entries.append(("ReadOnly", True, False))
        security = raw.get("security_opt", [])
        unknown_security = set(security) - {
            "no-new-privileges:true",
            "seccomp=unconfined",
        }
        if unknown_security:
            fail(f"service {name} has unsupported security_opt values")
        if "no-new-privileges:true" in security:
            container_entries.append(("NoNewPrivileges", True, False))
        if "seccomp=unconfined" in security:
            container_entries.append(("SeccompProfile", "unconfined", False))
        if "ipc" in raw:
            if raw["ipc"] != "host":
                fail(f"service {name} ipc currently supports only host")
        restart = raw.get("restart", "no")
        if restart not in ("no", "always", "unless-stopped", "on-failure"):
            fail(f"service {name} has unsupported restart policy {restart!r}")
        restart_policy = {
            "no": "no",
            "always": "always",
            "unless-stopped": "always",
            "on-failure": "on-failure",
        }[restart]
        podman_args = ["--ipc=host"] if raw.get("ipc") else []
        container_entries.extend(
            ("PodmanArgs", exec_args([value]), True) for value in podman_args
        )

        ulimits = raw.get("ulimits", {})
        if not isinstance(ulimits, dict):
            fail(f"service {name} ulimits must be a mapping")
        for limit, value in ulimits.items():
            if isinstance(value, dict) and set(value) == {"soft", "hard"}:
                rendered = (
                    f"{limit}={primitive(value['soft'])}:{primitive(value['hard'])}"
                )
            elif isinstance(value, PRIMITIVES):
                rendered = f"{limit}={primitive(value)}"
            else:
                fail(
                    f"service {name} ulimits must contain scalars or soft/hard mappings"
                )
            container_entries.append(("Ulimit", rendered, False))
        container_entries.extend(health_entries(name, raw.get("healthcheck")))
        container_text = render_quadlet(
            [
                ("Unit", unit_entries),
                ("Container", container_entries),
                (
                    "Service",
                    [
                        ("Restart", restart_policy, False),
                        ("TimeoutStartSec", timeout_ready_seconds, False),
                    ],
                ),
                ("Install", [("RequiredBy", public_unit, False)]),
            ]
        )
        (units_dir / container_file).write_text(container_text)
        unit_record = {
            "unit": container_unit,
            "sourcePath": source_path,
            "kind": "container",
            "containerName": container_name,
            "serviceName": name,
        }
        unit_records.append(unit_record)
        container_records.append(
            {
                "unit": container_unit,
                "sourcePath": source_path,
                "name": container_name,
                "serviceName": name,
            }
        )

    # This report is consumed only while combining build outputs.  Runtime
    # lifecycle and health derive exclusively from the generated systemd graph.
    report = {
        "version": 1,
        "kind": "quadlet-build-report",
        "units": [
            {
                "unit": record["unit"],
                "sourcePath": record["sourcePath"],
                "kind": record["kind"],
            }
            for record in unit_records
        ],
        "containers": [{"name": record["name"]} for record in container_records],
        "declaredImages": sorted(set(declared_images)),
        "localImages": list(
            {entry["runtimeRef"]: entry for entry in local_images}.values()
        ),
    }
    (output / "report.json").write_text(
        json.dumps(report, sort_keys=True, indent=2) + "\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        config = json.loads(Path(args.config).read_text())
        output = Path(args.output)
        output.mkdir(parents=True, exist_ok=True)
        compile_bundle(config, output)
    except CompileError as error:
        print(f"quadlet compiler: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
