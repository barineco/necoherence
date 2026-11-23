# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from collections.abc import Hashable, Iterable, Iterator
from itertools import groupby
from typing import Any, Final

_BITS: Final = 5
_WIDTH: Final = 1 << _BITS
_MASK: Final = _WIDTH - 1
_MIN_SHIFT: Final = 2 * _BITS
_HASH_MASK: Final = (1 << 64) - 1


def _new_path(shift: int, value: Any) -> tuple[Any, ...]:
    if shift == 0:
        return (value,)
    return (_new_path(shift - _BITS, value),)


def _assoc(node: tuple[Any, ...], shift: int, index: int, value: Any) -> tuple[Any, ...]:
    slot = (index >> shift) & _MASK
    if shift == 0:
        return node[:slot] + (value,) + node[slot + 1:]
    return node[:slot] + (_assoc(node[slot], shift - _BITS, index, value),) + node[slot + 1:]


def _push(node: tuple[Any, ...], shift: int, index: int, value: Any) -> tuple[Any, ...]:
    slot = (index >> shift) & _MASK
    if shift == 0:
        return node + (value,)
    if slot < len(node):
        return node[:slot] + (_push(node[slot], shift - _BITS, index, value),) + node[slot + 1:]
    return node + (_new_path(shift - _BITS, value),)


def _walk(node: tuple[Any, ...], shift: int) -> Iterator[Any]:
    if shift == 0:
        yield from node
        return
    for child in node:
        yield from _walk(child, shift - _BITS)


class PersistentVector[T]:
    __slots__ = ("_count", "_shift", "_root")

    _count: int
    _shift: int
    _root: tuple[Any, ...]

    def __init__(self, count: int, shift: int, root: tuple[Any, ...]) -> None:
        object.__setattr__(self, "_count", count)
        object.__setattr__(self, "_shift", shift)
        object.__setattr__(self, "_root", root)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("PersistentVector is immutable")

    def __len__(self) -> int:
        return self._count

    def __iter__(self) -> Iterator[T]:
        return _walk(self._root, self._shift) if self._count else iter(())

    def get(self, index: int) -> T:
        node: Any = self._root
        shift = self._shift
        while shift > 0:
            node = node[(index >> shift) & _MASK]
            shift -= _BITS
        return node[index & _MASK]  # type: ignore[no-any-return]

    def set(self, index: int, value: T) -> PersistentVector[T]:
        return PersistentVector(self._count, self._shift, _assoc(self._root, self._shift, index, value))

    def append(self, value: T) -> PersistentVector[T]:
        index = self._count
        if index == 1 << (self._shift + _BITS):
            return PersistentVector(
                index + 1, self._shift + _BITS, (self._root, _new_path(self._shift, value))
            )
        return PersistentVector(index + 1, self._shift, _push(self._root, self._shift, index, value))


def vector_of[T](values: Iterable[T]) -> PersistentVector[T]:
    items = tuple(values)
    level: list[tuple[Any, ...]] = [items[start:start + _WIDTH] for start in range(0, len(items), _WIDTH)]
    shift = 0
    while shift < _MIN_SHIFT or len(level) > 1:
        level = [tuple(level[start:start + _WIDTH]) for start in range(0, len(level), _WIDTH)]
        shift += _BITS
    return PersistentVector(len(items), shift, level[0] if level else ())


class _Entry:
    __slots__ = ("key_hash", "key", "value")

    def __init__(self, key_hash: int, key: Hashable, value: Any) -> None:
        self.key_hash = key_hash
        self.key = key
        self.value = value


class _Collision:
    __slots__ = ("key_hash", "pairs")

    def __init__(self, key_hash: int, pairs: tuple[tuple[Hashable, Any], ...]) -> None:
        self.key_hash = key_hash
        self.pairs = pairs


class _Branch:
    __slots__ = ("bitmap", "items")

    def __init__(self, bitmap: int, items: tuple[Any, ...]) -> None:
        self.bitmap = bitmap
        self.items = items


_EMPTY_BRANCH: Final = _Branch(0, ())
_MISSING: Final = object()


def _merge(first: Any, second: Any, shift: int) -> _Branch:
    first_slot = (first.key_hash >> shift) & _MASK
    second_slot = (second.key_hash >> shift) & _MASK
    if first_slot == second_slot:
        return _Branch(1 << first_slot, (_merge(first, second, shift + _BITS),))
    bitmap = (1 << first_slot) | (1 << second_slot)
    if first_slot < second_slot:
        return _Branch(bitmap, (first, second))
    return _Branch(bitmap, (second, first))


