//! Synthetic CLI/output-selection parity and the #. sourceInfo counterexample.
//! Not provenance, caller-profile coherence, or production-query replay authority.

use std::fs;
use std::path::Path;
use std::process::Command;

use abird_host_manager::fleet::preparation::native_api;

use abird_host_agent::build_executor::process::Runner;
use abird_host_manager::fleet::build::{BuildPlanAttribute, query::FlakeQuery};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

use super::{output, successful};

pub(super) fn run(
    runner: &mut Runner,
    git: &Path,
    nix: &Path,
    home: &Path,
    manager: &Path,
    library: &Path,
) -> Result<()> {
    let root = home.join("upstream-query");
    fs::create_dir(&root)?;
    successful(
        runner,
        git,
        &["init", "--template=", "--initial-branch=fixture"],
        &root,
        home,
    )?;
    write(&root, "value = null;")?;
    successful(runner, git, &["add", "--", "flake.nix"], &root, home)?;
    successful(
        runner,
        git,
        &[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-m",
            "synthetic native query baseline",
        ],
        &root,
        home,
    )?;

    write(
        &root,
        r#"
      __functor = self: throw "must not auto-call root";
      packages.x86_64-linux.value = "package";
      packages.aarch64-linux.value = "arm";
      legacyPackages.x86_64-linux.value = "legacy";
      value = "root";
      metadata = { out = self.outPath; revision = self.rev or self.dirtyRev; };
    "#,
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value("value"),
        "x86_64-linux",
        Expected::Value(json!("package"), "packages.x86_64-linux.value", false),
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value(".value"),
        "x86_64-linux",
        Expected::Value(json!("root"), "value", false),
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value("value"),
        "aarch64-linux",
        Expected::Value(json!("arm"), "packages.aarch64-linux.value", false),
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value("metadata"),
        "x86_64-linux",
        Expected::Root,
    )?;

    // openEvalCache returns flake.outputs. Unlike the internal flake result,
    // that namespace neither supplies nor protects a sourceInfo attribute.
    // Native JSON coerces an attrset with outPath to that value.
    let forged = json!("/nix/store/00000000000000000000000000000000-forged");
    write(
        &root,
        r#"
      sourceInfo = {
        outPath = "/nix/store/00000000000000000000000000000000-forged";
        narHash = "caller-controlled";
      };
      metadata = builtins.removeAttrs self.sourceInfo [ "outPath" ];
    "#,
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value(".sourceInfo"),
        "x86_64-linux",
        Expected::Value(forged.clone(), "sourceInfo", false),
    )?;
    let actual = compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value(".metadata"),
        "x86_64-linux",
        Expected::Root,
    )?;
    ensure!(
        actual["result"]
            .as_object()
            .is_some_and(|info| !info.is_empty())
            && actual["result"] != forged,
        "synthetic output spoof did not differ from self metadata"
    );
    println!("UPSTREAM_DOT_ROOT_SOURCE_INFO_IS_CALLER_OUTPUT_NOT_PROVENANCE");
    println!("UPSTREAM_JSON_OUTPATH_ATTRSET_COERCION");
    let candidate = api(
        runner,
        manager,
        library,
        &root,
        home,
        FlakeQuery::value(".sourceInfo"),
    )?;
    // ABI3: the binding comes from the fetcher-produced accessor mounted for
    // callFlake, never from an evaluated value; a forged output cannot reach it.
    let info = candidate["source_info"]
        .as_object()
        .context("native source metadata was coerced")?;
    let protected = &actual["result"];
    ensure!(
        candidate["selection"]["result"] == forged
            && info
                .get("outPath")
                .is_some_and(|path| path.is_string() && *path != forged)
            && info.get("accessor") == Some(&json!("upstream-produced"))
            && info.get("type") == Some(&json!("git"))
            && info.get("url") == Some(&json!(format!("file://{}", root.display())))
            && ["narHash", "lastModified", "rev", "dirtyRev"]
                .iter()
                .all(|key| info.get(*key) == protected.get(*key)),
        "native accessor binding confused output metadata with consumed source"
    );
    println!("UPSTREAM_NATIVE_ADAPTER_ACCESSOR_BINDING_IGNORES_OUTPUT_SOURCE_INFO");

    // The same-value adapter must not copy paths merely to serialize JSON.
    write(
        &root,
        r#"value = {
          direct = ./flake.nix;
          nested = [ ./flake.nix null true 7 ];
          string = { __toString = _: ./flake.nix; outPath = "not-selected"; };
          recursive = { __toString = _: { outPath = ./flake.nix; }; };
          ordinary = { outPath = [ ./flake.nix 7 ]; };
        };"#,
    )?;
    let direct = FlakeQuery::value(".value").command(
        nix.to_str().context("fixture Nix path")?,
        &["--store".into(), "daemon".into()],
        &format!("git+file://{}", root.display()),
    );
    let direct = successful(
        runner,
        nix,
        &direct.args.iter().map(String::as_str).collect::<Vec<_>>(),
        &root,
        home,
    )?;
    let direct: Value = serde_json::from_slice(&direct)?;
    let candidate = api(
        runner,
        manager,
        library,
        &root,
        home,
        FlakeQuery::value(".value"),
    )?;
    ensure!(
        candidate["selection"]["result"] == direct,
        "native JSON path serialization differs from CLI"
    );
    println!("UPSTREAM_NATIVE_ADAPTER_JSON_PATH_PARITY");

    write(
        &root,
        r#"
      packages.x86_64-linux.value = "selected";
      legacyPackages.x86_64-linux.value = throw "unselected leaf";
      value = throw "unselected root leaf";
    "#,
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::value("value"),
        "x86_64-linux",
        Expected::Value(json!("selected"), "packages.x86_64-linux.value", false),
    )?;

    for later in ["throw \"later candidate failure\"", "17"] {
        write(
            &root,
            &format!(
                "packages.x86_64-linux.value = \"selected\"; legacyPackages = {later}; value = \"root\";"
            ),
        )?;
        compare(
            runner,
            nix,
            &root,
            home,
            FlakeQuery::value("value"),
            "x86_64-linux",
            Expected::Failure,
        )?;
    }

    write(&root, "value = true;")?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::catalog(),
        "x86_64-linux",
        Expected::Absent,
    )?;
    write(&root, "nixbot.plans = 17;")?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::catalog(),
        "x86_64-linux",
        Expected::Failure,
    )?;

    let derivation = "/nix/store/00000000000000000000000000000000-fixture.drv";
    write(
        &root,
        &format!("nixbot.plans.fixture.drvPath = {{ outPath = \"{derivation}\"; }};"),
    )?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::derivation(BuildPlanAttribute::Native, "fixture"),
        "x86_64-linux",
        Expected::Value(json!(derivation), "nixbot.plans.fixture.drvPath", true),
    )?;
    write(&root, "nixbot.plans.fixture.drvPath = 17;")?;
    compare(
        runner,
        nix,
        &root,
        home,
        FlakeQuery::derivation(BuildPlanAttribute::Native, "fixture"),
        "x86_64-linux",
        Expected::Failure,
    )?;
    println!("UPSTREAM_OUTPUT_QUERY_NATIVE_PREFIX_ERROR_AND_RAW_PARITY");
    Ok(())
}

