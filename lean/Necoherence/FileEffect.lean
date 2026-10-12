-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
File effect as a pure state transition over an external file world.

`ExternalFileState` stands for the whole of what a real filesystem adapter
would touch: present files and the paths where an adapter has declared a
read or write to fail (its own boundary observation, not something this
module computes). Content digests are likewise values fed in from outside:
this module never hashes bytes and only compares digests supplied by an
external adapter.

`track`, `read`, and `replace` are defined as `(ExternalFileState, Request) ->
(ExternalFileState, Outcome)` with no filesystem access: normalization,
identity, staleness, and atomic replacement are total functions over the
values supplied.
-/

import Necoherence.Core

namespace Necoherence

/-- A path already reduced to root flag and non-special segments. -/
structure NormalizedPath where
  root : Bool
  segments : List String
  deriving DecidableEq, Repr

/-- A content digest as computed by an external touchpoint (never by this module). -/
structure ContentDigest where
  value : String
  deriving DecidableEq, Repr

/-- Segments that normalization always removes: empty, `.`, and `..` with nothing to pop. -/
def isSpecialSegment (segment : String) : Bool :=
  segment == "" || segment == "." || segment == ".."

/--
Fold raw segments into a normalized list: empty segments and `.` are
dropped, `..` pops the most recently appended segment, the one nearest the
end of the accumulator (or is dropped outright when there is nothing to
pop), and every other segment is appended in order.
-/
def normalizeSegments (raw : List String) : List String :=
  raw.foldl
    (fun acc segment =>
      if segment == "" || segment == "." then acc
      else if segment == ".." then acc.dropLast
      else acc ++ [segment])
    []

/-- Normalize a raw root flag and segment list into a `NormalizedPath`. -/
def normalizePath (root : Bool) (raw : List String) : NormalizedPath :=
  ⟨root, normalizeSegments raw⟩

/-- Deterministic string rendering of a normalized path, used as a resource name. -/
def pathString (path : NormalizedPath) : String :=
  let body := String.intercalate "/" path.segments
  if path.root then "/" ++ body else body

def _FILE_KIND : String := "file"

/-- Identity a normalized path determines. Equal paths always yield an equal `ResourceId`. -/
def pathResource (path : NormalizedPath) : ResourceId :=
  ⟨_FILE_KIND, pathString path⟩

/-- A file's contents and the digest an external touchpoint computed for them. -/
structure FileRecord where
  digest : ContentDigest
  bytes : List UInt8
  deriving DecidableEq, Repr

/--
The external world `track`, `read`, and `replace` observe and update.
`files` holds present paths and their records; `readFailures` and
`writeFailures` are paths an adapter has declared unreadable or
unwritable for the next call, standing for a boundary failure such as a
permission or I/O error without modeling any particular exception type.
-/
structure ExternalFileState where
  files : List (NormalizedPath × FileRecord)
  readFailures : List NormalizedPath
  writeFailures : List NormalizedPath
  deriving DecidableEq, Repr

namespace ExternalFileState

/-- Current record at `path`, or `none` when the path is absent. -/
def lookup (state : ExternalFileState) (path : NormalizedPath) : Option FileRecord :=
  (state.files.find? (fun entry => entry.1 == path)).map Prod.snd

/-- Replace `path`'s record, adding it when absent. A single total step: never partial. -/
def setFile (state : ExternalFileState) (path : NormalizedPath) (record : FileRecord) :
    ExternalFileState :=
  { state with
    files :=
      if state.files.any (fun entry => entry.1 == path) then
        state.files.map (fun entry => if entry.1 == path then (path, record) else entry)
      else
        state.files ++ [(path, record)] }

end ExternalFileState

/-- Immutable map from resource identity to the digest of its last observed contents. -/
structure Digests where
  entries : List (ResourceId × ContentDigest)
  deriving DecidableEq, Repr

/-- Rejection payload when a resource has no recorded content digest. -/
structure UnobservedContents where
  resource : ResourceId
  deriving DecidableEq, Repr

/-- Closed sum of a held digest and an unobserved-contents payload. -/
inductive DigestLookup where
  | found : ContentDigest → DigestLookup
  | unobserved : UnobservedContents → DigestLookup
  deriving DecidableEq, Repr

def lookupDigest (digests : Digests) (resource : ResourceId) : DigestLookup :=
  match digests.entries.find? (fun entry => entry.1 == resource) with
  | some (_, digest) => .found digest
  | none => .unobserved ⟨resource⟩

