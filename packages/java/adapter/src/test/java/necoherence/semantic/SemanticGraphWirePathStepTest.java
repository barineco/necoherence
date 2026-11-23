// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.NIL;
import static necoherence.semantic.SemanticValues.obj;
import static necoherence.semantic.SemanticValues.str;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

class SemanticGraphWirePathStepTest {
    @Test
    void pathStepWithTheClosedTagAndValueKeysIsAccepted() throws Exception {
        assertEquals(new necoherence.composition.SemanticComposition.Field("x"),
                SemanticGraphWire.pathStep(obj("tag", str("Field"), "value", str("x"))));
        assertEquals(new necoherence.composition.SemanticComposition.Index(java.math.BigInteger.ZERO),
                SemanticGraphWire.pathStep(obj("tag", str("Index"), "value", str("0"))));
    }

    @Test
    void pathStepWithAnExtraKeyIsRejected() {
        assertRejected(obj("tag", str("Field"), "value", str("x"), "extra", NIL));
        assertRejected(obj("tag", str("Index"), "value", str("0"), "fields", NIL));
        assertRejected(obj("tag", str("Variant"), "value", str("x"), "extra", str("y")));
    }

    @Test
    void pathStepWithTheFieldsKeyInsteadOfTheValueKeyIsRejected() {
        assertRejected(obj("tag", str("Field"), "fields", str("x")));
    }

    private static void assertRejected(WireValue step) {
        assertThrows(WireException.class, () -> SemanticGraphWire.pathStep(step));
    }
}
