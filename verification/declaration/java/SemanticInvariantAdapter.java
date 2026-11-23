// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.comparison;

import neco.quotient.RefinementOutcome;
import neco.quotient.ResidualSet;
import neco.quotient.Result;
import necoherence.semantic.SemanticGraphWire;
import necoherence.semantic.SemanticResidualRecord;
import necoherence.semantic.SemanticTypes;
import necoherence.semantic.SemanticTypes.ReasonDisposition;
import necoherence.semantic.TypeSignatures;
import necoherence.semantic.WireFailure;
import necoherence.semantic.WireJson;
import necoherence.semantic.WireFailure.WireException;
import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public final class SemanticInvariantAdapter {
    private WireValue cachedLibrary;
    private CheckedGeneration cachedGeneration;

    private CheckedGeneration generation(WireValue library) throws GenerationFailure {
        if (library.equals(cachedLibrary)) return cachedGeneration;
        WireValue entries = arr(a(f(library, "definitions")).stream()
                .map(definition -> obj("identity", f(definition, "id"), "definition", f(definition, "id"))).toList());
        String libraryText = encodeWire(library);
        TypeSignatures.TypeSignatureLibrary.decode(libraryText);
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        WireValue exchange = obj("schema", str("ncoh-checked-generation@5"), "basis", basis.value,
                "signatures", library, "entrypoints", entries, "composition", NIL);
        CheckedGeneration checked = TypeSignatures.admitGeneration(basis, encodeWire(exchange));
        cachedLibrary = library;
        cachedGeneration = checked;
        return checked;
    }

    private static WireValue typeReference(WireValue input) { return TypeSignatures.typeReference(s(f(input, "type_id"))); }

    private static WireValue path(Context context, WireValue reference, WireValue value, ValueRejection failure) {
        return arr(failure.path().stream().map(step -> tag(step).equals("Index") ? num(n(payload(step))) : payload(step)).toList());
    }

    private static WireValue condition(ValueRejection failure) {
        String tag = valueConditionTag(failure.condition());
        return str(valueConditionArgument(failure.condition()).map(argument -> tag + ":" + argument).orElse(tag));
    }

    private static WireValue declarationFailure(WireValue id, GenerationFailure failure) {
        String predicate = failure.condition();
        String location = predicate.startsWith("PR") ? "profile" : "library";
        return obj("id", id, "status", str("Rejected"), "predicate", str(predicate),
                "path", arr(List.of(str(location))));
    }

    private record WireClassification(String status, List<WireValue> obligations, List<WireValue> residuals,
            List<WireValue> stops, List<WireValue> failures, WireValue provenance) {}
    private record ClassifiedObligation(WireValue obligation, ReasonDisposition disposition) {}

    private static WireValue typedProvenance(SemanticTypes.EvaluationProvenance provenance) {
        return obj("operation", str(provenance.operation()), "type_ref", SemanticGraphWire.typeRefWire(provenance.typeRef()),
                "value_path", arr(provenance.valuePath().stream().map(SemanticGraphWire::pathStepWire).toList()));
    }

    private record EvaluationSummary(String status, SemanticTypes.EvaluationProvenance provenance,
            List<SemanticTypes.SemanticObligation> residuals) {}

    private static EvaluationSummary summarize(Result<RefinementOutcome<SemanticTypes.SemanticJudgment,
            SemanticTypes.SemanticObligation, List<SemanticTypes.SemanticObligation>>,
            SemanticTypes.SemanticDecisionFailure> evaluation) {
        return switch (evaluation) {
            case Result.Accepted(RefinementOutcome.Resolved(var judgment)) ->
                new EvaluationSummary("Resolved", judgment.provenance(), List.of());
            case Result.Accepted(RefinementOutcome.Residual(var judgment, var residuals)) ->
                new EvaluationSummary("Residual", judgment.provenance(), residuals.values());
            case Result.Accepted(RefinementOutcome.Stopped(var judgment, var residuals, var cause)) ->
                new EvaluationSummary("Stopped", judgment.provenance(), residuals.values());
            case Result.Rejected(var failure) ->
                new EvaluationSummary("Failed", failure.provenance(), failure.residuals().values());
        };
    }

    private static WireClassification valueClassification(ValueProcessingFailure failure) {
        EvaluationSummary summary = summarize(failure.evaluation().orElseThrow());
        List<SemanticTypes.SemanticObligation> typed = failure.obligations();
        return new WireClassification(summary.status(), typed.stream().map(SemanticGraphWire::obligationWire).toList(),
                summary.residuals().stream().map(SemanticGraphWire::obligationWire).toList(),
                typed.stream().filter(item -> item.reason().disposition() == ReasonDisposition.STOPPED)
                        .map(SemanticGraphWire::obligationWire).toList(),
                typed.stream().filter(item -> item.reason().disposition() == ReasonDisposition.FAILED)
                        .map(SemanticGraphWire::obligationWire).toList(),
                typedProvenance(summary.provenance()));
    }

    private static boolean sameStructure(WireValue left, WireValue right) {
        if (left instanceof ObjectValue x && right instanceof ObjectValue y) {
            return x.members().size() == y.members().size() && x.members().stream().allMatch(member ->
                    y.members().stream().anyMatch(other -> member.key().equals(other.key()) && sameStructure(member.value(), other.value())));
        }
        if (left instanceof ArrayValue x && right instanceof ArrayValue y) {
            return x.items().size() == y.items().size() && java.util.stream.IntStream.range(0, x.items().size())
                    .allMatch(index -> sameStructure(x.items().get(index), y.items().get(index)));
        }
        return left.equals(right);
    }

    private record WireJudgment(List<WireValue> obligations, WireValue provenance) {}
    private record WireReasonFailure(WireJudgment judgment, ResidualSet<WireValue> residuals,
            List<ReasonDisposition> classifications) {}

    private static WireClassification classifiedWire(List<WireValue> obligations, List<ClassifiedObligation> classified,
            WireValue provenance) {
        List<WireValue> residuals = new ArrayList<>();
        for (ClassifiedObligation item : classified) {
            if (item.disposition() == ReasonDisposition.RESIDUAL && residuals.stream().noneMatch(other -> sameStructure(item.obligation(), other)))
                residuals.add(item.obligation());
        }
        List<WireValue> stops = classified.stream().filter(item -> item.disposition() == ReasonDisposition.STOPPED).map(ClassifiedObligation::obligation).toList();
        List<WireValue> failures = classified.stream().filter(item -> item.disposition() == ReasonDisposition.FAILED).map(ClassifiedObligation::obligation).toList();
        List<ReasonDisposition> classes = classified.stream().map(ClassifiedObligation::disposition).toList();
        WireJudgment judgment = new WireJudgment(obligations, provenance);
        Result<RefinementOutcome<WireJudgment, WireValue, List<WireValue>>, WireReasonFailure> evaluation =
                switch (SemanticTypes.classifyDispositions(classes)) {
                    case RESIDUAL -> new Result.Accepted<>(new RefinementOutcome.Residual<>(judgment, residuals));
                    case STOPPED -> new Result.Accepted<>(new RefinementOutcome.Stopped<>(judgment, residuals, stops));
                    case FAILED -> new Result.Rejected<>(new WireReasonFailure(judgment, ResidualSet.of(residuals), classes));
                };
        return switch (evaluation) {
            case Result.Accepted(RefinementOutcome.Resolved(var resolved)) ->
                new WireClassification("Resolved", resolved.obligations(), List.of(), stops, failures, resolved.provenance());
            case Result.Accepted(RefinementOutcome.Residual(var residual, var set)) ->
                new WireClassification("Residual", residual.obligations(), set.values(), stops, failures, residual.provenance());
            case Result.Accepted(RefinementOutcome.Stopped(var stopped, var set, var cause)) ->
                new WireClassification("Stopped", stopped.obligations(), set.values(), cause, failures, stopped.provenance());
            case Result.Rejected(var failed) ->
                new WireClassification("Failed", failed.judgment().obligations(), failed.residuals().values(), stops, failures, failed.judgment().provenance());
        };
    }

    private static WireClassification wireClassification(List<WireValue> obligations, WireValue provenance) {
        return classifiedWire(obligations, obligations.stream().map(item -> new ClassifiedObligation(item,
                SemanticGraphWire.reason(f(item, "reason"), "$.reason").disposition())).toList(), provenance);
    }

    private static ReasonDisposition meaningDisposition(WireValue obligation) {
        WireValue reason = obligation instanceof ObjectValue object ? object.get("reason") : null;
        if (reason != null) return SemanticGraphWire.reason(reason, "$.reason").disposition();
        return switch (tag(f(obligation, "predicate"))) {
            case "Mo01", "Mo02", "Mo03", "Mo04", "Mo05", "Mo07", "Mo10", "Mo11" -> ReasonDisposition.RESIDUAL;
            case "Mo06", "Mo08", "Mo09" -> ReasonDisposition.FAILED;
            default -> throw new IllegalArgumentException("unknown meaning obligation");
        };
    }

    private static List<ClassifiedObligation> expandObligation(WireValue obligation) {
        String kind = tag(obligation);
        switch (kind) {
            case "Meaning", "SemanticMeaning": {
                List<WireValue> reasons = a(payload(obligation));
                return reasons.isEmpty() ? List.of(new ClassifiedObligation(obligation, ReasonDisposition.FAILED)) : reasons.stream()
                        .map(reason -> new ClassifiedObligation(variant(kind, arr(List.of(reason))), meaningDisposition(reason))).toList();
            }
            case "Type": {
                WireValue value = payload(obligation);
                List<WireValue> reasons = a(f(value, "obligations"));
                if (reasons.isEmpty()) return List.of(new ClassifiedObligation(obligation, ReasonDisposition.FAILED));
                List<ClassifiedObligation> result = new ArrayList<>();
                for (WireValue reason : reasons) {
                    WireValue category = f(reason, "reason");
                    if (tag(category).equals("Meaning")) {
                        List<WireValue> meanings = a(payload(category));
                        if (meanings.isEmpty()) result.add(new ClassifiedObligation(obligation, ReasonDisposition.FAILED));
                        for (WireValue meaning : meanings) {
                            WireValue next = TypeSignatures.replace(reason, "reason", variant("Meaning", arr(List.of(meaning))));
                            result.add(new ClassifiedObligation(obj("tag", str("Type"), "fields", TypeSignatures.replace(value, "obligations", arr(List.of(next)))), meaningDisposition(meaning)));
                        }
                    } else {
                        ReasonDisposition disposition = switch (tag(category)) {
                            case "ConstraintImplication", "Presence", "UnionRemainder", "Inhabitation", "ExtraField" -> ReasonDisposition.RESIDUAL;
                            case "ObligationBoundExhausted" -> ReasonDisposition.STOPPED;
                            default -> throw new IllegalArgumentException("unknown type obligation reason");
                        };
                        result.add(new ClassifiedObligation(obj("tag", str("Type"), "fields", TypeSignatures.replace(value, "obligations", arr(List.of(reason)))), disposition));
                    }
                }
                return result;
            }
            case "Inhabitation", "BranchInhabitation", "UnresolvedUniqueness":
                return List.of(new ClassifiedObligation(obligation, ReasonDisposition.RESIDUAL));
            case "StateBoundExhausted", "BindingBoundExhausted", "BranchBoundExhausted", "ResourceSolverUnknown", "ResourceCapacityBound":
                return List.of(new ClassifiedObligation(obligation, ReasonDisposition.STOPPED));
            default: throw new IllegalArgumentException("unknown unresolved obligation");
        }
    }

    private static WireClassification compositionClassification(List<WireValue> obligations, WireValue provenance) {
        return classifiedWire(obligations, obligations.stream().flatMap(item -> expandObligation(item).stream()).toList(), provenance);
    }

    private static WireValue wireRejection(WireValue id, WireFailure failure) {
        String classification = switch (failure) {
            case WireFailure.UnsupportedSchema unused -> "UnsupportedSchema";
            case WireFailure.UnknownField unused -> "UnknownField";
            case WireFailure.UnknownTag unused -> "UnknownTag";
            case WireFailure.Syntax unused -> "Syntax";
        };
        return obj("id", id, "status", str("Rejected"), "failure_kind", str("Wire"), "classification", str(classification),
                "path", str(failure.path()));
    }

    private enum ClassificationDomain { COMPOSITION, PUBLIC_VALIDATION, SEMANTIC }

    /** Lean {@code classificationInput}: the composition domain is decided before the value entry. */
    private static ClassificationDomain classificationDomain(WireValue input) {
        if (input instanceof ObjectValue object && object.get("domain") instanceof StringValue domain && domain.value().equals("composition")) return ClassificationDomain.COMPOSITION;
        if (input instanceof ObjectValue object && object.get("entry") instanceof StringValue entry && entry.value().equals("value")) return ClassificationDomain.PUBLIC_VALIDATION;
        return ClassificationDomain.SEMANTIC;
    }

    private static void checkClassificationInput(WireValue input) {
        switch (classificationDomain(input)) {
            case COMPOSITION -> { }
            case PUBLIC_VALIDATION -> {
                SemanticGraphWire.decodeGraph(f(input, "graph"), "$.graph", SemanticGraphWire.GraphReading.PUBLIC_VALIDATION);
                SemanticGraphWire.typeRef(f(input, "reference"), "$.reference");
                if (((ObjectValue) input).get("value") == null) throw new WireException(new WireFailure.Syntax("$", "missing field value"));
            }
            case SEMANTIC -> {
                readField(input, "obligations", list -> readList(list, obligation -> SemanticGraphWire.obligation(obligation, "$")));
                SemanticGraphWire.evaluationProvenance(f(input, "provenance"), "$.provenance");
            }
        }
    }

    WireValue evaluate(WireValue input) throws Exception {
        WireValue id = f(input, "id");
        String kind = s(f(input, "kind"));
        if (kind.equals("classification")) {
            try { checkClassificationInput(input); }
            catch (WireException failure) { return wireRejection(id, failure.failure()); }
            if (classificationDomain(input) == ClassificationDomain.PUBLIC_VALIDATION) {
                try { new Context(SemanticGraphWire.decodeGraph(f(input, "graph"), "$.graph", SemanticGraphWire.GraphReading.PUBLIC_VALIDATION)).validate(f(input, "reference"), f(input, "value")); }
                catch (ValueProcessingFailure failure) {
                    if (failure.evaluation().isEmpty())
                        return obj("id", id, "status", str("Rejected"), "failure_kind", str("Wire"), "classification", str("Syntax"), "path", str("$"));
                    WireClassification result = valueClassification(failure);
                    return obj("id", id, "status", str(result.status()), "obligations", arr(result.obligations()), "residuals", arr(result.residuals()), "stops", arr(result.stops()), "failures", arr(result.failures()), "provenance", result.provenance());
                }
                return obj("id", id, "status", str("Resolved"));
            }
            boolean composition = classificationDomain(input) == ClassificationDomain.COMPOSITION;
            WireClassification result = composition ? compositionClassification(a(f(input, "obligations")), f(input, "provenance"))
                    : wireClassification(a(f(input, "obligations")), f(input, "provenance"));
            return obj("id", id, "status", str(result.status()), "obligations", arr(result.obligations()),
                    "domain", composition ? str("composition") : NIL, "residuals", arr(result.residuals()), "stops", arr(result.stops()), "failures", arr(result.failures()), "provenance", result.provenance());
        }
        if (kind.equals("wire")) {
            WireValue value = f(input, "value");
            GenerationBasis basis = GenerationBasis.ofInput(value);
            try {
                CheckedGeneration checked = TypeSignatures.admitGeneration(basis, encodeWire(value));
                return obj("id", id, "status", str("Accepted"), "encoded", checked.input);
            } catch (GenerationFailure failure) {
                if (failure.kind() == GenerationFailureKind.UNSUPPORTED_SCHEMA)
                    return obj("id", id, "status", str("Rejected"), "failure_kind", str("Wire"), "classification", str("UnsupportedSchema"), "path", str(failure.path()));
                if (failure.wireFailure() != null) return wireRejection(id, failure.wireFailure());
                return obj("id", id, "status", str("Rejected"), "condition", str(failure.condition()));
            }
        }
        Context context;
        try {
            context = generation(f(input, "library")).valueContext();
        } catch (GenerationFailure failure) {
            if (kind.equals("profile_admission")) return declarationFailure(id, failure);
            throw failure;
        }
        if (kind.equals("profile_admission")) return obj("id", id, "status", str("Accepted"));
        return switch (kind) {
            case "value" -> {
                WireValue type = typeReference(input);
                WireValue value = f(input, "value");
                try {
                    context.validate(type, value);
                    WireValue decoded = context.decode(type, necoherence.semantic.SemanticValues.encodeWire(value));
                    if (!sameJson(decoded, value)) throw new IllegalStateException("roundtrip changed value");
                    yield obj("id", id, "status", str("Accepted"));
                } catch (ValueRejection failure) {
                    yield obj("id", id, "status", str("Rejected"),
                            "type_ref", failure.typeRef(),
                            "path", path(context, f(input, "type_id"), value, failure),
                            "condition", condition(failure), "trace", arr(failure.referenceTrace().stream().map(ref -> f(ref, "definition_name")).toList()));
                } catch (ValueProcessingFailure failure) {
                    if (failure.evaluation().isPresent()) {
                        WireClassification classification = valueClassification(failure);
                        yield obj("id", id, "status", str("Unresolved"), "classification", obj("status", str(classification.status()), "obligations", arr(classification.obligations()), "residuals", arr(classification.residuals()), "provenance", classification.provenance()));
                    }
                    yield obj("id", id, "status", str("Unresolved"));
                }
            }
            case "residual_record" -> {
                WireValue type = typeReference(input);
                WireValue value = f(input, "value");
                try {
                    context.validate(type, value);
                    yield obj("id", id, "status", str("not-unresolved"));
                } catch (ValueRejection failure) {
                    yield obj("id", id, "status", str("not-unresolved"));
                } catch (ValueProcessingFailure failure) {
                    List<SemanticTypes.SemanticObligation> residuals = failure.obligations().stream()
                            .filter(item -> item.reason().disposition() == ReasonDisposition.RESIDUAL).toList();
                    if (residuals.isEmpty()) yield obj("id", id, "status", str("not-unresolved"));
                    GenerationBasis basis;
                    try {
                        basis = GenerationBasis.ofInput(obj("basis", f(input, "basis"), "composition", NIL));
                    } catch (GenerationFailure basisFailure) {
                        yield obj("id", id, "status", str("Rejected"), "condition", str(basisFailure.condition()));
                    }
                    yield switch (SemanticResidualRecord.encodeSemanticResidual(basis,
                            SemanticGraphWire.typeRef(type, "$.reference"), WireJson.fromWire(value), residuals)) {
                        case Result.Accepted(var bytes) ->
                            obj("id", id, "status", str("encoded"), "bytes", str(java.util.HexFormat.of().formatHex(bytes)));
                        case Result.Rejected(var failed) ->
                            obj("id", id, "status", str("Rejected"), "condition", str(failed.conditionName()));
                    };
                }
            }
            default -> throw new IllegalArgumentException("unsupported invariant kind: " + kind);
        };
    }

    public static void main(String[] args) throws Exception {
        SemanticInvariantAdapter adapter = new SemanticInvariantAdapter();
        try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
                PrintWriter output = new PrintWriter(System.out, true, StandardCharsets.UTF_8)) {
            String line;
            while ((line = input.readLine()) != null) {
                output.println(encodeWire(adapter.evaluate(TypeSignatures.parseWire(line))));
            }
        }
    }
}
