// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticGraphWire;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.SemanticValidation.Ok;
import necoherence.semantic.WireJson;
import org.junit.jupiter.api.Test;

/** The tagged decimal decoder of the production path, which the Lean {@code decodeExact} keeps as the decimal text. */
final class SignatureCompositionWireExactZeroTest {
    private static final WireValue SOURCE = obj("repository", str("r"), "revision", str("1"), "path", str("p"),
            "content_digest", str("0".repeat(64)), "document_id", str("d"), "declared_revision", NIL);
    private static final ProfileRef PROFILE = new ProfileRef("profile", "1", "0".repeat(64));
    private static final TypeRef DECIMAL = new TypeRef(SemanticGraphWire.sourceRef(SOURCE, "$"), "decimal", List.of());

    private static SemanticGraph decimalGraph() {
        VersionedSemanticProfile profile = new VersionedSemanticProfile(PROFILE, List.of(),
                List.of(new IntegerDomainBinding("numbers", PROFILE, new UnboundedDomain(), List.of(IntegerForm.NUMBER))),
                "numbers", new NumberModel(true), Optional.empty(), List.of(), Optional.empty(), List.of(), Optional.empty());
        TypeNode node = new TypeNode(DECIMAL, new DecimalShape(new DecimalSpec(Optional.empty(), Optional.empty())),
                Optional.empty(), List.of(), List.of());
        return new SemanticGraph(profile, List.of(node), List.of());
    }

    private static WireValue tagged(String spelling) {
        return obj("tag", str("Decimal"), "text", str(spelling));
    }

    @Test void taggedDecimalZeroSpellingsKeepTheirTextAsTheDecimalForm() throws Exception {
        for (String spelling : List.of("0.0", "0e-100", "0.000e-100"))
            assertEquals(new DecimalValue(spelling), SignatureCompositionWire.exact(tagged(spelling), "$"), spelling);
    }

    @Test void taggedDecimalZeroIsAcceptedByTheDecimalSlot() throws Exception {
        SemanticGraph graph = decimalGraph();
        necoherence.semantic.SemanticValues.Context context = new necoherence.semantic.SemanticValues.Context(graph);
        for (String spelling : List.of("0.0", "0e-100", "0.000e-100", "1.5")) {
            WireValue value = SignatureCompositionWire.exact(tagged(spelling), "$");
            assertInstanceOf(Ok.class, SemanticValidation.validateValue(context, DECIMAL, WireJson.fromWire(value), Optional.empty()), spelling);
        }
    }

    @Test void taggedEncodingOfDecimalZeroRoundTripsItsText() throws Exception {
        WireValue value = new DecimalValue("0.0");
        assertEquals(value, SignatureCompositionWire.exact(SemanticGeneration.toExact(value), "$"));
    }
}
