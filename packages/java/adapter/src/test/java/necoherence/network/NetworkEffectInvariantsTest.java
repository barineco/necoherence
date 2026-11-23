// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Optional;
import java.util.Random;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;
import org.junit.jupiter.api.Test;

final class NetworkEffectInvariantsTest {
    private static Nat n(long value) { return Nat.fromLong(value); }

    private static NetworkEffect.HostConfiguration config() {
        return new NetworkEffect.HostConfiguration(n(32), n(32), Optional.empty(), Optional.empty());
    }

    private static NetworkEffect.AttemptInput input(NetworkEffect.AttemptIdentity attempt) {
        return new NetworkEffect.AttemptInput(attempt,
                new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), ByteString.empty()),
                Optional.empty(), config());
    }

    private static NetworkEffect.EffectStatus unknown() {
        return new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse);
    }

    private static NetworkEffect.AdapterObservation response(
            NetworkEffect.AttemptIdentity attempt, ExecutionHandle handle) {
        return new NetworkEffect.AdapterObservation.ResponseObservation(attempt, handle,
                new NetworkEffect.SourceSequence.None(),
                new NetworkEffect.RawHttpResponse(200, List.of(), ByteString.empty()),
                NetworkEffect.HeaderProvenance.WireObserved, unknown());
    }

    private static NetworkEffect.AttemptCondition conditionOf(NetworkEffect.AttemptRecord record) {
        return switch (record.disposition()) {
            case NetworkEffect.AttemptDisposition.Prepared ignored -> NetworkEffect.AttemptCondition.IsPrepared;
            case NetworkEffect.AttemptDisposition.CommandIssued ignored -> NetworkEffect.AttemptCondition.IsCommandIssued;
            case NetworkEffect.AttemptDisposition.Started ignored -> NetworkEffect.AttemptCondition.IsStarted;
            case NetworkEffect.AttemptDisposition.Settled ignored -> NetworkEffect.AttemptCondition.IsSettled;
        };
    }

    private static NetworkEffect.NetworkState state(NetworkEffect.NetworkStep step) {
        return switch (step) {
            case NetworkEffect.NetworkStep.Started x -> x.state();
            case NetworkEffect.NetworkStep.Pending x -> x.state();
            case NetworkEffect.NetworkStep.Terminal x -> x.state();
            case NetworkEffect.NetworkStep.Late x -> x.state();
            case NetworkEffect.NetworkStep.Duplicate x -> x.state();
            case NetworkEffect.NetworkStep.Rejected x -> x.state();
        };
    }

    private static final int[] reached = new int[4];

    private static NetworkEffect.NetworkState step(NetworkEffect.NetworkState state, Random random, long fresh) {
        List<NetworkEffect.AttemptRecord> records = state.attempts();
        if (records.isEmpty() || random.nextInt(6) == 0) {
            var attempt = new NetworkEffect.AttemptIdentity(new RequestIdentity("generated", "n", n(fresh)), n(0));
            return switch (NetworkEffect.prepare(state, input(attempt))) {
                case NetworkEffect.PrepareStep.Prepared prepared -> prepared.state();
                case NetworkEffect.PrepareStep.Rejected rejected -> rejected.state();
            };
        }
        NetworkEffect.AttemptRecord record = records.get(random.nextInt(records.size()));
        var prepared = new NetworkEffect.PreparedAttempt(record.input(), record.chain());
        var attempt = record.input().attempt();
        switch (conditionOf(record)) {
            case IsPrepared -> {
                return switch (NetworkEffect.sendCommand(state, prepared)) {
                    case NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand> ready -> ready.state();
                    case NetworkEffect.CommandStep.Rejected<NetworkEffect.SendCommand> rejected -> rejected.state();
                };
            }
            case IsCommandIssued -> {
                return state(NetworkEffect.observeStart(state, prepared,
                        new NetworkEffect.StartObservation.Started(attempt, new ExecutionHandle("h" + fresh))));
            }
            case IsStarted -> {
                var handle = ((NetworkEffect.AttemptDisposition.Started) record.disposition()).handle();
                return state(NetworkEffect.observe(state,
                        new NetworkEffect.HostObservation.Delivered(n(0), response(attempt, handle))));
            }
            default -> {
                var settled = (NetworkEffect.AttemptDisposition.Settled) record.disposition();
                int choice = random.nextInt(3);
                if (choice == 0 && settled.handle().isPresent()) {
                    long delivery = 1 + record.late().size();
                    var next = state(NetworkEffect.observe(state, new NetworkEffect.HostObservation.Delivered(
                            n(delivery), response(attempt, settled.handle().get()))));
                    reached[0]++;
                    return next;
                }
                if (choice == 1) {
                    var witness = new NetworkEffect.EffectWitness(attempt,
                            NetworkEffect.EffectWitnessSource.Protocol, new NetworkEffect.OpaqueEvidence("w"));
                    reached[1]++;
                    return switch (NetworkEffect.annotateEffect(state, new NetworkEffect.EffectObservation(
                            attempt, new NetworkEffect.EffectStatus.EffectOccurred(witness)))) {
                        case NetworkEffect.StateStep.Applied applied -> applied.state();
                        case NetworkEffect.StateStep.Rejected rejected -> rejected.state();
                    };
                }
                var nextAttempt = new NetworkEffect.AttemptIdentity(attempt.logical(), attempt.ordinal().successor());
                var authorization = new NetworkEffect.RetryAuthorization(
                        attempt.logical(), attempt, nextAttempt, new NetworkEffect.OpaqueEvidence("r"));
                var request = new NetworkEffect.RetryRequest(new NetworkEffect.RetryPermission.RetryAllowed(authorization),
                        record.input().instruction(), Optional.empty(), config());
                reached[2]++;
                return switch (NetworkEffect.retry(state, request)) {
                    case NetworkEffect.PrepareStep.Prepared prepared2 -> {
                        reached[3]++;
                        yield prepared2.state();
                    }
                    case NetworkEffect.PrepareStep.Rejected rejected -> rejected.state();
                };
            }
        }
    }

    @Test
    void generatedOperationSequencesKeepTheStateInvariant() {
        for (long seed = 0; seed < 80; seed++) {
            Random random = new Random(seed);
            NetworkEffect.NetworkState state = NetworkEffect.NetworkState.empty();
            for (long index = 0; index < 120; index++) {
                NetworkEffect.NetworkState before = state;
                List<NetworkEffect.AttemptRecord> beforeRecords = before.attempts();
                state = step(state, random, index);
                NetworkEffect.NetworkStateResult rebuilt = NetworkEffect.networkStateOf(state.attempts());
                assertEquals(state, assertInstanceOf(NetworkEffect.NetworkStateResult.Built.class, rebuilt).state());
                assertEquals(beforeRecords, before.attempts());
            }
        }
        assertTrue(reached[0] > 0 && reached[1] > 0 && reached[3] > 0, "late, annotation and accepted retry paths are reached");
    }
}
