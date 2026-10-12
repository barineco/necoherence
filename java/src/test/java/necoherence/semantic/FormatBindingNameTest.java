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

public final class FormatBindingNameTest {
    private static final Path FIXTURE = Path.of("../rust/tests/fixtures/canonical-profile.json");

    private static WireValue profileWithNames(String... names) {
        WireValue profile=f(SemanticLibraryFixture.library(),"profile"),expected=f(profile,"reference");
        List<WireValue> bindings = new java.util.ArrayList<>();
        for (String name : names) bindings.add(obj("name", str(name), "reference", expected, "rule", variant("Literal", str("x"))));
        return TypeSignatures.replace(profile, "format_bindings", arr(bindings));
    }

    @Test void profileWithEmptyFormatBindingNameIsRejected() {
        assertThrows(SemanticGeneration.GenerationFailure.class, () -> TypeSignatures.checkProfile(profileWithNames("")));
    }

    @Test void profileWithDuplicateFormatBindingNameIsRejected() throws Exception {
        assertThrows(SemanticGeneration.GenerationFailure.class, () -> TypeSignatures.checkProfile(profileWithNames("same", "same")));
    }
}
