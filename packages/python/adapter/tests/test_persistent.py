# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from hypothesis import given, strategies as st

from necoherence.persistent import (
    PersistentBitSet,
    PersistentMap,
    PersistentVector,
    bit_set_of,
    empty_bit_set,
    empty_map,
    map_of,
    vector_of,
)


class Colliding:
    def __init__(self, bucket: int, identity: int) -> None:
        self.bucket = bucket
        self.identity = identity

    def __hash__(self) -> int:
        return self.bucket

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Colliding) and self.identity == other.identity


def _bucket(identity: int) -> int:
    return identity % 4 if identity % 2 else identity * 7919


@given(st.lists(st.integers(), max_size=70), st.lists(st.tuples(st.booleans(), st.integers()), max_size=70))
def test_vector_follows_a_list_and_keeps_every_earlier_version(
    initial: list[int], updates: list[tuple[bool, int]]
) -> None:
    current: PersistentVector[int] = vector_of(initial)
    model = list(initial)
    history = [(current, list(model))]
    for append, value in updates:
        if append or not model:
            current = current.append(value)
            model.append(value)
        else:
            position = value % len(model)
            current = current.set(position, value)
            model[position] = value
        history.append((current, list(model)))
    for version, expected in history:
        assert list(version) == expected
        assert len(version) == len(expected)
        assert [version.get(position) for position in range(len(expected))] == expected


def test_vector_grows_past_the_depth_of_a_small_vector() -> None:
    current: PersistentVector[int] = vector_of(())
    for value in range(33 * 1024 + 5):
        current = current.append(value)
    assert list(current) == list(range(33 * 1024 + 5))
    assert current.get(33 * 1024) == 33 * 1024


@given(st.lists(st.tuples(st.integers(0, 3), st.integers(0, 40), st.integers()), max_size=120))
def test_map_follows_a_dict_under_hash_collisions_and_keeps_every_earlier_version(
    updates: list[tuple[int, int, int]]
) -> None:
    current: PersistentMap[Colliding, int] = empty_map()
    model: dict[int, int] = {}
    history: list[tuple[PersistentMap[Colliding, int], dict[int, int]]] = [(current, {})]
    for _, identity, value in updates:
        key = Colliding(_bucket(identity), identity)
        current = current.set(key, value)
        model[identity] = value
        history.append((current, dict(model)))
    for version, expected in history:
        assert len(version) == len(expected)
        assert {key.identity: value for key, value in version} == expected
        for identity, value in expected.items():
            probe = Colliding(_bucket(identity), identity)
            assert version.find(probe) == value
            assert version.contains(probe)


@given(st.dictionaries(st.integers(0, 10**6), st.integers(), max_size=200))
def test_bulk_map_equals_repeated_insertion(pairs: dict[int, int]) -> None:
    bulk = map_of(pairs.items())
    inserted: PersistentMap[int, int] = empty_map()
    for key, value in pairs.items():
        inserted = inserted.set(key, value)
    assert dict(bulk) == dict(inserted) == pairs
    assert len(bulk) == len(pairs)


@given(st.lists(st.tuples(st.booleans(), st.integers(0, 70_000)), max_size=150))
def test_bit_set_reports_its_least_member_and_keeps_every_earlier_version(
    updates: list[tuple[bool, int]]
) -> None:
    current: PersistentBitSet = empty_bit_set()
    model: set[int] = set()
    history: list[tuple[PersistentBitSet, set[int]]] = [(current, set())]
    for add, position in updates:
        if add:
            current = current.add(position)
            model.add(position)
        else:
            current = current.discard(position)
            model.discard(position)
        history.append((current, set(model)))
    for version, expected in history:
        assert list(version) == sorted(expected)
        assert version.least() == (min(expected) if expected else None)


@given(st.sets(st.integers(0, 70_000), max_size=200))
def test_bulk_bit_set_equals_repeated_insertion(positions: set[int]) -> None:
    inserted = empty_bit_set()
    for position in positions:
        inserted = inserted.add(position)
    assert list(bit_set_of(positions)) == list(inserted) == sorted(positions)
