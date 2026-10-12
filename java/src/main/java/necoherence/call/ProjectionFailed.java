// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.call;

import java.util.List;

/**
 * Declared failure when {@code x} is missing fields that an input shape requires.
 *
 * <p>{@code declaration} is the identity of the {@code Immediate} or
 * {@code Deferred} whose input shape could not be matched. {@code fields}
 * holds every missing field's name, not just the first, so a caller can fix
 * its input in one pass instead of discovering the gaps one at a time.
 *
 * <p>{@link Call#io} and {@link Call#issue} return this branch whenever a
 * {@link Call.Request}'s field-name list does not carry every name the
 * declaration requires; it is a reachable outcome of every call, not a
 * reserved vocabulary for a separate boundary path.
 */
public record ProjectionFailed(String declaration, List<String> fields) {

    public ProjectionFailed {
        fields = List.copyOf(fields);
    }
}
