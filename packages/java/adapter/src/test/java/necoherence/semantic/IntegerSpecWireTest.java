// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.NIL;
import static necoherence.semantic.SemanticValues.arr;
import static necoherence.semantic.SemanticValues.obj;
import static necoherence.semantic.SemanticValues.str;
import static necoherence.semantic.SemanticValues.variant;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.semantic.SemanticTypes.IntegerShape;
import necoherence.semantic.SemanticValues.WireValue;
import org.junit.jupiter.api.Test;

final class IntegerSpecWireTest {
    private static WireValue integerShape(WireValue enumeration) {
        return variant("Integer", obj("domain", NIL, "minimum", NIL, "maximum", NIL, "const_value", NIL,
                "enum_values", enumeration, "default_value", NIL));
    }

    @Test void enumValuesAreIntegersAsTheLeanIntegerSpecReadsThem() {
        IntegerShape shape = (IntegerShape) SemanticGraphWire.shape(integerShape(arr(List.of(str("-1"), str("0"), str("7")))));
        assertEquals(Optional.of(List.of(BigInteger.valueOf(-1), BigInteger.ZERO, BigInteger.valueOf(7))), shape.spec().enumValues());
    }

    @Test void enumValuesRejectNonCanonicalIntegers() {
        for (String text : new String[] {"-0", "01", "1.5", "+1", ""})
            assertThrows(WireFailure.WireException.class,
                    () -> SemanticGraphWire.shape(integerShape(arr(List.of(str(text))))), text);
    }
}
