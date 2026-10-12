// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.comparison;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.function.Function;
import necoherence.admission.Admission;
import necoherence.admission.AdmissionDecision;
import necoherence.admission.AdmissionProvenance;
import necoherence.admission.AdmissionSignal;
import necoherence.admission.CapacityObservation;
import necoherence.admission.CoalescingWitness;
import necoherence.admission.DynamicAdmissionFailure;
import necoherence.admission.DynamicAdmissionInput;
import necoherence.admission.DynamicAdmissionResult;
import necoherence.admission.DynamicAdmissionState;
import necoherence.admission.EnvironmentSpecification;
import necoherence.admission.ProvenanceErasureWitness;
import necoherence.admission.SignalKind;
import necoherence.call.BoundaryDiagnosis;
import necoherence.call.Call;
import necoherence.call.Call.CallResult;
import necoherence.call.Call.Request;
import necoherence.call.Deferred;
import necoherence.call.Immediate;
import necoherence.call.ProjectionFailed;
import necoherence.iteration.Iteration;
import necoherence.core.Basis;
import necoherence.core.Command;
import necoherence.core.Core;
import necoherence.core.Lookup;
import necoherence.core.Nat;
import necoherence.core.PositiveNat;
import necoherence.core.Never;
import necoherence.core.Observation;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.StaleBasis;
import necoherence.core.UnknownResource;
import necoherence.core.World;
import necoherence.file.ContentDigest;
import necoherence.file.Digests;
import necoherence.file.DigestLookup;
import necoherence.file.ExternalFileState;
import necoherence.file.ExternalMutation;
import necoherence.file.FileEffect;
import necoherence.file.FileRecord;
import necoherence.file.FileSnapshot;
import necoherence.file.NormalizedPath;
import necoherence.file.ReplaceContents;
import necoherence.file.ReplaceConflict;
import necoherence.file.ReplaceRejection;
import necoherence.file.ResourcePathMismatch;
import necoherence.file.UnobservedContents;
import necoherence.file.WriteFailure;
import necoherence.file.ReadFailure;
import necoherence.progression.Accepted;
import necoherence.progression.AdapterCommand;
import necoherence.progression.AdapterFailure;
import necoherence.progression.AdapterResult;
import necoherence.progression.AdapterSignal;
import necoherence.progression.CancelFailure;
import necoherence.progression.CancelDecisionResult;
import necoherence.progression.ConfiguredSafetyLimit;
import necoherence.progression.CompletionObservationFailure;
import necoherence.progression.CompletionObservationResult;
import necoherence.progression.CostSelection;
import necoherence.progression.EvidenceVersion;
import necoherence.progression.MeaningPermission;
import necoherence.progression.PermissionDenial;
import necoherence.progression.Progression;
import necoherence.progression.RequestEffectClass;
import necoherence.progression.RequestEntry;
import necoherence.progression.RequestFootprint;
import necoherence.progression.RequestIdentity;
import necoherence.progression.RequestInput;
import necoherence.progression.RequestPhase;
import necoherence.progression.RequestPolicy;
import necoherence.progression.RequestProgressionSnapshot;
import necoherence.progression.ResourceBudget;
import necoherence.progression.ResourceDemand;
import necoherence.progression.Running;
import necoherence.progression.StartDecisionFailure;
import necoherence.progression.StartDecisionResult;
import necoherence.progression.StartObservationFailure;
import necoherence.progression.StartObservationResult;
import necoherence.progression.Starting;
import necoherence.progression.SubmitFailure;
import necoherence.progression.SubmitResult;
import necoherence.reconcile.Divergence;
import necoherence.reconcile.Reconcile;
import necoherence.reconcile.Reconciliation;
import necoherence.record.CallRecord;
import necoherence.record.Record;
import necoherence.record.RecordBasis;
import necoherence.store.Stores;
import necoherence.transition.StepTransition;

/**
 * Inspection adapter: reads one generated query from stdin, evaluates it against this package's
 * computable declarations, and writes one normalized JSON result to stdout.
 *
 * <p>Protocol mirrors {@code lean_driver/FeatureCheck.lean}: {@code {"kind":"surface"}} returns the fixed
 * feature/operation inventory; {@code {"kind":"evaluate","requests":[...]}} decodes and evaluates
 * each request in order; any syntax, shape, or unknown-name failure closes the whole reply as
 * {@code {"kind":"invalid","failure":{...}}}.
 *
 * <p>Non-negative integers are exchanged as decimal-digit JSON strings.
 */
public final class FeatureCheck {

    private FeatureCheck() {
    }

    /** Distinguishes why decoding a query or a request's input failed. */
    private enum FailureKind {
        JSON_SYNTAX("json_syntax"),
        QUERY_SHAPE("query_shape"),
        UNKNOWN_FEATURE("unknown_feature"),
        UNKNOWN_OPERATION("unknown_operation"),
        INPUT_SHAPE("input_shape");

        private final String label;

        FailureKind(String label) {
            this.label = label;
        }
    }

    private static final class DecodeException extends RuntimeException {
        final FailureKind kind;

        DecodeException(FailureKind kind, String detail) {
            super(detail);
            this.kind = kind;
        }
    }

    private static DecodeException shape(String detail) {
        return new DecodeException(FailureKind.INPUT_SHAPE, detail);
    }

    /* ---------------------------------------------------------------- JSON accessors */

    private static Json.JObj asObj(Json j) {
        if (j instanceof Json.JObj o) {
            return o;
        }
        throw shape("expected object");
    }

    private static Json objVal(Json j, String key) {
        Json.JObj o = asObj(j);
        if (!o.fields().containsKey(key)) {
            throw shape("missing field " + key);
        }
        return o.fields().get(key);
    }

    private static String asStr(Json j) {
        if (j instanceof Json.JStr s) {
            return s.value();
        }
        throw shape("expected string");
    }

    private static boolean asBool(Json j) {
        if (j instanceof Json.JBool b) {
            return b.value();
        }
        throw shape("expected bool");
    }

    private static List<Json> asArr(Json j) {
        if (j instanceof Json.JArr a) {
            return a.items();
        }
        throw shape("expected array");
    }

    private static Nat natOfStr(String s) {
        if (s.isEmpty()) throw shape("empty integer");
        for (int i = 0; i < s.length(); i++) if (!Character.isDigit(s.charAt(i))) throw shape("invalid integer");
        return switch (Nat.of(new BigInteger(s))) {
            case necoherence.core.Validation.Valid<Nat> valid -> valid.value();
            case necoherence.core.Validation.Invalid<Nat> invalid -> throw shape(invalid.detail());
        };
    }

    private static Nat natField(Json j, String key) {
        return natOfStr(asStr(objVal(j, key)));
    }

    private static String strField(Json j, String key) {
        return asStr(objVal(j, key));
    }

    private static List<Json> arrField(Json j, String key) {
        return asArr(objVal(j, key));
    }

    private static Json natToJson(Nat n) {
        return Json.str(n.toString());
    }

    private static <A, B> List<B> mapList(List<A> arr, Function<A, B> f) {
        List<B> out = new ArrayList<>(arr.size());
        for (A a : arr) {
            out.add(f.apply(a));
        }
        return out;
    }

    /* ---------------------------------------------------------------- Core */

    private static ResourceId decodeResourceId(Json j) {
        return new ResourceId(strField(j, "kind"), strField(j, "name"));
    }

    private static Json encodeResourceId(ResourceId r) {
        return Json.obj("kind", Json.str(r.kind()), "name", Json.str(r.name()));
    }

    private static Revision decodeRevision(Json j) {
        return Revision.fromNat(natOfStr(asStr(j)));
    }

    private static Json encodeRevision(Revision r) {
        return natToJson(r.value());
    }

    private static Basis decodeBasis(Json j) {
        return new Basis(decodeResourceId(objVal(j, "resource")), decodeRevision(objVal(j, "revision")));
    }

    private static Json encodeBasis(Basis b) {
        return Json.obj("resource", encodeResourceId(b.resource()), "revision", encodeRevision(b.revision()));
    }

    private static World decodeWorld(Json j) {
        List<World.Entry> entries = new ArrayList<>();
        for (Json item : asArr(j)) {
            entries.add(new World.Entry(
                    decodeResourceId(objVal(item, "resource")), decodeRevision(objVal(item, "revision"))));
        }
        return new World(entries);
    }

    private static Json encodeWorld(World w) {
        List<Json> items = new ArrayList<>();
        for (World.Entry e : w.entries()) {
            items.add(Json.obj("resource", encodeResourceId(e.resource()), "revision", encodeRevision(e.revision())));
        }
        return Json.arr(items);
    }

    private static Json encodeLookup(Lookup l) {
        if (l instanceof Lookup.Found found) {
            return Json.obj("tag", Json.str("found"), "revision", encodeRevision(found.revision()));
        }
        Lookup.Unknown unknown = (Lookup.Unknown) l;
        return Json.obj("tag", Json.str("unknown"), "resource", encodeResourceId(unknown.unknownResource().resource()));
    }

    private static Command<Json> decodeCommand(Json j) {
        return new Command<>(objVal(j, "intent"), decodeBasis(objVal(j, "basis")));
    }

    private static Json encodeCommand(Command<Json> c) {
        return Json.obj("intent", c.intent(), "basis", encodeBasis(c.basis()));
    }

    private static Json encodeApplyOutcome(Outcome<Core.AppliedValue<Json>, UnknownResource, StaleBasis, Never> o) {
        if (o instanceof Outcome.Applied<Core.AppliedValue<Json>, UnknownResource, StaleBasis, Never> applied) {
            return Json.obj(
                    "tag", Json.str("applied"), "intent", applied.value().intent(),
                    "world", encodeWorld(applied.value().world()));
        }
        if (o instanceof Outcome.Rejected<Core.AppliedValue<Json>, UnknownResource, StaleBasis, Never> rejected) {
            return Json.obj("tag", Json.str("rejected"), "resource", encodeResourceId(rejected.reason().resource()));
        }
        Outcome.Conflicted<Core.AppliedValue<Json>, UnknownResource, StaleBasis, Never> conflicted =
                (Outcome.Conflicted<Core.AppliedValue<Json>, UnknownResource, StaleBasis, Never>) o;
        return Json.obj(
                "tag", Json.str("conflicted"),
                "expected", encodeRevision(conflicted.conflict().expected()),
                "actual", encodeRevision(conflicted.conflict().actual()));
    }

    private static Json opCoreLookup(Json input) {
        World world = decodeWorld(objVal(input, "world"));
        ResourceId resource = decodeResourceId(objVal(input, "resource"));
        return encodeLookup(Core.lookup(world, resource));
    }

    private static Json opCoreBump(Json input) {
        World world = decodeWorld(objVal(input, "world"));
        ResourceId resource = decodeResourceId(objVal(input, "resource"));
        return encodeWorld(Core.bump(world, resource));
    }

    private static Json opCoreCommandOf(Json input) {
        Json obsJ = objVal(input, "observation");
        Json payload = objVal(obsJ, "payload");
        Basis basis = decodeBasis(objVal(obsJ, "basis"));
        Nat observedAt = natField(obsJ, "observedAt");
        Observation<Json> observation = new Observation<>(payload, basis, observedAt);
        Json intentPayload = objVal(input, "payload");
        return encodeCommand(Core.commandOf(observation, intentPayload));
    }

    private static Json opCoreApply(Json input) {
        World world = decodeWorld(objVal(input, "world"));
        Command<Json> command = decodeCommand(objVal(input, "command"));
        return encodeApplyOutcome(Core.apply(world, command));
    }

