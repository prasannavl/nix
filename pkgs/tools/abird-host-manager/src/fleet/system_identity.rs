//! Local host identity and address discovery for controller self-target
//! planning.
//!
//! These helpers use libc directly so a controller can decide whether it is
//! itself the deploy target without depending on the `hostname`, `ip`,
//! `getent`, or `id` command-line tools.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString};
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, ToSocketAddrs};

use anyhow::{Context, Result, bail};

/// Host names that identify the local machine: the kernel node name, its short
/// form, and the canonical name (FQDN) when the resolver supplies one.
pub fn local_host_aliases() -> BTreeSet<String> {
    let mut aliases = BTreeSet::new();
    if let Some(node) = node_name() {
        add_name_and_short(&mut aliases, &node);
        if let Some(canonical) = canonical_name(&node) {
            add_name_and_short(&mut aliases, &canonical);
        }
    }
    aliases
}

fn add_name_and_short(aliases: &mut BTreeSet<String>, name: &str) {
    let name = name.trim();
    if name.is_empty() {
        return;
    }
    aliases.insert(name.to_owned());
    if let Some(short) = name.split('.').next().filter(|short| !short.is_empty()) {
        aliases.insert(short.to_owned());
    }
}

fn node_name() -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: `buffer` is a valid writable array of `buffer.len()` bytes.
    let result =
        unsafe { libc::gethostname(buffer.as_mut_ptr() as *mut libc::c_char, buffer.len()) };
    if result != 0 {
        return None;
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(buffer.len());
    let name = String::from_utf8_lossy(&buffer[..end]).trim().to_owned();
    (!name.is_empty()).then_some(name)
}

fn canonical_name(node: &str) -> Option<String> {
    let node = CString::new(node).ok()?;
    // SAFETY: a zeroed `addrinfo` is a valid starting value; every field we do
    // not set stays null, which the resolver treats as "no preference".
    let mut hints: libc::addrinfo = unsafe { std::mem::zeroed() };
    hints.ai_family = libc::AF_UNSPEC;
    hints.ai_socktype = libc::SOCK_STREAM;
    hints.ai_flags = libc::AI_CANONNAME;
    let mut result: *mut libc::addrinfo = std::ptr::null_mut();
    // SAFETY: `node` is a valid C string and `result` is a valid out-pointer.
    let code = unsafe { libc::getaddrinfo(node.as_ptr(), std::ptr::null(), &hints, &mut result) };
    if code != 0 || result.is_null() {
        return None;
    }
    let mut canonical = None;
    let mut cursor = result;
    while !cursor.is_null() {
        // SAFETY: `cursor` is a node in the `getaddrinfo` result list.
        let entry = unsafe { &*cursor };
        if !entry.ai_canonname.is_null() {
            // SAFETY: `ai_canonname` is NUL-terminated when non-null.
            let name = unsafe { CStr::from_ptr(entry.ai_canonname) }
                .to_string_lossy()
                .trim()
                .to_owned();
            if !name.is_empty() {
                canonical = Some(name);
                break;
            }
        }
        cursor = entry.ai_next;
    }
    // SAFETY: `result` is the pointer returned by `getaddrinfo`.
    unsafe { libc::freeaddrinfo(result) };
    canonical
}

