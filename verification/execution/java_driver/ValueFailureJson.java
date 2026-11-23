// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.comparison;

import static necoherence.composition.SemanticComposition.*;
import static necoherence.semantic.SemanticValues.*;

import java.util.List;
import necoherence.composition.SemanticComposition.PathStep;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticGraphWire;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.WireJson;
import necoherence.semantic.SemanticValues.WireValue;

public final class ValueFailureJson {
    private ValueFailureJson() {}

    public static WireValue render(SemanticValidation.ValidationFailure failure) {
        if (failure instanceof SemanticValidation.ValueRejected value)
            return nested("value", value(new SemanticValues.ValueRejection(value.failure())));
        if (failure instanceof SemanticValidation.ValidationUnresolved value)
            return nested("unresolved", arr(value.obligations().stream().map(SemanticGraphWire::obligationWire).map(ValueFailureJson::obligation).toList()));
        return nested("certificateMismatch", str(((SemanticValidation.CertificateMismatch) failure).condition()));
    }

    private static WireValue value(SemanticValues.ValueRejection failure) {
        WireValue reference = failure.typeRef();
        WireValue source = f(reference, "source");
        WireValue origin = failure.origin();
        WireValue observed = switch (failure.observed()) {
            case Absent<JsonValue> unused -> variant("Absent");
            case NullSlot<JsonValue> unused -> variant("Null");
            case Present<JsonValue> present -> variant("Present", SemanticGeneration.toExact(WireJson.toWire(present.value())));
        };
        return obj("typeRef", type(reference),
                "definitionRef", obj("source", source(source), "name", str(failure.definition())),
                "origin", obj("source", source(f(origin, "source")), "pointer", f(origin, "pointer")),
                "valuePath", path(failure.path().stream().map(step -> switch (s(f(step, "tag"))) {
                    case "Field" -> (PathStep) new Field(s(payload(step)));
                    case "Index" -> new Index(n(payload(step)));
                    default -> new Variant(s(payload(step)));
                }).toList()),
                "condition", condition(failure.condition()), "observed", observed,
                "referenceTrace", arr(failure.referenceTrace().stream().map(ValueFailureJson::type).toList()));
    }

    private static WireValue reason(WireValue reason) {
        String tag = s(f(reason, "tag"));
        String constructor = Character.toLowerCase(tag.charAt(0)) + tag.substring(1);
        return switch (tag) {
            case "UnknownFormat", "UnknownIntegerDomain", "UnknownWrapper", "WrapperPayload",
                    "UnknownSealedTag", "OpaqueType", "UninterpretedExtension", "InvalidProfile",
                    "CertificateMismatch", "ProjectionUnavailable" -> nested(constructor, payload(reason));
            default -> nested(constructor);
        };
    }

    private static WireValue obligation(WireValue obligation) {
        return obj("typeRef", type(f(obligation, "type_ref")),
                "valuePath", path(a(f(obligation, "value_path")).stream().map(step -> switch (s(f(step, "tag"))) {
                    case "Field" -> (PathStep) new Field(s(payload(step)));
                    case "Index" -> new Index(n(payload(step)));
                    default -> new Variant(s(payload(step)));
                }).toList()),
                "reason", reason(f(obligation, "reason")));
    }

    private static WireValue source(WireValue source) {
        return obj("repository", f(source, "repository"), "revision", f(source, "revision"),
                "path", f(source, "path"), "contentDigest", f(source, "content_digest"),
                "documentId", f(source, "document_id"), "declaredRevision", f(source, "declared_revision"));
    }

    private static WireValue type(WireValue reference) {
        return obj("source", source(f(reference, "source")),
                "definition", f(reference, "definition_name"), "pointer", f(reference, "pointer"));
    }

    private static WireValue condition(SemanticValues.ValueCondition condition) {
        String tag = SemanticValues.valueConditionTag(condition);
        return SemanticValues.valueConditionArgument(condition)
                .map(argument -> variant(tag, str(argument))).orElseGet(() -> variant(tag));
    }

    private static WireValue path(List<PathStep> path) {
        return arr(path.stream().map(step -> {
            if (step instanceof Field value) return obj("field", str(value.wireName()));
            if (step instanceof Index value) return obj("index", num(value.index()));
            return obj("variant", str(((Variant) step).wireTag()));
        }).toList());
    }

    private static WireValue nested(String constructor, WireValue... arguments) {
        return obj("constructor", str(constructor), "arguments", arr(List.of(arguments)));
    }
}
