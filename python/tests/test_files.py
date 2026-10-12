# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Tests for file effect as a pure state transition over an external file world.

``track``, ``read``, and ``replace`` are plain ``Immediate`` declarations
called through ``io``, with no filesystem access: an ``ExternalFileState``
value stands in for whatever a real adapter would touch, and each call
returns the next version of whatever it touched for the caller to thread
into the next request.
"""

from __future__ import annotations

import hashlib

from hypothesis import given, strategies as st

from necoherence.call import CallFailed, CallOk, ProjectionFailed, Request, io
from necoherence.core import (
    Applied,
    BoundaryFailed,
    Command,
    Conflicted,
    Rejected,
    Revision,
    StaleBasis,
    UnknownResource,
    World,
    command_of,
)
from necoherence.files import (
    ContentDigest,
    Digests,
    ExternalFileState,
    ExternalMutation,
    FileRecord,
    NormalizedPath,
    ReadFailure,
    ReadReq,
    ReplaceContents,
    ReplaceReq,
    ResourcePathMismatch,
    TrackReq,
    UnobservedContents,
    WriteFailure,
    normalize_path,
    read,
    replace,
    track,
)


def _digest(contents: bytes) -> ContentDigest:
    return ContentDigest(hashlib.sha256(contents).hexdigest())


def _path(*segments: str) -> NormalizedPath:
    return normalize_path(True, tuple(segments))


def _fresh_world() -> World:
    return World(())


def _state(*entries: tuple[NormalizedPath, bytes]) -> ExternalFileState:
    return ExternalFileState(
        files=tuple((p, FileRecord(digest=_digest(b), bytes=tuple(b))) for p, b in entries),
        read_failures=(),
        write_failures=(),
    )


def _call_result(result: object) -> object:
    """Unwrap a ``CallResult`` to the inner ``Outcome`` or ``ProjectionFailed`` value."""
    if isinstance(result, CallOk):
        return result.value
    assert isinstance(result, CallFailed)
    return result.failure


def _track(path: NormalizedPath, world: World, at: int) -> object:
    req = TrackReq(path=path, world=world, observed_at=at)
    return _call_result(io(track, Request(payload=req, fields=track.required)))


def _read(path: NormalizedPath, world: World, digests: Digests, state: ExternalFileState, at: int) -> object:
    req = ReadReq(path=path, world=world, digests=digests, state=state, observed_at=at)
    return _call_result(io(read, Request(payload=req, fields=read.required)))


def _replace(
    command: Command[ReplaceContents],
    path: NormalizedPath,
    world: World,
    digests: Digests,
    state: ExternalFileState,
    at: int,
) -> object:
    req = ReplaceReq(
        command=command, path=path, world=world, digests=digests, state=state, observed_at=at
    )
    return _call_result(io(replace, Request(payload=req, fields=replace.required)))


# --- Path normalization -----------------------------------------------------


def test_normalize_path_drops_empty_and_dot_segments() -> None:
    assert normalize_path(True, ("a", "", ".", "b")) == NormalizedPath(True, ("a", "b"))


def test_normalize_path_pop_dot_dot() -> None:
    assert normalize_path(True, ("a", "b", "..")) == NormalizedPath(True, ("a",))


def test_normalize_path_dot_dot_with_nothing_to_pop_is_dropped() -> None:
    assert normalize_path(True, ("..", "a")) == NormalizedPath(True, ("a",))


def test_normalize_path_is_idempotent() -> None:
    raw = ("a", "..", "b", ".", "c", "..", "..")
    once = normalize_path(True, raw)
    twice = normalize_path(True, once.segments)
    assert once == twice


# --- Roundtrip ---------------------------------------------------------


def test_roundtrip_track_read_replace_reread() -> None:
    path = _path("a.txt")
    world = _fresh_world()
    state = _state((path, b"before"))

    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world

    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)
    observation = got.value.observation
    world, digests = got.value.world, got.value.digests

    command = command_of(
        observation, ReplaceContents(new_contents=tuple(b"after"), new_digest=_digest(b"after"))
    )
    replaced = _replace(command, path, world, digests, state, 2)
    assert isinstance(replaced, Applied)
    assert replaced.value.observation.payload.contents == tuple(b"after")
    assert replaced.value.observation.payload.digest == _digest(b"after")
    world, digests, state = replaced.value.world, replaced.value.digests, replaced.value.state

    reread = _read(path, world, digests, state, 3)
    assert isinstance(reread, Applied)
    assert reread.value.observation.payload.contents == tuple(b"after")


# --- Two-layer staleness --------------------------------------------------


def test_stale_basis_layer_alone_is_checked_without_touching_the_file() -> None:
    path = _path("b.txt")
    world = _fresh_world()
    state = _state((path, b"x"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)
    world, digests = got.value.world, got.value.digests
    resource = got.value.observation.basis.resource

    from necoherence.core import Basis

    fabricated = Command(
        intent=ReplaceContents(new_contents=tuple(b"y"), new_digest=_digest(b"y")),
        basis=Basis(resource, Revision(7)),
    )
    outcome = _replace(fabricated, path, world, digests, state, 2)
    assert outcome == Conflicted(StaleBasis(expected=Revision(7), actual=Revision(0)))


def test_digest_layer_alone_fires_when_revision_still_matches() -> None:
    path = _path("c.txt")
    world = _fresh_world()
    state = _state((path, b"v0"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)
    observation = got.value.observation
    world, digests = got.value.world, got.value.digests

    externally_changed = _state((path, b"externally-changed"))

    command = command_of(
        observation, ReplaceContents(new_contents=tuple(b"v1"), new_digest=_digest(b"v1"))
    )
    outcome = _replace(command, path, world, digests, externally_changed, 2)
    assert outcome == Conflicted(
        ExternalMutation(expected=_digest(b"v0"), actual=_digest(b"externally-changed"))
    )


def test_stale_basis_is_reported_before_the_digest_layer_when_both_conflict() -> None:
    path = _path("d.txt")
    world = _fresh_world()
    state = _state((path, b"v0"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    first = _read(path, world, Digests(()), state, 1)
    assert isinstance(first, Applied)
    old_observation = first.value.observation
    world, digests = first.value.world, first.value.digests

    bump_cmd = command_of(
        old_observation, ReplaceContents(new_contents=tuple(b"v1"), new_digest=_digest(b"v1"))
    )
    bumped = _replace(bump_cmd, path, world, digests, state, 2)
    assert isinstance(bumped, Applied)

    state_after_external = _state((path, b"v2-external"))

    stale = command_of(
        old_observation, ReplaceContents(new_contents=tuple(b"v3"), new_digest=_digest(b"v3"))
    )
    outcome = _replace(
        stale, path, bumped.value.world, bumped.value.digests, state_after_external, 3
    )
    assert outcome == Conflicted(StaleBasis(expected=Revision(0), actual=Revision(1)))


# --- Basis retention -----------------------------------------------------


def test_command_retains_the_observations_basis() -> None:
    path = _path("e.txt")
    world = _fresh_world()
    state = _state((path, b"x"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)
    command = command_of(
        got.value.observation, ReplaceContents(new_contents=tuple(b"y"), new_digest=_digest(b"y"))
    )
    assert command.basis == got.value.observation.basis


def test_track_only_replace_is_rejected_for_unobserved_contents() -> None:
    path = _path("f.txt")
    world = _fresh_world()
    state = _state((path, b"content"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    command = command_of(
        tracked.value.observation,
        ReplaceContents(new_contents=tuple(b"new"), new_digest=_digest(b"new")),
    )
    outcome = _replace(command, path, tracked.value.world, Digests(()), state, 1)
    assert outcome == Rejected(UnobservedContents(tracked.value.observation.basis.resource))


# --- Closed outcomes -------------------------------------------------------


def test_track_read_replace_outcomes_are_exactly_the_closed_variants() -> None:
    path = _path("g.txt")
    world = _fresh_world()
    state = _state((path, b"x"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)
    missing = _read(_path("absent.txt"), world, Digests(()), state, 2)

    for outcome in (tracked, got, missing):
        match outcome:
            case Applied():
                pass
            case Rejected():
                pass
            case Conflicted():
                pass
            case BoundaryFailed():
                pass
            case _:
                raise AssertionError(f"non-Outcome value: {outcome!r}")
    assert isinstance(missing, Rejected)


# --- Aliased paths resolve to the same resource ----------------------------


def test_aliased_paths_resolve_to_the_same_resource() -> None:
    real = _path("aliased.txt")
    dotted = normalize_path(True, ("sub", "..", "aliased.txt"))
    state = _state((real, b"content"))

    tracked_real = _track(real, _fresh_world(), 0)
    assert isinstance(tracked_real, Applied)
    tracked_dotted = _track(dotted, tracked_real.value.world, 1)
    assert isinstance(tracked_dotted, Applied)

    assert (
        tracked_real.value.observation.basis.resource
        == tracked_dotted.value.observation.basis.resource
    )


# --- Resource identity is a pure function of the path, not a counter -----


def test_same_path_always_yields_the_same_resource_identity() -> None:
    path = _path("same.txt")
    first = _track(path, _fresh_world(), 0)
    second = _track(path, _fresh_world(), 0)
    assert isinstance(first, Applied)
    assert isinstance(second, Applied)
    assert first.value.observation.basis.resource == second.value.observation.basis.resource


def test_different_paths_always_yield_different_resource_identities() -> None:
    path_a = _path("one.txt")
    path_b = _path("two.txt")

    a = _track(path_a, _fresh_world(), 0)
    b = _track(path_b, _fresh_world(), 0)
    assert isinstance(a, Applied)
    assert isinstance(b, Applied)
    assert a.value.observation.basis.resource != b.value.observation.basis.resource


def test_file_resource_identity_carries_the_file_kind() -> None:
    path = _path("kind.txt")
    tracked = _track(path, _fresh_world(), 0)
    assert isinstance(tracked, Applied)
    assert tracked.value.observation.basis.resource.kind == "file"


def test_command_from_one_independent_series_combined_with_anothers_world_is_rejected() -> None:
    path_a = _path("series_a.txt")
    path_b = _path("series_b.txt")
    state_a = _state((path_a, b"same-content"))
    state_b = _state((path_b, b"same-content"))

    tracked_a = _track(path_a, _fresh_world(), 0)
    assert isinstance(tracked_a, Applied)
    read_a = _read(path_a, tracked_a.value.world, Digests(()), state_a, 1)
    assert isinstance(read_a, Applied)

    tracked_b = _track(path_b, _fresh_world(), 0)
    assert isinstance(tracked_b, Applied)
    read_b = _read(path_b, tracked_b.value.world, Digests(()), state_b, 1)
    assert isinstance(read_b, Applied)

    resource_a = read_a.value.observation.basis.resource
    resource_b = read_b.value.observation.basis.resource
    assert resource_a != resource_b

    command_from_a = command_of(
        read_a.value.observation,
        ReplaceContents(new_contents=tuple(b"hijacked"), new_digest=_digest(b"hijacked")),
    )
    outcome = _replace(command_from_a, path_a, read_b.value.world, read_b.value.digests, state_b, 2)
    assert outcome == Rejected(UnobservedContents(resource_a))


# --- Declared boundary failures ---------------------------------------------


def test_read_declared_unreadable_is_boundary_failed() -> None:
    path = _path("locked.txt")
    state = ExternalFileState(
        files=((path, FileRecord(digest=_digest(b"secret"), bytes=tuple(b"secret"))),),
        read_failures=(path,),
        write_failures=(),
    )
    outcome = _read(path, _fresh_world(), Digests(()), state, 0)
    assert outcome == BoundaryFailed(ReadFailure(path))


def test_read_missing_file_is_rejected_not_a_boundary_failure() -> None:
    path = _path("missing.txt")
    outcome = _read(path, _fresh_world(), Digests(()), _state(), 0)
    assert isinstance(outcome, Rejected)
    assert isinstance(outcome.reason, UnknownResource)


def test_replace_resource_path_mismatch_is_rejected() -> None:
    path = _path("a.txt")
    other_path = _path("b.txt")
    world = _fresh_world()
    state = _state((path, b"x"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)

    command = command_of(
        got.value.observation, ReplaceContents(new_contents=tuple(b"y"), new_digest=_digest(b"y"))
    )
    outcome = _replace(command, other_path, got.value.world, got.value.digests, state, 2)
    assert outcome == Rejected(
        ResourcePathMismatch(resource=command.basis.resource, path=other_path)
    )


def test_replace_declared_unwritable_is_boundary_failed() -> None:
    path = _path("h.txt")
    world = _fresh_world()
    state = _state((path, b"stable"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)

    write_blocked_state = ExternalFileState(
        files=state.files, read_failures=(), write_failures=(path,)
    )
    command = command_of(
        got.value.observation,
        ReplaceContents(new_contents=tuple(b"never"), new_digest=_digest(b"never")),
    )
    outcome = _replace(command, path, got.value.world, got.value.digests, write_blocked_state, 2)
    assert outcome == BoundaryFailed(WriteFailure(path))


def test_atomic_write_result_is_exactly_new_contents_on_success() -> None:
    path = _path("j.txt")
    world = _fresh_world()
    state = _state((path, b"old-content"))
    tracked = _track(path, world, 0)
    assert isinstance(tracked, Applied)
    world = tracked.value.world
    got = _read(path, world, Digests(()), state, 1)
    assert isinstance(got, Applied)

    command = command_of(
        got.value.observation,
        ReplaceContents(new_contents=tuple(b"new-content"), new_digest=_digest(b"new-content")),
    )
    outcome = _replace(command, path, got.value.world, got.value.digests, state, 2)
    assert isinstance(outcome, Applied)
    assert outcome.value.state.files == ((path, FileRecord(_digest(b"new-content"), tuple(b"new-content"))),)


# --- Caller carries values: a stale World or Digests degrades to Conflicted -


def test_a_world_from_before_a_later_replace_is_rejected_as_stale_basis() -> None:
    path = _path("k.txt")
    state = _state((path, b"v0"))
    tracked = _track(path, _fresh_world(), 0)
    assert isinstance(tracked, Applied)
    world_before = tracked.value.world
    first = _read(path, world_before, Digests(()), state, 1)
    assert isinstance(first, Applied)
    old_observation = first.value.observation
    digests = first.value.digests

    bump_cmd = command_of(
        old_observation, ReplaceContents(new_contents=tuple(b"v1"), new_digest=_digest(b"v1"))
    )
    bumped = _replace(bump_cmd, path, world_before, digests, state, 2)
    assert isinstance(bumped, Applied)

    again = command_of(
        old_observation, ReplaceContents(new_contents=tuple(b"v2"), new_digest=_digest(b"v2"))
    )
    outcome = _replace(again, path, bumped.value.world, bumped.value.digests, bumped.value.state, 3)
    assert outcome == Conflicted(StaleBasis(expected=Revision(0), actual=Revision(1)))


def test_stale_digests_entry_is_rejected_as_external_mutation() -> None:
    path = _path("l.txt")
    state = _state((path, b"v0"))
    tracked = _track(path, _fresh_world(), 0)
    assert isinstance(tracked, Applied)
    first = _read(path, tracked.value.world, Digests(()), state, 1)
    assert isinstance(first, Applied)
    stale_digests = first.value.digests

    replaced_elsewhere = _replace(
        command_of(
            first.value.observation,
            ReplaceContents(new_contents=tuple(b"v1"), new_digest=_digest(b"v1")),
        ),
        path,
        first.value.world,
        first.value.digests,
        state,
        2,
    )
    assert isinstance(replaced_elsewhere, Applied)

    outcome = _replace(
        command_of(
            replaced_elsewhere.value.observation,
            ReplaceContents(new_contents=tuple(b"v2"), new_digest=_digest(b"v2")),
        ),
        path,
        replaced_elsewhere.value.world,
        stale_digests,
        replaced_elsewhere.value.state,
        3,
    )
    assert outcome == Conflicted(ExternalMutation(expected=_digest(b"v0"), actual=_digest(b"v1")))


# --- Missing declared fields degrade to CallFailed, never raise ------------


def test_missing_request_field_is_call_failed() -> None:
    req = TrackReq(path=_path("m.txt"), world=World(()), observed_at=0)
    result = io(track, Request(payload=req, fields=("path", "observed_at")))
    assert isinstance(result, CallFailed)
    assert result.failure == ProjectionFailed(declaration="necoherence.files.track", fields=("world",))


# --- Property: normalization never leaves a special segment ---------------


@given(
    st.lists(
        st.sampled_from(["", ".", "..", "a", "b", "c"]),
        max_size=8,
    )
)
def test_normalize_segments_never_leaves_a_special_segment(raw: list[str]) -> None:
    normalized = normalize_path(True, tuple(raw))
    assert all(segment not in ("", ".", "..") for segment in normalized.segments)


# --- Host filesystem adapter -------------------------------------------------
# This deliberately lives in the test boundary. Production File effect remains
# a pure (ExternalFileState, Input) -> (ExternalFileState', Result) API.

from pathlib import Path
from tempfile import TemporaryDirectory


class _HostFileAdapter:
    def __init__(self, root: Path, fail_writes: bool = False) -> None:
        self.root = root
        self.fail_writes = fail_writes

    def path(self, raw: str) -> NormalizedPath:
        host = Path(raw)
        if not host.is_absolute():
            host = self.root / host
        return normalize_path(True, tuple(host.parts[1:]))

    def host_path(self, path: NormalizedPath) -> Path:
        return Path("/").joinpath(*path.segments)

    def state(self, path: NormalizedPath) -> ExternalFileState:
        try:
            contents = self.host_path(path).read_bytes()
        except FileNotFoundError:
            return ExternalFileState((), (), ())
        except OSError:
            return ExternalFileState((), (path,), ())
        return ExternalFileState(((path, FileRecord(_digest(contents), tuple(contents))),), (), ())

    def read(self, path: NormalizedPath, world: World, digests: Digests, at: int) -> object:
        return _read(path, world, digests, self.state(path), at)

    def replace(self, command: Command[ReplaceContents], path: NormalizedPath, world: World, digests: Digests, at: int) -> object:
        state = self.state(path)
        if self.fail_writes:
            state = ExternalFileState(state.files, state.read_failures, (path,))
        outcome = _replace(command, path, world, digests, state, at)
        if isinstance(outcome, Applied):
            target = self.host_path(path)
            temporary = target.with_name(target.name + ".necoherence-tmp")
            try:
                temporary.write_bytes(bytes(outcome.value.state.files[0][1].bytes))
                temporary.replace(target)
            except OSError:
                return BoundaryFailed(WriteFailure(path))
        return outcome


@given(st.binary(min_size=1, max_size=32))
def test_host_file_adapter_exercises_all_file_effect_states(payload: bytes) -> None:
    coverage: set[str] = set()
    with TemporaryDirectory() as directory:
        root = Path(directory)
        adapter = _HostFileAdapter(root)
        target = root / "nested" / "item.bin"
        target.parent.mkdir()
        target.write_bytes(payload)
        relative = adapter.path("nested/item.bin")
        absolute = adapter.path(str(target))
        unnormalized = adapter.path("nested/ignored/../item.bin")
        assert relative == absolute == unnormalized
        coverage.add("relative-absolute-normalized")

        tracked = _track(relative, World(()), 0)
        assert isinstance(tracked, Applied)
        read_result = adapter.read(unnormalized, tracked.value.world, Digests(()), 1)
        assert isinstance(read_result, Applied)
        coverage.add("registered-read")

        missing = adapter.read(adapter.path("missing.bin"), World(()), Digests(()), 2)
        assert isinstance(missing, Rejected) and isinstance(missing.reason, UnknownResource)
        coverage.add("missing")

        unobserved = _track(relative, World(()), 3)
        assert isinstance(unobserved, Applied)
        denied = adapter.replace(
            command_of(unobserved.value.observation, ReplaceContents(tuple(b"x"), _digest(b"x"))),
            relative, unobserved.value.world, Digests(()), 4,
        )
        assert isinstance(denied, Rejected) and isinstance(denied.reason, UnobservedContents)
        coverage.add("unobserved")

        target.write_bytes(payload + b"changed")
        changed = adapter.replace(
            command_of(read_result.value.observation, ReplaceContents(tuple(b"new"), _digest(b"new"))),
            relative, read_result.value.world, read_result.value.digests, 5,
        )
        assert isinstance(changed, Conflicted) and isinstance(changed.conflict, ExternalMutation)
        coverage.add("changed-after-observation")

        current = adapter.read(relative, read_result.value.world, read_result.value.digests, 6)
        assert isinstance(current, Applied)
        failed = _HostFileAdapter(root, fail_writes=True).replace(
            command_of(current.value.observation, ReplaceContents(tuple(b"blocked"), _digest(b"blocked"))),
            relative, current.value.world, current.value.digests, 7,
        )
        assert isinstance(failed, BoundaryFailed) and isinstance(failed.failure, WriteFailure)
        coverage.add("write-failure")

        replaced = adapter.replace(
            command_of(current.value.observation, ReplaceContents(tuple(b"atomic"), _digest(b"atomic"))),
            relative, current.value.world, current.value.digests, 8,
        )
        assert isinstance(replaced, Applied)
        assert target.read_bytes() == b"atomic"
        assert not target.with_name(target.name + ".necoherence-tmp").exists()
        coverage.add("atomic-replace")
    assert coverage == {
        "relative-absolute-normalized", "registered-read", "missing", "unobserved",
        "changed-after-observation", "write-failure", "atomic-replace",
    }