    /* ---------------------------------------------------------------- Call */

    private sealed interface FunctionForm {
        record IdentityForm() implements FunctionForm {
        }

        record ConstForm(Json value) implements FunctionForm {
        }

        record GetFieldForm(String name) implements FunctionForm {
        }

        record SetFieldForm(String name, Json value) implements FunctionForm {
        }

        record WrapForm(String tag) implements FunctionForm {
        }
    }

    private static FunctionForm decodeFunctionForm(Json j) {
        String kind = strField(j, "kind");
        return switch (kind) {
            case "identity" -> new FunctionForm.IdentityForm();
            case "const" -> new FunctionForm.ConstForm(objVal(j, "value"));
            case "getField" -> new FunctionForm.GetFieldForm(strField(j, "name"));
            case "setField" -> new FunctionForm.SetFieldForm(strField(j, "name"), objVal(j, "value"));
            case "wrap" -> new FunctionForm.WrapForm(strField(j, "tag"));
            default -> throw shape("unknown function form kind " + kind);
        };
    }

    private static Json applyFunctionForm(FunctionForm form, Json x) {
        if (form instanceof FunctionForm.IdentityForm) {
            return x;
        }
        if (form instanceof FunctionForm.ConstForm c) {
            return c.value();
        }
        if (form instanceof FunctionForm.GetFieldForm g) {
            if (x instanceof Json.JObj o && o.fields().containsKey(g.name())) {
                return o.fields().get(g.name());
            }
            return Json.NULL;
        }
        if (form instanceof FunctionForm.SetFieldForm s) {
            LinkedHashMap<String, Json> fields = new LinkedHashMap<>();
            if (x instanceof Json.JObj o) {
                fields.putAll(o.fields());
            }
            fields.put(s.name(), s.value());
            return new Json.JObj(fields);
        }
        FunctionForm.WrapForm w = (FunctionForm.WrapForm) form;
        return Json.obj("tag", Json.str(w.tag()), "value", x);
    }

    private static Request<Json> decodeCallRequest(Json j) {
        Json payload = objVal(j, "payload");
        List<String> fields = mapList(arrField(j, "fields"), FeatureCheck::asStr);
        return new Request<>(payload, fields);
    }

    private record DecodedDeclaration(String identity, List<String> required, FunctionForm form) {
    }

    private static DecodedDeclaration decodeDeclaration(Json j) {
        String identity = strField(j, "identity");
        List<String> required = mapList(arrField(j, "required"), FeatureCheck::asStr);
        FunctionForm form = decodeFunctionForm(objVal(j, "output"));
        return new DecodedDeclaration(identity, required, form);
    }

    private static Immediate<Json, Json> immediateOfDecoded(DecodedDeclaration decl) {
        return Call.immediateOf(decl.identity(), decl.required(), x -> applyFunctionForm(decl.form(), x));
    }

    private static Deferred<Json, Json> deferredOfDecoded(DecodedDeclaration decl) {
        return Call.deferredOf(decl.identity(), decl.required(), x -> applyFunctionForm(decl.form(), x));
    }

    private static Json encodeCallResult(CallResult<Json> r) {
        if (r instanceof CallResult.Ok<Json> ok) {
            return Json.obj("tag", Json.str("ok"), "value", ok.value());
        }
        CallResult.Failed<Json> failed = (CallResult.Failed<Json>) r;
        return encodeProjectionFailed(failed.failure());
    }

    private static Json encodeProjectionFailed(ProjectionFailed f) {
        List<Json> fields = new ArrayList<>();
        for (String s : f.fields()) {
            fields.add(Json.str(s));
        }
        return Json.obj("tag", Json.str("failed"), "declaration", Json.str(f.declaration()), "fields", Json.arr(fields));
    }

    private static Json opCallImmediateOf(Json input) {
        Immediate<Json, Json> decl = immediateOfDecoded(decodeDeclaration(input));
        return Json.obj(
                "identity", Json.str(decl.identity()), "required", Json.arr(mapList(decl.required(), Json::str)));
    }

    private static Json opCallDeferredOf(Json input) {
        Deferred<Json, Json> decl = deferredOfDecoded(decodeDeclaration(input));
        return Json.obj(
                "identity", Json.str(decl.identity()), "required", Json.arr(mapList(decl.required(), Json::str)));
    }

    private static Json opCallIo(Json input) {
        Immediate<Json, Json> decl = immediateOfDecoded(decodeDeclaration(objVal(input, "declaration")));
        Request<Json> req = decodeCallRequest(objVal(input, "request"));
        return encodeCallResult(Call.io(decl, req));
    }

    private static Json opCallIssue(Json input) {
        Deferred<Json, Json> decl = deferredOfDecoded(decodeDeclaration(objVal(input, "declaration")));
        Request<Json> req = decodeCallRequest(objVal(input, "request"));
        return encodeCallResult(Call.issue(decl, req));
    }

    /* ---------------------------------------------------------------- Step transition */

    private sealed interface AdvanceForm {
        record ConsumeImmediately(List<Json> outputs) implements AdvanceForm {
        }

        record ReprocessAlways(List<Json> outputs) implements AdvanceForm {
        }

        record ConsumeAfter(Nat rounds, List<Json> outputsPerRound) implements AdvanceForm {
        }
    }

    private static AdvanceForm decodeAdvanceForm(Json j) {
        String mode = strField(j, "mode");
        return switch (mode) {
            case "consumeImmediately" -> new AdvanceForm.ConsumeImmediately(arrField(j, "outputs"));
            case "reprocessAlways" -> new AdvanceForm.ReprocessAlways(arrField(j, "outputs"));
            case "consumeAfter" -> new AdvanceForm.ConsumeAfter(natField(j, "rounds"), arrField(j, "outputsPerRound"));
            default -> throw shape("unknown advance mode " + mode);
        };
    }

    private static Nat roundOf(Json state) {
        if (state instanceof Json.JObj o && o.fields().get("round") instanceof Json.JStr s) {
            try {
                return natOfStr(s.value());
            } catch (DecodeException e) {
                return Nat.zero();
            }
        }
        return Nat.zero();
    }

    private static Json stateWithRound(Nat n) {
        return Json.obj("round", Json.str(n.toString()));
    }

    private static StepTransition.Consumption<Json, Json> advanceEval(AdvanceForm form, Json state) {
        if (form instanceof AdvanceForm.ConsumeImmediately c) {
            return new StepTransition.Consumed<>(state, c.outputs());
        }
        if (form instanceof AdvanceForm.ReprocessAlways r) {
            return new StepTransition.Reprocess<>(state, r.outputs());
        }
        AdvanceForm.ConsumeAfter c = (AdvanceForm.ConsumeAfter) form;
        Nat r = roundOf(state).successor();
        Json newState = stateWithRound(r);
        if (r.compareTo(c.rounds()) >= 0) {
            return new StepTransition.Consumed<>(newState, c.outputsPerRound());
        }
        return new StepTransition.Reprocess<>(newState, c.outputsPerRound());
    }

    private static Json encodeStepFailure(StepTransition.Failure f) {
        if (f instanceof StepTransition.ReprocessLimitExhausted r) {
            return Json.obj("tag", Json.str("reprocess_limit_exhausted"), "applications", natToJson(r.applications()));
        }
        StepTransition.CapacityExceeded c = (StepTransition.CapacityExceeded) f;
        return Json.obj(
                "tag", Json.str("capacity_exceeded"), "capacity", natToJson(c.capacity()),
                "attempted", natToJson(c.attempted()));
    }

    private static Json encodeStepTransitionResult(StepTransition.Result<Json, Json> r) {
        if (r instanceof StepTransition.Settled<Json, Json> settled) {
            return Json.obj(
                    "tag", Json.str("settled"), "state", settled.state(), "outputs", Json.arr(settled.outputs()),
                    "applications", natToJson(settled.applications()));
        }
        StepTransition.Failed<Json, Json> failed = (StepTransition.Failed<Json, Json>) r;
        return Json.obj(
                "tag", Json.str("failed"), "state", failed.state(), "outputs", Json.arr(failed.outputs()),
                "failure", encodeStepFailure(failed.failure()));
    }

    private static Json opStepTransitionStep(Json input) {
        Json state = objVal(input, "state");
        Json inp = objVal(input, "input");
        AdvanceForm form = decodeAdvanceForm(objVal(input, "advance"));
        Nat limitN = natField(input, "limit");
        Nat capacityValue = natField(input, "capacity");
        PositiveNat positiveLimit = switch (PositiveNat.of(limitN)) {
            case necoherence.core.Validation.Valid<PositiveNat> valid -> valid.value();
            case necoherence.core.Validation.Invalid<PositiveNat> invalid -> throw shape(invalid.detail());
        };
        StepTransition.PositiveLimit limit = new StepTransition.PositiveLimit(positiveLimit);
        StepTransition.Capacity capacity = new StepTransition.Capacity(capacityValue);
        StepTransition.Result<Json, Json> result =
                StepTransition.step(state, inp, (s, i) -> advanceEval(form, s), limit, capacity);
        return encodeStepTransitionResult(result);
    }

    /* ---------------------------------------------------------------- Iteration */

    private static Json encodeStageFailed(Iteration.StageProjectionFailed s) {
        return Json.obj(
                "position", natToJson(s.position()), "declaration", Json.str(s.failure().declaration()),
                "fields", Json.arr(mapList(s.failure().fields(), Json::str)));
    }

    private static Json opIterationFold(Json input) {
        DecodedDeclaration step = decodeDeclaration(objVal(input, "step"));
        Immediate<Json, Json> immediate = immediateOfDecoded(step);
        Json seed = objVal(input, "seed");
        Nat count = natField(input, "count");
        List<String> stepFields = mapList(arrField(input, "stepFields"), FeatureCheck::asStr);
        Iteration.FoldOutcome<Json> outcome = Iteration.runFold(immediate, seed, count, stepFields);
        if (outcome instanceof Iteration.FoldTrace<Json> trace) {
            return Json.obj("tag", Json.str("trace"), "states", Json.arr(trace.states()));
        }
        Iteration.FoldStopped<Json> stopped = (Iteration.FoldStopped<Json>) outcome;
        return Json.obj(
                "tag", Json.str("stopped"), "states", Json.arr(stopped.states()),
                "stopped", encodeStageFailed(stopped.stopped()));
    }

    private sealed interface StepOutcomeForm {
        record Settled() implements StepOutcomeForm {
        }

        record Advance(Nat measure) implements StepOutcomeForm {
        }
    }

