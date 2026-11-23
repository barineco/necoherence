// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Random;
import necoherence.core.Nat;
import org.junit.jupiter.api.Test;

final class ProgressionInvariantsTest {
    private static Nat n(long value) { return Nat.fromLong(value); }

    private static ResourceBudget budget() {
        return new ResourceBudget(new ConfiguredSafetyLimit("pending", n(100)),
                new ConfiguredSafetyLimit("inFlight", n(100)), new ConfiguredSafetyLimit("concurrent", n(100)));
    }

    private static RequestIdentity identity(long index) { return new RequestIdentity("generated", "r", n(index)); }

    private static EvidenceVersion evidence() { return new EvidenceVersion("e", "d", "a"); }

    private static RequestInput request(long index, boolean ordered) {
        RequestIdentity identity = identity(index);
        MeaningPermission permission = ordered
                ? new MeaningPermission.Ordered(identity, List.of())
                : new MeaningPermission.Permitted(identity, List.of());
        return new RequestInput(identity,
                new RequestFootprint(List.of(), List.of(),
                        ordered ? RequestEffectClass.ORDERED_EFFECT : RequestEffectClass.PURE),
                new ResourceDemand(n(1 + index % 3), n(index % 2), n(index % 2)), permission);
    }

    private static RequestProgressionSnapshot rebuilt(RequestProgressionSnapshot snapshot) {
        return ((SnapshotResult.Built) RequestProgressionSnapshot.of(snapshot.policy(), snapshot.budget(),
                snapshot.currentIdentity(), snapshot.entries(), snapshot.revision())).snapshot();
    }

    private static ResourceDemand sum(RequestProgressionSnapshot snapshot, RequestPhase... phases) {
        ResourceDemand total = ResourceDemand.ZERO;
        for (RequestEntry entry : snapshot.entries()) {
            for (RequestPhase phase : phases) {
                if (entry.phase() == phase) total = total.plus(entry.demand());
            }
        }
        return total;
    }

    private static void checkInvariant(RequestProgressionSnapshot snapshot) {
        assertEquals(snapshot, rebuilt(snapshot));
        assertEquals(sum(snapshot, RequestPhase.PENDING), Progression.derivePending(snapshot));
        assertEquals(sum(snapshot, RequestPhase.PREPARING, RequestPhase.PUBLISHING), Progression.deriveInFlight(snapshot));
        assertEquals(sum(snapshot, RequestPhase.PUBLISHING), Progression.deriveConcurrent(snapshot));
        List<RequestEntry> entries = snapshot.entries();
        int firstPending = -1;
        for (int position = 0; position < entries.size() && firstPending < 0; position++) {
            if (entries.get(position).phase() == RequestPhase.PENDING) firstPending = position;
        }
        assertEquals(firstPending, snapshot.firstPendingPosition());
    }

    private static List<RequestEntry> inPhase(RequestProgressionSnapshot snapshot, RequestPhase phase) {
        return snapshot.entries().stream().filter(entry -> entry.phase() == phase).toList();
    }

