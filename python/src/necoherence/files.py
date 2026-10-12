# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""File effect as a pure state transition over an external file world.

``ExternalFileState`` stands for the whole of what a real filesystem adapter
would touch: present files and the paths where an adapter has declared a
read or write to fail (its own boundary observation, not something this
module computes). Content digests are likewise values fed in from outside:
this module never hashes bytes, it only compares digests it is given.

``track``, ``read``, and ``replace`` are pure functions over the values
supplied: no filesystem access happens here. A caller (or the stdin
inspection adapter) supplies ``ExternalFileState`` as ordinary input data
and threads the returned state forward. Mirrors ``FileEffect.lean``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Never

from necoherence.call import Immediate, immediate_of
from necoherence.core import (
    Applied,
    Basis,
    BoundaryFailed,
    Command,
    Conflicted,
    Observation,
    Outcome,
    Rejected,
    ResourceId,
    Revision,
    StaleBasis,
    UnknownResource,
    World,
    bump,
    lookup,
)

_FILE_KIND = "file"


@dataclass(frozen=True, slots=True)
class NormalizedPath:
    """A path already reduced to root flag and non-special segments."""

    root: bool
    segments: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ContentDigest:
    """A content digest as computed by an external touchpoint (never by this module)."""

    value: str


def _is_special_segment(segment: str) -> bool:
    """Segments that normalization always removes: empty, ``.``, and ``..``
    with nothing to pop."""
    return segment == "" or segment == "." or segment == ".."


def _normalize_segments(raw: tuple[str, ...]) -> tuple[str, ...]:
    """Fold raw segments into a normalized list: empty segments and ``.`` are
    dropped, ``..`` pops the most recently appended segment (or is dropped
    outright when there is nothing to pop), and every other segment is
    appended in order."""
    acc: list[str] = []
    for segment in raw:
        if segment == "" or segment == ".":
            continue
        if segment == "..":
            if acc:
                acc.pop()
            continue
        acc.append(segment)
    return tuple(acc)


def normalize_path(root: bool, raw: tuple[str, ...]) -> NormalizedPath:
    """Normalize a raw root flag and segment list into a ``NormalizedPath``."""
    return NormalizedPath(root=root, segments=_normalize_segments(raw))


def _path_string(path: NormalizedPath) -> str:
    """Deterministic string rendering of a normalized path, used as a resource name."""
    body = "/".join(path.segments)
    return "/" + body if path.root else body


def _path_resource(path: NormalizedPath) -> ResourceId:
    """Identity a normalized path determines. Equal paths always yield an
    equal ``ResourceId``."""
    return ResourceId(kind=_FILE_KIND, name=_path_string(path))


@dataclass(frozen=True, slots=True)
class FileRecord:
    """A file's contents and the digest an external touchpoint computed for them."""

    digest: ContentDigest
    bytes: tuple[int, ...]


@dataclass(frozen=True, slots=True)
class ExternalFileState:
    """The external world ``track``, ``read``, and ``replace`` observe and
    update.

    ``files`` holds present paths and their records; ``read_failures`` and
    ``write_failures`` are paths an adapter has declared unreadable or
    unwritable for the next call, standing for a boundary failure such as a
    permission or I/O error without modeling any particular exception type.
    """

    files: tuple[tuple[NormalizedPath, FileRecord], ...]
    read_failures: tuple[NormalizedPath, ...]
    write_failures: tuple[NormalizedPath, ...]


def _state_lookup(state: ExternalFileState, path: NormalizedPath) -> FileRecord | None:
    """Current record at ``path``, or ``None`` when the path is absent."""
    for entry_path, record in state.files:
        if entry_path == path:
            return record
    return None


def _set_file(state: ExternalFileState, path: NormalizedPath, record: FileRecord) -> ExternalFileState:
    """Replace ``path``'s record, adding it when absent. A single total step:
    never partial."""
    if any(entry_path == path for entry_path, _ in state.files):
        files = tuple((entry_path, record if entry_path == path else entry_record)
                       for entry_path, entry_record in state.files)
    else:
        files = state.files + ((path, record),)
    return ExternalFileState(files=files, read_failures=state.read_failures, write_failures=state.write_failures)


@dataclass(frozen=True, slots=True)
class Digests:
    """Immutable map from resource identity to the digest of its last observed contents."""

    entries: tuple[tuple[ResourceId, ContentDigest], ...]


