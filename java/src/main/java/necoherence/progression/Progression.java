// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.core.Nat;

/** Computable request progression matching Necoherence.RequestProgression. */
public final class Progression {
    private Progression() {}

    public static RequestProgressionSnapshot empty(RequestPolicy policy, ResourceBudget budget) {
        return new RequestProgressionSnapshot(policy, budget, Optional.empty(), List.of(), Nat.zero());
    }

    private static Optional<RequestEntry> findEntry(List<RequestEntry> entries, RequestIdentity identity) {
        for (RequestEntry entry : entries) if (entry.identity().equals(identity)) return Optional.of(entry);
        return Optional.empty();
    }

    private static List<RequestEntry> replaceEntry(
            List<RequestEntry> entries, RequestIdentity identity, RequestEntry replacement) {
        List<RequestEntry> next = new ArrayList<>(entries.size());
        for (RequestEntry entry : entries) next.add(entry.identity().equals(identity) ? replacement : entry);
        return next;
    }

    private static ResourceDemand sumDemand(List<RequestEntry> entries, RequestPhase... phases) {
        ResourceDemand total = ResourceDemand.ZERO;
        for (RequestEntry entry : entries) {
            for (RequestPhase phase : phases) {
                if (entry.phase() == phase) {
                    total = total.plus(entry.demand());
                    break;
                }
            }
        }
        return total;
    }

    public static ResourceDemand derivePending(RequestProgressionSnapshot snapshot) {
        return sumDemand(snapshot.entries(), RequestPhase.PENDING);
    }

    public static ResourceDemand deriveInFlight(RequestProgressionSnapshot snapshot) {
        return sumDemand(snapshot.entries(), RequestPhase.PREPARING, RequestPhase.PUBLISHING);
    }

    public static ResourceDemand deriveConcurrent(RequestProgressionSnapshot snapshot) {
        return sumDemand(snapshot.entries(), RequestPhase.PUBLISHING);
    }

    private static boolean policyOrderAllowed(RequestProgressionSnapshot snapshot, RequestIdentity identity) {
        return switch (snapshot.policy()) {
            case LATEST_WINS -> snapshot.currentIdentity().map(identity::equals).orElse(false);
            case ALL_EXECUTE -> true;
            case FIFO -> {
                for (RequestEntry entry : snapshot.entries()) {
                    if (entry.phase() == RequestPhase.PENDING) yield entry.identity().equals(identity);
                }
                yield false;
            }
        };
    }

    private static boolean orderedEffectAllowed(
            RequestProgressionSnapshot snapshot, RequestIdentity identity, RequestEntry entry) {
        if (entry.footprint().effectClass() != RequestEffectClass.ORDERED_EFFECT) return true;
        for (RequestEntry candidate : snapshot.entries()) {
            if (candidate.phase() == RequestPhase.PENDING
                    && candidate.footprint().effectClass() == RequestEffectClass.ORDERED_EFFECT) {
                return candidate.identity().equals(identity);
            }
        }
        return true;
    }

    public static SubmitResult submit(RequestProgressionSnapshot snapshot, RequestInput request) {
        if (findEntry(snapshot.entries(), request.identity()).isPresent()) {
            return new SubmitResult.SubmitRejected(snapshot, new SubmitFailure.DuplicateIdentity(request.identity()));
        }
        Nat pendingOccupied = derivePending(snapshot).pending().plus(request.demand().pending());
        if (pendingOccupied.compareTo(snapshot.budget().pendingMaximum().maximum()) > 0) {
            return new SubmitResult.SubmitRejected(
                    snapshot, new SubmitFailure.PendingLimitExceeded(request.demand(), snapshot.budget()));
        }
        RequestEntry created = new RequestEntry(request.identity(), request.footprint(), request.demand(),
                RequestPhase.PENDING, request.permission(), Optional.empty(), Optional.empty());
        List<RequestEntry> entries = new ArrayList<>();
        if (snapshot.policy() == RequestPolicy.LATEST_WINS) {
            for (RequestEntry entry : snapshot.entries()) {
                entries.add(entry.phase() == RequestPhase.PENDING ? entry.withPhase(RequestPhase.SUPERSEDED) : entry);
            }
        } else {
            entries.addAll(snapshot.entries());
        }
        entries.add(created);
        return new SubmitResult.SubmitAccepted(
                snapshot.withCurrentIdentityAndRevisionBump(entries, request.identity()), new Accepted(request.identity()));
    }

