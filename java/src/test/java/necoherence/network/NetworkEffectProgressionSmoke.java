// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.util.List;
import java.util.Optional;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;

public final class NetworkEffectProgressionSmoke {
    private static Nat n(long value) { return Nat.fromLong(value); }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    public static void main(String[] args) {
        var logical = new RequestIdentity("progression", "smoke", n(0));
        var root = new NetworkEffect.AttemptIdentity(logical, n(0));
        var config = new NetworkEffect.HostConfiguration(n(16), n(16),
                new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("cancel")),
                new NetworkEffect.MonotonicClockCapability(new NetworkEffect.OpaqueEvidence("clock"), new NetworkEffect.ClockBasis("mono")));
        var deadline = new NetworkEffect.Deadline(new NetworkEffect.ClockBasis("mono"), n(10), config.monotonicClock().get());
        var instruction = new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), List.of());
        var input = new NetworkEffect.AttemptInput(root, instruction, Optional.of(deadline), config);
        var prepared = NetworkEffect.prepare(new NetworkEffect.NetworkState(List.of()), input);
        check(prepared instanceof NetworkEffect.PrepareStep.Prepared, "progression root");
        var rootPrepared = ((NetworkEffect.PrepareStep.Prepared) prepared).prepared();
        var issued = NetworkEffect.sendCommand(((NetworkEffect.PrepareStep.Prepared) prepared).state(), rootPrepared);
        var started = NetworkEffect.observeStart(((NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) issued).state(),
                rootPrepared, new NetworkEffect.StartObservation.Started(root, new ExecutionHandle("progression-h")));
        check(started instanceof NetworkEffect.NetworkStep.Started, "progression start");
        var startedValue = ((NetworkEffect.NetworkStep.Started) started).started();
        var cancel = NetworkEffect.cancelCommand(((NetworkEffect.NetworkStep.Started) started).state(), startedValue);
        check(cancel instanceof NetworkEffect.CommandStep.CommandReady, "cancel capability");
        var cancelled = NetworkEffect.observe(((NetworkEffect.NetworkStep.Started) started).state(),
                new NetworkEffect.HostObservation.Delivered(n(0), new NetworkEffect.AdapterObservation.CancellationObservation(
                        root, startedValue.handle(), new NetworkEffect.SourceSequence.None(),
                        new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.Cancellation))));
        check(cancelled instanceof NetworkEffect.NetworkStep.Terminal, "cancel terminal");
        var authorization = new NetworkEffect.RetryAuthorization(logical, root,
                new NetworkEffect.AttemptIdentity(logical, n(1)), new NetworkEffect.OpaqueEvidence("protocol"));
        var retry = NetworkEffect.retry(((NetworkEffect.NetworkStep.Terminal) cancelled).state(),
                new NetworkEffect.RetryRequest(new NetworkEffect.RetryPermission.RetryAllowed(authorization), instruction,
                        Optional.of(deadline), config));
        check(retry instanceof NetworkEffect.PrepareStep.Prepared, "causal retry");
        check(((NetworkEffect.PrepareStep.Prepared) retry).prepared().lineage() instanceof NetworkEffect.AttemptLineage.RetryOf,
                "retry lineage");
        System.out.println("NetworkEffectProgressionSmoke: OK");
    }
}
