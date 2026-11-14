use super::*;
use crate::fleet::repository::{CommandOutput, CommandRequest};

fn id(n: u8) -> ObjectId {
    ObjectId::parse(format!("{n:02x}").repeat(20)).unwrap()
}
fn row(mode: &[u8], name: &[u8], n: u8) -> Vec<u8> {
    [mode, b" ", name, b"\0", &[n; 20]].concat()
}
fn limits() -> ObjectLimits {
    ObjectLimits {
        entries: 32,
        bytes: 8192,
        depth: 8,
        path_bytes: 8192,
    }
}

struct Fake {
    objects: BTreeMap<String, (&'static str, Vec<u8>)>,
    requests: Vec<CommandRequest>,
    fault: Option<(usize, u8)>,
}
impl CommandRunner for Fake {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        if let Some((at, kind)) = self.fault
            && self.requests.len() == at
        {
            return match kind {
                0 => anyhow::bail!("capture uncertain"),
                1 => Ok(CommandOutput {
                    status: 128,
                    stdout: Vec::new(),
                    stderr: b"PRIVATE-OBJECT".to_vec(),
                }),
                _ => Ok(CommandOutput {
                    status: 0,
                    stdout: format!("{}\n", id(99).as_str()).into_bytes(),
                    stderr: Vec::new(),
                }),
            };
        }
        assert_eq!(request.current_dir.as_deref(), Some(Path::new("/repo")));
        assert!(request.environment.is_empty());
        let args = request
            .args
            .iter()
            .map(|s| s.to_str().unwrap())
            .collect::<Vec<_>>();
        let bytes = match args.as_slice() {
            ["cat-file", kind, name] => {
                let (actual, bytes) = self.objects.get(*name).expect("unexpected object");
                assert_eq!(actual, kind);
                bytes.clone()
            }
            ["hash-object", "--no-filters", "-t", kind, "--stdin"] => {
                let input = request.stdin.as_ref().expect("hash stdin required");
                let (name, _) = self
                    .objects
                    .iter()
                    .find(|(_, (actual, bytes))| actual == kind && bytes == input)
                    .expect("unexpected hash payload");
                format!("{name}\n").into_bytes()
            }
            _ => panic!("unexpected helper"),
        };
        Ok(CommandOutput {
            status: 0,
            stdout: bytes,
            stderr: Vec::new(),
        })
    }
}
fn manager(objects: Vec<(u8, &'static str, Vec<u8>)>) -> RepositoryManager<Fake> {
    RepositoryManager::new(
        "/installed/git",
        Fake {
            objects: objects
                .into_iter()
                .map(|(n, k, b)| (id(n).as_str().to_owned(), (k, b)))
                .collect(),
            requests: Vec::new(),
            fault: None,
        },
    )
}
fn simple(bytes: Vec<u8>) -> RepositoryManager<Fake> {
    manager(vec![
        (1, "tree", row(b"100644", b"PRIVATE-OBJECT", 2)),
        (2, "blob", bytes),
    ])
}
fn reject(manager: &mut RepositoryManager<Fake>, limits: ObjectLimits, expected: &str) {
    let error = manager
        .observe_tree(Path::new("/repo"), &id(1), limits)
        .err()
        .unwrap()
        .to_string();
    assert!(error.contains(expected), "{error}");
    assert!(!error.contains("PRIVATE-OBJECT"));
}

#[test]
fn nested_tree_binary_executable_and_symlink_are_observed_without_following_targets() {
    let root = [
        row(b"40000", b"a-dir", 2),
        row(b"100755", b"b-exec", 4),
        row(b"120000", b"c-link", 5),
    ]
    .concat();
    let child = row(b"100644", b"raw\t\n\xff", 3);
    let bytes = root.len() + child.len() + 3 + 1 + 11;
    let mut manager = manager(vec![
        (1, "tree", root),
        (2, "tree", child),
        (3, "blob", b"a\0\xff".to_vec()),
        (4, "blob", b"x".to_vec()),
        (5, "blob", b"/outside/..".to_vec()),
    ]);
    let observed = manager
        .observe_tree(Path::new("/repo"), &id(1), limits())
        .unwrap();
    assert_eq!(observed.root().as_str(), id(1).as_str());
    assert_eq!(observed.observed_bytes(), bytes as u64);
    assert_eq!(observed.entries().len(), 4);
    for (path, kind, n) in [
        (b"a-dir".as_slice(), TreeKind::Directory, 2),
        (b"a-dir/raw\t\n\xff", TreeKind::File, 3),
        (b"b-exec", TreeKind::Executable, 4),
        (b"c-link", TreeKind::Symlink, 5),
    ] {
        let entry = observed.entries().get(path).unwrap();
        assert!(entry.kind() == kind);
        assert_eq!(entry.object().as_str(), id(n).as_str());
    }
    assert_eq!(manager.runner().requests.len(), 10);
}

#[test]
fn empty_tree_and_empty_blob_are_distinct_valid_observations() {
    let mut manager = manager(vec![(1, "tree", Vec::new())]);
    let observed = manager
        .observe_tree(
            Path::new("/repo"),
            &id(1),
            ObjectLimits {
                entries: 1,
                bytes: 0,
                depth: 1,
                path_bytes: 0,
            },
        )
        .unwrap();
    assert!(observed.entries().is_empty());
    assert_eq!(observed.observed_bytes(), 0);
    let mut manager = simple(Vec::new());
    let observed = manager
        .observe_tree(Path::new("/repo"), &id(1), limits())
        .unwrap();
    assert_eq!(observed.entries().len(), 1);
    assert!(observed.observed_bytes() > 0);
    assert_eq!(
        manager.runner().requests.last().unwrap().stdin.as_deref(),
        Some(b"".as_slice())
    );
}

#[test]
fn invalid_limits_fail_before_any_helper() {
    for bound in [
        ObjectLimits {
            entries: 0,
            ..limits()
        },
        ObjectLimits {
            entries: 32769,
            ..limits()
        },
        ObjectLimits {
            bytes: 64 * 1024 * 1024 + 1,
            ..limits()
        },
        ObjectLimits {
            depth: 0,
            ..limits()
        },
        ObjectLimits {
            depth: 65,
            ..limits()
        },
        ObjectLimits {
            path_bytes: 16 * 1024 * 1024 + 1,
            ..limits()
        },
    ] {
        let mut manager = simple(b"x".to_vec());
        reject(
            &mut manager,
            bound,
            "invalid native object observation limits",
        );
        assert!(manager.runner().requests.is_empty());
    }
}

#[test]
fn repeated_blob_references_count_each_logical_path_and_payload() {
    let tree = [row(b"100644", b"a", 2), row(b"100644", b"b", 2)].concat();
    let total = tree.len() as u64 + 2 * 4;
    let objects = vec![(1, "tree", tree), (2, "blob", b"same".to_vec())];
    let exact = ObjectLimits {
        entries: 3,
        bytes: total,
        depth: 1,
        path_bytes: 2,
    };
    assert_eq!(
        manager(objects.clone())
            .observe_tree(Path::new("/repo"), &id(1), exact)
            .unwrap()
            .observed_bytes(),
        total
    );
    for (bound, why) in [
        (
            ObjectLimits {
                entries: 2,
                ..exact
            },
            "entry bound",
        ),
        (
            ObjectLimits {
                bytes: total - 1,
                ..exact
            },
            "byte bound",
        ),
        (
            ObjectLimits {
                path_bytes: 1,
                ..exact
            },
            "path byte bound",
        ),
    ] {
        reject(&mut manager(objects.clone()), bound, why);
    }
}

#[test]
fn malformed_cycles_hit_depth_bound_without_recursive_stack_or_infinite_helpers() {
    let mut manager = manager(vec![(1, "tree", row(b"40000", b"d", 1))]);
    reject(
        &mut manager,
        ObjectLimits {
            depth: 3,
            ..limits()
        },
        "depth bound",
    );
    assert_eq!(manager.runner().requests.len(), 8);
}

#[test]
fn full_relative_path_limit_is_independent_of_individual_component_limit() {
    let mut manager = manager(vec![
        (1, "tree", row(b"40000", &vec![b'x'; 4096], 2)),
        (2, "tree", row(b"100644", b"y", 3)),
    ]);
    reject(&mut manager, limits(), "path length exceeded");
    assert_eq!(manager.runner().requests.len(), 4);
}

#[test]
fn child_capture_or_hash_failure_returns_no_partial_inventory_and_does_not_retry() {
    for (at, kind, why) in [
        (3, 0, "capture uncertain"),
        (4, 0, "capture uncertain"),
        (3, 1, "read native blob object failed"),
        (4, 1, "hash native blob object failed"),
        (4, 2, "native blob content differs"),
    ] {
        let mut manager = simple(b"private".to_vec());
        manager.runner.fault = Some((at, kind));
        reject(&mut manager, limits(), why);
        assert_eq!(manager.runner().requests.len(), at);
    }
}

#[test]
fn blob_ceiling_rejects_before_rehash_even_with_larger_total_allowance() {
    let bound = ObjectLimits {
        bytes: 64 * 1024 * 1024,
        ..limits()
    };
    let mut manager = simple(vec![b'x'; object::MAX_BLOB_BYTES]);
    assert!(
        manager
            .observe_tree(Path::new("/repo"), &id(1), bound)
            .is_ok()
    );
    drop(manager);
    let mut manager = simple(vec![b'x'; object::MAX_BLOB_BYTES + 1]);
    reject(&mut manager, bound, "native blob object size outside bound");
    assert_eq!(manager.runner().requests.len(), 3);
}

struct IndexOutput(Vec<u8>);
impl CommandRunner for IndexOutput {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        assert_eq!(request.args[0], "ls-files");
        Ok(CommandOutput {
            status: 0,
            stdout: std::mem::take(&mut self.0),
            stderr: Vec::new(),
        })
    }
}
fn index_record(mode: &str, path: &[u8], n: u8) -> Vec<u8> {
    [
        format!("H {mode} {} 0\t", id(n).as_str()).as_bytes(),
        path,
        b"\0",
    ]
    .concat()
}
fn index_view(bytes: Vec<u8>) -> crate::fleet::repository::IndexEntries {
    RepositoryManager::new("/installed/git", IndexOutput(bytes))
        .index_entries(Path::new("/repo"))
        .unwrap()
}

