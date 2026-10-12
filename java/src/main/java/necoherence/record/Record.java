// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.record;

import necoherence.core.Basis;

/**
 * Static free functions building and relating {@link CallRecord} values.
 *
 * <p>Follows the same first-argument-takes-the-subject convention as
 * {@code necoherence.core.Core}: no method lives on {@code CallRecord}
 * beyond the record accessors Java generates.
 */
public final class Record {

    private Record() {
    }

    /** Build a {@link CallRecord} without a basis. */
    public static <Input, Product> CallRecord<Input, Product> recordOf(
            String declaration, Input input, Product product) {
        return new CallRecord<>(declaration, input, product, new RecordBasis.Unsituated());
    }

    /** Build a {@link CallRecord} that carries the basis its command was situated on. */
    public static <Input, Product> CallRecord<Input, Product> recordOnBasis(
            String declaration, Input input, Product product, Basis basis) {
        return new CallRecord<>(declaration, input, product, new RecordBasis.Situated(basis));
    }

    /**
     * Hold where {@code later} reads the resource {@code earlier} settled.
     *
     * <p>An absent edge witnesses that two calls touched disjoint
     * coordinates. Derived from both records' bases each time; no edge is
     * ever stored on either record.
     */
    public static boolean hasEdge(CallRecord<?, ?> earlier, CallRecord<?, ?> later) {
        if (earlier.basis() instanceof RecordBasis.Situated settled
                && later.basis() instanceof RecordBasis.Situated read) {
            return settled.basis().resource().equals(read.basis().resource());
        }
        return false;
    }
}
