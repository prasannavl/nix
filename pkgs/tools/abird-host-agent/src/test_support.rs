use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, Stdio};

/// Publish an executable fixture without opening its inode for writing in the
/// parallel Rust test process.
///
/// A concurrently forked test child can inherit any write-open descriptor until
/// it completes `exec`. Executing that inode in another test then fails with
/// `ETXTBSY`, even when the creating thread closed and atomically renamed it.
/// Letting a dedicated child own the write descriptor prevents sibling test
/// children from inheriting it.
pub(crate) fn write_executable(path: &Path, contents: impl AsRef<[u8]>) -> io::Result<()> {
    let mut child = Command::new("/bin/sh")
        .args([
            "-eu",
            "-c",
            r#"
destination=$1
staging="${destination}.tmp.$$"
trap 'rm -f -- "$staging"' EXIT HUP INT TERM
umask 077
cat > "$staging"
chmod 700 -- "$staging"
mv -f -- "$staging" "$destination"
trap - EXIT
"#,
            "abird-test-executable-writer",
        ])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("fixture writer has no stdin"))?;
    let write_result = stdin.write_all(contents.as_ref());
    drop(stdin);

    let status = child.wait()?;
    write_result?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "fixture writer exited with {status} for {}",
            path.display()
        )))
    }
}
