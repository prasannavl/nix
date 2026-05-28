#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate repo-declared Incus client cert/key/PFX artifacts."
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        type=pathlib.Path,
        help="Repository root. Defaults to git rev-parse --show-toplevel.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing public certs or encrypted outputs.",
    )
    parser.add_argument(
        "--pfx-password",
        default=os.environ.get("PFX_PASSWORD"),
        help="Password for generated .pfx files. Defaults to PFX_PASSWORD or empty.",
    )
    parser.add_argument(
        "--pfx-password-file",
        default=(
            pathlib.Path(os.environ["PFX_PASSWORD_FILE"])
            if "PFX_PASSWORD_FILE" in os.environ
            else None
        ),
        type=pathlib.Path,
        help="File containing the .pfx password. Defaults to PFX_PASSWORD_FILE.",
    )
    parser.add_argument(
        "--config-expr",
        default=os.environ.get("INCUS_CERTS_CONFIG_EXPR"),
        help="Nix expression that evaluates to generatorConfig JSON.",
    )
    parser.add_argument(
        "--config-file",
        default=None,
        type=pathlib.Path,
        help="JSON file containing generatorConfig. Overrides --config-expr.",
    )
    parser.add_argument(
        "selectors",
        nargs="*",
        help="Optional user, project, or user/project selectors.",
    )
    return parser.parse_args()


def run(
    cmd: list[str],
    *,
    cwd: pathlib.Path | None = None,
    stdin: bytes | None = None,
) -> bytes:
    try:
        return subprocess.check_output(cmd, cwd=cwd, input=stdin, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode(errors="replace").strip()
        message = " ".join(cmd)
        if stderr:
            message = f"{message}\n{stderr}"
        raise SystemExit(message) from exc


def repo_root(arg_root: pathlib.Path | None) -> pathlib.Path:
    if arg_root is not None:
        return arg_root.resolve()
    out = run(["git", "rev-parse", "--show-toplevel"])
    return pathlib.Path(out.decode().strip()).resolve()


def read_pfx_password(args: argparse.Namespace) -> bytes:
    password_file = args.pfx_password_file
    if password_file:
        return password_file.expanduser().read_text().rstrip("\n").encode()
    return (args.pfx_password or "").encode()


def load_config(root: pathlib.Path, args: argparse.Namespace) -> list[dict]:
    if args.config_file is not None:
        config = json.loads(args.config_file.expanduser().read_text())
        if not isinstance(config, list):
            raise SystemExit("Unexpected Incus cert generator config shape")
        return config

    expr = args.config_expr
    if not expr:
        raise SystemExit("Pass --config-expr, --config-file, or INCUS_CERTS_CONFIG_EXPR")
    out = run(["nix", "eval", "--impure", "--json", "--expr", expr], cwd=root)
    config = json.loads(out)
    if not isinstance(config, list):
        raise SystemExit("Unexpected Incus cert generator config shape")
    return config


def selected(entry: dict, selectors: list[str]) -> bool:
    if not selectors:
        return True
    user = entry["user"]
    projects = set(entry["projects"])
    name = entry["name"]
    return any(
        selector == user
        or selector == name
        or selector in projects
        or any(selector == f"{user}/{project}" for project in projects)
        for selector in selectors
    )


def generate_private_key(key_type: str):
    if key_type == "ecdsa-p256":
        return ec.generate_private_key(ec.SECP256R1())
    if key_type == "rsa-3072":
        return rsa.generate_private_key(public_exponent=65537, key_size=3072)
    if key_type == "rsa-4096":
        return rsa.generate_private_key(public_exponent=65537, key_size=4096)
    raise SystemExit(f"Unsupported Incus client key type: {key_type}")


def generate_certificate(entry: dict, private_key):
    now = datetime.now(timezone.utc)
    subject = issuer = x509.Name(
        [x509.NameAttribute(NameOID.COMMON_NAME, f"{entry['name']}-incus")]
    )
    return (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=int(entry["days"])))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=isinstance(private_key, rsa.RSAPrivateKey),
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]),
            critical=False,
        )
        .sign(private_key, hashes.SHA256())
    )


def serialize_pfx(entry: dict, private_key, cert, password: bytes) -> bytes:
    encryption = (
        serialization.BestAvailableEncryption(password)
        if password
        else serialization.NoEncryption()
    )
    return pkcs12.serialize_key_and_certificates(
        name=entry["name"].encode(),
        key=private_key,
        cert=cert,
        cas=None,
        encryption_algorithm=encryption,
    )


def check_outputs(paths: list[pathlib.Path], force: bool) -> None:
    existing = [path for path in paths if path.exists()]
    if existing and not force:
        formatted = "\n".join(f"  {path}" for path in existing)
        raise SystemExit(f"Refusing to overwrite existing files without --force:\n{formatted}")


def encrypt_bytes(root: pathlib.Path, data: bytes, output: pathlib.Path, recipients: list[str]) -> None:
    if not recipients:
        raise SystemExit(f"No recipients configured for {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=root / "tmp") as tmp:
        tmp.write(data)
        tmp.flush()
        cmd = ["age"]
        for recipient in recipients:
            cmd.extend(["-r", recipient])
        cmd.extend(["-o", str(output), tmp.name])
        run(cmd)
    output.chmod(0o600)


def generate_entry(root: pathlib.Path, entry: dict, pfx_password: bytes, force: bool) -> None:
    public_cert = root / entry["publicCert"]
    key_age = root / entry["keyAge"]
    pfx_age = root / entry["pfxAge"]
    check_outputs([public_cert, key_age, pfx_age], force)

    private_key = generate_private_key(entry["keyType"])
    cert = generate_certificate(entry, private_key)
    key_pem = private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    cert_pem = cert.public_bytes(serialization.Encoding.PEM)
    pfx = serialize_pfx(entry, private_key, cert, pfx_password)

    public_cert.parent.mkdir(parents=True, exist_ok=True)
    public_cert.write_bytes(cert_pem)
    public_cert.chmod(0o644)
    encrypt_bytes(root, key_pem, key_age, entry["recipients"])
    encrypt_bytes(root, pfx, pfx_age, entry["recipients"])

    print(f"wrote {public_cert}")
    print(f"wrote {key_age}")
    print(f"wrote {pfx_age}")


def main() -> None:
    args = parse_args()
    root = repo_root(args.repo_root)
    (root / "tmp").mkdir(exist_ok=True)
    pfx_password = read_pfx_password(args)

    entries = [entry for entry in load_config(root, args) if selected(entry, args.selectors)]
    if not entries:
        raise SystemExit("No Incus cert entries matched the supplied selectors")
    for entry in entries:
        generate_entry(root, entry, pfx_password, args.force)


if __name__ == "__main__":
    main()