def _branch_get(node: _Branch, key: Hashable, key_hash: int) -> Any:
    shift = 0
    while True:
        bit = 1 << ((key_hash >> shift) & _MASK)
        if not node.bitmap & bit:
            return _MISSING
        item = node.items[(node.bitmap & (bit - 1)).bit_count()]
        if type(item) is _Branch:
            node = item
            shift += _BITS
        elif type(item) is _Entry:
            return item.value if item.key_hash == key_hash and item.key == key else _MISSING
        else:
            for pair_key, pair_value in item.pairs:
                if pair_key == key:
                    return pair_value
            return _MISSING


def _branch_set(node: _Branch, key: Hashable, value: Any, key_hash: int, shift: int) -> _Branch:
    bit = 1 << ((key_hash >> shift) & _MASK)
    position = (node.bitmap & (bit - 1)).bit_count()
    if not node.bitmap & bit:
        return _Branch(
            node.bitmap | bit,
            node.items[:position] + (_Entry(key_hash, key, value),) + node.items[position:],
        )
    item = node.items[position]
    replacement: Any
    if type(item) is _Branch:
        replacement = _branch_set(item, key, value, key_hash, shift + _BITS)
    elif type(item) is _Entry:
        if item.key_hash != key_hash:
            replacement = _merge(item, _Entry(key_hash, key, value), shift + _BITS)
        elif item.key == key:
            replacement = _Entry(key_hash, key, value)
        else:
            replacement = _Collision(key_hash, ((item.key, item.value), (key, value)))
    elif item.key_hash != key_hash:
        replacement = _merge(item, _Entry(key_hash, key, value), shift + _BITS)
    else:
        pairs = tuple(pair for pair in item.pairs if pair[0] != key) + ((key, value),)
        replacement = _Collision(key_hash, pairs)
    return _Branch(node.bitmap, node.items[:position] + (replacement,) + node.items[position + 1:])


def _branch_iter(node: _Branch) -> Iterator[tuple[Hashable, Any]]:
    for item in node.items:
        if type(item) is _Branch:
            yield from _branch_iter(item)
        elif type(item) is _Entry:
            yield (item.key, item.value)
        else:
            yield from item.pairs


class PersistentMap[K: Hashable, V]:
    __slots__ = ("_count", "_root")

    _count: int
    _root: _Branch

    def __init__(self, count: int, root: _Branch) -> None:
        object.__setattr__(self, "_count", count)
        object.__setattr__(self, "_root", root)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("PersistentMap is immutable")

    def __len__(self) -> int:
        return self._count

    def __iter__(self) -> Iterator[tuple[K, V]]:
        return _branch_iter(self._root)  # type: ignore[return-value]

    def find(self, key: K, default: V | None = None) -> V | None:
        found = _branch_get(self._root, key, hash(key) & _HASH_MASK)
        return default if found is _MISSING else found  # type: ignore[no-any-return]

    def contains(self, key: K) -> bool:
        return _branch_get(self._root, key, hash(key) & _HASH_MASK) is not _MISSING

    def set(self, key: K, value: V) -> PersistentMap[K, V]:
        key_hash = hash(key) & _HASH_MASK
        added = 0 if _branch_get(self._root, key, key_hash) is not _MISSING else 1
        return PersistentMap(self._count + added, _branch_set(self._root, key, value, key_hash, 0))


def empty_map[K: Hashable, V]() -> PersistentMap[K, V]:
    return PersistentMap(0, _EMPTY_BRANCH)


def _build_branch(items: list[_Entry], shift: int) -> _Branch:
    groups: dict[int, list[_Entry]] = {}
    for item in items:
        groups.setdefault((item.key_hash >> shift) & _MASK, []).append(item)
    bitmap = 0
    children: list[Any] = []
    for slot in sorted(groups):
        group = groups[slot]
        bitmap |= 1 << slot
        if len(group) == 1:
            children.append(group[0])
        elif all(member.key_hash == group[0].key_hash for member in group):
            children.append(_Collision(group[0].key_hash, tuple((member.key, member.value) for member in group)))
        else:
            children.append(_build_branch(group, shift + _BITS))
    return _Branch(bitmap, tuple(children))


