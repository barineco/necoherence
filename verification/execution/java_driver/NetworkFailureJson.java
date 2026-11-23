// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.comparison;

import static necoherence.semantic.SemanticValues.*;

import java.lang.reflect.RecordComponent;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.core.Nat;
import necoherence.network.NetworkEffect;
import necoherence.semantic.SemanticValues.WireValue;

public final class NetworkFailureJson {
    private NetworkFailureJson() {}

    public static WireValue render(NetworkEffect.NetworkFailure failure) {
        return tagged(failure);
    }

    private static WireValue tagged(Object value) {
        List<Object> fields = new ArrayList<>();
        fields.add("tag");
        fields.add(str(tagName(value)));
        for (RecordComponent component : value.getClass().getRecordComponents()) {
            fields.add(fieldName(value, component.getName()));
            fields.add(member(value, component));
        }
        return obj(fields.toArray());
    }

    private static WireValue member(Object owner, RecordComponent component) {
        try {
            return value(component.getAccessor().invoke(owner));
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException(failure);
        }
    }

    private static WireValue value(Object value) {
        if (value == null || value instanceof Optional<?> optional && optional.isEmpty()) return NIL;
        if (value instanceof Optional<?> optional) return value(optional.get());
        if (value instanceof String text) return str(text);
        if (value instanceof Integer number) return num(BigInteger.valueOf(number));
        if (value instanceof BigInteger number) return num(number);
        if (value instanceof Nat number) return num(new BigInteger(number.toString()));
        if (value instanceof List<?> values) return arr(values.stream().map(NetworkFailureJson::value).toList());
        if (value instanceof NetworkEffect.AttemptCondition || value instanceof NetworkEffect.AttemptTokenField
                || value instanceof NetworkEffect.ObservationField || value instanceof NetworkEffect.CapabilityKind)
            return str(enumName((Enum<?>) value));
        if (value instanceof Enum<?> item) return obj("tag", str(enumName(item)));
        if (value instanceof NetworkEffect.SourceSequence.None) return NIL;
        if (value instanceof NetworkEffect.SourceSequence.Some item) return value(item.ordinal());
        if (isTagged(value)) return tagged(value);
        if (value.getClass().isRecord()) {
            List<Object> fields = new ArrayList<>();
            for (RecordComponent component : value.getClass().getRecordComponents()) {
                fields.add(fieldName(value, component.getName()));
                fields.add(member(value, component));
            }
            return obj(fields.toArray());
        }
        throw new IllegalArgumentException(value.getClass().getName());
    }

    private static boolean isTagged(Object value) {
        return value instanceof NetworkEffect.NetworkStateViolation
                || value instanceof NetworkEffect.AdapterObservation
                || value instanceof NetworkEffect.HostFailure
                || value instanceof NetworkEffect.EffectStatus
                || value instanceof NetworkEffect.NetworkOutcome
                || value instanceof NetworkEffect.AttemptChain;
    }

    private static String tagName(Object value) {
        String name = value.getClass().getSimpleName();
        return switch (name) {
            case "None" -> "none";
            case "Some" -> "some";
            default -> name;
        };
    }

    private static String enumName(Enum<?> value) {
        return switch (value.name()) {
            case "DeadlineField" -> "Deadline";
            case "CancellationCapabilityKind" -> "Cancellation";
            default -> value.name();
        };
    }

    private static String fieldName(Object owner, String name) {
        if (owner instanceof NetworkEffect.NetworkFailure.DeadlineNotReached && name.equals("observed")) return "observedAt";
        if (owner instanceof NetworkEffect.NetworkFailure.ConflictingDelivery && name.equals("oldObservation")) return "old";
        if (owner instanceof NetworkEffect.NetworkFailure.ConflictingDelivery && name.equals("newObservation")) return "fresh";
        if (owner instanceof NetworkEffect.NetworkFailure.RetryOrderViolation && name.equals("parent")) return "expected";
        if (owner instanceof NetworkEffect.NetworkFailure.RetryOrderViolation && name.equals("next")) return "actual";
        if (owner instanceof NetworkEffect.AdapterObservation && name.equals("source")) return "sourceSequence";
        if (owner instanceof NetworkEffect.AdapterObservation.DeadlineObservation && name.equals("observed")) return "observedAt";
        return name;
    }
}
