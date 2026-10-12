// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.ArrayList;
import necoherence.core.Nat;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import necoherence.core.Never;
import necoherence.core.Outcome;
import necoherence.progression.Accepted;
import necoherence.progression.ConfiguredSafetyLimit;
import necoherence.progression.CostSelection;
import necoherence.progression.MeaningPermission;
import necoherence.progression.PermissionDenial;
import necoherence.progression.Progression;
import necoherence.progression.RequestEntry;
import necoherence.progression.RequestIdentity;
import necoherence.progression.RequestInput;
import necoherence.progression.RequestPhase;
import necoherence.progression.RequestProgressionSnapshot;
import necoherence.progression.ResourceBudget;
import necoherence.progression.ResourceDemand;
import necoherence.progression.StartDecisionResult;
import necoherence.progression.SubmitResult;

/** Dynamic admission over {@code RequestProgression}. */
public final class Admission {

    private Admission() {
    }

    private static Optional<RequestEntry> findByIdentity(List<RequestEntry> entries, RequestIdentity identity) {
        for (RequestEntry entry : entries) {
            if (entry.identity().equals(identity)) {
                return Optional.of(entry);
            }
        }
        return Optional.empty();
    }

    private static List<RequestEntry> replaceByIdentity(
            List<RequestEntry> entries, RequestIdentity identity, RequestEntry replacement) {
        List<RequestEntry> next = new ArrayList<>(entries.size());
        for (RequestEntry entry : entries) {
            next.add(entry.identity().equals(identity) ? replacement : entry);
        }
        return next;
    }

    private static ConfiguredSafetyLimit minLimit(ConfiguredSafetyLimit a, ConfiguredSafetyLimit b) {
        return new ConfiguredSafetyLimit(a.resource(), a.maximum().min(b.maximum()));
    }

    private static ResourceBudget effectiveBudgetOf(ResourceBudget configured, ResourceBudget observed) {
        return new ResourceBudget(
                minLimit(configured.pendingMaximum(), observed.pendingMaximum()),
                minLimit(configured.inFlightMaximum(), observed.inFlightMaximum()),
                minLimit(configured.concurrentMaximum(), observed.concurrentMaximum()));
    }

    private static Optional<String[]> resourceCoordinateMismatch(ResourceBudget configured, ResourceBudget observed) {
        if (!configured.pendingMaximum().resource().equals(observed.pendingMaximum().resource())) {
            return Optional.of(new String[] {configured.pendingMaximum().resource(), observed.pendingMaximum().resource()});
        }
        if (!configured.inFlightMaximum().resource().equals(observed.inFlightMaximum().resource())) {
            return Optional.of(new String[] {configured.inFlightMaximum().resource(), observed.inFlightMaximum().resource()});
        }
        if (!configured.concurrentMaximum().resource().equals(observed.concurrentMaximum().resource())) {
            return Optional.of(new String[] {configured.concurrentMaximum().resource(), observed.concurrentMaximum().resource()});
        }
        return Optional.empty();
    }

    private static Nat observationAge(DynamicAdmissionInput input) {
        Nat observedAt = input.observedAt();
        Nat capturedAt = input.capacityObservation().observedAt();
        if (observedAt.compareTo(capturedAt) < 0) {
            return capturedAt.minusWhenOrdered(observedAt)
                    .plus(input.environmentSpecification().maxObservationAge())
                    .successor();
        }
        return observedAt.minusWhenOrdered(capturedAt);
    }

    private static Optional<DynamicAdmissionFailure> permissionCheck(RequestInput request) {
        MeaningPermission permission = request.permission();
        if (permission instanceof MeaningPermission.Denied denied) {
            if (denied.identity().equals(request.identity())) {
                return Optional.of(new DynamicAdmissionFailure.MeaningDenied(denied.identity(), denied.reason()));
            }
            return Optional.of(
                    new DynamicAdmissionFailure.PermissionIdentityMismatch(request.identity(), denied.identity()));
        }
        if (permission instanceof MeaningPermission.Permitted permitted) {
            if (permitted.identity().equals(request.identity())) {
                return Optional.empty();
            }
            return Optional.of(
                    new DynamicAdmissionFailure.PermissionIdentityMismatch(request.identity(), permitted.identity()));
        }
        MeaningPermission.Ordered ordered = (MeaningPermission.Ordered) permission;
        if (ordered.identity().equals(request.identity())) {
            return Optional.empty();
        }
        return Optional.of(
                new DynamicAdmissionFailure.PermissionIdentityMismatch(request.identity(), ordered.identity()));
    }

    private static boolean samePendingEntry(RequestEntry entry, RequestInput request) {
        return entry.phase() == RequestPhase.PENDING
                && entry.identity().equals(request.identity())
                && entry.footprint().equals(request.footprint())
                && entry.demand().equals(request.demand())
                && entry.meaningPermission().equals(request.permission());
    }

    private static Optional<RequestEntry> matchingPendingDuplicate(
            RequestProgressionSnapshot snapshot, RequestInput request) {
        return findByIdentity(snapshot.entries(), request.identity())
                .filter(entry -> samePendingEntry(entry, request));
    }

