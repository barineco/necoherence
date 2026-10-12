// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{
    lookup_digest, normalize_path, read, replace, set_digest, track, world_of, Basis, Command,
    ContentDigest, Digests, ExternalFileState, FileRecord, Nat, Outcome, ReadReq, ReplaceContents,
    ReplaceReq, TrackReq,
};
use proptest::prelude::*;

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

fn digest(s: &str) -> ContentDigest {
    ContentDigest {
        value: s.to_string(),
    }
}

proptest! {
    #[test]
    fn normalize_path_drops_dot_segments(root in prop::bool::ANY) {
        let raw = vec![".".to_string(), "a".to_string(), "".to_string(), "b".to_string()];
        let p = normalize_path(root, &raw);
        prop_assert_eq!(p.segments, vec!["a".to_string(), "b".to_string()]);
        prop_assert_eq!(p.root, root);
    }

    #[test]
    fn normalize_path_pops_on_dotdot(root in prop::bool::ANY) {
        let raw = vec!["a".to_string(), "b".to_string(), "..".to_string(), "c".to_string()];
        let p = normalize_path(root, &raw);
        prop_assert_eq!(p.segments, vec!["a".to_string(), "c".to_string()]);
    }

    #[test]
    fn track_registers_new_resource_at_zero(_x in 0u64..3) {
        let path = normalize_path(true, &["a".to_string()]);
        let result = track(&TrackReq { path, world: world_of([]), observed_at: nat(0) });
        match result {
            Outcome::Applied(t) => prop_assert_eq!(t.observation.payload, necoherence::Revision { value: nat(0) }),
            _ => prop_assert!(false, "expected applied"),
        }
    }

    #[test]
    fn read_missing_path_is_rejected(_x in 0u64..3) {
        let path = normalize_path(true, &["a".to_string()]);
        let result = read(&ReadReq {
            path,
            world: world_of([]),
            digests: Digests::new(vec![]),
            state: ExternalFileState::default(),
            observed_at: nat(0),
        });
        prop_assert!(matches!(result, Outcome::Rejected(_)));
    }

    #[test]
    fn set_digest_then_lookup_returns_value(name in "[a-z]{1,5}") {
        let resource = necoherence::ResourceId { kind: "file".to_string(), name };
        let digests = set_digest(&Digests::new(vec![]), &resource, &digest("d1"));
        match lookup_digest(&digests, &resource) {
            necoherence::DigestLookup::Found(d) => prop_assert_eq!(d, digest("d1")),
            necoherence::DigestLookup::Unobserved(_) => prop_assert!(false),
        }
    }
}

#[test]
fn read_declared_failure_is_boundary_failed() {
    let path = normalize_path(true, &["a".to_string()]);
    let state = ExternalFileState::new(vec![], vec![path.clone()], vec![]);
    let result = read(&ReadReq {
        path,
        world: world_of([]),
        digests: Digests::new(vec![]),
        state,
        observed_at: nat(0),
    });
    assert!(matches!(result, Outcome::BoundaryFailed(_)));
}

