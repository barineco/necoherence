// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

public final class LabelsSeparatorTest {
    private static final Path FIXTURE = Path.of("../rust/tests/fixtures/canonical-profile.json");

    private static WireValue labels(String separator) {
        WireValue letters = fields("Identifier", obj("first_alphabet", str("a"), "rest_alphabet", str("a"),
                "exact_length", NIL, "min_length", str("1"), "max_length", str("8"), "forbidden", arr(List.of())));
        return fields("Labels", obj("separator", str(separator), "min_count", str("1"), "max_count", NIL, "total_max", NIL, "rule", letters));
    }

    private static WireValue profileWith(WireValue rule) {
        WireValue profile=f(SemanticLibraryFixture.library(),"profile");
        WireValue reference=f(profile,"reference");
        WireValue binding = obj("name", str("labels"), "reference", reference, "rule", rule);
        List<WireValue> bindings=new java.util.ArrayList<>(a(f(profile,"format_bindings")));bindings.add(binding);
        return TypeSignatures.replace(profile, "format_bindings", arr(bindings));
    }

    @Test void multiCharacterSeparatorSplitsOnTheWholeSeparator() {
        WireValue rule = labels("::");
        assertTrue(SemanticValues.recognize(rule, "a::a"));
        assertFalse(SemanticValues.recognize(rule, "a:a"));
        assertFalse(SemanticValues.recognize(rule, "a:::a"));
    }

    @Test void singleCharacterSeparatorIsUnchanged() {
        WireValue rule = labels(".");
        assertTrue(SemanticValues.recognize(rule, "a.a.a"));
        assertFalse(SemanticValues.recognize(rule, "a..a"));
    }

    @Test void profileWithEmptySeparatorIsRejected() throws Exception {
        assertDoesNotThrow(() -> TypeSignatures.checkProfile(profileWith(labels("::"))));
        assertThrows(SemanticGeneration.GenerationFailure.class, () -> TypeSignatures.checkProfile(profileWith(labels(""))));
    }
}