    private static RequestProgressionSnapshot step(RequestProgressionSnapshot snapshot, Random random, long fresh) {
        switch (random.nextInt(5)) {
            case 0 -> {
                return switch (Progression.submit(snapshot, request(fresh, random.nextBoolean()))) {
                    case SubmitResult.SubmitAccepted accepted -> accepted.snapshot();
                    case SubmitResult.SubmitRejected rejected -> rejected.snapshot();
                };
            }
            case 1 -> {
                List<RequestEntry> pending = inPhase(snapshot, RequestPhase.PENDING);
                if (pending.isEmpty()) return snapshot;
                RequestIdentity id = pending.get(random.nextInt(pending.size())).identity();
                CostSelection selection = random.nextBoolean()
                        ? new CostSelection.ExecuteNow(id, evidence(), Nat.zero())
                        : new CostSelection.RemainPending(id, evidence(), Nat.zero());
                return switch (Progression.decideStart(snapshot, new Accepted(id), selection)) {
                    case StartDecisionResult.Execute execute -> execute.snapshot();
                    case StartDecisionResult.Deferred deferred -> deferred.snapshot();
                    case StartDecisionResult.Rejected rejected -> rejected.snapshot();
                };
            }
            case 2 -> {
                List<RequestEntry> preparing = inPhase(snapshot, RequestPhase.PREPARING);
                if (preparing.isEmpty()) return snapshot;
                RequestIdentity id = preparing.get(random.nextInt(preparing.size())).identity();
                AdapterResult<AdapterSignal<String>> observed = new AdapterResult.AppliedSignal<>(
                        new AdapterSignal.Started<>(id, new ExecutionHandle("h" + id.revision())));
                return switch (Progression.applyStartObservation(snapshot, new Starting(id, new AdapterCommand.StartCommand(
                        id, snapshot.entries().stream().filter(e -> e.identity().equals(id)).findFirst().get().footprint())), observed)) {
                    case StartObservationResult.Publishing publishing -> publishing.snapshot();
                    case StartObservationResult.Failed failed -> failed.snapshot();
                };
            }
            case 3 -> {
                List<RequestEntry> publishing = inPhase(snapshot, RequestPhase.PUBLISHING);
                if (publishing.isEmpty()) return snapshot;
                RequestEntry entry = publishing.get(random.nextInt(publishing.size()));
                ExecutionHandle handle = entry.executionHandle().orElseThrow();
                AdapterSignal<String> signal = random.nextBoolean()
                        ? new AdapterSignal.Completed<>(entry.identity(), handle, "done")
                        : new AdapterSignal.CancelledAtAdapter<>(entry.identity(), handle);
                return switch (Progression.applyCompletionObservation(
                        snapshot, new Running(entry.identity(), handle), new AdapterResult.AppliedSignal<>(signal))) {
                    case CompletionObservationResult.Applied<String> applied -> applied.snapshot();
                    case CompletionObservationResult.Superseded<String> superseded -> superseded.snapshot();
                    case CompletionObservationResult.Cancelled<String> cancelled -> cancelled.snapshot();
                    case CompletionObservationResult.Failed<String> failed -> failed.snapshot();
                };
            }
            default -> {
                List<RequestEntry> entries = snapshot.entries();
                if (entries.isEmpty()) return snapshot;
                RequestIdentity id = entries.get(random.nextInt(entries.size())).identity();
                return switch (Progression.decideCancel(snapshot, id)) {
                    case CancelDecisionResult.Cancelled cancelled -> cancelled.snapshot();
                    case CancelDecisionResult.CancelCommand command -> command.snapshot();
                    case CancelDecisionResult.Rejected rejected -> rejected.snapshot();
                };
            }
        }
    }

    @Test
    void generatedOperationSequencesKeepTheSnapshotInvariant() {
        for (RequestPolicy policy : RequestPolicy.values()) {
            for (long seed = 0; seed < 60; seed++) {
                Random random = new Random(seed);
                RequestProgressionSnapshot snapshot = Progression.empty(policy, budget());
                List<RequestProgressionSnapshot> earlier = new ArrayList<>();
                List<List<RequestEntry>> earlierEntries = new ArrayList<>();
                for (long index = 0; index < 60; index++) {
                    earlier.add(snapshot);
                    earlierEntries.add(snapshot.entries());
                    snapshot = step(snapshot, random, index);
                    checkInvariant(snapshot);
                }
                for (int i = 0; i < earlier.size(); i++) {
                    assertEquals(earlierEntries.get(i), earlier.get(i).entries());
                }
            }
        }
    }

    @Test
    void fifoStartIsBlockedExactlyForPendingEntriesAfterTheFirst() {
        RequestProgressionSnapshot snapshot = Progression.empty(RequestPolicy.FIFO, budget());
        for (long index = 0; index < 5; index++) {
            snapshot = assertInstanceOf(SubmitResult.SubmitAccepted.class,
                    Progression.submit(snapshot, request(index, false))).snapshot();
        }
        for (long index = 0; index < 5; index++) {
            RequestIdentity id = identity(index);
            StartDecisionResult decision = Progression.decideStart(
                    snapshot, new Accepted(id), new CostSelection.RemainPending(id, evidence(), Nat.zero()));
            if (index == 0) {
                assertInstanceOf(StartDecisionResult.Deferred.class, decision);
            } else {
                assertEquals(new StartDecisionFailure.PolicyOrderBlocked(id),
                        assertInstanceOf(StartDecisionResult.Rejected.class, decision).failure());
            }
        }
    }

    @Test
    void constructionRejectsDuplicateIdentities() {
        RequestProgressionSnapshot snapshot = Progression.empty(RequestPolicy.ALL_EXECUTE, budget());
        RequestProgressionSnapshot one = assertInstanceOf(SubmitResult.SubmitAccepted.class,
                Progression.submit(snapshot, request(1, false))).snapshot();
        RequestEntry entry = one.entries().get(0);
        SnapshotResult result = RequestProgressionSnapshot.of(
                RequestPolicy.ALL_EXECUTE, budget(), Optional.empty(), List.of(entry, entry), Nat.zero());
        assertEquals(new SnapshotFailure.DuplicateIdentity(entry.identity()),
                assertInstanceOf(SnapshotResult.Rejected.class, result).failure());
    }
}
