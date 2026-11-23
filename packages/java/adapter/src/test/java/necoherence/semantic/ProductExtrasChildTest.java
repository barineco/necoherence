// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticTypes.*;
import org.junit.jupiter.api.Test;

final class ProductExtrasChildTest {
    @Test void allowedExtrasValueTypeIsAChildOfTheProduct() {
        WireValue source = obj("repository", str("synthetic"), "revision", str("1"), "path", str("types"),
                "content_digest", str("a".repeat(64)), "document_id", str("d"), "declared_revision", NIL);
        TypeRef child = SemanticGraphWire.typeRef(obj("source", source, "definition_name", str("value"), "pointer", arr(List.of())), "$");
        ProductShape shape = new ProductShape(new ProductSpec(List.of(),
                new AllowExtras(Optional.empty(), new ElementContract(child, false))));
        assertEquals(List.of(child), SemanticTypes.typeChildren(shape));
    }

    @Test void rejectedExtrasProductHasNoExtrasChild() {
        ProductShape shape = new ProductShape(new ProductSpec(List.of(), new RejectExtras()));
        assertEquals(List.of(), SemanticTypes.typeChildren(shape));
    }
}