    private static StartDecisionResult decideStartSelection(
            RequestProgressionSnapshot snapshot, Accepted accepted, RequestEntry entry, CostSelection selection) {
        if (selection instanceof CostSelection.RemainPending remainPending) {
            if (!remainPending.identity().equals(accepted.identity())) {
                return new StartDecisionResult.Rejected(snapshot,
                        new StartDecisionFailure.CostSelectionIdentityMismatch(accepted.identity(), remainPending.identity()));
            }
            return new StartDecisionResult.Deferred(
                    snapshot.withEntries(replaceEntry(snapshot.entries(), accepted.identity(), entry.withCostSelection(selection))),
                    accepted);
        }
        CostSelection.ExecuteNow executeNow = (CostSelection.ExecuteNow) selection;
        if (!executeNow.identity().equals(accepted.identity())) {
            return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.CostSelectionIdentityMismatch(accepted.identity(), executeNow.identity()));
        }
        if (deriveInFlight(snapshot).inFlight().plus(entry.demand().inFlight())
                .compareTo(snapshot.budget().inFlightMaximum().maximum()) > 0) {
            return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.InFlightLimitExceeded(entry.demand(), snapshot.budget()));
        }
        if (deriveConcurrent(snapshot).concurrent().plus(entry.demand().concurrent())
                .compareTo(snapshot.budget().concurrentMaximum().maximum()) > 0) {
            return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.ConcurrentLimitExceeded(entry.demand(), snapshot.budget()));
        }
        AdapterCommand command = new AdapterCommand.StartCommand(accepted.identity(), entry.footprint());
        RequestEntry preparing = entry.withPhase(RequestPhase.PREPARING).withCostSelection(selection);
        RequestProgressionSnapshot advanced = snapshot.withEntriesAndRevisionBump(
                replaceEntry(snapshot.entries(), accepted.identity(), preparing));
        return new StartDecisionResult.Execute(advanced, new Starting(accepted.identity(), command), command);
    }

    /** Decide whether to start without consuming an adapter observation. */
    public static StartDecisionResult decideStart(
            RequestProgressionSnapshot snapshot, Accepted accepted, CostSelection selection) {
        Optional<RequestEntry> found = findEntry(snapshot.entries(), accepted.identity());
        if (found.isEmpty()) return new StartDecisionResult.Rejected(snapshot,
                new StartDecisionFailure.UnknownRequest(accepted.identity()));
        RequestEntry entry = found.get();
        if (entry.phase() != RequestPhase.PENDING) return new StartDecisionResult.Rejected(snapshot,
                new StartDecisionFailure.RequestNotPending(accepted.identity()));
        if (!policyOrderAllowed(snapshot, accepted.identity()) || !orderedEffectAllowed(snapshot, accepted.identity(), entry)) {
            return new StartDecisionResult.Rejected(snapshot, new StartDecisionFailure.PolicyOrderBlocked(accepted.identity()));
        }
        MeaningPermission permission = entry.meaningPermission();
        if (permission instanceof MeaningPermission.Denied denied) {
            return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.PermissionDenied(accepted.identity(), denied.reason()));
        }
        if (permission instanceof MeaningPermission.Permitted permitted) {
            if (!permitted.identity().equals(accepted.identity())) return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.PermissionIdentityMismatch(accepted.identity(), permitted.identity()));
            if (entry.footprint().effectClass() == RequestEffectClass.ORDERED_EFFECT) return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.PermissionNotOrdered(accepted.identity()));
        } else {
            MeaningPermission.Ordered ordered = (MeaningPermission.Ordered) permission;
            if (!ordered.identity().equals(accepted.identity())) return new StartDecisionResult.Rejected(snapshot,
                    new StartDecisionFailure.PermissionIdentityMismatch(accepted.identity(), ordered.identity()));
        }
        return decideStartSelection(snapshot, accepted, entry, selection);
    }

    /** Apply an adapter result after {@link #decideStart} has produced a {@link Starting} token. */
    public static <Result> StartObservationResult applyStartObservation(
            RequestProgressionSnapshot snapshot, Starting starting, AdapterResult<AdapterSignal<Result>> observed) {
        Optional<RequestEntry> found = findEntry(snapshot.entries(), starting.identity());
        if (found.isEmpty()) return new StartObservationResult.Failed(snapshot,
                new StartObservationFailure.UnknownRequest(starting.identity()));
        RequestEntry entry = found.get();
        if (entry.phase() != RequestPhase.PREPARING) return new StartObservationResult.Failed(snapshot,
                new StartObservationFailure.RequestNotStarting(starting.identity()));
        if (observed instanceof AdapterResult.AppliedSignal<AdapterSignal<Result>> applied
                && applied.signal() instanceof AdapterSignal.Started<Result> started) {
            if (started.identity().equals(starting.identity())) {
                RequestEntry publishing = entry.withPhase(RequestPhase.PUBLISHING);
                publishing = new RequestEntry(publishing.identity(), publishing.footprint(), publishing.demand(),
                        publishing.phase(), publishing.meaningPermission(), publishing.costSelection(), Optional.of(started.handle()));
                RequestProgressionSnapshot advanced = snapshot.withEntriesAndRevisionBump(
                        replaceEntry(snapshot.entries(), starting.identity(), publishing));
                return new StartObservationResult.Publishing(advanced, new Running(starting.identity(), started.handle()));
            }
            return startObservationFailed(snapshot, starting.identity(), entry,
                    new StartObservationFailure.StartIdentityMismatch(starting.identity(), started.identity()));
        }
        if (observed instanceof AdapterResult.AdapterFailed<AdapterSignal<Result>> adapterFailed
                && adapterFailed.failure() instanceof AdapterFailure.StartAdapterFailure failure) {
            StartObservationFailure result = failure.identity().equals(starting.identity())
                    ? new StartObservationFailure.StartAdapterFailureObserved(starting.identity(), failure.detail())
                    : new StartObservationFailure.StartIdentityMismatch(starting.identity(), failure.identity());
            return startObservationFailed(snapshot, starting.identity(), entry, result);
        }
        return startObservationFailed(snapshot, starting.identity(), entry,
                new StartObservationFailure.StartSignalMismatch(starting.identity()));
    }

    private static StartObservationResult startObservationFailed(RequestProgressionSnapshot snapshot,
            RequestIdentity identity, RequestEntry entry, StartObservationFailure failure) {
        RequestProgressionSnapshot advanced = snapshot.withEntriesAndRevisionBump(
                replaceEntry(snapshot.entries(), identity, entry.withPhase(RequestPhase.FAILED)));
        return new StartObservationResult.Failed(advanced, failure);
    }

    /** Apply a completion, cancellation, or failure observation to a publishing entry. */
    public static <Result> CompletionObservationResult<Result> applyCompletionObservation(
            RequestProgressionSnapshot snapshot, Running running, AdapterResult<AdapterSignal<Result>> observed) {
        Optional<RequestEntry> found = findEntry(snapshot.entries(), running.identity());
        if (found.isEmpty()) return new CompletionObservationResult.Failed<>(snapshot,
                new CompletionObservationFailure.UnknownCompletion(running.identity()));
        RequestEntry entry = found.get();
        if (entry.phase() != RequestPhase.PUBLISHING) return new CompletionObservationResult.Failed<>(snapshot,
                new CompletionObservationFailure.CompletionNotRunning(running.identity()));
        if (entry.executionHandle().isEmpty() || !entry.executionHandle().get().equals(running.handle())) {
            return new CompletionObservationResult.Failed<>(snapshot,
                    new CompletionObservationFailure.HandleMismatch(running.identity()));
        }
        if (observed instanceof AdapterResult.AppliedSignal<AdapterSignal<Result>> applied) {
            AdapterSignal<Result> signal = applied.signal();
            if (signal instanceof AdapterSignal.Completed<Result> completed) {
                if (!completed.identity().equals(running.identity())) return completionFailed(snapshot,
                        new CompletionObservationFailure.CompletionIdentityMismatch(running.identity(), completed.identity()));
                if (!completed.handle().equals(running.handle())) return completionFailed(snapshot,
                        new CompletionObservationFailure.HandleMismatch(running.identity()));
                if (snapshot.policy() == RequestPolicy.LATEST_WINS
                        && !snapshot.currentIdentity().map(running.identity()::equals).orElse(false)) {
                    return new CompletionObservationResult.Superseded<>(snapshot.withEntries(
                            replaceEntry(snapshot.entries(), running.identity(), entry.withPhase(RequestPhase.SUPERSEDED))),
                            running.identity());
                }
                RequestProgressionSnapshot advanced = snapshot.withEntriesAndRevisionBump(
                        replaceEntry(snapshot.entries(), running.identity(), entry.withPhase(RequestPhase.PUBLISHED)));
                return new CompletionObservationResult.Applied<>(advanced, running.identity(), completed.value());
            }
            if (signal instanceof AdapterSignal.CancelledAtAdapter<Result> cancelled) {
                if (!cancelled.identity().equals(running.identity())) return completionFailed(snapshot,
                        new CompletionObservationFailure.CompletionIdentityMismatch(running.identity(), cancelled.identity()));
                if (!cancelled.handle().equals(running.handle())) return completionFailed(snapshot,
                        new CompletionObservationFailure.HandleMismatch(running.identity()));
                RequestProgressionSnapshot advanced = snapshot.withEntriesAndRevisionBump(
                        replaceEntry(snapshot.entries(), running.identity(), entry.withPhase(RequestPhase.CANCELLED)));
                return new CompletionObservationResult.Cancelled<>(advanced, running.identity());
            }
            return completionFailed(snapshot, new CompletionObservationFailure.CompletionSignalMismatch(running.identity()));
        }
        AdapterFailure failure = ((AdapterResult.AdapterFailed<AdapterSignal<Result>>) observed).failure();
        if (failure instanceof AdapterFailure.CompletionAdapterFailure completion) {
            if (!completion.identity().equals(running.identity())) return completionFailed(snapshot,
                    new CompletionObservationFailure.CompletionIdentityMismatch(running.identity(), completion.identity()));
            if (!completion.handle().equals(running.handle())) return completionFailed(snapshot,
                    new CompletionObservationFailure.HandleMismatch(running.identity()));
            return completionFailedWithEntry(snapshot, running.identity(), entry,
                    new CompletionObservationFailure.CompletionAdapterFailureObserved(running.identity(), completion.detail()));
        }
        if (failure instanceof AdapterFailure.CancellationAdapterFailure cancellation) {
            if (!cancellation.identity().equals(running.identity())) return completionFailed(snapshot,
                    new CompletionObservationFailure.CompletionIdentityMismatch(running.identity(), cancellation.identity()));
            if (!cancellation.handle().equals(running.handle())) return completionFailed(snapshot,
                    new CompletionObservationFailure.HandleMismatch(running.identity()));
            return completionFailedWithEntry(snapshot, running.identity(), entry,
                    new CompletionObservationFailure.CancellationAdapterFailureObserved(running.identity(), cancellation.detail()));
        }
        return completionFailed(snapshot, new CompletionObservationFailure.CompletionSignalMismatch(running.identity()));
    }

    private static <Result> CompletionObservationResult<Result> completionFailed(
            RequestProgressionSnapshot snapshot, CompletionObservationFailure failure) {
        return new CompletionObservationResult.Failed<>(snapshot, failure);
    }

    private static <Result> CompletionObservationResult<Result> completionFailedWithEntry(
            RequestProgressionSnapshot snapshot, RequestIdentity identity, RequestEntry entry,
            CompletionObservationFailure failure) {
        return new CompletionObservationResult.Failed<>(snapshot.withEntriesAndRevisionBump(
                replaceEntry(snapshot.entries(), identity, entry.withPhase(RequestPhase.FAILED))), failure);
    }

    /** Decide cancellation without consuming the resulting adapter observation. */
    public static CancelDecisionResult decideCancel(RequestProgressionSnapshot snapshot, RequestIdentity identity) {
        Optional<RequestEntry> found = findEntry(snapshot.entries(), identity);
        if (found.isEmpty()) return new CancelDecisionResult.Rejected(snapshot, new CancelFailure.UnknownRequest(identity));
        RequestEntry entry = found.get();
        return switch (entry.phase()) {
            case PENDING -> new CancelDecisionResult.Cancelled(snapshot.withEntriesAndRevisionBump(
                    replaceEntry(snapshot.entries(), identity, entry.withPhase(RequestPhase.CANCELLED))), identity);
            case PUBLISHING -> {
                if (entry.executionHandle().isEmpty()) yield new CancelDecisionResult.Rejected(snapshot,
                        new CancelFailure.MissingExecutionHandle(identity));
                ExecutionHandle handle = entry.executionHandle().get();
                yield new CancelDecisionResult.CancelCommand(snapshot, new Running(identity, handle),
                        new AdapterCommand.CancelCommand(identity, handle));
            }
            case PREPARING -> new CancelDecisionResult.Rejected(snapshot, new CancelFailure.MissingExecutionHandle(identity));
            default -> new CancelDecisionResult.Rejected(snapshot, new CancelFailure.RequestAlreadyTerminal(identity));
        };
    }
}
