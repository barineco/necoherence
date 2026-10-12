// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/string
import necoherence/core.{
  type Command, type Observation, type Outcome, type ResourceId, type Revision,
  type StaleBasis, type UnknownResource, type World, Applied, Basis,
  BoundaryFailed, Conflicted, Found, Observation, Rejected, Unknown,
  UnknownResource,
}

pub type NormalizedPath {
  NormalizedPath(root: Bool, segments: List(String))
}

pub type ContentDigest {
  ContentDigest(value: String)
}

fn drop_last(items: List(a)) -> List(a) {
  case items {
    [] -> []
    [_] -> []
    [head, ..rest] -> [head, ..drop_last(rest)]
  }
}

fn normalize_segments(raw: List(String)) -> List(String) {
  list.fold(raw, [], fn(acc, segment) {
    case segment == "" || segment == "." {
      True -> acc
      False ->
        case segment == ".." {
          True -> drop_last(acc)
          False -> list.append(acc, [segment])
        }
    }
  })
}

/// Reduce a raw root flag and segment list into a normalized path.
pub fn normalize_path(root: Bool, raw: List(String)) -> NormalizedPath {
  NormalizedPath(root, normalize_segments(raw))
}

fn path_string(path: NormalizedPath) -> String {
  let body = string.join(path.segments, "/")
  case path.root {
    True -> "/" <> body
    False -> body
  }
}

const file_kind = "file"

fn path_resource(path: NormalizedPath) -> ResourceId {
  core.resource(file_kind, path_string(path))
}

pub type FileRecord {
  FileRecord(digest: ContentDigest, bytes: List(Int))
}

