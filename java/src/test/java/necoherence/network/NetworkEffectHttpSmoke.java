// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.http.HttpClient;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;

public final class NetworkEffectHttpSmoke {
    private static final AtomicLong IDENTITY = new AtomicLong();

    private record Issued(
            NetworkEffect.NetworkState state,
            NetworkEffect.PreparedAttempt prepared,
            NetworkEffect.SendCommand command) {}

    private static final class Peer implements AutoCloseable {
        private final ServerSocket server;
        private final Thread thread;
        private final byte[] response;
        private final CountDownLatch release;
        private final CountDownLatch requestComplete = new CountDownLatch(1);
        private final AtomicReference<Throwable> failure = new AtomicReference<>();
        private final AtomicInteger received = new AtomicInteger();
        private volatile boolean closing;
        private volatile byte[] requestBody = new byte[0];
        private volatile String requestHead = "";

        Peer(byte[] response, boolean delayed) throws Exception {
            this.response = response;
            this.release = new CountDownLatch(delayed ? 1 : 0);
            this.server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
            this.thread = new Thread(this::serve, "java-loopback-peer");
            this.thread.setDaemon(true);
            this.thread.start();
        }

        String target(String path) {
            return "http://127.0.0.1:" + server.getLocalPort() + path;
        }

        int receivedCount() { return received.get(); }
        byte[] requestBody() { return requestBody.clone(); }
        String requestHead() { return requestHead; }
        void release() { release.countDown(); }

        void awaitRequest() throws Exception {
            check(requestComplete.await(5, TimeUnit.SECONDS), "peer request completion");
            check(received.get() == 1, "peer received request");
        }

        private void serve() {
            try (Socket socket = server.accept()) {
                socket.setSoTimeout(5_000);
                InputStream input = socket.getInputStream();
                ByteArrayOutputStream headerBytes = new ByteArrayOutputStream();
                int matched = 0;
                while (matched < 4) {
                    int next = input.read();
                    if (next < 0) return;
                    headerBytes.write(next);
                    matched = switch (matched) {
                        case 0 -> next == '\r' ? 1 : 0;
                        case 1 -> next == '\n' ? 2 : next == '\r' ? 1 : 0;
                        case 2 -> next == '\r' ? 3 : 0;
                        default -> next == '\n' ? 4 : 0;
                    };
                }
                received.incrementAndGet();
                requestHead = headerBytes.toString(StandardCharsets.ISO_8859_1);
                int contentLength = 0;
                for (String line : requestHead.split("\\r\\n")) {
                    if (line.toLowerCase(java.util.Locale.ROOT).startsWith("content-length:"))
                        contentLength = Integer.parseInt(line.substring(line.indexOf(':') + 1).trim());
                }
                requestBody = input.readNBytes(contentLength);
                requestComplete.countDown();
                if (!release.await(5, TimeUnit.SECONDS))
                    throw new AssertionError("peer release timeout");
                if (response != null) {
                    OutputStream output = socket.getOutputStream();
                    output.write(response);
                    output.flush();
                }
            } catch (Throwable error) {
                if (!(closing && error instanceof SocketException)) failure.set(error);
            }
        }

        @Override public void close() throws Exception {
            closing = true;
            release.countDown();
            server.close();
            thread.join(5_000);
            check(!thread.isAlive(), "peer thread stopped");
            Throwable error = failure.get();
            if (error != null) throw new AssertionError(error);
        }
    }

    private static Nat n(long value) { return Nat.fromLong(value); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static byte[] response(int status, List<String> headers, byte[] body) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        StringBuilder head = new StringBuilder("HTTP/1.1 ").append(status).append(" Result\r\n");
        for (String header : headers) head.append(header).append("\r\n");
        head.append("Content-Length: ").append(body.length).append("\r\n\r\n");
        bytes.writeBytes(head.toString().getBytes(StandardCharsets.ISO_8859_1));
        bytes.writeBytes(body);
        return bytes.toByteArray();
    }

    private static NetworkEffect.HostConfiguration configuration(long requestLimit, long responseLimit) {
        return new NetworkEffect.HostConfiguration(
                n(requestLimit), n(responseLimit), Optional.empty(), Optional.empty());
    }

