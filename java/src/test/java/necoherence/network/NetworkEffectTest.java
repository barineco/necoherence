// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.util.List;
import java.util.Optional;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;

public final class NetworkEffectTest {
    private static Nat n(long value) { return Nat.fromLong(value); }
    private static NetworkEffect.HostConfiguration config() {
        return new NetworkEffect.HostConfiguration(n(32), n(32), Optional.empty(), Optional.empty());
    }
    private static NetworkEffect.AttemptInput input(String target) {
        return new NetworkEffect.AttemptInput(new NetworkEffect.AttemptIdentity(
                new RequestIdentity("runner", "test", n(0)), n(0)),
                new NetworkEffect.HttpWireInstruction("POST", target,
                        List.of(new NetworkEffect.RawHeaderField("X-Test", List.of(0x61, 0x7e))), List.of(0x80, 0xff)),
                Optional.empty(), config());
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void verifyInvalidStateRejection() {
        var cancellation = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel"));
        var configuration = new NetworkEffect.HostConfiguration(
                n(32), n(32), Optional.of(cancellation), Optional.empty());
        var attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("runner", "invalid-state", n(0)), n(1));
        var invalidInput = new NetworkEffect.AttemptInput(
                attempt,
                new NetworkEffect.HttpWireInstruction(
                        "GET", "http://127.0.0.1/", List.of(), List.of()),
                Optional.empty(),
                configuration);
        var prepared = new NetworkEffect.PreparedAttempt(
                invalidInput, new NetworkEffect.AttemptLineage.Root());
        var preparedState = new NetworkEffect.NetworkState(List.of(
                new NetworkEffect.AttemptRecord(
                        invalidInput, prepared.lineage(),
                        new NetworkEffect.AttemptDisposition.Prepared(),
                        Optional.empty(), List.of())));

        var read = NetworkEffect.readNetworkState(preparedState);
        check(read instanceof NetworkEffect.ReadStateStep.Rejected rejected
                        && rejected.failure() instanceof NetworkEffect.NetworkFailure.InvalidNetworkState invalid
                        && invalid.violation()
                                instanceof NetworkEffect.NetworkStateViolation.NonRootFirstAttempt,
                "read rejects invalid state with violation evidence");
        check(NetworkEffect.prepare(preparedState, input("http://127.0.0.1/"))
                        instanceof NetworkEffect.PrepareStep.Rejected rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.InvalidNetworkState,
                "prepare rejects invalid state");
        check(NetworkEffect.sendCommand(preparedState, prepared)
                        instanceof NetworkEffect.CommandStep.Rejected<?> rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.InvalidNetworkState,
                "send rejects invalid state");

        var commandIssuedState = new NetworkEffect.NetworkState(List.of(
                new NetworkEffect.AttemptRecord(
                        invalidInput, prepared.lineage(),
                        new NetworkEffect.AttemptDisposition.CommandIssued(),
                        Optional.empty(), List.of())));
        var handle = new ExecutionHandle("invalid-handle");
        check(NetworkEffect.observeStart(
                        commandIssuedState, prepared,
                        new NetworkEffect.StartObservation.Started(attempt, handle))
                        instanceof NetworkEffect.NetworkStep.Rejected rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.InvalidNetworkState,
                "start observation rejects invalid state");

        var startedState = new NetworkEffect.NetworkState(List.of(
                new NetworkEffect.AttemptRecord(
                        invalidInput, prepared.lineage(),
                        new NetworkEffect.AttemptDisposition.Started(handle),
                        Optional.empty(), List.of())));
        var started = new NetworkEffect.StartedAttempt(prepared, handle);
        check(NetworkEffect.cancelCommand(startedState, started)
                        instanceof NetworkEffect.CommandStep.Rejected<?> rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.InvalidNetworkState,
                "cancel rejects invalid state");
        check(NetworkEffect.observe(
                        startedState,
                        new NetworkEffect.HostObservation.Pending(attempt, handle))
                        instanceof NetworkEffect.NetworkStep.Rejected rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.InvalidNetworkState,
                "pending observation rejects invalid state");

        var terminal = new NetworkEffect.NetworkTerminal(
                new NetworkEffect.NetworkOutcome.Cancelled(),
                new NetworkEffect.EffectStatus.Unknown(
                        NetworkEffect.UnknownEffectReason.NoResponse));
        var settledState = new NetworkEffect.NetworkState(List.of(
                new NetworkEffect.AttemptRecord(
                        invalidInput, prepared.lineage(),
                        new NetworkEffect.AttemptDisposition.Settled(
                                Optional.empty(), terminal),
                        Optional.empty(), List.of())));
        var witness = new NetworkEffect.EffectWitness(
                attempt, NetworkEffect.EffectWitnessSource.Protocol,
                new NetworkEffect.OpaqueEvidence("protocol"));
        check(NetworkEffect.annotateEffect(
                        settledState,
                        new NetworkEffect.EffectObservation(
                                attempt,
                                new NetworkEffect.EffectStatus.EffectOccurred(witness)))
                        instanceof NetworkEffect.StateStep.Rejected rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.InvalidNetworkState,
                "effect annotation rejects invalid state");

        var next = new NetworkEffect.AttemptIdentity(attempt.logical(), n(2));
        var authorization = new NetworkEffect.RetryAuthorization(
                attempt.logical(), attempt, next,
                new NetworkEffect.OpaqueEvidence("retry"));
        var retry = new NetworkEffect.RetryRequest(
                new NetworkEffect.RetryPermission.RetryAllowed(authorization),
                invalidInput.instruction(), Optional.empty(), configuration);
        check(NetworkEffect.retry(settledState, retry)
                        instanceof NetworkEffect.PrepareStep.Rejected rejected
                        && rejected.failure()
                                instanceof NetworkEffect.NetworkFailure.RetryNotPermitted,
                "retry rejects invalid state");
    }
    private static void verifyCrossLineageFromMismatch() {
        var configuration = config();
        var logicalL = new RequestIdentity("generated", "runtime", n(0));
        var logicalM = new RequestIdentity("generated", "runtime", n(1));
        var terminal = new NetworkEffect.NetworkTerminal(
                new NetworkEffect.NetworkOutcome.Cancelled(),
                new NetworkEffect.EffectStatus.Unknown(
                        NetworkEffect.UnknownEffectReason.NoResponse));
        var wire = new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), List.of());
        var l0Attempt = new NetworkEffect.AttemptIdentity(logicalL, n(0));
        var m0Attempt = new NetworkEffect.AttemptIdentity(logicalM, n(0));
        var m1Attempt = new NetworkEffect.AttemptIdentity(logicalM, n(1));
        var l2Attempt = new NetworkEffect.AttemptIdentity(logicalL, n(2));
        var l0 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(l0Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptLineage.Root(),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var m0 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(m0Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptLineage.Root(),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var m1Authorization = new NetworkEffect.RetryAuthorization(
                logicalM, m0Attempt, m1Attempt, new NetworkEffect.OpaqueEvidence("m-retry"));
        var m1 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(m1Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptLineage.RetryOf(m1Authorization),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var l2Authorization = new NetworkEffect.RetryAuthorization(
                logicalL, m1Attempt, l2Attempt, new NetworkEffect.OpaqueEvidence("cross-lineage"));
        var l2 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(l2Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptLineage.RetryOf(l2Authorization),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var state = new NetworkEffect.NetworkState(List.of(l0, m0, m1, l2));
        var read = NetworkEffect.readNetworkState(state);
        check(read instanceof NetworkEffect.ReadStateStep.Rejected rejected
                        && rejected.failure() instanceof NetworkEffect.NetworkFailure.InvalidNetworkState invalid
                        && invalid.violation() instanceof NetworkEffect.NetworkStateViolation.LineageMismatch mismatch
                        && mismatch.attempt().equals(l2Attempt),
                "cross-lineage retry (from another logical) is rejected as LineageMismatch, matching Lean");
    }



    public static void main(String[] args) {
        NetworkEffect.NetworkState empty = new NetworkEffect.NetworkState(List.of());
        NetworkEffect.AttemptInput input = input("http://127.0.0.1/");
        NetworkEffect.PrepareStep preparedResult = NetworkEffect.prepare(empty, input);
        check(preparedResult instanceof NetworkEffect.PrepareStep.Prepared, "root prepare");
        var prepared = ((NetworkEffect.PrepareStep.Prepared) preparedResult).prepared();
        var issued = NetworkEffect.sendCommand(((NetworkEffect.PrepareStep.Prepared) preparedResult).state(), prepared);
        check(issued instanceof NetworkEffect.CommandStep.CommandReady, "send command");
        var handle = new ExecutionHandle("h");
        var started = NetworkEffect.observeStart(((NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) issued).state(),
                prepared, new NetworkEffect.StartObservation.Started(input.attempt(), handle));
        check(started instanceof NetworkEffect.NetworkStep.Started, "start observation");
        var startedValue = ((NetworkEffect.NetworkStep.Started) started).started();
        var response = new NetworkEffect.RawHttpResponse(200,
                List.of(new NetworkEffect.RawHeaderField("x", List.of(0xC3, 0xA9))), List.of(0x80, 0xFF));
        var observation = new NetworkEffect.AdapterObservation.ResponseObservation(input.attempt(), handle,
                new NetworkEffect.SourceSequence.None(), response, NetworkEffect.HeaderProvenance.WireObserved,
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse));
        var terminal = NetworkEffect.observe(((NetworkEffect.NetworkStep.Started) started).state(),
                new NetworkEffect.HostObservation.Delivered(n(0), observation));
        check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "response terminal");
        var settledState = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
        var witness = new NetworkEffect.EffectWitness(input.attempt(), NetworkEffect.EffectWitnessSource.Protocol,
                new NetworkEffect.OpaqueEvidence("peer"));
        var annotated = NetworkEffect.annotateEffect(settledState,
                new NetworkEffect.EffectObservation(input.attempt(), new NetworkEffect.EffectStatus.EffectOccurred(witness)));
        check(annotated instanceof NetworkEffect.StateStep.Applied, "effect annotation");
        var late = NetworkEffect.observe(settledState,
                new NetworkEffect.HostObservation.Delivered(n(1), observation));
        check(late instanceof NetworkEffect.NetworkStep.Late, "late observation");
        verifyInvalidStateRejection();
        verifyCrossLineageFromMismatch();
        System.out.println("NetworkEffectTest: OK");
    }
}
