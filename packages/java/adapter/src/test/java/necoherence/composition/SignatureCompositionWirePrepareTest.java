// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.NIL;
import static necoherence.semantic.SemanticValues.arr;
import static necoherence.semantic.SemanticValues.obj;
import static necoherence.semantic.SemanticValues.str;
import static necoherence.semantic.SemanticValues.variant;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.CompositionEffect;
import necoherence.composition.SemanticComposition.DefinitionRef;
import necoherence.composition.SemanticComposition.FunctionRef;
import necoherence.composition.SemanticComposition.FunctionSignature;
import necoherence.composition.SemanticComposition.Pure;
import necoherence.semantic.SemanticTypes.SourceRef;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

class SignatureCompositionWirePrepareTest {
    private static final String DIGEST = "d".repeat(64);

    @Test
    void operationShapeWithAnExtraKeyIsRejectedBeforeTheEffectCheck() throws Exception {
        WireValue shape = obj("tag", str("Operation"), "value", obj("effect", variant("DataOnly")), "extra", NIL);
        WireValue declaration = obj("id", str("op"), "wire_identity", str("ncoh"), "shape", shape);
        WireValue library = obj("revision", str("1"), "definitions", arr(List.of(declaration)));
        FunctionSignature function = new FunctionSignature(new FunctionRef("ncoh", "1", DIGEST), new Pure(),
                CompositionEffect.DATA_ONLY, List.of(), List.of(), List.of(), "assumption", Optional.empty());
        Method method = SignatureCompositionWire.class.getDeclaredMethod("checkOperation", WireValue.class, String.class,
                List.class, FunctionSignature.class, DefinitionRef.class);
        method.setAccessible(true);
        DefinitionRef definition = new DefinitionRef(new SourceRef("ncoh", "1", "types.md", DIGEST, "doc", Optional.empty()), "op");
        InvocationTargetException failure = assertThrows(InvocationTargetException.class,
                () -> method.invoke(null, library, DIGEST, List.of(), function, definition));
        WireException rejected = assertInstanceOf(WireException.class, failure.getCause());
        org.junit.jupiter.api.Assertions.assertEquals(new necoherence.semantic.WireFailure.UnknownField("$.shape.extra", "extra"),
                rejected.failure());
    }
}
