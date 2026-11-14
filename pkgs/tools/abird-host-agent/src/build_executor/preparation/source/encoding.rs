//! Bounded streaming metadata validation: large private NAR strings are never
//! cloned merely to count or hash their enclosing JSON.
use crate::sha256::{Sha256, to_hex};
use anyhow::{Result, ensure};
use serde::Serialize;
use std::io::{self, Write};

struct Sink {
    hash: Sha256,
    bytes: usize,
    limit: usize,
}
impl Write for Sink {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.bytes = self
            .bytes
            .checked_add(bytes.len())
            .filter(|count| *count <= self.limit)
            .ok_or_else(|| io::Error::other("private encoding exceeds bound"))?;
        self.hash.update(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub fn json_digest(domain: &[u8], value: &impl Serialize, limit: usize) -> Result<String> {
    let mut sink = Sink {
        hash: Sha256::new(),
        bytes: 0,
        limit,
    };
    sink.write_all(domain)?;
    serde_json::to_writer(&mut sink, value)?;
    Ok(to_hex(&sink.hash.finish()))
}

pub fn require_size(value: &impl Serialize, limit: usize) -> Result<()> {
    struct Count {
        bytes: usize,
        limit: usize,
    }
    impl Write for Count {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.bytes = self
                .bytes
                .checked_add(bytes.len())
                .filter(|n| *n <= self.limit)
                .ok_or_else(|| io::Error::other("private encoding exceeds bound"))?;
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    serde_json::to_writer(Count { bytes: 0, limit }, value)?;
    Ok(())
}

pub fn hex_digest(value: &str, limit: usize) -> Result<String> {
    ensure!(
        value.len().is_multiple_of(2) && value.len() / 2 <= limit,
        "private hex encoding exceeds bound"
    );
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 8192];
    for chunk in value.as_bytes().chunks(buffer.len() * 2) {
        for (out, pair) in buffer.iter_mut().zip(chunk.chunks_exact(2)) {
            let nibble = |b| match b {
                b'0'..=b'9' => Ok(b - b'0'),
                b'a'..=b'f' => Ok(b - b'a' + 10),
                _ => Err(anyhow::anyhow!("invalid private hex encoding")),
            };
            *out = nibble(pair[0])? * 16 + nibble(pair[1])?;
        }
        hash.update(&buffer[..chunk.len() / 2]);
    }
    Ok(to_hex(&hash.finish()))
}