#[test]
fn replace_atomic_write_updates_state_on_success() {
    let path = normalize_path(true, &["a".to_string()]);
    let resource = necoherence::ResourceId {
        kind: "file".to_string(),
        name: "/a".to_string(),
    };
    let world = world_of([(resource.clone(), necoherence::Revision { value: nat(0) })]);
    let digests = set_digest(&Digests::new(vec![]), &resource, &digest("old"));
    let state = ExternalFileState::new(
        vec![(
            path.clone(),
            FileRecord {
                digest: digest("old"),
                bytes: vec![1, 2, 3],
            },
        )],
        vec![],
        vec![],
    );
    let command = Command {
        intent: ReplaceContents {
            new_contents: vec![4, 5, 6],
            new_digest: digest("new"),
        },
        basis: Basis {
            resource: resource.clone(),
            revision: necoherence::Revision { value: nat(0) },
        },
    };
    let result = replace(&ReplaceReq {
        command,
        path,
        world,
        digests,
        state,
        observed_at: nat(1),
    });
    match result {
        Outcome::Applied(r) => {
            assert_eq!(r.observation.payload.digest, digest("new"));
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn replace_unobserved_contents_is_rejected() {
    let path = normalize_path(true, &["a".to_string()]);
    let resource = necoherence::ResourceId {
        kind: "file".to_string(),
        name: "/a".to_string(),
    };
    let world = world_of([(resource.clone(), necoherence::Revision { value: nat(0) })]);
    let command = Command {
        intent: ReplaceContents {
            new_contents: vec![1],
            new_digest: digest("new"),
        },
        basis: Basis {
            resource,
            revision: necoherence::Revision { value: nat(0) },
        },
    };
    let result = replace(&ReplaceReq {
        command,
        path,
        world,
        digests: Digests::new(vec![]),
        state: ExternalFileState::default(),
        observed_at: nat(0),
    });
    assert!(matches!(
        result,
        Outcome::Rejected(necoherence::ReplaceRejection::UnobservedContents(_))
    ));
}

#[test]
fn replace_external_mutation_is_conflicted() {
    let path = normalize_path(true, &["a".to_string()]);
    let resource = necoherence::ResourceId {
        kind: "file".to_string(),
        name: "/a".to_string(),
    };
    let world = world_of([(resource.clone(), necoherence::Revision { value: nat(0) })]);
    let digests = set_digest(&Digests::new(vec![]), &resource, &digest("expected"));
    let state = ExternalFileState::new(
        vec![(
            path.clone(),
            FileRecord {
                digest: digest("actual-mutated"),
                bytes: vec![9],
            },
        )],
        vec![],
        vec![],
    );
    let command = Command {
        intent: ReplaceContents {
            new_contents: vec![1],
            new_digest: digest("new"),
        },
        basis: Basis {
            resource,
            revision: necoherence::Revision { value: nat(0) },
        },
    };
    let result = replace(&ReplaceReq {
        command,
        path,
        world,
        digests,
        state,
        observed_at: nat(0),
    });
    assert!(matches!(
        result,
        Outcome::Conflicted(necoherence::ReplaceConflict::ExternalMutation(_))
    ));
}

mod host_adapter {
    use super::*;
    use std::{
        fs,
        path::{Path, PathBuf},
    };

    pub struct Adapter {
        pub root: PathBuf,
        pub fail_writes: bool,
    }
    impl Adapter {
        pub fn path(&self, raw: &Path) -> necoherence::NormalizedPath {
            let host = if raw.is_absolute() {
                raw.to_path_buf()
            } else {
                self.root.join(raw)
            };
            let parts = host
                .components()
                .skip(1)
                .map(|p| p.as_os_str().to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            normalize_path(true, &parts)
        }
        fn host(&self, path: &necoherence::NormalizedPath) -> PathBuf {
            path.segments
                .iter()
                .fold(PathBuf::from("/"), |host, segment| host.join(segment))
        }
        pub fn state(&self, path: &necoherence::NormalizedPath) -> ExternalFileState {
            match fs::read(self.host(path)) {
                Ok(bytes) => ExternalFileState::new(
                    vec![(
                        path.clone(),
                        FileRecord {
                            digest: digest(&format!("{bytes:?}")),
                            bytes,
                        },
                    )],
                    vec![],
                    vec![],
                ),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    ExternalFileState::default()
                }
                Err(_) => ExternalFileState::new(vec![], vec![path.clone()], vec![]),
            }
        }
        pub fn replace(
            &self,
            command: Command<ReplaceContents>,
            path: necoherence::NormalizedPath,
            world: necoherence::World,
            digests: Digests,
            at: u64,
        ) -> necoherence::ReplaceResult {
            let mut state = self.state(&path);
            if self.fail_writes {
                state.write_failures.push(path.clone());
            }
            match replace(&ReplaceReq {
                command,
                path: path.clone(),
                world,
                digests,
                state,
                observed_at: nat(at),
            }) {
                Outcome::Applied(replaced) => {
                    let target = self.host(&path);
                    let temporary = target.with_extension("necoherence-tmp");
                    match fs::write(&temporary, &replaced.observation.payload.contents)
                        .and_then(|_| fs::rename(&temporary, &target))
                    {
                        Ok(()) => Outcome::Applied(replaced),
                        Err(_) => Outcome::BoundaryFailed(necoherence::WriteFailure { path }),
                    }
                }
                other => other,
            }
        }
    }
}

#[test]
fn host_file_adapter_covers_real_filesystem_states() {
    use host_adapter::Adapter;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };
    let root = std::env::temp_dir().join(format!(
        "necoherence-file-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    fs::create_dir_all(root.join("nested")).unwrap();
    let target = root.join("nested/item.bin");
    fs::write(&target, b"before").unwrap();
    let adapter = Adapter {
        root: root.clone(),
        fail_writes: false,
    };
    let relative = adapter.path(std::path::Path::new("nested/item.bin"));
    let absolute = adapter.path(&target);
    let unnormalised = adapter.path(std::path::Path::new("nested/ignored/../item.bin"));
    assert_eq!(relative, absolute);
    assert_eq!(relative, unnormalised);
    let mut coverage = std::collections::BTreeSet::from(["paths"]);
    let Outcome::Applied(tracked) = track(&TrackReq {
        path: relative.clone(),
        world: world_of([]),
        observed_at: nat(0),
    });
    let Outcome::Applied(observed) = read(&ReadReq {
        path: relative.clone(),
        world: tracked.world,
        digests: Digests::new(vec![]),
        state: adapter.state(&relative),
        observed_at: nat(1),
    }) else {
        panic!("read")
    };
    coverage.insert("registered");
    assert!(matches!(
        read(&ReadReq {
            path: adapter.path(std::path::Path::new("missing")),
            world: world_of([]),
            digests: Digests::new(vec![]),
            state: ExternalFileState::default(),
            observed_at: nat(2)
        }),
        Outcome::Rejected(_)
    ));
    coverage.insert("missing");
    let Outcome::Applied(only_tracked) = track(&TrackReq {
        path: relative.clone(),
        world: world_of([]),
        observed_at: nat(3),
    });
    assert!(matches!(
        adapter.replace(
            Command {
                intent: ReplaceContents {
                    new_contents: b"x".to_vec(),
                    new_digest: digest("x")
                },
                basis: only_tracked.observation.basis
            },
            relative.clone(),
            only_tracked.world,
            Digests::new(vec![]),
            4
        ),
        Outcome::Rejected(necoherence::ReplaceRejection::UnobservedContents(_))
    ));
    coverage.insert("unobserved");
    fs::write(&target, b"changed").unwrap();
    assert!(matches!(
        adapter.replace(
            Command {
                intent: ReplaceContents {
                    new_contents: b"new".to_vec(),
                    new_digest: digest("new")
                },
                basis: observed.observation.basis.clone()
            },
            relative.clone(),
            observed.world.clone(),
            observed.digests.clone(),
            5
        ),
        Outcome::Conflicted(necoherence::ReplaceConflict::ExternalMutation(_))
    ));
    coverage.insert("changed");
    let Outcome::Applied(current) = read(&ReadReq {
        path: relative.clone(),
        world: observed.world,
        digests: observed.digests,
        state: adapter.state(&relative),
        observed_at: nat(6),
    }) else {
        panic!("read")
    };
    let blocked = Adapter {
        root: root.clone(),
        fail_writes: true,
    };
    assert!(matches!(
        blocked.replace(
            Command {
                intent: ReplaceContents {
                    new_contents: b"blocked".to_vec(),
                    new_digest: digest("blocked")
                },
                basis: current.observation.basis.clone()
            },
            relative.clone(),
            current.world.clone(),
            current.digests.clone(),
            7
        ),
        Outcome::BoundaryFailed(_)
    ));
    coverage.insert("write-failure");
    assert!(matches!(
        adapter.replace(
            Command {
                intent: ReplaceContents {
                    new_contents: b"atomic".to_vec(),
                    new_digest: digest("atomic")
                },
                basis: current.observation.basis
            },
            relative,
            current.world,
            current.digests,
            8
        ),
        Outcome::Applied(_)
    ));
    assert_eq!(fs::read(&target).unwrap(), b"atomic");
    coverage.insert("atomic");
    assert_eq!(
        coverage,
        std::collections::BTreeSet::from([
            "atomic",
            "changed",
            "missing",
            "paths",
            "registered",
            "unobserved",
            "write-failure"
        ])
    );
    fs::remove_dir_all(root).unwrap();
}
