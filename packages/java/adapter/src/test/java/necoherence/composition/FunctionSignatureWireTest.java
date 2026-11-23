// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticGeneration.readJson;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.AcceptedArm;
import necoherence.composition.SemanticComposition.CompositionEffect;
import necoherence.composition.SemanticComposition.FailureOrigin;
import necoherence.composition.SemanticComposition.FunctionFailureOrigin;
import necoherence.composition.SemanticComposition.FunctionRef;
import necoherence.composition.SemanticComposition.FunctionSignature;
import necoherence.composition.SemanticComposition.GuardFailureOrigin;
import necoherence.composition.SemanticComposition.GuardId;
import necoherence.composition.SemanticComposition.OutcomeId;
import necoherence.composition.SemanticComposition.Pure;
import necoherence.composition.SemanticComposition.VariantArm;
import necoherence.semantic.SemanticValues.WireValue;
import org.junit.jupiter.api.Test;

class FunctionSignatureWireTest {
    private static final FunctionRef REFERENCE = new FunctionRef("ncoh-type-signatures", "1", "a".repeat(64));
    private static final String REFERENCE_JSON = "{\"content_digest\":\"" + "a".repeat(64)
            + "\",\"identity\":\"ncoh-type-signatures\",\"revision\":\"1\"}";
    private static final String HEAD_JSON = "{\"assumption_ref\":\"assumption\",\"effect\":{\"tag\":\"PureFunction\"},"
            + "\"form\":{\"tag\":\"Pure\"},";
    private static final String TAIL_JSON = ",\"inputs\":[],\"outcomes\":[],\"reference\":" + REFERENCE_JSON
            + ",\"resource_inputs\":[]}";
    private static final String LEAN_ENCODING_WITH_FUNCTION = HEAD_JSON
            + "\"handles_failure\":{\"fields\":{\"function\":" + REFERENCE_JSON + ",\"outcome\":\"o\"},\"tag\":\"Function\"}"
            + TAIL_JSON;
    private static final String LEAN_ENCODING_WITH_GUARD_VARIANT = HEAD_JSON
            + "\"handles_failure\":{\"fields\":{\"arm\":{\"tag\":\"Variant\",\"value\":\"x\"},\"guard\":\"g\"},\"tag\":\"Guard\"}"
            + TAIL_JSON;
    private static final String LEAN_ENCODING_WITH_GUARD_ACCEPTED = HEAD_JSON
            + "\"handles_failure\":{\"fields\":{\"arm\":{\"tag\":\"Accepted\"},\"guard\":\"g\"},\"tag\":\"Guard\"}"
            + TAIL_JSON;
    private static final String LEAN_ENCODING_ABSENT = HEAD_JSON + "\"handles_failure\":null" + TAIL_JSON;

    @Test
    void leanEncodingWithEveryHandlesFailureDecodesToTheTypedSignature() throws Exception {
        assertEquals(signature(Optional.of(new FunctionFailureOrigin(REFERENCE, new OutcomeId("o")))),
                functionSignature(LEAN_ENCODING_WITH_FUNCTION));
        assertEquals(signature(Optional.of(new GuardFailureOrigin(new GuardId("g"), new VariantArm("x")))),
                functionSignature(LEAN_ENCODING_WITH_GUARD_VARIANT));
        assertEquals(signature(Optional.of(new GuardFailureOrigin(new GuardId("g"), new AcceptedArm()))),
                functionSignature(LEAN_ENCODING_WITH_GUARD_ACCEPTED));
        assertEquals(signature(Optional.empty()), functionSignature(LEAN_ENCODING_ABSENT));
    }

    private static FunctionSignature signature(Optional<FailureOrigin> origin) {
        return new FunctionSignature(REFERENCE, new Pure(), CompositionEffect.PURE_FUNCTION, List.of(), List.of(), List.of(),
                "assumption", origin);
    }

    private static FunctionSignature functionSignature(String text) throws Exception {
        Method method = SignatureCompositionWire.class.getDeclaredMethod("functionSignature", WireValue.class, String.class,
                List.class);
        method.setAccessible(true);
        return (FunctionSignature) method.invoke(null, readJson(text), "$", new java.util.ArrayList<>());
    }
}
