// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.net.URI;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.function.Predicate;
import neco.quotient.retention.ErasureDecision;
import neco.quotient.retention.ErasureRequest;
import neco.quotient.retention.LiveMembership;
import neco.quotient.retention.Recoverability;
import neco.quotient.retention.Retention;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.persistent.PersistentMap;
import necoherence.persistent.PersistentVector;
import necoherence.progression.RequestIdentity;

/** Pure network-effect ledger and its closed transition results. */
public final class NetworkEffect {
    private NetworkEffect() {}

    public record RawHeaderField(String name, ByteString value) {}
    public record HttpWireInstruction(String method, String target, List<RawHeaderField> headers,
            ByteString body) {
        public HttpWireInstruction { headers = List.copyOf(headers); }
    }
    public record RawHttpResponse(int status, List<RawHeaderField> headers, ByteString body) {
        public RawHttpResponse { headers = List.copyOf(headers); }
    }
    public enum HeaderProvenance { WireObserved, LibraryObserved, LibraryNormalized }
    public record AttemptIdentity(RequestIdentity logical, Nat ordinal) {}
    public record OpaqueEvidence(String value) {}
    public record ClockBasis(String value) {}
    public record MonotonicClockObservation(ClockBasis clockBasis, Nat value) {}
    public record MonotonicClockCapability(OpaqueEvidence identity, ClockBasis clockBasis) {}
    public record CancellationCapability(OpaqueEvidence identity) {}
    public record Deadline(ClockBasis clockBasis, Nat limit, MonotonicClockCapability capability) {}
    public record HostConfiguration(Nat requestBodyLimit, Nat responseBodyLimit,
            Optional<CancellationCapability> cancellation,
            Optional<MonotonicClockCapability> monotonicClock) {
        public HostConfiguration {
            cancellation = cancellation == null ? Optional.empty() : cancellation;
            monotonicClock = monotonicClock == null ? Optional.empty() : monotonicClock;
        }
        public HostConfiguration(Nat requestBodyLimit, Nat responseBodyLimit,
                CancellationCapability cancellation, MonotonicClockCapability clock) {
            this(requestBodyLimit, responseBodyLimit, Optional.ofNullable(cancellation), Optional.ofNullable(clock));
        }
    }
    public record AttemptInput(AttemptIdentity attempt, HttpWireInstruction instruction,
            Optional<Deadline> deadline, HostConfiguration configuration) {
        public AttemptInput {
            deadline = deadline == null ? Optional.empty() : deadline;
        }
        public AttemptInput(AttemptIdentity attempt, HttpWireInstruction instruction,
                Deadline deadline, HostConfiguration configuration) {
            this(attempt, instruction, Optional.ofNullable(deadline), configuration);
        }
    }
    public record RetryAuthorization(RequestIdentity logical, AttemptIdentity from, AttemptIdentity next,
            OpaqueEvidence protocolEvidence) {}
    public sealed interface AttemptChain permits AttemptChain.Root, AttemptChain.RetryOf {
        record Root() implements AttemptChain {}
        record RetryOf(RetryAuthorization authorization) implements AttemptChain {}
    }
    public record PreparedAttempt(AttemptInput input, AttemptChain chain) {}
    public record StartedAttempt(PreparedAttempt prepared, ExecutionHandle handle) {}
    public record SendCommand(PreparedAttempt prepared) {}
    public record CancelCommand(AttemptIdentity attempt, ExecutionHandle handle,
            CancellationCapability capability) {}

    public sealed interface EffectStatus permits EffectStatus.NoEffect, EffectStatus.EffectOccurred,
            EffectStatus.Unknown {
        record NoEffect(EffectWitness witness) implements EffectStatus {}
        record EffectOccurred(EffectWitness witness) implements EffectStatus {}
        record Unknown(UnknownEffectReason reason) implements EffectStatus {}
    }
    public enum EffectWitnessSource { Adapter, Protocol }
    public record EffectWitness(AttemptIdentity attempt, EffectWitnessSource source, OpaqueEvidence evidence) {}
    public enum UnknownEffectReason { NoResponse, Cancellation, Deadline, HostFailure, ProtocolWitnessMissing, LateSignal }
    public record EffectObservation(AttemptIdentity attempt, EffectStatus status) {}

    public enum HostStage { Start, RequestWrite, ResponseHeaders, ResponseBody, Cancel, Deadline }
    public enum HostTimeoutCause { LibraryReported, SocketReported, PoolAcquisition, HostOperation }
    public sealed interface HostFailure permits HostFailure.UnsupportedUriScheme, HostFailure.InvalidHostConfiguration,
            HostFailure.ExecutionStartFailed, HostFailure.NameResolutionFailed, HostFailure.ConnectionFailed,
            HostFailure.RequestWriteFailed, HostFailure.ResponseHeadersFailed, HostFailure.ResponseBodyFailed,
            HostFailure.ResponseBodyLimitExceeded, HostFailure.MalformedResponse,
            HostFailure.HeaderRepresentationUnavailable, HostFailure.RequestHeaderEncodingUnavailable,
            HostFailure.CancellationRejected, HostFailure.DeadlineControlUnavailable, HostFailure.Timeout,
            HostFailure.HostRuntimeFailure, HostFailure.HostClosed {
        record UnsupportedUriScheme() implements HostFailure {}
        record InvalidHostConfiguration() implements HostFailure {}
        record ExecutionStartFailed() implements HostFailure {}
        record NameResolutionFailed() implements HostFailure {}
        record ConnectionFailed() implements HostFailure {}
        record RequestWriteFailed() implements HostFailure {}
        record ResponseHeadersFailed() implements HostFailure {}
        record ResponseBodyFailed() implements HostFailure {}
        record ResponseBodyLimitExceeded() implements HostFailure {}
        record MalformedResponse() implements HostFailure {}
        record HeaderRepresentationUnavailable() implements HostFailure {}
        record RequestHeaderEncodingUnavailable() implements HostFailure {}
        record CancellationRejected() implements HostFailure {}
        record DeadlineControlUnavailable() implements HostFailure {}
        record Timeout(HostStage stage, HostTimeoutCause cause) implements HostFailure {}
        record HostRuntimeFailure() implements HostFailure {}
        record HostClosed() implements HostFailure {}
    }
    public record NetworkHostFailure(AttemptIdentity attempt, HostStage stage,
            HostConfiguration configuration, HostFailure cause) {}

