// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import neco.quotient.Result;
import necoherence.progression.ExecutionHandle;
import necoherence.semantic.SemanticValues;

final class HttpPortFixtures {
    interface Now { NetworkEffect.MonotonicClockObservation get(); }
    interface ObserveResult { Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> get(); }
    interface Request { Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle); }

    static final NetworkEffect.MonotonicClockCapability UNUSED_CLOCK =
            new NetworkEffect.MonotonicClockCapability(
                    new NetworkEffect.OpaqueEvidence("unused-clock"), new NetworkEffect.ClockBasis("unused"));
    static final NetworkEffect.CancellationCapability UNUSED_CANCELLATION =
            new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("unused-cancel"));

    private HttpPortFixtures() {}

    static Result<SemanticValues.Unit, NetworkEffect.HostFailure> accepted() {
        return new Result.Accepted<>(SemanticValues.Unit.VALUE);
    }

    static Result<SemanticValues.Unit, NetworkEffect.HostFailure> rejected() {
        return rejected(new NetworkEffect.HostFailure.CancellationRejected());
    }

    static Result<SemanticValues.Unit, NetworkEffect.HostFailure> rejected(NetworkEffect.HostFailure failure) {
        return new Result.Rejected<>(failure);
    }

    static JavaHttpAdapter.MonotonicClockPort clock(NetworkEffect.MonotonicClockCapability capability, Now now) {
        return clockResult(capability, () -> new Result.Accepted<>(now.get()));
    }

    static JavaHttpAdapter.MonotonicClockPort clockResult(
            NetworkEffect.MonotonicClockCapability capability, ObserveResult observe) {
        return new JavaHttpAdapter.MonotonicClockPort() {
            @Override public NetworkEffect.MonotonicClockCapability capability() { return capability; }
            @Override public Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe() {
                return observe.get();
            }
        };
    }

    static JavaHttpAdapter.CancellationPort cancellation(
            NetworkEffect.CancellationCapability capability, Request request) {
        return new JavaHttpAdapter.CancellationPort() {
            @Override public NetworkEffect.CancellationCapability capability() { return capability; }
            @Override public Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle) {
                return request.request(handle);
            }
        };
    }
}
