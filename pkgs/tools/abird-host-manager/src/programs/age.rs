//! In-binary `.age` decryption (binary and ASCII-armored formats).

use std::fs::File;
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use tempfile::NamedTempFile;
use zeroize::Zeroizing;

/// Upper bound on an identity file, mirroring the reference `age` implementation.
const IDENTITY_SIZE_LIMIT: u64 = 1 << 24;

/// Upper bound on the SSH-key portion of an identity file, mirroring the
/// reference `age` implementation.
const SSH_IDENTITY_SIZE_LIMIT: u64 = 1 << 14;

/// Decrypts `.age` files in-process with the RustCrypto `age` crate.
///
/// Both the binary age format and the ASCII-armored
/// (`-----BEGIN AGE ENCRYPTED FILE-----`) encoding are accepted; the armor is
/// auto-detected per file.
///
/// There is no external `age` program, no runtime override, and no fallback: a
/// candidate identity is parsed as an [`age::x25519::Identity`] when it is an
/// age identity file and as an [`age::ssh::Identity`] when it is an OpenSSH
/// private key. `age-plugin-*` identities and recipients are unsupported, and
/// passphrase-protected keys fail instead of prompting.
#[derive(Clone, Copy, Debug, Default)]
pub struct Age;

impl Age {
    pub fn new() -> Self {
        Self
    }

    /// Decrypts `source` into `destination` with the first candidate identity
    /// that can unwrap the file key.
    ///
    /// Candidates are tried in the order given by `identities`; candidates that
    /// are not files are skipped. The plaintext is written to a sibling
    /// temporary file with mode `0600` and renamed over `destination` only on
    /// success, so a corrupt or truncated ciphertext never leaves a partial
    /// plaintext and no output appears when no identity matches.
    pub fn decrypt(&self, source: &Path, identities: &[PathBuf], destination: &Path) -> Result<()> {
        let mut attempts = Vec::new();
        for identity in identities {
            if !identity.is_file() {
                continue;
            }
            match decrypt_with_identity(source, identity, destination) {
                Ok(()) => return Ok(()),
                Err(error) => attempts.push(format!("{}: {error:#}", identity.display())),
            }
        }
        if attempts.is_empty() {
            bail!("no usable age identities were found");
        }
        bail!("attempts failed: {}", attempts.join("; "))
    }
}

fn decrypt_with_identity(source: &Path, identity: &Path, destination: &Path) -> Result<()> {
    let identities = parse_identity(identity)?;
    let file = File::open(source)?;
    // `ArmoredReader` auto-detects ASCII armor and otherwise passes the binary
    // age format through unchanged, mirroring the reference `age` CLI.
    let decryptor = age::Decryptor::new_buffered(age::armor::ArmoredReader::new(file))?;
    let mut plaintext = decryptor.decrypt(identities.iter().map(|identity| &**identity))?;

    // Write beside the destination so the final rename stays on one filesystem.
    // `NamedTempFile` creates the file with mode 0600 and removes it on drop, so
    // every failure path below cleans up the temporary output.
    let parent = destination
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(parent).with_context(|| {
        format!(
            "create temporary decryption output beside {}",
            destination.display()
        )
    })?;
    std::io::copy(&mut plaintext, temporary.as_file_mut())
        .with_context(|| format!("write decrypted output for {}", destination.display()))?;
    temporary
        .as_file_mut()
        .flush()
        .with_context(|| format!("flush decrypted output for {}", destination.display()))?;
    temporary
        .persist(destination)
        .map_err(|error| error.error)
        .with_context(|| format!("replace {} with decrypted output", destination.display()))?;
    Ok(())
}