    public sealed interface NetworkOutcome permits NetworkOutcome.Response, NetworkOutcome.Failed,
            NetworkOutcome.Cancelled, NetworkOutcome.DeadlineExceeded {
        record Response(RawHttpResponse response, HeaderProvenance provenance) implements NetworkOutcome {}
        record Failed(NetworkHostFailure failure) implements NetworkOutcome {}
        record Cancelled() implements NetworkOutcome {}
        record DeadlineExceeded(Deadline deadline, MonotonicClockObservation observed) implements NetworkOutcome {}
    }
    public record NetworkTerminal(NetworkOutcome outcome, EffectStatus effect) {}
    public sealed interface AttemptDisposition permits AttemptDisposition.Prepared,
            AttemptDisposition.CommandIssued, AttemptDisposition.Started, AttemptDisposition.Settled {
        record Prepared() implements AttemptDisposition {}
        record CommandIssued() implements AttemptDisposition {}
        record Started(ExecutionHandle handle) implements AttemptDisposition {}
        record Settled(Optional<ExecutionHandle> handle, NetworkTerminal terminal) implements AttemptDisposition {
            public Settled { handle = handle == null ? Optional.empty() : handle; }
        }
    }
    public sealed interface SourceSequence permits SourceSequence.None, SourceSequence.Some {
        record None() implements SourceSequence {}
        record Some(Nat ordinal) implements SourceSequence {}
    }
    public record DeliveredObservation(Nat delivery, AdapterObservation observation) {}
    public record LateObservation(DeliveredObservation delivered) {}
    public record AttemptRecord(AttemptInput input, AttemptChain chain, AttemptDisposition disposition,
            Optional<DeliveredObservation> firstDelivery, List<LateObservation> late) {
        public AttemptRecord {
            firstDelivery = firstDelivery == null ? Optional.empty() : firstDelivery;
            late = List.copyOf(late);
        }
    }
    /**
     * Attempt records that satisfy the network-state invariant.
     *
     * <p>{@link #networkStateOf} is the only way to build a non-empty state; it
     * checks the invariant once. Operations keep a state valid, so they do not
     * check it again. A state holds an index from attempt identity to position,
     * the highest ordinal seen per logical request, and the retry
     * authorizations already used; operations update these with the record
     * they change.
     */
    public static final class NetworkState {
        private static final NetworkState EMPTY = new NetworkState(
                PersistentVector.empty(), PersistentMap.empty(), PersistentMap.empty(), PersistentMap.empty());

        private final PersistentVector<AttemptRecord> records;
        private final PersistentMap<AttemptIdentity, Integer> positions;
        private final PersistentMap<RequestIdentity, Nat> latestOrdinals;
        private final PersistentMap<RetryAuthorization, Boolean> usedAuthorizations;

        private NetworkState(PersistentVector<AttemptRecord> records,
                PersistentMap<AttemptIdentity, Integer> positions,
                PersistentMap<RequestIdentity, Nat> latestOrdinals,
                PersistentMap<RetryAuthorization, Boolean> usedAuthorizations) {
            this.records = records;
            this.positions = positions;
            this.latestOrdinals = latestOrdinals;
            this.usedAuthorizations = usedAuthorizations;
        }

        public static NetworkState empty() {
            return EMPTY;
        }

        /** Return the attempt records in order. */
        public List<AttemptRecord> attempts() {
            return List.copyOf(records.toList());
        }

        private NetworkState appended(AttemptRecord record) {
            AttemptIdentity key = record.input().attempt();
            Nat latest = latestOrdinals.get(key.logical());
            Nat ordinal = latest == null ? key.ordinal() : latest.max(key.ordinal());
            return new NetworkState(records.append(record), positions.put(key, records.size()),
                    latestOrdinals.put(key.logical(), ordinal),
                    record.chain() instanceof AttemptChain.RetryOf retry
                            ? usedAuthorizations.put(retry.authorization(), Boolean.TRUE) : usedAuthorizations);
        }

        private NetworkState replaced(AttemptIdentity key, AttemptRecord replacement) {
            return new NetworkState(records.set(positions.get(key), replacement), positions, latestOrdinals,
                    usedAuthorizations);
        }

        private AttemptRecord find(AttemptIdentity key) {
            Integer position = positions.get(key);
            return position == null ? null : records.get(position);
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof NetworkState state && attempts().equals(state.attempts());
        }

        @Override
        public int hashCode() {
            return attempts().hashCode();
        }

        @Override
        public String toString() {
            return "NetworkState" + attempts();
        }
    }
    public sealed interface NetworkStateResult permits NetworkStateResult.Built, NetworkStateResult.Rejected {
        record Built(NetworkState state) implements NetworkStateResult {}
        record Rejected(NetworkStateViolation violation) implements NetworkStateResult {}
    }
    public sealed interface AdapterObservation permits AdapterObservation.ResponseObservation,
            AdapterObservation.FailureObservation, AdapterObservation.CancellationObservation,
            AdapterObservation.DeadlineObservation {
        AttemptIdentity attempt();
        ExecutionHandle handle();
        SourceSequence source();
        EffectStatus effect();
        record ResponseObservation(AttemptIdentity attempt, ExecutionHandle handle, SourceSequence source,
                RawHttpResponse response, HeaderProvenance provenance, EffectStatus effect) implements AdapterObservation {}
        record FailureObservation(AttemptIdentity attempt, ExecutionHandle handle, SourceSequence source,
                NetworkHostFailure failure, EffectStatus effect) implements AdapterObservation {}
        record CancellationObservation(AttemptIdentity attempt, ExecutionHandle handle, SourceSequence source,
                EffectStatus effect) implements AdapterObservation {}
        record DeadlineObservation(AttemptIdentity attempt, ExecutionHandle handle, SourceSequence source,
                Deadline deadline, MonotonicClockObservation observed, EffectStatus effect) implements AdapterObservation {}
    }
    public sealed interface RetryPermission permits RetryPermission.RetryAllowed, RetryPermission.RetryDenied {
        record RetryAllowed(RetryAuthorization authorization) implements RetryPermission {}
        record RetryDenied(RequestIdentity logical, AttemptIdentity attempt, OpaqueEvidence evidence)
                implements RetryPermission {}
    }
    public record RetryRequest(RetryPermission permission, HttpWireInstruction instruction,
            Optional<Deadline> deadline, HostConfiguration configuration) {
        public RetryRequest { deadline = deadline == null ? Optional.empty() : deadline; }
        public RetryRequest(RetryPermission permission, HttpWireInstruction instruction, Deadline deadline,
                HostConfiguration configuration) { this(permission, instruction, Optional.ofNullable(deadline), configuration); }
    }
    public sealed interface StartObservation permits StartObservation.Started, StartObservation.StartFailed {
        record Started(AttemptIdentity attempt, ExecutionHandle handle) implements StartObservation {}
        record StartFailed(NetworkHostFailure failure, EffectStatus effect) implements StartObservation {}
    }
    public sealed interface HostObservation permits HostObservation.Pending, HostObservation.Delivered {
        record Pending(AttemptIdentity attempt, ExecutionHandle handle) implements HostObservation {}
        record Delivered(Nat delivery, AdapterObservation observation) implements HostObservation {}
    }

