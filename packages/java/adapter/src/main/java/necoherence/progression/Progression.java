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
        return ((SnapshotResult.Built) RequestProgressionSnapshot.of(
                policy, budget, Optional.empty(), List.of(), Nat.zero())).snapshot();
    }

    private static Optional<RequestEntry> findEntry(RequestProgressionSnapshot snapshot, RequestIdentity identity) {
        int position = snapshot.positionOf(identity);
        return position < 0 ? Optional.empty() : Optional.of(snapshot.entryAt(position));
    }

    private static RequestProgressionSnapshot replaceEntry(
            RequestProgressionSnapshot snapshot, RequestIdentity identity, RequestEntry replacement) {
        return snapshot.replacedAt(snapshot.positionOf(identity), replacement);
    }

    public static ResourceDemand derivePending(RequestProgressionSnapshot snapshot) {
        return snapshot.pendingTotal();
    }

    public static ResourceDemand deriveInFlight(RequestProgressionSnapshot snapshot) {
        return snapshot.inFlightTotal();
    }

    public static ResourceDemand deriveConcurrent(RequestProgressionSnapshot snapshot) {
        return snapshot.concurrentTotal();
    }

    private static boolean policyOrderAllowed(RequestProgressionSnapshot snapshot, RequestIdentity identity) {
        return switch (snapshot.policy()) {
            case LATEST_WINS -> snapshot.currentIdentity().map(identity::equals).orElse(false);
            case ALL_EXECUTE -> true;
            case FIFO -> {
                int first = snapshot.firstPendingPosition();
                yield first >= 0 && snapshot.entryAt(first).identity().equals(identity);
            }
        };
    }

    private static boolean orderedEffectAllowed(
            RequestProgressionSnapshot snapshot, RequestIdentity identity, RequestEntry entry) {
        if (entry.footprint().effectClass() != RequestEffectClass.ORDERED_EFFECT) return true;
        int first = snapshot.firstOrderedPendingPosition();
        return first < 0 || snapshot.entryAt(first).identity().equals(identity);
    }

    public static SubmitResult submit(RequestProgressionSnapshot snapshot, RequestInput request) {
        if (snapshot.positionOf(request.identity()) >= 0) {
            return new SubmitResult.SubmitRejected(snapshot, new SubmitFailure.DuplicateIdentity(request.identity()));
        }
        Nat pendingOccupied = derivePending(snapshot).pending().plus(request.demand().pending());
        if (pendingOccupied.compareTo(snapshot.budget().pendingMaximum().maximum()) > 0) {
            return new SubmitResult.SubmitRejected(
                    snapshot, new SubmitFailure.PendingLimitExceeded(request.demand(), snapshot.budget()));
        }
        RequestEntry created = new RequestEntry(request.identity(), request.footprint(), request.demand(),
                RequestPhase.PENDING, request.permission(), Optional.empty(), Optional.empty());
        RequestProgressionSnapshot next = snapshot;
        if (snapshot.policy() == RequestPolicy.LATEST_WINS) {
            for (int position : snapshot.pendingPositionList()) {
                next = next.replacedAt(position, next.entryAt(position).withPhase(RequestPhase.SUPERSEDED));
            }
        }
        return new SubmitResult.SubmitAccepted(
                next.appended(created).withCurrent(request.identity()).bumped(), new Accepted(request.identity()));
    }

    private static StartDecisionResult decideStartSelection(
            RequestProgressionSnapshot snapshot, Accepted accepted, RequestEntry entry, CostSelection selection) {
        if (selection instanceof CostSelection.RemainPending remainPending) {
            if (!remainPending.identity().equals(accepted.identity())) {
                return new StartDecisionResult.Rejected(snapshot,
                        new StartDecisionFailure.CostSelectionIdentityMismatch(accepted.identity(), remainPending.identity()));
            }
            return new StartDecisionResult.Deferred(
                    replaceEntry(snapshot, accepted.identity(), entry.withCostSelection(selection)),
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
        RequestProgressionSnapshot advanced = replaceEntry(snapshot, accepted.identity(), preparing).bumped();
        return new StartDecisionResult.Execute(advanced, new Starting(accepted.identity(), command), command);
    }

    /** Decide whether to start without consuming an adapter observation. */
    public static StartDecisionResult decideStart(
            RequestProgressionSnapshot snapshot, Accepted accepted, CostSelection selection) {
        Optional<RequestEntry> found = findEntry(snapshot, accepted.identity());
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
        Optional<RequestEntry> found = findEntry(snapshot, starting.identity());
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
                RequestProgressionSnapshot advanced = replaceEntry(snapshot, starting.identity(), publishing).bumped();
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
        RequestProgressionSnapshot advanced = replaceEntry(snapshot, identity, entry.withPhase(RequestPhase.FAILED)).bumped();
        return new StartObservationResult.Failed(advanced, failure);
    }

    /** Apply a completion, cancellation, or failure observation to a publishing entry. */
    public static <Result> CompletionObservationResult<Result> applyCompletionObservation(
            RequestProgressionSnapshot snapshot, Running running, AdapterResult<AdapterSignal<Result>> observed) {
        Optional<RequestEntry> found = findEntry(snapshot, running.identity());
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
                    return new CompletionObservationResult.Superseded<>(replaceEntry(snapshot, running.identity(), entry.withPhase(RequestPhase.SUPERSEDED)),
                            running.identity());
                }
                RequestProgressionSnapshot advanced = replaceEntry(snapshot, running.identity(), entry.withPhase(RequestPhase.PUBLISHED)).bumped();
                return new CompletionObservationResult.Applied<>(advanced, running.identity(), completed.value());
            }
            if (signal instanceof AdapterSignal.CancelledAtAdapter<Result> cancelled) {
                if (!cancelled.identity().equals(running.identity())) return completionFailed(snapshot,
                        new CompletionObservationFailure.CompletionIdentityMismatch(running.identity(), cancelled.identity()));
                if (!cancelled.handle().equals(running.handle())) return completionFailed(snapshot,
                        new CompletionObservationFailure.HandleMismatch(running.identity()));
                RequestProgressionSnapshot advanced = replaceEntry(snapshot, running.identity(), entry.withPhase(RequestPhase.CANCELLED)).bumped();
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
        return new CompletionObservationResult.Failed<>(replaceEntry(snapshot, identity, entry.withPhase(RequestPhase.FAILED)).bumped(), failure);
    }

    /** Decide cancellation without consuming the resulting adapter observation. */
    public static CancelDecisionResult decideCancel(RequestProgressionSnapshot snapshot, RequestIdentity identity) {
        Optional<RequestEntry> found = findEntry(snapshot, identity);
        if (found.isEmpty()) return new CancelDecisionResult.Rejected(snapshot, new CancelFailure.UnknownRequest(identity));
        RequestEntry entry = found.get();
        return switch (entry.phase()) {
            case PENDING -> new CancelDecisionResult.Cancelled(replaceEntry(snapshot, identity, entry.withPhase(RequestPhase.CANCELLED)).bumped(), identity);
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
