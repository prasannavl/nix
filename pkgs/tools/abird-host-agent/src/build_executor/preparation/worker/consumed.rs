//! Actual native preparation-query observations. The root binding is emitted
//! by the upstream adapter after checking that the accessor produced for the
//! original sealed input is the one callFlake consumed; result hashes only bind
//! returned values. Neither proves caller-profile fidelity or settlement.

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Input;
use crate::build_executor::context::{InputLocation, InputTree};
use crate::build_executor::digest;
use crate::build_executor::preparation::{Disposition, MAX_PREPARED_BYTES, PreparedInputs};
use crate::sha256::digest_bytes;

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum QueryKind {
    Dependencies,
    Catalog,
    Derivation {
        host: String,
    },
    /// `nixosConfigurations.<cfg>.config.boot.isContainer`: the one fact
    /// activation/rollback otherwise re-evaluate from the repository.
    Activation {
        host: String,
    },
}

/// Deployment retains per-target activation facts from the same evaluator.
pub fn needs_activation(request: &crate::build_executor::request::BuildRequest) -> bool {
    matches!(
        request.selection,
        crate::build_executor::request::Selection::Fleet { .. }
    ) && matches!(
        request.evaluation.action,
        crate::build_executor::context::BuildAction::Deploy
            | crate::build_executor::context::BuildAction::Run
    )
}