    public sealed interface NetworkStateViolation permits NetworkStateViolation.DuplicateAttemptKey,
            NetworkStateViolation.NonRootFirstAttempt, NetworkStateViolation.OrdinalGap,
            NetworkStateViolation.ChainMismatch, NetworkStateViolation.RetryAuthorizationReuse,
            NetworkStateViolation.DispositionEvidenceMismatch, NetworkStateViolation.DeliveryLogMismatch {
        record DuplicateAttemptKey(AttemptIdentity attempt) implements NetworkStateViolation {}
        record NonRootFirstAttempt(AttemptIdentity attempt) implements NetworkStateViolation {}
        record OrdinalGap(AttemptIdentity attempt) implements NetworkStateViolation {}
        record ChainMismatch(AttemptIdentity attempt) implements NetworkStateViolation {}
        record RetryAuthorizationReuse(RetryAuthorization authorization) implements NetworkStateViolation {}
        record DispositionEvidenceMismatch(AttemptIdentity attempt) implements NetworkStateViolation {}
        record DeliveryLogMismatch(AttemptIdentity attempt) implements NetworkStateViolation {}
    }
    public enum AttemptCondition { IsPrepared, IsCommandIssued, IsStarted, IsSettled }
    public enum AttemptTokenField { Instruction, Deadline, Configuration, Chain, Handle }
    public enum ObservationField { FailureConfiguration, FailureStage, DeadlineValue, ClockBasisValue,
        ClockObservationValue, EffectWitnessValue }
    public enum CapabilityKind { Cancellation, MonotonicClock }
    public sealed interface NetworkFailure permits NetworkFailure.InvalidWireInstruction, NetworkFailure.InvalidDeadline,
            NetworkFailure.InvalidNetworkState, NetworkFailure.RootAttemptRequired, NetworkFailure.DuplicateAttempt,
            NetworkFailure.UnknownAttempt, NetworkFailure.AttemptConditionMismatch, NetworkFailure.AttemptTokenMismatch,
            NetworkFailure.ObservationRelationMismatch, NetworkFailure.RequiredCapabilityUnavailable,
            NetworkFailure.CommandAlreadyIssued, NetworkFailure.IdentityMismatch, NetworkFailure.HandleMismatch,
            NetworkFailure.ClockBasisMismatch, NetworkFailure.DeadlineNotReached, NetworkFailure.DeliveryOrderViolation,
            NetworkFailure.ConflictingDelivery, NetworkFailure.MalformedAdapterObservation, NetworkFailure.Host,
            NetworkFailure.RetryNotPermitted, NetworkFailure.RetryIdentityMismatch, NetworkFailure.RetryParentMismatch,
            NetworkFailure.RetryParentNotSettled, NetworkFailure.RetryOrderViolation,
            NetworkFailure.RetryAuthorizationAlreadyUsed, NetworkFailure.EffectWitnessMissing,
            NetworkFailure.EffectKnowledgeConflict {
        record InvalidWireInstruction(String method) implements NetworkFailure {}
        record InvalidDeadline() implements NetworkFailure {}
        record InvalidNetworkState(NetworkStateViolation violation) implements NetworkFailure {}
        record RootAttemptRequired(AttemptIdentity attempt) implements NetworkFailure {}
        record DuplicateAttempt(AttemptIdentity attempt) implements NetworkFailure {}
        record UnknownAttempt(AttemptIdentity attempt) implements NetworkFailure {}
        record AttemptConditionMismatch(AttemptIdentity attempt, AttemptCondition expected,
                AttemptCondition actual) implements NetworkFailure {}
        record AttemptTokenMismatch(AttemptIdentity attempt, AttemptTokenField field) implements NetworkFailure {}
        record ObservationRelationMismatch(AttemptIdentity attempt, ObservationField field) implements NetworkFailure {}
        record RequiredCapabilityUnavailable(AttemptIdentity attempt, CapabilityKind capability) implements NetworkFailure {}
        record CommandAlreadyIssued(AttemptIdentity attempt) implements NetworkFailure {}
        record IdentityMismatch(AttemptIdentity expected, AttemptIdentity actual) implements NetworkFailure {}
        record HandleMismatch(ExecutionHandle expected, ExecutionHandle actual) implements NetworkFailure {}
        record ClockBasisMismatch(ClockBasis expected, ClockBasis actual) implements NetworkFailure {}
        record DeadlineNotReached(Deadline deadline, MonotonicClockObservation observed) implements NetworkFailure {}
        record DeliveryOrderViolation(AttemptIdentity attempt, Nat expected, Nat actual) implements NetworkFailure {}
        record ConflictingDelivery(AttemptIdentity attempt, Nat delivery, AdapterObservation oldObservation,
                AdapterObservation newObservation) implements NetworkFailure {}
        record MalformedAdapterObservation() implements NetworkFailure {}
        record Host(NetworkHostFailure failure) implements NetworkFailure {}
        record RetryNotPermitted(AttemptIdentity attempt) implements NetworkFailure {}
        record RetryIdentityMismatch(RequestIdentity expected, RequestIdentity actual) implements NetworkFailure {}
        record RetryParentMismatch(AttemptIdentity expected, AttemptIdentity actual) implements NetworkFailure {}
        record RetryParentNotSettled(AttemptIdentity attempt) implements NetworkFailure {}
        record RetryOrderViolation(AttemptIdentity parent, AttemptIdentity next) implements NetworkFailure {}
        record RetryAuthorizationAlreadyUsed(RetryAuthorization authorization) implements NetworkFailure {}
        record EffectWitnessMissing(AttemptIdentity attempt) implements NetworkFailure {}
        record EffectKnowledgeConflict(AttemptIdentity attempt) implements NetworkFailure {}
    }

    public sealed interface ReadStateStep permits ReadStateStep.Read, ReadStateStep.Rejected {
        record Read(NetworkState state) implements ReadStateStep {}
        record Rejected(NetworkState state, NetworkFailure failure) implements ReadStateStep {}
    }
    public sealed interface PrepareStep permits PrepareStep.Prepared, PrepareStep.Rejected {
        record Prepared(NetworkState state, PreparedAttempt prepared) implements PrepareStep {}
        record Rejected(NetworkState state, NetworkFailure failure) implements PrepareStep {}
    }
    public sealed interface CommandStep<T> permits CommandStep.CommandReady, CommandStep.Rejected {
        record CommandReady<T>(NetworkState state, T command) implements CommandStep<T> {}
        record Rejected<T>(NetworkState state, NetworkFailure failure) implements CommandStep<T> {}
    }
    public sealed interface StateStep permits StateStep.Applied, StateStep.Rejected {
        record Applied(NetworkState state) implements StateStep {}
        record Rejected(NetworkState state, NetworkFailure failure) implements StateStep {}
    }
    public record SettledAttempt(PreparedAttempt prepared, Optional<ExecutionHandle> handle, NetworkTerminal terminal) {
        public SettledAttempt { handle = handle == null ? Optional.empty() : handle; }
    }
    public sealed interface NetworkStep permits NetworkStep.Started, NetworkStep.Pending, NetworkStep.Terminal,
            NetworkStep.Late, NetworkStep.Duplicate, NetworkStep.Rejected {
        record Started(NetworkState state, StartedAttempt started) implements NetworkStep {}
        record Pending(NetworkState state, StartedAttempt started) implements NetworkStep {}
        record Terminal(NetworkState state, SettledAttempt settled) implements NetworkStep {}
        record Late(NetworkState state, SettledAttempt settled, LateObservation late) implements NetworkStep {}
        record Duplicate(NetworkState state, AttemptIdentity attempt, Nat delivery) implements NetworkStep {}
        record Rejected(NetworkState state, NetworkFailure failure) implements NetworkStep {}
    }

