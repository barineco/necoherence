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

from collections.abc import Iterable
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
    _world_appended,
    bump,
    lookup,
)
from necoherence.persistent import PersistentMap, PersistentVector, map_of, vector_of

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
    return segment == "" or segment == "." or segment == ".."


def _normalize_segments(raw: tuple[str, ...]) -> tuple[str, ...]:
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
    body = "/".join(path.segments)
    return "/" + body if path.root else body


def _path_resource(path: NormalizedPath) -> ResourceId:
    return ResourceId(kind=_FILE_KIND, name=_path_string(path))


@dataclass(frozen=True, slots=True)
class FileRecord:
    """A file's contents and the digest an external touchpoint computed for them."""

    digest: ContentDigest
    bytes: tuple[int, ...]


class ExternalFileState:
    """The external world ``track``, ``read``, and ``replace`` observe and
    update.

    ``files`` holds present paths and their records; ``read_failures`` and
    ``write_failures`` are paths an adapter has declared unreadable or
    unwritable for the next call, standing for a boundary failure such as a
    permission or I/O error without modeling any particular exception type.

    The fields are private. ``external_file_state_of`` is the only construction
    path, and ``external_file_state_files``, ``external_file_state_read_failures``
    and ``external_file_state_write_failures`` read the parts back. Operations
    return a new value that shares every unchanged file with the state they
    were given.
    """

    __slots__ = (
        "_files", "_positions", "_read_failure_order", "_write_failure_order", "_read_failures", "_write_failures",
    )

    _files: PersistentVector[tuple[NormalizedPath, FileRecord]]
    _positions: PersistentMap[NormalizedPath, int]
    _read_failure_order: tuple[NormalizedPath, ...]
    _write_failure_order: tuple[NormalizedPath, ...]
    _read_failures: frozenset[NormalizedPath]
    _write_failures: frozenset[NormalizedPath]

    def __init__(self, *_arguments: object, **_keywords: object) -> None:
        raise TypeError("ExternalFileState is constructed with external_file_state_of")

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("ExternalFileState is immutable")

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, ExternalFileState)
            and external_file_state_files(self) == external_file_state_files(other)
            and self._read_failure_order == other._read_failure_order
            and self._write_failure_order == other._write_failure_order
        )

    def __hash__(self) -> int:
        return hash((external_file_state_files(self), self._read_failure_order, self._write_failure_order))

    def __repr__(self) -> str:
        return (
            f"ExternalFileState(files={external_file_state_files(self)!r}, "
            f"read_failures={self._read_failure_order!r}, write_failures={self._write_failure_order!r})"
        )


def _file_state_from(
    files: PersistentVector[tuple[NormalizedPath, FileRecord]],
    positions: PersistentMap[NormalizedPath, int],
    read_failures: tuple[NormalizedPath, ...],
    write_failures: tuple[NormalizedPath, ...],
    read_failed: frozenset[NormalizedPath],
    write_failed: frozenset[NormalizedPath],
) -> ExternalFileState:
    state = object.__new__(ExternalFileState)
    object.__setattr__(state, "_files", files)
    object.__setattr__(state, "_positions", positions)
    object.__setattr__(state, "_read_failure_order", read_failures)
    object.__setattr__(state, "_write_failure_order", write_failures)
    object.__setattr__(state, "_read_failures", read_failed)
    object.__setattr__(state, "_write_failures", write_failed)
    return state


def external_file_state_of(
    files: Iterable[tuple[NormalizedPath, FileRecord]],
    read_failures: Iterable[NormalizedPath],
    write_failures: Iterable[NormalizedPath],
) -> ExternalFileState:
    """Build a state from ordered files, indexing each path's first position."""
    ordered = tuple(files)
    first: dict[NormalizedPath, int] = {}
    for position, (path, _record) in enumerate(ordered):
        first.setdefault(path, position)
    reads = tuple(read_failures)
    writes = tuple(write_failures)
    return _file_state_from(vector_of(ordered), map_of(first.items()), reads, writes, frozenset(reads), frozenset(writes))


def external_file_state_files(state: ExternalFileState) -> tuple[tuple[NormalizedPath, FileRecord], ...]:
    """Return the ordered files of a state, read-only."""
    return tuple(state._files)


