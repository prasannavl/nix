# Host Manager Age Armor Decryption 2026-09

Ported from the Abird repository
(`fix(host-manager): decrypt ASCII-armored age
files`).

## Symptom

A fleet deploy failed while acquiring deployment artifacts:

```text
abird-gondor-tictactoe acquisition: unable to decrypt the host-age-identity
SSH key for abird-gondor-tictactoe: attempts failed:
/home/pvl/.ssh/id_ed25519: Header is invalid
```

Only one host failed, so the operator identity looked like the problem.

## Root cause

Some managed machine keys are stored in age ASCII-armor form
(`-----BEGIN AGE ENCRYPTED FILE-----`) instead of the binary age format. The
reference `age` CLI auto-detects armor, so file-level decrypt tooling succeeds,
but the host-manager's in-binary `Age::decrypt`
(`pkgs/tools/abird-host-manager/src/programs/age.rs`) fed the raw stream into
`age::Decryptor::new_buffered`. That parsed the armor marker line as an age
header and returned `DecryptError::InvalidHeader` ("Header is invalid"), which
the per-identity error wrapper then reported against the SSH identity path.

## Fix

`age`'s `armor` feature is enabled and the decryptor wraps the source reader in
`age::armor::ArmoredReader`, which auto-detects armor and passes binary age
through unchanged. This keeps one owner for `.age` decryption across all
in-binary consumers (`native.rs`, `ci_runtime.rs`, `terraform_runtime.rs`,
`ssh_runtime.rs`). Regression coverage lives in the `programs::age` unit tests.

## Gotcha

Stored `.age` files can be either binary or ASCII-armored (`age -a` is used by
some playbooks). When an in-binary `age::DecryptError::InvalidHeader` names a
specific identity, check the ciphertext's first bytes before suspecting the key.
