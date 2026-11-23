// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.util.List;
import necoherence.core.Nat;
import org.junit.jupiter.api.Test;


final class ProgressionTest {
    private static Nat n(long value) { return Nat.fromLong(value); }
    private static ResourceBudget budget(long pending, long inFlight, long concurrent) {
        return new ResourceBudget(new ConfiguredSafetyLimit("pending", n(pending)),
                new ConfiguredSafetyLimit("inFlight", n(inFlight)), new ConfiguredSafetyLimit("concurrent", n(concurrent)));
    }
    private static RequestIdentity identity(String provenance) { return new RequestIdentity("test", provenance, Nat.zero()); }
    private static RequestInput request(String provenance, ResourceDemand demand) {
        RequestIdentity identity = identity(provenance);
        return new RequestInput(identity, new RequestFootprint(List.of(), List.of(), RequestEffectClass.PURE), demand,
                new MeaningPermission.Permitted(identity, List.of()));
    }
    private static CostSelection execute(String provenance) {
        return new CostSelection.ExecuteNow(identity(provenance), new EvidenceVersion("e", "d", "a"), Nat.zero());
    }
    private static SubmitResult.SubmitAccepted submit(RequestProgressionSnapshot snapshot, String provenance, ResourceDemand demand) {
        return assertInstanceOf(SubmitResult.SubmitAccepted.class, Progression.submit(snapshot, request(provenance, demand)));
    }

    @Test void decideStartPreparesThenObservationPublishes() {
        var accepted = submit(Progression.empty(RequestPolicy.FIFO, budget(4, 4, 4)), "r1", new ResourceDemand(n(1), n(1), n(1)));
        var decision = assertInstanceOf(StartDecisionResult.Execute.class,
                Progression.decideStart(accepted.snapshot(), accepted.accepted(), execute("r1")));
        assertEquals(RequestPhase.PREPARING, decision.snapshot().entries().get(0).phase());
        AdapterResult<AdapterSignal<String>> started = new AdapterResult.AppliedSignal<>(
                new AdapterSignal.Started<>(identity("r1"), new ExecutionHandle("h1")));
        var observation = assertInstanceOf(StartObservationResult.Publishing.class,
                Progression.applyStartObservation(decision.snapshot(), decision.starting(), started));
        assertEquals(RequestPhase.PUBLISHING, observation.snapshot().entries().get(0).phase());
        assertEquals(new ExecutionHandle("h1"), observation.running().handle());
    }

    @Test void startObservationMismatchFailsPreparingEntry() {
        var accepted = submit(Progression.empty(RequestPolicy.FIFO, budget(4, 4, 4)), "r1", new ResourceDemand(n(1), n(1), n(1)));
        var decision = assertInstanceOf(StartDecisionResult.Execute.class,
                Progression.decideStart(accepted.snapshot(), accepted.accepted(), execute("r1")));
        AdapterResult<AdapterSignal<String>> mismatch = new AdapterResult.AppliedSignal<>(
                new AdapterSignal.Started<>(identity("other"), new ExecutionHandle("h")));
        var result = assertInstanceOf(StartObservationResult.Failed.class,
                Progression.applyStartObservation(decision.snapshot(), decision.starting(), mismatch));
        assertInstanceOf(StartObservationFailure.StartIdentityMismatch.class, result.failure());
        assertEquals(RequestPhase.FAILED, result.snapshot().entries().get(0).phase());
    }

    @Test void latestWinsStaleCompletionIsSupersededWithoutChangingNewRequest() {
        var first = submit(Progression.empty(RequestPolicy.LATEST_WINS, budget(4, 4, 4)), "r1", new ResourceDemand(n(1), n(1), n(1)));
        var decision = assertInstanceOf(StartDecisionResult.Execute.class,
                Progression.decideStart(first.snapshot(), first.accepted(), execute("r1")));
        var start = assertInstanceOf(StartObservationResult.Publishing.class, Progression.applyStartObservation(
                decision.snapshot(), decision.starting(), new AdapterResult.AppliedSignal<>(
                        new AdapterSignal.Started<String>(identity("r1"), new ExecutionHandle("h1")))));
        var next = submit(start.snapshot(), "r2", new ResourceDemand(n(1), n(1), n(1)));
        var result = assertInstanceOf(CompletionObservationResult.Superseded.class,
                Progression.applyCompletionObservation(next.snapshot(), start.running(), new AdapterResult.AppliedSignal<>(
                        new AdapterSignal.Completed<>(identity("r1"), new ExecutionHandle("h1"), "value"))));
        assertEquals(RequestPhase.SUPERSEDED, result.snapshot().entries().get(0).phase());
        assertEquals(RequestPhase.PENDING, result.snapshot().entries().get(1).phase());
    }

    @Test void decideCancelPendingCancelsAndPreparingHasNoHandle() {
        var accepted = submit(Progression.empty(RequestPolicy.FIFO, budget(4, 4, 4)), "r1", new ResourceDemand(n(1), n(1), n(1)));
        var cancelled = assertInstanceOf(CancelDecisionResult.Cancelled.class,
                Progression.decideCancel(accepted.snapshot(), identity("r1")));
        assertEquals(RequestPhase.CANCELLED, cancelled.snapshot().entries().get(0).phase());
        var decision = assertInstanceOf(StartDecisionResult.Execute.class,
                Progression.decideStart(accepted.snapshot(), accepted.accepted(), execute("r1")));
        var rejected = assertInstanceOf(CancelDecisionResult.Rejected.class,
                Progression.decideCancel(decision.snapshot(), identity("r1")));
        assertInstanceOf(CancelFailure.MissingExecutionHandle.class, rejected.failure());
    }

    @Test void derivationsCountTheirDeclaredPhases() {
        var accepted = submit(Progression.empty(RequestPolicy.FIFO, budget(4, 4, 4)), "r1", new ResourceDemand(n(1), n(2), n(3)));
        var decision = assertInstanceOf(StartDecisionResult.Execute.class,
                Progression.decideStart(accepted.snapshot(), accepted.accepted(), execute("r1")));
        assertEquals(n(2), Progression.deriveInFlight(decision.snapshot()).inFlight());
        assertEquals(Nat.zero(), Progression.deriveConcurrent(decision.snapshot()).concurrent());
    }
}
