// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticValidation.DefaultedValue;
import necoherence.semantic.SemanticValidation.Except;
import org.junit.jupiter.api.Test;

final class NestedJsonDepthTest {
    private static final int SHALLOW = 1000;
    private static final int DEEP = 10000;
    private static final WireValue SOURCE = obj("repository", str("r"), "revision", str("1"), "path", str("p"),
            "content_digest", str("0".repeat(64)), "document_id", str("d"), "declared_revision", NIL);
    private static final ProfileRef PROFILE = new ProfileRef("profile", "1", "0".repeat(64));
    private static final OccurrenceRef ORIGIN = new OccurrenceRef(SemanticGraphWire.sourceRef(SOURCE, "$"), List.of());

    private static TypeRef ref(String name) { return new TypeRef(SemanticGraphWire.sourceRef(SOURCE, "$"), name, List.of()); }

    private static TypeNode node(String name, TypeShape shape) {
        return new TypeNode(ref(name), shape, Optional.empty(), List.of(), List.of());
    }

    private static SemanticGraph graph(TypeNode... nodes) {
        VersionedSemanticProfile profile = new VersionedSemanticProfile(PROFILE, List.of(), List.of(
                new IntegerDomainBinding("numbers", PROFILE, new UnboundedDomain(), List.of(IntegerForm.NUMBER))),
                "numbers", new NumberModel(false), Optional.empty(), List.of(), Optional.empty(), List.of(), Optional.empty());
        return new SemanticGraph(profile, List.of(nodes), List.of());
    }

    /** A recursive array type: {@code list = [list]}. */
    private static SemanticGraph recursiveArrayGraph() {
        return graph(node("list", new ArrayShape(new ArraySpec(new ElementContract(ref("list"), false), Optional.empty(), Optional.empty()))));
    }

    /** A recursive product type: {@code node = { child?: node }}, with the extra members rejected. */
    private static SemanticGraph recursiveProductGraph() {
        FieldSpec child = new FieldSpec("child", new SlotContract(ref("node"), false, false), ORIGIN);
        return graph(node("node", new ProductShape(new ProductSpec(List.of(child), new RejectExtras()))));
    }

    private static SemanticGraph unknownGraph() {
        return graph(node("any", new UnknownShape(UnknownKind.ANY)));
    }

    private static String nestedArrays(int depth) { return "[".repeat(depth) + "]".repeat(depth); }

    private static String nestedObjects(int depth) { return "{\"child\":".repeat(depth) + "{}" + "}".repeat(depth); }

    private static JsonValue parsed(String text) { return WireJson.fromWire(SemanticGeneration.readJson(text)); }

    private static <T> T accepted(Except<T> result) {
        if (result instanceof SemanticValidation.Ok<T> ok) return ok.value();
        throw new AssertionError("rejected: " + result);
    }

    @Test
    void nestedArraysAreReadWithTheirSize() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            assertEquals(BigInteger.valueOf(depth), SemanticValidation.jsonSize(parsed(nestedArrays(depth))));
        }
    }

    @Test
    void nestedObjectsAreReadWithTheirSize() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            assertEquals(BigInteger.valueOf(depth + 1L), SemanticValidation.jsonSize(parsed(nestedObjects(depth))));
        }
    }

    @Test
    void nestedValuesAreParsedByTheWireReaderAtBothDepths() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            assertEquals(BigInteger.valueOf(depth), SemanticValidation.jsonSize(WireJson.fromWire(TypeSignatures.parseWire(nestedArrays(depth)))));
        }
    }

    @Test
    void nestedValuesAreEncodedBackToTheirText() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            assertEquals(nestedArrays(depth), ExactJson.encode(parsed(nestedArrays(depth))));
            assertEquals(nestedObjects(depth), ExactJson.encode(parsed(nestedObjects(depth))));
        }
    }

    @Test
    void nestedValuesSurviveTheWireConversionAtBothDepths() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            JsonValue value = parsed(nestedObjects(depth));
            assertEquals(nestedObjects(depth), ExactJson.encode(WireJson.fromWire(WireJson.toWire(value))));
        }
    }

    @Test
    void nestedArraysAreAcceptedByARecursiveArrayType() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            accepted(SemanticValidation.validateValue(new SemanticValues.Context(recursiveArrayGraph()), ref("list"), parsed(nestedArrays(depth)), Optional.empty()));
        }
    }

    @Test
    void nestedObjectsAreAcceptedByARecursiveProductType() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            accepted(SemanticValidation.validateValue(new SemanticValues.Context(recursiveProductGraph()), ref("node"), parsed(nestedObjects(depth)), Optional.empty()));
        }
    }

    @Test
    void nestedValuesAreAcceptedByAnUnknownType() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            accepted(SemanticValidation.validateValue(new SemanticValues.Context(unknownGraph()), ref("any"), parsed(nestedArrays(depth)), Optional.empty()));
            accepted(SemanticValidation.validateValue(new SemanticValues.Context(unknownGraph()), ref("any"), parsed(nestedObjects(depth)), Optional.empty()));
        }
    }

    @Test
    void nestedArraysKeepTheirSizeWhenDefaultsAreMaterialized() {
        for (int depth : new int[] {SHALLOW, DEEP}) {
            DefaultedValue defaulted = accepted(SemanticValidation.materializeDefaults(new SemanticValues.Context(recursiveArrayGraph()), ref("list"), parsed(nestedArrays(depth))));
            assertEquals(List.of(), defaulted.applications());
            assertEquals(BigInteger.valueOf(depth), SemanticValidation.jsonSize(defaulted.value()));
        }
    }
}
