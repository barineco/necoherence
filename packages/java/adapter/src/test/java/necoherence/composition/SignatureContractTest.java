// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.lang.reflect.Method;
import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.CompositionEffect;
import necoherence.composition.SemanticComposition.FunctionRef;
import necoherence.composition.SemanticComposition.FunctionSignature;
import necoherence.composition.SemanticComposition.OutcomeContract;
import necoherence.composition.SemanticComposition.OutcomeForm;
import necoherence.composition.SemanticComposition.OutcomeId;
import necoherence.composition.SemanticComposition.Pure;
import necoherence.composition.SemanticComposition.ProductionId;
import necoherence.composition.SemanticComposition.ResourceProduction;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.composition.SignatureCompositionWire.CauseBinding;
import necoherence.semantic.SemanticLibraryFixture;
import necoherence.semantic.SemanticTypes.SourceRef;
import necoherence.semantic.TypeSignatures;
import org.junit.jupiter.api.Test;

final class SignatureContractTest {
    private static final FunctionRef REFERENCE = new FunctionRef("public.operation", "1", "a".repeat(64));

    @SuppressWarnings("unchecked")
    private static Optional<WireValue> signatureContract(List<CauseBinding> causes, FunctionSignature function)
            throws Exception {
        Method method = SignatureCompositionWire.class.getDeclaredMethod("signatureContract", List.class, FunctionSignature.class);
        method.setAccessible(true);
        return (Optional<WireValue>) method.invoke(null, causes, function);
    }

    private static FunctionSignature producing(OutcomeId outcome) {
        TypeRef token = new TypeRef(new SourceRef("ncoh-type-signatures", "1", "", "", "", Optional.empty()), "number", List.of());
        ResourceProduction production = new ResourceProduction(new ProductionId("p"), token,
                BigInteger.ONE, BigInteger.TWO, "provenance");
        OutcomeContract contract = new OutcomeContract(outcome, OutcomeForm.SUCCESS, List.of(), List.of(production));
        return new FunctionSignature(REFERENCE, new Pure(), CompositionEffect.DATA_ONLY, List.of(), List.of(contract),
                List.of(), "assumption", Optional.empty());
    }

    @Test void producedResourcesAreEncodedWithNaturalNumbersAsText() throws Exception {
        OutcomeId outcome = new OutcomeId("ok");
        WireValue cause = f(SemanticLibraryFixture.library(), "sources");
        FunctionSignature function = producing(outcome);
        WireValue contract = signatureContract(List.of(new CauseBinding(REFERENCE, outcome, cause)), function).orElseThrow();
        WireValue production = a(f(a(f(contract, "outcomes")).get(0), "produced_resources")).get(0);
        assertEquals(str("1"), f(production, "revision"));
        assertEquals(str("2"), f(production, "quantity"));
        assertEquals("DataOnly", tag(f(contract, "effect")));
    }

    @Test void anOutcomeWithoutACauseBindingHasNoContract() throws Exception {
        assertTrue(signatureContract(List.of(), producing(new OutcomeId("ok"))).isEmpty());
    }
}
