use std::path::{Path, PathBuf};

use abird_host_agent::command::CommandSpec;
use anyhow::{Context, Result, bail};
use serde_json::Value;

use super::without_git_repository_environment;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileBinaryCache {
    directory: PathBuf,
    url: String,
}

impl FileBinaryCache {
    pub fn new(directory: impl Into<PathBuf>) -> Result<Self> {
        let directory = directory.into();
        let text = directory.to_string_lossy();
        if !directory.is_absolute() || directory == Path::new("/") {
            bail!("binary cache directory must be an absolute non-root path");
        }
        if text.contains(char::is_whitespace) || text.contains(['\0', '\r', '\n', '?', '#', '%']) {
            bail!("binary cache directory contains characters unsafe in a file URL");
        }
        let url = format!("file://{text}");
        Ok(Self { directory, url })
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn url(&self) -> &str {
        &self.url
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StorePath(PathBuf);

impl StorePath {
    pub fn new(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if !path.starts_with("/nix/store") || path == Path::new("/nix/store") {
            bail!("Nix returned a path outside /nix/store: {}", path.display());
        }
        Ok(Self(path))
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

#[derive(Clone, Debug)]
pub struct Nix {
    executable: PathBuf,
}

impl Nix {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("Nix executable must be absolute");
        }
        Ok(Self { executable })
    }

    fn command(&self) -> CommandSpec {
        without_git_repository_environment(CommandSpec::new(&self.executable))
    }

    pub fn build_output(&self, repository: &Path, installable: &str) -> Result<PathBuf> {
        Ok(self.build_store_path(repository, installable, None)?.0)
    }

    pub fn build_store_path(
        &self,
        repository: &Path,
        installable: &str,
        cache: Option<&FileBinaryCache>,
    ) -> Result<StorePath> {
        let mut command = immutable_flake_arguments(
            self.command()
                .arg("build")
                .arg(installable)
                .arg("--no-link")
                .arg("--print-out-paths"),
        );
        if let Some(cache) = cache {
            command = offline_cache_arguments(command, cache);
        }
        let result = command.current_dir(repository).output()?;
        if !result.success {
            bail!("Nix build failed for {installable}: {}", result.stderr);
        }
        if result.stdout_truncated_bytes != 0 {
            bail!("Nix build output exceeded the bounded capture limit");
        }
        let output = result.stdout.trim();
        if output.is_empty() || output.lines().count() != 1 {
            bail!("Nix build returned an unexpected output path list");
        }
        StorePath::new(output)
    }

    pub fn eval_file_json(&self, file: &Path) -> Result<Value> {
        let result = self
            .command()
            .args(["eval", "--json", "--file"])
            .arg(file)
            .output()?;
        if !result.success {
            bail!("Nix file evaluation failed: {}", result.stderr);
        }
        serde_json::from_str(&result.stdout).context("parse Nix JSON evaluation")
    }

    pub fn eval_file_apply_json(&self, file: &Path, expression: &str) -> Result<Value> {
        let result = self
            .command()
            .arg("eval")
            .arg("--json")
            .arg("--file")
            .arg(file)
            .arg("--apply")
            .arg(expression)
            .output()?;
        if !result.success {
            bail!("Nix applied file evaluation failed: {}", result.stderr);
        }
        if result.stdout_truncated_bytes != 0 {
            bail!("Nix applied file evaluation exceeded the bounded capture limit");
        }
        serde_json::from_str(&result.stdout).context("parse applied Nix JSON evaluation")
    }

    pub fn eval_installable_apply_json(
        &self,
        repository: &Path,
        installable: &str,
        expression: &str,
    ) -> Result<Value> {
        let result = immutable_flake_arguments(self.command().args([
            "eval",
            "--json",
            installable,
            "--apply",
            expression,
        ]))
        .current_dir(repository)
        .output()?;
        if !result.success {
            bail!("Nix installable evaluation failed: {}", result.stderr);
        }
        if result.stdout_truncated_bytes != 0 {
            bail!("Nix installable evaluation exceeded the bounded capture limit");
        }
        serde_json::from_str(&result.stdout).context("parse applied Nix installable JSON")
    }

    pub fn eval_installable_json(&self, repository: &Path, installable: &str) -> Result<Value> {
        let result =
            immutable_flake_arguments(self.command().args(["eval", "--json", installable]))
                .current_dir(repository)
                .output()?;
        if !result.success {
            bail!("Nix installable evaluation failed: {}", result.stderr);
        }
        if result.stdout_truncated_bytes != 0 {
            bail!("Nix installable evaluation exceeded the bounded capture limit");
        }
        serde_json::from_str(&result.stdout).context("parse Nix installable JSON evaluation")
    }

    pub fn eval_file_with_overlay_json(
        &self,
        file: &Path,
        overlay: Option<&Path>,
    ) -> Result<Value> {
        let mut value = self.eval_file_json(file)?;
        if let Some(overlay) = overlay {
            merge_json(&mut value, self.eval_file_json(overlay)?);
        }
        Ok(value)
    }

    pub fn eval_inventory_file_with_overlay_json(
        &self,
        file: &Path,
        overlay: Option<&Path>,
        repository_config: Option<&Path>,
    ) -> Result<Value> {
        let apply = inventory_apply_expression(repository_config)?;
        let mut value = self.eval_file_apply_json(file, &apply)?;
        if let Some(overlay) = overlay {
            merge_json(&mut value, self.eval_file_apply_json(overlay, &apply)?);
        }
        Ok(value)
    }

    pub fn build_link(&self, repository: &Path, installable: &str, out_link: &Path) -> Result<()> {
        let link = out_link
            .to_str()
            .context("Nix output link is not valid UTF-8")?;
        immutable_flake_arguments(
            self.command()
                .args(["build", installable, "--out-link", link]),
        )
        .current_dir(repository)
        .status_inherited()
    }

    pub fn copy_to_directory(&self, store_path: &Path, destination: &Path) -> Result<()> {
        let destination = FileBinaryCache::new(destination.to_path_buf())?;
        self.copy_store_paths(&[StorePath::new(store_path.to_path_buf())?], &destination)
    }

    pub fn archive_flake(&self, repository: &Path, destination: &FileBinaryCache) -> Result<()> {
        immutable_flake_arguments(self.command().args([
            "flake",
            "archive",
            "--to",
            destination.url(),
            ".",
        ]))
        .current_dir(repository)
        .status_inherited()
    }

    pub fn copy_store_paths(
        &self,
        store_paths: &[StorePath],
        destination: &FileBinaryCache,
    ) -> Result<()> {
        if store_paths.is_empty() {
            bail!("at least one store path is required for Nix copy");
        }
        self.command()
            .arg("copy")
            .arg("--to")
            .arg(destination.url())
            .args(store_paths.iter().map(StorePath::as_path))
            .status_inherited()
    }
}

fn immutable_flake_arguments(command: CommandSpec) -> CommandSpec {
    command.args(["--no-update-lock-file", "--no-write-lock-file"])
}

fn inventory_apply_expression(repository_config: Option<&Path>) -> Result<String> {
    let arguments = match repository_config {
        Some(path) => {
            let path = path
                .to_str()
                .context("repository config path is not valid UTF-8")?;
            let literal = serde_json::to_string(path).context("encode repository config path")?;
            format!("{{ stacks = (import (builtins.toPath {literal})).stacks; }}")
        }
        None => "{}".to_owned(),
    };
    Ok(format!(
        "inventory: if builtins.isFunction inventory then inventory {arguments} else inventory"
    ))
}

fn offline_cache_arguments(command: CommandSpec, cache: &FileBinaryCache) -> CommandSpec {
    command
        .arg("--offline")
        .arg("--option")
        .arg("substituters")
        .arg(cache.url())
        .arg("--option")
        .arg("require-sigs")
        .arg("false")
        .arg("--option")
        .arg("fallback")
        .arg("false")
}

fn merge_json(base: &mut Value, overlay: Value) {
    match (base, overlay) {
        (Value::Object(base), Value::Object(overlay)) => {
            for (name, value) in overlay {
                match base.get_mut(&name) {
                    Some(base_value) => merge_json(base_value, value),
                    None => {
                        base.insert(name, value);
                    }
                }
            }
        }
        (base, overlay) => *base = overlay,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;
    use tempfile::tempdir;

    use super::*;
    use crate::test_support::write_executable;

    fn executable(path: &Path, body: String) {
        write_executable(path, body).unwrap();
    }

    #[test]
    fn overlay_recursively_merges_attrs_and_replaces_other_values() {
        let mut base = json!({
            "config": {"hostDefaults": {"user": "nixbot", "groups": ["base"]}},
            "hosts": {"parent": {"target": "public", "proxyCommand": "tunnel"}}
        });
        merge_json(
            &mut base,
            json!({
                "config": {"hostDefaults": {"operatorUser": "pvl", "groups": ["local"]}},
                "hosts": {"parent": {"target": "10.0.0.1", "proxyCommand": null}}
            }),
        );

        assert_eq!(
            base,
            json!({
                "config": {"hostDefaults": {
                    "user": "nixbot",
                    "operatorUser": "pvl",
                    "groups": ["local"]
                }},
                "hosts": {"parent": {"target": "10.0.0.1", "proxyCommand": null}}
            })
        );
    }

    #[test]
    fn every_nix_command_ignores_inherited_git_selectors() {
        let nix = Nix::new("/bin/true").unwrap();
        assert_eq!(
            nix.command().removed_environment(),
            super::super::GIT_REPOSITORY_ENVIRONMENT
        );
    }

    #[test]
    fn offline_build_uses_only_the_declared_file_cache() {
        let temporary = tempdir().unwrap();
        let log = temporary.path().join("argv");
        let program = temporary.path().join("nix");
        executable(
            &program,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}\nprintf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system\\n'\n",
                log.display()
            ),
        );
        let cache = FileBinaryCache::new("/var/cache/offline").unwrap();

        let output = Nix::new(program)
            .unwrap()
            .build_store_path(temporary.path(), ".#system", Some(&cache))
            .unwrap();

        assert_eq!(
            output.as_path(),
            Path::new("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system")
        );
        let arguments = fs::read_to_string(log).unwrap();
        assert!(arguments.contains("--offline"));
        assert!(arguments.contains("file:///var/cache/offline"));
        assert!(arguments.contains("fallback"));
        assert!(arguments.contains("false"));
    }

    #[test]
    fn every_repository_flake_command_uses_the_committed_lock() {
        let temporary = tempdir().unwrap();
        let log = temporary.path().join("argv");
        let program = temporary.path().join("nix");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        executable(
            &program,
            format!(
                "#!{shell}\nprintf '%s ' \"$@\" >> {log}\nprintf '\\n' >> {log}\ncase \"$1\" in\n  build) printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system\\n' ;;\n  eval) printf '{{\"ok\":true}}\\n' ;;\nesac\n",
                log = log.display(),
            ),
        );
        let nix = Nix::new(program).unwrap();
        nix.build_store_path(temporary.path(), ".#system", None)
            .unwrap();
        nix.eval_installable_json(temporary.path(), ".#inventory")
            .unwrap();
        nix.eval_installable_apply_json(temporary.path(), ".#inventory", "x: x")
            .unwrap();
        nix.build_link(
            temporary.path(),
            ".#system",
            &temporary.path().join("result"),
        )
        .unwrap();
        nix.archive_flake(
            temporary.path(),
            &FileBinaryCache::new(temporary.path().join("cache")).unwrap(),
        )
        .unwrap();

        let invocations = fs::read_to_string(log).unwrap();
        assert_eq!(invocations.matches("--no-update-lock-file").count(), 5);
        assert_eq!(invocations.matches("--no-write-lock-file").count(), 5);
    }

    #[test]
    fn file_cache_and_store_paths_are_confined() {
        assert!(FileBinaryCache::new("relative").is_err());
        assert!(FileBinaryCache::new("/cache with spaces").is_err());
        assert!(StorePath::new("/tmp/not-store").is_err());
        assert!(StorePath::new("/nix/store/aaaaaaaa-ok").is_ok());
    }

    #[test]
    fn applied_file_evaluation_keeps_the_expression_in_one_argv() {
        let temporary = tempdir().unwrap();
        let log = temporary.path().join("argv");
        let program = temporary.path().join("nix");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        executable(
            &program,
            format!(
                "#!{shell}\nprintf '%s\\n' \"$@\" > {}\nprintf '{{\"ok\":true}}\\n'\n",
                log.display()
            ),
        );
        let expression = "inventory: inventory // { sentinel = \"a b; $(false)\"; }";

        let value = Nix::new(program)
            .unwrap()
            .eval_file_apply_json(Path::new("/tmp/inventory.nix"), expression)
            .unwrap();

        assert_eq!(value, json!({"ok": true}));
        let arguments = fs::read_to_string(log).unwrap();
        assert!(arguments.contains("--apply\n"));
        assert!(arguments.contains(expression));
        assert_eq!(
            arguments.lines().filter(|line| *line == expression).count(),
            1
        );
    }

    #[test]
    fn inventory_file_evaluation_supplies_repository_stacks_to_functions() {
        let temporary = tempdir().unwrap();
        let log = temporary.path().join("argv");
        let program = temporary.path().join("nix");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        executable(
            &program,
            format!(
                "#!{shell}\nprintf '%s\\n' \"$@\" > {}\nprintf '{{\"ok\":true}}\\n'\n",
                log.display()
            ),
        );

        let value = Nix::new(program)
            .unwrap()
            .eval_inventory_file_with_overlay_json(
                Path::new("/tmp/inventory.nix"),
                None,
                Some(Path::new("/repo/config")),
            )
            .unwrap();

        assert_eq!(value, json!({"ok": true}));
        let arguments = fs::read_to_string(log).unwrap();
        assert!(arguments.contains("--apply\n"));
        assert!(arguments.contains("builtins.isFunction inventory"));
        assert!(arguments.contains("(import (builtins.toPath \"/repo/config\")).stacks"));
    }

    #[test]
    fn installable_evaluation_ignores_inherited_git_selectors() {
        const CHILD: &str = "ABIRD_TEST_NIX_ENVIRONMENT_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let mut child = std::process::Command::new(std::env::current_exe().unwrap());
            child.args([
                "--exact",
                "programs::nix::tests::installable_evaluation_ignores_inherited_git_selectors",
                "--nocapture",
            ]);
            child.env(CHILD, "1");
            for variable in super::super::GIT_REPOSITORY_ENVIRONMENT {
                child.env(variable, "/incorrect/checkout");
            }
            assert!(child.status().unwrap().success());
            return;
        }
        let temporary = tempdir().unwrap();
        let program = temporary.path().join("nix");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        let checks = super::super::GIT_REPOSITORY_ENVIRONMENT
            .iter()
            .map(|variable| format!("test -z \"${{{variable}+x}}\" || exit 23\n"))
            .collect::<String>();
        executable(
            &program,
            format!("#!{shell}\n{checks}printf '{{\"ok\":true}}\\n'\n"),
        );
        let nix = Nix::new(program).unwrap();
        assert_eq!(
            nix.eval_installable_json(temporary.path(), ".#inventory")
                .unwrap(),
            json!({"ok": true})
        );
        assert_eq!(
            nix.eval_installable_apply_json(temporary.path(), ".#inventory", "x: x")
                .unwrap(),
            json!({"ok": true})
        );
    }

    #[test]
    fn applied_installable_evaluation_keeps_policy_structured() {
        let temporary = tempdir().unwrap();
        let log = temporary.path().join("argv");
        let program = temporary.path().join("nix");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        executable(
            &program,
            format!(
                "#!{shell}\nprintf '%s\\n' \"$@\" > {}\nprintf '\"abird-zulip\"\\n'\n",
                log.display()
            ),
        );
        let expression = "services: builtins.head (builtins.attrNames services)";

        let value = Nix::new(program)
            .unwrap()
            .eval_installable_apply_json(temporary.path(), ".#services", expression)
            .unwrap();

        assert_eq!(value, json!("abird-zulip"));
        let arguments = fs::read_to_string(log).unwrap();
        assert!(arguments.contains(".#services\n--apply\n"));
        assert_eq!(
            arguments.lines().filter(|line| *line == expression).count(),
            1
        );
    }
}
