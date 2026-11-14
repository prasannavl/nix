use super::*;
use std::os::unix::fs::symlink;
use std::time::Duration;

fn alias_profile() -> (tempfile::TempDir, SearchPath) {
    let directory = tempfile::tempdir().unwrap();
    symlink("generation-7", directory.path().join("current")).unwrap();
    symlink(
        "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-profile",
        directory.path().join("generation-7"),
    )
    .unwrap();
    let original = directory.path().join("current/bin");
    let mut links = BTreeMap::new();
    let target = resolve(
        &original,
        &mut links,
        Instant::now() + Duration::from_secs(5),
        &mut |_| Ok(()),
    )
    .unwrap();
    let profile = SearchPath {
        value: format!("{}:{}", original.display(), original.display()),
        entries: vec![
            Entry {
                original,
                store_path: target.clone(),
                resolved: target
            };
            2
        ],
        links: links.into_values().collect(),
    };
    (directory, profile)
}

#[test]
fn private_search_binding_preserves_alias_hops_duplicates_and_order() {
    let (_directory, profile) = alias_profile();
    profile.validate().unwrap();
    assert_eq!(profile.links.len(), 2);
    assert!(
        profile
            .links
            .iter()
            .any(|link| link.target == Path::new("generation-7"))
    );
    assert_eq!(profile.entries.len(), 2);
    let bytes = serde_json::to_vec(&profile).unwrap();
    let decoded: SearchPath = serde_json::from_slice(&bytes).unwrap();
    assert!(decoded == profile);
    assert!(
        profile
            .require_value("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-profile/bin")
            .is_err()
    );
    let mut wrong = profile.clone();
    wrong.entries[0].store_path = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other/bin".into();
    assert!(wrong.validate().is_err());
    let mut unused = profile.clone();
    let mut link = unused.links[0].clone();
    link.path = "/unexpected-alias".into();
    unused.links.push(link);
    unused.links.sort_by(|a, b| a.path.cmp(&b.path));
    assert!(unused.validate().is_err());
    // Synthetic store names are claims only; no capture/native execution occurred.
}

#[test]
fn changed_alias_and_cycles_never_become_replacement_bindings() {
    let (directory, profile) = alias_profile();
    let path = directory.path().join("current");
    fs::remove_file(&path).unwrap();
    symlink("different-generation", &path).unwrap();
    assert!(
        profile
            .check_live(Instant::now() + Duration::from_secs(5))
            .is_err()
    );
    symlink("b", directory.path().join("a")).unwrap();
    symlink("a", directory.path().join("b")).unwrap();
    assert!(
        resolve(
            &directory.path().join("a/bin"),
            &mut BTreeMap::new(),
            Instant::now() + Duration::from_secs(5),
            &mut |_| Ok(()),
        )
        .is_err()
    );
}

#[test]
fn immutable_hops_cannot_escape_and_reenter_or_erase_unknown_aliases() {
    let link = Path::new("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-profile/bin");
    assert!(immutable_destination(link, Path::new("/tmp/provider"), Path::new("")).is_err());
    assert!(destination(link, Path::new("unknown/../bin"), Path::new("")).is_err());
    assert!(destination(link, Path::new("/unknown/../nix/store"), Path::new("")).is_err());
    assert_eq!(
        immutable_destination(
            link,
            Path::new("../bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bin/bin"),
            Path::new("git")
        )
        .unwrap(),
        Path::new("/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bin/bin/git")
    );
}

#[test]
fn relative_empty_mutable_or_expired_search_has_no_installed_path_fallback() {
    let directory = tempfile::tempdir().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    for value in [
        "",
        ":/nix/store/example/bin",
        "bin",
        "../bin",
        directory.path().to_str().unwrap(),
    ] {
        assert!(SearchPath::capture_at(value, deadline).is_err());
    }
    assert!(SearchPath::capture_at("/nix/store/example/bin", Instant::now()).is_err());
    let (_directory, profile) = alias_profile();
    let mut unknown = serde_json::to_value(profile).unwrap();
    unknown["fallback"] = serde_json::json!("/installed/bin");
    assert!(serde_json::from_value::<SearchPath>(unknown).is_err());
}
