// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;
import java.util.List;
import org.junit.jupiter.api.Test;

final class ProducedResourceIdentityTest {
    private static WireValue resource(String id) {
        return obj("id", str(id), "token_type", str("number"), "revision", str("0"), "quantity", str("1"), "provenance", str("p"));
    }

    private static WireValue libraryWithResources(List<WireValue> resources) {
        WireValue outcome = SemanticLibraryFixture.replace(SemanticLibraryFixture.outcome("ok", false), "produced_resources", arr(resources));
        WireValue operation = obj("effect", variant("HttpRequestResponse"), "inputs", arr(List.of()),
                "outcomes", arr(List.of(outcome, SemanticLibraryFixture.outcome("denied", true))));
        WireValue definitions = arr(List.of(
                obj("id", str("data"), "wire_identity", str("public.data"), "shape", variant("Value", str("product"))),
                obj("id", str("op"), "wire_identity", str("public.operation"), "shape", variant("Operation", operation))));
        return SemanticLibraryFixture.replace(SemanticLibraryFixture.library(), "definitions", definitions);
    }

    @Test void distinctProducedResourceIdentitiesAreAccepted() throws Exception {
        TypeSignatures.checkLibrary(libraryWithResources(List.of(resource("a"), resource("b"))));
    }

    @Test void duplicateProducedResourceIdentityIsALibraryDeclarationFailure() {
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.checkLibrary(libraryWithResources(List.of(resource("a"), resource("a")))));
        assertEquals("LB01", failure.condition());
        assertNotNull(failure.observed());
    }
}
