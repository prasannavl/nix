# pvl-a1 Incus Client Certificate 2026-05

`pvl-a1` trusts a pinned Incus TLS client certificate through
`virtualisation.incus.preseed.certificates`. The host firewall also allows TCP
`8443`, matching the Incus HTTPS listener.

It declares three operator projects through Incus preseed:

- `pvl`
- `abird`
- `abird-dev`

The tenant projects use isolated images, profiles, storage buckets, and storage
volumes. Their `features.networks` value stays `false` because Incus managed
bridge networks are created in the `default` project, not project-local tenant
projects.

Each tenant gets a dedicated managed bridge subnet in the default Incus project:

- `pvl`: `ipvlbr0` on `10.10.23.1/24`
- `abird`: `iabirdbr0` on `10.10.21.1/24`
- `abird-dev`: `iabirddevbr0` on `10.10.22.1/24`

Each tenant project is marked restricted with `restricted.devices.nic=managed`
and `restricted.networks.access` set to only that project's bridge. That means
instances in the project can attach managed NICs only to the allowed subnet:

- `pvl`: only `ipvlbr0`
- `abird`: only `iabirdbr0`
- `abird-dev`: only `iabirddevbr0`

Each tenant project also has a project-local default profile that uses its own
allowed bridge plus the daemon-global `default` storage pool for root disks. The
default Incus project keeps `incusbr0` on `10.10.20.1/24`.

The `pvl` certificate is still an unrestricted admin client certificate. The
`pvl` project restriction controls what instances in the `pvl` project can
attach to; it does not make the admin certificate itself project-limited.

The public certificates live at:

- `data/secrets/incus/pvl.crt`
- `data/secrets/incus/abird.crt`
- `data/secrets/incus/abird-dev.crt`

The private keys are age-encrypted for admins only at:

- `data/secrets/incus/pvl.key.age`
- `data/secrets/incus/abird.key.age`
- `data/secrets/incus/abird-dev.key.age`

PKCS#12 browser/import bundles are age-encrypted for admins only at:

- `data/secrets/incus/pvl.pfx.age`
- `data/secrets/incus/abird.pfx.age`
- `data/secrets/incus/abird-dev.pfx.age`

The PFX bundles use an empty import password. They contain private key material,
so keep only the `.pfx.age` files in the repo and create plaintext PFX files
temporarily outside the repo when importing into a browser or OS certificate
store.

Do not put private keys in Nix store paths or Incus preseed. Incus preseed only
needs the public certificate material so the server can deterministically trust
the same client identities after activation.

Certificate access:

- `pvl`: unrestricted client access, public cert `pvl.crt`, private key
  `pvl.key.age`, fingerprint
  `2D:DD:69:90:53:41:0B:F5:E6:AB:0F:4E:2B:F3:89:32:56:3C:6A:D0:BE:7E:B6:5C:6C:F2:BA:5A:41:1E:6C:F9`
- `abird`: restricted client access to projects `abird` and `abird-dev`, public
  cert `abird.crt`, private key `abird.key.age`, fingerprint
  `AC:E7:CE:92:5C:80:DB:25:7A:FE:6B:FE:D3:86:46:73:27:A6:82:F1:8A:E8:BC:A3:36:5E:EE:D5:A6:4E:2F:34`
- `abird-dev`: restricted client access to project `abird-dev`, public cert
  `abird-dev.crt`, private key `abird-dev.key.age`, fingerprint
  `28:30:8B:39:B8:38:F5:81:9D:DA:24:AE:2B:C9:2C:52:79:39:42:AF:7E:70:C0:0F:97:F2:F3:CD:16:BD:72:A4`

All three certificates are type `client`, have `CA:FALSE`, include the
`clientAuth` extended key usage. The `pvl` and `abird` certificates are valid
from `2026-05-07` to `2036-05-04`; the `abird-dev` certificate is valid from
`2026-05-11` to `2036-05-08`.

To use it from a CLI client, decrypt the private key into that client's Incus
config directory and copy the public cert as the matching client cert. For
browser UI login, decrypt the matching `.pfx.age` outside the repo and import it
into the browser or OS certificate store.