/// Parses one candidate identity file into the identities it declares.
///
/// Input is read as bytes so a non-UTF-8 identity still reaches the parsers.
/// SSH/PEM input is detected by its header and parsed first; the line-based age
/// identity parse is attempted only when `ssh::Identity::from_buffer` itself
/// fails, surfacing the SSH error when both fail, mirroring the reference `age`
/// fallback behaviour. A key that `from_buffer` parsed but that is
/// passphrase-protected or unsupported is reported directly, without a
/// line-based retry.
fn parse_identity(path: &Path) -> Result<Vec<Box<dyn age::Identity>>> {
    let contents = read_identity(path)?;

    if contains_pem_header(&contents) {
        match parse_ssh_identity(path, &contents) {
            Ok(identity) => {
                ensure_ssh_identity_is_usable(path, &identity)?;
                return Ok(vec![Box::new(identity)]);
            }
            Err(ssh_error) => match parse_line_identities(path, &contents) {
                Ok(identities) => return Ok(identities),
                Err(_) => return Err(ssh_error),
            },
        }
    }

    parse_line_identities(path, &contents)
}

/// Reads an identity file as bytes, rejecting input larger than the reference
/// size limit instead of truncating it.
fn read_identity(path: &Path) -> Result<Zeroizing<Vec<u8>>> {
    let file = File::open(path)?;
    let mut contents = Zeroizing::new(Vec::new());
    BufReader::new(file)
        .take(IDENTITY_SIZE_LIMIT + 1)
        .read_to_end(&mut contents)
        .map_err(|error| anyhow::anyhow!("read age identity {}: {error}", path.display()))?;
    if contents.len() as u64 > IDENTITY_SIZE_LIMIT {
        bail!(
            "age identity {} exceeds the {IDENTITY_SIZE_LIMIT} byte limit",
            path.display()
        );
    }
    Ok(contents)
}

fn contains_pem_header(contents: &[u8]) -> bool {
    const PEM_HEADER: &[u8] = b"-----BEGIN";
    contents
        .windows(PEM_HEADER.len())
        .any(|window| window == PEM_HEADER)
}

/// Parses a single multi-line OpenSSH private key, capped at the reference
/// SSH-key size limit.
fn parse_ssh_identity(path: &Path, contents: &[u8]) -> Result<age::ssh::Identity> {
    age::ssh::Identity::from_buffer(
        BufReader::new(contents).take(SSH_IDENTITY_SIZE_LIMIT),
        Some(path.display().to_string()),
    )
    .map_err(|error| anyhow::anyhow!("parse SSH identity {}: {error}", path.display()))
}

/// Rejects a parsed SSH key that cannot be used without an interactive unlock.
fn ensure_ssh_identity_is_usable(path: &Path, identity: &age::ssh::Identity) -> Result<()> {
    match identity {
        age::ssh::Identity::Unencrypted(_) => Ok(()),
        age::ssh::Identity::Encrypted(_) => bail!(
            "SSH identity {} is passphrase-protected and cannot be unlocked non-interactively",
            path.display()
        ),
        age::ssh::Identity::Unsupported(key) => {
            bail!("SSH identity {} is unsupported: {key:?}", path.display())
        }
    }
}

