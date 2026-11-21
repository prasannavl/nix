"""Pure reference normalization for modern and legacy Nix path-info JSON."""
import re

_STORE = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+\Z")


def _path(value):
    if not isinstance(value, str) or not _STORE.fullmatch(value):
        raise ValueError("noncanonical store path")
    return value


def path_info_references(value):
    """Normalize references; callers still verify queried/physical closure equality.

    JSON must already have been parsed with duplicate-key rejection. Modern Nix
    keys metadata by store path; legacy Nix includes path in each array element.
    This is neither content/signature admission nor a filesystem observation.
    """
    if isinstance(value, dict) and value:
        items = list(value.items())
    elif isinstance(value, list) and value:
        if any(not isinstance(info, dict) or "path" not in info for info in value):
            raise ValueError("invalid legacy path-info entry")
        items = [(info["path"], info) for info in value]
    else:
        raise ValueError("expected nonempty path-info map or array")
    result = {}
    for path, info in items:
        _path(path)
        if path in result or not isinstance(info, dict):
            raise ValueError("duplicate path or nonobject path-info entry")
        if "path" in info and info["path"] != path:
            raise ValueError("path-info key/path mismatch")
        if "storeDir" in info and info["storeDir"] != "/nix/store":
            raise ValueError("foreign store directory")
        references = info.get("references")
        if not isinstance(references, list):
            raise ValueError("references must be an array")
        refs = [_path(reference) for reference in references]
        if len(refs) != len(set(refs)):
            raise ValueError("duplicate reference")
        result[path] = sorted(refs)
    return result