    private static Issued issue(
            String target,
            List<NetworkEffect.RawHeaderField> headers,
            List<Integer> body,
            NetworkEffect.HostConfiguration configuration,
            Optional<NetworkEffect.Deadline> deadline) {
        long identity = IDENTITY.getAndIncrement();
        var attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("http", "causal-" + identity, n(identity)), n(0));
        var input = new NetworkEffect.AttemptInput(
                attempt,
                new NetworkEffect.HttpWireInstruction("POST", target, headers, body),
                deadline,
                configuration);
        var preparedResult = NetworkEffect.prepare(new NetworkEffect.NetworkState(List.of()), input);
        check(preparedResult instanceof NetworkEffect.PrepareStep.Prepared, "prepare host instruction");
        var prepared = ((NetworkEffect.PrepareStep.Prepared) preparedResult).prepared();
        var commandResult = NetworkEffect.sendCommand(
                ((NetworkEffect.PrepareStep.Prepared) preparedResult).state(), prepared);
        check(commandResult instanceof NetworkEffect.CommandStep.CommandReady<?>, "issue send command");
        @SuppressWarnings("unchecked")
        var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) commandResult;
        return new Issued(ready.state(), prepared, ready.command());
    }

    private static NetworkEffect.HostObservation.Delivered awaitDelivered(
            JavaHttpAdapter adapter, NetworkEffect.StartedAttempt started) throws Exception {
        for (int index = 0; index < 5_000; index++) {
            JavaHttpAdapter.PollResult poll = adapter.observe(started);
            if (poll instanceof JavaHttpAdapter.PollResult.Delivered delivered
                    && delivered.observation() instanceof NetworkEffect.HostObservation.Delivered value)
                return value;
            Thread.sleep(1);
        }
        throw new AssertionError("adapter delivery timeout");
    }

    private static NetworkEffect.NetworkStep.Started applyStart(
            Issued issued, JavaHttpAdapter.StartResult start) {
        var step = NetworkEffect.observeStart(issued.state(), issued.prepared(), start.observation());
        check(step instanceof NetworkEffect.NetworkStep.Started, "ledger accepts adapter start");
        return (NetworkEffect.NetworkStep.Started) step;
    }

    private static void loopbackSuccessPreservesBytesHeadersAndCounts() throws Exception {
        byte[] response = response(201,
                List.of("X-Dupe: z", "X-Dupe: a", "X-Accent: é"),
                new byte[] {(byte) 0x80, (byte) 0xff});
        try (Peer peer = new Peer(response, true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            String causal = "causal-" + IDENTITY.get();
            var issued = issue(peer.target("/echo"),
                    List.of(
                            new NetworkEffect.RawHeaderField("X-Visible", List.of(0x20, 0x7e)),
                            new NetworkEffect.RawHeaderField("X-Causal", causal.chars().boxed().toList())),
                    List.of(0x80, 0xff), configuration(128, 128), Optional.empty());
            int ledgerRecordCount = issued.state().attempts().size();
            int issuedCommandCount = 1;
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            check(start.started().isPresent(), "start returns stable handle");
            var startedStep = applyStart(issued, start);
            var started = start.started().get();
            JavaHttpAdapter.PollResult firstPoll = adapter.observe(started);
            check(firstPoll instanceof JavaHttpAdapter.PollResult.Pending, "delayed peer is pending");
            JavaHttpAdapter.PollResult secondPoll = adapter.observe(started);
            check(secondPoll instanceof JavaHttpAdapter.PollResult.Pending, "pending poll is stable");
            peer.awaitRequest();
            check(peer.requestHead().startsWith("POST /echo HTTP/1.1"), "method and path observed");
            check(peer.requestHead().contains(causal), "causal identity observed by peer");
            check(List.of(0x80, 0xff).equals(
                    java.util.Arrays.stream(toUnsigned(peer.requestBody())).boxed().toList()),
                    "unsigned request body");
            peer.release();
            var delivered = awaitDelivered(adapter, started);
            check(delivered.delivery().isZero(), "pending did not consume delivery ordinal");
            check(delivered.observation().attempt().equals(issued.prepared().input().attempt()),
                    "response keeps causal attempt identity");
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation,
                    "loopback response observation");
            var observed = (NetworkEffect.AdapterObservation.ResponseObservation) delivered.observation();
            check(observed.response().status() == 201, "raw success status");
            check(observed.response().body().equals(List.of(0x80, 0xff)), "unsigned response body");
            check(observed.provenance() == NetworkEffect.HeaderProvenance.LibraryNormalized,
                    "normalized header provenance");
            check(observed.response().headers().stream().filter(h -> h.name().equals("x-dupe")).count() == 2,
                    "duplicate response fields preserved");
            check(observed.response().headers().stream().anyMatch(h -> h.name().equals("x-accent")
                            && h.value().equals(List.of(0xc3, 0xa9))),
                    "response header UTF-8 normalization");
            var terminal = NetworkEffect.observe(startedStep.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "typed terminal persisted");
            int peerReceivedCount = peer.receivedCount();
            check(ledgerRecordCount == 1 && issuedCommandCount == 1 && peerReceivedCount == 1,
                    "ledger, dispatch, and peer counts");
            check(peerReceivedCount <= issuedCommandCount, "peer count bounded by dispatch count");
        }
    }

    private static int[] toUnsigned(byte[] values) {
        int[] result = new int[values.length];
        for (int index = 0; index < values.length; index++)
            result[index] = Byte.toUnsignedInt(values[index]);
        return result;
    }

    private static void rawStatusesRemainResponses() throws Exception {
        for (int status : List.of(404, 429, 500)) {
            try (Peer peer = new Peer(response(status, List.of(), new byte[0]), false);
                    JavaHttpAdapter adapter = new JavaHttpAdapter()) {
                Issued issued = issue(peer.target("/status"), List.of(), List.of(),
                        configuration(16, 16), Optional.empty());
                JavaHttpAdapter.StartResult start = adapter.start(issued.command());
                var delivered = awaitDelivered(adapter, start.started().orElseThrow());
                check(delivered.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation value
                                && value.response().status() == status,
                        "protocol status remains raw response");
            }
        }
    }

    private static NetworkEffect.AdapterObservation.FailureObservation awaitFailure(
            JavaHttpAdapter adapter, NetworkEffect.StartedAttempt started) throws Exception {
        var delivered = awaitDelivered(adapter, started);
        check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation,
                "typed host failure delivered");
        return (NetworkEffect.AdapterObservation.FailureObservation) delivered.observation();
    }

    private static void actualFailureStimuli() throws Exception {
        Set<Class<?>> observed = new HashSet<>();

        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued ftp = issue("ftp://127.0.0.1/file", List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(ftp.command());
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }

        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued invalid = issue("http://127.0.0.1/", List.of(), List.of(),
                    configuration(0, 0), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(invalid.command());
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }

        int refusedPort;
        try (ServerSocket unused = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            refusedPort = unused.getLocalPort();
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued refused = issue("http://127.0.0.1:" + refusedPort + "/", List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(refused.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }

        try (Peer peer = new Peer(null, false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/no-headers"), List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }

        byte[] incompleteBody = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nx"
                .getBytes(StandardCharsets.US_ASCII);
        try (Peer peer = new Peer(incompleteBody, false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/short-body"), List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }
        byte[] malformedResponse =
                "HTTP/1.1 invalid status\r\nContent-Length: 0\r\n\r\n"
                        .getBytes(StandardCharsets.US_ASCII);
        try (Peer peer = new Peer(malformedResponse, false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/malformed"), List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow())
                    .failure().cause().getClass());
        }


        try (Peer peer = new Peer(response(200, List.of(), new byte[] {1, 2, 3}), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/oversized"), List.of(), List.of(),
                    configuration(16, 2), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }

        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued rejected = issue(peer.target("/header"),
                    List.of(new NetworkEffect.RawHeaderField("X-Bad", List.of(0x80))),
                    List.of(), configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(rejected.command());
            check(result.started().isPresent(), "header rejection observed after start");
            var failure = awaitFailure(adapter, result.started().orElseThrow());
            observed.add(failure.failure().cause().getClass());
            check(failure.failure().stage() == NetworkEffect.HostStage.RequestWrite,
                    "header rejection reported at request-write stage");
            check(peer.receivedCount() == 0, "request header rejected before send");
        }

        var cancellation = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel"));
        var cancelConfig = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.of(cancellation), Optional.empty());
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        () -> new NetworkEffect.MonotonicClockObservation(
                                new NetworkEffect.ClockBasis("unused"), n(0)),
                        (attempt, handle) -> false)) {
            Issued issued = issue(peer.target("/cancel"), List.of(), List.of(),
                    cancelConfig, Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            var startedStep = applyStart(issued, start);
            var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
            check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>, "cancel command ready");
            @SuppressWarnings("unchecked")
            var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
            JavaHttpAdapter.PollResult result = adapter.cancel(ready.command());
            check(result instanceof JavaHttpAdapter.PollResult.Delivered, "cancel rejection delivered");
            var delivered = (NetworkEffect.HostObservation.Delivered)
                    ((JavaHttpAdapter.PollResult.Delivered) result).observation();
            var failure = (NetworkEffect.AdapterObservation.FailureObservation) delivered.observation();
            observed.add(failure.failure().cause().getClass());
            peer.release();
        }

        var basis = new NetworkEffect.ClockBasis("clock");
        var clock = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("clock"), basis);
        var wrongClock = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("wrong"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clock);
        var attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("http", "deadline-control", n(0)), n(0));
        var forgedInput = new NetworkEffect.AttemptInput(attempt,
                new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), List.of()),
                Optional.of(deadline),
                new NetworkEffect.HostConfiguration(n(16), n(16), Optional.empty(), Optional.of(wrongClock)));
        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var forged = new NetworkEffect.SendCommand(
                    new NetworkEffect.PreparedAttempt(forgedInput, new NetworkEffect.AttemptLineage.Root()));
            var result = adapter.start(forged);
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                () -> new NetworkEffect.MonotonicClockObservation(
                        new NetworkEffect.ClockBasis("unused"), n(0)),
                (key, handle) -> true,
                prepared -> { throw new IllegalStateException("worker bootstrap"); },
                () -> {})) {
            Issued issued = issue("http://127.0.0.1/", List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(issued.command());
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }

        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                () -> new NetworkEffect.MonotonicClockObservation(
                        new NetworkEffect.ClockBasis("unused"), n(0)),
                (key, handle) -> true,
                prepared -> java.util.concurrent.Executors.newSingleThreadExecutor(),
                () -> { throw new IllegalStateException("worker callback"); })) {
            Issued issued = issue("http://127.0.0.1/", List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, result.started().orElseThrow())
                    .failure().cause().getClass());
        }

        try (Peer peer = new Peer(null, true)) {
            JavaHttpAdapter adapter = new JavaHttpAdapter();
            Issued issued = issue(peer.target("/close"), List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(issued.command());
            peer.awaitRequest();
            adapter.close();
            observed.add(awaitFailure(adapter, result.started().orElseThrow())
                    .failure().cause().getClass());
            peer.release();
        }


        check(observed.contains(NetworkEffect.HostFailure.UnsupportedUriScheme.class), "unsupported scheme observed");
        check(observed.contains(NetworkEffect.HostFailure.InvalidHostConfiguration.class), "invalid configuration observed");
        check(observed.contains(NetworkEffect.HostFailure.ConnectionFailed.class), "connection failure observed");
        check(observed.contains(NetworkEffect.HostFailure.ResponseHeadersFailed.class), "response headers failure observed");
        check(observed.contains(NetworkEffect.HostFailure.ResponseBodyFailed.class), "response body failure observed");
        check(observed.contains(NetworkEffect.HostFailure.ResponseBodyLimitExceeded.class), "body limit failure observed");
        check(observed.contains(NetworkEffect.HostFailure.RequestHeaderEncodingUnavailable.class), "request header failure observed");
        check(observed.contains(NetworkEffect.HostFailure.MalformedResponse.class), "malformed response observed");
        check(observed.contains(NetworkEffect.HostFailure.CancellationRejected.class), "cancellation rejection observed");
        check(observed.contains(NetworkEffect.HostFailure.DeadlineControlUnavailable.class), "deadline control failure observed");
        check(observed.contains(NetworkEffect.HostFailure.ExecutionStartFailed.class), "execution start failure observed");
        check(observed.contains(NetworkEffect.HostFailure.HostRuntimeFailure.class), "host runtime failure observed");
        check(observed.contains(NetworkEffect.HostFailure.HostClosed.class), "host close observed");
    }

    private static NetworkEffect.NetworkStep.Started syntheticStartedStep() {
        Issued issued = issue("http://127.0.0.1/", List.of(), List.of(),
                configuration(16, 16), Optional.empty());
        var start = new NetworkEffect.StartObservation.Started(
                issued.prepared().input().attempt(), new ExecutionHandle("synthetic-handle"));
        var step = NetworkEffect.observeStart(issued.state(), issued.prepared(), start);
        check(step instanceof NetworkEffect.NetworkStep.Started, "synthetic attempt started");
        return (NetworkEffect.NetworkStep.Started) step;
    }

    private static void assertFault(
            NetworkEffect.HostFailure cause, NetworkEffect.HostStage stage) {
        var started = syntheticStartedStep();
        var attempt = started.started().prepared().input().attempt();
        var failure = new NetworkEffect.NetworkHostFailure(
                attempt, stage, started.started().prepared().input().configuration(), cause);
        var observation = new NetworkEffect.AdapterObservation.FailureObservation(
                attempt, started.started().handle(), new NetworkEffect.SourceSequence.None(), failure,
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.HostFailure));
        var result = NetworkEffect.observe(started.state(),
                new NetworkEffect.HostObservation.Delivered(n(0), observation));
        check(result instanceof NetworkEffect.NetworkStep.Terminal terminal
                        && terminal.settled().terminal().outcome()
                                instanceof NetworkEffect.NetworkOutcome.Failed value
                        && value.failure().cause().equals(cause)
                        && value.failure().attempt().equals(attempt)
                        && value.failure().stage() == stage
                        && value.failure().configuration().equals(
                                started.started().prepared().input().configuration()),
                "fault source preserves closed failure provenance");
    }

    private static void hostFailureMatrixPreservesProvenance() {
        assertFault(new NetworkEffect.HostFailure.UnsupportedUriScheme(), NetworkEffect.HostStage.Start);
        assertFault(new NetworkEffect.HostFailure.InvalidHostConfiguration(), NetworkEffect.HostStage.Start);
        assertFault(new NetworkEffect.HostFailure.ExecutionStartFailed(), NetworkEffect.HostStage.Start);
        assertFault(new NetworkEffect.HostFailure.NameResolutionFailed(), NetworkEffect.HostStage.Start);
        assertFault(new NetworkEffect.HostFailure.ConnectionFailed(), NetworkEffect.HostStage.Start);
        assertFault(new NetworkEffect.HostFailure.RequestWriteFailed(), NetworkEffect.HostStage.RequestWrite);
        assertFault(new NetworkEffect.HostFailure.ResponseHeadersFailed(), NetworkEffect.HostStage.ResponseHeaders);
        assertFault(new NetworkEffect.HostFailure.ResponseBodyFailed(), NetworkEffect.HostStage.ResponseBody);
        assertFault(new NetworkEffect.HostFailure.ResponseBodyLimitExceeded(), NetworkEffect.HostStage.ResponseBody);
        assertFault(new NetworkEffect.HostFailure.MalformedResponse(), NetworkEffect.HostStage.ResponseHeaders);
        assertFault(new NetworkEffect.HostFailure.HeaderRepresentationUnavailable(), NetworkEffect.HostStage.ResponseHeaders);
        assertFault(new NetworkEffect.HostFailure.RequestHeaderEncodingUnavailable(), NetworkEffect.HostStage.RequestWrite);
        assertFault(new NetworkEffect.HostFailure.CancellationRejected(), NetworkEffect.HostStage.Cancel);
        assertFault(new NetworkEffect.HostFailure.DeadlineControlUnavailable(), NetworkEffect.HostStage.Start);
        assertFault(new NetworkEffect.HostFailure.HostRuntimeFailure(), NetworkEffect.HostStage.ResponseBody);
        assertFault(new NetworkEffect.HostFailure.HostClosed(), NetworkEffect.HostStage.Cancel);
        for (NetworkEffect.HostStage stage : NetworkEffect.HostStage.values()) {
            for (NetworkEffect.HostTimeoutCause cause : NetworkEffect.HostTimeoutCause.values()) {
                assertFault(new NetworkEffect.HostFailure.Timeout(stage, cause), stage);
            }
        }
    }

    private static void timeoutAndDeadlineRemainDistinct() throws Exception {
        var basis = new NetworkEffect.ClockBasis("test-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        () -> new NetworkEffect.MonotonicClockObservation(basis, n(10)),
                        (attempt, handle) -> true)) {
            Issued issued = issue(peer.target("/deadline"), List.of(), List.of(),
                    config, Optional.of(deadline));
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            var delivered = awaitDelivered(adapter, start.started().orElseThrow());
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.DeadlineObservation value
                            && value.deadline().equals(deadline)
                            && value.observed().value().equals(n(10)),
                    "clock deadline observation");
            check(!(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation),
                    "deadline is distinct from library timeout");
            peer.release();
        }
        assertFault(new NetworkEffect.HostFailure.Timeout(
                NetworkEffect.HostStage.ResponseHeaders,
                NetworkEffect.HostTimeoutCause.LibraryReported),
                NetworkEffect.HostStage.ResponseHeaders);
    }

    private static void deliveryOrderIgnoresSourceSequence() {
        var started = syntheticStartedStep();
        var attempt = started.started().prepared().input().attempt();
        var handle = started.started().handle();
        var response = new NetworkEffect.AdapterObservation.ResponseObservation(
                attempt, handle, new NetworkEffect.SourceSequence.Some(n(9)),
                new NetworkEffect.RawHttpResponse(200, List.of(), List.of()),
                NetworkEffect.HeaderProvenance.LibraryNormalized,
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse));
        var first = NetworkEffect.observe(started.state(),
                new NetworkEffect.HostObservation.Delivered(n(0), response));
        check(first instanceof NetworkEffect.NetworkStep.Terminal, "delivery zero wins");
        var cancellation = new NetworkEffect.AdapterObservation.CancellationObservation(
                attempt, handle, new NetworkEffect.SourceSequence.Some(n(0)),
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.Cancellation));
        var second = NetworkEffect.observe(((NetworkEffect.NetworkStep.Terminal) first).state(),
                new NetworkEffect.HostObservation.Delivered(n(1), cancellation));
        check(second instanceof NetworkEffect.NetworkStep.Late, "delivery one is late despite source order");
    }

    private static void duplicateAndConflictAreDistinct() {
        var started = syntheticStartedStep();
        var attempt = started.started().prepared().input().attempt();
        var handle = started.started().handle();
        var response = new NetworkEffect.AdapterObservation.ResponseObservation(
                attempt, handle, new NetworkEffect.SourceSequence.None(),
                new NetworkEffect.RawHttpResponse(200, List.of(), List.of()),
                NetworkEffect.HeaderProvenance.LibraryNormalized,
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse));
        var first = NetworkEffect.observe(started.state(),
                new NetworkEffect.HostObservation.Delivered(n(0), response));
        var settled = ((NetworkEffect.NetworkStep.Terminal) first).state();
        check(NetworkEffect.observe(settled,
                        new NetworkEffect.HostObservation.Delivered(n(0), response))
                        instanceof NetworkEffect.NetworkStep.Duplicate,
                "exact duplicate is idempotent");
        var different = new NetworkEffect.AdapterObservation.ResponseObservation(
                attempt, handle, new NetworkEffect.SourceSequence.None(),
                new NetworkEffect.RawHttpResponse(200, List.of(), List.of(1)),
                NetworkEffect.HeaderProvenance.LibraryNormalized,
                response.effect());
        check(NetworkEffect.observe(settled,
                        new NetworkEffect.HostObservation.Delivered(n(0), different))
                        instanceof NetworkEffect.NetworkStep.Rejected rejected
                        && rejected.failure() instanceof NetworkEffect.NetworkFailure.ConflictingDelivery,
                "different replay conflicts");
    }

    private static void forgedTokensAndRetriesDoNotDispatch() {
        Issued issued = issue("http://127.0.0.1/", List.of(), List.of(),
                configuration(16, 16), Optional.empty());
        int issuedCommandCount = 0;
        int peerReceivedCount = 0;
        var authoritative = issued.prepared();
        var input = authoritative.input();
        List<NetworkEffect.PreparedAttempt> forgeries = List.of(
                new NetworkEffect.PreparedAttempt(new NetworkEffect.AttemptInput(
                        input.attempt(), new NetworkEffect.HttpWireInstruction("POST", "http://127.0.0.1/x", List.of(), List.of()),
                        input.deadline(), input.configuration()), authoritative.lineage()),
                new NetworkEffect.PreparedAttempt(new NetworkEffect.AttemptInput(
                        input.attempt(), input.instruction(), Optional.of(new NetworkEffect.Deadline(
                                new NetworkEffect.ClockBasis("x"), n(1),
                                new NetworkEffect.MonotonicClockCapability(
                                        new NetworkEffect.OpaqueEvidence("x"), new NetworkEffect.ClockBasis("x")))),
                        input.configuration()), authoritative.lineage()),
                new NetworkEffect.PreparedAttempt(new NetworkEffect.AttemptInput(
                        input.attempt(), input.instruction(), input.deadline(), configuration(17, 16)), authoritative.lineage()),
                new NetworkEffect.PreparedAttempt(input,
                        new NetworkEffect.AttemptLineage.RetryOf(new NetworkEffect.RetryAuthorization(
                                input.attempt().logical(), input.attempt(), input.attempt(),
                                new NetworkEffect.OpaqueEvidence("forged")))));
        for (NetworkEffect.PreparedAttempt forged : forgeries) {
            check(NetworkEffect.sendCommand(issued.state(), forged)
                            instanceof NetworkEffect.CommandStep.Rejected<?>,
                    "forged prepared field rejected");
        }
        var started = new NetworkEffect.StartedAttempt(authoritative, new ExecutionHandle("forged"));
        check(NetworkEffect.cancelCommand(issued.state(), started)
                        instanceof NetworkEffect.CommandStep.Rejected<?>,
                "forged started handle rejected");

        var terminal = new NetworkEffect.NetworkTerminal(
                new NetworkEffect.NetworkOutcome.Cancelled(),
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.Cancellation));
        var settledRecord = new NetworkEffect.AttemptRecord(
                input, authoritative.lineage(),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var settled = new NetworkEffect.NetworkState(List.of(settledRecord));
        var next = new NetworkEffect.AttemptIdentity(input.attempt().logical(), n(1));
        var authorization = new NetworkEffect.RetryAuthorization(
                input.attempt().logical(), input.attempt(), next,
                new NetworkEffect.OpaqueEvidence("retry"));
        var request = new NetworkEffect.RetryRequest(
                new NetworkEffect.RetryPermission.RetryAllowed(authorization),
                input.instruction(), input.deadline(), input.configuration());
        var retry = NetworkEffect.retry(settled, request);
        check(retry instanceof NetworkEffect.PrepareStep.Prepared prepared
                        && prepared.state().attempts().size() == 2,
                "retry appends ledger record");
        check(NetworkEffect.retry(((NetworkEffect.PrepareStep.Prepared) retry).state(), request)
                        instanceof NetworkEffect.PrepareStep.Rejected,
                "authorization reuse rejected");
        check(issuedCommandCount == 0 && peerReceivedCount == 0,
                "forgery and retry append do not dispatch");
    }

    private static void retryAfterSettledRootDispatchesOrdinalOneAgainstAPeer() throws Exception {
        try (Peer rootPeer = new Peer(response(200, List.of(), new byte[] {'r'}), false);
                Peer retryPeer = new Peer(response(200, List.of(), new byte[] {'t'}), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(rootPeer.target("/retry"), List.of(), List.of(),
                    configuration(16, 16), Optional.empty());
            int issuedCommandCount = 1;
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            check(start.started().isPresent(), "root start returns stable handle");
            var startedStep = applyStart(issued, start);
            var rootDelivered = awaitDelivered(adapter, start.started().orElseThrow());
            check(rootDelivered.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation,
                    "root receives a real response");
            var rootTerminalStep = NetworkEffect.observe(startedStep.state(), rootDelivered);
            check(rootTerminalStep instanceof NetworkEffect.NetworkStep.Terminal, "root settles");
            var rootTerminal = (NetworkEffect.NetworkStep.Terminal) rootTerminalStep;
            check(rootTerminal.settled().terminal().outcome() instanceof NetworkEffect.NetworkOutcome.Response,
                    "root outcome is a response");

            int ledgerRecordCount = rootTerminal.state().attempts().size();
            int peerReceivedCount = rootPeer.receivedCount();
            check(ledgerRecordCount == 1 && issuedCommandCount == 1 && peerReceivedCount == 1,
                    "root ledger, dispatch, and peer counts");

            var input = issued.prepared().input();
            var next = new NetworkEffect.AttemptIdentity(input.attempt().logical(), n(1));
            var authorization = new NetworkEffect.RetryAuthorization(
                    input.attempt().logical(), input.attempt(), next,
                    new NetworkEffect.OpaqueEvidence("retry-auth"));
            var retryInstruction = new NetworkEffect.HttpWireInstruction(
                    input.instruction().method(), retryPeer.target("/retry"),
                    input.instruction().headers(), input.instruction().body());
            var request = new NetworkEffect.RetryRequest(
                    new NetworkEffect.RetryPermission.RetryAllowed(authorization),
                    retryInstruction, input.deadline(), input.configuration());

            var retriedStep = NetworkEffect.retry(rootTerminal.state(), request);
            check(retriedStep instanceof NetworkEffect.PrepareStep.Prepared, "retry appends a prepared record");
            var retried = (NetworkEffect.PrepareStep.Prepared) retriedStep;
            check(retried.state().attempts().size() == ledgerRecordCount + 1,
                    "retry appends exactly one ledger record");
            check(issuedCommandCount == 1 && retryPeer.receivedCount() == 0,
                    "retry() alone does not dispatch or reach the peer");
            check(retried.prepared().lineage() instanceof NetworkEffect.AttemptLineage.RetryOf retryOf
                            && retryOf.authorization().equals(authorization),
                    "prepared retry keeps the authorization lineage");
            check(retried.state().attempts().get(0).lineage() instanceof NetworkEffect.AttemptLineage.Root,
                    "root record lineage unchanged");

            var commandStep = NetworkEffect.sendCommand(retried.state(), retried.prepared());
            check(commandStep instanceof NetworkEffect.CommandStep.CommandReady<?>, "retry send command issued");
            @SuppressWarnings("unchecked")
            var commandReady = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) commandStep;
            Issued retryIssued = new Issued(commandReady.state(), retried.prepared(), commandReady.command());
            JavaHttpAdapter.StartResult retryStart = adapter.start(retryIssued.command());
            check(retryStart.started().isPresent(), "retry start returns stable handle");
            var retryStartedStep = applyStart(retryIssued, retryStart);
            issuedCommandCount += 1;
            var retryDelivered = awaitDelivered(adapter, retryStart.started().orElseThrow());
            check(retryDelivered.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation,
                    "retry receives a real response");
            var retryTerminalStep = NetworkEffect.observe(retryStartedStep.state(), retryDelivered);
            check(retryTerminalStep instanceof NetworkEffect.NetworkStep.Terminal, "retry settles");
            var retryTerminal = (NetworkEffect.NetworkStep.Terminal) retryTerminalStep;
            check(retryTerminal.settled().terminal().outcome() instanceof NetworkEffect.NetworkOutcome.Response,
                    "retry outcome is a response");

            check(issuedCommandCount == 2, "retry dispatch increases issued command count by exactly one");
            check(retryPeer.receivedCount() == 1, "retry dispatch increases peer received count by exactly one");
            check(retryTerminal.state().attempts().size() == ledgerRecordCount + 1,
                    "retry settlement does not append a new ledger record");
            var retryRecord = retryTerminal.state().attempts().get(1);
            check(retryRecord.lineage() instanceof NetworkEffect.AttemptLineage.RetryOf retryOf
                            && retryOf.authorization().equals(authorization),
                    "settled retry keeps the authorization lineage");
            check(!retryRecord.lineage().equals(retryTerminal.state().attempts().get(0).lineage()),
                    "retry lineage is distinct from the root record");
            check(retryTerminal.state().attempts().get(0).lineage() instanceof NetworkEffect.AttemptLineage.Root,
                    "root lineage remains Root");

            var reused = NetworkEffect.retry(retryTerminal.state(), request);
            check(reused instanceof NetworkEffect.PrepareStep.Rejected rejected
                            && rejected.failure() instanceof NetworkEffect.NetworkFailure.RetryNotPermitted,
                    "reused authorization retry rejected");
            check(((NetworkEffect.PrepareStep.Rejected) reused).state().attempts().size()
                            == retryTerminal.state().attempts().size(),
                    "rejected reuse leaves ledger unchanged");
            check(retryPeer.receivedCount() == 1, "rejected reuse does not reach the peer");
        }
    }

    private static void javaResponseHeaderNormalization() {
        var normalized = JavaHttpAdapter.normalizeResponseHeaders(
                Map.of("X-A", List.of("é", "a"), "x-b", List.of("b")));
        check(normalized.get(0).name().equals("x-a")
                        && normalized.get(0).value().equals(List.of(0x61)),
                "sorted header first");
        check(normalized.get(1).value().equals(List.of(0xc3, 0xa9)),
                "strict UTF-8 header");
        check(normalized.get(2).name().equals("x-b"), "sorted header name");
        try {
            JavaHttpAdapter.normalizeResponseHeaders(Map.of("X-A", List.of("\ud800")));
            throw new AssertionError("unpaired surrogate accepted");
        } catch (IllegalArgumentException expected) {
            check(expected instanceof JavaHttpAdapter.HeaderRepresentationException
                            && expected.getMessage().equals("HeaderRepresentationUnavailable"),
                    "header representation failure type");
        }
    }

    public static void main(String[] args) throws Exception {
        loopbackSuccessPreservesBytesHeadersAndCounts();
        rawStatusesRemainResponses();
        actualFailureStimuli();
        hostFailureMatrixPreservesProvenance();
        timeoutAndDeadlineRemainDistinct();
        deliveryOrderIgnoresSourceSequence();
        duplicateAndConflictAreDistinct();
        forgedTokensAndRetriesDoNotDispatch();
        retryAfterSettledRootDispatchesOrdinalOneAgainstAPeer();
        javaResponseHeaderNormalization();
        System.out.println("NetworkEffectHttpSmoke: OK");
    }
}
