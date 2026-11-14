use super::*;

fn client() -> Client {
    Client {
        uid: 1000,
        user: "builder".into(),
    }
}

#[test]
fn native_clients_are_bounded_unique_nonroot_literal_accounts() {
    validate(&[client()]).unwrap();
    assert!(validate(&[]).is_err());
    assert!(validate(&vec![client(); MAX_CLIENTS + 1]).is_err());
    for name in [
        "",
        "root",
        "*",
        "@wheel",
        "1000",
        "-user",
        "builder root",
        "user\nroot",
        "user\0",
        "ユーザー",
    ] {
        let mut c = client();
        c.user = name.into();
        let error = validate(&[c]).unwrap_err().to_string();
        assert_eq!(error, "invalid native client identity");
    }
    for uid in [0, u32::MAX] {
        let mut c = client();
        c.uid = uid;
        assert!(validate(&[c]).is_err());
    }
    let mut other = client();
    other.uid += 1;
    assert!(validate(&[client(), other.clone()]).is_err());
    other.user = "secondary".into();
    validate(&[client(), other.clone()]).unwrap();
    assert_eq!(allowed(&[client(), other.clone()]), "builder secondary");
    other.uid = client().uid;
    assert!(validate(&[client(), other]).is_err());
    let mut c = client();
    c.user = "a".repeat(MAX_NAME + 1);
    assert!(validate(&[c]).is_err());
    assert!(
        serde_json::from_str::<Client>(r#"{"uid":1000,"user":"builder","trusted":true}"#).is_err()
    );
}

#[test]
fn native_clients_must_belong_to_the_declared_workload_not_control_principals() {
    validate_workload(&[client()], &[1000, 30001, 30002]).unwrap();
    for workers in [vec![], vec![1100], vec![30001, 30002]] {
        assert_eq!(
            validate_workload(&[client()], &workers)
                .unwrap_err()
                .to_string(),
            "native client outside workload identities"
        );
    }
}

fn by_uid(uid: u32) -> Result<(u32, String)> {
    Ok((uid, if uid == 0 { "root" } else { "builder" }.into()))
}
fn by_name(name: &str) -> Result<(u32, String)> {
    Ok((if name == "root" { 0 } else { 1000 }, name.into()))
}

#[test]
fn both_root_and_client_account_mappings_must_agree_without_cached_authority() {
    let mut seen_uids = Vec::new();
    let mut seen_names = Vec::new();
    verify_with(
        &[client()],
        |uid| {
            seen_uids.push(uid);
            by_uid(uid)
        },
        |name| {
            seen_names.push(name.to_owned());
            by_name(name)
        },
    )
    .unwrap();
    assert_eq!(seen_uids, [0, 1000]);
    assert_eq!(seen_names, ["root", "builder"]);
    for uid in [0, 1000] {
        assert!(
            verify_with(
                &[client()],
                |value| {
                    let mut result = by_uid(value)?;
                    if value == uid {
                        result.1 = "foreign".into();
                    }
                    Ok(result)
                },
                by_name
            )
            .is_err()
        );
        assert!(
            verify_with(&[client()], by_uid, |name| {
                let mut result = by_name(name)?;
                if result.0 == uid {
                    result.0 += 1;
                }
                Ok(result)
            })
            .is_err()
        );
    }
    assert!(verify_with(&[client()], |_| anyhow::bail!("unavailable"), by_name).is_err());
    assert!(verify_with(&[client()], by_uid, |_| anyhow::bail!("unavailable")).is_err());
    // A later call queries the namespace again; no previous match grants authority.
    verify_with(&[client()], by_uid, by_name).unwrap();
}

#[test]
fn bounded_native_account_lookup_checks_actual_uid_and_name() {
    let (uid, name) = lookup(Key::Uid(unsafe { libc::getuid() })).unwrap();
    assert!(lookup(Key::Name(&name)).unwrap() == (uid, name));
    assert!(lookup(Key::Uid(0)).unwrap() == (0, "root".into()));
    assert!(lookup(Key::Name("root")).unwrap() == (0, "root".into()));
    assert!(lookup(Key::Uid(u32::MAX)).is_err());
}
