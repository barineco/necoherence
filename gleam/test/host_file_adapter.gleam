// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/string
import necoherence/core
import necoherence/file_effect as files

@external(erlang, "host_file_adapter_ffi", "temporary_directory")
fn temporary_directory() -> String

@external(erlang, "host_file_adapter_ffi", "write")
fn host_write(path: String, contents: String) -> Nil

@external(erlang, "host_file_adapter_ffi", "read")
fn host_read(path: String) -> Result(String, Nil)

@external(erlang, "host_file_adapter_ffi", "atomic_replace")
fn atomic_replace(path: String, contents: String) -> Result(Nil, Nil)

@external(erlang, "host_file_adapter_ffi", "remove")
fn remove(path: String) -> Nil

fn path(root: String, raw: List(String)) -> files.NormalizedPath {
  files.normalize_path(True, list.append(string.split(root, "/"), raw))
}

fn host_path(path: files.NormalizedPath) -> String {
  "/" <> string.join(path.segments, "/")
}

fn bytes(_text: String) -> List(Int) {
  [1]
}

fn digest(text: String) -> files.ContentDigest {
  files.ContentDigest(text)
}

fn snapshot(path: files.NormalizedPath) -> files.ExternalFileState {
  case host_read(host_path(path)) {
    Ok(contents) ->
      files.ExternalFileState(
        [#(path, files.FileRecord(digest(contents), bytes(contents)))],
        [],
        [],
      )
    Error(_) -> files.ExternalFileState([], [], [])
  }
}

pub fn host_file_adapter_test() {
  let root = temporary_directory()
  let target = root <> "/nested/item"
  host_write(target, "before")
  let relative = path(root, ["nested", "item"])
  let absolute = path("", string.split(target, "/"))
  let unnormalised = path(root, ["nested", "ignored", "..", "item"])
  assert relative == absolute
  assert relative == unnormalised
  let coverage = ["paths"]
  let assert core.Applied(tracked) =
    files.track(files.TrackReq(relative, core.world([]), 0))
  let assert core.Applied(observed) =
    files.read(files.ReadReq(
      relative,
      tracked.world,
      files.Digests([]),
      snapshot(relative),
      1,
    ))
  let coverage = ["registered", ..coverage]
  let missing = path(root, ["missing"])
  assert files.read(files.ReadReq(
      missing,
      core.world([]),
      files.Digests([]),
      snapshot(missing),
      2,
    ))
    == core.Rejected(
      core.UnknownResource(core.resource("file", host_path(missing))),
    )
  let coverage = ["missing", ..coverage]
  let assert core.Applied(only_tracked) =
    files.track(files.TrackReq(relative, core.world([]), 3))
  let unobserved =
    files.replace(files.ReplaceReq(
      core.Command(
        files.ReplaceContents(bytes("x"), digest("x")),
        only_tracked.observation.basis,
      ),
      relative,
      only_tracked.world,
      files.Digests([]),
      snapshot(relative),
      4,
    ))
  case unobserved {
    core.Rejected(files.RejectUnobservedContents(_)) -> Nil
    _ -> panic as "unobserved"
  }
  let coverage = ["unobserved", ..coverage]
  host_write(target, "changed")
  let changed =
    files.replace(files.ReplaceReq(
      core.Command(
        files.ReplaceContents(bytes("new"), digest("new")),
        observed.observation.basis,
      ),
      relative,
      observed.world,
      observed.digests,
      snapshot(relative),
      5,
    ))
  case changed {
    core.Conflicted(files.ConflictExternalMutation(_)) -> Nil
    _ -> panic as "mutation"
  }
  let coverage = ["changed", ..coverage]
  let assert core.Applied(current) =
    files.read(files.ReadReq(
      relative,
      observed.world,
      observed.digests,
      snapshot(relative),
      6,
    ))
  let blocked =
    files.replace(files.ReplaceReq(
      core.Command(
        files.ReplaceContents(bytes("blocked"), digest("blocked")),
        current.observation.basis,
      ),
      relative,
      current.world,
      current.digests,
      files.ExternalFileState(snapshot(relative).files, [], [relative]),
      7,
    ))
  case blocked {
    core.BoundaryFailed(files.WriteFailure(_)) -> Nil
    _ -> panic as "write failure"
  }
  let coverage = ["write-failure", ..coverage]
  let assert core.Applied(replaced) =
    files.replace(files.ReplaceReq(
      core.Command(
        files.ReplaceContents(bytes("atomic"), digest("atomic")),
        current.observation.basis,
      ),
      relative,
      current.world,
      current.digests,
      snapshot(relative),
      8,
    ))
  let assert Ok(_) = atomic_replace(target, "atomic")
  assert host_read(target) == Ok("atomic")
  assert replaced.observation.payload.contents == bytes("atomic")
  let coverage = ["atomic", ..coverage]
  assert list.length(coverage) == 7
  remove(root)
}