@dataclass(frozen=True, slots=True)
class UnobservedContents:
    """Rejection payload when a resource has no recorded content digest."""

    resource: ResourceId


type DigestLookup = ContentDigest | UnobservedContents


def lookup_digest(digests: Digests, resource: ResourceId) -> DigestLookup:
    for bound_resource, digest in digests.entries:
        if bound_resource == resource:
            return digest
    return UnobservedContents(resource)


def set_digest(digests: Digests, resource: ResourceId, digest: ContentDigest) -> Digests:
    if any(bound_resource == resource for bound_resource, _ in digests.entries):
        entries = tuple(
            (bound_resource, digest if bound_resource == resource else bound_digest)
            for bound_resource, bound_digest in digests.entries
        )
    else:
        entries = digests.entries + ((resource, digest),)
    return Digests(entries)


@dataclass(frozen=True, slots=True)
class FileSnapshot:
    """Contents of a file as observed at some basis."""

    path: NormalizedPath
    contents: tuple[int, ...]
    digest: ContentDigest


@dataclass(frozen=True, slots=True)
class ExternalMutation:
    """Conflict payload when a file's digest no longer matches what was observed."""

    expected: ContentDigest
    actual: ContentDigest


@dataclass(frozen=True, slots=True)
class ReplaceContents:
    """Command intent that requests a file's contents be replaced."""

    new_contents: tuple[int, ...]
    new_digest: ContentDigest


def _register_resource(
    world: World, resource: ResourceId, observed_at: int
) -> tuple[Observation[Revision], World]:
    """Register ``resource``'s current revision in ``world``, starting it at
    0 when absent."""
    current = lookup(world, resource)
    if isinstance(current, UnknownResource):
        revision = Revision(0)
        world = World(world.entries + ((resource, revision),))
    else:
        revision = current
    observation = Observation(payload=revision, basis=Basis(resource, revision), observed_at=observed_at)
    return observation, world


@dataclass(frozen=True, slots=True)
class TrackReq:
    """Request to register a path as an owned resource without reading it."""

    path: NormalizedPath
    world: World
    observed_at: int


@dataclass(frozen=True, slots=True)
class Tracked:
    """Product of a successful ``track``."""

    observation: Observation[Revision]
    world: World


type TrackResult = Outcome[Tracked, Never, Never, Never]


def _track(req: TrackReq) -> TrackResult:
    """Register ``req.path`` as an owned resource and return its
    observation. Never fails: registering a revision touches no file
    contents."""
    resource = _path_resource(req.path)
    observation, world = _register_resource(req.world, resource, req.observed_at)
    return Applied(Tracked(observation=observation, world=world))


track: Immediate[TrackReq, TrackResult] = immediate_of(
    "necoherence.files.track", ("path", "world", "observed_at"), _track
)


@dataclass(frozen=True, slots=True)
class ReadReq:
    """Request to read a path's contents from the external state."""

    path: NormalizedPath
    world: World
    digests: Digests
    state: ExternalFileState
    observed_at: int


@dataclass(frozen=True, slots=True)
class Read:
    """Product of a successful ``read``."""

    observation: Observation[FileSnapshot]
    world: World
    digests: Digests


@dataclass(frozen=True, slots=True)
class ReadFailure:
    """Closed failure when the external state has declared ``path``'s read
    unreadable."""

    path: NormalizedPath


type ReadResult = Outcome[Read, UnknownResource, Never, ReadFailure]


def _read(req: ReadReq) -> ReadResult:
    """Read ``req.path`` from ``req.state``. A declared read failure yields
    ``BoundaryFailed``, checked first. Otherwise an absent path yields
    ``Rejected(UnknownResource(...))``; a present path yields ``Applied``
    with a basis-carrying observation of its ``FileSnapshot``, and its
    digest is recorded into ``req.digests``."""
    if req.path in req.state.read_failures:
        return BoundaryFailed(ReadFailure(req.path))
    resource = _path_resource(req.path)
    record = _state_lookup(req.state, req.path)
    if record is None:
        return Rejected(UnknownResource(resource))
    digests = set_digest(req.digests, resource, record.digest)
    observation, world = _register_resource(req.world, resource, req.observed_at)
    snapshot = FileSnapshot(path=req.path, contents=record.bytes, digest=record.digest)
    return Applied(
        Read(
            observation=Observation(
                payload=snapshot, basis=observation.basis, observed_at=observation.observed_at
            ),
            world=world,
            digests=digests,
        )
    )


