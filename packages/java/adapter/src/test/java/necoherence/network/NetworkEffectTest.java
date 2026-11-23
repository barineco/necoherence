// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.util.List;
import java.util.Optional;
import neco.quotient.retention.ErasureDecision;
import neco.quotient.retention.RetentionReason;
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
                        List.of(new NetworkEffect.RawHeaderField("X-Test", ByteString.ofUnsigned(0x61, 0x7e))), ByteString.ofUnsigned(0x80, 0xff)),
                Optional.empty(), config());
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static NetworkEffect.NetworkStateViolation violationOf(List<NetworkEffect.AttemptRecord> records) {
        return NetworkEffect.networkStateOf(records) instanceof NetworkEffect.NetworkStateResult.Rejected rejected
                ? rejected.violation() : null;
    }
    private static void verifyInvalidStateRejection() {
        var attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("runner", "invalid-state", n(0)), n(1));
        var invalidInput = new NetworkEffect.AttemptInput(
                attempt,
                new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), ByteString.empty()),
                Optional.empty(),
                config());
        var terminal = new NetworkEffect.NetworkTerminal(
                new NetworkEffect.NetworkOutcome.Cancelled(),
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse));
        for (NetworkEffect.AttemptDisposition disposition : List.of(
                new NetworkEffect.AttemptDisposition.Prepared(),
                new NetworkEffect.AttemptDisposition.CommandIssued(),
                new NetworkEffect.AttemptDisposition.Started(new ExecutionHandle("invalid-handle")),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal))) {
            check(violationOf(List.of(new NetworkEffect.AttemptRecord(
                            invalidInput, new NetworkEffect.AttemptChain.Root(), disposition,
                            Optional.empty(), List.of())))
                            instanceof NetworkEffect.NetworkStateViolation.NonRootFirstAttempt,
                    "a first attempt that is not a root is rejected at construction: " + disposition);
        }
    }
    private static void verifyCrossChainFromMismatch() {
        var configuration = config();
        var logicalL = new RequestIdentity("generated", "runtime", n(0));
        var logicalM = new RequestIdentity("generated", "runtime", n(1));
        var terminal = new NetworkEffect.NetworkTerminal(
                new NetworkEffect.NetworkOutcome.Cancelled(),
                new NetworkEffect.EffectStatus.Unknown(
                        NetworkEffect.UnknownEffectReason.NoResponse));
        var wire = new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), ByteString.empty());
        var l0Attempt = new NetworkEffect.AttemptIdentity(logicalL, n(0));
        var m0Attempt = new NetworkEffect.AttemptIdentity(logicalM, n(0));
        var m1Attempt = new NetworkEffect.AttemptIdentity(logicalM, n(1));
        var l2Attempt = new NetworkEffect.AttemptIdentity(logicalL, n(2));
        var l0 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(l0Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptChain.Root(),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var m0 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(m0Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptChain.Root(),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var m1Authorization = new NetworkEffect.RetryAuthorization(
                logicalM, m0Attempt, m1Attempt, new NetworkEffect.OpaqueEvidence("m-retry"));
        var m1 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(m1Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptChain.RetryOf(m1Authorization),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var l2Authorization = new NetworkEffect.RetryAuthorization(
                logicalL, m1Attempt, l2Attempt, new NetworkEffect.OpaqueEvidence("cross-chain"));
        var l2 = new NetworkEffect.AttemptRecord(
                new NetworkEffect.AttemptInput(l2Attempt, wire, Optional.empty(), configuration),
                new NetworkEffect.AttemptChain.RetryOf(l2Authorization),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        check(violationOf(List.of(l0, m0, m1, l2))
                        instanceof NetworkEffect.NetworkStateViolation.ChainMismatch mismatch
                        && mismatch.attempt().equals(l2Attempt),
                "cross-chain retry (from another logical) is rejected as ChainMismatch, matching Lean");
    }

    private static void verifyHostRecordRelease(
            NetworkEffect.NetworkState startedState, NetworkEffect.NetworkState settledState,
            NetworkEffect.AttemptIdentity key) {
        check(NetworkEffect.hostAwaits(startedState, key), "a started record awaits the host");
        check(!NetworkEffect.hostAwaits(settledState, key), "a settled record does not await the host");
        check(!NetworkEffect.hostAwaits(NetworkEffect.NetworkState.empty(), key), "a missing record does not await the host");
        check(!NetworkEffect.hostSettled(startedState, key), "a started record is not settled");
        check(NetworkEffect.hostSettled(settledState, key), "a settled record is settled");
        check(!NetworkEffect.hostSettled(NetworkEffect.NetworkState.empty(), key), "a missing record is not settled");
        var startedDecision = NetworkEffect.releaseHostRecord(startedState, target -> false, key);
        check(startedDecision instanceof ErasureDecision.Retain<?, ?, ?, ?, ?> startedRetain
                        && startedRetain.reasons().equals(List.of(new RetentionReason.FutureUse<>(key))),
                "a started record is retained only for future use");
        var runningDecision = NetworkEffect.releaseHostRecord(settledState, target -> true, key);
        check(runningDecision instanceof ErasureDecision.Retain<?, ?, ?, ?, ?> runningRetain
                        && runningRetain.reasons().equals(List.of(new RetentionReason.OutstandingEffect<>(key))),
                "a settled record with a running worker is retained only for the outstanding effect");
        var settledDecision = NetworkEffect.releaseHostRecord(settledState, target -> false, key);
        check(settledDecision instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?> dematerialize
                        && dematerialize.witness().target().equals(key)
                        && dematerialize.witness().removedObservations().equals(List.of(
                                NetworkEffect.HostRecordObservation.UNDELIVERED,
                                NetworkEffect.HostRecordObservation.DELIVERY_ORDINAL)),
                "a settled record without a running worker may be discarded");
        check(NetworkEffect.releaseHostRecord(NetworkEffect.NetworkState.empty(), target -> false, key)
                        instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                "a missing record without a running worker may be discarded");
    }

    public static void main(String[] args) {
        NetworkEffect.NetworkState empty = NetworkEffect.NetworkState.empty();
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
                List.of(new NetworkEffect.RawHeaderField("x", ByteString.ofUnsigned(0xC3, 0xA9))), ByteString.ofUnsigned(0x80, 0xFF));
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
        verifyHostRecordRelease(((NetworkEffect.NetworkStep.Started) started).state(), settledState, input.attempt());
        verifyInvalidStateRejection();
        verifyCrossChainFromMismatch();
        System.out.println("NetworkEffectTest: OK");
    }
}