    private static boolean isExecuteNow(CostSelection selection) {
        return selection instanceof CostSelection.ExecuteNow;
    }

    private static FutureUseSet toFutureUseSet(AdmissionProvenance provenance) {
        return new FutureUseSet(provenance.futureUses());
    }

    private static OutstandingSignalSet toOutstandingSignalSet(AdmissionProvenance provenance) {
        return new OutstandingSignalSet(provenance.outstandingSignals());
    }

    private static boolean isTerminalPhase(RequestPhase phase) {
        return phase == RequestPhase.PUBLISHED || phase == RequestPhase.SUPERSEDED
                || phase == RequestPhase.CANCELLED || phase == RequestPhase.FAILED;
    }

    private static MeaningPermission eraseMeaningPermissionEvidence(MeaningPermission permission) {
        if (permission instanceof MeaningPermission.Permitted permitted) {
            return new MeaningPermission.Permitted(permitted.identity(), List.of());
        }
        if (permission instanceof MeaningPermission.Ordered ordered) {
            return new MeaningPermission.Ordered(ordered.identity(), List.of());
        }
        return permission;
    }

    private static RequestEntry eraseEntryProvenance(RequestEntry entry) {
        return new RequestEntry(
                entry.identity(),
                new necoherence.progression.RequestFootprint(List.of(), List.of(), entry.footprint().effectClass()),
                entry.demand(),
                entry.phase(),
                eraseMeaningPermissionEvidence(entry.meaningPermission()),
                entry.costSelection(),
                entry.executionHandle());
    }

    /** Elide one terminal entry's provenance. */
    public static Outcome<ElisionApplied, DynamicAdmissionFailure, Never, Never> elideAdmissionProvenance(
            DynamicAdmissionState state, RequestIdentity identity) {
        Optional<RequestEntry> found = findByIdentity(state.progression().entries(), identity);
        if (found.isEmpty()) {
            return new Outcome.Rejected<>(new DynamicAdmissionFailure.UnknownRequest(identity));
        }
        RequestEntry entry = found.get();
        if (!isTerminalPhase(entry.phase())) {
            return new Outcome.Rejected<>(new DynamicAdmissionFailure.RequestNotTerminal(identity));
        }
        if (state.provenance().futureUses().contains(identity)) {
            return new Outcome.Rejected<>(new DynamicAdmissionFailure.ProvenanceRetentionRequired(identity));
        }
        for (AdmissionSignal signal : state.provenance().outstandingSignals()) {
            if (signal.identity().equals(identity)) {
                return new Outcome.Rejected<>(new DynamicAdmissionFailure.ProvenanceRetentionRequired(identity));
            }
        }
        RequestProgressionSnapshot newProgression = state.progression().withEntries(
                replaceByIdentity(state.progression().entries(), identity, eraseEntryProvenance(entry)));
        List<RequestIdentity> newFutureUses = new ArrayList<>();
        for (RequestIdentity i : state.provenance().futureUses()) {
            if (!i.equals(identity)) {
                newFutureUses.add(i);
            }
        }
        List<AdmissionSignal> newSignals = new ArrayList<>();
        for (AdmissionSignal s : state.provenance().outstandingSignals()) {
            if (!s.identity().equals(identity)) {
                newSignals.add(s);
            }
        }
        AdmissionProvenance newProvenance = new AdmissionProvenance(newFutureUses, newSignals);
        DynamicAdmissionState newState =
                new DynamicAdmissionState(newProgression, state.configuredSafetyLimit(), newProvenance);
        return new Outcome.Applied<>(
                new ElisionApplied(newState, new ProvenanceErasureWitness.Erased(identity)));
    }

    /** Product of a successful {@link #elideAdmissionProvenance}. */
    public record ElisionApplied(DynamicAdmissionState state, ProvenanceErasureWitness witness) {
    }

