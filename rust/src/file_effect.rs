// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! File effect as a pure state transition over an external file world.
//! This module never touches a real filesystem: digests and file bytes are
//! values supplied by the caller, standing in for an outside boundary.

use crate::core::{
    apply, lookup, Basis, Command, Lookup, Nat, Never, Observation, Outcome, ResourceId, Revision,
    StaleBasis, UnknownResource, World,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NormalizedPath {
    pub root: bool,
    pub segments: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContentDigest {
    pub value: String,
}

fn normalize_segments(raw: &[String]) -> Vec<String> {
    let mut acc: Vec<String> = Vec::new();
    for segment in raw {
        if segment.is_empty() || segment == "." {
            continue;
        } else if segment == ".." {
            acc.pop();
        } else {
            acc.push(segment.clone());
        }
    }
    acc
}

/// Normalize a raw root flag and segment list.
pub fn normalize_path(root: bool, raw: &[String]) -> NormalizedPath {
    NormalizedPath {
        root,
        segments: normalize_segments(raw),
    }
}

fn path_string(path: &NormalizedPath) -> String {
    let body = path.segments.join("/");
    if path.root {
        format!("/{body}")
    } else {
        body
    }
}

const FILE_KIND: &str = "file";

fn path_resource(path: &NormalizedPath) -> ResourceId {
    ResourceId {
        kind: FILE_KIND.to_string(),
        name: path_string(path),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRecord {
    pub digest: ContentDigest,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct ExternalFileState {
    files: Vec<(NormalizedPath, FileRecord)>,
    pub read_failures: Vec<NormalizedPath>,
    pub write_failures: Vec<NormalizedPath>,
}

impl ExternalFileState {
    pub fn new(
        files: Vec<(NormalizedPath, FileRecord)>,
        read_failures: Vec<NormalizedPath>,
        write_failures: Vec<NormalizedPath>,
    ) -> Self {
        Self {
            files,
            read_failures,
            write_failures,
        }
    }

    pub fn files(&self) -> &[(NormalizedPath, FileRecord)] {
        &self.files
    }

    fn lookup(&self, path: &NormalizedPath) -> Option<&FileRecord> {
        self.files.iter().find(|(p, _)| p == path).map(|(_, r)| r)
    }

    fn set_file(&self, path: &NormalizedPath, record: FileRecord) -> Self {
        let mut files = self.files.clone();
        if let Some(slot) = files.iter_mut().find(|(p, _)| p == path) {
            slot.1 = record;
        } else {
            files.push((path.clone(), record));
        }
        Self {
            files,
            read_failures: self.read_failures.clone(),
            write_failures: self.write_failures.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Digests {
    entries: Vec<(ResourceId, ContentDigest)>,
}

impl Digests {
    pub fn new(entries: Vec<(ResourceId, ContentDigest)>) -> Self {
        Self { entries }
    }

    pub fn entries(&self) -> &[(ResourceId, ContentDigest)] {
        &self.entries
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnobservedContents {
    pub resource: ResourceId,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DigestLookup {
    Found(ContentDigest),
    Unobserved(UnobservedContents),
}

pub fn lookup_digest(digests: &Digests, resource: &ResourceId) -> DigestLookup {
    match digests.entries.iter().find(|(r, _)| r == resource) {
        Some((_, d)) => DigestLookup::Found(d.clone()),
        None => DigestLookup::Unobserved(UnobservedContents {
            resource: resource.clone(),
        }),
    }
}

pub fn set_digest(digests: &Digests, resource: &ResourceId, digest: &ContentDigest) -> Digests {
    let mut entries = digests.entries.clone();
    if let Some(slot) = entries.iter_mut().find(|(r, _)| r == resource) {
        slot.1 = digest.clone();
    } else {
        entries.push((resource.clone(), digest.clone()));
    }
    Digests { entries }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileSnapshot {
    pub path: NormalizedPath,
    pub contents: Vec<u8>,
    pub digest: ContentDigest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExternalMutation {
    pub expected: ContentDigest,
    pub actual: ContentDigest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplaceContents {
    pub new_contents: Vec<u8>,
    pub new_digest: ContentDigest,
}

fn register_resource(
    world: &World,
    resource: &ResourceId,
    observed_at: &Nat,
) -> (Observation<Revision>, World) {
    match lookup(world, resource) {
        Lookup::Unknown(_) => {
            let mut entries: Vec<(ResourceId, Revision)> = crate::core::entries(world).to_vec();
            let zero = Revision {
                value: Nat::from(0u8),
            };
            entries.push((resource.clone(), zero.clone()));
            let world_prime = crate::core::world_of(entries);
            let observation = Observation {
                payload: zero.clone(),
                basis: Basis {
                    resource: resource.clone(),
                    revision: zero,
                },
                observed_at: observed_at.clone(),
            };
            (observation, world_prime)
        }
        Lookup::Found(revision) => {
            let observation = Observation {
                payload: revision.clone(),
                basis: Basis {
                    resource: resource.clone(),
                    revision: revision.clone(),
                },
                observed_at: observed_at.clone(),
            };
            (observation, world.clone())
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrackReq {
    pub path: NormalizedPath,
    pub world: World,
    pub observed_at: Nat,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tracked {
    pub observation: Observation<Revision>,
    pub world: World,
}

pub type TrackResult = Outcome<Tracked, Never, Never, Never>;

/// Register a path as an owned resource and return its observation.
pub fn track(req: &TrackReq) -> TrackResult {
    let resource = path_resource(&req.path);
    let (observation, world) = register_resource(&req.world, &resource, &req.observed_at);
    Outcome::Applied(Tracked { observation, world })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadReq {
    pub path: NormalizedPath,
    pub world: World,
    pub digests: Digests,
    pub state: ExternalFileState,
    pub observed_at: Nat,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub observation: Observation<FileSnapshot>,
    pub world: World,
    pub digests: Digests,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadFailure {
    pub path: NormalizedPath,
}

pub type ReadResult = Outcome<Read, UnknownResource, Never, ReadFailure>;

/// Read a path from the external state; a declared read failure closes as a boundary failure.
pub fn read(req: &ReadReq) -> ReadResult {
    if req.state.read_failures.contains(&req.path) {
        return Outcome::BoundaryFailed(ReadFailure {
            path: req.path.clone(),
        });
    }
    let resource = path_resource(&req.path);
    match req.state.lookup(&req.path) {
        None => Outcome::Rejected(UnknownResource { resource }),
        Some(record) => {
            let digests = set_digest(&req.digests, &resource, &record.digest);
            let (observation, world) = register_resource(&req.world, &resource, &req.observed_at);
            let snapshot = FileSnapshot {
                path: req.path.clone(),
                contents: record.bytes.clone(),
                digest: record.digest.clone(),
            };
            Outcome::Applied(Read {
                observation: Observation {
                    payload: snapshot,
                    basis: observation.basis,
                    observed_at: observation.observed_at,
                },
                world,
                digests,
            })
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplaceReq {
    pub command: Command<ReplaceContents>,
    pub path: NormalizedPath,
    pub world: World,
    pub digests: Digests,
    pub state: ExternalFileState,
    pub observed_at: Nat,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Replaced {
    pub observation: Observation<FileSnapshot>,
    pub world: World,
    pub digests: Digests,
    pub state: ExternalFileState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResourcePathMismatch {
    pub resource: ResourceId,
    pub path: NormalizedPath,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReplaceRejection {
    ResourcePathMismatch(ResourcePathMismatch),
    UnknownResource(UnknownResource),
    UnobservedContents(UnobservedContents),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReplaceConflict {
    StaleBasis(StaleBasis),
    ExternalMutation(ExternalMutation),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WriteFailure {
    pub path: NormalizedPath,
}

pub type ReplaceResult = Outcome<Replaced, ReplaceRejection, ReplaceConflict, WriteFailure>;

/// Apply a compare-and-replace atomic write, checked in path, digest,
/// world staleness, then mutation order.
pub fn replace(req: &ReplaceReq) -> ReplaceResult {
    let resource = req.command.basis.resource.clone();
    if resource != path_resource(&req.path) {
        return Outcome::Rejected(ReplaceRejection::ResourcePathMismatch(
            ResourcePathMismatch {
                resource,
                path: req.path.clone(),
            },
        ));
    }
    let expected = match lookup_digest(&req.digests, &resource) {
        DigestLookup::Unobserved(u) => {
            return Outcome::Rejected(ReplaceRejection::UnobservedContents(u));
        }
        DigestLookup::Found(d) => d,
    };
    let world_after_basis = match apply(&req.world, req.command.clone()) {
        Outcome::Rejected(u) => return Outcome::Rejected(ReplaceRejection::UnknownResource(u)),
        Outcome::Conflicted(k) => return Outcome::Conflicted(ReplaceConflict::StaleBasis(k)),
        Outcome::BoundaryFailed(f) => f.elim(),
        Outcome::Applied((_, world_prime)) => world_prime,
    };
    match req.state.lookup(&req.path) {
        None => Outcome::Rejected(ReplaceRejection::UnknownResource(UnknownResource {
            resource,
        })),
        Some(current) => {
            if current.digest != expected {
                return Outcome::Conflicted(ReplaceConflict::ExternalMutation(ExternalMutation {
                    expected,
                    actual: current.digest.clone(),
                }));
            }
            if req.state.write_failures.contains(&req.path) {
                return Outcome::BoundaryFailed(WriteFailure {
                    path: req.path.clone(),
                });
            }
            let new_contents = req.command.intent.new_contents.clone();
            let new_digest = req.command.intent.new_digest.clone();
            let record = FileRecord {
                digest: new_digest.clone(),
                bytes: new_contents.clone(),
            };
            let state_prime = req.state.set_file(&req.path, record);
            let digests_prime = set_digest(&req.digests, &resource, &new_digest);
            let (observation, world_prime) =
                register_resource(&world_after_basis, &resource, &req.observed_at);
            Outcome::Applied(Replaced {
                observation: Observation {
                    payload: FileSnapshot {
                        path: req.path.clone(),
                        contents: new_contents,
                        digest: new_digest,
                    },
                    basis: observation.basis,
                    observed_at: observation.observed_at,
                },
                world: world_prime,
                digests: digests_prime,
                state: state_prime,
            })
        }
    }
}
