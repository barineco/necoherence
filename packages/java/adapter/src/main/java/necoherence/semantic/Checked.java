// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Objects;
import java.util.Set;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.WireValue;

/**
 * A wire value that a {@link SemanticValues.Context} has validated against a type, with that context and that type's reference.
 * Only the context builds one, so holding one means that the validation has run.
 */
public final class Checked {
    private final SemanticValues.Context context;
    private final WireValue reference;
    private final SemanticValues.Slot<WireValue> slot;
    private final Set<WireValue> parts;

    Checked(SemanticValues.Context context, WireValue reference, SemanticValues.Slot<WireValue> slot) {
        this.context = Objects.requireNonNull(context);
        this.reference = Objects.requireNonNull(reference);
        this.slot = Objects.requireNonNull(slot);
        Set<WireValue> found = Collections.newSetFromMap(new IdentityHashMap<>());
        if (slot instanceof SemanticValues.Present<WireValue> present) collect(present.value(), found);
        this.parts = found;
    }

    SemanticValues.Context context() { return context; }

    /** The reference of the type that validated the value. */
    public WireValue reference() { return reference; }

    /** The validated value. A checked slot that is absent or null has none, and the call fails. */
    public WireValue value() {
        if (slot instanceof SemanticValues.Present<WireValue> present) return present.value();
        throw new IllegalStateException("The checked slot holds no value");
    }

    /** Whether the object is the value or one of the values inside it. The comparison is by identity. */
    boolean contains(WireValue part) {
        return parts.contains(part);
    }

    private static void collect(WireValue value, Set<WireValue> found) {
        if (!found.add(value)) return;
        if (value instanceof ArrayValue array) for (WireValue item : array.items()) collect(item, found);
        else if (value instanceof ObjectValue object) for (Member member : object.members()) collect(member.value(), found);
    }
}
