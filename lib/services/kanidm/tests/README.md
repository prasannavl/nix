# Kanidm Identity Proof

`test_helper.py` exercises localhost-redirect enablement, removal, drift
verification, and unchanged confidential-client behaviour. It also verifies that
changed auto-apply stamps require authentication and successful
verification/application, matching stamps skip work, and failures preserve the
old stamp. `default.nix` also checks that normalization rejects localhost
redirects without public-client PKCE. Both are registered in
`lib/tests/default.nix`.

`authority_proof.py` runs against an **isolated disposable** Kanidm 1.10.4
server using the image digest pinned in `pkgs/ext/kanidm-server/default.nix`:

1. Start it on HTTPS loopback with a private test database and generated test
   TLS certificate. Enable password-only credentials in this disposable fixture
   (`idm_all_persons` credential minimum `any`), not in deployment
   configuration.
2. Recover the fixture's `idm_admin` credential into a private file. Do not
   print or retain it in test reports.
3. Supply Python `requests` and `cryptography`, and run:

   ```bash
   KANIDM_PROOF_URL=https://localhost:18443 \
   KANIDM_PROOF_CA=/absolute/private-fixture/cert.pem \
   KANIDM_PROOF_ADMIN_PASSWORD=/absolute/private-fixture/admin-password \
   python3 lib/services/kanidm/tests/authority_proof.py -v
   ```

4. For the browser leg, also set `KANIDM_PROOF_BROWSER` to Chromium/Chrome and
   provide Node with `playwright` on `NODE_PATH`. The fixture callback listens
   on `127.0.0.1:18642`; leave that port free. This test uses a fresh
   external-browser context and exchanges its code through a separate
   CA-verifying HTTP client.
5. For the SSH leg, set up an isolated SSH forward from another loopback port to
   `127.0.0.1:18642` and set `KANIDM_PROOF_FORWARD_PORT` to that local port. Use
   generated fixture keys, strict client host-key verification, and a server
   permitting only that forwarding destination.
6. Stop and remove the disposable server and SSH processes, then remove private
   fixture state. Keep all temporary files under the repository's `tmp/`.

The suite generates distinct temporary people, a group and an OAuth client. It
cleans up its own records, including on setup failure. Passwords enter the
browser subprocess on stdin; returned authorization codes are captured by the
test process. Neither is printed. A missing browser configuration is reported as
a skipped test, not a passing browser gate.

The parent-expiry regression requires refresh followed by UserInfo. On pinned
1.10.4, refresh can return HTTP 200 after its write invalidates the parent, but
UserInfo on the returned tokens fails. Neither call alone establishes a renewed
controller lease. The suite also proves stable issuer/subject across sessions,
ports and rename, current group UUIDs, separate grant revocation, parent logout,
refresh rotation, and ES256/issuer/audience/nonce/expiry/subject validation.

The Abird controller, hosted-browser, and native application acceptance proofs
belong to the upstream product and are excluded from Pvl. Their commands and
fixture requirements are retained in the
[upstream identity proof guide](https://github.com/abird-ai/z/blob/829d81ed59b06d6d4500c92c5917facabcc92b26/lib/services/kanidm/tests/README.md).
The shared standalone authority/browser fixtures above remain available here;
they are separate from the packaged helper and normalization checks.
