// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import java.util.List;
import necoherence.persistent.PersistentMap;
import necoherence.persistent.PersistentVector;

/**
 * Immutable ordered map from resource identity to revision.
 *
 * <p>The constructor and {@link #appended} build a {@code World}; the constructor accepts any
 * list, including one that repeats a resource. {@link #entries()} returns the
 * entries in order. Operations in {@link Core} find a resource through an
 * index of first positions and replace a revision without copying the other
 * entries.
 */
public final class World {
    private final PersistentVector<Entry> entries;
    private final PersistentMap<ResourceId, Integer> firstPositions;

    public World(List<Entry> entries) {
        PersistentMap<ResourceId, Integer> positions = PersistentMap.empty();
        for (int position = 0; position < entries.size(); position++) {
            ResourceId resource = entries.get(position).resource();
            if (!positions.containsKey(resource)) {
                positions = positions.put(resource, position);
            }
        }
        this.entries = PersistentVector.of(entries);
        this.firstPositions = positions;
    }

    private World(PersistentVector<Entry> entries, PersistentMap<ResourceId, Integer> firstPositions) {
        this.entries = entries;
        this.firstPositions = firstPositions;
    }

    /** Return the entries in order. */
    public List<Entry> entries() {
        return List.copyOf(entries.toList());
    }

    int firstPosition(ResourceId resource) {
        Integer position = firstPositions.get(resource);
        return position == null ? -1 : position;
    }

    Entry entryAt(int position) {
        return entries.get(position);
    }

    World replacing(int position, Entry entry) {
        return new World(entries.set(position, entry), firstPositions);
    }

    /** Return a world with one more entry at the end; used by File effect to register a resource. */
    public World appended(ResourceId resource, Revision revision) {
        PersistentMap<ResourceId, Integer> positions =
                firstPositions.containsKey(resource) ? firstPositions : firstPositions.put(resource, entries.size());
        return new World(entries.append(new Entry(resource, revision)), positions);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof World world && entries().equals(world.entries());
    }

    @Override
    public int hashCode() {
        return entries().hashCode();
    }

    @Override
    public String toString() {
        return "World" + entries();
    }

    /** One resource identity paired with its revision. */
    public record Entry(ResourceId resource, Revision revision) {
    }
}
