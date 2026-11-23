// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! File effect as a pure state transition over an external file world.
//! This module never touches a real filesystem: digests and file bytes are
//! values supplied by the caller, standing in for an outside boundary.

use std::collections::HashMap;

use crate::core::{
    apply, lookup, Basis, Command, Lookup, Nat, Never, Observation, Outcome, ResourceId, Revision,
    StaleBasis, UnknownResource, World,
};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
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

/// Files keep their insertion order; lookups go through an index of the
/// first position of each path.
#[derive(Clone, Debug, Default)]
pub struct ExternalFileState {
    files: Vec<(NormalizedPath, FileRecord)>,
    first_positions: HashMap<NormalizedPath, usize>,
    pub read_failures: Vec<NormalizedPath>,
    pub write_failures: Vec<NormalizedPath>,
}

impl PartialEq for ExternalFileState {
    fn eq(&self, other: &Self) -> bool {
        self.files == other.files
            && self.read_failures == other.read_failures
            && self.write_failures == other.write_failures
    }
}

impl Eq for ExternalFileState {}

impl ExternalFileState {
    pub fn new(
        files: Vec<(NormalizedPath, FileRecord)>,
        read_failures: Vec<NormalizedPath>,
        write_failures: Vec<NormalizedPath>,
    ) -> Self {
        let mut first_positions = HashMap::with_capacity(files.len());
        for (position, (path, _)) in files.iter().enumerate() {
            first_positions.entry(path.clone()).or_insert(position);
        }
        Self {
            files,
            first_positions,
            read_failures,
            write_failures,
        }
    }

    pub fn files(&self) -> &[(NormalizedPath, FileRecord)] {
        &self.files
    }

    fn lookup(&self, path: &NormalizedPath) -> Option<&FileRecord> {
        self.first_positions
            .get(path)
            .and_then(|position| self.files.get(*position))
            .map(|(_, record)| record)
    }

    fn set_file(mut self, path: &NormalizedPath, record: FileRecord) -> Self {
        let held = self
            .first_positions
            .get(path)
            .copied()
            .and_then(|position| self.files.get_mut(position));
        if let Some(slot) = held {
            slot.1 = record;
        } else {
            self.first_positions.insert(path.clone(), self.files.len());
            self.files.push((path.clone(), record));
        }
        self
    }
}

/// Digests keep their insertion order; lookups go through an index of the
/// first position of each resource.
#[derive(Clone, Debug, Default)]
pub struct Digests {
    entries: Vec<(ResourceId, ContentDigest)>,
    first_positions: HashMap<ResourceId, usize>,
}

impl PartialEq for Digests {
    fn eq(&self, other: &Self) -> bool {
        self.entries == other.entries
    }
}

impl Eq for Digests {}

impl Digests {
    pub fn new(entries: Vec<(ResourceId, ContentDigest)>) -> Self {
        let mut first_positions = HashMap::with_capacity(entries.len());
        for (position, (resource, _)) in entries.iter().enumerate() {
            first_positions.entry(resource.clone()).or_insert(position);
        }
        Self {
            entries,
            first_positions,
        }
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
    match digests
        .first_positions
        .get(resource)
        .and_then(|position| digests.entries.get(*position))
    {
        Some((_, d)) => DigestLookup::Found(d.clone()),
        None => DigestLookup::Unobserved(UnobservedContents {
            resource: resource.clone(),
        }),
    }
}

pub fn set_digest(mut digests: Digests, resource: &ResourceId, digest: &ContentDigest) -> Digests {
    let held = digests
        .first_positions
        .get(resource)
        .copied()
        .and_then(|position| digests.entries.get_mut(position));
    if let Some(slot) = held {
        slot.1 = digest.clone();
    } else {
        digests
            .first_positions
            .insert(resource.clone(), digests.entries.len());
        digests.entries.push((resource.clone(), digest.clone()));
    }
    digests
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
    world: World,
    resource: &ResourceId,
    observed_at: &Nat,
) -> (Observation<Revision>, World) {
    match lookup(&world, resource) {
        Lookup::Unknown(_) => {
            let zero = Revision {
                value: Nat::from(0u8),
            };
            let world_prime = crate::core::append(world, resource.clone(), zero.clone());
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
            (observation, world)
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
pub fn track(req: TrackReq) -> TrackResult {
    let resource = path_resource(&req.path);
    let (observation, world) = register_resource(req.world, &resource, &req.observed_at);
    Outcome::Applied(Tracked { observation, world })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadReq<'a> {
    pub path: NormalizedPath,
    pub world: World,
    pub digests: Digests,
    pub state: &'a ExternalFileState,
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
pub fn read(req: ReadReq<'_>) -> ReadResult {
    if req.state.read_failures.contains(&req.path) {
        return Outcome::BoundaryFailed(ReadFailure { path: req.path });
    }
    let resource = path_resource(&req.path);
    match req.state.lookup(&req.path) {
        None => Outcome::Rejected(UnknownResource { resource }),
        Some(record) => {
            let digests = set_digest(req.digests, &resource, &record.digest);
            let (observation, world) = register_resource(req.world, &resource, &req.observed_at);
            let snapshot = FileSnapshot {
                path: req.path,
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
pub fn replace(req: ReplaceReq) -> ReplaceResult {
    let resource = req.command.basis.resource.clone();
    if resource != path_resource(&req.path) {
        return Outcome::Rejected(ReplaceRejection::ResourcePathMismatch(
            ResourcePathMismatch {
                resource,
                path: req.path,
            },
        ));
    }
    let expected = match lookup_digest(&req.digests, &resource) {
        DigestLookup::Unobserved(u) => {
            return Outcome::Rejected(ReplaceRejection::UnobservedContents(u));
        }
        DigestLookup::Found(d) => d,
    };
    let (world_after_basis, intent) = match apply(req.world, req.command) {
        (_, Outcome::Rejected(u)) => {
            return Outcome::Rejected(ReplaceRejection::UnknownResource(u))
        }
        (_, Outcome::Conflicted(k)) => return Outcome::Conflicted(ReplaceConflict::StaleBasis(k)),
        (_, Outcome::BoundaryFailed(f)) => f.elim(),
        (world_prime, Outcome::Applied(intent)) => (world_prime, intent),
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
                return Outcome::BoundaryFailed(WriteFailure { path: req.path });
            }
            let new_contents = intent.new_contents;
            let new_digest = intent.new_digest;
            let record = FileRecord {
                digest: new_digest.clone(),
                bytes: new_contents.clone(),
            };
            let state_prime = req.state.set_file(&req.path, record);
            let digests_prime = set_digest(req.digests, &resource, &new_digest);
            let (observation, world_prime) =
                register_resource(world_after_basis, &resource, &req.observed_at);
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