/// Dependencies + catalog + derivation and optional activation per target.
const MAX_QUERIES: usize = 2 + 2 * 64;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Consumed {
    pub location: InputLocation,
    pub source_info: Value,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Query {
    pub kind: QueryKind,
    pub location: InputLocation,
    /// Selected path in the actual native root; None only for proven absence.
    pub attribute: Option<String>,
    pub result_digest: String,
    /// Locked external flake inputs mounted by this evaluator so far.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub inputs: Vec<String>,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Consumption {
    pub flakes: Vec<Consumed>,
    pub queries: Vec<Query>,
}

/// Canonical Value encoding, not subprocess text or a command to replay.
pub fn value_digest(value: &Value) -> Result<String> {
    let mut bytes = b"abird-owned-evaluation-value-v1\n".to_vec();
    bytes.extend(serde_json::to_vec(value)?);
    Ok(digest_bytes(&bytes))
}

impl Consumed {
    pub fn validate(&self, input: &Input) -> Result<()> {
        ensure!(
            self.location == input.request.evaluation.build_flake
                || self.location == input.request.evaluation.dependency_flake,
            "unrequested consumed flake"
        );
        let info = &self.source_info;
        ensure!(
            info.is_object() && serde_json::to_vec(info)?.len() <= 16 * 1024,
            "consumed source metadata exceeds bound"
        );
        match &self.location.tree {
            InputTree::Source | InputTree::Git { .. } => {
                let (native_source, native_info, revision) = input.native_root(&self.location)?;
                let url = format!(
                    "file://{}",
                    native_source.to_str().context("non-UTF8 native source")?
                );
                ensure!(
                    info.get("accessor").and_then(Value::as_str) == Some("upstream-produced")
                        && info.get("type").and_then(Value::as_str) == Some("git")
                        && info.get("url").and_then(Value::as_str) == Some(url.as_str())
                        && info.get("dir").and_then(Value::as_str)
                            == Some(self.location.relative.as_str())
                        && info
                            .get("lock")
                            .and_then(Value::as_str)
                            .is_some_and(|lock| crate::build_executor::digest(lock).is_ok()),
                    "consumed root lacks upstream accessor binding"
                );
                ensure!(
                    [
                        "outPath",
                        "narHash",
                        "lastModified",
                        "rev",
                        "dirtyRev"
                    ]
                    .iter()
                    .all(|field| info.get(*field) == native_info.get(*field))
                        // Stock fetchTree may omit revCount even when the locked
                        // flake input supplies it. Absence is not a count of zero.
                        && native_info.get("revCount").is_none_or(|count| {
                            info.get("revCount") == Some(count)
                        }),
                    "consumed source differs from imported tree"
                );
                super::validate_revision(info, revision)?;
            }
            InputTree::Snapshot { .. } => {
                // External native flakes need their own Git/profile context;
                // a generic NAR/path snapshot cannot supply it.
                anyhow::bail!("external native flake lacks its own Git context");
            }
        }
        Ok(())
    }
}

impl Consumption {
    /// Called only after the actual native query returns. Failure does not
    /// append a partial receipt or authorize a replacement query.
    pub fn observe(&mut self, input: &Input, consumed: Consumed, query: Query) -> Result<()> {
        consumed.validate(input)?;
        validate_query(&query)?;
        ensure!(
            query.location == consumed.location && self.queries.len() < MAX_QUERIES,
            "consumed query location/count differs"
        );
        if let Some(previous) = self
            .queries
            .iter()
            .rev()
            .find(|item| item.location == query.location)
        {
            ensure!(
                previous
                    .inputs
                    .iter()
                    .all(|name| query.inputs.contains(name)),
                "mounted native inputs regressed"
            );
        }
        if let Some(previous) = self
            .flakes
            .iter()
            .find(|item| item.location == consumed.location)
        {
            ensure!(
                previous.source_info == consumed.source_info,
                "native context changed between actual queries"
            );
        } else {
            ensure!(self.flakes.len() < 2, "consumed flake count exceeds bound");
            self.flakes.push(consumed);
        }
        self.queries.push(query);
        Ok(())
    }

    pub fn validate(&self, input: &Input, prepared: &PreparedInputs) -> Result<()> {
        input.validate()?;
        prepared.validate(&input.request)?;
        ensure!(
            prepared.caller_repository == input.caller_repository,
            "prepared caller destination differs from captured input"
        );
        let per_target = if needs_activation(&input.request) {
            2
        } else {
            1
        };
        ensure!(
            self.flakes.len() <= 2 && self.queries.len() == prepared.targets.len() * per_target + 2,
            "actual query coverage differs"
        );
        let build = &input.request.evaluation.build_flake;
        let dependencies = &input.request.evaluation.dependency_flake;
        ensure!(
            self.flakes.len() == if build == dependencies { 1 } else { 2 },
            "consumed flake coverage differs"
        );
        for (index, flake) in self.flakes.iter().enumerate() {
            flake.validate(input)?;
            ensure!(
                !self.flakes[..index]
                    .iter()
                    .any(|previous| previous.location == flake.location),
                "duplicate consumed flake"
            );
        }
        for query in &self.queries {
            validate_query(query)?;
            ensure!(
                self.flakes
                    .iter()
                    .any(|flake| flake.location == query.location),
                "query lacks consumed root"
            );
        }
        ensure!(
            self.queries[0].kind == QueryKind::Dependencies
                && self.queries[0].location == *dependencies
                && self.queries[1].kind == QueryKind::Catalog
                && self.queries[1].location == *build,
            "native query order/context differs"
        );
        if self.queries[1].attribute.is_none() {
            ensure!(
                prepared
                    .resolved
                    .iter()
                    .all(|target| target.disposition == Disposition::Build),
                "absent native catalog cannot justify omitted targets"
            );
        }
        let (derivations, activations) = self.queries[2..].split_at(prepared.targets.len());
        for (query, target) in activations.iter().zip(&prepared.targets) {
            ensure!(
                query.kind
                    == (QueryKind::Activation {
                        host: target.target.host.clone()
                    })
                    && query.location == *build
                    && [true, false]
                        .iter()
                        .any(|fact| value_digest(&Value::Bool(*fact)).ok().as_ref()
                            == Some(&query.result_digest)),
                "actual activation query differs from prepared target"
            );
        }
        for (query, target) in derivations.iter().zip(&prepared.targets) {
            ensure!(
                query.kind
                    == (QueryKind::Derivation {
                        host: target.target.host.clone()
                    })
                    && query.location == *build
                    && query.result_digest
                        == value_digest(&Value::String(target.derivation.clone()))?,
                "actual derivation query differs from prepared target"
            );
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_PREPARED_BYTES,
            "consumption observations exceed bound"
        );
        Ok(())
    }
}

fn validate_query(query: &Query) -> Result<()> {
    digest(&query.result_digest)?;
    ensure!(
        query.inputs.len() <= 512
            && query.inputs.windows(2).all(|pair| pair[0] < pair[1])
            && query.inputs.iter().all(|name| {
                !name.is_empty()
                    && name.len() <= 128
                    && name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
            }),
        "invalid mounted native inputs"
    );
    if let QueryKind::Derivation { host } | QueryKind::Activation { host } = &query.kind {
        crate::build_executor::identifier(host)?;
    }
    if let Some(attribute) = &query.attribute {
        ensure!(
            !attribute.is_empty()
                && attribute.len() <= 4096
                && !attribute.chars().any(char::is_control),
            "invalid native cursor attribute"
        );
    } else {
        ensure!(
            query.kind == QueryKind::Catalog && query.result_digest == value_digest(&Value::Null)?,
            "missing attribute is not proven catalog absence"
        );
    }
    Ok(())
}

/// Private evaluated planning data for the original controller. Never include
/// in the public artifact projection or interpret it as deployment authority.
/// The manager owns its inventory schema; this shared carrier owns bounds.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Planning {
    pub version: u32,
    pub request: crate::build_executor::request::BuildRequest,
    pub inventory: Value,
    pub catalog: Value,
    /// Exact native selection encoding preserves its existing digest domain.
    pub selection: String,
    /// Host → `boot.isContainer`, from the actual Activation queries.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub activation: std::collections::BTreeMap<String, bool>,
    /// `{base, overlay, dependencies}`: raw inventory layers and the actual
    /// dependency result, so a caller resolves its own routes without
    /// re-evaluating source. Null only in encodings that predate it.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub layers: Value,
}