#[test]
fn index_projection_matches_exact_raw_leaf_paths_modes_and_ids_not_directories() {
    let root = [
        row(b"40000", b"a", 2),
        row(b"100644", b"b", 3),
        row(b"100755", b"c", 4),
        row(b"120000", b"d", 5),
        row(b"40000", b"e", 6),
    ]
    .concat();
    let mut repository = manager(vec![
        (1, "tree", root),
        (2, "tree", row(b"100644", b"raw\t\n\xff", 7)),
        (3, "blob", b"f".to_vec()),
        (4, "blob", b"x".to_vec()),
        (5, "blob", b"/outside".to_vec()),
        (6, "tree", Vec::new()),
        (7, "blob", b"n".to_vec()),
    ]);
    let observed = repository
        .observe_tree(Path::new("/repo"), &id(1), limits())
        .unwrap();
    let rows = vec![
        index_record("120000", b"d", 5),
        index_record("100755", b"c", 4),
        index_record("100644", b"b", 3),
        index_record("100644", b"a/raw\t\n\xff", 7),
    ];
    assert!(index_view(rows.concat()).matches_tree(&observed));
    assert!(!index_view(rows[1..].concat()).matches_tree(&observed));
    let mut extra = rows.clone();
    extra.push(index_record("100644", b"extra", 3));
    assert!(!index_view(extra.concat()).matches_tree(&observed));
    for replacement in [
        index_record("100644", b"d", 5),
        index_record("120000", b"d", 8),
        index_record("120000", b"other", 5),
    ] {
        let mut changed = rows.clone();
        changed[0] = replacement;
        assert!(!index_view(changed.concat()).matches_tree(&observed));
    }
    let empty = manager(vec![
        (1, "tree", row(b"40000", b"empty", 2)),
        (2, "tree", Vec::new()),
    ])
    .observe_tree(Path::new("/repo"), &id(1), limits())
    .unwrap();
    assert!(index_view(Vec::new()).matches_tree(&empty));
}
