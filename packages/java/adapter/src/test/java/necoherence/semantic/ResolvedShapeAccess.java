// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.f;
import static necoherence.semantic.SemanticValues.payload;
import static necoherence.semantic.SemanticValues.tag;

import java.util.HashSet;
import java.util.Set;
import necoherence.semantic.SemanticValues.Context;
import necoherence.semantic.SemanticValues.WireValue;

final class ResolvedShapeAccess {
    private ResolvedShapeAccess() {}

    static WireValue resolve(Context context, WireValue reference) {
        Set<WireValue> seen = new HashSet<>();
        while (seen.add(reference)) {
            WireValue shape = SemanticGraphWire.shapeWire(context.typed().nodes().get(context.index(reference)).shape());
            if (!tag(shape).equals("Alias")) return shape;
            reference = f(payload(shape), "target");
        }
        return null;
    }
}
