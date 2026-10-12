// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.record;

import necoherence.core.Basis;

/**
 * Closed sum standing in for Rust's {@code Option<Basis>}.
 *
 * <p>Absence must be a domain value, not a built-in optional/choice type.
 * {@link necoherence.core.Lookup} already follows this in the same package
 * family ({@code Found} / {@code Unknown} as a {@code sealed interface}), so
 * a record without a basis is written the same way here: a closed two-branch
 * sum, not {@code Optional<Basis>}.
 *
 * <p>Unlike {@code Lookup.Unknown}, the absent branch here carries no
 * domain payload of its own: "this call was not situated on a resource" is
 * the entire fact, there is nothing further to name. The shape mirrors
 * {@code Lookup} regardless, so the two closed sums in this codebase stay
 * uniform rather than one being a sealed interface and the other an
 * {@code Optional}.
 */
public sealed interface RecordBasis permits RecordBasis.Situated, RecordBasis.Unsituated {

    record Situated(Basis basis) implements RecordBasis {
    }

    record Unsituated() implements RecordBasis {
    }
}
