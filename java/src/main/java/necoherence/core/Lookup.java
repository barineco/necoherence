// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/**
 * Closed sum of a held revision and an absent-resource payload.
 *
 * <p>Java has no union types, so the Python return type
 * {@code Revision | UnknownResource} is not directly expressible. A closed
 * {@code sealed interface} carries the same two-way fact through the type
 * checker instead: {@code switch} over {@code Lookup} is exhaustive, and
 * absence never leaves the declared return type. This mirrors Rust's
 * {@code Lookup} type, chosen for the same reason.
 */
public sealed interface Lookup permits Lookup.Found, Lookup.Unknown {

    record Found(Revision revision) implements Lookup {
    }

    record Unknown(UnknownResource unknownResource) implements Lookup {
    }
}