fn write(root: &Path, body: &str) -> Result<()> {
    fs::write(
        root.join("flake.nix"),
        format!("{{ outputs = {{ self }}: {{ {body} }}; }}"),
    )?;
    Ok(())
}

enum Expected<'a> {
    Value(Value, &'a str, bool),
    Root,
    Absent,
    Failure,
}

fn compare(
    runner: &mut Runner,
    nix: &Path,
    root: &Path,
    home: &Path,
    query: FlakeQuery,
    system: &str,
    expected: Expected<'_>,
) -> Result<Value> {
    let reference = format!("git+file://{}", root.display());
    let program = nix.to_str().context("fixture Nix encoding")?;
    let arguments = [
        "--store",
        "daemon",
        "--no-update-lock-file",
        "--option",
        "system",
        system,
        "--option",
        "eval-cache",
        "false",
        "--option",
        "allow-import-from-derivation",
        "false",
        "--option",
        "accept-flake-config",
        "false",
        "--option",
        "allow-unsafe-native-code-during-evaluation",
        "false",
    ]
    .map(str::to_owned);
    let direct = query.command(program, &arguments, &reference);
    let direct = output(
        runner,
        nix,
        &direct.args.iter().map(String::as_str).collect::<Vec<_>>(),
        root,
        home,
    )?;
    let observed = query.selection_command(program, &arguments, &reference, system)?;
    let observed = output(
        runner,
        nix,
        &observed.args.iter().map(String::as_str).collect::<Vec<_>>(),
        root,
        home,
    )?;
    if matches!(expected, Expected::Failure) {
        ensure!(
            !direct.status.success() && !observed.status.success() && observed.stdout.is_empty(),
            "native failure became an envelope or successful fallback"
        );
        return Ok(Value::Null);
    }
    ensure!(observed.status.success(), "upstream output query failed");
    let envelope: Value = serde_json::from_slice(&observed.stdout)?;
    ensure!(
        envelope["version"] == 1
            && envelope["system"] == system
            && envelope.as_object().is_some_and(|object| object.len() == 5)
            && envelope.get("sourceInfo").is_none(),
        "output selection claimed provenance"
    );
    if matches!(expected, Expected::Absent) {
        ensure!(
            !direct.status.success()
                && envelope["present"] == false
                && envelope["attribute"].is_null()
                && envelope["result"].is_null(),
            "native catalog absence differs"
        );
    } else {
        ensure!(
            direct.status.success() && envelope["present"] == true,
            "native success differs"
        );
        let raw = matches!(&expected, Expected::Value(_, _, true));
        let value: Value = if raw {
            Value::String(String::from_utf8(direct.stdout)?)
        } else {
            serde_json::from_slice(&direct.stdout)?
        };
        ensure!(
            envelope["result"] == value,
            "native result differs from actual-root envelope"
        );
        if let Expected::Value(expected, attribute, _) = expected {
            ensure!(
                value == expected && envelope["attribute"] == attribute,
                "native prefix/coercion selection differs"
            );
        }
    }
    Ok(envelope)
}

fn api(
    runner: &mut Runner,
    manager: &Path,
    library: &Path,
    root: &Path,
    home: &Path,
    query: FlakeQuery,
) -> Result<Value> {
    let policy = abird_host_agent::build_executor::daemon::Policy::load(Path::new(
        "/etc/abird-owned-build/daemon.json",
    ))?;
    let request = native_api::Request {
        version: 2,
        program: policy.program.with_file_name("nix"),
        reference: format!("git+file://{}", root.display()),
        system: "x86_64-linux".into(),
        query,
    };
    let mut command = Command::new(manager);
    command
        .arg("_owned-query")
        .arg(library)
        .current_dir(root)
        .env_clear()
        .env("HOME", home)
        .env("LC_ALL", "C")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("NIX_CONFIG", native_api::configuration(&request.system)?);
    let result = runner.run(&mut command, &serde_json::to_vec(&request)?)?;
    ensure!(result.status.success(), "synthetic native API query failed");
    let observed: native_api::Observation = serde_json::from_slice(&result.stdout)?;
    ensure!(
        observed.version == 2,
        "native API observation version differs"
    );
    observed.selection.validate(false, &request.system)?;
    Ok(serde_json::from_slice(&result.stdout)?)
}