    public static ReadStateStep readNetworkState(NetworkState state) {
        return new ReadStateStep.Read(state);
    }

    public static PrepareStep prepare(NetworkState state, AttemptInput input) {
        if (!validInput(input)) return rejectPrepare(state, new NetworkFailure.InvalidWireInstruction(input.instruction().method()));
        if (!input.attempt().ordinal().equals(Nat.zero()))
            return rejectPrepare(state, new NetworkFailure.RootAttemptRequired(input.attempt()));
        if (state.latestOrdinals.containsKey(input.attempt().logical()))
            return rejectPrepare(state, new NetworkFailure.DuplicateAttempt(input.attempt()));
        PreparedAttempt prepared = new PreparedAttempt(input, new AttemptChain.Root());
        AttemptRecord record = new AttemptRecord(input, prepared.chain(), new AttemptDisposition.Prepared(), Optional.empty(), List.of());
        return new PrepareStep.Prepared(state.appended(record), prepared);
    }

    public static CommandStep<SendCommand> sendCommand(NetworkState state, PreparedAttempt prepared) {
        if (commandIssuedMatches(state, prepared))
            return rejectCommand(state,
                    new NetworkFailure.CommandAlreadyIssued(prepared.input().attempt()));
        if (!preparedReady(state, prepared)) {
            NetworkFailure failure = preparedConditionFailure(
                    state, prepared, AttemptCondition.IsPrepared);
            return rejectCommand(state, failure != null ? failure
                    : new NetworkFailure.AttemptConditionMismatch(
                            prepared.input().attempt(),
                            AttemptCondition.IsPrepared, AttemptCondition.IsPrepared));
        }
        AttemptRecord record = find(state, prepared.input().attempt());
        NetworkState next = state.replaced(prepared.input().attempt(),
                new AttemptRecord(record.input(), record.chain(),
                        new AttemptDisposition.CommandIssued(),
                        record.firstDelivery(), record.late()));
        return new CommandStep.CommandReady<>(next, new SendCommand(prepared));
    }

    public static CommandStep<CancelCommand> cancelCommand(NetworkState state, StartedAttempt started) {
        if (!startedRelation(state, started)) {
            NetworkFailure failure = startedTokenFailure(state, started);
            return rejectCommand(state, failure != null ? failure
                    : new NetworkFailure.AttemptConditionMismatch(
                            started.prepared().input().attempt(),
                            AttemptCondition.IsStarted, AttemptCondition.IsStarted));
        }
        if (started.prepared().input().configuration().cancellation().isEmpty())
            return rejectCommand(state, new NetworkFailure.RequiredCapabilityUnavailable(
                    started.prepared().input().attempt(), CapabilityKind.Cancellation));
        return new CommandStep.CommandReady<>(state, new CancelCommand(
                started.prepared().input().attempt(), started.handle(),
                started.prepared().input().configuration().cancellation().get()));
    }

    public static NetworkStep observeStart(
            NetworkState state, PreparedAttempt prepared, StartObservation observation) {
        if (!startObservationRelation(state, prepared, observation)) {
            NetworkFailure conditionFailure = preparedConditionFailure(
                    state, prepared, AttemptCondition.IsCommandIssued);
            if (conditionFailure != null)
                return rejectNetwork(state, conditionFailure);
            if (observation instanceof StartObservation.Started started)
                return rejectNetwork(state, new NetworkFailure.IdentityMismatch(
                        prepared.input().attempt(), started.attempt()));
            StartObservation.StartFailed failed =
                    (StartObservation.StartFailed) observation;
            if (!failed.failure().attempt().equals(prepared.input().attempt()))
                return rejectNetwork(state, new NetworkFailure.IdentityMismatch(
                        prepared.input().attempt(), failed.failure().attempt()));
            if (failed.failure().stage() != HostStage.Start)
                return rejectNetwork(state,
                        new NetworkFailure.ObservationRelationMismatch(
                                prepared.input().attempt(), ObservationField.FailureStage));
            if (!failed.failure().configuration().equals(
                    prepared.input().configuration()))
                return rejectNetwork(state,
                        new NetworkFailure.ObservationRelationMismatch(
                                prepared.input().attempt(),
                                ObservationField.FailureConfiguration));
            return rejectNetwork(state,
                    new NetworkFailure.ObservationRelationMismatch(
                            prepared.input().attempt(),
                            ObservationField.EffectWitnessValue));
        }
        AttemptRecord record = find(state, prepared.input().attempt());
        if (observation instanceof StartObservation.Started started) {
            StartedAttempt value = new StartedAttempt(prepared, started.handle());
            NetworkState next = state.replaced(prepared.input().attempt(),
                    new AttemptRecord(record.input(), record.chain(),
                            new AttemptDisposition.Started(started.handle()),
                            record.firstDelivery(), record.late()));
            return new NetworkStep.Started(next, value);
        }
        StartObservation.StartFailed failed = (StartObservation.StartFailed) observation;
        NetworkTerminal terminal = new NetworkTerminal(
                new NetworkOutcome.Failed(failed.failure()), failed.effect());
        NetworkState next = state.replaced(prepared.input().attempt(),
                new AttemptRecord(record.input(), record.chain(),
                        new AttemptDisposition.Settled(Optional.empty(), terminal),
                        record.firstDelivery(), record.late()));
        return new NetworkStep.Terminal(
                next, new SettledAttempt(prepared, Optional.empty(), terminal));
    }

    public static NetworkStep observe(NetworkState state, HostObservation observation) {
        if (!hostObservationRelation(state, observation)) {
            return rejectNetwork(state, hostObservationFailure(state, observation));
        }
        if (observation instanceof HostObservation.Pending pending) {
            AttemptRecord record = find(state, pending.attempt());
            return new NetworkStep.Pending(state, new StartedAttempt(
                    new PreparedAttempt(record.input(), record.chain()), pending.handle()));
        }
        HostObservation.Delivered delivered = (HostObservation.Delivered) observation;
        AdapterObservation value = delivered.observation();
        AttemptRecord record = find(state, value.attempt());
        Optional<AdapterObservation> old = recorded(record, delivered.delivery());
        if (old.isPresent()) {
            return old.get().equals(value)
                    ? new NetworkStep.Duplicate(state, value.attempt(), delivered.delivery())
                    : rejectNetwork(state, new NetworkFailure.ConflictingDelivery(
                            value.attempt(), delivered.delivery(), old.get(), value));
        }
        Nat expected = nextDelivery(record);
        if (!delivered.delivery().equals(expected))
            return rejectNetwork(state, new NetworkFailure.DeliveryOrderViolation(
                    value.attempt(), expected, delivered.delivery()));
        if (record.disposition() instanceof AttemptDisposition.Settled settled) {
            LateObservation late = new LateObservation(new DeliveredObservation(delivered.delivery(), value));
            NetworkState next = state.replaced(value.attempt(),
                    new AttemptRecord(record.input(), record.chain(), settled,
                            record.firstDelivery(), append(record.late(), late)));
            SettledAttempt settledAttempt = new SettledAttempt(
                    new PreparedAttempt(record.input(), record.chain()),
                    settled.handle(), settled.terminal());
            return new NetworkStep.Late(next, settledAttempt, late);
        }
        if (!(record.disposition() instanceof AttemptDisposition.Started started))
            return rejectNetwork(state, new NetworkFailure.AttemptConditionMismatch(
                    value.attempt(), AttemptCondition.IsStarted, condition(record.disposition())));
        NetworkTerminal terminal = terminalOf(value);
        Optional<ExecutionHandle> handle = Optional.of(started.handle());
        DeliveredObservation first = new DeliveredObservation(delivered.delivery(), value);
        NetworkState next = state.replaced(value.attempt(),
                new AttemptRecord(record.input(), record.chain(),
                        new AttemptDisposition.Settled(handle, terminal), Optional.of(first), List.of()));
        return new NetworkStep.Terminal(next, new SettledAttempt(
                new PreparedAttempt(record.input(), record.chain()), handle, terminal));
    }

