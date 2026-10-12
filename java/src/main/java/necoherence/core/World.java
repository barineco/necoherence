// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import java.util.List;

/**
 * Immutable ordered map from resource identity to revision.
 *
 * <p>{@code entries} is defensively copied with {@link List#copyOf} in the
 * canonical constructor, so a caller cannot mutate the list backing an
 * already-built {@code World} through a reference it kept. {@code List.of}
 * entries ({@link Entry}) are themselves records, so no further defense is
 * needed at that level.
 */
public record World(List<Entry> entries) {

    public World {
        entries = List.copyOf(entries);
    }

    /** One resource identity paired with its revision. */
    public record Entry(ResourceId resource, Revision revision) {
    }
}