    /** Evaluate dynamic admission. */
    public static Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> admitDynamicRequest(
            DynamicAdmissionInput input) {
        Objects.requireNonNull(input);
        Nat age = observationAge(input);
        if (age.compareTo(input.environmentSpecification().maxObservationAge()) > 0) {
            return new Outcome.Rejected<>(
                    new DynamicAdmissionFailure.CapacityObservationUnavailable(
                            age, input.environmentSpecification().maxObservationAge()));
        }
        Optional<String[]> mismatch =
                resourceCoordinateMismatch(input.state().configuredSafetyLimit(), input.capacityObservation().observed());
        if (mismatch.isPresent()) {
            return new Outcome.Rejected<>(
                    new DynamicAdmissionFailure.ResourceCoordinateMismatch(mismatch.get()[0], mismatch.get()[1]));
        }
        Optional<DynamicAdmissionFailure> permissionFailure = permissionCheck(input.request());
        if (permissionFailure.isPresent()) {
            return new Outcome.Rejected<>(permissionFailure.get());
        }
        ResourceBudget effectiveBudget =
                effectiveBudgetOf(input.state().configuredSafetyLimit(), input.capacityObservation().observed());
        RequestProgressionSnapshot snapshot = input.state().progression();
        AdmissionProvenance provenance = input.state().provenance();

        Optional<RequestEntry> duplicate = matchingPendingDuplicate(snapshot, input.request());
        if (duplicate.isPresent()) {
            RequestEntry entry = duplicate.get();
            Optional<CostSelection> newSelection = input.start();
            if (entry.costSelection().isEmpty() && newSelection.isEmpty()) {
                return coalescedResult(input, effectiveBudget, provenance);
            }
            if (entry.costSelection().isPresent() && newSelection.isPresent()) {
                if (entry.costSelection().get().equals(newSelection.get())) {
                    return coalescedResult(input, effectiveBudget, provenance);
                }
                return new Outcome.Rejected<>(
                        new DynamicAdmissionFailure.BindingSelectionMismatch(input.request().identity()));
            }
            return new Outcome.Rejected<>(
                    new DynamicAdmissionFailure.AdapterBindingUnavailable(input.request().identity()));
        }

        Nat pendingOccupied =
                Progression.derivePending(snapshot).pending().plus(input.request().demand().pending());
        if (pendingOccupied.compareTo(effectiveBudget.pendingMaximum().maximum()) > 0) {
            return new Outcome.Rejected<>(
                    new DynamicAdmissionFailure.ConfiguredSafetyLimitExceeded(
                            effectiveBudget.pendingMaximum().resource(), pendingOccupied,
                            effectiveBudget.pendingMaximum().maximum()));
        }

        boolean executeNow = input.start().map(Admission::isExecuteNow).orElse(false);
        Nat inFlightOccupied =
                Progression.deriveInFlight(snapshot).inFlight().plus(input.request().demand().inFlight());
        Nat concurrentOccupied =
                Progression.deriveConcurrent(snapshot).concurrent().plus(input.request().demand().concurrent());
        if (executeNow && inFlightOccupied.compareTo(effectiveBudget.inFlightMaximum().maximum()) > 0) {
            return new Outcome.Rejected<>(
                    new DynamicAdmissionFailure.ConfiguredSafetyLimitExceeded(
                            effectiveBudget.inFlightMaximum().resource(), inFlightOccupied,
                            effectiveBudget.inFlightMaximum().maximum()));
        }
        if (executeNow && concurrentOccupied.compareTo(effectiveBudget.concurrentMaximum().maximum()) > 0) {
            return new Outcome.Rejected<>(
                    new DynamicAdmissionFailure.ConfiguredSafetyLimitExceeded(
                            effectiveBudget.concurrentMaximum().resource(), concurrentOccupied,
                            effectiveBudget.concurrentMaximum().maximum()));
        }

        RequestProgressionSnapshot budgetedSnapshot = snapshot.withBudget(effectiveBudget);
        SubmitResult submitResult = Progression.submit(budgetedSnapshot, input.request());
        if (submitResult instanceof SubmitResult.SubmitRejected rejected) {
            return new Outcome.Rejected<>(new DynamicAdmissionFailure.ProgressionSubmitFailure(rejected.failure()));
        }
        SubmitResult.SubmitAccepted accepted = (SubmitResult.SubmitAccepted) submitResult;

        if (input.start().isEmpty()) {
            DynamicAdmissionState newState = input.state().withProgression(accepted.snapshot());
            return new Outcome.Applied<>(
                    new DynamicAdmissionResult(
                            effectiveBudget, new AdmissionDecision.Submitted(newState, accepted.accepted()),
                            toFutureUseSet(newState.provenance()), toOutstandingSignalSet(newState.provenance()),
                            Optional.empty(),
                            new CoalescingWitness.NotCoalesced("no duplicate pending request")));
        }

        StartDecisionResult startResult =
                Progression.decideStart(accepted.snapshot(), accepted.accepted(), input.start().get());
        if (startResult instanceof StartDecisionResult.Rejected rejected) {
            return new Outcome.Rejected<>(new DynamicAdmissionFailure.ProgressionStartFailure(rejected.failure()));
        }
        RequestProgressionSnapshot startedSnapshot = startResult instanceof StartDecisionResult.Execute execute
                ? execute.snapshot()
                : ((StartDecisionResult.Deferred) startResult).snapshot();
        DynamicAdmissionState newState = input.state().withProgression(startedSnapshot);
        return new Outcome.Applied<>(
                new DynamicAdmissionResult(
                        effectiveBudget, new AdmissionDecision.Started(newState, startResult),
                        toFutureUseSet(newState.provenance()), toOutstandingSignalSet(newState.provenance()),
                        Optional.empty(), new CoalescingWitness.NotCoalesced("no duplicate pending request")));
    }

    private static Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> coalescedResult(
            DynamicAdmissionInput input, ResourceBudget effectiveBudget, AdmissionProvenance provenance) {
        return new Outcome.Applied<>(
                new DynamicAdmissionResult(
                        effectiveBudget, new AdmissionDecision.Coalesced(input.state(), input.request().identity()),
                        toFutureUseSet(provenance), toOutstandingSignalSet(provenance), Optional.empty(),
                        new CoalescingWitness.Coalesced(input.request().identity())));
    }
}
