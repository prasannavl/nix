//! Shared legacy queries and upstream output selection. `#.` exposes outputs,
//! not the locked flake/sourceInfo. Selection is never a consumption receipt.

use anyhow::{Result, ensure};

use super::{BuildPlanAttribute, CommandSpec};
use crate::physical::nix_string;

#[derive(Clone, Copy, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum ValueMode {
    Json,
    Names,
    Raw,
}

#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct FlakeQuery {
    attribute: String,
    mode: ValueMode,
}

impl FlakeQuery {
    pub fn value(attribute: impl Into<String>) -> Self {
        Self {
            attribute: attribute.into(),
            mode: ValueMode::Json,
        }
    }

    pub fn catalog() -> Self {
        Self {
            attribute: "nixbot.plans".into(),
            mode: ValueMode::Names,
        }
    }

    pub fn derivation(attribute: BuildPlanAttribute, configuration: &str) -> Self {
        Self {
            attribute: attribute.attribute(configuration),
            mode: ValueMode::Raw,
        }
    }

    /// Legacy argv remains byte-compatible; no new planner or process path.
    pub fn command(&self, nix: &str, arguments: &[String], reference: &str) -> CommandSpec {
        let mut args = vec!["eval".into()];
        args.extend_from_slice(arguments);
        args.extend([
            if matches!(self.mode, ValueMode::Raw) {
                "--raw"
            } else {
                "--json"
            }
            .into(),
            "--no-write-lock-file".into(),
            format!("{reference}#{}", self.attribute),
        ]);
        if matches!(self.mode, ValueMode::Names) {
            args.extend(["--apply".into(), "builtins.attrNames".into()]);
        }
        CommandSpec::new(nix, args)
    }

    /// One output query; no source provenance. Fixed application only, with
    /// selector data rather than caller-supplied Nix code.
    pub fn selection_command(
        &self,
        nix: &str,
        arguments: &[String],
        reference: &str,
        system: &str,
    ) -> Result<CommandSpec> {
        ensure!(
            !reference.is_empty()
                && !reference.contains('#')
                && !reference.chars().any(char::is_control),
            "invalid native query reference"
        );
        let expression = self.application(system)?;
        let mut args = vec!["eval".into()];
        args.extend_from_slice(arguments);
        args.extend([
            "--json".into(),
            "--no-write-lock-file".into(),
            "--option".into(),
            "system".into(),
            system.into(),
            "--option".into(),
            "accept-flake-config".into(),
            "false".into(),
            "--option".into(),
            "allow-unsafe-native-code-during-evaluation".into(),
            "false".into(),
            format!("{reference}#."),
            "--apply".into(),
            expression,
        ]);
        Ok(CommandSpec::new(nix, args))
    }

    fn application(&self, system: &str) -> Result<String> {
        abird_host_agent::build_executor::preparation::worker::Input::validate_system(system)?;
        ensure!(
            !self.attribute.is_empty()
                && self.attribute.len() <= 4096
                && self
                    .attribute
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte)),
            "query requires an admitted native attribute path"
        );
        let paths = candidates(&self.attribute, system);
        let paths = paths
            .into_iter()
            .map(|path| {
                let attribute = path
                    .iter()
                    .skip_while(|part| part.is_empty())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(".");
                let path = path
                    .iter()
                    .map(|part| nix_string(part))
                    .collect::<Vec<_>>()
                    .join(" ");
                format!(
                    "{{ attribute = {}; path = [ {path} ]; }}",
                    nix_string(&attribute)
                )
            })
            .collect::<Vec<_>>()
            .join(" ");
        let mode = match self.mode {
            ValueMode::Json => "json",
            ValueMode::Names => "names",
            ValueMode::Raw => "raw",
        };
        let expression = format!(
            "({SELECT_OUTPUT}) {{ paths = [ {paths} ]; system = {}; mode = \"{mode}\"; }}",
            nix_string(system)
        );
        Ok(expression)
    }

    /// Same full root; the native adapter owns CLI-equivalent serialization.
    /// Output selection only: consumed-source evidence comes from the adapter's
    /// upstream fetcher/evaluator objects, never from an evaluated value.
    pub fn source_expression(&self, system: &str) -> Result<String> {
        let select = self.application(system)?;
        Ok(format!(
            "flake: {{ selection = ({select}) flake.outputs; }}"
        ))
    }
}

// Native getCursors traverses every candidate before choosing the first match.
// filter forces every presence test; no tryEval or error-as-absence fallback.
// Raw interpolation uses native non-coerceMore/copy-to-store coercion.
const SELECT_OUTPUT: &str = r#"
{ paths, system, mode }: root:
let
  walk = candidate:
    let
      selected = builtins.foldl' (state: name:
        if !state.present then state else
        let present = builtins.hasAttr name state.value;
        in { inherit present; value = if present then builtins.getAttr name state.value else null; }
      ) { present = true; value = root; } candidate.path;
    in selected // { attribute = candidate.attribute; };
  matches = builtins.filter (value: value.present) (map walk paths);
  present = matches != [];
  selected = if present then builtins.head matches else null;
in {
  version = 1;
  inherit system present;
  attribute = if present then selected.attribute else null;
  result = if !present then null
    else if mode == "names" then builtins.attrNames selected.value
    else if mode == "raw" then "${selected.value}"
    else selected.value;
}
"#;

/// Only selection data. Unknown fields reject, notably a caller-defined
/// `sourceInfo` promoted from the output namespace by the former envelope.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    version: u32,
    system: String,
    present: bool,
    // Required explicit nulls distinguish absence from incomplete JSON.
    attribute: serde_json::Value,
    pub result: serde_json::Value,
}

impl Selection {
    pub fn attribute(&self) -> Option<&str> {
        self.attribute.as_str()
    }

    pub fn validate(&self, catalog: bool, system: &str) -> Result<()> {
        ensure!(self.version == 1, "unsupported output-selection envelope");
        ensure!(self.system == system, "native query system differs");
        if self.present {
            ensure!(
                self.attribute
                    .as_str()
                    .is_some_and(|value| !value.is_empty()),
                "native output attribute missing"
            );
            if catalog {
                ensure!(self.result.is_array(), "invalid native plan catalog");
            }
        } else {
            ensure!(
                catalog && self.attribute.is_null() && self.result.is_null(),
                "required native attribute missing"
            );
        }
        Ok(())
    }
}

fn candidates(attribute: &str, system: &str) -> Vec<Vec<String>> {
    // Same admitted ASCII path syntax as deployDepsKey / BuildTarget.
    // No second URI/quoted-selector parser: unsupported forms reject pre-spawn.
    if let Some(exact) = attribute.strip_prefix('.') {
        return vec![parse_path(exact)];
    }
    [
        format!("packages.{system}.{attribute}"),
        format!("legacyPackages.{system}.{attribute}"),
        attribute.into(),
    ]
    .iter()
    .map(|path| parse_path(path))
    .collect()
}

fn parse_path(value: &str) -> Vec<String> {
    // Native AttrPath::parse omits the final empty component, not interior ones.
    let mut result = value.split('.').map(str::to_owned).collect::<Vec<_>>();
    if result.last().is_some_and(String::is_empty) {
        result.pop();
    }
    result
}

#[cfg(test)]
#[path = "build_query/tests.rs"]
mod tests;