def external_file_state_read_failures(state: ExternalFileState) -> tuple[NormalizedPath, ...]:
    """Return the paths declared unreadable."""
    return state._read_failure_order


def external_file_state_write_failures(state: ExternalFileState) -> tuple[NormalizedPath, ...]:
    """Return the paths declared unwritable."""
    return state._write_failure_order


def _state_lookup(state: ExternalFileState, path: NormalizedPath) -> FileRecord | None:
    position = state._positions.find(path)
    if position is None:
        return None
    return state._files.get(position)[1]


def _set_file(state: ExternalFileState, path: NormalizedPath, record: FileRecord) -> ExternalFileState:
    position = state._positions.find(path)
    if position is None:
        files = state._files.append((path, record))
        positions = state._positions.set(path, len(state._files))
    elif len(state._positions) == len(state._files):
        files = state._files.set(position, (path, record))
        positions = state._positions
    else:
        files = vector_of(
            (entry_path, record if entry_path == path else entry_record)
            for entry_path, entry_record in state._files
        )
        positions = state._positions
    return _file_state_from(
        files, positions, state._read_failure_order, state._write_failure_order,
        state._read_failures, state._write_failures,
    )


class Digests:
    """Immutable map from resource identity to the digest of its last observed contents.

    The fields are private. ``digests_of`` is the only construction path, and
    ``digests_entries`` reads the entries back in order. Operations return a
    new value that shares every unchanged entry with the digests they were
    given.
    """

    __slots__ = ("_entries", "_positions")

    _entries: PersistentVector[tuple[ResourceId, ContentDigest]]
    _positions: PersistentMap[ResourceId, int]

    def __init__(self, *_arguments: object, **_keywords: object) -> None:
        raise TypeError("Digests is constructed with digests_of")

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("Digests is immutable")

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Digests) and digests_entries(self) == digests_entries(other)

    def __hash__(self) -> int:
        return hash(digests_entries(self))

    def __repr__(self) -> str:
        return f"Digests(entries={digests_entries(self)!r})"


def _digests_from(
    entries: PersistentVector[tuple[ResourceId, ContentDigest]], positions: PersistentMap[ResourceId, int]
) -> Digests:
    digests = object.__new__(Digests)
    object.__setattr__(digests, "_entries", entries)
    object.__setattr__(digests, "_positions", positions)
    return digests


def digests_of(entries: Iterable[tuple[ResourceId, ContentDigest]]) -> Digests:
    """Build digests from ordered entries, indexing each resource's first position."""
    ordered = tuple(entries)
    first: dict[ResourceId, int] = {}
    for position, (resource, _digest) in enumerate(ordered):
        first.setdefault(resource, position)
    return _digests_from(vector_of(ordered), map_of(first.items()))


def digests_entries(digests: Digests) -> tuple[tuple[ResourceId, ContentDigest], ...]:
    """Return the ordered entries of digests, read-only."""
    return tuple(digests._entries)


@dataclass(frozen=True, slots=True)
class UnobservedContents:
    """Rejection payload when a resource has no recorded content digest."""

    resource: ResourceId


type DigestLookup = ContentDigest | UnobservedContents


def lookup_digest(digests: Digests, resource: ResourceId) -> DigestLookup:
    position = digests._positions.find(resource)
    if position is None:
        return UnobservedContents(resource)
    return digests._entries.get(position)[1]


def set_digest(digests: Digests, resource: ResourceId, digest: ContentDigest) -> Digests:
    position = digests._positions.find(resource)
    if position is None:
        return _digests_from(
            digests._entries.append((resource, digest)), digests._positions.set(resource, len(digests._entries))
        )
    if len(digests._positions) == len(digests._entries):
        return _digests_from(digests._entries.set(position, (resource, digest)), digests._positions)
    return _digests_from(
        vector_of(
            (bound_resource, digest if bound_resource == resource else bound_digest)
            for bound_resource, bound_digest in digests._entries
        ),
        digests._positions,
    )


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
    current = lookup(world, resource)
    if isinstance(current, UnknownResource):
        revision = Revision(0)
        world = _world_appended(world, resource, revision)
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
    if req.path in req.state._read_failures:
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

    if req.path in req.state._write_failures:
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
