// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.List;
import org.junit.jupiter.api.Test;

public final class CanonicalProfileTest {
    private static WireValue profile() {
        return f(SemanticLibraryFixture.library(), "profile");
    }

    private static WireValue admit(WireValue profile) throws Exception {
        byte[] bytes = encodeWire(profile).getBytes(StandardCharsets.UTF_8);
        return TypeSignatures.admitCanonicalProfile(f(profile, "reference"), a(f(profile, "source_refs")), bytes, bytes);
    }

    @Test void canonicalProfileRoundtripPreservesTheTypedDeclaration() throws Exception {
        WireValue profile = profile();
        assertEquals(profile, admit(profile));
        assertEquals(encodeWire(profile), encodeWire(admit(profile)));
    }

    @Test void callerBindingsAndExactFieldsAreChecked() {
        WireValue profile = profile();
        byte[] bytes = encodeWire(profile).getBytes(StandardCharsets.UTF_8);
        WireValue other = TypeSignatures.replace(f(profile, "reference"), "revision", str("other"));
        assertThrows(GenerationFailure.class,
                () -> TypeSignatures.admitCanonicalProfile(other, List.of(), bytes, bytes));
        byte[] changed = (encodeWire(profile) + " ").getBytes(StandardCharsets.UTF_8);
        assertThrows(GenerationFailure.class,
                () -> TypeSignatures.admitCanonicalProfile(f(profile, "reference"), List.of(), bytes, changed));
    }

    @Test void profilePredicatesReturnStableIdentifiers() {
        WireValue profile = profile();
        WireValue emptyReference = TypeSignatures.replace(f(profile, "reference"), "identity", str(""));
        GenerationFailure pr01 = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.checkWireProfile(TypeSignatures.replace(profile, "reference", emptyReference)));
        assertEquals("PR01", pr01.condition());
        WireValue duplicate = arr(List.of(a(f(profile, "integer_domains")).getFirst(),
                a(f(profile, "integer_domains")).getFirst()));
        GenerationFailure pr02 = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.checkWireProfile(TypeSignatures.replace(profile, "integer_domains", duplicate)));
        assertEquals("PR02", pr02.condition());
    }

    @Test void textAndNegationFormatRulesRemainGeneral() throws Exception {
        WireValue reference = f(profile(), "reference");
        WireValue binding = obj("name", str("not-x"), "reference", reference,
                "rule", variant("Not", variant("Literal", str("x"))));
        java.util.ArrayList<WireValue> bindings=new java.util.ArrayList<>(a(f(profile(),"format_bindings")));
        bindings.add(binding);
        WireValue checked = TypeSignatures.replace(profile(), "format_bindings", arr(bindings));
        assertDoesNotThrow(() -> TypeSignatures.checkWireProfile(checked));
        assertFalse(SemanticGraphWire.formatAccepts(Optional.empty(), f(binding, "rule"), "x"));
        assertTrue(SemanticGraphWire.formatAccepts(Optional.empty(), f(binding, "rule"), "y"));
        assertTrue(SemanticGraphWire.formatAccepts(Optional.empty(), variant("Text"), "any text"));
        assertEquals(checked, admit(checked));
    }

    private static GenerationFailure profileTextFailure(String text) {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        WireValue reference = obj("identity", str("profile"), "revision", str("4"), "content_digest", str("a".repeat(64)));
        return assertThrows(GenerationFailure.class, () -> TypeSignatures.admitCanonicalProfile(reference, List.of(), bytes, bytes));
    }

    @Test void profileTextRejectsAnExponentAtTheLimitBeforeTheParse() {
        assertEquals(new WireFailure.Syntax("$", "exponent too large"), profileTextFailure("1e10000").wireFailure());
    }

    @Test void profileTextRejectsLoneSurrogateEscapes() {
        assertEquals(new WireFailure.Syntax("$", "unpaired Unicode surrogate"), profileTextFailure("\"\\uD800\"").wireFailure());
        assertEquals(new WireFailure.Syntax("$", "unpaired Unicode surrogate"), profileTextFailure("\"\\uDC00\"").wireFailure());
    }

    @Test void profileTextAdmitsASurrogatePairBeforeTheStructureCheck() {
        GenerationFailure failure = profileTextFailure("\"\\uD83D\\uDE00\"");
        assertNull(failure.wireFailure());
        assertEquals("object", failure.condition());
    }
}