    public static StateStep annotateEffect(NetworkState state, EffectObservation observation) {
        AttemptRecord record = find(state, observation.attempt());
        if (record == null)
            return new StateStep.Rejected(state, new NetworkFailure.UnknownAttempt(observation.attempt()));
        if (!(record.disposition() instanceof AttemptDisposition.Settled settled))
            return new StateStep.Rejected(state, new NetworkFailure.AttemptConditionMismatch(
                    observation.attempt(), AttemptCondition.IsSettled, condition(record.disposition())));
        if (!effectMatches(observation.attempt(), observation.status()))
            return new StateStep.Rejected(state, new NetworkFailure.EffectWitnessMissing(observation.attempt()));
        EffectStatus current = settled.terminal().effect();
        if (!annotationStatusOk(current, observation.status())) {
            NetworkFailure failure = annotationConflict(current, observation.status())
                    ? new NetworkFailure.EffectKnowledgeConflict(observation.attempt())
                    : new NetworkFailure.EffectWitnessMissing(observation.attempt());
            return new StateStep.Rejected(state, failure);
        }
        NetworkTerminal terminal = new NetworkTerminal(settled.terminal().outcome(), observation.status());
        NetworkState next = state.replaced(observation.attempt(),
                new AttemptRecord(record.input(), record.chain(),
                        new AttemptDisposition.Settled(settled.handle(), terminal),
                        record.firstDelivery(), record.late()));
        return new StateStep.Applied(next);
    }

    public static PrepareStep retry(NetworkState state, RetryRequest request) {
        if (!retryAcceptable(state, request))
            return rejectPrepare(state, new NetworkFailure.RetryNotPermitted(retryKey(request.permission())));
        RetryAuthorization authorization =
                ((RetryPermission.RetryAllowed) request.permission()).authorization();
        AttemptInput input = new AttemptInput(authorization.next(), request.instruction(),
                request.deadline(), request.configuration());
        PreparedAttempt prepared = new PreparedAttempt(input, new AttemptChain.RetryOf(authorization));
        NetworkState next = state.appended(new AttemptRecord(input, prepared.chain(),
                new AttemptDisposition.Prepared(), Optional.empty(), List.of()));
        return new PrepareStep.Prepared(next, prepared);
    }

