// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;
import necoherence.core.ResourceId;
import necoherence.persistent.PersistentMap;
import necoherence.persistent.PersistentVector;

/**
 * Immutable map from resource identity to the digest of its last observed contents.
 *
 * <p>{@link #of} accepts any list, including one that repeats a resource. {@link #entries()} returns the
 * entries in order. Operations find a resource through an index of first positions and replace one entry
 * without copying the others; a list that repeats a resource updates every match.
 */
public final class Digests {
    private final PersistentVector<Entry> entries;
    private final PersistentMap<ResourceId, Integer> firstPositions;
    private final boolean distinct;

    private Digests(PersistentVector<Entry> entries, PersistentMap<ResourceId, Integer> firstPositions,
            boolean distinct) {
        this.entries = entries;
        this.firstPositions = firstPositions;
        this.distinct = distinct;
    }

    public static Digests of(List<Entry> entries) {
        PersistentMap<ResourceId, Integer> positions = PersistentMap.empty();
        boolean distinct = true;
        for (int position = 0; position < entries.size(); position++) {
            ResourceId resource = entries.get(position).resource();
            if (positions.containsKey(resource)) {
                distinct = false;
            } else {
                positions = positions.put(resource, position);
            }
        }
        return new Digests(PersistentVector.of(entries), positions, distinct);
    }

    /** Return the entries in order. */
    public List<Entry> entries() {
        return List.copyOf(entries.toList());
    }

    ContentDigest digestOf(ResourceId resource) {
        Integer position = firstPositions.get(resource);
        return position == null ? null : entries.get(position).digest();
    }

    Digests with(ResourceId resource, ContentDigest digest) {
        Integer position = firstPositions.get(resource);
        if (position == null) {
            return new Digests(entries.append(new Entry(resource, digest)),
                    firstPositions.put(resource, entries.size()), distinct);
        }
        if (distinct) {
            return new Digests(entries.set(position, new Entry(resource, digest)), firstPositions, true);
        }
        PersistentVector<Entry> next = entries;
        for (int index = 0; index < entries.size(); index++) {
            if (entries.get(index).resource().equals(resource)) {
                next = next.set(index, new Entry(resource, digest));
            }
        }
        return new Digests(next, firstPositions, false);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Digests digests && entries().equals(digests.entries());
    }

    @Override
    public int hashCode() {
        return entries().hashCode();
    }

    @Override
    public String toString() {
        return "Digests" + entries();
    }

    public record Entry(ResourceId resource, ContentDigest digest) {
    }
}
