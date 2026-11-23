// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.WireValue;
import org.junit.jupiter.api.Test;

final class JsonStageTest {
    @Test void nestingHasNoFixedLimit() {
        for (int depth : new int[] {513, 5000, 100_000}) {
            WireValue arrays = assertDoesNotThrow(() -> SemanticGeneration.readJson("[".repeat(depth) + "]".repeat(depth)));
            assertInstanceOf(ArrayValue.class, arrays);
            WireValue objects = assertDoesNotThrow(() -> SemanticGeneration.readJson("{\"a\":".repeat(depth) + "1" + "}".repeat(depth)));
            assertInstanceOf(ObjectValue.class, objects);
        }
    }

    @Test void nestedValuesKeepTheirMemberOrderAndSeparators() {
        WireValue value = SemanticGeneration.readJson(" {\"a\" : [1, {\"b\":[]}, \"x\"] , \"c\":{}} ");
        assertEquals("{\"a\":[1,{\"b\":[]},\"x\"],\"c\":{}}", SemanticValues.encodeWire(value));
        for (String malformed : new String[] {"[1,]", "{\"a\":1,}", "[1 2]", "{\"a\" 1}", "[", "{\"a\":1", "[[1]", "{\"a\":1}x", "[01]", "[1.]"})
            assertThrows(WireFailure.WireException.class, () -> SemanticGeneration.readJson(malformed), malformed);
    }

    @Test void exactDecimalRejectsSurroundingWhitespaceAndLargeExponents() {
        for (String text : new String[] {" 1", "1 ", "\n1", "\t1", "1\r", "1e10000", "1e-10000", "+1", "1.", ".5", "", "-"})
            assertFalse(SemanticValues.isExactDecimal(text), text);
        for (String text : new String[] {"1", "-0", "1.5", "1e-9999", "1E+9999", "0.5e0"})
            assertTrue(SemanticValues.isExactDecimal(text), text);
        assertTrue(SemanticValues.isJsonNumber(" 1 "));
        assertFalse(SemanticValues.isJsonNumber("1e-10000"));
    }

    @Test void exactJsonDecimalRejectsSurroundingWhitespace() {
        for (String text : new String[] {" 1", "1 ", "\n1", "\t1"})
            assertThrows(GenerationFailure.class, () -> SemanticGeneration.canonical(
                    SemanticValues.obj("tag", SemanticValues.str("Decimal"), "text", SemanticValues.str(text)), "ExactJson", "$"), text);
        assertDoesNotThrow(() -> SemanticGeneration.canonical(
                SemanticValues.obj("tag", SemanticValues.str("Decimal"), "text", SemanticValues.str("1.5")), "ExactJson", "$"));
    }

    @Test void canonicalDecimalSpellingIsTheExactDecimal() {
        for (String text : new String[] {" 1", "1 ", "\n1", "\t1", "1e10000"})
            assertThrows(GenerationFailure.class, () -> SemanticGeneration.canonical(SemanticValues.str(text), "d", "$"), text);
        assertDoesNotThrow(() -> SemanticGeneration.canonical(SemanticValues.str("1e-9999"), "d", "$"));
    }
}
