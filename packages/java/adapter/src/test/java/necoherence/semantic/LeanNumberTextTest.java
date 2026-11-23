// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

final class LeanNumberTextTest {
    private static String leanText(String text) {
        return SemanticValues.encodeWire(SemanticGeneration.readJson(text));
    }

    @Test void negativeExponentAtOrAboveTheLimitIsRejectedAsThePositiveOneIs() {
        for (String spelling : new String[] {"1e-10000", "1E-10000", "1e-4294967296", "1e-99999999999999999999",
                "1e10000", "1E+10000", "1e4294967296", "1e-" + "0".repeat(5000) + "10000", "1e" + "0".repeat(5000) + "10000"})
            assertEquals(new WireFailure.Syntax("$", "exponent too large"),
                    assertThrows(WireFailure.WireException.class, () -> leanText(spelling), spelling).failure(), spelling);
    }

    @Test void exponentLeadingZerosAreComparedByValue() {
        for (String spelling : new String[] {"1e-9999", "1e9999", "1e-" + "0".repeat(5000) + "5", "1e+" + "0".repeat(5000) + "9999",
                "1e-" + "0".repeat(5000), "7e-0000000005"})
            assertDoesNotThrow(() -> leanText(spelling), spelling);
    }

    @Test void largeNegativeExponentIsCanonicalAsTheLeanScientificText() {
        assertEquals("0.0000000001e-9989", leanText("1e-9999"));
        assertEquals("0.0000000001e-12", leanText("0.0000000000000000000001"));
    }

    @Test void equalValuesWithDifferentSpellingsShareTheCanonicalText() {
        assertEquals("0.0000000001e-9989", leanText("0.01e-9997"));
        assertEquals("0.0000000001e-9989", leanText("0.1e-9998"));
        assertEquals("0.000000000123456789012345678905e-1", leanText("12345678901234567890.5e-30"));
    }

    @Test void ordinaryNumbersAreWrittenWithTheLeanNumberText() {
        assertEquals("0.0001", leanText("1e-4"));
        assertEquals("1.5", leanText("1.50"));
        assertEquals("1.2345", leanText("123.4500e-2"));
        assertEquals("-0.125", leanText("-0.000125e3"));
        assertEquals("1500", leanText("1.5e3"));
        assertEquals("100.0", leanText("100.0"));
        assertEquals("-125", leanText("-1.25E+2"));
        assertEquals("0", leanText("0e11"));
        assertEquals("0.0", leanText("-0.0"));
    }

    @Test void decimalKindFollowsTheExponentAfterTheFraction() {
        assertEquals(new SemanticValues.DecimalValue("10"), SemanticGeneration.readJson("10.0"));
        assertEquals(new SemanticValues.DecimalValue("10"), SemanticGeneration.readJson("100.0e-1"));
        assertEquals(new SemanticValues.DecimalValue("15"), SemanticGeneration.readJson("1.50e1"));
        assertEquals(new SemanticValues.DecimalValue("0.5"), SemanticGeneration.readJson("5e-1"));
        assertEquals(new SemanticValues.DecimalValue("0"), SemanticGeneration.readJson("-0.0"));
        assertEquals(new SemanticValues.IntegerValue(java.math.BigInteger.TEN), SemanticGeneration.readJson("1e1"));
        assertEquals(new SemanticValues.IntegerValue(java.math.BigInteger.valueOf(105)), SemanticGeneration.readJson("10.5e1"));
        assertEquals(new SemanticValues.IntegerValue(java.math.BigInteger.ZERO), SemanticGeneration.readJson("0.0e1"));
    }

    @Test void decimalIsWrittenWithTheLeanNumberTextAndReadsBackAsTheSameDecimal() {
        assertEquals("10.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("10")));
        assertEquals("1.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("1")));
        assertEquals("-7.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("-7")));
        assertEquals("0.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("0")));
        assertEquals("1.5", SemanticValues.encodeWire(new SemanticValues.DecimalValue("1.5")));
        assertEquals("15.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("1.50e1")));
        assertEquals("1.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("100e-2")));
        assertEquals("0.0", SemanticValues.encodeWire(new SemanticValues.DecimalValue("0e-100")));
        assertEquals("0.0000000001e-90", SemanticValues.encodeWire(new SemanticValues.DecimalValue("1e-100")));
        assertEquals("1e10000", SemanticValues.encodeWire(new SemanticValues.DecimalValue("1e10000")));
        for (String text : new String[] {"10", "1", "-7", "0", "1.5", "0.0000000001e-90"}) {
            SemanticValues.WireValue written = new SemanticValues.DecimalValue(text);
            assertEquals(written, SemanticGeneration.readJson(SemanticValues.encodeWire(written)), text);
        }
    }
}