def map_of[K: Hashable, V](pairs: Iterable[tuple[K, V]]) -> PersistentMap[K, V]:
    unique = dict(pairs)
    items = [_Entry(hash(key) & _HASH_MASK, key, value) for key, value in unique.items()]
    return PersistentMap(len(items), _build_branch(items, 0) if items else _EMPTY_BRANCH)


def _empty_bits(shift: int) -> Any:
    return 0 if shift == 0 else (0, ())


def _bits_add(node: Any, shift: int, position: int) -> Any:
    if shift == 0:
        return node | (1 << (position & _MASK))
    mask, kids = node
    bit = 1 << ((position >> shift) & _MASK)
    offset = (mask & (bit - 1)).bit_count()
    if mask & bit:
        return (mask, kids[:offset] + (_bits_add(kids[offset], shift - _BITS, position),) + kids[offset + 1:])
    child = _bits_add(_empty_bits(shift - _BITS), shift - _BITS, position)
    return (mask | bit, kids[:offset] + (child,) + kids[offset:])


def _bits_discard(node: Any, shift: int, position: int) -> Any:
    if shift == 0:
        return node & ~(1 << (position & _MASK))
    mask, kids = node
    bit = 1 << ((position >> shift) & _MASK)
    if not mask & bit:
        return node
    offset = (mask & (bit - 1)).bit_count()
    child = _bits_discard(kids[offset], shift - _BITS, position)
    if shift - _BITS == 0:
        emptied = child == 0
    else:
        emptied = child[0] == 0
    if emptied:
        return (mask & ~bit, kids[:offset] + kids[offset + 1:])
    return (mask, kids[:offset] + (child,) + kids[offset + 1:])


def _bits_walk(node: Any, shift: int, base: int) -> Iterator[int]:
    if shift == 0:
        remaining = node
        while remaining:
            low = remaining & -remaining
            yield base | (low.bit_length() - 1)
            remaining ^= low
        return
    mask, kids = node
    index = 0
    remaining = mask
    while remaining:
        low = remaining & -remaining
        yield from _bits_walk(kids[index], shift - _BITS, base | ((low.bit_length() - 1) << shift))
        remaining ^= low
        index += 1


class PersistentBitSet:
    __slots__ = ("_shift", "_root")

    _shift: int
    _root: Any

    def __init__(self, shift: int, root: Any) -> None:
        object.__setattr__(self, "_shift", shift)
        object.__setattr__(self, "_root", root)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("PersistentBitSet is immutable")

    def __iter__(self) -> Iterator[int]:
        return _bits_walk(self._root, self._shift, 0)

    def least(self) -> int | None:
        node = self._root
        shift = self._shift
        base = 0
        while shift > 0:
            mask, kids = node
            if not mask:
                return None
            base |= ((mask & -mask).bit_length() - 1) << shift
            node = kids[0]
            shift -= _BITS
        if not node:
            return None
        return base | ((node & -node).bit_length() - 1)

    def add(self, position: int) -> PersistentBitSet:
        shift = self._shift
        root = self._root
        while position >> (shift + _BITS):
            root = (1, (root,)) if _has_members(root, shift) else _empty_bits(shift + _BITS)
            shift += _BITS
        return PersistentBitSet(shift, _bits_add(root, shift, position))

    def discard(self, position: int) -> PersistentBitSet:
        if position >> (self._shift + _BITS):
            return self
        return PersistentBitSet(self._shift, _bits_discard(self._root, self._shift, position))


def _has_members(node: Any, shift: int) -> bool:
    return node != 0 if shift == 0 else node[0] != 0


def empty_bit_set() -> PersistentBitSet:
    return PersistentBitSet(_MIN_SHIFT, _empty_bits(_MIN_SHIFT))


def _bits_build(positions: list[int], shift: int) -> Any:
    if shift == 0:
        mask = 0
        for position in positions:
            mask |= 1 << (position & _MASK)
        return mask
    mask = 0
    kids: list[Any] = []
    for slot, group in groupby(positions, key=lambda position: (position >> shift) & _MASK):
        mask |= 1 << slot
        kids.append(_bits_build(list(group), shift - _BITS))
    return (mask, tuple(kids))


def bit_set_of(positions: Iterable[int]) -> PersistentBitSet:
    ordered = sorted(set(positions))
    shift = _MIN_SHIFT
    while ordered and ordered[-1] >> (shift + _BITS):
        shift += _BITS
    return PersistentBitSet(shift, _bits_build(ordered, shift))
