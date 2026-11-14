//! Exact-NAR inventory expressions; not admission, provenance or GC authority.
//! Git-backed plan/dependency evaluation must separately preserve source metadata.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use abird_host_agent::build_executor::context::InputLocation;
use anyhow::{Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::Value;

use super::super::build::CommandSpec;
use crate::programs::nix::{inventory_application, merge_inventory_json};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NarSnapshot {
    path: String,
    nar_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotLocation {
    snapshot: NarSnapshot,
    relative: String,
}

impl NarSnapshot {
    /// Bind an expected digest, not a verified filesystem or store receipt.
    pub fn new(path: String, sha256: &str) -> Result<Self> {
        InputLocation::source("").resolve(&path, &BTreeMap::new())?;
        ensure!(
            sha256.len() == 64
                && sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "expected lowercase NAR SHA-256"
        );
        let bytes = (0..64)
            .step_by(2)
            .map(|n| u8::from_str_radix(&sha256[n..n + 2], 16))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(Self {
            path,
            nar_hash: format!("sha256-{}", STANDARD.encode(bytes)),
        })
    }

    pub fn location(&self, relative: &str) -> Result<SnapshotLocation> {
        InputLocation::source(relative).resolve(&self.path, &BTreeMap::new())?;
        Ok(SnapshotLocation {
            snapshot: self.clone(),
            relative: relative.into(),
        })
    }

    fn allowed_uri(&self) -> String {
        // Exact fetchTree URI, including its hash; a path prefix doesn't cover '?'.
        format!(
            "path:{}?narHash={}",
            uri_part(&self.path),
            uri_part(&self.nar_hash)
        )
    }
}

impl SnapshotLocation {
    fn expression(&self) -> String {
        let suffix = if self.relative.is_empty() {
            String::new()
        } else {
            format!("/{}", self.relative)
        };
        format!(
            "((builtins.fetchTree {{ type = \"path\"; path = {}; narHash = {}; }}).outPath + {})",
            literal(&self.snapshot.path),
            literal(&self.snapshot.nar_hash),
            literal(&suffix)
        )
    }
}

pub(super) fn uri_part(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

// JSON handles quotes/backslashes; Nix additionally interpolates `${...}`.
fn literal(value: &str) -> String {
    serde_json::to_string(value)
        .expect("string serialization")
        .replace("${", "\\${")
}

pub(crate) struct InventoryExpression {
    pub expression: String,
    pub allowed_uris: BTreeSet<String>,
}

pub(crate) struct InventoryExpressions {
    base: InventoryExpression,
    overlay: Option<InventoryExpression>,
}

impl InventoryExpressions {
    pub(crate) fn new(
        base: &SnapshotLocation,
        overlay: Option<&SnapshotLocation>,
        repository_config: Option<&SnapshotLocation>,
    ) -> Result<Self> {
        ensure!(
            !base.relative.is_empty() && overlay.is_none_or(|v| !v.relative.is_empty()),
            "inventory must name a file"
        );
        let make = |input: &SnapshotLocation| {
            let mut allowed_uris = BTreeSet::from([input.snapshot.allowed_uri()]);
            let config = repository_config.map(|v| {
                allowed_uris.insert(v.snapshot.allowed_uri());
                v.expression()
            });
            let apply = inventory_application(config.as_deref());
            InventoryExpression {
                expression: format!("({apply}) (import {})", input.expression()),
                allowed_uris,
            }
        };
        Ok(Self {
            base: make(base),
            overlay: overlay.map(make),
        })
    }

    pub(crate) fn evaluate(
        &self,
        execute: impl FnMut(&InventoryExpression) -> Result<Value>,
    ) -> Result<(Value, Value, Option<Value>)> {
        evaluate_layers(&self.base, self.overlay.as_ref(), execute)
    }
}

pub struct InventoryCommands {
    pub base: CommandSpec,
    pub overlay: Option<CommandSpec>,
}

impl InventoryCommands {
    /// Compatibility command adapter; agent evaluation uses the same expressions
    /// through its exec-closed native worker, not an additional Nix CLI client.
    pub fn new(
        nix: &Path,
        base: &SnapshotLocation,
        overlay: Option<&SnapshotLocation>,
        repository_config: Option<&SnapshotLocation>,
    ) -> Result<Self> {
        ensure!(
            nix.is_absolute() && nix.to_str().is_some(),
            "Nix executable must be absolute UTF-8"
        );
        let expressions = InventoryExpressions::new(base, overlay, repository_config)?;
        let make = |input: InventoryExpression| {
            CommandSpec::new(
                nix.to_str().expect("validated Nix executable"),
                [
                    "--store".into(),
                    "daemon".into(),
                    "eval".into(),
                    "--json".into(),
                    "--option".into(),
                    "pure-eval".into(),
                    "true".into(),
                    "--option".into(),
                    "restrict-eval".into(),
                    "true".into(),
                    "--option".into(),
                    "allow-import-from-derivation".into(),
                    "false".into(),
                    "--option".into(),
                    "allowed-uris".into(),
                    input.allowed_uris.into_iter().collect::<Vec<_>>().join(" "),
                    "--expr".into(),
                    input.expression,
                ],
            )
        };
        Ok(Self {
            base: make(expressions.base),
            overlay: expressions.overlay.map(make),
        })
    }

    /// Caller supplies the accounted, deadline/capture-bounded execution adapter.
    pub fn evaluate(
        &self,
        execute: impl FnMut(&CommandSpec) -> Result<Value>,
    ) -> Result<(Value, Value, Option<Value>)> {
        evaluate_layers(&self.base, self.overlay.as_ref(), execute)
    }
}

fn evaluate_layers<T>(
    base: &T,
    overlay: Option<&T>,
    mut execute: impl FnMut(&T) -> Result<Value>,
) -> Result<(Value, Value, Option<Value>)> {
    let base = execute(base)?;
    let overlay = overlay.map(&mut execute).transpose()?;
    Ok(merge_layers(base, overlay))
}

/// The one layer merge shared by live evaluation and retained restoration.
pub(crate) fn merge_layers(base: Value, overlay: Option<Value>) -> (Value, Value, Option<Value>) {
    let mut merged = base.clone();
    if let Some(value) = &overlay {
        merge_inventory_json(&mut merged, value.clone());
    }
    (merged, base, overlay)
}

#[cfg(test)]
mod tests;
