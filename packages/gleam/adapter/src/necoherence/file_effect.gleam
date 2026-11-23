// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
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
/// Files keep their order in numbered slots and an index finds the first slot
/// of each path. A file list that repeats a path holds every entry, and a
/// replacement rewrites each match.
pub opaque type ExternalFileState {
  ExternalFileState(
    slots: Dict(Int, #(NormalizedPath, FileRecord)),
    count: Int,
    first_positions: Dict(NormalizedPath, Int),
    distinct: Bool,
    read_failures: List(NormalizedPath),
    write_failures: List(NormalizedPath),
  )
}

pub fn external_file_state_of(
  files: List(#(NormalizedPath, FileRecord)),
  read_failures: List(NormalizedPath),
  write_failures: List(NormalizedPath),
) -> ExternalFileState {
  let start = Indexed(dict.new(), 0, dict.new(), True)
  let Indexed(slots:, count:, first_positions:, distinct:) =
    list.fold(files, start, indexed_append)
  ExternalFileState(
    slots:,
    count:,
    first_positions:,
    distinct:,
    read_failures:,
    write_failures:,
  )
}

pub fn state_files(
  state: ExternalFileState,
) -> List(#(NormalizedPath, FileRecord)) {
  collect_slots(state.slots, state.count - 1, [])
}

pub fn state_read_failures(state: ExternalFileState) -> List(NormalizedPath) {
  state.read_failures
}

pub fn state_write_failures(state: ExternalFileState) -> List(NormalizedPath) {
  state.write_failures
}

type Indexed(key, value) {
  Indexed(
    slots: Dict(Int, #(key, value)),
    count: Int,
    first_positions: Dict(key, Int),
    distinct: Bool,
  )
}

fn indexed_append(
  indexed: Indexed(key, value),
  entry: #(key, value),
) -> Indexed(key, value) {
  let Indexed(slots:, count:, first_positions:, distinct:) = indexed
  let present = dict.has_key(first_positions, entry.0)
  Indexed(
    slots: dict.insert(slots, count, entry),
    count: count + 1,
    first_positions: case present {
      True -> first_positions
      False -> dict.insert(first_positions, entry.0, count)
    },
    distinct: distinct && !present,
  )
}

fn collect_slots(
  slots: Dict(Int, #(key, value)),
  position: Int,
  accumulated: List(#(key, value)),
) -> List(#(key, value)) {
  case position < 0 {
    True -> accumulated
    False ->
      case dict.get(slots, position) {
        Ok(entry) -> collect_slots(slots, position - 1, [entry, ..accumulated])
        Error(Nil) -> collect_slots(slots, position - 1, accumulated)
      }
  }
}

fn replace_matches(
  slots: Dict(Int, #(key, value)),
  position: Int,
  key: key,
  value: value,
) -> Dict(Int, #(key, value)) {
  case position < 0 {
    True -> slots
    False ->
      case dict.get(slots, position) {
        Ok(#(existing, _)) if existing == key ->
          replace_matches(
            dict.insert(slots, position, #(key, value)),
            position - 1,
            key,
            value,
          )
        _ -> replace_matches(slots, position - 1, key, value)
      }
  }
}

fn indexed_set(
  indexed: Indexed(key, value),
  key: key,
  value: value,
) -> Indexed(key, value) {
  let Indexed(slots:, count:, first_positions:, distinct:) = indexed
  case dict.get(first_positions, key) {
    Error(Nil) -> indexed_append(indexed, #(key, value))
    Ok(position) ->
      case distinct {
        True ->
          Indexed(..indexed, slots: dict.insert(slots, position, #(key, value)))
        False ->
          Indexed(
            slots: replace_matches(slots, count - 1, key, value),
            count:,
            first_positions:,
            distinct:,
          )
      }
  }
}

fn state_lookup(
  state: ExternalFileState,
  path: NormalizedPath,
) -> Result(FileRecord, Nil) {
  case dict.get(state.first_positions, path) {
    Error(Nil) -> Error(Nil)
    Ok(position) ->
      case dict.get(state.slots, position) {
        Ok(#(_, record)) -> Ok(record)
        Error(Nil) -> Error(Nil)
      }
  }
}

fn set_file(
  state: ExternalFileState,
  path: NormalizedPath,
  record: FileRecord,
) -> ExternalFileState {
  let Indexed(slots:, count:, first_positions:, distinct:) =
    indexed_set(
      Indexed(state.slots, state.count, state.first_positions, state.distinct),
      path,
      record,
    )
  ExternalFileState(..state, slots:, count:, first_positions:, distinct:)
}

/// Map from resource identity to the digest of its last observed contents,
/// held with the same indexed layout as the file state.
pub opaque type Digests {
  Digests(
    slots: Dict(Int, #(ResourceId, ContentDigest)),
    count: Int,
    first_positions: Dict(ResourceId, Int),
    distinct: Bool,
  )
}

pub fn digests_of(entries: List(#(ResourceId, ContentDigest))) -> Digests {
  let start = Indexed(dict.new(), 0, dict.new(), True)
  let Indexed(slots:, count:, first_positions:, distinct:) =
    list.fold(entries, start, indexed_append)
  Digests(slots:, count:, first_positions:, distinct:)
}

pub fn digests_entries(digests: Digests) -> List(#(ResourceId, ContentDigest)) {
  collect_slots(digests.slots, digests.count - 1, [])
}

pub type UnobservedContents {
  UnobservedContents(resource: ResourceId)
}

pub type DigestLookup {
  DigestFound(ContentDigest)
  DigestUnobserved(UnobservedContents)
}

pub fn lookup_digest(digests: Digests, resource: ResourceId) -> DigestLookup {
  case dict.get(digests.first_positions, resource) {
    Error(Nil) -> DigestUnobserved(UnobservedContents(resource))
    Ok(position) ->
      case dict.get(digests.slots, position) {
        Ok(#(_, digest)) -> DigestFound(digest)
        Error(Nil) -> DigestUnobserved(UnobservedContents(resource))
      }
  }
}

pub fn set_digest(
  digests: Digests,
  resource: ResourceId,
  digest: ContentDigest,
) -> Digests {
  let Indexed(slots:, count:, first_positions:, distinct:) =
    indexed_set(
      Indexed(
        digests.slots,
        digests.count,
        digests.first_positions,
        digests.distinct,
      ),
      resource,
      digest,
    )
  Digests(slots:, count:, first_positions:, distinct:)
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
        core.world_appended(world, #(resource, core.revision(0)))
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
