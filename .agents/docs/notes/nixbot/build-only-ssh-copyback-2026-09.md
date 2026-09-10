# Build-only authenticated builder copy-back

## Trigger

A remote `nixbot build` completed the `gap3-gondor` realization on `abird-ci`
but failed while importing the result into the operator store. The configured
cache URL used private service DNS that resolved from managed hosts but not from
the operator. Retrying the same HTTP request revalidated the builder output but
could not change the operator's DNS boundary.

The recent system changes produced a new store path and exposed the latent
transport dependency; the build itself succeeded. Dependent hosts were reported
failed only because the parent build result was not imported locally.

## Ownership boundary

Remote build-only actions copy their result directly from the authenticated
`ssh-ng://<build-host>` store. This reuses the resolved builder endpoint, SSH
identity, host-key policy, proxy route, transport retry, and builder lease that
already protected the realization. Local closure-size resolution remains the
post-copy registration check.

Remote deployments retain the signed-cache contract. Same-store targets verify
offline; distinct-store targets use the configured signed cache and the existing
automatic relay policy. No deployment target may activate a closure merely
because build-only SSH copy-back succeeded.

## Regression contract

The Bash regression test configures a matching builder cache but asserts that
build-only copy-back:

- does not consult cache trust or the cache URL;
- preserves the resolved `NIX_SSHOPTS` value;
- copies from the exact `ssh-ng://` builder store URI; and
- retains builder-output revalidation before local closure inspection.

The Bash implementation and this regression are maintained in both the Abird and
Pvl repositories. The native Rust fleet implementation already owns the same
direct-builder copy-back boundary.
