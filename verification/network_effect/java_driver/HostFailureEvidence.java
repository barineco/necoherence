// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;


import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import neco.quotient.Result;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;
import necoherence.semantic.SemanticValues;

public final class HostFailureEvidence {
    public static void main(String[] args) throws Exception {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = in.readLine()) != null) {
            if (line.isBlank()) continue;
            Map<String, String> row = parseFlatObject(line);
            String report;
            try {
                report = runRow(row);
            } catch (Throwable error) {
                report = "{\"error\":" + quote(String.valueOf(error)) + "}";
            }
            System.out.println(report);
            System.out.flush();
        }
    }

    private static String runRow(Map<String, String> row) throws Exception {
        String constructor = row.get("constructor");
        boolean testOnly = "true".equals(row.get("testOnly"));
        String peerHost = row.get("peerHost");
        int peerPort = Integer.parseInt(row.get("peerPort"));
        String timeoutStage = row.get("timeoutStage");
        String timeoutCause = row.get("timeoutCause");

        boolean rejectCancellation = "CancellationRejected".equals(constructor);
        boolean clockFailure = "true".equals(row.get("clockFailure"));
        boolean deadlineReached = "true".equals(row.get("deadlineReached"));
        NetworkEffect.AttemptInput input = "Scenario".equals(constructor)
                ? scenarioInput(row, peerHost, peerPort)
                : buildInput(constructor, peerHost, peerPort, clockFailure || deadlineReached);

        boolean forged = "Scenario".equals(constructor) && Integer.parseInt(row.get("bodyLength")) > 256;
        NetworkEffect.AttemptInput ledgerInput = forged
                ? new NetworkEffect.AttemptInput(input.attempt(), new NetworkEffect.HttpWireInstruction(
                        input.instruction().method(), input.instruction().target(), input.instruction().headers(),
                        necoherence.network.ByteString.empty()), input.deadline(), input.configuration())
                : input;
        NetworkEffect.PrepareStep prepareStep = NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), ledgerInput);
        if (!(prepareStep instanceof NetworkEffect.PrepareStep.Prepared prepared)) {
            return "{\"error\":" + quote("prepare rejected: " + prepareStep) + "}";
        }
        int ledgerRecordCount = prepared.state().attempts().size();
        NetworkEffect.CommandStep<NetworkEffect.SendCommand> sendStep = NetworkEffect.sendCommand(prepared.state(), prepared.prepared());
        if (!(sendStep instanceof NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand> ready)) {
            return "{\"error\":" + quote("sendCommand rejected: " + sendStep) + "}";
        }
        int issuedCommandCount = 1;

        if (testOnly) {
            return runTestOnly(constructor, timeoutStage, timeoutCause, input, ready.state(), prepared.prepared(), ledgerRecordCount, issuedCommandCount);
        }
        NetworkEffect.SendCommand command = forged
                ? new NetworkEffect.SendCommand(withInput(prepared.prepared(), input))
                : ready.command();
        return runReal(constructor, rejectCancellation, "true".equals(row.get("foreignCommand")), clockFailure, deadlineReached, input, ready.state(), prepared.prepared(), command, ledgerRecordCount, issuedCommandCount);
    }

    private static NetworkEffect.PreparedAttempt withInput(NetworkEffect.PreparedAttempt original, NetworkEffect.AttemptInput input) throws Exception {
        Object second = NetworkEffect.PreparedAttempt.class.getRecordComponents()[1].getAccessor().invoke(original);
        var constructor = NetworkEffect.PreparedAttempt.class.getDeclaredConstructors()[0];
        constructor.setAccessible(true);
        return (NetworkEffect.PreparedAttempt) constructor.newInstance(input, second);
    }

    private static NetworkEffect.AttemptInput scenarioInput(Map<String, String> row, String peerHost, int peerPort) {
        String target = row.get("scheme") + "://" + peerHost + ":" + peerPort + "/host-failure-matrix";
        NetworkEffect.MonotonicClockCapability clock = switch (row.get("deadline")) {
            case "adapter" -> new NetworkEffect.MonotonicClockCapability(
                    new NetworkEffect.OpaqueEvidence("matrix-clock"), new NetworkEffect.ClockBasis("matrix"));
            case "foreign" -> new NetworkEffect.MonotonicClockCapability(
                    new NetworkEffect.OpaqueEvidence("foreign-clock"), new NetworkEffect.ClockBasis("foreign-basis"));
            default -> null;
        };
        Optional<NetworkEffect.CancellationCapability> cancellation = switch (row.get("cancellation")) {
            case "adapter" -> Optional.of(new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("matrix-cancel")));
            case "foreign" -> Optional.of(new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("foreign-cancel")));
            default -> Optional.empty();
        };
        Optional<NetworkEffect.Deadline> deadline = clock == null
                ? Optional.empty()
                : Optional.of(new NetworkEffect.Deadline(clock.clockBasis(), Nat.fromLong(1_000_000_000_000_000_000L), clock));
        NetworkEffect.HostConfiguration configuration = new NetworkEffect.HostConfiguration(
                Nat.fromLong(256), Nat.fromLong(64), cancellation, Optional.ofNullable(clock));
        NetworkEffect.AttemptIdentity attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("Scenario", "host-failure-matrix", Nat.zero()), Nat.zero());
        necoherence.network.ByteString body = necoherence.network.ByteString.copyOf(
                new byte[Integer.parseInt(row.get("bodyLength"))]);
        return new NetworkEffect.AttemptInput(attempt, new NetworkEffect.HttpWireInstruction(
                "POST", target, java.util.List.of(), body), deadline, configuration);
    }

    private static NetworkEffect.AttemptInput buildInput(String constructor, String peerHost, int peerPort, boolean clockFailure) {
        String scheme = "UnsupportedUriScheme".equals(constructor) ? "ftp" : "http";
        String target = scheme + "://" + peerHost + ":" + peerPort + "/host-failure-matrix";
        Nat requestBodyLimit = Nat.fromLong(256);
        Nat responseBodyLimit = "ResponseBodyLimitExceeded".equals(constructor) ? Nat.fromLong(4) : Nat.fromLong(16);
        java.util.List<NetworkEffect.RawHeaderField> headers = java.util.List.of();
        necoherence.network.ByteString body = necoherence.network.ByteString.empty();
        if ("RequestHeaderEncodingUnavailable".equals(constructor)) {
            headers = java.util.List.of(new NetworkEffect.RawHeaderField("x-forged", necoherence.network.ByteString.ofUnsigned(0)));
        }
        Optional<NetworkEffect.CancellationCapability> cancellation = Optional.empty();
        if ("CancellationRejected".equals(constructor)) {
            cancellation = Optional.of(new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("matrix-cancel")));
        }
        Optional<NetworkEffect.Deadline> deadline = Optional.empty();
        Optional<NetworkEffect.MonotonicClockCapability> monotonicClock = Optional.empty();
        if (clockFailure) {
            NetworkEffect.ClockBasis basis = new NetworkEffect.ClockBasis("java-matrix");
            NetworkEffect.MonotonicClockCapability capability = new NetworkEffect.MonotonicClockCapability(
                    new NetworkEffect.OpaqueEvidence("host-failure-matrix-clock"), basis);
            deadline = Optional.of(new NetworkEffect.Deadline(basis, Nat.fromLong(Long.MAX_VALUE), capability));
            monotonicClock = Optional.of(capability);
        }
        if ("ResponseHeadersFailed".equals(constructor)) {
            // The JDK silently retries this idempotent GET on a fresh
            // connection once the peer closes without sending headers; that
            // retry's stalled read only surfaces (as a typed Timeout,
            // instead of hanging forever) when the attempt carries a
            // deadline that JavaHttpAdapter can turn into a request timeout.
            NetworkEffect.ClockBasis basis = new NetworkEffect.ClockBasis("java-matrix");
            NetworkEffect.MonotonicClockCapability capability = new NetworkEffect.MonotonicClockCapability(
                    new NetworkEffect.OpaqueEvidence("host-failure-matrix-clock"), basis);
            Nat limit = Nat.fromLong(java.lang.System.nanoTime() + java.time.Duration.ofSeconds(1).toNanos());
            deadline = Optional.of(new NetworkEffect.Deadline(basis, limit, capability));
            monotonicClock = Optional.of(capability);
        }
        NetworkEffect.HostConfiguration configuration = new NetworkEffect.HostConfiguration(
                requestBodyLimit, responseBodyLimit, cancellation, monotonicClock);
        NetworkEffect.AttemptIdentity attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity(constructor, "host-failure-matrix", Nat.zero()), Nat.zero());
        return new NetworkEffect.AttemptInput(attempt, new NetworkEffect.HttpWireInstruction(
                "GET", target, headers, body), deadline, configuration);
    }

    private static NetworkEffect.HostFailure directCause(String constructor, String timeoutStage, String timeoutCause) {
        return switch (constructor) {
            case "ExecutionStartFailed" -> new NetworkEffect.HostFailure.ExecutionStartFailed();
            case "NameResolutionFailed" -> new NetworkEffect.HostFailure.NameResolutionFailed();
            case "RequestWriteFailed" -> new NetworkEffect.HostFailure.RequestWriteFailed();
            case "HeaderRepresentationUnavailable" -> new NetworkEffect.HostFailure.HeaderRepresentationUnavailable();
            case "HostRuntimeFailure" -> new NetworkEffect.HostFailure.HostRuntimeFailure();
            case "InvalidHostConfiguration" -> new NetworkEffect.HostFailure.InvalidHostConfiguration();
            case "DeadlineControlUnavailable" -> new NetworkEffect.HostFailure.DeadlineControlUnavailable();
            case "Timeout" -> new NetworkEffect.HostFailure.Timeout(stageOf(timeoutStage), causeOf(timeoutCause));
            default -> throw new IllegalArgumentException("unknown test-only constructor: " + constructor);
        };
    }

    private static NetworkEffect.HostStage directStage(String constructor, String timeoutStage) {
        return switch (constructor) {
            case "ExecutionStartFailed" -> NetworkEffect.HostStage.Start;
            case "NameResolutionFailed" -> NetworkEffect.HostStage.Start;
            case "RequestWriteFailed" -> NetworkEffect.HostStage.RequestWrite;
            case "HeaderRepresentationUnavailable" -> NetworkEffect.HostStage.ResponseHeaders;
            case "HostRuntimeFailure" -> NetworkEffect.HostStage.ResponseBody;
            case "InvalidHostConfiguration" -> NetworkEffect.HostStage.Start;
            case "DeadlineControlUnavailable" -> NetworkEffect.HostStage.Start;
            case "Timeout" -> stageOf(timeoutStage);
            default -> throw new IllegalArgumentException("unknown test-only constructor: " + constructor);
        };
    }

    private static String runTestOnly(String constructor, String timeoutStage, String timeoutCause,
            NetworkEffect.AttemptInput input, NetworkEffect.NetworkState state, NetworkEffect.PreparedAttempt prepared,
            int ledgerRecordCount, int issuedCommandCount) {
        NetworkEffect.HostStage stage = directStage(constructor, timeoutStage);
        NetworkEffect.HostFailure cause = directCause(constructor, timeoutStage, timeoutCause);
        NetworkEffect.EffectStatus unknown = new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.HostFailure);
        if ("ExecutionStartFailed".equals(constructor)) {
            NetworkEffect.NetworkHostFailure failure = new NetworkEffect.NetworkHostFailure(input.attempt(), stage, input.configuration(), cause);
            NetworkEffect.StartObservation observation = new NetworkEffect.StartObservation.StartFailed(failure, unknown);
            NetworkEffect.NetworkStep step = NetworkEffect.observeStart(state, prepared, observation);
            return reportFromStep("test-only-handle", ledgerRecordCount, issuedCommandCount, step);
        }
        ExecutionHandle handle = new ExecutionHandle("java-test-only-handle");
        NetworkEffect.NetworkStep startedStep = NetworkEffect.observeStart(
                state, prepared, new NetworkEffect.StartObservation.Started(input.attempt(), handle));
        if (!(startedStep instanceof NetworkEffect.NetworkStep.Started started)) {
            return "{\"error\":" + quote("unexpected observeStart result: " + startedStep) + "}";
        }
        NetworkEffect.NetworkHostFailure failure = new NetworkEffect.NetworkHostFailure(input.attempt(), stage, input.configuration(), cause);
        NetworkEffect.AdapterObservation observation = new NetworkEffect.AdapterObservation.FailureObservation(
                input.attempt(), handle, new NetworkEffect.SourceSequence.None(), failure, unknown);
        NetworkEffect.HostObservation delivered = new NetworkEffect.HostObservation.Delivered(Nat.zero(), observation);
        NetworkEffect.NetworkStep step = NetworkEffect.observe(started.state(), delivered);
        return reportFromStep(handle.value(), ledgerRecordCount, issuedCommandCount, step);
    }

    private static String runReal(String constructor, boolean rejectCancellation, boolean foreignCommand, boolean clockFailure, boolean deadlineReached, NetworkEffect.AttemptInput input,
            NetworkEffect.NetworkState state, NetworkEffect.PreparedAttempt prepared, NetworkEffect.SendCommand command,
            int ledgerRecordCount, int issuedCommandCount) throws InterruptedException {
        boolean scenario = "Scenario".equals(constructor);
        NetworkEffect.MonotonicClockCapability clockCapability = scenario
                ? new NetworkEffect.MonotonicClockCapability(
                        new NetworkEffect.OpaqueEvidence("matrix-clock"), new NetworkEffect.ClockBasis("matrix"))
                : new NetworkEffect.MonotonicClockCapability(
                        new NetworkEffect.OpaqueEvidence("host-failure-matrix-clock"), new NetworkEffect.ClockBasis("java-matrix"));
        java.util.concurrent.atomic.AtomicBoolean clockArmed = new java.util.concurrent.atomic.AtomicBoolean();
        JavaHttpAdapter.MonotonicClockPort clockPort = new JavaHttpAdapter.MonotonicClockPort() {
            @Override public NetworkEffect.MonotonicClockCapability capability() { return clockCapability; }
            @Override public Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe() {
                if (clockArmed.get()) throw new IllegalStateException("matrix clock failure");
                if (deadlineReached)
                    return new Result.Accepted<>(new NetworkEffect.MonotonicClockObservation(
                            clockCapability.clockBasis(), Nat.fromLong(Long.MAX_VALUE)));
                return new Result.Accepted<>(new NetworkEffect.MonotonicClockObservation(
                        clockCapability.clockBasis(), Nat.fromLong(java.lang.System.nanoTime())));
            }
        };
        NetworkEffect.CancellationCapability cancellationCapability = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("matrix-cancel"));
        boolean acceptCancellation = !rejectCancellation || foreignCommand;
        JavaHttpAdapter.CancellationPort cancellationPort = new JavaHttpAdapter.CancellationPort() {
            @Override public NetworkEffect.CancellationCapability capability() { return cancellationCapability; }
            @Override public Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle) {
                return acceptCancellation
                        ? new Result.Accepted<>(SemanticValues.Unit.VALUE)
                        : new Result.Rejected<>(new NetworkEffect.HostFailure.CancellationRejected());
            }
        };
        JavaHttpAdapter adapter = new JavaHttpAdapter(
                java.net.http.HttpClient.newBuilder().followRedirects(java.net.http.HttpClient.Redirect.NEVER).build(),
                clockPort, cancellationPort);
        JavaHttpAdapter.StartResult startResult = adapter.start(command);
        if (startResult.started().isEmpty()) {
            NetworkEffect.NetworkStep step = NetworkEffect.observeStart(state, prepared, startResult.observation());
            return reportFromStep("start-failed", ledgerRecordCount, issuedCommandCount, step);
        }
        NetworkEffect.StartedAttempt started = startResult.started().get();
        if (rejectCancellation) {
            Thread.sleep(50);
            NetworkEffect.CancelCommand cancelCommand = new NetworkEffect.CancelCommand(
                    input.attempt(), started.handle(), foreignCommand
                            ? new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("foreign-cancel"))
                            : input.configuration().cancellation().orElseThrow());
            JavaHttpAdapter.PollResult poll = adapter.cancel(cancelCommand);
            return finishFromPoll(state, prepared, input, poll, ledgerRecordCount, issuedCommandCount);
        }
        if (clockFailure || deadlineReached) {
            Thread.sleep(deadlineReached ? 300 : 50);
            clockArmed.set(clockFailure);
            JavaHttpAdapter.PollResult poll = adapter.observe(started);
            if (!(poll instanceof JavaHttpAdapter.PollResult.Delivered)) {
                return "{\"error\":\"clock failure was not delivered\"}";
            }
            return finishFromPoll(state, prepared, input, poll, ledgerRecordCount, issuedCommandCount);
        }
        if ("HostClosed".equals(constructor)) {
            Thread.sleep(50);
            adapter.close();
            JavaHttpAdapter.PollResult poll = adapter.observe(started);
            return finishFromPoll(state, prepared, input, poll, ledgerRecordCount, issuedCommandCount);
        }
        long deadline = java.lang.System.nanoTime() + 3_000_000_000L;
        while (true) {
            JavaHttpAdapter.PollResult poll = adapter.observe(started);
            if (poll instanceof JavaHttpAdapter.PollResult.Delivered) {
                return finishFromPoll(state, prepared, input, poll, ledgerRecordCount, issuedCommandCount);
            }
            if (java.lang.System.nanoTime() >= deadline) {
                return "{\"error\":\"polling timed out\"}";
            }
            Thread.sleep(10);
        }
    }

    private static String finishFromPoll(NetworkEffect.NetworkState state, NetworkEffect.PreparedAttempt prepared,
            NetworkEffect.AttemptInput input, JavaHttpAdapter.PollResult poll, int ledgerRecordCount, int issuedCommandCount) {
        NetworkEffect.HostObservation observation = switch (poll) {
            case JavaHttpAdapter.PollResult.Delivered delivered -> delivered.observation();
            case JavaHttpAdapter.PollResult.Pending pending -> pending.observation();
            case JavaHttpAdapter.PollResult.Closed closed -> closed.observation();
        };
        ExecutionHandle handle = observation instanceof NetworkEffect.HostObservation.Delivered delivered
                ? handleOf(delivered.observation())
                : ((NetworkEffect.HostObservation.Pending) observation).handle();
        NetworkEffect.NetworkStep startedStep = NetworkEffect.observeStart(
                state, prepared, new NetworkEffect.StartObservation.Started(input.attempt(), handle));
        if (!(startedStep instanceof NetworkEffect.NetworkStep.Started started)) {
            return "{\"error\":" + quote("unexpected observeStart result: " + startedStep) + "}";
        }
        NetworkEffect.NetworkStep step = NetworkEffect.observe(started.state(), observation);
        return reportFromStep(handle.value(), ledgerRecordCount, issuedCommandCount, step);
    }

    private static ExecutionHandle handleOf(NetworkEffect.AdapterObservation observation) {
        return switch (observation) {
            case NetworkEffect.AdapterObservation.ResponseObservation value -> value.handle();
            case NetworkEffect.AdapterObservation.FailureObservation value -> value.handle();
            case NetworkEffect.AdapterObservation.CancellationObservation value -> value.handle();
            case NetworkEffect.AdapterObservation.DeadlineObservation value -> value.handle();
        };
    }

    private static String reportFromStep(String handle, int ledgerRecordCount, int issuedCommandCount, NetworkEffect.NetworkStep step) {
        if (step instanceof NetworkEffect.NetworkStep.Terminal terminal) {
            return reportFromTerminal(handle, ledgerRecordCount, issuedCommandCount, terminal.settled().terminal());
        }
        if (step instanceof NetworkEffect.NetworkStep.Started || step instanceof NetworkEffect.NetworkStep.Pending) {
            return object(java.util.Map.of(
                    "ledgerRecordCount", String.valueOf(ledgerRecordCount),
                    "issuedCommandCount", String.valueOf(issuedCommandCount),
                    "outcomeTag", quote("Pending"),
                    "effect", quote("Unknown"),
                    "handle", quote(handle)));
        }
        if (step instanceof NetworkEffect.NetworkStep.Rejected rejected) {
            return object(java.util.Map.of(
                    "ledgerRecordCount", String.valueOf(ledgerRecordCount),
                    "issuedCommandCount", String.valueOf(issuedCommandCount),
                    "outcomeTag", quote("LedgerRejected"),
                    "cause", quote(String.valueOf(rejected.failure())),
                    "handle", quote(handle)));
        }
        return "{\"error\":" + quote("unexpected NetworkStep: " + step) + "}";
    }

    private static String reportFromTerminal(String handle, int ledgerRecordCount, int issuedCommandCount, NetworkEffect.NetworkTerminal terminal) {
        String effectTag = switch (terminal.effect()) {
            case NetworkEffect.EffectStatus.NoEffect ignored -> "NoEffect";
            case NetworkEffect.EffectStatus.EffectOccurred ignored -> "EffectOccurred";
            case NetworkEffect.EffectStatus.Unknown ignored -> "Unknown";
        };
        Map<String, String> fields = new HashMap<>();
        fields.put("ledgerRecordCount", String.valueOf(ledgerRecordCount));
        fields.put("issuedCommandCount", String.valueOf(issuedCommandCount));
        fields.put("effect", quote(effectTag));
        fields.put("effectReason", terminal.effect() instanceof NetworkEffect.EffectStatus.Unknown unknown
                ? quote(unknown.reason().toString()) : "null");
        fields.put("handle", quote(handle));
        if (terminal.outcome() instanceof NetworkEffect.NetworkOutcome.Failed failed) {
            NetworkEffect.NetworkHostFailure failure = failed.failure();
            fields.put("outcomeTag", quote("Failed"));
            fields.put("stage", quote(failure.stage().toString()));
            fields.put("cause", quote(causeTag(failure.cause())));
            if (failure.cause() instanceof NetworkEffect.HostFailure.Timeout timeout) {
                fields.put("innerStage", quote(timeout.stage().toString()));
                fields.put("innerCause", quote(timeout.cause().toString()));
            } else {
                fields.put("innerStage", "null");
                fields.put("innerCause", "null");
            }
        } else if (terminal.outcome() instanceof NetworkEffect.NetworkOutcome.Cancelled) {
            fields.put("outcomeTag", quote("Cancelled"));
            fields.put("stage", quote("Cancel"));
            fields.put("cause", quote("Cancelled"));
        } else {
            fields.put("outcomeTag", quote(terminal.outcome().getClass().getSimpleName()));
        }
        return object(fields);
    }

    private static String causeTag(NetworkEffect.HostFailure cause) {
        return cause.getClass().getSimpleName();
    }

    private static NetworkEffect.HostStage stageOf(String name) {
        return NetworkEffect.HostStage.valueOf(name);
    }

    private static NetworkEffect.HostTimeoutCause causeOf(String name) {
        return NetworkEffect.HostTimeoutCause.valueOf(name);
    }

    private static String object(Map<String, String> fields) {
        StringBuilder builder = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, String> entry : fields.entrySet()) {
            if (!first) builder.append(',');
            first = false;
            builder.append(quote(entry.getKey())).append(':').append(entry.getValue());
        }
        return builder.append('}').toString();
    }

    private static String quote(String value) {
        StringBuilder builder = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '"' || c == '\\') builder.append('\\').append(c);
            else if (c == '\n') builder.append("\\n");
            else if (c < 0x20) builder.append(' ');
            else builder.append(c);
        }
        return builder.append('"').toString();
    }

    private static Map<String, String> parseFlatObject(String line) {
        Map<String, String> result = new HashMap<>();
        String body = line.strip();
        body = body.substring(1, body.length() - 1);
        int index = 0;
        while (index < body.length()) {
            while (index < body.length() && (body.charAt(index) == ',' || body.charAt(index) == ' ')) index++;
            if (index >= body.length()) break;
            int[] keyEnd = new int[1];
            String key = readString(body, index, keyEnd);
            index = keyEnd[0];
            while (body.charAt(index) == ':' || body.charAt(index) == ' ') index++;
            if (body.charAt(index) == '"') {
                int[] valueEnd = new int[1];
                String value = readString(body, index, valueEnd);
                result.put(key, value);
                index = valueEnd[0];
            } else if (body.startsWith("null", index)) {
                result.put(key, null);
                index += 4;
            } else {
                int start = index;
                while (index < body.length() && body.charAt(index) != ',') index++;
                result.put(key, body.substring(start, index).strip());
            }
        }
        return result;
    }

    private static String readString(String body, int start, int[] endOut) {
        int index = start + 1;
        StringBuilder builder = new StringBuilder();
        while (body.charAt(index) != '"') {
            if (body.charAt(index) == '\\') {
                index++;
                builder.append(body.charAt(index));
            } else {
                builder.append(body.charAt(index));
            }
            index++;
        }
        endOut[0] = index + 1;
        return builder.toString();
    }
}