read: Immediate[ReadReq, ReadResult] = immediate_of(
    "necoherence.files.read", ("path", "world", "digests", "state", "observed_at"), _read
)


@dataclass(frozen=True, slots=True)
class ReplaceReq:
    """Request to replace a file's contents as a compare-and-replace atomic
    write. ``command``'s basis is the whole of what authorizes the write.
    ``path`` must name the same file ``command.basis.resource`` identifies;
    ``replace`` checks this closed, before touching digests, world, or file."""

    command: Command[ReplaceContents]
    path: NormalizedPath
    world: World
    digests: Digests
    state: ExternalFileState
    observed_at: int


@dataclass(frozen=True, slots=True)
class Replaced:
    """Product of a successful ``replace``."""

    observation: Observation[FileSnapshot]
    world: World
    digests: Digests
    state: ExternalFileState


@dataclass(frozen=True, slots=True)
class ResourcePathMismatch:
    """Rejection payload when ``command.basis.resource`` does not name ``path``."""

    resource: ResourceId
    path: NormalizedPath


type ReplaceRejection = ResourcePathMismatch | UnknownResource | UnobservedContents
type ReplaceConflict = StaleBasis | ExternalMutation


@dataclass(frozen=True, slots=True)
class WriteFailure:
    """Closed failure when the external state has declared ``path``'s write
    unwritable."""

    path: NormalizedPath


type ReplaceResult = Outcome[Replaced, ReplaceRejection, ReplaceConflict, WriteFailure]


def _replace(req: ReplaceReq) -> ReplaceResult:
    """Apply ``req.command`` as a compare-and-replace atomic write.

    ``req.command.basis.resource`` must name the same file as ``req.path``;
    a mismatch is rejected with ``ResourcePathMismatch`` before any digest,
    world, or file observation is made. A resource with no recorded digest
    is rejected with ``UnobservedContents``. A revision mismatch against
    ``req.world`` is the first staleness layer, ``Conflicted(StaleBasis(...))``.
    An absent path is ``Rejected(UnknownResource(...))``. With the file
    present, a digest mismatch against the last recorded digest is the
    second staleness layer, ``Conflicted(ExternalMutation(...))``. A
    declared write failure is ``BoundaryFailed``. Only once every layer
    passes is ``req.state`` updated, a single total step.
    """
    resource = req.command.basis.resource
    if resource != _path_resource(req.path):
        return Rejected(ResourcePathMismatch(resource=resource, path=req.path))

    expected_digest = lookup_digest(req.digests, resource)
    if isinstance(expected_digest, UnobservedContents):
        return Rejected(expected_digest)

    current = lookup(req.world, resource)
    if isinstance(current, UnknownResource):
        return Rejected(current)
    if current != req.command.basis.revision:
        return Conflicted(StaleBasis(expected=req.command.basis.revision, actual=current))
    world_after_basis = bump(req.world, resource)

    current_record = _state_lookup(req.state, req.path)
    if current_record is None:
        return Rejected(UnknownResource(resource))

    if current_record.digest != expected_digest:
        return Conflicted(ExternalMutation(expected=expected_digest, actual=current_record.digest))

    if req.path in req.state.write_failures:
        return BoundaryFailed(WriteFailure(req.path))

    new_contents = req.command.intent.new_contents
    new_digest = req.command.intent.new_digest
    record = FileRecord(digest=new_digest, bytes=new_contents)
    state = _set_file(req.state, req.path, record)
    digests = set_digest(req.digests, resource, new_digest)
    observation, world = _register_resource(world_after_basis, resource, req.observed_at)
    snapshot = FileSnapshot(path=req.path, contents=new_contents, digest=new_digest)
    return Applied(
        Replaced(
            observation=Observation(
                payload=snapshot, basis=observation.basis, observed_at=observation.observed_at
            ),
            world=world,
            digests=digests,
            state=state,
        )
    )


replace: Immediate[ReplaceReq, ReplaceResult] = immediate_of(
    "necoherence.files.replace",
    ("command", "path", "world", "digests", "state", "observed_at"),
    _replace,
)
