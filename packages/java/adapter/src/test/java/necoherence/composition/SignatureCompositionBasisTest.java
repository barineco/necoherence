// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.ArrayList;
import java.util.List;
import necoherence.semantic.SemanticLibraryFixture;
import necoherence.semantic.TypeSignatures;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

final class SignatureCompositionBasisTest {
    private static WireValue problemWith(WireValue basis) {
        return obj("identity", NIL, "revision", NIL, "basis", basis, "signatures", NIL, "initial_inputs", NIL,
                "initial_resources", NIL, "goal", NIL, "invocation_domain", NIL, "allowed_effects", NIL,
                "explicit_order", NIL, "selection_policy", NIL, "bounds", NIL);
    }

    private static WireValue basisFor(WireValue library) {
        return TypeSignatures.computeBasis(library, arr(List.of()), NIL);
    }

    @Test void basisExtraKeyIsAnUnknownFieldBelowTheBasisPath() {
        WireValue library = SemanticLibraryFixture.library();
        List<Member> members = new ArrayList<>(((ObjectValue) basisFor(library)).members());
        members.add(new Member("extra", NIL));
        WireException failure = assertThrows(WireException.class,
                () -> SignatureCompositionWire.decodeProblem(library, problemWith(new ObjectValue(members))));
        assertEquals(new UnknownField("$.basis.extra", "extra"), failure.failure());
    }

    @Test void basisMissingKeyIsASyntaxFailureBelowTheBasisPath() {
        WireValue library = SemanticLibraryFixture.library();
        List<Member> members = new ArrayList<>(((ObjectValue) basisFor(library)).members());
        members.removeIf(member -> member.key().equals("graph_sha256"));
        WireException failure = assertThrows(WireException.class,
                () -> SignatureCompositionWire.decodeProblem(library, problemWith(new ObjectValue(members))));
        assertEquals(new Syntax("$.basis.graph_sha256", "missing field"), failure.failure());
    }

    @Test void basisOfAnotherLibraryIsAMismatch() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue other = SemanticLibraryFixture.replace(library, "identity", str("other"));
        WireException failure = assertThrows(WireException.class,
                () -> SignatureCompositionWire.decodeProblem(library, problemWith(basisFor(other))));
        assertEquals(new Syntax("$.basis", "composition signature basis mismatch"), failure.failure());
    }
}