    private static AttemptIdentity retryKey(RetryPermission permission) {
        return permission instanceof RetryPermission.RetryAllowed a ? a.authorization().from() : ((RetryPermission.RetryDenied) permission).attempt();
    }
    private static <T> CommandStep<T> rejectCommand(NetworkState s, NetworkFailure f) { return new CommandStep.Rejected<>(s, f); }
    private static PrepareStep.Rejected rejectPrepare(NetworkState s, NetworkFailure f) { return new PrepareStep.Rejected(s, f); }
    private static NetworkStep.Rejected rejectNetwork(NetworkState s, NetworkFailure f) { return new NetworkStep.Rejected(s, f); }
    private static AttemptRecord find(NetworkState state, AttemptIdentity key) {
        return state.find(key);
    }
    private static <T> List<T> append(List<T> values, T value) { List<T> result = new ArrayList<>(values); result.add(value); return result; }
    private static AttemptCondition condition(AttemptDisposition d) {
        return switch (d) { case AttemptDisposition.Prepared ignored -> AttemptCondition.IsPrepared;
            case AttemptDisposition.CommandIssued ignored -> AttemptCondition.IsCommandIssued;
            case AttemptDisposition.Started ignored -> AttemptCondition.IsStarted;
            case AttemptDisposition.Settled ignored -> AttemptCondition.IsSettled; };
    }
    private static boolean preparedRelation(NetworkState state, PreparedAttempt prepared) {
        AttemptRecord record = find(state, prepared.input().attempt());
        return record != null && record.input().equals(prepared.input())
                && record.chain().equals(prepared.chain());
    }
    private static boolean preparedReady(NetworkState state, PreparedAttempt prepared) {
        if (!preparedRelation(state, prepared)) return false;
        return find(state, prepared.input().attempt()).disposition() instanceof AttemptDisposition.Prepared;
    }
    private static boolean commandIssuedMatches(NetworkState state, PreparedAttempt prepared) {
        AttemptRecord record = find(state, prepared.input().attempt());
        return record != null && record.input().equals(prepared.input())
                && record.chain().equals(prepared.chain())
                && record.disposition() instanceof AttemptDisposition.CommandIssued;
    }
    private static boolean commandIssuedRelation(NetworkState state, PreparedAttempt prepared) {
        if (!preparedRelation(state, prepared)) return false;
        return find(state, prepared.input().attempt()).disposition() instanceof AttemptDisposition.CommandIssued;
    }
    private static boolean startedRelation(NetworkState state, StartedAttempt started) {
        AttemptRecord record = find(state, started.prepared().input().attempt());
        return record != null
                && record.input().equals(started.prepared().input())
                && record.chain().equals(started.prepared().chain())
                && record.disposition() instanceof AttemptDisposition.Started disposition
                && disposition.handle().equals(started.handle())
                && record.firstDelivery().isEmpty()
                && record.late().isEmpty();
    }
    private static NetworkFailure preparedTokenFailure(
            NetworkState state, PreparedAttempt prepared) {
        AttemptIdentity attempt = prepared.input().attempt();
        AttemptRecord record = find(state, attempt);
        if (record == null) return new NetworkFailure.UnknownAttempt(attempt);
        if (!record.input().instruction().equals(prepared.input().instruction()))
            return new NetworkFailure.AttemptTokenMismatch(
                    attempt, AttemptTokenField.Instruction);
        if (!record.input().deadline().equals(prepared.input().deadline()))
            return new NetworkFailure.AttemptTokenMismatch(
                    attempt, AttemptTokenField.Deadline);
        if (!record.input().configuration().equals(prepared.input().configuration()))
            return new NetworkFailure.AttemptTokenMismatch(
                    attempt, AttemptTokenField.Configuration);
        if (!record.chain().equals(prepared.chain()))
            return new NetworkFailure.AttemptTokenMismatch(
                    attempt, AttemptTokenField.Chain);
        return null;
    }
    private static NetworkFailure preparedConditionFailure(
            NetworkState state, PreparedAttempt prepared, AttemptCondition expected) {
        NetworkFailure tokenFailure = preparedTokenFailure(state, prepared);
        if (tokenFailure != null) return tokenFailure;
        AttemptRecord record = find(state, prepared.input().attempt());
        if (record == null)
            return new NetworkFailure.UnknownAttempt(prepared.input().attempt());
        AttemptCondition actual = condition(record.disposition());
        return actual == expected ? null
                : new NetworkFailure.AttemptConditionMismatch(
                        prepared.input().attempt(), expected, actual);
    }
    private static NetworkFailure startedTokenFailure(
            NetworkState state, StartedAttempt started) {
        NetworkFailure tokenFailure = preparedTokenFailure(state, started.prepared());
        if (tokenFailure != null) return tokenFailure;
        AttemptIdentity attempt = started.prepared().input().attempt();
        AttemptRecord record = find(state, attempt);
        if (record == null) return new NetworkFailure.UnknownAttempt(attempt);
        if (!(record.disposition() instanceof AttemptDisposition.Started disposition))
            return new NetworkFailure.AttemptConditionMismatch(
                    attempt, AttemptCondition.IsStarted, condition(record.disposition()));
        return disposition.handle().equals(started.handle()) ? null
                : new NetworkFailure.HandleMismatch(
                        disposition.handle(), started.handle());
    }
    private static NetworkFailure hostObservationFailure(
            NetworkState state, HostObservation observation) {
        if (observation instanceof HostObservation.Pending pending) {
            AttemptRecord record = find(state, pending.attempt());
            if (record == null)
                return new NetworkFailure.UnknownAttempt(pending.attempt());
            if (!(record.disposition() instanceof AttemptDisposition.Started started))
                return new NetworkFailure.AttemptConditionMismatch(
                        pending.attempt(), AttemptCondition.IsStarted,
                        condition(record.disposition()));
            return started.handle().equals(pending.handle())
                    ? new NetworkFailure.MalformedAdapterObservation()
                    : new NetworkFailure.HandleMismatch(
                            started.handle(), pending.handle());
        }
        AdapterObservation delivered =
                ((HostObservation.Delivered) observation).observation();
        AttemptIdentity attempt = delivered.attempt();
        AttemptRecord record = find(state, attempt);
        if (record == null) return new NetworkFailure.UnknownAttempt(attempt);
        Optional<ExecutionHandle> expectedHandle =
                dispositionHandle(record.disposition());
        if (expectedHandle.isEmpty())
            return new NetworkFailure.AttemptConditionMismatch(
                    attempt, AttemptCondition.IsStarted,
                    condition(record.disposition()));
        if (!delivered.handle().equals(expectedHandle.get()))
            return new NetworkFailure.HandleMismatch(
                    expectedHandle.get(), delivered.handle());
        if (!effectMatches(attempt, delivered.effect()))
            return new NetworkFailure.EffectWitnessMissing(attempt);
        if (delivered instanceof AdapterObservation.ResponseObservation
                || delivered instanceof AdapterObservation.CancellationObservation)
            return new NetworkFailure.MalformedAdapterObservation();
        if (delivered instanceof AdapterObservation.FailureObservation failure) {
            NetworkHostFailure value = failure.failure();
            if (!value.attempt().equals(attempt))
                return new NetworkFailure.IdentityMismatch(
                        attempt, value.attempt());
            if (value.cause() instanceof HostFailure.Timeout timeout
                    && timeout.stage() != value.stage())
                return new NetworkFailure.ObservationRelationMismatch(
                        attempt, ObservationField.FailureStage);
            return new NetworkFailure.ObservationRelationMismatch(
                    attempt, ObservationField.FailureConfiguration);
        }
        AdapterObservation.DeadlineObservation deadline =
                (AdapterObservation.DeadlineObservation) delivered;
        if (!record.input().deadline().equals(Optional.of(deadline.deadline())))
            return new NetworkFailure.ObservationRelationMismatch(
                    attempt, ObservationField.DeadlineValue);
        if (!deadline.deadline().clockBasis().equals(
                deadline.observed().clockBasis()))
            return new NetworkFailure.ClockBasisMismatch(
                    deadline.deadline().clockBasis(),
                    deadline.observed().clockBasis());
        return new NetworkFailure.DeadlineNotReached(
                deadline.deadline(), deadline.observed());
    }
    private static boolean startObservationRelation(
            NetworkState state, PreparedAttempt prepared, StartObservation observation) {
        if (!commandIssuedRelation(state, prepared)) return false;
        if (observation instanceof StartObservation.Started started)
            return started.attempt().equals(prepared.input().attempt());
        StartObservation.StartFailed failed = (StartObservation.StartFailed) observation;
        return failed.failure().attempt().equals(prepared.input().attempt())
                && failed.failure().stage() == HostStage.Start
                && failed.failure().configuration().equals(prepared.input().configuration())
                && effectMatches(prepared.input().attempt(), failed.effect());
    }
    private static boolean responseFieldsMatch(AttemptRecord record, AdapterObservation observation) {
        if (observation instanceof AdapterObservation.CancellationObservation) return true;
        if (!(observation instanceof AdapterObservation.ResponseObservation response)) return false;
        RawHttpResponse value = response.response();
        return value.status() >= 100 && value.status() <= 999
                && headers(value.headers())
                && Nat.fromLong(value.body().size()).compareTo(
                        record.input().configuration().responseBodyLimit()) <= 0;
    }
    private static boolean failureFieldsMatch(AttemptRecord record, AdapterObservation observation) {
        if (!(observation instanceof AdapterObservation.FailureObservation failure)) return false;
        NetworkHostFailure value = failure.failure();
        return value.attempt().equals(failure.attempt())
                && value.configuration().equals(record.input().configuration())
                && (!(value.cause() instanceof HostFailure.Timeout timeout)
                        || timeout.stage() == value.stage());
    }
    private static boolean clockReaches(Deadline deadline, MonotonicClockObservation observation) {
        return deadline.capability().clockBasis().equals(deadline.clockBasis())
                && observation.clockBasis().equals(deadline.clockBasis())
                && deadline.limit().compareTo(observation.value()) <= 0;
    }
    private static boolean deadlineFieldsMatch(AttemptRecord record, AdapterObservation observation) {
        if (record.input().deadline().isEmpty()
                || record.input().configuration().monotonicClock().isEmpty()
                || !(observation instanceof AdapterObservation.DeadlineObservation deadline))
            return false;
        Deadline expected = record.input().deadline().get();
        return expected.equals(deadline.deadline())
                && record.input().configuration().monotonicClock().get().equals(expected.capability())
                && clockReaches(expected, deadline.observed());
    }
    private static Optional<ExecutionHandle> dispositionHandle(AttemptDisposition disposition) {
        if (disposition instanceof AttemptDisposition.Started started)
            return Optional.of(started.handle());
        if (disposition instanceof AttemptDisposition.Settled settled)
            return settled.handle();
        return Optional.empty();
    }
    private static boolean observationRelation(NetworkState state, AdapterObservation observation) {
        AttemptRecord record = find(state, observation.attempt());
        if (record == null) return false;
        Optional<ExecutionHandle> handle = dispositionHandle(record.disposition());
        return handle.isPresent()
                && observation.attempt().equals(record.input().attempt())
                && observation.handle().equals(handle.get())
                && effectMatches(record.input().attempt(), observation.effect())
                && (responseFieldsMatch(record, observation)
                        || failureFieldsMatch(record, observation)
                        || deadlineFieldsMatch(record, observation));
    }
    private static boolean hostObservationRelation(NetworkState state, HostObservation observation) {
        if (observation instanceof HostObservation.Pending pending) {
            AttemptRecord record = find(state, pending.attempt());
            return record != null
                    && record.disposition() instanceof AttemptDisposition.Started started
                    && started.handle().equals(pending.handle());
        }
        return observationRelation(
                state, ((HostObservation.Delivered) observation).observation());
    }
    private static boolean annotationStatusOk(EffectStatus current, EffectStatus requested) {
        if (current instanceof EffectStatus.Unknown)
            return requested instanceof EffectStatus.NoEffect
                    || requested instanceof EffectStatus.EffectOccurred;
        if (current instanceof EffectStatus.NoEffect oldStatus
                && requested instanceof EffectStatus.NoEffect newStatus)
            return oldStatus.witness().equals(newStatus.witness());
        if (current instanceof EffectStatus.EffectOccurred oldStatus
                && requested instanceof EffectStatus.EffectOccurred newStatus)
            return oldStatus.witness().equals(newStatus.witness());
        return false;
    }
    private static boolean annotationConflict(EffectStatus current, EffectStatus requested) {
        return current instanceof EffectStatus.NoEffect
                        && requested instanceof EffectStatus.EffectOccurred
                || current instanceof EffectStatus.EffectOccurred
                        && requested instanceof EffectStatus.NoEffect;
    }
    private static boolean retryAcceptable(NetworkState state, RetryRequest request) {
        if (!(request.permission() instanceof RetryPermission.RetryAllowed allowed)) return false;
        RetryAuthorization authorization = allowed.authorization();
        AttemptInput input = new AttemptInput(authorization.next(), request.instruction(),
                request.deadline(), request.configuration());
        if (!validInput(input)
                || !authorization.logical().equals(authorization.from().logical())
                || !authorization.logical().equals(authorization.next().logical())
                || !authorization.next().ordinal().equals(authorization.from().ordinal().successor()))
            return false;
        AttemptRecord parent = find(state, authorization.from());
        if (parent == null || !(parent.disposition() instanceof AttemptDisposition.Settled))
            return false;
        if (state.latestOrdinals.get(authorization.from().logical()).compareTo(authorization.from().ordinal()) > 0
                || state.usedAuthorizations.containsKey(authorization))
            return false;
        return find(state, authorization.next()) == null;
    }
    private static Nat nextDelivery(AttemptRecord r) {
        if (r.firstDelivery().isEmpty()) return Nat.zero();
        if (r.late().isEmpty()) return r.firstDelivery().get().delivery().successor();
        return r.late().get(r.late().size() - 1).delivered().delivery().successor();
    }
    private static Optional<AdapterObservation> recorded(AttemptRecord r, Nat delivery) {
        if (r.firstDelivery().isPresent() && r.firstDelivery().get().delivery().equals(delivery)) return Optional.of(r.firstDelivery().get().observation());
        return r.late().stream().filter(l -> l.delivered().delivery().equals(delivery)).map(l -> l.delivered().observation()).findFirst();
    }
    private static NetworkTerminal terminalOf(AdapterObservation o) {
        return switch (o) {
            case AdapterObservation.ResponseObservation r -> new NetworkTerminal(new NetworkOutcome.Response(r.response(), r.provenance()), r.effect());
            case AdapterObservation.FailureObservation f -> new NetworkTerminal(new NetworkOutcome.Failed(f.failure()), f.effect());
            case AdapterObservation.CancellationObservation c -> new NetworkTerminal(new NetworkOutcome.Cancelled(), c.effect());
            case AdapterObservation.DeadlineObservation d -> new NetworkTerminal(new NetworkOutcome.DeadlineExceeded(d.deadline(), d.observed()), d.effect());
        };
    }
    private static boolean effectMatches(AttemptIdentity k, EffectStatus e) {
        return e instanceof EffectStatus.Unknown || (e instanceof EffectStatus.NoEffect n && n.witness().attempt().equals(k))
                || (e instanceof EffectStatus.EffectOccurred x && x.witness().attempt().equals(k));
    }
    private static boolean terminalEvidenceOk(
            AttemptIdentity attempt, NetworkTerminal terminal) {
        return effectMatches(attempt, terminal.effect())
                && (!(terminal.outcome() instanceof NetworkOutcome.Failed failed)
                        || failed.failure().attempt().equals(attempt));
    }
    private static boolean lateEvidenceOk(
            List<LateObservation> late, AttemptIdentity attempt,
            ExecutionHandle handle, Nat previous) {
        Nat prior = previous;
        for (LateObservation value : late) {
            DeliveredObservation delivered = value.delivered();
            if (prior.compareTo(delivered.delivery()) >= 0
                    || !delivered.observation().attempt().equals(attempt)
                    || !delivered.observation().handle().equals(handle))
                return false;
            prior = delivered.delivery();
        }
        return true;
    }
    private static boolean recordEvidenceOk(AttemptRecord record) {
        if (!(record.disposition() instanceof AttemptDisposition.Settled settled))
            return record.firstDelivery().isEmpty() && record.late().isEmpty();
        if (settled.handle().isEmpty())
            return record.firstDelivery().isEmpty()
                    && record.late().isEmpty()
                    && terminalEvidenceOk(record.input().attempt(), settled.terminal());
        if (!terminalEvidenceOk(record.input().attempt(), settled.terminal())
                || record.firstDelivery().isEmpty())
            return false;
        DeliveredObservation first = record.firstDelivery().get();
        ExecutionHandle handle = settled.handle().get();
        return first.delivery().isZero()
                && first.observation().attempt().equals(record.input().attempt())
                && first.observation().handle().equals(handle)
                && lateEvidenceOk(record.late(), record.input().attempt(),
                        handle, first.delivery());
    }
    private static boolean rootForLogical(
            List<AttemptRecord> records, RequestIdentity logical) {
        for (AttemptRecord record : records) {
            if (record.input().attempt().logical().equals(logical)
                    && record.input().attempt().ordinal().isZero()
                    && record.chain() instanceof AttemptChain.Root)
                return true;
        }
        return false;
    }
    private static boolean settledKey(
            List<AttemptRecord> records, AttemptIdentity attempt) {
        for (AttemptRecord record : records) {
            if (record.input().attempt().equals(attempt)
                    && record.disposition() instanceof AttemptDisposition.Settled)
                return true;
        }
        return false;
    }
    private static boolean chainOk(
            List<AttemptRecord> records, AttemptRecord record) {
        return chainOk(logical -> rootForLogical(records, logical), attempt -> settledKey(records, attempt), record);
    }
    private static boolean chainOk(java.util.function.Predicate<RequestIdentity> root,
            java.util.function.Predicate<AttemptIdentity> settled, AttemptRecord record) {
        if (!root.test(record.input().attempt().logical())) return false;
        if (record.chain() instanceof AttemptChain.Root)
            return record.input().attempt().ordinal().isZero();
        RetryAuthorization authorization =
                ((AttemptChain.RetryOf) record.chain()).authorization();
        return authorization.logical().equals(record.input().attempt().logical())
                && authorization.from().logical().equals(record.input().attempt().logical())
                && authorization.next().equals(record.input().attempt())
                && authorization.next().ordinal().equals(
                        authorization.from().ordinal().successor())
                && settled.test(authorization.from());
    }
    public static NetworkStateResult networkStateOf(List<AttemptRecord> records) {
        if (!validRecords(records)) return new NetworkStateResult.Rejected(recordsViolation(records));
        NetworkState state = NetworkState.empty();
        for (AttemptRecord record : records) state = state.appended(record);
        return new NetworkStateResult.Built(state);
    }
    private static boolean validRecords(List<AttemptRecord> records) {
        Set<RequestIdentity> roots = new HashSet<>();
        Set<AttemptIdentity> settled = new HashSet<>();
        for (AttemptRecord record : records) {
            if (record.input().attempt().ordinal().isZero() && record.chain() instanceof AttemptChain.Root)
                roots.add(record.input().attempt().logical());
            if (record.disposition() instanceof AttemptDisposition.Settled) settled.add(record.input().attempt());
        }
        Set<AttemptIdentity> keys = new HashSet<>();
        for (AttemptRecord record : records) {
            if (!keys.add(record.input().attempt())
                    || !recordEvidenceOk(record)
                    || !chainOk(roots::contains, settled::contains, record))
                return false;
        }
        Set<RetryAuthorization> authorizations = new HashSet<>();
        for (AttemptRecord record : records)
            if (record.chain() instanceof AttemptChain.RetryOf retry && !authorizations.add(retry.authorization()))
                return false;
        return true;
    }
    private static NetworkStateViolation recordsViolation(List<AttemptRecord> records) {
        for (int index = 0; index < records.size(); index++) {
            AttemptIdentity key = records.get(index).input().attempt();
            for (int later = index + 1; later < records.size(); later++) {
                if (records.get(later).input().attempt().equals(key))
                    return new NetworkStateViolation.DuplicateAttemptKey(key);
            }
        }
        for (AttemptRecord record : records) {
            if (recordEvidenceOk(record)) continue;
            if (!(record.disposition() instanceof AttemptDisposition.Settled settled))
                return new NetworkStateViolation.DeliveryLogMismatch(
                        record.input().attempt());
            if (settled.handle().isEmpty()) {
                if (record.firstDelivery().isEmpty() && record.late().isEmpty())
                    return new NetworkStateViolation.DispositionEvidenceMismatch(
                            record.input().attempt());
                return new NetworkStateViolation.DeliveryLogMismatch(
                        record.input().attempt());
            }
            if (terminalEvidenceOk(record.input().attempt(), settled.terminal()))
                return new NetworkStateViolation.DeliveryLogMismatch(
                        record.input().attempt());
            return new NetworkStateViolation.DispositionEvidenceMismatch(
                    record.input().attempt());
        }
        for (AttemptRecord record : records) {
            if (chainOk(records, record)) continue;
            if (!rootForLogical(records, record.input().attempt().logical())
                    || record.chain() instanceof AttemptChain.Root)
                return new NetworkStateViolation.NonRootFirstAttempt(
                        record.input().attempt());
            RetryAuthorization authorization =
                    ((AttemptChain.RetryOf) record.chain()).authorization();
            if (!authorization.next().ordinal().equals(
                    authorization.from().ordinal().successor()))
                return new NetworkStateViolation.OrdinalGap(
                        record.input().attempt());
            return new NetworkStateViolation.ChainMismatch(
                    record.input().attempt());
        }
        for (AttemptRecord record : records) {
            if (!rootForLogical(records, record.input().attempt().logical()))
                return new NetworkStateViolation.NonRootFirstAttempt(
                        record.input().attempt());
        }
        for (int index = 0; index < records.size(); index++) {
            if (!(records.get(index).chain()
                    instanceof AttemptChain.RetryOf retry))
                continue;
            for (int later = index + 1; later < records.size(); later++) {
                if (records.get(later).chain()
                        instanceof AttemptChain.RetryOf candidate
                        && candidate.authorization().equals(retry.authorization()))
                    return new NetworkStateViolation.RetryAuthorizationReuse(
                            retry.authorization());
            }
        }
        AttemptIdentity empty =
                new AttemptIdentity(new RequestIdentity("", "", Nat.zero()), Nat.zero());
        return new NetworkStateViolation.DuplicateAttemptKey(empty);
    }
    private static boolean validInput(AttemptInput input) {
        if (input == null || input.instruction() == null || input.configuration() == null) return false;
        HttpWireInstruction i = input.instruction();
        if (!token(i.method()) || !absoluteTarget(i.target())) return false;
        if (!headers(i.headers())
                || Nat.fromLong(i.body().size()).compareTo(
                        input.configuration().requestBodyLimit()) > 0)
            return false;
        if (input.deadline().isEmpty()) return true;
        Deadline d = input.deadline().get();
        return d.clockBasis().equals(d.capability().clockBasis()) && input.configuration().monotonicClock().filter(d.capability()::equals).isPresent();
    }
    private static boolean headers(List<RawHeaderField> hs) { return hs.stream().allMatch(h -> token(h.name())); }
    private static boolean token(String value) {
        if (value == null || value.isEmpty()) return false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (!(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
                    || "!#$%&'*+-.^_`|~".indexOf(c) >= 0)) return false;
        }
        return true;
    }
    private static boolean absoluteTarget(String value) {
        try { URI uri = URI.create(value); return uri.isAbsolute() && uri.getScheme() != null && !uri.getScheme().isEmpty(); }
        catch (IllegalArgumentException e) { return false; }
    }

    public enum HostRecordObservation { UNDELIVERED, DELIVERY_ORDINAL }

    public static boolean hostAwaits(NetworkState state, AttemptIdentity key) {
        AttemptRecord record = find(state, key);
        return record != null && !(record.disposition() instanceof AttemptDisposition.Settled);
    }

    public static boolean hostSettled(NetworkState state, AttemptIdentity key) {
        AttemptRecord record = find(state, key);
        return record != null && record.disposition() instanceof AttemptDisposition.Settled;
    }

    public static ErasureDecision<AttemptIdentity, Void, Void, Void, HostRecordObservation> releaseHostRecord(
            NetworkState state, Predicate<AttemptIdentity> running, AttemptIdentity key) {
        ErasureRequest<AttemptIdentity, Void, HostRecordObservation> request = new ErasureRequest<>(
                key,
                Optional.empty(),
                List.of(HostRecordObservation.UNDELIVERED, HostRecordObservation.DELIVERY_ORDINAL),
                List.of());
        LiveMembership<AttemptIdentity, Void> membership = new LiveMembership<>(
                basis -> false,
                target -> false,
                target -> hostAwaits(state, target),
                running::test,
                target -> false);
        return Retention.judgeErasureBy(request, membership, Optional.of(new Recoverability.Irrecoverable<>()));
    }
}
