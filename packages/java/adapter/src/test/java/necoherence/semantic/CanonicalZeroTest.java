// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static org.junit.jupiter.api.Assertions.*;

import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.SemanticValues.DecimalValue;
import necoherence.semantic.SemanticValues.IntegerValue;
import necoherence.semantic.SemanticValues.WireValue;
import org.junit.jupiter.api.Test;

/** The Lean fromJson rule of the zero JSON number: the integer when the normalized exponent is zero, otherwise the decimal text 0. */
final class CanonicalZeroTest {
    private static final WireValue SOURCE = SemanticValues.obj("repository", SemanticValues.str("r"), "revision", SemanticValues.str("1"),
            "path", SemanticValues.str("p"), "content_digest", SemanticValues.str("0".repeat(64)), "document_id", SemanticValues.str("d"),
            "declared_revision", SemanticValues.NIL);
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

    @Test void zeroWithLargeExponentIsWrittenAsTheLeanNumberTextZero() {
        assertEquals("0.0", SemanticValues.encodeWire(new DecimalValue("0e11")));
    }

    @Test void zeroWithFractionDigitsIsWrittenAsTheLeanNumberTextZero() {
        assertEquals("0.0", SemanticValues.encodeWire(new DecimalValue("0.000")));
    }

    @Test void nonzeroDecimalKeepsItsSpelling() {
        assertEquals("1.5", SemanticValues.encodeWire(new DecimalValue("1.5")));
    }

    @Test void zeroWithAFractionOrANegativeExponentReadsAsTheDecimalZeroText() {
        for (String spelling : List.of("0.0", "0e-100", "0.000e-100", "-0.0"))
            assertEquals(new DecimalValue("0"), SemanticGeneration.readJson(spelling), spelling);
    }

    @Test void zeroWithoutANormalizedExponentReadsAsTheIntegerZero() {
        for (String spelling : List.of("0", "-0", "0e11"))
            assertEquals(new IntegerValue(BigInteger.ZERO), SemanticGeneration.readJson(spelling), spelling);
    }

    @Test void zeroDecimalReadFromJsonIsAcceptedByTheDecimalSlot() {
        SemanticGraph graph = decimalGraph();
        for (String spelling : List.of("0.0", "0e-100", "0.000e-100"))
            assertInstanceOf(SemanticValidation.Ok.class,
                    SemanticValidation.validateValue(new SemanticValues.Context(graph), DECIMAL, WireJson.fromWire(SemanticGeneration.readJson(spelling)), Optional.empty()), spelling);
    }
}
