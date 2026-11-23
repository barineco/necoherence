// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.NIL;
import static necoherence.semantic.SemanticValues.arr;
import static necoherence.semantic.SemanticValues.fields;
import static necoherence.semantic.SemanticValues.obj;
import static necoherence.semantic.SemanticValues.str;
import static necoherence.semantic.SemanticValues.variant;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.TypeSignatures;
import org.junit.jupiter.api.Test;

class SignatureCompositionWireCauseTest {
    private static final List<WireValue> SOURCES = List.of(source());

    @Test
    void valueContractCauseNamingALibrarySourceIsValid() {
        assertEquals(true, TypeSignatures.outcomeValid(outcome("Success", cause("ValueContract", "origin", source()), port("value"), List.of()), SOURCES));
    }

    @Test
    void causeSourceOutsideTheLibraryIsInvalid() {
        WireValue other = TypeSignatures.replace(source(), "revision", str("2"));
        assertEquals(false, TypeSignatures.outcomeValid(outcome("Success", cause("ValueContract", "origin", other), port("value"), List.of()), SOURCES));
    }

    @Test
    void causeSourceIsComparedWithoutRegardToTheKeyOrder() {
        WireValue reordered = obj("content_digest", str("a".repeat(64)), "path", str("type-signatures.md"),
                "revision", str("1"), "repository", str("ncoh-type-signatures"));
        assertEquals(true, TypeSignatures.outcomeValid(outcome("Success", cause("ValueContract", "origin", reordered), port("value"), List.of()), SOURCES));
    }

    @Test
    void externalConditionNeedsADeclaredFailureWithAValuePort() {
        WireValue external = cause("ExternalCondition", "specification", source());
        assertEquals(true, TypeSignatures.outcomeValid(outcome("DeclaredFailure", external, port("value"), List.of()), SOURCES));
        assertEquals(false, TypeSignatures.outcomeValid(outcome("Success", external, port("value"), List.of()), SOURCES));
        assertEquals(false, TypeSignatures.outcomeValid(outcome("DeclaredFailure", external, List.of(), List.of()), SOURCES));
    }

    @Test
    void valuePortAndProducedResourceIdentitiesAreUniqueAndNotEmpty() {
        WireValue cause = cause("ValueContract", "origin", source());
        WireValue production = obj("id", str("p"), "token_type", str("t"), "revision", str("0"), "quantity", str("1"), "provenance", str("x"));
        assertEquals(false, TypeSignatures.outcomeValid(outcome("Success", cause, port("value", "value"), List.of()), SOURCES));
        assertEquals(false, TypeSignatures.outcomeValid(outcome("Success", cause, port(""), List.of()), SOURCES));
        assertEquals(false, TypeSignatures.outcomeValid(outcome("Success", cause, port("value"), List.of(production, production)), SOURCES));
        assertEquals(true, TypeSignatures.outcomeValid(outcome("Success", cause, port("value"), List.of(production)), SOURCES));
    }

    private static WireValue outcome(String form, WireValue cause, List<WireValue> ports, List<WireValue> productions) {
        return obj("id", str("o"), "form", variant(form), "cause", cause, "value_ports", arr(ports),
                "produced_resources", arr(productions));
    }

    private static List<WireValue> port(String... identities) {
        return java.util.Arrays.stream(identities).map(identity -> obj("id", str(identity), "contract", NIL)).toList();
    }

    private static WireValue cause(String tag, String member, WireValue source) {
        return fields(tag, obj(member, obj("source", source, "locator", arr(List.of()))));
    }

    private static WireValue source() {
        return obj("repository", str("ncoh-type-signatures"), "revision", str("1"), "path", str("type-signatures.md"),
                "content_digest", str("a".repeat(64)));
    }
}