def setDigest (digests : Digests) (resource : ResourceId) (digest : ContentDigest) : Digests :=
  if digests.entries.any (fun entry => entry.1 == resource) then
    ⟨digests.entries.map (fun entry => if entry.1 == resource then (resource, digest) else entry)⟩
  else
    ⟨digests.entries ++ [(resource, digest)]⟩

/-- Contents of a file as observed at some basis. -/
structure FileSnapshot where
  path : NormalizedPath
  contents : List UInt8
  digest : ContentDigest
  deriving DecidableEq, Repr

/--
Conflict payload when a file's digest no longer matches what was observed.
`expected` is the digest recorded at the last observation, `actual` is the
digest `replace` finds at the path when it is applied.
-/
structure ExternalMutation where
  expected : ContentDigest
  actual : ContentDigest
  deriving DecidableEq, Repr

/-- Command intent that requests a file's contents be replaced. -/
structure ReplaceContents where
  newContents : List UInt8
  newDigest : ContentDigest
  deriving DecidableEq, Repr

/-- Register `resource`'s current revision in `world`, starting it at 0 when absent. -/
def registerResource (world : World) (resource : ResourceId) (observedAt : Nat) :
    Observation Revision × World :=
  match World.lookup world resource with
  | .unknown _ =>
    let world' : World := List.append world [(resource, ⟨0⟩)]
    (⟨⟨0⟩, ⟨resource, ⟨0⟩⟩, observedAt⟩, world')
  | .found revision =>
    (⟨revision, ⟨resource, revision⟩, observedAt⟩, world)

/-- Request to register a path as an owned resource without reading it. -/
structure TrackReq where
  path : NormalizedPath
  world : World
  observedAt : Nat

/-- Product of a successful `track`. -/
structure Tracked where
  observation : Observation Revision
  world : World

/-- `track` never fails: registering a revision touches no file contents. -/
def TrackResult := Outcome Tracked Empty Empty Empty

/--
Register `req.path` as an owned resource and return its observation. An
already-tracked path yields an observation of its current revision without
changing `req.world`.
-/
def track (req : TrackReq) : TrackResult :=
  let resource := pathResource req.path
  let (observation, world) := registerResource req.world resource req.observedAt
  .applied ⟨observation, world⟩

/-- Request to read a path's contents from the external state. -/
structure ReadReq where
  path : NormalizedPath
  world : World
  digests : Digests
  state : ExternalFileState
  observedAt : Nat

/-- Product of a successful `read`. -/
structure Read where
  observation : Observation FileSnapshot
  world : World
  digests : Digests

/-- Closed failure when the external state has declared `path`'s read unreadable. -/
structure ReadFailure where
  path : NormalizedPath
  deriving DecidableEq, Repr

def ReadResult := Outcome Read UnknownResource Empty ReadFailure

/--
Read `req.path` from `req.state`. A declared read failure yields
`boundaryFailed`, checked first since it represents the external read call
itself failing. Otherwise an absent path yields `rejected (UnknownResource
...)`; a present path yields `applied` with a basis-carrying observation of
its `FileSnapshot`, and its digest is recorded into `req.digests`.
-/
def read (req : ReadReq) : ReadResult :=
  if req.state.readFailures.contains req.path then
    .boundaryFailed ⟨req.path⟩
  else
    let resource := pathResource req.path
    match req.state.lookup req.path with
    | none => .rejected ⟨resource⟩
    | some record =>
      let digests := setDigest req.digests resource record.digest
      let (observation, world) := registerResource req.world resource req.observedAt
      let snapshot : FileSnapshot := ⟨req.path, record.bytes, record.digest⟩
      .applied ⟨⟨snapshot, observation.basis, observation.observedAt⟩, world, digests⟩

/--
Request to replace a file's contents as a compare-and-replace atomic write.
`command`'s basis is the whole of what authorizes the write: it can only
have been built by `commandOf` from a real prior observation. `path` must
name the same file `command.basis.resource` identifies; `replace` checks
this closed, before touching digests, world, or file.
-/
structure ReplaceReq where
  command : Command ReplaceContents
  path : NormalizedPath
  world : World
  digests : Digests
  state : ExternalFileState
  observedAt : Nat

/-- Product of a successful `replace`. -/
structure Replaced where
  observation : Observation FileSnapshot
  world : World
  digests : Digests
  state : ExternalFileState

/-- Rejection payload when `command.basis.resource` does not name `path`. -/
structure ResourcePathMismatch where
  resource : ResourceId
  path : NormalizedPath
  deriving DecidableEq, Repr

/--
Closed rejection: `path` and `command.basis.resource` name different
resources, the resource is absent, or its contents were never observed.
-/
inductive ReplaceRejection where
  | resourcePathMismatch : ResourcePathMismatch → ReplaceRejection
  | unknownResource : UnknownResource → ReplaceRejection
  | unobservedContents : UnobservedContents → ReplaceRejection
  deriving DecidableEq, Repr

/-- Closed conflict: the world revision is stale, or the file's digest was mutated externally. -/
inductive ReplaceConflict where
  | staleBasis : StaleBasis → ReplaceConflict
  | externalMutation : ExternalMutation → ReplaceConflict
  deriving DecidableEq, Repr

/-- Closed failure when the external state has declared `path`'s write unwritable. -/
structure WriteFailure where
  path : NormalizedPath
  deriving DecidableEq, Repr

def ReplaceResult := Outcome Replaced ReplaceRejection ReplaceConflict WriteFailure

/--
Apply `req.command` as a compare-and-replace atomic write.

`req.command.basis.resource` must name the same file as `req.path`; a
mismatch is rejected with `ResourcePathMismatch` before any digest, world,
or file observation is made. A resource with no recorded digest (`track`
only, never `read`) is rejected with `UnobservedContents` before the world
or the file is touched. A revision mismatch against `req.world` is the
first staleness layer, `conflicted (StaleBasis ...)`, checked without
touching the file. An absent path is `rejected (UnknownResource ...)`.
With the file present, a digest mismatch against the last recorded digest
is the second staleness layer, `conflicted (ExternalMutation ...)`; this
comparison is value-based, so contents changed and then returned to the
observed bytes are indistinguishable from contents never touched. A
declared write failure is `boundaryFailed`. Only once every layer passes
is `req.state` updated, by `ExternalFileState.setFile`, a single total
step: the external state after `replace` is either wholly the prior
record or wholly the new one, never a mixture of the two.
-/
def replace (req : ReplaceReq) : ReplaceResult :=
  let resource := req.command.basis.resource
  if resource != pathResource req.path then
    .rejected (.resourcePathMismatch ⟨resource, req.path⟩)
  else
  match lookupDigest req.digests resource with
  | .unobserved u => .rejected (.unobservedContents u)
  | .found expected =>
    match World.apply req.world req.command with
    | .rejected u => .rejected (.unknownResource u)
    | .conflicted k => .conflicted (.staleBasis k)
    | .boundaryFailed f => Empty.elim f
    | .applied (_, worldAfterBasis) =>
      match req.state.lookup req.path with
      | none => .rejected (.unknownResource ⟨resource⟩)
      | some current =>
        if current.digest != expected then
          .conflicted (.externalMutation ⟨expected, current.digest⟩)
        else if req.state.writeFailures.contains req.path then
          .boundaryFailed ⟨req.path⟩
        else
          let newContents := req.command.intent.newContents
          let newDigest := req.command.intent.newDigest
          let record : FileRecord := ⟨newDigest, newContents⟩
          let state' := req.state.setFile req.path record
          let digests' := setDigest req.digests resource newDigest
          let (observation, world') := registerResource worldAfterBasis resource req.observedAt
          .applied
            ⟨⟨⟨req.path, newContents, newDigest⟩, observation.basis, observation.observedAt⟩,
              world', digests', state'⟩

/-! ### Theorems -/

/--
Folding onto an accumulator that already carries no special segment never
introduces one, for any raw list. `normalizeSegments_no_special` is the
`acc = []` instance.
-/
theorem foldSegments_no_special (raw : List String) (acc : List String)
    (hacc : ∀ segment ∈ acc, ¬ isSpecialSegment segment) :
    ∀ segment ∈ raw.foldl
      (fun acc segment =>
        if segment == "" || segment == "." then acc
        else if segment == ".." then acc.dropLast
        else acc ++ [segment])
      acc,
      ¬ isSpecialSegment segment := by
  induction raw generalizing acc with
  | nil => simpa using hacc
  | cons head tail ih =>
    rw [List.foldl_cons]
    by_cases hb1 : head == ""
    · simp only [hb1, Bool.true_or, if_true]
      exact ih acc hacc
    · by_cases hb2 : head == "."
      · simp only [hb1, hb2, Bool.false_or, if_true]
        exact ih acc hacc
      · have hb1' : (head == "") = false := by simpa using hb1
        have hb2' : (head == ".") = false := by simpa using hb2
        have hcond : (head == "" || head == ".") = false := by
          simp [hb1', hb2']
        simp only [hcond, Bool.false_eq_true, if_false]
        by_cases hdotdot : head == ".."
        · simp only [hdotdot, if_true]
          have hacc' : ∀ segment ∈ acc.dropLast, ¬ isSpecialSegment segment := by
            intro segment hmem
            exact hacc segment (List.dropLast_subset acc hmem)
          exact ih acc.dropLast hacc'
        · have hdotdot' : (head == "..") = false := by simpa using hdotdot
          simp only [hdotdot', Bool.false_eq_true, if_false]
          have hnotSpecial : ¬ isSpecialSegment head := by
            simp [isSpecialSegment, hb1', hb2', hdotdot']
          have hacc' : ∀ segment ∈ acc ++ [head], ¬ isSpecialSegment segment := by
            intro segment hmem
            rcases List.mem_append.mp hmem with hleft | hright
            · exact hacc segment hleft
            · have : segment = head := List.mem_singleton.mp hright
              rw [this]; exact hnotSpecial
          exact ih (acc ++ [head]) hacc'

/-- No raw segment folded by `normalizeSegments` ever survives into its output. -/
theorem normalizeSegments_no_special (raw : List String) :
    ∀ segment ∈ normalizeSegments raw, ¬ isSpecialSegment segment :=
  foldSegments_no_special raw [] (by simp)

/-- A list with no special segment is left unchanged by `normalizeSegments`. -/
theorem foldSegments_fixed_of_no_special (raw : List String) (acc : List String)
    (hraw : ∀ segment ∈ raw, ¬ isSpecialSegment segment) :
    raw.foldl
      (fun acc segment =>
        if segment == "" || segment == "." then acc
        else if segment == ".." then acc.dropLast
        else acc ++ [segment])
      acc = acc ++ raw := by
  induction raw generalizing acc with
  | nil => simp
  | cons head tail ih =>
    have hheadNoSpecial : ¬ isSpecialSegment head := hraw head List.mem_cons_self
    have htailNoSpecial : ∀ segment ∈ tail, ¬ isSpecialSegment segment :=
      fun segment hmem => hraw segment (List.mem_cons_of_mem head hmem)
    simp only [isSpecialSegment, Bool.or_eq_true, not_or] at hheadNoSpecial
    obtain ⟨⟨hempty, hdot⟩, hdotdot⟩ := hheadNoSpecial
    have hempty' : (head == "") = false := by simpa using hempty
    have hdot' : (head == ".") = false := by simpa using hdot
    have hdotdot' : (head == "..") = false := by simpa using hdotdot
    rw [List.foldl_cons]
    simp only [hempty', hdot', hdotdot', Bool.or_self, Bool.false_eq_true, if_false]
    rw [ih (acc ++ [head]) htailNoSpecial, List.append_assoc, List.singleton_append]

theorem normalizeSegments_fixed_of_no_special (xs : List String)
    (hno : ∀ segment ∈ xs, ¬ isSpecialSegment segment) :
    normalizeSegments xs = xs := by
  have h := foldSegments_fixed_of_no_special xs [] hno
  simpa [normalizeSegments] using h

/-- Normalizing an already-normalized segment list changes nothing: `normalizePath` is idempotent. -/
theorem normalizeSegments_idempotent (raw : List String) :
    normalizeSegments (normalizeSegments raw) = normalizeSegments raw :=
  normalizeSegments_fixed_of_no_special (normalizeSegments raw) (normalizeSegments_no_special raw)

theorem normalizePath_idempotent (root : Bool) (raw : List String) :
    normalizePath root (normalizeSegments raw) = normalizePath root raw := by
  simp [normalizePath, normalizeSegments_idempotent]

/-- `track` always settles: no request causes it to reject, conflict, or boundary-fail. -/
theorem track_always_applied (req : TrackReq) :
    ∃ tracked, track req = .applied tracked := by
  refine ⟨_, rfl⟩

/-- Command resource and requested path disagree: rejected before any digest, world, or file observation. -/
theorem replace_resource_path_mismatch_is_rejected (req : ReplaceReq)
    (hmismatch : req.command.basis.resource ≠ pathResource req.path) :
    replace req = .rejected (.resourcePathMismatch ⟨req.command.basis.resource, req.path⟩) := by
  have hne : req.command.basis.resource != pathResource req.path := by
    simpa [bne, decide_eq_true_eq] using hmismatch
  simp [replace, hne]

/-- A resource with no recorded digest is rejected before the world or file is touched. -/
theorem replace_unobserved_is_rejected (req : ReplaceReq) (u : UnobservedContents)
    (hmatch : req.command.basis.resource = pathResource req.path)
    (hlook : lookupDigest req.digests req.command.basis.resource = .unobserved u) :
    replace req = .rejected (.unobservedContents u) := by
  rw [hmatch] at hlook
  simp [replace, hmatch, hlook]

/-- Layer one of staleness: a revision mismatch against `req.world` conflicts as `StaleBasis`. -/
theorem replace_stale_revision_is_conflicted (req : ReplaceReq)
    (hmatch : req.command.basis.resource = pathResource req.path)
    (expected : ContentDigest)
    (hdigest : lookupDigest req.digests req.command.basis.resource = .found expected)
    (revision : Revision)
    (hlook : World.lookup req.world req.command.basis.resource = .found revision)
    (hne : revision ≠ req.command.basis.revision) :
    replace req = .conflicted (.staleBasis ⟨req.command.basis.revision, revision⟩) := by
  have happly : World.apply req.world req.command = .conflicted ⟨req.command.basis.revision, revision⟩ :=
    stale_conflict req.world req.command revision hlook hne
  rw [hmatch] at hdigest
  simp [replace, hmatch, hdigest, happly]

/-- Layer two of staleness: with the revision matching, a digest mismatch conflicts as `ExternalMutation`. -/
theorem replace_external_mutation_is_conflicted (req : ReplaceReq)
    (hmatch : req.command.basis.resource = pathResource req.path)
    (expected : ContentDigest)
    (hdigest : lookupDigest req.digests req.command.basis.resource = .found expected)
    (worldAfterBasis : World)
    (happly : World.apply req.world req.command =
      .applied (req.command.intent, worldAfterBasis))
    (current : FileRecord)
    (hlookState : req.state.lookup req.path = some current)
    (hmut : current.digest ≠ expected) :
    replace req = .conflicted (.externalMutation ⟨expected, current.digest⟩) := by
  have hne : current.digest != expected := by
    simpa [bne, decide_eq_true_eq] using hmut
  rw [hmatch] at hdigest
  simp [replace, hmatch, hdigest, happly, hlookState, hne]

/-- A path absent from the external state is rejected as `UnknownResource`. -/
theorem replace_missing_path_is_rejected (req : ReplaceReq)
    (hmatch : req.command.basis.resource = pathResource req.path)
    (expected : ContentDigest)
    (hdigest : lookupDigest req.digests req.command.basis.resource = .found expected)
    (worldAfterBasis : World)
    (happly : World.apply req.world req.command =
      .applied (req.command.intent, worldAfterBasis))
    (hlookState : req.state.lookup req.path = none) :
    replace req = .rejected (.unknownResource ⟨req.command.basis.resource⟩) := by
  rw [hmatch] at hdigest
  simp [replace, hmatch, hdigest, happly, hlookState]

/--
Replacing (or appending) a path's entry in a raw list and then finding it
by that path always yields the new record, for any prior entry list.
-/
theorem setFile_lookup_self_aux (entries : List (NormalizedPath × FileRecord))
    (path : NormalizedPath) (record : FileRecord) :
    (if entries.any (fun entry => entry.1 == path) then
        entries.map (fun entry => if entry.1 == path then (path, record) else entry)
      else
        entries ++ [(path, record)]).find? (fun entry => entry.1 == path) = some (path, record) := by
  induction entries with
  | nil => simp
  | cons head tail ih =>
    obtain ⟨entryPath, entryRecord⟩ := head
    rw [List.any_cons]
    by_cases heq : entryPath == path
    · have heq' : entryPath = path := by simpa using heq
      simp [heq']
    · simp only [heq, Bool.false_or]
      by_cases hrest : tail.any (fun entry => entry.1 == path)
      · simp only [hrest, if_true, List.map_cons, List.find?_cons, heq, Bool.false_eq_true,
          if_false]
        simp only [hrest, if_true] at ih
        exact ih
      · have hrest' : tail.any (fun entry => entry.1 == path) = false := Bool.not_eq_true _ ▸ hrest
        simp only [hrest', Bool.false_eq_true, if_false, List.cons_append, List.find?_cons, heq]
        simp only [hrest', Bool.false_eq_true, if_false] at ih
        exact ih

/-- Setting a path's record and then looking it up always yields that record, regardless of prior state. -/
theorem setFile_lookup_self (state : ExternalFileState) (path : NormalizedPath) (record : FileRecord) :
    (state.setFile path record).lookup path = some record := by
  dsimp [ExternalFileState.setFile, ExternalFileState.lookup]
  rw [setFile_lookup_self_aux]
  rfl

/--
Atomic replace: when every layer passes, `replace` settles as `applied` and
the resulting external state's record at `req.path` is exactly the new
bytes and digest the command carried, the only value `setFile` could have
produced.
-/
theorem replace_success_sets_new_record (req : ReplaceReq)
    (hmatch : req.command.basis.resource = pathResource req.path)
    (expected : ContentDigest)
    (hdigest : lookupDigest req.digests req.command.basis.resource = .found expected)
    (worldAfterBasis : World)
    (happly : World.apply req.world req.command =
      .applied (req.command.intent, worldAfterBasis))
    (current : FileRecord)
    (hlookState : req.state.lookup req.path = some current)
    (hsame : current.digest = expected)
    (hnofail : req.state.writeFailures.contains req.path = false) :
    ∃ result, replace req = .applied result ∧
      result.state.lookup req.path =
        some ⟨req.command.intent.newDigest, req.command.intent.newContents⟩ := by
  have hne : (current.digest != expected) = false := by simp [hsame]
  have hnotmem : req.path ∉ req.state.writeFailures := by simpa using hnofail
  rw [hmatch] at hdigest
  have heq : replace req = .applied
      ⟨⟨⟨req.path, req.command.intent.newContents, req.command.intent.newDigest⟩,
          (registerResource worldAfterBasis req.command.basis.resource req.observedAt).1.basis,
          (registerResource worldAfterBasis req.command.basis.resource req.observedAt).1.observedAt⟩,
        (registerResource worldAfterBasis req.command.basis.resource req.observedAt).2,
        setDigest req.digests req.command.basis.resource req.command.intent.newDigest,
        req.state.setFile req.path ⟨req.command.intent.newDigest, req.command.intent.newContents⟩⟩ := by
    simp [replace, hmatch, hdigest, happly, hlookState, hne, hnotmem]
  exact ⟨_, heq, setFile_lookup_self req.state req.path _⟩

theorem replace_write_failure_is_boundary_failed (req : ReplaceReq)
    (hmatch : req.command.basis.resource = pathResource req.path)
    (expected : ContentDigest)
    (hdigest : lookupDigest req.digests req.command.basis.resource = .found expected)
    (worldAfterBasis : World)
    (happly : World.apply req.world req.command =
      .applied (req.command.intent, worldAfterBasis))
    (current : FileRecord)
    (hlookState : req.state.lookup req.path = some current)
    (hsame : current.digest = expected)
    (hfail : req.state.writeFailures.contains req.path = true) :
    replace req = .boundaryFailed ⟨req.path⟩ := by
  have hne : (current.digest != expected) = false := by simp [hsame]
  have hmem : req.path ∈ req.state.writeFailures := by simpa using hfail
  rw [hmatch] at hdigest
  simp [replace, hmatch, hdigest, happly, hlookState, hne, hmem]

/-- `normalizeSegments` pops the segment immediately before a trailing `..`. -/
theorem normalizeSegments_pop_example :
    normalizeSegments ["a", "b", ".."] = ["a"] := by decide

/--
A resource/path mismatch rejects without changing `req.state`, `req.world`,
or `req.digests`: the rejection payload is the only value `replace`
produces, and none of the three carried values is touched.
-/
theorem replace_resource_path_mismatch_state_unchanged (req : ReplaceReq)
    (hmismatch : req.command.basis.resource ≠ pathResource req.path) :
    replace req = .rejected (.resourcePathMismatch ⟨req.command.basis.resource, req.path⟩) ∧
      req.state = req.state ∧ req.world = req.world ∧ req.digests = req.digests :=
  ⟨replace_resource_path_mismatch_is_rejected req hmismatch, rfl, rfl, rfl⟩

#print axioms normalizePath_idempotent
#print axioms normalizeSegments_pop_example
#print axioms track_always_applied
#print axioms replace_resource_path_mismatch_is_rejected
#print axioms replace_resource_path_mismatch_state_unchanged
#print axioms replace_unobserved_is_rejected
#print axioms replace_stale_revision_is_conflicted
#print axioms replace_external_mutation_is_conflicted
#print axioms replace_missing_path_is_rejected
#print axioms replace_success_sets_new_record
#print axioms replace_write_failure_is_boundary_failed

end Necoherence
