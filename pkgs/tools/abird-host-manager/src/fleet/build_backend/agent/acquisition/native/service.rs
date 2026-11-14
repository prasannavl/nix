//! Fixed shared-store worker. Only the worker enters the work budget; the CLI
//! keeps control outside it. SCM_RIGHTS retains the original run exclusion.

use super::*;
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;

use abird_host_agent::build_executor::{
    consumer_role::{self, FailureStage},
    process,
};

const MAX_HEADER: usize = 16 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u32,
    library: PathBuf,
    home: Option<String>,
    config_home: Option<String>,
    bytes: usize,
    cutoff_ns: u64,
}

fn environment(name: &str) -> Result<Option<String>> {
    std::env::var_os(name)
        .map(|value| value.into_string())
        .transpose()
        .map_err(|_| anyhow::anyhow!("non-UTF8 public trust context"))
}

fn monotonic_ns() -> Result<u64> {
    let mut time: libc::timespec = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } == 0,
        "consumer monotonic clock unavailable"
    );
    u64::try_from(time.tv_sec)?
        .checked_mul(1_000_000_000)
        .and_then(|value| value.checked_add(u64::try_from(time.tv_nsec).ok()?))
        .context("consumer clock overflow")
}

fn peer(stream: &UnixStream) -> Result<u32> {
    let mut value: libc::ucred = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of_val(&value) as libc::socklen_t;
    ensure!(
        unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                std::ptr::from_mut(&mut value).cast(),
                &mut size,
            )
        } == 0
            && size as usize == std::mem::size_of_val(&value),
        "consumer peer unavailable"
    );
    Ok(value.uid)
}

pub(super) fn run(
    input: &[u8],
    lock: &File,
    cutoff: Instant,
    mut active: impl FnMut() -> Result<()>,
) -> Result<Vec<u8>> {
    active()?;
    let endpoint = Path::new(consumer_role::ENDPOINT);
    for parent in endpoint.ancestors().skip(1) {
        let metadata = std::fs::symlink_metadata(parent)?;
        ensure!(
            metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
            "consumer endpoint parent is not root-controlled"
        );
    }
    let metadata = std::fs::symlink_metadata(endpoint)?;
    ensure!(
        metadata.file_type().is_socket() && metadata.uid() == 0,
        "installed shared consumer endpoint unavailable"
    );
    let mut stream = connect(endpoint)?;
    ensure!(peer(&stream)? == 0, "consumer endpoint is not root-owned");
    stream.set_nonblocking(true)?;
    // Sample the kernel clock before Instant so rounding never extends cutoff.
    let now = monotonic_ns()?;
    let remaining = cutoff
        .checked_duration_since(Instant::now())
        .context("consumer deadline expired")?;
    let header = Header {
        version: 1,
        library: library()?,
        home: environment("HOME")?,
        config_home: environment("XDG_CONFIG_HOME")?.filter(|value| !value.is_empty()),
        bytes: input.len(),
        cutoff_ns: now
            .checked_add(u64::try_from(remaining.as_nanos())?)
            .context("consumer cutoff overflow")?,
    };
    let header = serde_json::to_vec(&header)?;
    ensure!(
        header.len() <= MAX_HEADER && input.len() <= MAX_REQUEST,
        "consumer frame exceeds bound"
    );
    let check = |active: &mut dyn FnMut() -> Result<()>| -> Result<()> {
        ensure!(Instant::now() < cutoff, "consumer deadline expired");
        active()
    };
    loop {
        check(&mut active)?;
        match send_lock(&stream, lock) {
            Ok(()) => break,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::park_timeout(Duration::from_millis(5))
            }
            Err(error) => return Err(error.into()),
        }
    }
    for bytes in [&(header.len() as u32).to_be_bytes()[..], &header, input] {
        let mut position = 0;
        while position < bytes.len() {
            check(&mut active)?;
            match stream.write(&bytes[position..(position + 8192).min(bytes.len())]) {
                Ok(0) => anyhow::bail!("consumer request closed"),
                Ok(count) => position += count,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::park_timeout(Duration::from_millis(5))
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error.into()),
            }
        }
    }
    let mut output = Vec::new();
    loop {
        check(&mut active)?;
        let mut bytes = [0u8; 1024];
        match stream.read(&mut bytes) {
            Ok(0) => return Ok(output),
            Ok(count) => {
                ensure!(
                    output.len() + count <= MAX_REPLY,
                    "consumer reply exceeds bound"
                );
                output.extend_from_slice(&bytes[..count]);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::park_timeout(Duration::from_millis(5))
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
}

fn connect(path: &Path) -> Result<UnixStream> {
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    let bytes = path.as_os_str().as_bytes();
    ensure!(
        bytes.len() < address.sun_path.len(),
        "consumer socket path exceeds bound"
    );
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (target, source) in address.sun_path.iter_mut().zip(bytes) {
        *target = *source as libc::c_char;
    }
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    ensure!(fd >= 0, "consumer socket unavailable");
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    let size = std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1;
    ensure!(
        unsafe {
            libc::connect(
                fd,
                std::ptr::from_ref(&address).cast(),
                size as libc::socklen_t,
            )
        } == 0,
        "consumer socket busy or unavailable"
    );
    Ok(stream)
}

fn send_lock(stream: &UnixStream, lock: &File) -> std::io::Result<()> {
    let mut byte = 1u8;
    let mut vector = libc::iovec {
        iov_base: std::ptr::from_mut(&mut byte).cast(),
        iov_len: 1,
    };
    let mut control = [0usize; 4];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen =
        unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let count = unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as usize;
        std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<RawFd>(), lock.as_raw_fd());
        libc::sendmsg(stream.as_raw_fd(), &message, libc::MSG_NOSIGNAL)
    };
    if count == 1 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn receive_lock(stream: &UnixStream) -> Result<File> {
    let mut byte = 0u8;
    let mut vector = libc::iovec {
        iov_base: std::ptr::from_mut(&mut byte).cast(),
        iov_len: 1,
    };
    let mut control = [0usize; 4];
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = std::mem::size_of_val(&control);
    let count = unsafe { libc::recvmsg(stream.as_raw_fd(), &mut message, libc::MSG_CMSG_CLOEXEC) };
    ensure!(count >= 0, "consumer exclusion transfer unavailable");
    let mut files = Vec::new();
    let mut valid = true;
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let bytes = (*header)
                    .cmsg_len
                    .saturating_sub(libc::CMSG_LEN(0) as usize);
                valid &= bytes.is_multiple_of(std::mem::size_of::<RawFd>());
                for index in 0..bytes / std::mem::size_of::<RawFd>() {
                    let fd = std::ptr::read_unaligned(
                        libc::CMSG_DATA(header).cast::<RawFd>().add(index),
                    );
                    files.push(File::from_raw_fd(fd));
                }
            } else {
                valid = false;
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
    }
    ensure!(
        valid
            && count == 1
            && byte == 1
            && message.msg_flags & libc::MSG_CTRUNC == 0
            && files.len() == 1,
        "invalid consumer exclusion transfer"
    );
    Ok(files.pop().unwrap())
}