impl Planning {
    pub fn decode(bytes: &[u8], prepared: &PreparedInputs) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_PREPARED_BYTES,
            "private planning exceeds bound"
        );
        let planning: Self = serde_json::from_slice(bytes)
            .map_err(|_| anyhow::anyhow!("invalid private planning data"))?;
        ensure!(
            serde_json::to_vec(&planning)? == bytes,
            "noncanonical private planning data"
        );
        planning.validate(prepared)?;
        Ok(planning)
    }

    pub fn digest(&self) -> Result<String> {
        let bytes = serde_json::to_vec(self)?;
        ensure!(
            bytes.len() <= MAX_PREPARED_BYTES,
            "retained planning exceeds preparation bound"
        );
        let mut bound = b"abird-owned-planning-v1\n".to_vec();
        bound.extend(bytes);
        Ok(digest_bytes(&bound))
    }

    pub fn validate(&self, prepared: &PreparedInputs) -> Result<()> {
        prepared.validate(&self.request)?;
        ensure!(
            prepared.planning_digest.as_deref() == Some(self.digest()?.as_str()),
            "retained planning binding differs"
        );
        ensure!(
            self.version == 1
                && self.inventory.is_object()
                && (self.catalog.is_null()
                    || self
                        .catalog
                        .as_array()
                        .is_some_and(|items| items.iter().all(|item| item.as_str().is_some()))),
            "invalid retained planning data"
        );
        ensure!(
            self.selection.len() <= MAX_PREPARED_BYTES
                && serde_json::from_str::<Value>(&self.selection)?.is_object()
                && digest_bytes(self.selection.as_bytes()) == prepared.selection_digest,
            "retained selection differs"
        );
        ensure!(
            self.layers.is_null()
                || self.layers.as_object().is_some_and(|layers| {
                    layers.len() == 3
                        && layers.get("base").is_some_and(Value::is_object)
                        && layers
                            .get("overlay")
                            .is_some_and(|overlay| overlay.is_object() || overlay.is_null())
                        && layers.contains_key("dependencies")
                }),
            "invalid retained inventory layers"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_PREPARED_BYTES,
            "retained planning exceeds preparation bound"
        );
        Ok(())
    }

    pub fn validate_consumption(
        &self,
        prepared: &PreparedInputs,
        consumed: &Consumption,
    ) -> Result<()> {
        self.validate(prepared)?;
        let query = consumed
            .queries
            .get(1)
            .context("actual catalog query missing")?;
        ensure!(
            query.kind == QueryKind::Catalog && query.result_digest == value_digest(&self.catalog)?,
            "retained catalog differs from actual query"
        );
        ensure!(
            self.layers.is_null()
                || consumed.queries.first().is_some_and(|query| {
                    query.kind == QueryKind::Dependencies
                        && value_digest(&self.layers["dependencies"]).ok().as_ref()
                            == Some(&query.result_digest)
                }),
            "retained dependencies differ from actual query"
        );
        // Facts come only from the actual Activation queries, complete or none.
        let observed = consumed
            .queries
            .iter()
            .filter_map(|query| match &query.kind {
                QueryKind::Activation { host } => Some((host, &query.result_digest)),
                _ => None,
            })
            .collect::<Vec<_>>();
        ensure!(
            observed.len() == self.activation.len()
                && observed.iter().all(|(host, digest)| {
                    self.activation.get(*host).is_some_and(|fact| {
                        value_digest(&Value::Bool(*fact)).ok().as_ref() == Some(*digest)
                    })
                }),
            "retained activation facts differ from actual queries"
        );
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Output {
    pub version: u32,
    pub prepared: PreparedInputs,
    pub consumed: Consumption,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<Planning>,
}

impl Output {
    pub fn validate(&self, input: &Input) -> Result<()> {
        ensure!(self.version == 3, "unsupported preparation result protocol");
        ensure!(
            !matches!(
                input.request.selection,
                crate::build_executor::request::Selection::Fleet { .. }
            ) || self.planning.is_some(),
            "fleet preparation lacks retained planning"
        );
        self.consumed.validate(input, &self.prepared)?;
        ensure!(
            self.planning.is_some() == self.prepared.planning_digest.is_some(),
            "retained planning presence differs"
        );
        if let Some(planning) = &self.planning {
            ensure!(
                planning.request == input.request && !planning.layers.is_null(),
                "retained resolved request/layers differ"
            );
            planning.validate_consumption(&self.prepared, &self.consumed)?;
        }
        ensure!(
            self.prepared.source_path == input.source.path
                && self.prepared.tree_digest == input.source.nar_digest
                && self.prepared.context_sources == input.context_sources()
                && self.prepared.protection_digest == input.protection_digest,
            "preparation result witnesses differ"
        );
        // Share the existing complete-result allowance, not another reservation.
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_PREPARED_BYTES,
            "preparation result exceeds bound"
        );
        Ok(())
    }

    pub fn decode(bytes: &[u8], input: &Input) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_PREPARED_BYTES,
            "preparation result exceeds bound"
        );
        let result: Self = serde_json::from_slice(bytes).context("invalid preparation result")?;
        result.validate(input)?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests;
