# pvl-a1 Incus Client Certificate 2026-05

`pvl-a1` trusts a pinned Incus TLS client certificate through
`services.incusMachines.global.certificates`. The host firewall also allows TCP
`8443`, matching the Incus HTTPS listener.

As of 2026-05-15, `pvl-a1` is intentionally reduced back to a single default
Incus project. The host preseed declares only the default bridge `incusbr0` on
`10.10.20.1/24`, the default storage pool, and the default profile. The previous
restricted `pvl`, `abird`, and `abird-dev` tenant projects, their project-local
profiles, and their default-project tenant bridges were removed.

The `pvl` certificate is an unrestricted admin client certificate.

The public certificates live at:

- `data/secrets/incus/pvl.crt`

The private keys are age-encrypted for admins only at:

- `data/secrets/incus/pvl.key.age`

PKCS#12 browser/import bundles are age-encrypted for admins only at:

- `data/secrets/incus/pvl.pfx.age`

The PFX bundles use an empty import password. They contain private key material,
so keep only the `.pfx.age` files in the repo and create plaintext PFX files
temporarily outside the repo when importing into a browser or OS certificate
store.

Do not put private keys in Nix store paths or Incus preseed. The
`services.incusMachines.global.certificates` reconciler only needs the public
certificate material so the server can deterministically trust the same client
identities after activation.

The shared Incus helper reconciles declared certificates after
`incus-preseed.service` runs upstream `incus admin init --preseed`, so project
restrictions can reference projects created by preseed. It removes trust-store
entries that match a declared certificate name or fingerprint, plus entries from
the previous successfully applied managed certificate state that are no longer
declared. After certificates are added successfully, it records the current
desired name/fingerprint set under `/var/lib/incus-machines/certificates.json`.
This keeps certificate additions, renames, material changes, project/restriction
changes, and removals declarative instead of failing with
`Certificate already in trust store` or leaving previously managed certificates
behind.

Current certificate access:

- `pvl`: unrestricted client access, public cert `pvl.crt`, private key
  `pvl.key.age`, fingerprint
  `2D:DD:69:90:53:41:0B:F5:E6:AB:0F:4E:2B:F3:89:32:56:3C:6A:D0:BE:7E:B6:5C:6C:F2:BA:5A:41:1E:6C:F9`

The `pvl` certificate is type `client`, has `CA:FALSE`, includes the
`clientAuth` extended key usage, and is valid from `2026-05-07` to `2036-05-04`.

To use it from a CLI client, decrypt the private key into that client's Incus
config directory and copy the public cert as the matching client cert. For
browser UI login, decrypt the matching `.pfx.age` outside the repo and import it
into the browser or OS certificate store.