    private static StepOutcomeForm decodeStepOutcomeForm(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "settled" -> new StepOutcomeForm.Settled();
            case "advance" -> new StepOutcomeForm.Advance(natField(j, "measure"));
            default -> throw shape("unknown step outcome tag " + tag);
        };
    }

    private record RecurseTableEntry(Json payload, StepOutcomeForm outcome) {
    }

    private static List<RecurseTableEntry> decodeRecurseTable(Json j) {
        List<RecurseTableEntry> out = new ArrayList<>();
        for (Json entry : asArr(j)) {
            out.add(new RecurseTableEntry(objVal(entry, "payload"), decodeStepOutcomeForm(objVal(entry, "outcome"))));
        }
        return out;
    }

    private static boolean jsonEquals(Json a, Json b) {
        return Json.compress(a).equals(Json.compress(b));
    }

    private static Json opIterationRecurse(Json input) {
        List<String> required = mapList(arrField(input, "required"), FeatureCheck::asStr);
        List<RecurseTableEntry> table = decodeRecurseTable(objVal(input, "table"));
        FunctionForm nextForm = decodeFunctionForm(objVal(input, "next"));
        Json seed = objVal(input, "seed");
        List<String> stepFields = mapList(arrField(input, "stepFields"), FeatureCheck::asStr);

        Immediate<Json, Iteration.StepOutcome<Json>> immediate =
                Call.immediateOf("necoherence.iteration.recurse.adapter.step", required, state -> {
                    RecurseTableEntry matched = null;
                    for (RecurseTableEntry entry : table) {
                        if (jsonEquals(entry.payload(), state)) {
                            matched = entry;
                            break;
                        }
                    }
                    if (matched == null || matched.outcome() instanceof StepOutcomeForm.Settled) {
                        return new Iteration.Settled<>(state);
                    }
                    StepOutcomeForm.Advance advance = (StepOutcomeForm.Advance) matched.outcome();
                    Json next = applyFunctionForm(nextForm, state);
                    return new Iteration.Continue<>(next, advance.measure());
                });
        Iteration.RecurseOutcome<Json> outcome = Iteration.runRecurse(immediate, seed, stepFields);
        if (outcome instanceof Iteration.RecurseSettled<Json> settled) {
            return Json.obj("tag", Json.str("settled"), "value", settled.value(), "steps", natToJson(settled.steps()));
        }
        if (outcome instanceof Iteration.RecurseDidNotDecrease<Json> didNotDecrease) {
            return Json.obj(
                    "tag", Json.str("did_not_decrease"), "position", natToJson(didNotDecrease.position()),
                    "state", didNotDecrease.state(), "measure", natToJson(didNotDecrease.measure()),
                    "previousMeasure", natToJson(didNotDecrease.previousMeasure()));
        }
        Iteration.RecurseProjectionFailed<Json> failed = (Iteration.RecurseProjectionFailed<Json>) outcome;
        return Json.obj(
                "tag", Json.str("projection_failed"), "lastState", failed.lastState(),
                "stopped", encodeStageFailed(failed.stopped()));
    }

    private static String closureElemOfJson(Json j) {
        return Json.compress(j);
    }

    private static Json closureElemToJson(String s) {
        return Json.parse(s);
    }

    private static Json encodeClosureElems(Set<String> elems) {
        return Json.arr(mapList(List.copyOf(elems), FeatureCheck::closureElemToJson));
    }

    private static Json opIterationClosure(Json input) {
        DecodedDeclaration step = decodeDeclaration(objVal(input, "step"));
        Set<String> carrier = new LinkedHashSet<>(mapList(arrField(input, "carrier"), FeatureCheck::closureElemOfJson));
        Set<String> seed = new LinkedHashSet<>(mapList(arrField(input, "seed"), FeatureCheck::closureElemOfJson));
        List<String> stepFields = mapList(arrField(input, "stepFields"), FeatureCheck::asStr);

        Immediate<Iteration.ClosureState<String>, Set<String>> immediate =
                Call.immediateOf(step.identity(), step.required(), state -> {
                    Json elemsJson = encodeClosureElems(state.elements());
                    Json producedJson = applyFunctionForm(step.form(), elemsJson);
                    Set<String> produced = new LinkedHashSet<>();
                    if (producedJson instanceof Json.JArr arr) {
                        for (Json item : arr.items()) {
                            produced.add(closureElemOfJson(item));
                        }
                    }
                    return produced;
                });
        Iteration.ClosureOutcome<String> outcome = Iteration.runClosure(immediate, carrier, seed, stepFields);
        if (outcome instanceof Iteration.ClosureFixpoint<String> fixpoint) {
            return Json.obj(
                    "tag", Json.str("fixpoint"), "result", encodeClosureElems(fixpoint.elements()),
                    "position", natToJson(fixpoint.steps()));
        }
        if (outcome instanceof Iteration.ClosureViolation<String> violation) {
            return Json.obj(
                    "tag", Json.str("violation"), "position", natToJson(violation.position()),
                    "current", encodeClosureElems(violation.current()), "produced", encodeClosureElems(violation.produced()));
        }
        Iteration.ClosureProjectionFailed<String> failed = (Iteration.ClosureProjectionFailed<String>) outcome;
        return Json.obj(
                "tag", Json.str("projection_failed"), "current", encodeClosureElems(failed.last()),
                "stopped", encodeStageFailed(failed.stopped()));
    }

    /* ---------------------------------------------------------------- Store */

    private static Stores.Store.Entry<Json> decodeStoreEntry(Json j) {
        return new Stores.Store.Entry<>(
                decodeResourceId(objVal(j, "resource")), decodeRevision(objVal(j, "revision")), objVal(j, "payload"));
    }

    private static Stores.Store<Json> decodeStore(Json j) {
        return Stores.storeOf(mapList(asArr(j), FeatureCheck::decodeStoreEntry));
    }

    private static Json encodeStoreEntry(Stores.Store.Entry<Json> e) {
        return Json.obj(
                "resource", encodeResourceId(e.resource()), "revision", encodeRevision(e.revision()), "payload", e.payload());
    }

    private static Json encodeStore(Stores.Store<Json> s) {
        return Json.arr(mapList(Stores.storeEntries(s), FeatureCheck::encodeStoreEntry));
    }

    private static Json opStoreStoreOf(Json input) {
        return encodeStore(decodeStore(input));
    }

    private static Json opStoreStoreEntries(Json input) {
        return encodeStore(decodeStore(objVal(input, "store")));
    }

    private static Json encodeObservedOutcome(Stores.Observed<Json> observed) {
        if (observed instanceof Stores.Observed.Found<Json> found) {
            return Json.obj("tag", Json.str("found"), "revision", encodeRevision(found.revision()), "payload", found.payload());
        }
        Stores.Observed.Unknown<Json> unknown = (Stores.Observed.Unknown<Json>) observed;
        return Json.obj("tag", Json.str("unknown"), "resource", encodeResourceId(unknown.unknownResource().resource()));
    }

    private static Json opStoreObserve(Json input) {
        Stores.Store<Json> store = decodeStore(objVal(input, "store"));
        ResourceId resource = decodeResourceId(objVal(input, "resource"));
        return encodeObservedOutcome(Stores.observe(store, resource));
    }

    private static Json encodeStoreApplyOutcome(
            Outcome<Stores.AppliedStore<Json>, UnknownResource, StaleBasis, Never> o) {
        if (o instanceof Outcome.Applied<Stores.AppliedStore<Json>, UnknownResource, StaleBasis, Never> applied) {
            return Json.obj(
                    "tag", Json.str("applied"), "intent", applied.value().intent(),
                    "store", encodeStore(applied.value().store()));
        }
        if (o instanceof Outcome.Rejected<Stores.AppliedStore<Json>, UnknownResource, StaleBasis, Never> rejected) {
            return Json.obj("tag", Json.str("rejected"), "resource", encodeResourceId(rejected.reason().resource()));
        }
        Outcome.Conflicted<Stores.AppliedStore<Json>, UnknownResource, StaleBasis, Never> conflicted =
                (Outcome.Conflicted<Stores.AppliedStore<Json>, UnknownResource, StaleBasis, Never>) o;
        return Json.obj(
                "tag", Json.str("conflicted"),
                "expected", encodeRevision(conflicted.conflict().expected()),
                "actual", encodeRevision(conflicted.conflict().actual()));
    }

    private static Json opStoreApply(Json input) {
        Stores.Store<Json> store = decodeStore(objVal(input, "store"));
        Command<Json> command = decodeCommand(objVal(input, "command"));
        return encodeStoreApplyOutcome(Stores.apply(store, command));
    }

    private static Json opStoreWorldOf(Json input) {
        Stores.Store<Json> store = decodeStore(input);
        return encodeWorld(Stores.worldOfStore(store));
    }

    /* ---------------------------------------------------------------- Record */

    private static CallRecord<Json, Json> decodeCallRecord(Json j) {
        String declaration = strField(j, "declaration");
        Json ins = objVal(j, "input");
        Json product = objVal(j, "product");
        Json basisJ = objVal(j, "basis");
        RecordBasis basis = basisJ instanceof Json.JNull
                ? new RecordBasis.Unsituated()
                : new RecordBasis.Situated(decodeBasis(basisJ));
        return new CallRecord<>(declaration, ins, product, basis);
    }

    private static Json encodeCallRecord(CallRecord<Json, Json> r) {
        Json basisJson = r.basis() instanceof RecordBasis.Situated situated ? encodeBasis(situated.basis()) : Json.NULL;
        return Json.obj(
                "declaration", Json.str(r.declaration()), "input", r.input(), "product", r.product(), "basis", basisJson);
    }

    private static Json opRecordRecordOf(Json input) {
        String declaration = strField(input, "declaration");
        Json ins = objVal(input, "input");
        Json product = objVal(input, "product");
        return encodeCallRecord(Record.recordOf(declaration, ins, product));
    }

    private static Json opRecordRecordOnBasis(Json input) {
        String declaration = strField(input, "declaration");
        Json ins = objVal(input, "input");
        Json product = objVal(input, "product");
        Basis basis = decodeBasis(objVal(input, "basis"));
        return encodeCallRecord(Record.recordOnBasis(declaration, ins, product, basis));
    }

    private static Json opRecordHasEdge(Json input) {
        CallRecord<Json, Json> earlier = decodeCallRecord(objVal(input, "earlier"));
        CallRecord<Json, Json> later = decodeCallRecord(objVal(input, "later"));
        return Json.obj("holds", Json.bool(Record.hasEdge(earlier, later)));
    }

    /* ---------------------------------------------------------------- Reconcile */

    private static Optional<Basis> decodeOptionBasis(Json j) {
        return j instanceof Json.JNull ? Optional.empty() : Optional.of(decodeBasis(j));
    }

    private static boolean resourceIdLe(ResourceId a, ResourceId b) {
        int c = a.kind().compareTo(b.kind());
        if (c != 0) {
            return c < 0;
        }
        return a.name().compareTo(b.name()) <= 0;
    }

    private static ResourceId divergenceResource(Divergence d) {
        return d.resource();
    }

    private static Json encodeDivergence(Divergence d) {
        if (d instanceof Divergence.WorldAhead a) {
            return Json.obj(
                    "tag", Json.str("world_ahead"), "resource", encodeResourceId(a.resource()),
                    "recorded", encodeRevision(a.recorded()), "actual", encodeRevision(a.actual()));
        }
        if (d instanceof Divergence.WorldBehind b) {
            return Json.obj(
                    "tag", Json.str("world_behind"), "resource", encodeResourceId(b.resource()),
                    "recorded", encodeRevision(b.recorded()), "actual", encodeRevision(b.actual()));
        }
        Divergence.UnknownToWorld u = (Divergence.UnknownToWorld) d;
        return Json.obj(
                "tag", Json.str("unknown_to_world"), "resource", encodeResourceId(u.resource()),
                "recorded", encodeRevision(u.recorded()));
    }

    private static Json encodeReconciliation(Reconciliation r) {
        List<Divergence> sorted = new ArrayList<>(r.divergences());
        sorted.sort((a, b) -> {
            ResourceId ra = divergenceResource(a);
            ResourceId rb = divergenceResource(b);
            if (resourceIdLe(ra, rb) && resourceIdLe(rb, ra)) {
                return 0;
            }
            return resourceIdLe(ra, rb) ? -1 : 1;
        });
        return Json.obj(
                "divergences", Json.arr(mapList(sorted, FeatureCheck::encodeDivergence)),
                "unbased", natToJson(r.unbased()), "dropped", natToJson(r.dropped()));
    }

    private static Json opReconcileReconcile(Json input) {
        List<Optional<Basis>> bases = mapList(arrField(input, "bases"), FeatureCheck::decodeOptionBasis);
        World world = decodeWorld(objVal(input, "world"));
        Nat dropped = natField(input, "dropped");
        return encodeReconciliation(Reconcile.reconcile(bases, world, dropped));
    }

    private static Divergence decodeDivergence(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "world_ahead" -> new Divergence.WorldAhead(
                    decodeResourceId(objVal(j, "resource")), decodeRevision(objVal(j, "recorded")),
                    decodeRevision(objVal(j, "actual")));
            case "world_behind" -> new Divergence.WorldBehind(
                    decodeResourceId(objVal(j, "resource")), decodeRevision(objVal(j, "recorded")),
                    decodeRevision(objVal(j, "actual")));
            case "unknown_to_world" -> new Divergence.UnknownToWorld(
                    decodeResourceId(objVal(j, "resource")), decodeRevision(objVal(j, "recorded")));
            default -> throw shape("unknown divergence tag " + tag);
        };
    }

    private static Json opReconcileCoherent(Json input) {
        List<Divergence> divergences = mapList(arrField(input, "divergences"), FeatureCheck::decodeDivergence);
        Nat unbased = natField(input, "unbased");
        Nat dropped = natField(input, "dropped");
        Reconciliation r = new Reconciliation(divergences, unbased, dropped);
        return Json.obj("coherent", Json.bool(Reconcile.coherent(r)));
    }

    /* ---------------------------------------------------------------- Request progression */

    private static RequestPolicy decodeRequestPolicy(Json j) {
        String s = asStr(j);
        return switch (s) {
            case "latestWins" -> RequestPolicy.LATEST_WINS;
            case "fifo" -> RequestPolicy.FIFO;
            case "allExecute" -> RequestPolicy.ALL_EXECUTE;
            default -> throw shape("unknown policy " + s);
        };
    }

    private static Json encodeRequestPolicy(RequestPolicy p) {
        return Json.str(switch (p) {
            case LATEST_WINS -> "latestWins";
            case FIFO -> "fifo";
            case ALL_EXECUTE -> "allExecute";
        });
    }

    private static RequestPhase decodeRequestPhase(Json j) {
        String s = asStr(j);
        return switch (s) {
            case "pending" -> RequestPhase.PENDING;
            case "preparing" -> RequestPhase.PREPARING;
            case "publishing" -> RequestPhase.PUBLISHING;
            case "published" -> RequestPhase.PUBLISHED;
            case "superseded" -> RequestPhase.SUPERSEDED;
            case "cancelled" -> RequestPhase.CANCELLED;
            case "failed" -> RequestPhase.FAILED;
            default -> throw shape("unknown phase " + s);
        };
    }

    private static Json encodeRequestPhase(RequestPhase p) {
        return Json.str(switch (p) {
            case PENDING -> "pending";
            case PREPARING -> "preparing";
            case PUBLISHING -> "publishing";
            case PUBLISHED -> "published";
            case SUPERSEDED -> "superseded";
            case CANCELLED -> "cancelled";
            case FAILED -> "failed";
        });
    }

    private static RequestEffectClass decodeRequestEffectClass(Json j) {
        String s = asStr(j);
        return switch (s) {
            case "pure" -> RequestEffectClass.PURE;
            case "orderedEffect" -> RequestEffectClass.ORDERED_EFFECT;
            default -> throw shape("unknown effect class " + s);
        };
    }

    private static Json encodeRequestEffectClass(RequestEffectClass c) {
        return Json.str(c == RequestEffectClass.PURE ? "pure" : "orderedEffect");
    }

    private static RequestIdentity decodeRequestIdentity(Json j) {
        return new RequestIdentity(strField(j, "kind"), strField(j, "provenance"), natField(j, "revision"));
    }

    private static Json encodeRequestIdentity(RequestIdentity i) {
        return Json.obj(
                "kind", Json.str(i.kind()), "provenance", Json.str(i.provenance()), "revision", natToJson(i.revision()));
    }

    private static RequestFootprint decodeRequestFootprint(Json j) {
        List<String> reads = mapList(arrField(j, "reads"), FeatureCheck::asStr);
        List<String> writes = mapList(arrField(j, "writes"), FeatureCheck::asStr);
        RequestEffectClass effectClass = decodeRequestEffectClass(objVal(j, "effectClass"));
        return new RequestFootprint(reads, writes, effectClass);
    }

    private static Json encodeRequestFootprint(RequestFootprint f) {
        List<Json> reads = mapList(f.reads(), Json::str);
        List<Json> writes = mapList(f.writes(), Json::str);
        return Json.obj(
                "reads", Json.arr(reads), "writes", Json.arr(writes), "effectClass", encodeRequestEffectClass(f.effectClass()));
    }

    private static ResourceDemand decodeResourceDemand(Json j) {
        return new ResourceDemand(natField(j, "pending"), natField(j, "inFlight"), natField(j, "concurrent"));
    }

    private static Json encodeResourceDemand(ResourceDemand d) {
        return Json.obj(
                "pending", natToJson(d.pending()), "inFlight", natToJson(d.inFlight()),
                "concurrent", natToJson(d.concurrent()));
    }

    private static ConfiguredSafetyLimit decodeConfiguredSafetyLimit(Json j) {
        return new ConfiguredSafetyLimit(strField(j, "resource"), natField(j, "maximum"));
    }

    private static Json encodeConfiguredSafetyLimit(ConfiguredSafetyLimit l) {
        return Json.obj("resource", Json.str(l.resource()), "maximum", natToJson(l.maximum()));
    }

    private static ResourceBudget decodeResourceBudget(Json j) {
        return new ResourceBudget(
                decodeConfiguredSafetyLimit(objVal(j, "pendingMaximum")),
                decodeConfiguredSafetyLimit(objVal(j, "inFlightMaximum")),
                decodeConfiguredSafetyLimit(objVal(j, "concurrentMaximum")));
    }

    private static Json encodeResourceBudget(ResourceBudget b) {
        return Json.obj(
                "pendingMaximum", encodeConfiguredSafetyLimit(b.pendingMaximum()),
                "inFlightMaximum", encodeConfiguredSafetyLimit(b.inFlightMaximum()),
                "concurrentMaximum", encodeConfiguredSafetyLimit(b.concurrentMaximum()));
    }

    private static EvidenceVersion decodeEvidenceVersion(Json j) {
        return new EvidenceVersion(strField(j, "identifier"), strField(j, "digest"), strField(j, "artifactPath"));
    }

    private static Json encodeEvidenceVersion(EvidenceVersion e) {
        return Json.obj(
                "identifier", Json.str(e.identifier()), "digest", Json.str(e.digest()),
                "artifactPath", Json.str(e.artifactPath()));
    }

    private static PermissionDenial decodePermissionDenial(Json j) {
        return new PermissionDenial(asStr(j));
    }

    private static Json encodePermissionDenial(PermissionDenial d) {
        return Json.str(d.reason());
    }

    private static MeaningPermission decodeMeaningPermission(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "permitted" -> new MeaningPermission.Permitted(
                    decodeRequestIdentity(objVal(j, "identity")),
                    mapList(arrField(j, "evidence"), FeatureCheck::decodeEvidenceVersion));
            case "ordered" -> new MeaningPermission.Ordered(
                    decodeRequestIdentity(objVal(j, "identity")),
                    mapList(arrField(j, "evidence"), FeatureCheck::decodeEvidenceVersion));
            case "denied" -> new MeaningPermission.Denied(
                    decodeRequestIdentity(objVal(j, "identity")), decodePermissionDenial(objVal(j, "reason")));
            default -> throw shape("unknown meaning permission tag " + tag);
        };
    }

    private static Json encodeMeaningPermission(MeaningPermission p) {
        if (p instanceof MeaningPermission.Permitted permitted) {
            return Json.obj(
                    "tag", Json.str("permitted"), "identity", encodeRequestIdentity(permitted.identity()),
                    "evidence", Json.arr(mapList(permitted.evidence(), FeatureCheck::encodeEvidenceVersion)));
        }
        if (p instanceof MeaningPermission.Ordered ordered) {
            return Json.obj(
                    "tag", Json.str("ordered"), "identity", encodeRequestIdentity(ordered.identity()),
                    "evidence", Json.arr(mapList(ordered.evidence(), FeatureCheck::encodeEvidenceVersion)));
        }
        MeaningPermission.Denied denied = (MeaningPermission.Denied) p;
        return Json.obj(
                "tag", Json.str("denied"), "identity", encodeRequestIdentity(denied.identity()),
                "reason", encodePermissionDenial(denied.reason()));
    }

    private static necoherence.progression.ExecutionHandle decodeExecutionHandle(Json j) {
        return new necoherence.progression.ExecutionHandle(asStr(j));
    }

    private static Json encodeExecutionHandle(necoherence.progression.ExecutionHandle h) {
        return Json.str(h.value());
    }

    private static CostSelection decodeCostSelection(Json j) {
        String tag = strField(j, "tag");
        RequestIdentity identity = decodeRequestIdentity(objVal(j, "identity"));
        EvidenceVersion evidence = decodeEvidenceVersion(objVal(j, "evidence"));
        Nat cost = natField(j, "cost");
        return switch (tag) {
            case "executeNow" -> new CostSelection.ExecuteNow(identity, evidence, cost);
            case "remainPending" -> new CostSelection.RemainPending(identity, evidence, cost);
            default -> throw shape("unknown cost selection tag " + tag);
        };
    }

    private static Json encodeCostSelection(CostSelection s) {
        String tag = s instanceof CostSelection.ExecuteNow ? "executeNow" : "remainPending";
        return Json.obj(
                "tag", Json.str(tag), "identity", encodeRequestIdentity(s.identity()),
                "evidence", encodeEvidenceVersion(s.evidence()), "cost", natToJson(s.cost()));
    }

    private static RequestEntry decodeRequestEntry(Json j) {
        RequestIdentity identity = decodeRequestIdentity(objVal(j, "identity"));
        RequestFootprint footprint = decodeRequestFootprint(objVal(j, "footprint"));
        ResourceDemand demand = decodeResourceDemand(objVal(j, "demand"));
        RequestPhase phase = decodeRequestPhase(objVal(j, "phase"));
        MeaningPermission permission = decodeMeaningPermission(objVal(j, "meaningPermission"));
        Json costSelectionJ = objVal(j, "costSelection");
        Optional<CostSelection> costSelection =
                costSelectionJ instanceof Json.JNull ? Optional.empty() : Optional.of(decodeCostSelection(costSelectionJ));
        Json handleJ = objVal(j, "executionHandle");
        Optional<necoherence.progression.ExecutionHandle> handle =
                handleJ instanceof Json.JNull ? Optional.empty() : Optional.of(decodeExecutionHandle(handleJ));
        return new RequestEntry(identity, footprint, demand, phase, permission, costSelection, handle);
    }

    private static Json encodeRequestEntry(RequestEntry e) {
        return Json.obj(
                "identity", encodeRequestIdentity(e.identity()), "footprint", encodeRequestFootprint(e.footprint()),
                "demand", encodeResourceDemand(e.demand()), "phase", encodeRequestPhase(e.phase()),
                "meaningPermission", encodeMeaningPermission(e.meaningPermission()),
                "costSelection", e.costSelection().<Json>map(FeatureCheck::encodeCostSelection).orElse(Json.NULL),
                "executionHandle", e.executionHandle().<Json>map(FeatureCheck::encodeExecutionHandle).orElse(Json.NULL));
    }

    private static RequestProgressionSnapshot decodeRequestProgressionSnapshot(Json j) {
        RequestPolicy policy = decodeRequestPolicy(objVal(j, "policy"));
        ResourceBudget budget = decodeResourceBudget(objVal(j, "budget"));
        Json currentIdentityJ = objVal(j, "currentIdentity");
        Optional<RequestIdentity> currentIdentity = currentIdentityJ instanceof Json.JNull
                ? Optional.empty() : Optional.of(decodeRequestIdentity(currentIdentityJ));
        List<RequestEntry> entries = mapList(arrField(j, "entries"), FeatureCheck::decodeRequestEntry);
        Nat revision = natField(j, "revision");
        return new RequestProgressionSnapshot(policy, budget, currentIdentity, entries, revision);
    }

    private static Json encodeRequestProgressionSnapshot(RequestProgressionSnapshot s) {
        return Json.obj(
                "policy", encodeRequestPolicy(s.policy()), "budget", encodeResourceBudget(s.budget()),
                "currentIdentity", s.currentIdentity().<Json>map(FeatureCheck::encodeRequestIdentity).orElse(Json.NULL),
                "entries", Json.arr(mapList(s.entries(), FeatureCheck::encodeRequestEntry)),
                "revision", natToJson(s.revision()));
    }

    private static RequestInput decodeRequestInput(Json j) {
        return new RequestInput(
                decodeRequestIdentity(objVal(j, "identity")), decodeRequestFootprint(objVal(j, "footprint")),
                decodeResourceDemand(objVal(j, "demand")), decodeMeaningPermission(objVal(j, "permission")));
    }

    private static Accepted decodeAccepted(Json j) {
        return new Accepted(decodeRequestIdentity(objVal(j, "identity")));
    }

    private static Json encodeAccepted(Accepted a) {
        return Json.obj("identity", encodeRequestIdentity(a.identity()));
    }

    private static Running decodeRunning(Json j) {
        return new Running(decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")));
    }

    private static Json encodeRunning(Running r) {
        return Json.obj("identity", encodeRequestIdentity(r.identity()), "handle", encodeExecutionHandle(r.handle()));
    }

    private static Json encodeAdapterCommand(AdapterCommand c) {
        if (c instanceof AdapterCommand.StartCommand start) {
            return Json.obj(
                    "tag", Json.str("startCommand"), "identity", encodeRequestIdentity(start.identity()),
                    "footprint", encodeRequestFootprint(start.footprint()));
        }
        AdapterCommand.CancelCommand cancel = (AdapterCommand.CancelCommand) c;
        return Json.obj(
                "tag", Json.str("cancelCommand"), "identity", encodeRequestIdentity(cancel.identity()),
                "handle", encodeExecutionHandle(cancel.handle()));
    }

    private static AdapterCommand decodeAdapterCommand(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "startCommand" -> new AdapterCommand.StartCommand(
                    decodeRequestIdentity(objVal(j, "identity")), decodeRequestFootprint(objVal(j, "footprint")));
            case "cancelCommand" -> new AdapterCommand.CancelCommand(
                    decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")));
            default -> throw shape("unknown adapter command tag " + tag);
        };
    }

    private static AdapterSignal<Json> decodeAdapterSignal(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "started" -> new AdapterSignal.Started<>(
                    decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")));
            case "completed" -> new AdapterSignal.Completed<>(
                    decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")),
                    objVal(j, "value"));
            case "cancelledAtAdapter" -> new AdapterSignal.CancelledAtAdapter<>(
                    decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")));
            default -> throw shape("unknown adapter signal tag " + tag);
        };
    }

    private static AdapterFailure decodeAdapterFailure(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "startAdapterFailure" -> new AdapterFailure.StartAdapterFailure(
                    decodeRequestIdentity(objVal(j, "identity")), strField(j, "detail"));
            case "completionAdapterFailure" -> new AdapterFailure.CompletionAdapterFailure(
                    decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")),
                    strField(j, "detail"));
            case "cancellationAdapterFailure" -> new AdapterFailure.CancellationAdapterFailure(
                    decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")),
                    strField(j, "detail"));
            default -> throw shape("unknown adapter failure tag " + tag);
        };
    }

    private static AdapterResult<AdapterSignal<Json>> decodeAdapterResult(Json j) {
        String tag = strField(j, "tag");
        return switch (tag) {
            case "appliedSignal" -> new AdapterResult.AppliedSignal<>(decodeAdapterSignal(objVal(j, "signal")));
            case "adapterFailed" -> new AdapterResult.AdapterFailed<>(decodeAdapterFailure(objVal(j, "failure")));
            default -> throw shape("unknown adapter result tag " + tag);
        };
    }

    private static Json encodeSubmitFailure(SubmitFailure f) {
        if (f instanceof SubmitFailure.DuplicateIdentity d) {
            return Json.obj("tag", Json.str("duplicateIdentity"), "identity", encodeRequestIdentity(d.identity()));
        }
        SubmitFailure.PendingLimitExceeded p = (SubmitFailure.PendingLimitExceeded) f;
        return Json.obj(
                "tag", Json.str("pendingLimitExceeded"), "demand", encodeResourceDemand(p.demand()),
                "budget", encodeResourceBudget(p.budget()));
    }

    private static Json encodeSubmitResult(SubmitResult r) {
        if (r instanceof SubmitResult.SubmitAccepted a) {
            return Json.obj(
                    "tag", Json.str("accepted"), "snapshot", encodeRequestProgressionSnapshot(a.snapshot()),
                    "accepted", encodeAccepted(a.accepted()));
        }
        SubmitResult.SubmitRejected rej = (SubmitResult.SubmitRejected) r;
        return Json.obj(
                "tag", Json.str("submitRejected"), "snapshot", encodeRequestProgressionSnapshot(rej.snapshot()),
                "failure", encodeSubmitFailure(rej.failure()));
    }

    private static Json encodeStartDecisionFailure(StartDecisionFailure f) {
        if (f instanceof StartDecisionFailure.UnknownRequest x) return Json.obj("tag", Json.str("unknownRequest"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof StartDecisionFailure.RequestNotPending x) return Json.obj("tag", Json.str("requestNotPending"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof StartDecisionFailure.PolicyOrderBlocked x) return Json.obj("tag", Json.str("policyOrderBlocked"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof StartDecisionFailure.PermissionDenied x) return Json.obj("tag", Json.str("permissionDenied"), "identity", encodeRequestIdentity(x.identity()), "reason", encodePermissionDenial(x.reason()));
        if (f instanceof StartDecisionFailure.PermissionIdentityMismatch x) return Json.obj("tag", Json.str("permissionIdentityMismatch"), "identity", encodeRequestIdentity(x.identity()), "other", encodeRequestIdentity(x.other()));
        if (f instanceof StartDecisionFailure.PermissionNotOrdered x) return Json.obj("tag", Json.str("permissionNotOrdered"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof StartDecisionFailure.CostSelectionIdentityMismatch x) return Json.obj("tag", Json.str("costSelectionIdentityMismatch"), "identity", encodeRequestIdentity(x.identity()), "other", encodeRequestIdentity(x.other()));
        if (f instanceof StartDecisionFailure.InFlightLimitExceeded x) return Json.obj("tag", Json.str("inFlightLimitExceeded"), "demand", encodeResourceDemand(x.demand()), "budget", encodeResourceBudget(x.budget()));
        StartDecisionFailure.ConcurrentLimitExceeded x = (StartDecisionFailure.ConcurrentLimitExceeded) f;
        return Json.obj("tag", Json.str("concurrentLimitExceeded"), "demand", encodeResourceDemand(x.demand()), "budget", encodeResourceBudget(x.budget()));
    }

    private static Json encodeStarting(Starting s) {
        return Json.obj("identity", encodeRequestIdentity(s.identity()), "command", encodeAdapterCommand(s.command()));
    }

    private static Starting decodeStarting(Json j) {
        return new Starting(decodeRequestIdentity(objVal(j, "identity")), decodeAdapterCommand(objVal(j, "command")));
    }

    private static Json encodeStartDecisionResult(StartDecisionResult r) {
        if (r instanceof StartDecisionResult.Execute x) return Json.obj("tag", Json.str("execute"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "starting", encodeStarting(x.starting()), "command", encodeAdapterCommand(x.command()));
        if (r instanceof StartDecisionResult.Deferred x) return Json.obj("tag", Json.str("deferred"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "accepted", encodeAccepted(x.accepted()));
        StartDecisionResult.Rejected x = (StartDecisionResult.Rejected) r;
        return Json.obj("tag", Json.str("rejected"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "failure", encodeStartDecisionFailure(x.failure()));
    }

    private static Json encodeStartObservationFailure(StartObservationFailure f) {
        if (f instanceof StartObservationFailure.UnknownRequest x) return Json.obj("tag", Json.str("unknownRequest"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof StartObservationFailure.RequestNotStarting x) return Json.obj("tag", Json.str("requestNotStarting"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof StartObservationFailure.StartIdentityMismatch x) return Json.obj("tag", Json.str("startIdentityMismatch"), "identity", encodeRequestIdentity(x.identity()), "other", encodeRequestIdentity(x.other()));
        if (f instanceof StartObservationFailure.StartSignalMismatch x) return Json.obj("tag", Json.str("startSignalMismatch"), "identity", encodeRequestIdentity(x.identity()));
        StartObservationFailure.StartAdapterFailureObserved x = (StartObservationFailure.StartAdapterFailureObserved) f;
        return Json.obj("tag", Json.str("startAdapterFailureObserved"), "identity", encodeRequestIdentity(x.identity()), "detail", Json.str(x.detail()));
    }

    private static Json encodeStartObservationResult(StartObservationResult r) {
        if (r instanceof StartObservationResult.Publishing x) return Json.obj("tag", Json.str("publishing"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "running", encodeRunning(x.running()));
        StartObservationResult.Failed x = (StartObservationResult.Failed) r;
        return Json.obj("tag", Json.str("failed"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "failure", encodeStartObservationFailure(x.failure()));
    }

    private static Json encodeCompletionObservationFailure(CompletionObservationFailure f) {
        if (f instanceof CompletionObservationFailure.UnknownCompletion x) return Json.obj("tag", Json.str("unknownCompletion"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof CompletionObservationFailure.CompletionNotRunning x) return Json.obj("tag", Json.str("completionNotRunning"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof CompletionObservationFailure.HandleMismatch x) return Json.obj("tag", Json.str("handleMismatch"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof CompletionObservationFailure.CompletionIdentityMismatch x) return Json.obj("tag", Json.str("completionIdentityMismatch"), "identity", encodeRequestIdentity(x.identity()), "other", encodeRequestIdentity(x.other()));
        if (f instanceof CompletionObservationFailure.CompletionSignalMismatch x) return Json.obj("tag", Json.str("completionSignalMismatch"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof CompletionObservationFailure.CompletionAdapterFailureObserved x) return Json.obj("tag", Json.str("completionAdapterFailureObserved"), "identity", encodeRequestIdentity(x.identity()), "detail", Json.str(x.detail()));
        CompletionObservationFailure.CancellationAdapterFailureObserved x = (CompletionObservationFailure.CancellationAdapterFailureObserved) f;
        return Json.obj("tag", Json.str("cancellationAdapterFailureObserved"), "identity", encodeRequestIdentity(x.identity()), "detail", Json.str(x.detail()));
    }

    private static Json encodeCompletionObservationResult(CompletionObservationResult<Json> r) {
        if (r instanceof CompletionObservationResult.Applied<Json> x) return Json.obj("tag", Json.str("applied"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "identity", encodeRequestIdentity(x.identity()), "value", x.value());
        if (r instanceof CompletionObservationResult.Superseded<Json> x) return Json.obj("tag", Json.str("superseded"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "identity", encodeRequestIdentity(x.identity()));
        if (r instanceof CompletionObservationResult.Cancelled<Json> x) return Json.obj("tag", Json.str("cancelled"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "identity", encodeRequestIdentity(x.identity()));
        CompletionObservationResult.Failed<Json> x = (CompletionObservationResult.Failed<Json>) r;
        return Json.obj("tag", Json.str("failed"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "failure", encodeCompletionObservationFailure(x.failure()));
    }

    private static Json encodeCancelFailure(CancelFailure f) {
        if (f instanceof CancelFailure.UnknownRequest x) return Json.obj("tag", Json.str("unknownRequest"), "identity", encodeRequestIdentity(x.identity()));
        if (f instanceof CancelFailure.RequestAlreadyTerminal x) return Json.obj("tag", Json.str("requestAlreadyTerminal"), "identity", encodeRequestIdentity(x.identity()));
        CancelFailure.MissingExecutionHandle x = (CancelFailure.MissingExecutionHandle) f;
        return Json.obj("tag", Json.str("missingExecutionHandle"), "identity", encodeRequestIdentity(x.identity()));
    }

    private static Json encodeCancelDecisionResult(CancelDecisionResult r) {
        if (r instanceof CancelDecisionResult.Cancelled x) return Json.obj("tag", Json.str("cancelled"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "identity", encodeRequestIdentity(x.identity()));
        if (r instanceof CancelDecisionResult.CancelCommand x) return Json.obj("tag", Json.str("cancelCommand"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "running", encodeRunning(x.running()), "command", encodeAdapterCommand(x.command()));
        CancelDecisionResult.Rejected x = (CancelDecisionResult.Rejected) r;
        return Json.obj("tag", Json.str("rejected"), "snapshot", encodeRequestProgressionSnapshot(x.snapshot()), "failure", encodeCancelFailure(x.failure()));
    }

    private static Json opRequestProgressionEmpty(Json input) {
        RequestPolicy policy = decodeRequestPolicy(objVal(input, "policy"));
        ResourceBudget budget = decodeResourceBudget(objVal(input, "budget"));
        return encodeRequestProgressionSnapshot(Progression.empty(policy, budget));
    }

    private static Json opRequestProgressionSubmit(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        RequestInput request = decodeRequestInput(objVal(input, "request"));
        return encodeSubmitResult(Progression.submit(snapshot, request));
    }

    private static Json opRequestProgressionDecideStart(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        Accepted accepted = decodeAccepted(objVal(input, "accepted"));
        CostSelection selection = decodeCostSelection(objVal(input, "selection"));
        return encodeStartDecisionResult(Progression.decideStart(snapshot, accepted, selection));
    }

    private static Json opRequestProgressionApplyStartObservation(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        Starting starting = decodeStarting(objVal(input, "starting"));
        AdapterResult<AdapterSignal<Json>> observed = decodeAdapterResult(objVal(input, "observed"));
        return encodeStartObservationResult(Progression.applyStartObservation(snapshot, starting, observed));
    }

    private static Json opRequestProgressionApplyCompletionObservation(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        Running running = decodeRunning(objVal(input, "running"));
        AdapterResult<AdapterSignal<Json>> observed = decodeAdapterResult(objVal(input, "observed"));
        return encodeCompletionObservationResult(Progression.applyCompletionObservation(snapshot, running, observed));
    }

    private static Json opRequestProgressionDecideCancel(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        RequestIdentity identity = decodeRequestIdentity(objVal(input, "identity"));
        return encodeCancelDecisionResult(Progression.decideCancel(snapshot, identity));
    }

    private static Json opRequestProgressionDerivePending(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        return encodeResourceDemand(Progression.derivePending(snapshot));
    }

    private static Json opRequestProgressionDeriveInFlight(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        return encodeResourceDemand(Progression.deriveInFlight(snapshot));
    }

    private static Json opRequestProgressionDeriveConcurrent(Json input) {
        RequestProgressionSnapshot snapshot = decodeRequestProgressionSnapshot(objVal(input, "snapshot"));
        return encodeResourceDemand(Progression.deriveConcurrent(snapshot));
    }

    /* ---------------------------------------------------------------- Dynamic admission */

    private static EnvironmentSpecification decodeEnvironmentSpecification(Json j) {
        return new EnvironmentSpecification(natField(j, "maxObservationAge"));
    }

    private static CapacityObservation decodeCapacityObservation(Json j) {
        return new CapacityObservation(decodeResourceBudget(objVal(j, "observed")), natField(j, "observedAt"));
    }

    private static SignalKind decodeSignalKind(Json j) {
        String s = asStr(j);
        return switch (s) {
            case "pendingCompletion" -> SignalKind.PENDING_COMPLETION;
            case "pendingCancellation" -> SignalKind.PENDING_CANCELLATION;
            default -> throw shape("unknown signal kind " + s);
        };
    }

    private static Json encodeSignalKind(SignalKind k) {
        return Json.str(k == SignalKind.PENDING_COMPLETION ? "pendingCompletion" : "pendingCancellation");
    }

    private static AdmissionSignal decodeAdmissionSignal(Json j) {
        return new AdmissionSignal(
                decodeRequestIdentity(objVal(j, "identity")), decodeExecutionHandle(objVal(j, "handle")),
                decodeSignalKind(objVal(j, "kind")));
    }

    private static Json encodeAdmissionSignal(AdmissionSignal s) {
        return Json.obj(
                "identity", encodeRequestIdentity(s.identity()), "handle", encodeExecutionHandle(s.handle()),
                "kind", encodeSignalKind(s.kind()));
    }

    private static AdmissionProvenance decodeAdmissionProvenance(Json j) {
        List<RequestIdentity> futureUses = mapList(arrField(j, "futureUses"), FeatureCheck::decodeRequestIdentity);
        List<AdmissionSignal> outstandingSignals =
                mapList(arrField(j, "outstandingSignals"), FeatureCheck::decodeAdmissionSignal);
        return new AdmissionProvenance(futureUses, outstandingSignals);
    }

    private static Json encodeAdmissionProvenance(AdmissionProvenance p) {
        return Json.obj(
                "futureUses", Json.arr(mapList(p.futureUses(), FeatureCheck::encodeRequestIdentity)),
                "outstandingSignals", Json.arr(mapList(p.outstandingSignals(), FeatureCheck::encodeAdmissionSignal)));
    }

    private static DynamicAdmissionState decodeDynamicAdmissionState(Json j) {
        RequestProgressionSnapshot progression = decodeRequestProgressionSnapshot(objVal(j, "progression"));
        ResourceBudget configured = decodeResourceBudget(objVal(j, "configuredSafetyLimit"));
        AdmissionProvenance provenance = decodeAdmissionProvenance(objVal(j, "provenance"));
        return new DynamicAdmissionState(progression, configured, provenance);
    }

    private static Json encodeDynamicAdmissionState(DynamicAdmissionState s) {
        return Json.obj(
                "progression", encodeRequestProgressionSnapshot(s.progression()),
                "configuredSafetyLimit", encodeResourceBudget(s.configuredSafetyLimit()),
                "provenance", encodeAdmissionProvenance(s.provenance()));
    }

    private static DynamicAdmissionInput decodeDynamicAdmissionInput(Json j) {
        DynamicAdmissionState state = decodeDynamicAdmissionState(objVal(j, "state"));
        RequestInput request = decodeRequestInput(objVal(j, "request"));
        EnvironmentSpecification env = decodeEnvironmentSpecification(objVal(j, "environmentSpecification"));
        CapacityObservation capacityObservation = decodeCapacityObservation(objVal(j, "capacityObservation"));
        Nat observedAt = natField(j, "observedAt");
        Json startJ = objVal(j, "start");
        Optional<CostSelection> start =
                startJ instanceof Json.JNull ? Optional.empty() : Optional.of(decodeCostSelection(startJ));
        return new DynamicAdmissionInput(state, request, env, capacityObservation, observedAt, start);
    }

    private static Json encodeDynamicAdmissionFailure(DynamicAdmissionFailure f) {
        if (f instanceof DynamicAdmissionFailure.CapacityObservationUnavailable x) {
            return Json.obj(
                    "tag", Json.str("capacityObservationUnavailable"), "age", natToJson(x.age()),
                    "maxAge", natToJson(x.maxAge()));
        }
        if (f instanceof DynamicAdmissionFailure.ResourceCoordinateMismatch x) {
            return Json.obj(
                    "tag", Json.str("resourceCoordinateMismatch"), "configuredResource", Json.str(x.configuredResource()),
                    "observedResource", Json.str(x.observedResource()));
        }
        if (f instanceof DynamicAdmissionFailure.ConfiguredSafetyLimitExceeded x) {
            return Json.obj(
                    "tag", Json.str("configuredSafetyLimitExceeded"), "resource", Json.str(x.resource()),
                    "occupied", natToJson(x.occupied()), "allowed", natToJson(x.allowed()));
        }
        if (f instanceof DynamicAdmissionFailure.MeaningDenied x) {
            return Json.obj(
                    "tag", Json.str("meaningDenied"), "identity", encodeRequestIdentity(x.identity()),
                    "reason", encodePermissionDenial(x.reason()));
        }
        if (f instanceof DynamicAdmissionFailure.PermissionIdentityMismatch x) {
            return Json.obj(
                    "tag", Json.str("permissionIdentityMismatch"), "requestIdentity", encodeRequestIdentity(x.requestIdentity()),
                    "permissionIdentity", encodeRequestIdentity(x.permissionIdentity()));
        }
        if (f instanceof DynamicAdmissionFailure.AdapterBindingUnavailable x) {
            return Json.obj("tag", Json.str("adapterBindingUnavailable"), "identity", encodeRequestIdentity(x.identity()));
        }
        if (f instanceof DynamicAdmissionFailure.BindingSelectionMismatch x) {
            return Json.obj("tag", Json.str("bindingSelectionMismatch"), "identity", encodeRequestIdentity(x.identity()));
        }
        if (f instanceof DynamicAdmissionFailure.ProgressionSubmitFailure x) {
            return Json.obj("tag", Json.str("progressionSubmitFailure"), "failure", encodeSubmitFailure(x.failure()));
        }
        if (f instanceof DynamicAdmissionFailure.ProgressionStartFailure x) {
            return Json.obj("tag", Json.str("progressionStartFailure"), "failure", encodeStartDecisionFailure(x.failure()));
        }
        if (f instanceof DynamicAdmissionFailure.ProvenanceRetentionRequired x) {
            return Json.obj("tag", Json.str("provenanceRetentionRequired"), "identity", encodeRequestIdentity(x.identity()));
        }
        if (f instanceof DynamicAdmissionFailure.UnknownRequest x) {
            return Json.obj("tag", Json.str("unknownRequest"), "identity", encodeRequestIdentity(x.identity()));
        }
        DynamicAdmissionFailure.RequestNotTerminal x = (DynamicAdmissionFailure.RequestNotTerminal) f;
        return Json.obj("tag", Json.str("requestNotTerminal"), "identity", encodeRequestIdentity(x.identity()));
    }

    private static Json encodeAdmissionDecision(AdmissionDecision d) {
        if (d instanceof AdmissionDecision.Submitted s) {
            return Json.obj(
                    "tag", Json.str("submitted"), "state", encodeDynamicAdmissionState(s.state()),
                    "accepted", encodeAccepted(s.accepted()));
        }
        if (d instanceof AdmissionDecision.Started s) {
            return Json.obj(
                    "tag", Json.str("started"), "state", encodeDynamicAdmissionState(s.state()),
                    "result", encodeStartDecisionResult(s.result()));
        }
        AdmissionDecision.Coalesced c = (AdmissionDecision.Coalesced) d;
        return Json.obj(
                "tag", Json.str("coalesced"), "state", encodeDynamicAdmissionState(c.state()),
                "identity", encodeRequestIdentity(c.identity()));
    }

    private static Json encodeProvenanceErasureWitness(ProvenanceErasureWitness w) {
        if (w instanceof ProvenanceErasureWitness.Erased e) {
            return Json.obj("tag", Json.str("erased"), "identity", encodeRequestIdentity(e.identity()));
        }
        ProvenanceErasureWitness.Retained r = (ProvenanceErasureWitness.Retained) w;
        return Json.obj(
                "tag", Json.str("retained"), "identity", encodeRequestIdentity(r.identity()), "reason", Json.str(r.reason()));
    }

    private static Json encodeCoalescingWitness(CoalescingWitness w) {
        if (w instanceof CoalescingWitness.Coalesced c) {
            return Json.obj("tag", Json.str("coalesced"), "identity", encodeRequestIdentity(c.identity()));
        }
        CoalescingWitness.NotCoalesced n = (CoalescingWitness.NotCoalesced) w;
        return Json.obj("tag", Json.str("notCoalesced"), "reason", Json.str(n.reason()));
    }

    private static Json encodeDynamicAdmissionResult(DynamicAdmissionResult r) {
        return Json.obj(
                "effectiveBudget", encodeResourceBudget(r.effectiveBudget()),
                "admissionDecision", encodeAdmissionDecision(r.admissionDecision()),
                "futureUseSet", Json.arr(mapList(r.futureUseSet().identities(), FeatureCheck::encodeRequestIdentity)),
                "outstandingSignalSet",
                Json.arr(mapList(r.outstandingSignalSet().signals(), FeatureCheck::encodeAdmissionSignal)),
                "provenanceErasureWitness",
                r.provenanceErasureWitness().<Json>map(FeatureCheck::encodeProvenanceErasureWitness).orElse(Json.NULL),
                "coalescingWitness", encodeCoalescingWitness(r.coalescingWitness()));
    }

    private static Json encodeDynamicAdmissionOutcome(
            Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> o) {
        if (o instanceof Outcome.Applied<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> applied) {
            return Json.obj("tag", Json.str("applied"), "value", encodeDynamicAdmissionResult(applied.value()));
        }
        Outcome.Rejected<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> rejected =
                (Outcome.Rejected<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never>) o;
        return Json.obj("tag", Json.str("rejected"), "failure", encodeDynamicAdmissionFailure(rejected.reason()));
    }

    private static Json encodeElisionOutcome(
            Outcome<Admission.ElisionApplied, DynamicAdmissionFailure, Never, Never> o) {
        if (o instanceof Outcome.Applied<Admission.ElisionApplied, DynamicAdmissionFailure, Never, Never> applied) {
            return Json.obj(
                    "tag", Json.str("applied"), "state", encodeDynamicAdmissionState(applied.value().state()),
                    "witness", encodeProvenanceErasureWitness(applied.value().witness()));
        }
        Outcome.Rejected<Admission.ElisionApplied, DynamicAdmissionFailure, Never, Never> rejected =
                (Outcome.Rejected<Admission.ElisionApplied, DynamicAdmissionFailure, Never, Never>) o;
        return Json.obj("tag", Json.str("rejected"), "failure", encodeDynamicAdmissionFailure(rejected.reason()));
    }

    private static Json opDynamicAdmissionElideAdmissionProvenance(Json input) {
        DynamicAdmissionState state = decodeDynamicAdmissionState(objVal(input, "state"));
        RequestIdentity identity = decodeRequestIdentity(objVal(input, "identity"));
        return encodeElisionOutcome(Admission.elideAdmissionProvenance(state, identity));
    }

    private static Json opDynamicAdmissionAdmitDynamicRequest(Json input) {
        DynamicAdmissionInput admissionInput = decodeDynamicAdmissionInput(input);
        return encodeDynamicAdmissionOutcome(Admission.admitDynamicRequest(admissionInput));
    }

    /* ---------------------------------------------------------------- File effect */

    private static NormalizedPath decodeNormalizedPath(Json j) {
        boolean root = asBool(objVal(j, "root"));
        List<String> segments = mapList(arrField(j, "segments"), FeatureCheck::asStr);
        return new NormalizedPath(root, segments);
    }

    private static Json encodeNormalizedPath(NormalizedPath p) {
        return Json.obj("root", Json.bool(p.root()), "segments", Json.arr(mapList(p.segments(), Json::str)));
    }

    private static ContentDigest decodeContentDigest(Json j) {
        return new ContentDigest(asStr(j));
    }

    private static Json encodeContentDigest(ContentDigest d) {
        return Json.str(d.value());
    }

    private static byte decodeByte(Json j) {
        Nat n = natOfStr(asStr(j));
        if (n.compareTo(Nat.fromLong(256)) >= 0) {
            throw shape("byte out of range");
        }
        return (byte) n.intValue();
    }

    private static Json encodeByte(byte b) {
        return natToJson(Nat.fromLong(b & 0xFF));
    }

    private static List<Byte> decodeBytes(Json j) {
        List<Byte> out = new ArrayList<>();
        for (Json item : asArr(j)) {
            out.add(decodeByte(item));
        }
        return out;
    }

    private static Json encodeBytes(List<Byte> bytes) {
        List<Json> items = new ArrayList<>();
        for (Byte b : bytes) {
            items.add(encodeByte(b));
        }
        return Json.arr(items);
    }

    private static FileRecord decodeFileRecord(Json j) {
        return new FileRecord(decodeContentDigest(objVal(j, "digest")), decodeBytes(objVal(j, "bytes")));
    }

    private static Json encodeFileRecord(FileRecord r) {
        return Json.obj("digest", encodeContentDigest(r.digest()), "bytes", encodeBytes(r.bytes()));
    }

    private static ExternalFileState decodeExternalFileState(Json j) {
        List<ExternalFileState.PathRecord> files = new ArrayList<>();
        for (Json e : arrField(j, "files")) {
            NormalizedPath path = decodeNormalizedPath(objVal(e, "path"));
            FileRecord record = decodeFileRecord(objVal(e, "record"));
            files.add(new ExternalFileState.PathRecord(path, record));
        }
        List<NormalizedPath> readFailures = mapList(arrField(j, "readFailures"), FeatureCheck::decodeNormalizedPath);
        List<NormalizedPath> writeFailures = mapList(arrField(j, "writeFailures"), FeatureCheck::decodeNormalizedPath);
        return new ExternalFileState(files, readFailures, writeFailures);
    }

    private static Json encodeExternalFileState(ExternalFileState s) {
        List<Json> files = new ArrayList<>();
        for (ExternalFileState.PathRecord e : s.files()) {
            files.add(Json.obj("path", encodeNormalizedPath(e.path()), "record", encodeFileRecord(e.record())));
        }
        return Json.obj(
                "files", Json.arr(files), "readFailures", Json.arr(mapList(s.readFailures(), FeatureCheck::encodeNormalizedPath)),
                "writeFailures", Json.arr(mapList(s.writeFailures(), FeatureCheck::encodeNormalizedPath)));
    }

    private static Digests decodeDigests(Json j) {
        List<Digests.Entry> entries = new ArrayList<>();
        for (Json e : asArr(j)) {
            entries.add(new Digests.Entry(decodeResourceId(objVal(e, "resource")), decodeContentDigest(objVal(e, "digest"))));
        }
        return new Digests(entries);
    }

    private static Json encodeDigests(Digests d) {
        List<Json> items = new ArrayList<>();
        for (Digests.Entry e : d.entries()) {
            items.add(Json.obj("resource", encodeResourceId(e.resource()), "digest", encodeContentDigest(e.digest())));
        }
        return Json.arr(items);
    }

    private static Json encodeDigestLookup(DigestLookup l) {
        if (l instanceof DigestLookup.Found f) {
            return Json.obj("tag", Json.str("found"), "digest", encodeContentDigest(f.digest()));
        }
        DigestLookup.Unobserved u = (DigestLookup.Unobserved) l;
        return Json.obj("tag", Json.str("unobserved"), "resource", encodeResourceId(u.unobservedContents().resource()));
    }

    private static Json encodeObservation(Function<Object, Json> encodePayload, Observation<?> o) {
        return Json.obj(
                "payload", encodePayload.apply(o.payload()), "basis", encodeBasis(o.basis()),
                "observedAt", natToJson(o.observedAt()));
    }

    private static Json encodeFileSnapshot(FileSnapshot s) {
        return Json.obj(
                "path", encodeNormalizedPath(s.path()), "contents", encodeBytes(s.contents()),
                "digest", encodeContentDigest(s.digest()));
    }

    @SuppressWarnings("unchecked")
    private static Json encodeTrackResult(Outcome<FileEffect.Tracked, Never, Never, Never> o) {
        Outcome.Applied<FileEffect.Tracked, Never, Never, Never> applied =
                (Outcome.Applied<FileEffect.Tracked, Never, Never, Never>) o;
        return Json.obj(
                "tag", Json.str("applied"),
                "observation", encodeObservation(p -> encodeRevision((Revision) p), applied.value().observation()),
                "world", encodeWorld(applied.value().world()));
    }

    private static Json encodeReadResult(Outcome<FileEffect.Read, UnknownResource, Never, ReadFailure> o) {
        if (o instanceof Outcome.Applied<FileEffect.Read, UnknownResource, Never, ReadFailure> applied) {
            return Json.obj(
                    "tag", Json.str("applied"),
                    "observation", encodeObservation(p -> encodeFileSnapshot((FileSnapshot) p), applied.value().observation()),
                    "world", encodeWorld(applied.value().world()), "digests", encodeDigests(applied.value().digests()));
        }
        if (o instanceof Outcome.Rejected<FileEffect.Read, UnknownResource, Never, ReadFailure> rejected) {
            return Json.obj("tag", Json.str("rejected"), "resource", encodeResourceId(rejected.reason().resource()));
        }
        Outcome.BoundaryFailed<FileEffect.Read, UnknownResource, Never, ReadFailure> boundary =
                (Outcome.BoundaryFailed<FileEffect.Read, UnknownResource, Never, ReadFailure>) o;
        return Json.obj("tag", Json.str("boundaryFailed"), "path", encodeNormalizedPath(boundary.failure().path()));
    }

    private static ReplaceContents decodeReplaceContents(Json j) {
        return new ReplaceContents(decodeBytes(objVal(j, "newContents")), decodeContentDigest(objVal(j, "newDigest")));
    }

    private static Json encodeReplaceRejection(ReplaceRejection r) {
        if (r instanceof ReplaceRejection.ResourcePathMismatchRejection m) {
            ResourcePathMismatch mismatch = m.mismatch();
            return Json.obj(
                    "tag", Json.str("resourcePathMismatch"), "resource", encodeResourceId(mismatch.resource()),
                    "path", encodeNormalizedPath(mismatch.path()));
        }
        if (r instanceof ReplaceRejection.UnknownResourceRejection u) {
            return Json.obj("tag", Json.str("unknownResource"), "resource", encodeResourceId(u.unknownResource().resource()));
        }
        ReplaceRejection.UnobservedContentsRejection u = (ReplaceRejection.UnobservedContentsRejection) r;
        return Json.obj(
                "tag", Json.str("unobservedContents"), "resource", encodeResourceId(u.unobservedContents().resource()));
    }

    private static Json encodeReplaceConflict(ReplaceConflict c) {
        if (c instanceof ReplaceConflict.StaleBasisConflict s) {
            StaleBasis sb = s.staleBasis();
            return Json.obj(
                    "tag", Json.str("staleBasis"), "expected", encodeRevision(sb.expected()),
                    "actual", encodeRevision(sb.actual()));
        }
        ReplaceConflict.ExternalMutationConflict m = (ReplaceConflict.ExternalMutationConflict) c;
        ExternalMutation mutation = m.mutation();
        return Json.obj(
                "tag", Json.str("externalMutation"), "expected", encodeContentDigest(mutation.expected()),
                "actual", encodeContentDigest(mutation.actual()));
    }

    private static Json encodeReplaceResult(Outcome<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> o) {
        if (o instanceof Outcome.Applied<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> applied) {
            return Json.obj(
                    "tag", Json.str("applied"),
                    "observation", encodeObservation(p -> encodeFileSnapshot((FileSnapshot) p), applied.value().observation()),
                    "world", encodeWorld(applied.value().world()), "digests", encodeDigests(applied.value().digests()),
                    "state", encodeExternalFileState(applied.value().state()));
        }
        if (o instanceof Outcome.Rejected<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> rejected) {
            return Json.obj("tag", Json.str("rejected"), "rejection", encodeReplaceRejection(rejected.reason()));
        }
        if (o instanceof Outcome.Conflicted<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> conflicted) {
            return Json.obj("tag", Json.str("conflicted"), "conflict", encodeReplaceConflict(conflicted.conflict()));
        }
        Outcome.BoundaryFailed<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> boundary =
                (Outcome.BoundaryFailed<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure>) o;
        return Json.obj("tag", Json.str("boundaryFailed"), "path", encodeNormalizedPath(boundary.failure().path()));
    }

    private static Json opFileEffectNormalizePath(Json input) {
        boolean root = asBool(objVal(input, "root"));
        List<String> raw = mapList(arrField(input, "raw"), FeatureCheck::asStr);
        return encodeNormalizedPath(FileEffect.normalizePath(root, raw));
    }

    private static Json opFileEffectLookupDigest(Json input) {
        Digests digests = decodeDigests(objVal(input, "digests"));
        ResourceId resource = decodeResourceId(objVal(input, "resource"));
        return encodeDigestLookup(FileEffect.lookupDigest(digests, resource));
    }

    private static Json opFileEffectSetDigest(Json input) {
        Digests digests = decodeDigests(objVal(input, "digests"));
        ResourceId resource = decodeResourceId(objVal(input, "resource"));
        ContentDigest digest = decodeContentDigest(objVal(input, "digest"));
        return encodeDigests(FileEffect.setDigest(digests, resource, digest));
    }

    private static Json opFileEffectTrack(Json input) {
        NormalizedPath path = decodeNormalizedPath(objVal(input, "path"));
        World world = decodeWorld(objVal(input, "world"));
        Nat observedAt = natField(input, "observedAt");
        return encodeTrackResult(FileEffect.track(new FileEffect.TrackReq(path, world, observedAt)));
    }

    private static Json opFileEffectRead(Json input) {
        NormalizedPath path = decodeNormalizedPath(objVal(input, "path"));
        World world = decodeWorld(objVal(input, "world"));
        Digests digests = decodeDigests(objVal(input, "digests"));
        ExternalFileState state = decodeExternalFileState(objVal(input, "state"));
        Nat observedAt = natField(input, "observedAt");
        return encodeReadResult(FileEffect.read(new FileEffect.ReadReq(path, world, digests, state, observedAt)));
    }

    private static Json opFileEffectReplace(Json input) {
        ReplaceContents intent = decodeReplaceContents(objVal(input, "intent"));
        Basis basis = decodeBasis(objVal(input, "basis"));
        Command<ReplaceContents> command = new Command<>(intent, basis);
        NormalizedPath path = decodeNormalizedPath(objVal(input, "path"));
        World world = decodeWorld(objVal(input, "world"));
        Digests digests = decodeDigests(objVal(input, "digests"));
        ExternalFileState state = decodeExternalFileState(objVal(input, "state"));
        Nat observedAt = natField(input, "observedAt");
        return encodeReplaceResult(
                FileEffect.replace(new FileEffect.ReplaceReq(command, path, world, digests, state, observedAt)));
    }

    /* ---------------------------------------------------------------- Surface inventory */

    private record SurfaceEntry(String feature, List<String> operations) {
    }

    private static final List<SurfaceEntry> SURFACE_ENTRIES = List.of(
            new SurfaceEntry("core", List.of("lookup", "bump", "commandOf", "apply")),
            new SurfaceEntry("call", List.of("immediateOf", "deferredOf", "io", "issue")),
            new SurfaceEntry("iteration", List.of("fold", "recurse", "closure")),
            new SurfaceEntry("store", List.of("storeOf", "storeEntries", "observe", "apply", "worldOf")),
            new SurfaceEntry("record", List.of("recordOf", "recordOnBasis", "hasEdge")),
            new SurfaceEntry("reconcile", List.of("reconcile", "coherent")),
            new SurfaceEntry(
                    "request_progression",
                    List.of("empty", "submit", "decideStart", "applyStartObservation",
                            "applyCompletionObservation", "decideCancel", "derivePending", "deriveInFlight",
                            "deriveConcurrent")),
            new SurfaceEntry("dynamic_admission", List.of("elideAdmissionProvenance", "admitDynamicRequest")),
            new SurfaceEntry("step_transition", List.of("step")),
            new SurfaceEntry("file_effect", List.of("normalizePath", "lookupDigest", "setDigest", "track", "read", "replace")));

    private static final List<String> KNOWN_FEATURES = mapList(SURFACE_ENTRIES, SurfaceEntry::feature);

    private static Json surfaceJson() {
        List<Json> features = new ArrayList<>();
        for (SurfaceEntry entry : SURFACE_ENTRIES) {
            features.add(Json.obj(
                    "feature", Json.str(entry.feature()), "operations", Json.arr(mapList(entry.operations(), Json::str))));
        }
        return Json.obj("kind", Json.str("surface"), "features", Json.arr(features));
    }

    /* ---------------------------------------------------------------- Dispatch */

    private static Json dispatch(String feature, String operation, Json input) {
        String key = feature + "." + operation;
        return switch (key) {
            case "core.lookup" -> opCoreLookup(input);
            case "core.bump" -> opCoreBump(input);
            case "core.commandOf" -> opCoreCommandOf(input);
            case "core.apply" -> opCoreApply(input);
            case "call.immediateOf" -> opCallImmediateOf(input);
            case "call.deferredOf" -> opCallDeferredOf(input);
            case "call.io" -> opCallIo(input);
            case "call.issue" -> opCallIssue(input);
            case "iteration.fold" -> opIterationFold(input);
            case "iteration.recurse" -> opIterationRecurse(input);
            case "iteration.closure" -> opIterationClosure(input);
            case "store.storeOf" -> opStoreStoreOf(input);
            case "store.storeEntries" -> opStoreStoreEntries(input);
            case "store.observe" -> opStoreObserve(input);
            case "store.apply" -> opStoreApply(input);
            case "store.worldOf" -> opStoreWorldOf(input);
            case "record.recordOf" -> opRecordRecordOf(input);
            case "record.recordOnBasis" -> opRecordRecordOnBasis(input);
            case "record.hasEdge" -> opRecordHasEdge(input);
            case "reconcile.reconcile" -> opReconcileReconcile(input);
            case "reconcile.coherent" -> opReconcileCoherent(input);
            case "request_progression.empty" -> opRequestProgressionEmpty(input);
            case "request_progression.submit" -> opRequestProgressionSubmit(input);
            case "request_progression.decideStart" -> opRequestProgressionDecideStart(input);
            case "request_progression.applyStartObservation" -> opRequestProgressionApplyStartObservation(input);
            case "request_progression.applyCompletionObservation" -> opRequestProgressionApplyCompletionObservation(input);
            case "request_progression.decideCancel" -> opRequestProgressionDecideCancel(input);
            case "request_progression.derivePending" -> opRequestProgressionDerivePending(input);
            case "request_progression.deriveInFlight" -> opRequestProgressionDeriveInFlight(input);
            case "request_progression.deriveConcurrent" -> opRequestProgressionDeriveConcurrent(input);
            case "dynamic_admission.elideAdmissionProvenance" -> opDynamicAdmissionElideAdmissionProvenance(input);
            case "dynamic_admission.admitDynamicRequest" -> opDynamicAdmissionAdmitDynamicRequest(input);
            case "step_transition.step" -> opStepTransitionStep(input);
            case "file_effect.normalizePath" -> opFileEffectNormalizePath(input);
            case "file_effect.lookupDigest" -> opFileEffectLookupDigest(input);
            case "file_effect.setDigest" -> opFileEffectSetDigest(input);
            case "file_effect.track" -> opFileEffectTrack(input);
            case "file_effect.read" -> opFileEffectRead(input);
            case "file_effect.replace" -> opFileEffectReplace(input);
            default -> {
                if (KNOWN_FEATURES.contains(feature)) {
                    throw new DecodeException(FailureKind.UNKNOWN_OPERATION, feature + "." + operation);
                }
                throw new DecodeException(FailureKind.UNKNOWN_FEATURE, feature);
            }
        };
    }

    private static Json processRequest(Json j) {
        String feature = strField(j, "feature");
        String operation = strField(j, "operation");
        Json input = objVal(j, "input");
        Json result = dispatch(feature, operation, input);
        return Json.obj("feature", Json.str(feature), "operation", Json.str(operation), "result", result);
    }

    private static String topKind(Json j) {
        if (j instanceof Json.JObj o && o.fields().get("kind") instanceof Json.JStr s) {
            return s.value();
        }
        throw new DecodeException(FailureKind.QUERY_SHAPE, "missing or invalid top-level kind");
    }

    private static Json decodeQuery(Json j) {
        String kind = topKind(j);
        return switch (kind) {
            case "surface" -> surfaceJson();
            case "evaluate" -> {
                Json requestsField = j instanceof Json.JObj o ? o.fields().get("requests") : null;
                if (!(requestsField instanceof Json.JArr arr)) {
                    throw new DecodeException(FailureKind.QUERY_SHAPE, "missing or invalid requests array");
                }
                List<Json> results = mapList(arr.items(), FeatureCheck::processRequest);
                yield Json.obj("kind", Json.str("results"), "results", Json.arr(results));
            }
            default -> throw new DecodeException(FailureKind.QUERY_SHAPE, "unknown query kind " + kind);
        };
    }

    private static Json renderInvalid(DecodeException f) {
        return Json.obj(
                "kind", Json.str("invalid"),
                "failure", Json.obj("kind", Json.str(f.kind.label), "detail", Json.str(f.getMessage())));
    }

    /** Reads one query from stdin, evaluates it, and writes one normalized JSON result to stdout. */
    public static void main(String[] args) throws java.io.IOException {
        String content = new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        Json out;
        try {
            Json parsed;
            try {
                parsed = Json.parse(content);
            } catch (Json.JsonSyntaxException e) {
                throw new DecodeException(FailureKind.JSON_SYNTAX, e.getMessage());
            }
            out = decodeQuery(parsed);
        } catch (DecodeException e) {
            out = renderInvalid(e);
        }
        System.out.println(Json.compress(out));
    }
}