fn gc_descriptor() -> Result<File> {
    for path in ["/nix", "/nix/var", "/nix/var/nix"] {
        let metadata = std::fs::symlink_metadata(path)?;
        ensure!(
            metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
            "GC lock parent differs"
        );
    }
    // Own open description; neither PID1 nor the caller keeps this GC authority.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/nix/var/nix/gc.lock")?;
    let before = file.metadata()?;
    let after = std::fs::symlink_metadata("/nix/var/nix/gc.lock")?;
    ensure!(
        before.is_file()
            && before.uid() == 0
            && before.nlink() == 1
            && before.mode() & 0o022 == 0
            && after.is_file()
            && (before.dev(), before.ino()) == (after.dev(), after.ino()),
        "GC lock identity differs"
    );
    Ok(file)
}

pub fn worker() -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "shared consumer entry requires root"
    );
    process::protect_worker_memory()?;
    let mut stream = unsafe { UnixStream::from_raw_fd(0) };
    let uid = peer(&stream).context(FailureStage::Peer)?;
    let gc = gc_descriptor().context(FailureStage::GcLock)?;
    consumer_role::enter(uid)?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    let lock = receive_lock(&stream).context(FailureStage::Exclusion)?;
    let mut length = [0u8; 4];
    stream
        .read_exact(&mut length)
        .context(FailureStage::Request)?;
    let length = u32::from_be_bytes(length) as usize;
    ensure!(
        length > 0 && length <= MAX_HEADER,
        "consumer header exceeds bound"
    );
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes)?;
    let header: Header = serde_json::from_slice(&bytes).context(FailureStage::Request)?;
    let left = header
        .cutoff_ns
        .checked_sub(monotonic_ns()?)
        .context("consumer cutoff expired")?;
    ensure!(
        header.version == 1
            && header.library == library()?
            && header.bytes <= MAX_REQUEST
            && left > 0
            && left <= 7 * 86400 * 1_000_000_000,
        "invalid fixed consumer request"
    );
    for (name, value) in [
        ("HOME", header.home),
        ("XDG_CONFIG_HOME", header.config_home),
    ] {
        if let Some(path) = &value {
            ensure!(
                Path::new(path).is_absolute() && path.len() <= 4096 && !path.contains('\0'),
                "invalid public trust context"
            );
        }
        // Fixed single-threaded entry; do this after dropping root, before watchers.
        unsafe {
            if let Some(value) = value {
                std::env::set_var(name, value);
            } else {
                std::env::remove_var(name);
            }
        }
    }
    let mut bytes = vec![0; header.bytes];
    stream.read_exact(&mut bytes)?;
    let watch = stream.try_clone()?;
    std::thread::spawn(move || {
        loop {
            if !monotonic_ns().is_ok_and(|now| now < header.cutoff_ns) {
                unsafe { libc::_exit(124) };
            }
            let mut event = libc::pollfd {
                fd: watch.as_raw_fd(),
                events: libc::POLLRDHUP | libc::POLLIN,
                revents: 0,
            };
            let result = unsafe { libc::poll(&mut event, 1, 10) };
            if result > 0
                || (result < 0
                    && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted)
            {
                unsafe { libc::_exit(125) };
            }
        }
    });
    let output = execute(
        &header.library,
        bytes,
        Some(lock.as_raw_fd()),
        gc.as_raw_fd(),
    )
    .context(FailureStage::Operation)?;
    stream.write_all(&output).context(FailureStage::Reply)?;
    // The watcher retains the socket until process exit, so EOF cannot certify
    // success while this fixed worker could still mutate consumer state.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_transfer_preserves_original_exclusion() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let original = file.reopen().unwrap();
        assert_eq!(
            unsafe { libc::flock(original.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let (left, right) = UnixStream::pair().unwrap();
        send_lock(&left, &original).unwrap();
        drop(original);
        let contender = file.reopen().unwrap();
        assert_ne!(
            unsafe { libc::flock(contender.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let received = receive_lock(&right).unwrap();
        assert_ne!(
            unsafe { libc::flock(contender.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        drop(received);
        assert_eq!(
            unsafe { libc::flock(contender.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
    }
}