/// Local interface addresses (including loopback) as canonical display
/// strings.
pub fn local_ip_addresses() -> Result<BTreeSet<String>> {
    let mut addresses = BTreeSet::new();
    let mut interfaces: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: `interfaces` is a valid out-pointer for `getifaddrs`.
    if unsafe { libc::getifaddrs(&mut interfaces) } != 0 {
        return Err(io::Error::last_os_error()).context("enumerate local interface addresses");
    }
    let mut cursor = interfaces;
    while !cursor.is_null() {
        // SAFETY: `cursor` is a node in the `getifaddrs` list.
        let interface = unsafe { &*cursor };
        // Match `ip -o addr show up`: only interfaces that are administratively
        // up contribute addresses to self-target classification.
        let is_up = interface.ifa_flags & libc::IFF_UP as u32 != 0;
        if is_up && !interface.ifa_addr.is_null() {
            // SAFETY: `ifa_addr` is non-null and its family selects the layout.
            let family = unsafe { (*interface.ifa_addr).sa_family as i32 };
            match family {
                libc::AF_INET => {
                    // SAFETY: `AF_INET` proves the `sockaddr_in` layout.
                    let address = unsafe { &*(interface.ifa_addr as *const libc::sockaddr_in) };
                    addresses
                        .insert(Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr)).to_string());
                }
                libc::AF_INET6 => {
                    // SAFETY: `AF_INET6` proves the `sockaddr_in6` layout.
                    let address = unsafe { &*(interface.ifa_addr as *const libc::sockaddr_in6) };
                    addresses.insert(Ipv6Addr::from(address.sin6_addr.s6_addr).to_string());
                }
                _ => {}
            }
        }
        cursor = interface.ifa_next;
    }
    // SAFETY: `interfaces` is the pointer returned by `getifaddrs`.
    unsafe { libc::freeifaddrs(interfaces) };
    Ok(addresses)
}

/// Resolve a peer host name or literal IP to every address the resolver
/// returns.
pub fn resolve_peer_addresses(target: &str) -> Result<Vec<String>> {
    (target, 0)
        .to_socket_addrs()
        .with_context(|| format!("resolve peer addresses for {target}"))
        .map(|addresses| addresses.map(|address| address.ip().to_string()).collect())
}

/// Effective user id of the manager process.
pub fn effective_uid() -> u32 {
    // SAFETY: `geteuid` has no preconditions.
    unsafe { libc::geteuid() }
}

/// Login name of the effective user id.
pub fn current_user() -> Result<String> {
    let uid = effective_uid();
    let mut size = passwd_buffer_size();
    loop {
        let mut buffer = vec![0u8; size];
        // SAFETY: a zeroed `passwd` is a valid out-parameter for `getpwuid_r`.
        let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: `entry`, `buffer`, and `result` are valid for `getpwuid_r`.
        let code = unsafe {
            libc::getpwuid_r(
                uid,
                &mut entry,
                buffer.as_mut_ptr() as *mut libc::c_char,
                buffer.len(),
                &mut result,
            )
        };
        if code == libc::ERANGE {
            if size >= MAX_PASSWD_BUFFER {
                bail!("local passwd entry exceeds the supported buffer size");
            }
            size *= 2;
            continue;
        }
        if code != 0 {
            bail!(
                "could not determine local user identity for self-target planning: {}",
                io::Error::from_raw_os_error(code)
            );
        }
        if result.is_null() {
            bail!("could not determine local user identity for self-target planning");
        }
        // SAFETY: a non-null `result` has a valid `pw_name`.
        let name = unsafe { CStr::from_ptr(entry.pw_name) }
            .to_string_lossy()
            .trim()
            .to_owned();
        if name.is_empty() {
            bail!("could not determine local user identity for self-target planning");
        }
        return Ok(name);
    }
}

const MAX_PASSWD_BUFFER: usize = 1 << 16;

fn passwd_buffer_size() -> usize {
    // SAFETY: `sysconf` has no preconditions; an unknown name returns -1.
    let value = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    if value > 0 { value as usize } else { 1024 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_host_aliases_are_nonempty_and_short_forms_present() {
        let aliases = local_host_aliases();
        assert!(!aliases.is_empty(), "kernel node name is always available");
        for alias in &aliases {
            let short = alias.split('.').next().unwrap_or(alias);
            assert!(
                aliases.contains(short),
                "short form {short} missing for {alias}"
            );
        }
    }

    #[test]
    fn local_addresses_include_loopback() {
        let addresses = local_ip_addresses().unwrap();
        assert!(addresses.contains("127.0.0.1"), "{addresses:?}");
    }

    #[test]
    fn peer_literal_ip_resolves_to_itself() {
        assert_eq!(
            resolve_peer_addresses("127.0.0.1").unwrap(),
            vec!["127.0.0.1".to_owned()]
        );
    }

    #[test]
    fn identity_matches_libc() {
        assert_eq!(effective_uid(), unsafe { libc::geteuid() });
        assert!(!current_user().unwrap().is_empty());
    }
}
