//! Native username allowlist, with current UID/name consistency vetoes.
//! NSS mappings and account membership are not per-attempt process provenance.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString};

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

const MAX_CLIENTS: usize = 64;
const MAX_NAME: usize = 64;
const LOOKUP_BYTES: usize = 64 * 1024;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Client {
    pub uid: u32,
    pub user: String,
}

pub(super) fn validate(clients: &[Client]) -> Result<()> {
    ensure!(
        !clients.is_empty() && clients.len() <= MAX_CLIENTS,
        "invalid native client count"
    );
    let mut uids = BTreeSet::new();
    let mut names = BTreeSet::new();
    for client in clients {
        let name = client.user.as_bytes();
        ensure!(
            client.uid > 0
                && client.uid < u32::MAX
                && uids.insert(client.uid)
                && names.insert(&client.user)
                && client.user != "root"
                && !name.is_empty()
                && name.len() <= MAX_NAME
                && (name[0].is_ascii_alphabetic() || name[0] == b'_')
                && name
                    .iter()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(b)),
            "invalid native client identity"
        );
    }
    Ok(())
}

pub(super) fn validate_workload(clients: &[Client], workload: &[u32]) -> Result<()> {
    validate(clients)?;
    ensure!(
        clients.iter().all(|client| workload.contains(&client.uid)),
        "native client outside workload identities"
    );
    Ok(())
}

pub(super) fn allowed(clients: &[Client]) -> String {
    clients
        .iter()
        .map(|client| client.user.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) fn verify(clients: &[Client]) -> Result<()> {
    verify_with(
        clients,
        |uid| lookup(Key::Uid(uid)),
        |user| lookup(Key::Name(user)),
    )
}

fn verify_with(
    clients: &[Client],
    mut by_uid: impl FnMut(u32) -> Result<(u32, String)>,
    mut by_name: impl FnMut(&str) -> Result<(u32, String)>,
) -> Result<()> {
    validate(clients)?;
    for (uid, name) in std::iter::once((0, "root")).chain(
        clients
            .iter()
            .map(|client| (client.uid, client.user.as_str())),
    ) {
        for (actual_uid, actual_name) in [by_uid(uid)?, by_name(name)?] {
            ensure!(
                actual_uid == uid && actual_name == name,
                "native client account mapping differs"
            );
        }
    }
    Ok(())
}

enum Key<'a> {
    Uid(u32),
    Name(&'a str),
}

// Fixed capture allocation; NSS itself can block. Run inside the accounted role
// after its durable claim, then recheck the original owner/deadline before exec.
fn lookup(key: Key<'_>) -> Result<(u32, String)> {
    let mut buffer = vec![0u8; LOOKUP_BYTES];
    let mut record = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let code = match key {
        Key::Uid(uid) => unsafe {
            libc::getpwuid_r(
                uid,
                record.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        },
        Key::Name(name) => {
            let name = CString::new(name)?;
            unsafe {
                libc::getpwnam_r(
                    name.as_ptr(),
                    record.as_mut_ptr(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                    &mut result,
                )
            }
        }
    };
    ensure!(
        code == 0 && result == record.as_mut_ptr(),
        "native client account lookup unavailable"
    );
    let record = unsafe { record.assume_init() };
    ensure!(
        !record.pw_name.is_null(),
        "native client account name unavailable"
    );
    let name = unsafe { CStr::from_ptr(record.pw_name) }.to_bytes();
    ensure!(
        name.len() <= MAX_NAME,
        "native client account name exceeds bound"
    );
    let name = std::str::from_utf8(name)
        .map_err(|_| anyhow::anyhow!("native client account name unavailable"))?;
    Ok((record.pw_uid, name.to_owned()))
}

#[cfg(test)]
mod tests;
