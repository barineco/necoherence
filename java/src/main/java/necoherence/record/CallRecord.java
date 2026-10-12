// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.record;

/**
 * One call: which declaration ran, on what input, and what settled.
 *
 * <p>Mirrors Rust's {@code CallRecord<Input, Product>}. The discriminant
 * that Rust's {@code Option<Basis>} carries is a language-machinery
 * question in its own right; see {@link RecordBasis} for why this field is
 * that closed sum rather than a nullable or {@code Optional} value. No edge
 * field is held here: an edge is derived from two records' bases, never
 * stored (see {@link Record#hasEdge}).
 */
public record CallRecord<Input, Product>(
        String declaration, Input input, Product product, RecordBasis basis) {
}