/// The external world normalize_path, track, read, and replace observe and
/// update. Read and write failures stand for a boundary failure such as a
/// permission or I/O error without modeling any particular exception type.
pub type ExternalFileState {
  ExternalFileState(
    files: List(#(NormalizedPath, FileRecord)),
    read_failures: List(NormalizedPath),
    write_failures: List(NormalizedPath),
  )
}

fn state_lookup(
  state: ExternalFileState,
  path: NormalizedPath,
) -> Result(FileRecord, Nil) {
  case list.find(state.files, fn(entry) { entry.0 == path }) {
    Ok(#(_, record)) -> Ok(record)
    Error(_) -> Error(Nil)
  }
}

fn set_file(
  state: ExternalFileState,
  path: NormalizedPath,
  record: FileRecord,
) -> ExternalFileState {
  let has_entry = list.any(state.files, fn(entry) { entry.0 == path })
  let files = case has_entry {
    True ->
      list.map(state.files, fn(entry) {
        case entry.0 == path {
          True -> #(path, record)
          False -> entry
        }
      })
    False -> list.append(state.files, [#(path, record)])
  }
  ExternalFileState(..state, files: files)
}

pub type Digests {
  Digests(entries: List(#(ResourceId, ContentDigest)))
}

pub type UnobservedContents {
  UnobservedContents(resource: ResourceId)
}

pub type DigestLookup {
  DigestFound(ContentDigest)
  DigestUnobserved(UnobservedContents)
}

pub fn lookup_digest(digests: Digests, resource: ResourceId) -> DigestLookup {
  case list.find(digests.entries, fn(entry) { entry.0 == resource }) {
    Ok(#(_, digest)) -> DigestFound(digest)
    Error(_) -> DigestUnobserved(UnobservedContents(resource))
  }
}

pub fn set_digest(
  digests: Digests,
  resource: ResourceId,
  digest: ContentDigest,
) -> Digests {
  let has_entry = list.any(digests.entries, fn(entry) { entry.0 == resource })
  case has_entry {
    True ->
      Digests(
        list.map(digests.entries, fn(entry) {
          case entry.0 == resource {
            True -> #(resource, digest)
            False -> entry
          }
        }),
      )
    False -> Digests(list.append(digests.entries, [#(resource, digest)]))
  }
}

pub type FileSnapshot {
  FileSnapshot(path: NormalizedPath, contents: List(Int), digest: ContentDigest)
}

pub type ExternalMutation {
  ExternalMutation(expected: ContentDigest, actual: ContentDigest)
}

pub type ReplaceContents {
  ReplaceContents(new_contents: List(Int), new_digest: ContentDigest)
}

fn register_resource(
  world: World,
  resource: ResourceId,
  observed_at: Int,
) -> #(Observation(Revision), World) {
  case core.lookup(world, resource) {
    Unknown(_) -> {
      let world_prime =
        core.world(
          list.append(core.world_entries(world), [
            #(resource, core.revision(0)),
          ]),
        )
      #(
        Observation(
          core.revision(0),
          Basis(resource, core.revision(0)),
          observed_at,
        ),
        world_prime,
      )
    }
    Found(revision) -> #(
      Observation(revision, Basis(resource, revision), observed_at),
      world,
    )
  }
}

pub type TrackReq {
  TrackReq(path: NormalizedPath, world: World, observed_at: Int)
}

pub type Tracked {
  Tracked(observation: Observation(Revision), world: World)
}

/// Register the path as an owned resource and return its observation. An
/// already-tracked path yields an observation of its current revision
/// without changing the world.
pub fn track(
  req: TrackReq,
) -> Outcome(Tracked, boundary_r, boundary_c, boundary_b) {
  let resource = path_resource(req.path)
  let #(observation, world) =
    register_resource(req.world, resource, req.observed_at)
  Applied(Tracked(observation, world))
}

pub type ReadReq {
  ReadReq(
    path: NormalizedPath,
    world: World,
    digests: Digests,
    state: ExternalFileState,
    observed_at: Int,
  )
}

pub type Read {
  Read(observation: Observation(FileSnapshot), world: World, digests: Digests)
}

pub type ReadFailure {
  ReadFailure(path: NormalizedPath)
}

/// Read the path from the external state. A declared read failure yields a
/// boundary failure, checked first. Otherwise an absent path is rejected as
/// an unknown resource; a present path yields an observation of its
/// snapshot, and its digest is recorded.
pub fn read(
  req: ReadReq,
) -> Outcome(Read, UnknownResource, boundary_c, ReadFailure) {
  case list.contains(req.state.read_failures, req.path) {
    True -> BoundaryFailed(ReadFailure(req.path))
    False -> {
      let resource = path_resource(req.path)
      case state_lookup(req.state, req.path) {
        Error(_) -> Rejected(UnknownResource(resource))
        Ok(record) -> {
          let digests = set_digest(req.digests, resource, record.digest)
          let #(observation, world) =
            register_resource(req.world, resource, req.observed_at)
          let snapshot = FileSnapshot(req.path, record.bytes, record.digest)
          Applied(Read(
            Observation(snapshot, observation.basis, observation.observed_at),
            world,
            digests,
          ))
        }
      }
    }
  }
}

pub type ReplaceReq {
  ReplaceReq(
    command: Command(ReplaceContents),
    path: NormalizedPath,
    world: World,
    digests: Digests,
    state: ExternalFileState,
    observed_at: Int,
  )
}

pub type Replaced {
  Replaced(
    observation: Observation(FileSnapshot),
    world: World,
    digests: Digests,
    state: ExternalFileState,
  )
}

pub type ResourcePathMismatch {
  ResourcePathMismatch(resource: ResourceId, path: NormalizedPath)
}

pub type ReplaceRejection {
  RejectMismatch(ResourcePathMismatch)
  RejectUnknownResource(UnknownResource)
  RejectUnobservedContents(UnobservedContents)
}

pub type ReplaceConflict {
  ConflictStaleBasis(StaleBasis)
  ConflictExternalMutation(ExternalMutation)
}

pub type WriteFailure {
  WriteFailure(path: NormalizedPath)
}

/// Apply the command as a compare-and-replace atomic write. The command's
/// resource must name the same file as the path; a mismatch is rejected
/// before any digest, world, or file observation is made. A resource with
/// no recorded digest is rejected before the world or file is touched. A
/// revision mismatch is a stale-basis conflict; a digest mismatch after
/// that is an external-mutation conflict. Only once every layer passes is
/// the external state updated as a single total step.
pub fn replace(
  req: ReplaceReq,
) -> Outcome(Replaced, ReplaceRejection, ReplaceConflict, WriteFailure) {
  let resource = req.command.basis.resource
  case resource != path_resource(req.path) {
    True -> Rejected(RejectMismatch(ResourcePathMismatch(resource, req.path)))
    False ->
      case lookup_digest(req.digests, resource) {
        DigestUnobserved(u) -> Rejected(RejectUnobservedContents(u))
        DigestFound(expected) ->
          case core.apply(req.world, req.command) {
            Rejected(u) -> Rejected(RejectUnknownResource(u))
            Conflicted(k) -> Conflicted(ConflictStaleBasis(k))
            BoundaryFailed(_) ->
              Rejected(RejectUnknownResource(UnknownResource(resource)))
            Applied(#(_, world_after_basis)) ->
              case state_lookup(req.state, req.path) {
                Error(_) ->
                  Rejected(RejectUnknownResource(UnknownResource(resource)))
                Ok(current) ->
                  case current.digest != expected {
                    True ->
                      Conflicted(
                        ConflictExternalMutation(ExternalMutation(
                          expected,
                          current.digest,
                        )),
                      )
                    False ->
                      case list.contains(req.state.write_failures, req.path) {
                        True -> BoundaryFailed(WriteFailure(req.path))
                        False -> {
                          let new_contents = req.command.intent.new_contents
                          let new_digest = req.command.intent.new_digest
                          let record = FileRecord(new_digest, new_contents)
                          let state_prime =
                            set_file(req.state, req.path, record)
                          let digests_prime =
                            set_digest(req.digests, resource, new_digest)
                          let #(observation, world_prime) =
                            register_resource(
                              world_after_basis,
                              resource,
                              req.observed_at,
                            )
                          Applied(Replaced(
                            Observation(
                              FileSnapshot(req.path, new_contents, new_digest),
                              observation.basis,
                              observation.observed_at,
                            ),
                            world_prime,
                            digests_prime,
                            state_prime,
                          ))
                        }
                      }
                  }
              }
          }
      }
  }
}
