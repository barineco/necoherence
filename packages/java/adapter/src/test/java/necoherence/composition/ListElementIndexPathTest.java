// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;
import java.util.List;
import necoherence.composition.CompositionPlanWire.DecodeRejection;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure;
import org.junit.jupiter.api.Test;

final class ListElementIndexPathTest {
    @Test void unknownFieldInSecondListElementReportsItsIndex() {
        WireValue outer = obj("items", arr(List.of(obj("ok", str("1")), obj("ok", str("2"), "note", str("x")))));
        DecodeRejection rejection = assertThrows(DecodeRejection.class, () -> WireDecode.getList(outer, "items", element -> {
            if (element instanceof necoherence.semantic.SemanticValues.ObjectValue object && object.get("note") != null) throw new DecodeRejection(new WireFailure.UnknownField("$.note", "note"));
            return element;
        }));
        assertEquals("$.items[1].note", rejection.failure().path());
    }

    @Test void directArrayReadFailureOfAnElementIsNotIndexed() {
        WireValue outer = obj("items", arr(List.of(obj("ok", str("1")), obj("ok", str("2"), "note", str("x")))));
        DecodeRejection rejection = assertThrows(DecodeRejection.class, () -> WireDecode.listProp(outer, "items", element -> {
            if (element instanceof necoherence.semantic.SemanticValues.ObjectValue object && object.get("note") != null) throw new DecodeRejection(new WireFailure.UnknownField("$.note", "note"));
            return element;
        }));
        assertEquals("$.note", rejection.failure().path());
    }
}
