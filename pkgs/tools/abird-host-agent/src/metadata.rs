use std::ffi::{CStr, CString, OsString};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;

use anyhow::{Context, Result, bail};

use crate::sha256::{digest_bytes, to_hex};

pub fn xattrs_digest(path: &Path) -> Result<String> {
    let attributes = read_xattrs(path)?;
    let mut canonical = Vec::new();
    for (name, value) in attributes {
        canonical.extend_from_slice(&(name.len() as u64).to_be_bytes());
        canonical.extend_from_slice(&name);
        canonical.extend_from_slice(&(value.len() as u64).to_be_bytes());
        canonical.extend_from_slice(&value);
    }
    Ok(digest_bytes(&canonical))
}

pub fn copy_xattrs(source: &Path, destination: &Path) -> Result<()> {
    let source_attributes = read_xattrs(source)?;
    let destination_attributes = read_xattrs(destination)?;
    let destination_path = c_path(destination)?;
    for (name, _) in destination_attributes {
        if source_attributes
            .iter()
            .any(|(source_name, _)| source_name == &name)
        {
            continue;
        }
        let name = CString::new(name).context("extended attribute name contains NUL")?;
        // SAFETY: destination and name are valid NUL-terminated values.
        let result = unsafe { libc::lremovexattr(destination_path.as_ptr(), name.as_ptr()) };
        if result != 0 {
            return Err(std::io::Error::last_os_error()).with_context(|| {
                format!(
                    "remove extended attribute {} from {}",
                    to_hex(name.as_bytes()),
                    destination.display()
                )
            });
        }
    }
    for (name, value) in source_attributes {
        let name = CString::new(name).context("extended attribute name contains NUL")?;
        // SAFETY: all pointers remain valid for the duration of lsetxattr and
        // the value length matches the provided byte slice.
        let result = unsafe {
            libc::lsetxattr(
                destination_path.as_ptr(),
                name.as_ptr(),
                value.as_ptr().cast(),
                value.len(),
                0,
            )
        };
        if result != 0 {
            return Err(std::io::Error::last_os_error()).with_context(|| {
                format!(
                    "copy extended attribute {} to {}",
                    to_hex(name.as_bytes()),
                    destination.display()
                )
            });
        }
    }
    Ok(())
}

fn read_xattrs(path: &Path) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
    let path_c = c_path(path)?;
    // SAFETY: path_c is a valid NUL-terminated path and a zero length query
    // does not dereference the null buffer.
    let length = unsafe { libc::llistxattr(path_c.as_ptr(), std::ptr::null_mut(), 0) };
    if length < 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("list extended attributes for {}", path.display()));
    }
    if length == 0 {
        return Ok(Vec::new());
    }
    let mut names = vec![0_u8; length as usize];
    // SAFETY: names has exactly the length reported by the prior call.
    let actual =
        unsafe { libc::llistxattr(path_c.as_ptr(), names.as_mut_ptr().cast(), names.len()) };
    if actual < 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("list extended attributes for {}", path.display()));
    }
    names.truncate(actual as usize);
    let mut attributes = Vec::new();
    for name in names
        .split(|byte| *byte == 0)
        .filter(|name| !name.is_empty())
    {
        let name_c = CString::new(name).context("extended attribute name contains NUL")?;
        // SAFETY: path and name are valid NUL-terminated strings.
        let value_length =
            unsafe { libc::lgetxattr(path_c.as_ptr(), name_c.as_ptr(), std::ptr::null_mut(), 0) };
        if value_length < 0 {
            return Err(std::io::Error::last_os_error()).with_context(|| {
                format!(
                    "read extended attribute {} on {}",
                    to_hex(name),
                    path.display()
                )
            });
        }
        let mut value = vec![0_u8; value_length as usize];
        // SAFETY: value has the length returned by lgetxattr.
        let actual = unsafe {
            libc::lgetxattr(
                path_c.as_ptr(),
                name_c.as_ptr(),
                value.as_mut_ptr().cast(),
                value.len(),
            )
        };
        if actual < 0 {
            return Err(std::io::Error::last_os_error()).with_context(|| {
                format!(
                    "read extended attribute {} on {}",
                    to_hex(name),
                    path.display()
                )
            });
        }
        value.truncate(actual as usize);
        attributes.push((name.to_vec(), value));
    }
    attributes.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(attributes)
}

fn c_path(path: &Path) -> Result<CString> {
    if path.as_os_str().as_bytes().contains(&0) {
        bail!("path contains NUL: {}", path.display());
    }
    CString::new(path.as_os_str().as_bytes())
        .with_context(|| format!("encode path {}", path.display()))
}

#[allow(dead_code)]
fn c_string_to_os_string(value: &CStr) -> OsString {
    OsString::from_vec(value.to_bytes().to_vec())
}