/// Parses a file of one `AGE-SECRET-KEY-1...` identity per line.
fn parse_line_identities(path: &Path, contents: &[u8]) -> Result<Vec<Box<dyn age::Identity>>> {
    let mut identities: Vec<Box<dyn age::Identity>> = Vec::new();
    for (index, raw) in contents.split(|byte| *byte == b'\n').enumerate() {
        let Ok(line) = std::str::from_utf8(raw) else {
            bail!(
                "age identity {} contains non-identity data on line {}",
                path.display(),
                index + 1
            );
        };
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let identity = line.parse::<age::x25519::Identity>().map_err(|error| {
            anyhow::anyhow!(
                "age identity {} contains non-identity data on line {}: {error}",
                path.display(),
                index + 1
            )
        })?;
        identities.push(Box::new(identity));
    }
    if identities.is_empty() {
        bail!("age identity {} contains no identities", path.display());
    }
    Ok(identities)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    use age::secrecy::ExposeSecret;

    /// A throwaway `ssh-ed25519` key pair generated for this test suite only.
    const TEST_SSH_IDENTITY: &str = "\
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAF0bQ+BmRkHTh52NIc6rYABmWalhiq0NqUcy9cLcTeZQAAAKh2TpQ2dk6U
NgAAAAtzc2gtZWQyNTUxOQAAACAF0bQ+BmRkHTh52NIc6rYABmWalhiq0NqUcy9cLcTeZQ
AAAEBTeXBBfngAgyrH0x2SvbT4nQ6sXUBV2YobQpVNS1ahLwXRtD4GZGQdOHnY0hzqtgAG
ZZqWGKrQ2pRzL1wtxN5lAAAAH2FiaXJkLWhvc3QtbWFuYWdlciB0ZXN0IGZpeHR1cmUBAg
MEBQY=
-----END OPENSSH PRIVATE KEY-----
";
    const TEST_SSH_RECIPIENT: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAXRtD4GZGQdOHnY0hzqtgAGZZqWGKrQ2pRzL1wtxN5l abird-host-manager test fixture";

    /// The same fixture key protected with a passphrase, which has no
    /// non-interactive unlock path.
    const TEST_SSH_ENCRYPTED_IDENTITY: &str = "\
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDoa+NFG6
o0CVzqmgpbwF4GAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIuxkpGM/cX5cQjX
Crw8JqVPao1X5z+gCP4SFHK+b7tbAAAAsOl4Ha//Cx/t7F4pbfmxMP/Cy2xv3qmmOOQP1Y
7Mrxy1zymryym3chXpOckZZzafv3SotPSZ5uoXzP2o51qqYukgWQgH+8SZ5rurXv/rYzYE
WK2RuW0p77MMbXuYMdQ9J6l/aLoeL9Ao9Gu04iS4qs0eKrf7UhZyuXlUVpU2si4lFkdgUt
yqPpbFFUX2lXWPH9I3zqYt2VnWDScGTitnk6RpLFwc3nSFWiDm1rkzj/Tf
-----END OPENSSH PRIVATE KEY-----
";

    fn encrypt_to_recipient(recipient: &age::x25519::Recipient, plaintext: &[u8]) -> Vec<u8> {
        age::encrypt(recipient, plaintext).unwrap()
    }

    #[test]
    fn x25519_identity_round_trips_through_the_in_binary_decryptor() {
        let directory = tempfile::tempdir().unwrap();
        let identity = age::x25519::Identity::generate();
        let source = directory.path().join("secret.age");
        let identity_file = directory.path().join("identity");
        let destination = directory.path().join("secret");
        std::fs::write(
            &source,
            encrypt_to_recipient(&identity.to_public(), b"plaintext\n"),
        )
        .unwrap();
        std::fs::write(
            &identity_file,
            format!(
                "# created by the test fixture\n# public key: {}\n{}\n",
                identity.to_public(),
                identity.to_string().expose_secret()
            ),
        )
        .unwrap();

        Age::new()
            .decrypt(&source, &[identity_file], &destination)
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(&destination).unwrap(),
            "plaintext\n"
        );
        assert_eq!(
            std::fs::metadata(&destination)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn ascii_armored_ciphertext_round_trips_through_the_in_binary_decryptor() {
        let directory = tempfile::tempdir().unwrap();
        let identity = age::x25519::Identity::generate();
        let source = directory.path().join("secret.age");
        let identity_file = directory.path().join("identity");
        let destination = directory.path().join("secret");
        std::fs::write(&identity_file, identity.to_string().expose_secret()).unwrap();

        let ciphertext = encrypt_to_recipient(&identity.to_public(), b"armored\n");
        let mut armored = Vec::new();
        {
            let mut writer = age::armor::ArmoredWriter::wrap_output(
                &mut armored,
                age::armor::Format::AsciiArmor,
            )
            .unwrap();
            writer.write_all(&ciphertext).unwrap();
            writer.finish().unwrap();
        }
        assert!(armored.starts_with(b"-----BEGIN AGE ENCRYPTED FILE-----"));
        std::fs::write(&source, armored).unwrap();

        Age::new()
            .decrypt(&source, &[identity_file], &destination)
            .unwrap();

        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "armored\n");
    }

    #[test]
    fn an_unreadable_candidate_is_skipped_for_the_next_identity() {
        let directory = tempfile::tempdir().unwrap();
        let identity = age::x25519::Identity::generate();
        let source = directory.path().join("secret.age");
        let unrelated = directory.path().join("unrelated.age");
        let identity_file = directory.path().join("identity");
        let destination = directory.path().join("secret");
        std::fs::write(
            &source,
            encrypt_to_recipient(&identity.to_public(), b"plaintext"),
        )
        .unwrap();
        std::fs::write(
            &unrelated,
            encrypt_to_recipient(&age::x25519::Identity::generate().to_public(), b"other"),
        )
        .unwrap();
        std::fs::write(&identity_file, identity.to_string().expose_secret()).unwrap();

        Age::new()
            .decrypt(
                &source,
                &[
                    directory.path().join("missing-identity"),
                    identity_file.clone(),
                ],
                &destination,
            )
            .unwrap();
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "plaintext");

        std::fs::remove_file(&destination).unwrap();
        let error = Age::new()
            .decrypt(&unrelated, &[identity_file], &destination)
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("attempts failed"),
            "{error:#}"
        );
        assert!(!destination.exists(), "failed decryption created output");
    }

    #[test]
    fn ssh_ed25519_identity_round_trips_through_the_in_binary_decryptor() {
        let directory = tempfile::tempdir().unwrap();
        let recipient = TEST_SSH_RECIPIENT.parse::<age::ssh::Recipient>().unwrap();
        let source = directory.path().join("secret.age");
        let identity_file = directory.path().join("id_ed25519");
        let destination = directory.path().join("secret");
        std::fs::write(
            &source,
            age::encrypt(&recipient, b"ssh plaintext\n").unwrap(),
        )
        .unwrap();
        std::fs::write(&identity_file, TEST_SSH_IDENTITY).unwrap();

        Age::new()
            .decrypt(&source, &[identity_file], &destination)
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(&destination).unwrap(),
            "ssh plaintext\n"
        );
    }

    #[test]
    fn passphrase_protected_ssh_identities_fail_without_prompting() {
        let directory = tempfile::tempdir().unwrap();
        let recipient = TEST_SSH_RECIPIENT.parse::<age::ssh::Recipient>().unwrap();
        let source = directory.path().join("secret.age");
        let identity_file = directory.path().join("id_ed25519");
        std::fs::write(
            &source,
            age::encrypt(&recipient, b"ssh plaintext\n").unwrap(),
        )
        .unwrap();
        std::fs::write(&identity_file, TEST_SSH_ENCRYPTED_IDENTITY).unwrap();

        let error = Age::new()
            .decrypt(&source, &[identity_file], &directory.path().join("secret"))
            .unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("passphrase-protected"), "{message}");
    }

    #[test]
    fn identities_without_a_readable_candidate_report_the_identity_absence() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("secret.age");
        std::fs::write(&source, b"not really encrypted").unwrap();

        let error = Age::new()
            .decrypt(
                &source,
                &[directory.path().join("missing-identity")],
                &directory.path().join("secret"),
            )
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("no usable age identities were found"),
            "{error:#}"
        );
    }

    #[test]
    fn plugin_and_non_identity_files_are_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let identity_file = directory.path().join("identity");
        std::fs::write(&identity_file, "AGE-PLUGIN-EXAMPLE-1XYZ\n").unwrap();

        let error = parse_identity(&identity_file).err().unwrap();
        assert!(
            format!("{error:#}").contains("non-identity data on line 1"),
            "{error:#}"
        );
    }

    #[test]
    fn truncated_ciphertext_preserves_the_existing_destination_and_removes_the_temp() {
        let directory = tempfile::tempdir().unwrap();
        let identity = age::x25519::Identity::generate();
        let identity_file = directory.path().join("identity");
        let destination = directory.path().join("secret");
        std::fs::write(&identity_file, identity.to_string().expose_secret()).unwrap();

        let mut ciphertext = encrypt_to_recipient(&identity.to_public(), b"plaintext\n");
        ciphertext.truncate(ciphertext.len() - 16);
        let source = directory.path().join("secret.age");
        std::fs::write(&source, ciphertext).unwrap();

        std::fs::write(&destination, b"previous\n").unwrap();
        let error = Age::new()
            .decrypt(&source, &[identity_file], &destination)
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("attempts failed"),
            "{error:#}"
        );
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "previous\n");

        let mut names: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["identity", "secret", "secret.age"]);
    }

    #[test]
    fn ssh_parse_failure_still_attempts_the_line_based_identities() {
        let directory = tempfile::tempdir().unwrap();
        let identity = age::x25519::Identity::generate();
        let source = directory.path().join("secret.age");
        let identity_file = directory.path().join("identity");
        let destination = directory.path().join("secret");
        std::fs::write(
            &source,
            encrypt_to_recipient(&identity.to_public(), b"fallback\n"),
        )
        .unwrap();
        // The `-----BEGIN` header routes the file to the SSH parser, which
        // rejects this comment; the valid line-based identity must still be used.
        std::fs::write(
            &identity_file,
            format!(
                "# -----BEGIN OPENSSH PRIVATE KEY-----\n{}\n",
                identity.to_string().expose_secret()
            ),
        )
        .unwrap();

        Age::new()
            .decrypt(&source, &[identity_file], &destination)
            .unwrap();
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "fallback\n");
    }

    #[test]
    fn non_utf8_identity_reports_a_parse_error_instead_of_a_read_error() {
        let directory = tempfile::tempdir().unwrap();
        let identity = age::x25519::Identity::generate();
        let identity_file = directory.path().join("identity");
        let mut contents = vec![0xff, 0xfe, b'\n'];
        contents.extend_from_slice(identity.to_string().expose_secret().as_bytes());
        std::fs::write(&identity_file, contents).unwrap();

        let error = parse_identity(&identity_file).err().unwrap();
        let message = format!("{error:#}");
        assert!(message.contains("non-identity data on line 1"), "{message}");
        assert!(!message.contains("read age identity"), "{message}");
    }

    #[test]
    fn ssh_identity_parsing_is_capped_at_the_reference_size_limit() {
        let directory = tempfile::tempdir().unwrap();
        let identity_file = directory.path().join("identity");
        let mut contents = vec![b'\n'; SSH_IDENTITY_SIZE_LIMIT as usize];
        contents.extend_from_slice(TEST_SSH_IDENTITY.as_bytes());
        std::fs::write(&identity_file, contents).unwrap();

        let error = parse_identity(&identity_file).err().unwrap();
        let message = format!("{error:#}");
        assert!(message.contains("parse SSH identity"), "{message}");
    }

    #[test]
    fn identity_files_at_the_reference_size_limit_parse_and_larger_files_are_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let identity_file = directory.path().join("identity");
        let identity = age::x25519::Identity::generate();

        // Padding is a single comment line, so a file at exactly the limit parses.
        let mut contents = identity.to_string().expose_secret().as_bytes().to_vec();
        contents.push(b'\n');
        contents.resize(IDENTITY_SIZE_LIMIT as usize, b'#');
        std::fs::write(&identity_file, &contents).unwrap();
        assert_eq!(parse_identity(&identity_file).unwrap().len(), 1);

        // One byte more is rejected instead of silently truncating the input.
        contents.push(b'#');
        std::fs::write(&identity_file, &contents).unwrap();
        let error = parse_identity(&identity_file).err().unwrap();
        let message = format!("{error:#}");
        assert!(
            message.contains("exceeds the") && message.contains("byte limit"),
            "{message}"
        );
    }
}
