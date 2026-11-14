//! Persistent allowlisted diagnostics, never subprocess output or error strings.
//! Reuse the journal's bounded history; no second file store or resource budget.

use anyhow::Result;
use serde::{Deserialize, Serialize};

use super::{ExecutionHandle, daemon, journal::Journal};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Activity {
    Worker,
    Receive,
    Capture,
    Resolve,
    Source,
    SourceCheck,
    SourceCheckout,
    SourceImport,
    SourceRestore,
    SourceAnchor,
    SourceHash,
    SourceSeal,
    InputVerify,
    Prepare,
    Realize,
    NativeSeal,
    Verify,
    Publish,
    Collect,
    Retire,
    RetireController,
    RetireRoots,
    RetireArtifacts,
    RetireNative,
    RetireSource,
    Cleanup,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Observation {
    Entered,
    Returned,
    Error,
}

/// Neither an activity return nor the end of diagnostics is job settlement.
/// Intentionally no message/path/argv/env/output field: redaction by construction.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostic {
    pub activity: Activity,
    pub observation: Observation,
}

impl Journal {
    pub(in crate::build_executor) fn diagnose<T>(
        &self,
        handle: &ExecutionHandle,
        activity: Activity,
        operation: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        self.record_diagnostic(
            handle,
            Diagnostic {
                activity,
                observation: Observation::Entered,
            },
            daemon::now()?,
        )?;
        let result = operation();
        let observation = if result.is_ok() {
            Observation::Returned
        } else {
            Observation::Error
        };
        // An uncertain log write cannot cause this operation to run again.
        self.record_diagnostic(
            handle,
            Diagnostic {
                activity,
                observation,
            },
            daemon::now()?,
        )?;
        result
    }
}
