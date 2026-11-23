// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.io.IOException;
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
import neco.quotient.Result;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;
import necoherence.semantic.SemanticValues;

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
        private final CountDownLatch clientClosed = new CountDownLatch(1);
        private final AtomicReference<Throwable> failure = new AtomicReference<>();
        private final AtomicInteger received = new AtomicInteger();
        private final AtomicInteger accepted = new AtomicInteger();
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
        int acceptedCount() { return accepted.get(); }
        byte[] requestBody() { return requestBody.clone(); }
        String requestHead() { return requestHead; }
        void release() { release.countDown(); }

        void awaitClientClosed() throws Exception {
            check(clientClosed.await(5, TimeUnit.SECONDS), "the connection was closed from the client side");
        }

        void awaitNoLateResponse(JavaHttpAdapter adapter, NetworkEffect.StartedAttempt started) throws Exception {
            awaitClientClosed();
            release();
            Thread.sleep(150);
            for (int round = 0; round < 2; round++)
                check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                        "no observation follows the stopped request");
        }

        void awaitRequest() throws Exception {
            check(requestComplete.await(5, TimeUnit.SECONDS), "peer request completion");
            check(received.get() == 1, "peer received request");
        }

        private void serve() {
            try (Socket socket = server.accept()) {
                accepted.incrementAndGet();
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
                socket.setSoTimeout(20);
                long limit = System.nanoTime() + 5_000_000_000L;
                while (!release.await(0, TimeUnit.MILLISECONDS)) {
                    if (System.nanoTime() > limit) throw new AssertionError("peer release timeout");
                    try {
                        if (input.read() < 0) {
                            clientClosed.countDown();
                            return;
                        }
                    } catch (java.net.SocketTimeoutException waiting) {
                        // the request stays open until the release
                    }
                }
                if (response != null) {
                    OutputStream output = socket.getOutputStream();
                    output.write(response);
                    output.flush();
                }
            } catch (Throwable error) {
                if (!(closing && error instanceof SocketException)) failure.set(error);
            }
        }

        @Override public void close() throws IOException {
            closing = true;
            release.countDown();
            server.close();
            try {
                thread.join(5_000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IOException("peer thread join interrupted", interrupted);
            }
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
            ByteString body,
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
        var preparedResult = NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), input);
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
        if (step instanceof NetworkEffect.NetworkStep.Started started) return started;
        throw new AssertionError("ledger accepts adapter start");
    }

    private static void loopbackSuccessPreservesBytesHeadersAndCounts() throws Exception {
        byte[] response = response(201,
                List.of("X-Dupe: z", "X-Dupe: a", "X-Accent: é"),
                new byte[] {(byte) 0x80, (byte) 0xff});
        try (Peer peer = new Peer(response, true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            String causal = "causal-" + IDENTITY.get();
            var issued = issue(peer.target("/echo"),
                    List.of(
                            new NetworkEffect.RawHeaderField("X-Visible", ByteString.ofUnsigned(0x20, 0x7e)),
                            new NetworkEffect.RawHeaderField("X-Causal", ByteString.copyOf(causal.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1)))),
                    ByteString.ofUnsigned(0x80, 0xff), configuration(128, 128), Optional.empty());
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
            check(observed.response().body().equals(ByteString.ofUnsigned(0x80, 0xff)), "unsigned response body");
            check(observed.provenance() == NetworkEffect.HeaderProvenance.LibraryNormalized,
                    "normalized header provenance");
            check(observed.response().headers().stream().filter(h -> h.name().equals("x-dupe")).count() == 2,
                    "duplicate response fields preserved");
            check(observed.response().headers().stream().anyMatch(h -> h.name().equals("x-accent")
                            && h.value().equals(ByteString.ofUnsigned(0xc3, 0xa9))),
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
                Issued issued = issue(peer.target("/status"), List.of(), ByteString.empty(),
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
            Issued ftp = issue("ftp://127.0.0.1/file", List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(ftp.command());
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }

        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued invalid = issue("http://127.0.0.1/", List.of(), ByteString.empty(),
                    configuration(4, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(oversizedCommand(invalid, 8));
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }

        int refusedPort;
        try (ServerSocket unused = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            refusedPort = unused.getLocalPort();
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued refused = issue("http://127.0.0.1:" + refusedPort + "/", List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(refused.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }

        try (Peer peer = new Peer(null, false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/no-headers"), List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }

        byte[] incompleteBody = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nx"
                .getBytes(StandardCharsets.US_ASCII);
        try (Peer peer = new Peer(incompleteBody, false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/short-body"), List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }
        byte[] malformedResponse =
                "HTTP/1.1 invalid status\r\nContent-Length: 0\r\n\r\n"
                        .getBytes(StandardCharsets.US_ASCII);
        try (Peer peer = new Peer(malformedResponse, false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/malformed"), List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow())
                    .failure().cause().getClass());
        }


        try (Peer peer = new Peer(response(200, List.of(), new byte[] {1, 2, 3}), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/oversized"), List.of(), ByteString.empty(),
                    configuration(16, 2), Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, start.started().orElseThrow()).failure().cause().getClass());
        }

        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued rejected = issue(peer.target("/header"),
                    List.of(new NetworkEffect.RawHeaderField("X-Bad", ByteString.ofUnsigned(0x80))),
                    ByteString.empty(), configuration(16, 16), Optional.empty());
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
                        HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("unused"), n(0))),
                        HttpPortFixtures.cancellation(cancellation, handle -> HttpPortFixtures.rejected()))) {
            Issued issued = issue(peer.target("/cancel"), List.of(), ByteString.empty(),
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
            check(failure.failure().stage() == NetworkEffect.HostStage.Cancel,
                    "cancel rejection reported at cancel stage");
            check(failure.effect().equals(new NetworkEffect.EffectStatus.Unknown(
                            NetworkEffect.UnknownEffectReason.HostFailure)),
                    "cancel rejection effect reason is host failure");
            peer.release();
        }

        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("unused"), n(0))),
                        HttpPortFixtures.cancellation(cancellation,
                                handle -> { throw new IllegalStateException("cancellation port"); }))) {
            Issued issued = issue(peer.target("/cancel-throws"), List.of(), ByteString.empty(),
                    cancelConfig, Optional.empty());
            JavaHttpAdapter.StartResult start = adapter.start(issued.command());
            var startedStep = applyStart(issued, start);
            var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
            check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>, "throwing cancel command ready");
            @SuppressWarnings("unchecked")
            var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
            JavaHttpAdapter.PollResult result = adapter.cancel(ready.command());
            check(result instanceof JavaHttpAdapter.PollResult.Delivered, "cancel port exception delivered");
            var delivered = (NetworkEffect.HostObservation.Delivered)
                    ((JavaHttpAdapter.PollResult.Delivered) result).observation();
            var failure = (NetworkEffect.AdapterObservation.FailureObservation) delivered.observation();
            check(failure.failure().stage() == NetworkEffect.HostStage.Cancel,
                    "cancel port exception reported at cancel stage");
            check(failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                    "cancel port exception is host runtime failure");
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
                new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), ByteString.empty()),
                Optional.of(deadline),
                new NetworkEffect.HostConfiguration(n(16), n(16), Optional.empty(), Optional.of(clock)));
        var mismatchedInput = new NetworkEffect.AttemptInput(attempt,
                forgedInput.instruction(), Optional.of(deadline),
                new NetworkEffect.HostConfiguration(n(16), n(16), Optional.empty(), Optional.of(wrongClock)));
        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var forged = new NetworkEffect.SendCommand(
                    new NetworkEffect.PreparedAttempt(forgedInput, new NetworkEffect.AttemptChain.Root()));
            var result = adapter.start(forged);
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
            var mismatched = withInput(forged, mismatchedInput);
            var mismatchedResult = adapter.start(mismatched);
            check(((NetworkEffect.StartObservation.StartFailed) mismatchedResult.observation())
                            .failure().cause() instanceof NetworkEffect.HostFailure.InvalidHostConfiguration,
                    "deadline capability differing from the configuration is an invalid configuration");
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                        () -> new NetworkEffect.MonotonicClockObservation(
                                new NetworkEffect.ClockBasis("unused"), n(0))),
                HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION, handle -> HttpPortFixtures.accepted()),
                prepared -> { throw new IllegalStateException("worker bootstrap"); },
                () -> {})) {
            Issued issued = issue("http://127.0.0.1/", List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(issued.command());
            observed.add(((NetworkEffect.StartObservation.StartFailed) result.observation())
                    .failure().cause().getClass());
        }

        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                        () -> new NetworkEffect.MonotonicClockObservation(
                                new NetworkEffect.ClockBasis("unused"), n(0))),
                HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION, handle -> HttpPortFixtures.accepted()),
                prepared -> java.util.concurrent.Executors.newSingleThreadExecutor(),
                () -> { throw new IllegalStateException("worker callback"); })) {
            Issued issued = issue("http://127.0.0.1/", List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(issued.command());
            observed.add(awaitFailure(adapter, result.started().orElseThrow())
                    .failure().cause().getClass());
        }

        try (Peer peer = new Peer(null, true)) {
            JavaHttpAdapter adapter = new JavaHttpAdapter();
            Issued issued = issue(peer.target("/close"), List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            JavaHttpAdapter.StartResult result = adapter.start(issued.command());
            peer.awaitRequest();
            adapter.close();
            var closedFailure = awaitFailure(adapter, result.started().orElseThrow());
            observed.add(closedFailure.failure().cause().getClass());
            check(closedFailure.failure().stage() == NetworkEffect.HostStage.Cancel,
                    "host close reported at cancel stage");
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
        Issued issued = issue("http://127.0.0.1/", List.of(), ByteString.empty(),
                configuration(16, 16), Optional.empty());
        var start = new NetworkEffect.StartObservation.Started(
                issued.prepared().input().attempt(), new ExecutionHandle("synthetic-handle"));
        var step = NetworkEffect.observeStart(issued.state(), issued.prepared(), start);
        if (step instanceof NetworkEffect.NetworkStep.Started started) return started;
        throw new AssertionError("synthetic attempt started");
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
                        HttpPortFixtures.clock(clockCapability,
                                () -> new NetworkEffect.MonotonicClockObservation(basis, n(10))),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/deadline"), List.of(), ByteString.empty(),
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

    private static void clockBelowTheLimitKeepsObservePending() throws Exception {
        var basis = new NetworkEffect.ClockBasis("below-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("below-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(clockCapability,
                                () -> new NetworkEffect.MonotonicClockObservation(basis, n(9))),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/below"), List.of(), ByteString.empty(),
                    config, Optional.of(deadline));
            var started = adapter.start(issued.command()).started().orElseThrow();
            check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                    "a clock below the limit leaves observe pending");
            peer.release();
        }
    }

    private static void clockNowExceptionIsOneHostRuntimeFailure() throws Exception {
        var basis = new NetworkEffect.ClockBasis("raising-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("raising-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        var calls = new java.util.concurrent.atomic.AtomicInteger();
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(clockCapability, () -> {
                            calls.incrementAndGet();
                            throw new IllegalStateException("clock failure");
                        }),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/raising"), List.of(), ByteString.empty(),
                    config, Optional.of(deadline));
            var started = adapter.start(issued.command()).started().orElseThrow();
            var delivered = awaitDelivered(adapter, started);
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.Deadline
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                            && failure.effect().equals(unknownHostFailure()),
                    "clock now exception is a deadline stage host runtime failure");
            check(calls.get() == 1, "the port is called once");
            check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                    "the failure observation is queued once");
            check(calls.get() == 1, "a later observe does not call the port");
            check(peer.acceptedCount() == 0, "no request is sent after the clock failure");
            peer.release();
        }
    }

    private static void aClockFailureSeenByObserveInterruptsTheRequest() throws Exception {
        var basis = new NetworkEffect.ClockBasis("observe-failure-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("observe-failure-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        var failing = new java.util.concurrent.atomic.AtomicBoolean();
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(clockCapability, () -> {
                            if (failing.get()) throw new IllegalStateException("clock failure");
                            return new NetworkEffect.MonotonicClockObservation(basis, n(0));
                        }),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/observe-failure"), List.of(), ByteString.empty(),
                    config, Optional.of(deadline));
            var started = adapter.start(issued.command()).started().orElseThrow();
            peer.awaitRequest();
            failing.set(true);
            var delivered = awaitDelivered(adapter, started);
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.Deadline
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                            && failure.effect().equals(unknownHostFailure()),
                    "a clock failure seen by observe is a deadline stage host runtime failure");
            peer.awaitNoLateResponse(adapter, started);
        }
    }

    private static void aClockFailureValueOnTheFirstObservationIsOneDeadlineFailure() throws Exception {
        var basis = new NetworkEffect.ClockBasis("failure-value-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("failure-value-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        var calls = new java.util.concurrent.atomic.AtomicInteger();
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clockResult(clockCapability, () -> {
                            calls.incrementAndGet();
                            return new Result.Rejected<>(new NetworkEffect.HostFailure.HostRuntimeFailure());
                        }),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/failure-value"), List.of(), ByteString.empty(),
                    config, Optional.of(deadline));
            var started = adapter.start(issued.command()).started().orElseThrow();
            var delivered = awaitDelivered(adapter, started);
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.Deadline
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                            && failure.effect().equals(unknownHostFailure()),
                    "a clock failure value on the first observation is a deadline stage host runtime failure");
            check(calls.get() == 1, "the port is called once");
            check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                    "the failure observation is queued once");
            check(calls.get() == 1, "a later observe does not call the port");
            check(peer.acceptedCount() == 0, "no request is sent after the clock failure value");
            peer.release();
        }
    }

    private static void aClockFailureValueOnALaterObservationIsOneDeadlineFailure() throws Exception {
        var basis = new NetworkEffect.ClockBasis("later-failure-value-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("later-failure-value-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        var failing = new java.util.concurrent.atomic.AtomicBoolean();
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clockResult(clockCapability, () -> failing.get()
                                ? new Result.Rejected<>(new NetworkEffect.HostFailure.HostRuntimeFailure())
                                : new Result.Accepted<>(new NetworkEffect.MonotonicClockObservation(basis, n(0)))),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/later-failure-value"), List.of(), ByteString.empty(),
                    config, Optional.of(deadline));
            var started = adapter.start(issued.command()).started().orElseThrow();
            peer.awaitRequest();
            failing.set(true);
            var delivered = awaitDelivered(adapter, started);
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.Deadline
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                            && failure.effect().equals(unknownHostFailure()),
                    "a clock failure value on a later observation is a deadline stage host runtime failure");
            peer.awaitNoLateResponse(adapter, started);
        }
    }

    private static void aCancellationRequestFailureValueIsOneCancelFailure() throws Exception {
        var cancellation = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel-failure-value"));
        var cancelConfig = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.of(cancellation), Optional.empty());
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("unused"), n(0))),
                        HttpPortFixtures.cancellation(cancellation,
                                handle -> HttpPortFixtures.rejected(new NetworkEffect.HostFailure.HostRuntimeFailure())))) {
            Issued issued = issue(peer.target("/cancel-failure-value"), List.of(), ByteString.empty(),
                    cancelConfig, Optional.empty());
            var startedStep = applyStart(issued, adapter.start(issued.command()));
            peer.awaitRequest();
            var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
            @SuppressWarnings("unchecked")
            var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
            var result = adapter.cancel(ready.command());
            check(result instanceof JavaHttpAdapter.PollResult.Delivered, "cancel failure value delivered");
            var delivered = (NetworkEffect.HostObservation.Delivered)
                    ((JavaHttpAdapter.PollResult.Delivered) result).observation();
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.Cancel
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                            && failure.effect().equals(unknownHostFailure()),
                    "a cancellation failure value is a cancel stage host runtime failure");
            peer.awaitNoLateResponse(adapter, startedStep.started());
        }
    }

    private static void aCancellationThatFailsInterruptsTheRequest() throws Exception {
        var cancellation = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel-fails"));
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.of(cancellation), Optional.empty());
        for (int scenario = 0; scenario < 2; scenario++) {
            final boolean throwing = scenario == 1;
            try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                    JavaHttpAdapter adapter = new JavaHttpAdapter(
                            HttpClient.newHttpClient(),
                            HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                    () -> new NetworkEffect.MonotonicClockObservation(
                                            new NetworkEffect.ClockBasis("unused"), n(0))),
                            HttpPortFixtures.cancellation(cancellation, handle -> {
                                if (throwing) throw new IllegalStateException("cancellation port failure");
                                return HttpPortFixtures.rejected();
                            }))) {
                Issued issued = issue(peer.target("/cancel-fails-" + scenario),
                        List.of(), ByteString.empty(), config, Optional.empty());
                var startedStep = applyStart(issued, adapter.start(issued.command()));
                peer.awaitRequest();
                var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
                @SuppressWarnings("unchecked")
                var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
                var result = adapter.cancel(ready.command());
                check(result instanceof JavaHttpAdapter.PollResult.Delivered, "failed cancel delivered");
                var delivered = (NetworkEffect.HostObservation.Delivered)
                        ((JavaHttpAdapter.PollResult.Delivered) result).observation();
                check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                                && failure.failure().stage() == NetworkEffect.HostStage.Cancel
                                && (throwing
                                        ? failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                                        : failure.failure().cause() instanceof NetworkEffect.HostFailure.CancellationRejected)
                                && failure.effect().equals(unknownHostFailure()),
                        "the cancel failure carries the cancel stage and the port cause");
                peer.awaitNoLateResponse(adapter, startedStep.started());
            }
        }
    }

    private static void clockWithAnotherBasisNeverReachesTheDeadline() throws Exception {
        var basis = new NetworkEffect.ClockBasis("deadline-basis");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("basis-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(clockCapability,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("other-basis"), n(100))),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue(peer.target("/basis"), List.of(), ByteString.empty(),
                    config, Optional.of(deadline));
            var started = adapter.start(issued.command()).started().orElseThrow();
            check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                    "a clock with another basis leaves observe pending");
            check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                    "a clock with another basis queues nothing");
            peer.release();
        }
    }

    private static void deadlineCheckBeforeTheRequestIsSent() throws Exception {
        var basis = new NetworkEffect.ClockBasis("before-send-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("before-send-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        var other = new NetworkEffect.ClockBasis("other-before-send-basis");
        var calls = new AtomicInteger();
        java.util.function.Supplier<NetworkEffect.MonotonicClockObservation> reached =
                () -> new NetworkEffect.MonotonicClockObservation(basis, n(10));
        java.util.function.Supplier<NetworkEffect.MonotonicClockObservation> below =
                () -> new NetworkEffect.MonotonicClockObservation(basis, n(9));
        java.util.function.Supplier<NetworkEffect.MonotonicClockObservation> otherBasis =
                () -> new NetworkEffect.MonotonicClockObservation(other, n(100));
        java.util.function.Supplier<NetworkEffect.MonotonicClockObservation> firstFails = () -> {
            if (calls.incrementAndGet() == 1) throw new IllegalStateException("first read");
            return new NetworkEffect.MonotonicClockObservation(basis, n(0));
        };
        for (int scenario = 0; scenario < 4; scenario++) {
            var source = switch (scenario) {
                case 0 -> reached;
                case 1 -> below;
                case 2 -> otherBasis;
                default -> firstFails;
            };
            try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                    JavaHttpAdapter adapter = new JavaHttpAdapter(
                            HttpClient.newHttpClient(),
                            HttpPortFixtures.clock(clockCapability, source::get),
                            HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                    handle -> HttpPortFixtures.accepted()))) {
                Issued issued = issue(peer.target("/before-send"), List.of(), ByteString.empty(),
                        config, Optional.of(deadline));
                var started = adapter.start(issued.command()).started().orElseThrow();
                if (scenario == 1 || scenario == 2) {
                    peer.awaitRequest();
                } else {
                    Thread.sleep(300);
                    check(peer.acceptedCount() == 0, "no connection is accepted in scenario " + scenario);
                    var delivered = awaitDelivered(adapter, started);
                    if (scenario == 0)
                        check(delivered.observation() instanceof NetworkEffect.AdapterObservation.DeadlineObservation,
                                "a clock at the limit delivers the deadline observation");
                    else {
                        check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                                        && failure.failure().stage() == NetworkEffect.HostStage.Deadline
                                        && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                                "a failing first read delivers a deadline stage host runtime failure");
                        check(calls.get() == 1, "the failing port is read once");
                        check(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Pending,
                                "the failure observation is queued once");
                    }
                }
                peer.release();
            }
        }
    }

    private static void aPublicObserveAndTheWorkerQueueOneDeadlineObservation() throws Exception {
        var basis = new NetworkEffect.ClockBasis("once-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("once-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                HttpPortFixtures.clock(clockCapability,
                        () -> new NetworkEffect.MonotonicClockObservation(basis, n(10))),
                HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                        handle -> HttpPortFixtures.accepted()))) {
            for (int round = 0; round < 200; round++) {
                Issued issued = issue("http://127.0.0.1:1/once", List.of(), ByteString.empty(),
                        config, Optional.of(deadline));
                var started = adapter.start(issued.command()).started().orElseThrow();
                long limit = System.nanoTime() + 2_000_000_000L;
                for (;;) {
                    var observed = adapter.observe(started);
                    if (observed instanceof JavaHttpAdapter.PollResult.Delivered delivered) {
                        check(delivered.observation() instanceof NetworkEffect.HostObservation.Delivered value
                                && value.observation() instanceof NetworkEffect.AdapterObservation.DeadlineObservation,
                                "the first delivery is the deadline observation");
                        break;
                    }
                    check(System.nanoTime() < limit, "the deadline observation arrived");
                }
                for (int later = 0; later < 5; later++) {
                    Thread.sleep(1);
                    check(!(adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Delivered),
                            "no second deadline observation in round " + round);
                }
            }
        }
    }

    private static void startCapabilityReadExceptionIsAHostRuntimeFailure() throws Exception {
        var basis = new NetworkEffect.ClockBasis("read-clock");
        var clockCapability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("read-clock"), basis);
        var cancellationCapability = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("read-cancel"));
        var deadline = new NetworkEffect.Deadline(basis, n(10), clockCapability);
        var clockConfig = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.empty(), Optional.of(clockCapability));
        var cancelConfig = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.of(cancellationCapability), Optional.empty());
        JavaHttpAdapter.MonotonicClockPort rawClock = new JavaHttpAdapter.MonotonicClockPort() {
            @Override public NetworkEffect.MonotonicClockCapability capability() {
                throw new IllegalStateException("clock capability failure");
            }
            @Override public Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe() {
                return new Result.Accepted<>(new NetworkEffect.MonotonicClockObservation(basis, n(0)));
            }
        };
        JavaHttpAdapter.CancellationPort rawCancellation = new JavaHttpAdapter.CancellationPort() {
            @Override public NetworkEffect.CancellationCapability capability() {
                throw new IllegalStateException("cancellation capability failure");
            }
            @Override public Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle) {
                return HttpPortFixtures.accepted();
            }
        };
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(), rawClock,
                HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION, handle -> HttpPortFixtures.accepted()))) {
            Issued issued = issue("http://127.0.0.1:1/clock-read", List.of(), ByteString.empty(),
                    clockConfig, Optional.of(deadline));
            var result = adapter.start(issued.command());
            check(result.started().isEmpty(), "a clock capability read exception creates no record");
            check(result.observation() instanceof NetworkEffect.StartObservation.StartFailed failed
                            && failed.failure().stage() == NetworkEffect.HostStage.Start
                            && failed.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                    "a clock capability read exception is a start host runtime failure");
            check(adapter.recordCount() == 0, "a clock capability read exception leaves no record");
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                        () -> new NetworkEffect.MonotonicClockObservation(
                                new NetworkEffect.ClockBasis("unused"), n(0))),
                rawCancellation)) {
            Issued issued = issue("http://127.0.0.1:1/cancel-read", List.of(), ByteString.empty(),
                    cancelConfig, Optional.empty());
            var result = adapter.start(issued.command());
            check(result.started().isEmpty(), "a cancellation capability read exception creates no record");
            check(result.observation() instanceof NetworkEffect.StartObservation.StartFailed failed
                            && failed.failure().stage() == NetworkEffect.HostStage.Start
                            && failed.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                    "a cancellation capability read exception is a start host runtime failure");
            check(adapter.recordCount() == 0, "a cancellation capability read exception leaves no record");
        }
    }

    private static void cancelCapabilityReadExceptionIsACancelHostRuntimeFailure() throws Exception {
        var cancellation = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel-read"));
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.of(cancellation), Optional.empty());
        AtomicInteger reads = new AtomicInteger();
        AtomicInteger requests = new AtomicInteger();
        var armed = new java.util.concurrent.atomic.AtomicBoolean();
        JavaHttpAdapter.CancellationPort port = new JavaHttpAdapter.CancellationPort() {
            @Override public NetworkEffect.CancellationCapability capability() {
                reads.incrementAndGet();
                if (armed.get()) throw new IllegalStateException("cancellation capability failure");
                return cancellation;
            }
            @Override public Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle) {
                requests.incrementAndGet();
                return HttpPortFixtures.accepted();
            }
        };
        try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("unused"), n(0))),
                        port)) {
            Issued issued = issue(peer.target("/cancel-read"), List.of(), ByteString.empty(),
                    config, Optional.empty());
            var startedStep = applyStart(issued, adapter.start(issued.command()));
            peer.awaitRequest();
            var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
            @SuppressWarnings("unchecked")
            var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
            armed.set(true);
            var result = adapter.cancel(ready.command());
            check(result instanceof JavaHttpAdapter.PollResult.Delivered, "capability read failure delivered");
            var delivered = (NetworkEffect.HostObservation.Delivered)
                    ((JavaHttpAdapter.PollResult.Delivered) result).observation();
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.Cancel
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure
                            && failure.effect().equals(unknownHostFailure()),
                    "a cancellation capability read exception is a cancel host runtime failure");
            check(requests.get() == 0, "a failed capability read never reaches the request");
            peer.awaitNoLateResponse(adapter, startedStep.started());
        }
    }

    private static NetworkEffect.EffectStatus unknownHostFailure() {
        return new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.HostFailure);
    }

    private static void deliveryOrderIgnoresSourceSequence() {
        var started = syntheticStartedStep();
        var attempt = started.started().prepared().input().attempt();
        var handle = started.started().handle();
        var response = new NetworkEffect.AdapterObservation.ResponseObservation(
                attempt, handle, new NetworkEffect.SourceSequence.Some(n(9)),
                new NetworkEffect.RawHttpResponse(200, List.of(), ByteString.empty()),
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
                new NetworkEffect.RawHttpResponse(200, List.of(), ByteString.empty()),
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
                new NetworkEffect.RawHttpResponse(200, List.of(), ByteString.ofUnsigned(1)),
                NetworkEffect.HeaderProvenance.LibraryNormalized,
                response.effect());
        check(NetworkEffect.observe(settled,
                        new NetworkEffect.HostObservation.Delivered(n(0), different))
                        instanceof NetworkEffect.NetworkStep.Rejected rejected
                        && rejected.failure() instanceof NetworkEffect.NetworkFailure.ConflictingDelivery,
                "different replay conflicts");
    }

    private static void forgedTokensAndRetriesDoNotDispatch() {
        Issued issued = issue("http://127.0.0.1/", List.of(), ByteString.empty(),
                configuration(16, 16), Optional.empty());
        int issuedCommandCount = 0;
        int peerReceivedCount = 0;
        var authoritative = issued.prepared();
        var input = authoritative.input();
        List<NetworkEffect.PreparedAttempt> forgeries = List.of(
                new NetworkEffect.PreparedAttempt(new NetworkEffect.AttemptInput(
                        input.attempt(), new NetworkEffect.HttpWireInstruction("POST", "http://127.0.0.1/x", List.of(), ByteString.empty()),
                        input.deadline(), input.configuration()), authoritative.chain()),
                new NetworkEffect.PreparedAttempt(new NetworkEffect.AttemptInput(
                        input.attempt(), input.instruction(), Optional.of(new NetworkEffect.Deadline(
                                new NetworkEffect.ClockBasis("x"), n(1),
                                new NetworkEffect.MonotonicClockCapability(
                                        new NetworkEffect.OpaqueEvidence("x"), new NetworkEffect.ClockBasis("x")))),
                        input.configuration()), authoritative.chain()),
                new NetworkEffect.PreparedAttempt(new NetworkEffect.AttemptInput(
                        input.attempt(), input.instruction(), input.deadline(), configuration(17, 16)), authoritative.chain()),
                new NetworkEffect.PreparedAttempt(input,
                        new NetworkEffect.AttemptChain.RetryOf(new NetworkEffect.RetryAuthorization(
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
                input, authoritative.chain(),
                new NetworkEffect.AttemptDisposition.Settled(Optional.empty(), terminal),
                Optional.empty(), List.of());
        var settled = ((NetworkEffect.NetworkStateResult.Built) NetworkEffect.networkStateOf(List.of(settledRecord))).state();
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
            Issued issued = issue(rootPeer.target("/retry"), List.of(), ByteString.empty(),
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
            check(retried.prepared().chain() instanceof NetworkEffect.AttemptChain.RetryOf retryOf
                            && retryOf.authorization().equals(authorization),
                    "prepared retry keeps the authorization chain");
            check(retried.state().attempts().get(0).chain() instanceof NetworkEffect.AttemptChain.Root,
                    "root record chain unchanged");

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
            check(retryRecord.chain() instanceof NetworkEffect.AttemptChain.RetryOf retryOf
                            && retryOf.authorization().equals(authorization),
                    "settled retry keeps the authorization chain");
            check(!retryRecord.chain().equals(retryTerminal.state().attempts().get(0).chain()),
                    "retry chain is distinct from the root record");
            check(retryTerminal.state().attempts().get(0).chain() instanceof NetworkEffect.AttemptChain.Root,
                    "root chain remains Root");

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

    private static NetworkEffect.SendCommand withInput(
            NetworkEffect.SendCommand original, NetworkEffect.AttemptInput input) throws Exception {
        var constructor = NetworkEffect.PreparedAttempt.class.getDeclaredConstructors()[0];
        constructor.setAccessible(true);
        Object second = NetworkEffect.PreparedAttempt.class.getRecordComponents()[1]
                .getAccessor().invoke(original.prepared());
        return new NetworkEffect.SendCommand(
                (NetworkEffect.PreparedAttempt) constructor.newInstance(input, second));
    }

    private static NetworkEffect.SendCommand oversizedCommand(Issued issued, int length) throws Exception {
        var input = issued.prepared().input();
        return withInput(issued.command(), new NetworkEffect.AttemptInput(input.attempt(),
                new NetworkEffect.HttpWireInstruction(input.instruction().method(),
                        input.instruction().target(), List.of(), ByteString.copyOf(new byte[length])),
                input.deadline(), input.configuration()));
    }

    private static NetworkEffect.HostFailure startFailure(JavaHttpAdapter.StartResult result) {
        check(result.observation() instanceof NetworkEffect.StartObservation.StartFailed,
                "start failure expected");
        var failed = (NetworkEffect.StartObservation.StartFailed) result.observation();
        check(failed.failure().stage() == NetworkEffect.HostStage.Start, "start failure stage");
        return failed.failure().cause();
    }

    private static void startChecksRunInTheFixedOrder() throws Exception {
        var basis = new NetworkEffect.ClockBasis("order-basis");
        var capability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("order-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, n(10), capability);
        var configuration = new NetworkEffect.HostConfiguration(
                n(4), n(16), Optional.empty(), Optional.of(capability));
        try (Peer peer = new Peer(null, false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued valid = issue(peer.target("/order"), List.of(), ByteString.empty(),
                    configuration, Optional.of(deadline));
            var ftpInput = new NetworkEffect.AttemptInput(valid.prepared().input().attempt(),
                    new NetworkEffect.HttpWireInstruction("POST", "ftp://127.0.0.1/",
                            List.of(), ByteString.copyOf(new byte[8])),
                    Optional.of(deadline), configuration);
            check(startFailure(adapter.start(withInput(valid.command(), ftpInput)))
                            instanceof NetworkEffect.HostFailure.UnsupportedUriScheme,
                    "scheme is checked before the configuration");
            var oversizeInput = new NetworkEffect.AttemptInput(valid.prepared().input().attempt(),
                    new NetworkEffect.HttpWireInstruction("POST", peer.target("/order"),
                            List.of(), ByteString.copyOf(new byte[8])),
                    Optional.of(deadline), configuration);
            check(startFailure(adapter.start(withInput(valid.command(), oversizeInput)))
                            instanceof NetworkEffect.HostFailure.InvalidHostConfiguration,
                    "configuration is checked before the deadline clock");
            check(startFailure(adapter.start(valid.command()))
                            instanceof NetworkEffect.HostFailure.DeadlineControlUnavailable,
                    "the deadline clock must match the adapter clock at start");
            check(peer.receivedCount() == 0, "no request reached the peer");
        }
        var sameBasisOtherIdentity = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("other-clock"), basis);
        try (Peer peer = new Peer(null, false);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(sameBasisOtherIdentity,
                                () -> new NetworkEffect.MonotonicClockObservation(basis, n(0))),
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            Issued valid = issue(peer.target("/other-identity"), List.of(), ByteString.empty(),
                    configuration, Optional.of(deadline));
            check(startFailure(adapter.start(valid.command()))
                            instanceof NetworkEffect.HostFailure.DeadlineControlUnavailable,
                    "a clock port with the same basis and another capability is a start failure");
            check(peer.receivedCount() == 0, "no request reached the peer");
        }
        var cancelCapability = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("order-cancel"));
        var cancelConfiguration = new NetworkEffect.HostConfiguration(
                n(4), n(16), Optional.of(cancelCapability), Optional.empty());
        try (Peer peer = new Peer(response(200, List.of(), new byte[] {1}), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued valid = issue(peer.target("/other-cancel"), List.of(), ByteString.empty(),
                    cancelConfiguration, Optional.empty());
            check(startFailure(adapter.start(valid.command()))
                            instanceof NetworkEffect.HostFailure.InvalidHostConfiguration,
                    "a cancellation capability differing from the port is an invalid configuration");
            check(peer.receivedCount() == 0, "no request reached the peer");
        }
        try (Peer peer = new Peer(response(200, List.of(), new byte[] {1}), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(capability,
                                () -> new NetworkEffect.MonotonicClockObservation(basis, n(0))),
                        HttpPortFixtures.cancellation(cancelCapability, handle -> HttpPortFixtures.accepted()))) {
            var allMatching = new NetworkEffect.HostConfiguration(
                    n(4), n(16), Optional.of(cancelCapability), Optional.of(capability));
            var farDeadline = new NetworkEffect.Deadline(basis, n(1_000_000_000L), capability);
            Issued valid = issue(peer.target("/all-match"), List.of(), ByteString.empty(),
                    allMatching, Optional.of(farDeadline));
            var result = adapter.start(valid.command());
            check(result.started().isPresent(), "all capabilities matching starts");
            check(awaitDelivered(adapter, result.started().orElseThrow()).observation()
                            instanceof NetworkEffect.AdapterObservation.ResponseObservation,
                    "all capabilities matching returns the response");
        }
    }

    private static void responseEffectReasonIsTheMissingProtocolWitness() throws Exception {
        try (Peer peer = new Peer(response(200, List.of(), new byte[] {1}), false);
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Issued issued = issue(peer.target("/reason"), List.of(), ByteString.empty(),
                    configuration(16, 16), Optional.empty());
            var delivered = awaitDelivered(adapter, adapter.start(issued.command()).started().orElseThrow());
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation value
                            && value.effect().equals(new NetworkEffect.EffectStatus.Unknown(
                                    NetworkEffect.UnknownEffectReason.ProtocolWitnessMissing)),
                    "response effect reason is the missing protocol witness");
        }
    }

    private static final class FailingClient extends HttpClient {
        private final boolean headersFirst;

        FailingClient(boolean headersFirst) { this.headersFirst = headersFirst; }

        @Override public Optional<java.net.CookieHandler> cookieHandler() { return Optional.empty(); }
        @Override public Optional<java.time.Duration> connectTimeout() { return Optional.empty(); }
        @Override public Redirect followRedirects() { return Redirect.NEVER; }
        @Override public Optional<java.net.ProxySelector> proxy() { return Optional.empty(); }
        @Override public javax.net.ssl.SSLContext sslContext() {
            try { return javax.net.ssl.SSLContext.getDefault(); }
            catch (java.security.NoSuchAlgorithmException error) { throw new IllegalStateException(error); }
        }
        @Override public javax.net.ssl.SSLParameters sslParameters() { return new javax.net.ssl.SSLParameters(); }
        @Override public Optional<java.net.Authenticator> authenticator() { return Optional.empty(); }
        @Override public Version version() { return Version.HTTP_1_1; }
        @Override public Optional<java.util.concurrent.Executor> executor() { return Optional.empty(); }
        @Override public <T> java.net.http.HttpResponse<T> send(
                java.net.http.HttpRequest request, java.net.http.HttpResponse.BodyHandler<T> handler) {
            throw new UnsupportedOperationException();
        }
        @Override public <T> java.util.concurrent.CompletableFuture<java.net.http.HttpResponse<T>> sendAsync(
                java.net.http.HttpRequest request, java.net.http.HttpResponse.BodyHandler<T> handler) {
            if (headersFirst) handler.apply(new java.net.http.HttpResponse.ResponseInfo() {
                @Override public int statusCode() { return 200; }
                @Override public java.net.http.HttpHeaders headers() {
                    return java.net.http.HttpHeaders.of(Map.of(), (name, value) -> true);
                }
                @Override public Version version() { return Version.HTTP_1_1; }
            });
            return java.util.concurrent.CompletableFuture.failedFuture(
                    new IllegalStateException("controlled failure"));
        }
        @Override public <T> java.util.concurrent.CompletableFuture<java.net.http.HttpResponse<T>> sendAsync(
                java.net.http.HttpRequest request, java.net.http.HttpResponse.BodyHandler<T> handler,
                java.net.http.HttpResponse.PushPromiseHandler<T> pushPromiseHandler) {
            return sendAsync(request, handler);
        }
    }

    private static NetworkEffect.NetworkHostFailure unclassifiedFailure(JavaHttpAdapter adapter, String target)
            throws Exception {
        Issued issued = issue(target, List.of(), ByteString.empty(), configuration(16, 16), Optional.empty());
        var failure = awaitFailure(adapter, adapter.start(issued.command()).started().orElseThrow());
        check(failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                "unclassified failure is a host runtime failure");
        return failure.failure();
    }

    private static void unclassifiedFailureKeepsTheStageOfTheWorker() throws Exception {
        var clock = HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                () -> new NetworkEffect.MonotonicClockObservation(new NetworkEffect.ClockBasis("unused"), n(0)));
        var cancellation = HttpPortFixtures.cancellation(
                HttpPortFixtures.UNUSED_CANCELLATION, handle -> HttpPortFixtures.accepted());
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(), clock, cancellation,
                prepared -> java.util.concurrent.Executors.newSingleThreadExecutor(),
                () -> { throw new IllegalStateException("worker callback"); })) {
            check(unclassifiedFailure(adapter, "http://127.0.0.1/").stage()
                            == NetworkEffect.HostStage.RequestWrite,
                    "failure before the request is sent stays at the request-write stage");
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(new FailingClient(false), clock, cancellation)) {
            check(unclassifiedFailure(adapter, "http://127.0.0.1/").stage()
                            == NetworkEffect.HostStage.ResponseHeaders,
                    "failure while waiting for headers stays at the response-headers stage");
        }
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(new FailingClient(true), clock, cancellation)) {
            check(unclassifiedFailure(adapter, "http://127.0.0.1/").stage()
                            == NetworkEffect.HostStage.ResponseBody,
                    "failure after the headers stays at the response-body stage");
        }
    }

    private static void javaResponseHeaderNormalization() {
        var normalized = JavaHttpAdapter.normalizeResponseHeaders(
                Map.of("X-A", List.of("é", "a"), "x-b", List.of("b")));
        check(normalized.get(0).name().equals("x-a")
                        && normalized.get(0).value().equals(ByteString.ofUnsigned(0x61)),
                "sorted header first");
        check(normalized.get(1).value().equals(ByteString.ofUnsigned(0xc3, 0xa9)),
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

    private static void cancelValidatesTheCommandCapability() throws Exception {
        var cancellation = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel-command"));
        var foreign = new NetworkEffect.CancellationCapability(
                new NetworkEffect.OpaqueEvidence("cancel-command-foreign"));
        var config = new NetworkEffect.HostConfiguration(
                n(16), n(16), Optional.of(cancellation), Optional.empty());
        for (int scenario = 0; scenario < 3; scenario++) {
            AtomicInteger calls = new AtomicInteger();
            try (Peer peer = new Peer(response(200, List.of(), new byte[0]), true);
                    JavaHttpAdapter adapter = new JavaHttpAdapter(
                            HttpClient.newHttpClient(),
                            HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                    () -> new NetworkEffect.MonotonicClockObservation(
                                            new NetworkEffect.ClockBasis("unused"), n(0))),
                            HttpPortFixtures.cancellation(cancellation,
                                    handle -> { calls.incrementAndGet(); return HttpPortFixtures.accepted(); }))) {
                Issued issued = issue(peer.target("/cancel-command-" + scenario),
                        List.of(), ByteString.empty(), config, Optional.empty());
                var startedStep = applyStart(issued, adapter.start(issued.command()));
                peer.awaitRequest();
                var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
                check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>,
                        "capability cancel command ready");
                @SuppressWarnings("unchecked")
                var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
                NetworkEffect.CancelCommand base = ready.command();
                check(base.capability().equals(cancellation), "cancel command carries the record capability");
                if (scenario == 0) {
                    var result = adapter.cancel(base);
                    check(result instanceof JavaHttpAdapter.PollResult.Delivered, "matching cancel delivered");
                    var delivered = (NetworkEffect.HostObservation.Delivered)
                            ((JavaHttpAdapter.PollResult.Delivered) result).observation();
                    check(delivered.observation() instanceof NetworkEffect.AdapterObservation.CancellationObservation,
                            "matching cancel is accepted");
                    check(calls.get() == 1, "matching cancel calls the port once");
                } else if (scenario == 1) {
                    var mutated = new NetworkEffect.CancelCommand(base.attempt(), base.handle(), foreign);
                    var result = adapter.cancel(mutated);
                    check(result instanceof JavaHttpAdapter.PollResult.Delivered, "foreign capability cancel delivered");
                    var delivered = (NetworkEffect.HostObservation.Delivered)
                            ((JavaHttpAdapter.PollResult.Delivered) result).observation();
                    check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation,
                            "foreign capability yields a failure observation");
                    var failure = (NetworkEffect.AdapterObservation.FailureObservation) delivered.observation();
                    check(failure.failure().stage() == NetworkEffect.HostStage.Cancel,
                            "foreign capability reported at cancel stage");
                    check(failure.failure().cause() instanceof NetworkEffect.HostFailure.CancellationRejected,
                            "foreign capability is a cancellation rejection");
                    check(failure.effect().equals(new NetworkEffect.EffectStatus.Unknown(
                                    NetworkEffect.UnknownEffectReason.HostFailure)),
                            "foreign capability effect reason is host failure");
                    check(calls.get() == 0, "foreign capability never reaches the port");
                    peer.awaitNoLateResponse(adapter, startedStep.started());
                } else {
                    var mutated = new NetworkEffect.CancelCommand(base.attempt(),
                            new ExecutionHandle("java-foreign-handle"), base.capability());
                    var result = adapter.cancel(mutated);
                    check(result instanceof JavaHttpAdapter.PollResult.Closed, "foreign handle is unknown");
                    check(calls.get() == 0, "foreign handle never reaches the port");
                    peer.release();
                    var late = awaitDelivered(adapter, startedStep.started());
                    check(late.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation,
                            "foreign handle does not interrupt the request");
                }
                peer.release();
            }
        }
    }

    public static void main(String[] args) throws Exception {
        try (JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var issued = issue("ftp://example.test/", List.of(), ByteString.empty(), configuration(0, 0), Optional.empty());
            check(adapter.start(issued.command()).observation() instanceof NetworkEffect.StartObservation.StartFailed,
                    "adapter preserves failed start");
        }
        loopbackSuccessPreservesBytesHeadersAndCounts();
        rawStatusesRemainResponses();
        actualFailureStimuli();
        hostFailureMatrixPreservesProvenance();
        timeoutAndDeadlineRemainDistinct();
        clockBelowTheLimitKeepsObservePending();
        clockNowExceptionIsOneHostRuntimeFailure();
        aClockFailureSeenByObserveInterruptsTheRequest();
        aClockFailureValueOnTheFirstObservationIsOneDeadlineFailure();
        aClockFailureValueOnALaterObservationIsOneDeadlineFailure();
        aCancellationRequestFailureValueIsOneCancelFailure();
        aCancellationThatFailsInterruptsTheRequest();
        clockWithAnotherBasisNeverReachesTheDeadline();
        deadlineCheckBeforeTheRequestIsSent();
        aPublicObserveAndTheWorkerQueueOneDeadlineObservation();
        startCapabilityReadExceptionIsAHostRuntimeFailure();
        cancelCapabilityReadExceptionIsACancelHostRuntimeFailure();
        deliveryOrderIgnoresSourceSequence();
        duplicateAndConflictAreDistinct();
        forgedTokensAndRetriesDoNotDispatch();
        retryAfterSettledRootDispatchesOrdinalOneAgainstAPeer();
        javaResponseHeaderNormalization();
        startChecksRunInTheFixedOrder();
        responseEffectReasonIsTheMissingProtocolWitness();
        unclassifiedFailureKeepsTheStageOfTheWorker();
        cancelValidatesTheCommandCapability();
        NetworkEffectHttpRelease.run();
        NetworkEffectHttpDrive.run();
        System.out.println("NetworkEffectHttpSmoke: OK");
    }
}
