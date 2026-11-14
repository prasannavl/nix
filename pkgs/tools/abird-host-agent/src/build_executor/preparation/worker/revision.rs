use anyhow::{Result, ensure};
use serde_json::Value;

pub(super) fn validate_revision(info: &Value, expected: &str) -> Result<()> {
    ensure!(
        expected.len() == 40
            && expected
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "invalid native revision"
    );
    let revision = info.get("rev").and_then(Value::as_str);
    let dirty = info.get("dirtyRev").and_then(Value::as_str);
    ensure!(
        (revision == Some(expected) && dirty.is_none())
            || (revision.is_none() && dirty == Some(format!("{expected}-dirty").as_str())),
        "native flake revision differs from intent"
    );
    Ok(())
}
