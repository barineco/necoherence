// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.util.Objects;

/**
 * A structured failure produced while reading a wire value.
 * The variants are the Java representation of the Lean {@code SignatureWire.WireFailure}.
 */
public sealed interface WireFailure permits WireFailure.UnsupportedSchema, WireFailure.UnknownField,
        WireFailure.UnknownTag, WireFailure.Syntax {

    /** The JSON path of the failing value. */
    String path();

    /** The schema version is not the admitted one. */
    record UnsupportedSchema(String path, String schema) implements WireFailure {}

    /** The object has a member that the wire form does not define. */
    record UnknownField(String path, String field) implements WireFailure {}

    /** The tag is not a variant of the wire form. */
    record UnknownTag(String path, String tag) implements WireFailure {}

    /** The value is not of the wire form, or a required member is missing. */
    record Syntax(String path, String message) implements WireFailure {}

    /**
     * Carries one wire failure value out of a decoder to the boundary that reports it, so that the value is never
     * reduced to a message before that boundary.
     */
    final class WireException extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final transient WireFailure failure;

        public WireException(WireFailure failure) {
            super(Objects.requireNonNull(failure).toString());
            this.failure = failure;
        }

        /** @return the structured wire failure */
        public WireFailure failure() { return failure; }
    }
}
