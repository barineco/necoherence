// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.WireFailure.UnknownField;
import org.junit.jupiter.api.Test;

/**
 * Lean {@code keys}: the unknown members are reported first, the first in key order, and then the first missing
 * expected member, in the order of the expected list. The expected paths and messages follow the Lean
 * {@code SignatureWire.decode} contract.
 */
final class SignatureWireKeysTest {
    private static final WireValue TRUE = new BooleanValue(true), FALSE = new BooleanValue(false);

    @Test void recordWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue slot = obj("type_id", str("t"), "required", TRUE, "nullable", FALSE, "note", str("x"));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.canonical(slot, "SignatureSlot", "$"));
        assertEquals("$.note", failure.path());
        assertEquals(new UnknownField("$.note", "note"), failure.wireFailure());
    }

    @Test void recordMissingAFieldIsReportedBeforeAnEarlierFieldIsRead() {
        WireValue slot = obj("type_id", NIL, "nullable", FALSE);
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.canonical(slot, "SignatureSlot", "$"));
        assertEquals("$.required", failure.path());
        assertEquals("missing field", failure.condition());
    }

    @Test void recordReportsTheFirstUnknownMemberInKeyOrderNotInputOrder() {
        WireValue slot = obj("type_id", str("t"), "required", TRUE, "nullable", FALSE, "zeta", str("1"), "alpha", str("2"));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.canonical(slot, "SignatureSlot", "$"));
        assertEquals("$.alpha", failure.path());
        assertEquals(new UnknownField("$.alpha", "alpha"), failure.wireFailure());
    }

    @Test void exactDecimalReportsTheFirstUnknownMemberInKeyOrderNotInputOrder() {
        WireValue decimal = obj("tag", str("Decimal"), "zeta", str("1"), "alpha", str("2"));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.canonical(decimal, "ExactJson", "$"));
        assertEquals("$.alpha", failure.path());
        assertEquals(new UnknownField("$.alpha", "alpha"), failure.wireFailure());
    }

    @Test void exactDecimalWithAnExtraMemberIsAnUnknownFieldBeforeTheTextIsRequired() {
        WireValue decimal = obj("tag", str("Decimal"), "note", str("x"));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.canonical(decimal, "ExactJson", "$"));
        assertEquals("$.note", failure.path());
        assertEquals(new UnknownField("$.note", "note"), failure.wireFailure());
    }

    @Test void exactBoolWithAnExtraMemberIsAnUnknownFieldNotAMissingValue() {
        WireValue bool = obj("tag", str("Bool"), "note", str("x"));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.canonical(bool, "ExactJson", "$"));
        assertEquals("$.note", failure.path());
        assertEquals(new UnknownField("$.note", "note"), failure.wireFailure());
    }
}
