// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static org.junit.jupiter.api.Assertions.*;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

final class JsonAdmissionFailureTest {
    private static Syntax syntaxFailureOf(String text) {
        WireException rejected = assertThrows(WireException.class, () -> SemanticGeneration.readJson(text));
        return (Syntax) rejected.failure();
    }

    @Test void loneHighSurrogateEscapeIsAnUnpairedSurrogateFailure() {
        assertEquals(new Syntax("$", "unpaired Unicode surrogate"), syntaxFailureOf("\"\\uD800\""));
    }

    @Test void loneLowSurrogateEscapeIsAnUnpairedSurrogateFailure() {
        assertEquals(new Syntax("$", "unpaired Unicode surrogate"), syntaxFailureOf("\"\\uDC00\""));
    }

    @Test void surrogatePairEscapeIsAccepted() {
        assertDoesNotThrow(() -> SemanticGeneration.readJson("\"\\uD800\\uDC00\""));
    }

    @Test void positiveExponentAtTheLimitIsAnExponentFailure() {
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("1e10000"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("1E+10000"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("1e100000"));
    }

    @Test void positiveExponentBelowTheLimitIsAccepted() {
        assertDoesNotThrow(() -> SemanticGeneration.readJson("1e9999"));
    }

    @Test void positiveExponentAtTwoToThe32IsAnExponentFailure() {
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("1e4294967296"));
    }

    @Test void uppercaseSignedPositiveExponentAtLimitIsAnExponentFailure() {
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("1E+4294967296"));
    }

    @Test void negativeExponentIsAccepted() {
        assertDoesNotThrow(() -> SemanticGeneration.readJson("1e-4"));
    }

    @Test void exponentLimitAppliesToNumbersOutsideStringsOnly() {
        assertTrue(SemanticValues.exponentTooLarge("1e10000"));
        assertFalse(SemanticValues.exponentTooLarge("1e9999"));
        assertEquals(new SemanticValues.StringValue("e10000"), SemanticGeneration.readJson("\"e10000\""));
    }

    @Test void exponentBeforeASyntaxErrorIsTheFailureOfTheWholeText() {
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("[1 2 1e10000]"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("{\"a\": x, \"b\": 1e10000}"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("[1 x 1e+10000]"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("[1e-10000 x]"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("[\"\\\\\" 1e10000]"));
    }

    @Test void surrogateAndExponentFailuresFollowTheOrderOfTheText() {
        assertEquals(new Syntax("$", "unpaired Unicode surrogate"), syntaxFailureOf("[\"\\uD800\" x 1e10000]"));
        assertEquals(new Syntax("$", "exponent too large"), syntaxFailureOf("[1e10000 \"\\uD800\"]"));
    }

    @Test void profileAdmissionChecksTheSignatureRuleBeforeTheParse() {
        assertEquals(new Syntax("$", "unpaired Unicode surrogate"),
                assertThrows(WireException.class, () -> SemanticGeneration.boundedJsonParse("[\"\\uD800\" x 1e10000]")).failure());
        assertEquals(new Syntax("$", "exponent too large"),
                assertThrows(WireException.class, () -> SemanticGeneration.boundedJsonParse("[1 2 1e10000]")).failure());
    }

    @Test void exponentTextInsideAStringIsNotAnExponent() {
        assertDoesNotThrow(() -> SemanticGeneration.readJson("[\"1e10000\"]"));
    }
}
