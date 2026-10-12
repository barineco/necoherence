// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.util.List;
import java.util.Optional;
import necoherence.core.Nat;
import necoherence.core.Never;
import necoherence.core.Outcome;
import necoherence.progression.ConfiguredSafetyLimit;
import necoherence.progression.CostSelection;
import necoherence.progression.EvidenceVersion;
import necoherence.progression.MeaningPermission;
import necoherence.progression.Progression;
import necoherence.progression.RequestEffectClass;
import necoherence.progression.RequestFootprint;
import necoherence.progression.RequestIdentity;
import necoherence.progression.RequestInput;
import necoherence.progression.RequestPhase;
import necoherence.progression.RequestPolicy;
import necoherence.progression.ResourceBudget;
import necoherence.progression.ResourceDemand;
import necoherence.progression.StartDecisionResult;
import org.junit.jupiter.api.Test;

/** Tests dynamic admission's submit-to-decide-start boundary. */
final class AdmissionTest {
    private static Nat n(long value) { return Nat.fromLong(value); }
    private static ResourceBudget budget(long pending, long inFlight, long concurrent) {
        return new ResourceBudget(new ConfiguredSafetyLimit("pending", n(pending)),
                new ConfiguredSafetyLimit("inFlight", n(inFlight)), new ConfiguredSafetyLimit("concurrent", n(concurrent)));
    }
    private static RequestIdentity identity(String provenance) { return new RequestIdentity("test", provenance, Nat.zero()); }
    private static RequestInput request(String provenance) {
        RequestIdentity identity = identity(provenance);
        return new RequestInput(identity, new RequestFootprint(List.of(), List.of(), RequestEffectClass.PURE),
                new ResourceDemand(n(1), n(1), n(1)), new MeaningPermission.Permitted(identity, List.of()));
    }
    private static DynamicAdmissionState state() {
        ResourceBudget budget = budget(4, 4, 4);
        return new DynamicAdmissionState(Progression.empty(RequestPolicy.FIFO, budget), budget,
                new AdmissionProvenance(List.of(), List.of()));
    }
    private static DynamicAdmissionInput input(RequestInput request, Optional<CostSelection> start) {
        return new DynamicAdmissionInput(state(), request, new EnvironmentSpecification(n(5)),
                new CapacityObservation(budget(4, 4, 4), Nat.zero()), Nat.zero(), start);
    }

    @Test void submitWithoutStartReturnsPendingSubmission() {
        Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> outcome =
                Admission.admitDynamicRequest(input(request("r1"), Optional.empty()));
        var applied = assertInstanceOf(Outcome.Applied.class, outcome);
        var result = assertInstanceOf(DynamicAdmissionResult.class, applied.value());
        var submitted = assertInstanceOf(AdmissionDecision.Submitted.class, result.admissionDecision());
        assertEquals(RequestPhase.PENDING, submitted.state().progression().entries().get(0).phase());
    }

    @Test void requestedStartReturnsPreparingDecisionWithoutAdapterObservation() {
        CostSelection selection = new CostSelection.ExecuteNow(identity("r1"), new EvidenceVersion("e", "d", "a"), Nat.zero());
        Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never> outcome =
                Admission.admitDynamicRequest(input(request("r1"), Optional.of(selection)));
        var applied = assertInstanceOf(Outcome.Applied.class, outcome);
        var result = assertInstanceOf(DynamicAdmissionResult.class, applied.value());
        var started = assertInstanceOf(AdmissionDecision.Started.class, result.admissionDecision());
        assertInstanceOf(StartDecisionResult.Execute.class, started.result());
        assertEquals(RequestPhase.PREPARING, started.state().progression().entries().get(0).phase());
    }
}
