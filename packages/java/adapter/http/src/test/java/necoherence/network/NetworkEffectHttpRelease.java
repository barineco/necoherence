// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Authenticator;
import java.net.CookieHandler;
import java.net.InetAddress;
import java.net.URI;
import java.net.ProxySelector;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.BiConsumer;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSession;
import neco.quotient.retention.ErasureDecision;
import neco.quotient.retention.RetentionReason;
import necoherence.core.Nat;
import necoherence.progression.RequestIdentity;

final class NetworkEffectHttpRelease {
    private static final AtomicLong IDENTITY = new AtomicLong();

    private record Dispatched(NetworkEffect.NetworkState state, NetworkEffect.StartedAttempt started) {}

    private static final class Peer implements AutoCloseable {
        private final ServerSocket server;
        private final Thread thread;
        private final CountDownLatch gate;
        private final AtomicInteger open = new AtomicInteger();
        private volatile boolean closing;

        Peer(boolean gated) throws IOException {
            this.gate = new CountDownLatch(gated ? 1 : 0);
            this.server = new ServerSocket(0, 128, InetAddress.getLoopbackAddress());
            this.thread = new Thread(this::serve, "java-release-peer");
            this.thread.setDaemon(true);
            this.thread.start();
        }

        String target() { return "http://127.0.0.1:" + server.getLocalPort() + "/release"; }
        void release() { gate.countDown(); }
        int openRequests() { return open.get(); }

        private void serve() {
            while (!closing) {
                try {
                    Socket socket = server.accept();
                    Thread handler = new Thread(() -> answer(socket), "java-release-peer-connection");
                    handler.setDaemon(true);
                    handler.start();
                } catch (IOException error) {
                    return;
                }
            }
        }

        private void answer(Socket socket) {
            try (socket) {
                InputStream in = socket.getInputStream();
                int matched = 0;
                while (matched < 4) {
                    int next = in.read();
                    if (next < 0) return;
                    matched = next == "\r\n\r\n".charAt(matched) ? matched + 1 : next == '\r' ? 1 : 0;
                }
                open.incrementAndGet();
                try {
                    socket.setSoTimeout(20);
                    while (!gate.await(0, TimeUnit.MILLISECONDS)) {
                        try {
                            if (in.read() < 0) return;
                        } catch (SocketTimeoutException waiting) {
                            // the request stays open until the gate opens
                        }
                    }
                    OutputStream out = socket.getOutputStream();
                    out.write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok"
                            .getBytes(StandardCharsets.ISO_8859_1));
                    out.flush();
                } finally {
                    open.decrementAndGet();
                }
            } catch (IOException | InterruptedException error) {
                // the adapter may abandon the exchange; nothing to report
            }
        }

        @Override public void close() throws IOException {
            closing = true;
            gate.countDown();
            server.close();
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static Dispatched dispatch(JavaHttpAdapter adapter, String target) {
        return dispatchWith(adapter, target, Optional.empty(), Optional.empty());
    }

    private static Dispatched dispatchWith(JavaHttpAdapter adapter, String target,
            Optional<NetworkEffect.Deadline> deadline,
            Optional<NetworkEffect.MonotonicClockCapability> clock) {
        return dispatchFull(adapter, target, deadline, clock, Optional.empty());
    }

    private static Dispatched dispatchFull(JavaHttpAdapter adapter, String target,
            Optional<NetworkEffect.Deadline> deadline,
            Optional<NetworkEffect.MonotonicClockCapability> clock,
            Optional<NetworkEffect.CancellationCapability> cancellation) {
        long identity = IDENTITY.getAndIncrement();
        var attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("http", "release-" + identity, Nat.fromLong(identity)), Nat.fromLong(0));
        var input = new NetworkEffect.AttemptInput(
                attempt,
                new NetworkEffect.HttpWireInstruction("GET", target, List.of(), ByteString.empty()),
                deadline,
                new NetworkEffect.HostConfiguration(
                        Nat.fromLong(128), Nat.fromLong(128), cancellation, clock));
        var prepared = NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), input);
        check(prepared instanceof NetworkEffect.PrepareStep.Prepared, "prepare");
        var preparedStep = (NetworkEffect.PrepareStep.Prepared) prepared;
        var commandStep = NetworkEffect.sendCommand(preparedStep.state(), preparedStep.prepared());
        check(commandStep instanceof NetworkEffect.CommandStep.CommandReady<?>, "send command");
        @SuppressWarnings("unchecked")
        var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) commandStep;
        JavaHttpAdapter.StartResult start = adapter.start(ready.command());
        check(start.started().isPresent(), "start");
        var step = NetworkEffect.observeStart(ready.state(), preparedStep.prepared(), start.observation());
        check(step instanceof NetworkEffect.NetworkStep.Started, "observe start");
        return new Dispatched(((NetworkEffect.NetworkStep.Started) step).state(), start.started().get());
    }

    private static NetworkEffect.HostObservation.Delivered awaitDelivered(
            JavaHttpAdapter adapter, NetworkEffect.StartedAttempt started) throws InterruptedException {
        for (int index = 0; index < 5_000; index++) {
            if (adapter.observe(started) instanceof JavaHttpAdapter.PollResult.Delivered delivered
                    && delivered.observation() instanceof NetworkEffect.HostObservation.Delivered value)
                return value;
            Thread.sleep(1);
        }
        throw new AssertionError("adapter delivery timeout");
    }

    private static boolean effectOutstanding(
            ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> decision) {
        return decision instanceof ErasureDecision.Retain<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> retain
                && retain.reasons().stream().anyMatch(reason -> reason instanceof RetentionReason.OutstandingEffect<?, ?, ?>);
    }

    private static ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> releaseWhenIdle(
            JavaHttpAdapter adapter, NetworkEffect.NetworkState state, NetworkEffect.StartedAttempt started)
            throws InterruptedException {
        for (int index = 0; index < 5_000; index++) {
            var decision = adapter.release(state, started);
            if (!effectOutstanding(decision)) return decision;
            Thread.sleep(1);
        }
        throw new AssertionError("worker remained running");
    }

    private static int drain(int total, int unreleased) throws Exception {
        try (Peer peer = new Peer(false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            for (int index = 0; index < total; index++) {
                Dispatched dispatched = dispatch(adapter, peer.target());
                var terminal = NetworkEffect.observe(dispatched.state(), awaitDelivered(adapter, dispatched.started()));
                check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "terminal");
                if (index >= unreleased) {
                    var decision = releaseWhenIdle(adapter,
                            ((NetworkEffect.NetworkStep.Terminal) terminal).state(), dispatched.started());
                    check(decision instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>, "release permitted");
                }
            }
            return adapter.recordCount();
        }
    }

    private static void releasedRecordsLeaveNoRegistration() throws Exception {
        check(drain(500, 0) == 0, "no registration after 500 released requests");
        check(drain(40, 3) == 3, "unreleased registrations remain");
    }

    private static void futureUseIsTheOnlyReasonBeforeTerminal() throws Exception {
        try (Peer peer = new Peer(false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Dispatched dispatched = dispatch(adapter, peer.target());
            awaitDelivered(adapter, dispatched.started());
            var decision = releaseWhenIdle(adapter, dispatched.state(), dispatched.started());
            var attempt = dispatched.started().prepared().input().attempt();
            check(decision instanceof ErasureDecision.Retain<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> retain
                            && retain.reasons().size() == 1
                            && retain.reasons().get(0) instanceof RetentionReason.FutureUse<?, ?, ?> future
                            && future.target().equals(attempt),
                    "only future use retained");
            check(adapter.recordCount() == 1, "record remains");
        }
    }

    private static void outstandingEffectIsTheOnlyReasonWhileTheWorkerRuns() throws Exception {
        try (Peer peer = new Peer(true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Dispatched dispatched = dispatch(adapter, peer.target());
            awaitRequestAtPeer(peer);
            var started = dispatched.started();
            var attempt = started.prepared().input().attempt();
            var cancelled = new NetworkEffect.HostObservation.Delivered(Nat.fromLong(0),
                    new NetworkEffect.AdapterObservation.CancellationObservation(
                            attempt, started.handle(), new NetworkEffect.SourceSequence.None(),
                            new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.Cancellation)));
            var terminal = NetworkEffect.observe(dispatched.state(), cancelled);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "cancellation reaches terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            var decision = adapter.release(state, started);
            check(decision instanceof ErasureDecision.Retain<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> retain
                            && retain.reasons().size() == 1
                            && retain.reasons().get(0) instanceof RetentionReason.OutstandingEffect<?, ?, ?> effect
                            && effect.target().equals(attempt),
                    "only outstanding effect retained");
            check(adapter.recordCount() == 1, "release leaves the request running");
            check(peer.openRequests() == 1, "release leaves the request open at the peer");
            peer.release();
            awaitRecordsRemoved(adapter, peer);
            check(releaseWhenIdle(adapter, state, started) instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                    "release permitted after the worker finished");
            check(adapter.recordCount() == 0, "record removed");
        }
    }

    private static void awaitRecordsRemoved(JavaHttpAdapter adapter, Peer peer) throws InterruptedException {
        for (int index = 0; index < 400; index++) {
            if (adapter.recordCount() == 0 && peer.openRequests() == 0) return;
            Thread.sleep(5);
        }
        throw new AssertionError("record or open request remained without release of the peer");
    }

    private static final NetworkEffect.CancellationCapability REJECTED_CANCEL =
            new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("release-rejected-cancel"));

    private static JavaHttpAdapter rejectingAdapter() {
        return new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                        () -> new NetworkEffect.MonotonicClockObservation(
                                new NetworkEffect.ClockBasis("unused"), Nat.fromLong(0))),
                HttpPortFixtures.cancellation(REJECTED_CANCEL, handle -> HttpPortFixtures.rejected()));
    }

    private static void awaitRequestAtPeer(Peer peer) throws InterruptedException {
        for (int index = 0; index < 1_000; index++) {
            if (peer.openRequests() == 1) return;
            Thread.sleep(5);
        }
        throw new AssertionError("peer never held the request");
    }

    private static NetworkEffect.HostObservation.Delivered rejectedCancel(
            JavaHttpAdapter adapter, Dispatched dispatched) {
        var cancel = NetworkEffect.cancelCommand(dispatched.state(), dispatched.started());
        check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>, "cancel command ready");
        @SuppressWarnings("unchecked")
        var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
        var result = adapter.cancel(ready.command());
        check(result instanceof JavaHttpAdapter.PollResult.Delivered, "rejected cancel delivered");
        var delivered = (NetworkEffect.HostObservation.Delivered)
                ((JavaHttpAdapter.PollResult.Delivered) result).observation();
        check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                        && failure.failure().stage() == NetworkEffect.HostStage.Cancel
                        && failure.failure().cause() instanceof NetworkEffect.HostFailure.CancellationRejected,
                "cancellation rejected at the cancel stage");
        return delivered;
    }

    private static void releaseAfterTheTerminalObservationRemovesTheRecordWithinTheLimit() throws Exception {
        try (Peer peer = new Peer(true); JavaHttpAdapter adapter = rejectingAdapter()) {
            Dispatched dispatched = dispatchFull(adapter, peer.target(), Optional.empty(), Optional.empty(),
                    Optional.of(REJECTED_CANCEL));
            awaitRequestAtPeer(peer);
            var delivered = rejectedCancel(adapter, dispatched);
            var terminal = NetworkEffect.observe(dispatched.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "rejected cancel reaches terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            var decision = adapter.release(state, dispatched.started());
            check(decision instanceof ErasureDecision.Retain<?, ?, ?, ?, ?>
                            || decision instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                    "release retains or dematerializes");
            awaitRecordsRemoved(adapter, peer);
            peer.release();
        }
    }

    private static void releaseWhileTheCoreStillAwaitsKeepsTheRecordAndNoResponseFollows() throws Exception {
        try (Peer peer = new Peer(true); JavaHttpAdapter adapter = rejectingAdapter()) {
            Dispatched dispatched = dispatchFull(adapter, peer.target(), Optional.empty(), Optional.empty(),
                    Optional.of(REJECTED_CANCEL));
            awaitRequestAtPeer(peer);
            rejectedCancel(adapter, dispatched);
            for (int index = 0; index < 400 && peer.openRequests() != 0; index++) Thread.sleep(5);
            check(peer.openRequests() == 0, "the request was closed at the peer before the release");
            check(adapter.release(dispatched.state(), dispatched.started()) instanceof ErasureDecision.Retain<?, ?, ?, ?, ?>,
                    "release retains while the core awaits");
            check(adapter.recordCount() == 1, "record remains while the core awaits");
            peer.release();
            Thread.sleep(150);
            for (int round = 0; round < 2; round++)
                check(adapter.observe(dispatched.started()) instanceof JavaHttpAdapter.PollResult.Pending,
                        "no late response is observed");
        }
    }

    private static void aRejectedCancelRightAfterTheStartNeverLeavesAResponseBehindIt() throws Exception {
        try (Peer peer = new Peer(false); JavaHttpAdapter adapter = rejectingAdapter()) {
            for (int trial = 0; trial < 200; trial++) {
                Dispatched dispatched = dispatchFull(adapter, peer.target(), Optional.empty(), Optional.empty(),
                        Optional.of(REJECTED_CANCEL));
                var cancel = NetworkEffect.cancelCommand(dispatched.state(), dispatched.started());
                check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>, "cancel command ready");
                @SuppressWarnings("unchecked")
                var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
                List<NetworkEffect.AdapterObservation> kinds = new ArrayList<>();
                var first = adapter.cancel(ready.command());
                check(first instanceof JavaHttpAdapter.PollResult.Delivered, "cancel delivered, trial " + trial);
                kinds.add(((NetworkEffect.HostObservation.Delivered)
                        ((JavaHttpAdapter.PollResult.Delivered) first).observation()).observation());
                releaseWhenIdle(adapter, dispatched.state(), dispatched.started());
                while (adapter.observe(dispatched.started()) instanceof JavaHttpAdapter.PollResult.Delivered later)
                    kinds.add(((NetworkEffect.HostObservation.Delivered) later.observation()).observation());
                boolean failureOnly = kinds.size() == 1
                        && kinds.get(0) instanceof NetworkEffect.AdapterObservation.FailureObservation;
                boolean responseThenFailure = kinds.size() == 2
                        && kinds.get(0) instanceof NetworkEffect.AdapterObservation.ResponseObservation
                        && kinds.get(1) instanceof NetworkEffect.AdapterObservation.FailureObservation;
                check(failureOnly || responseThenFailure, "no response follows the failure, trial " + trial);
            }
        }
    }

    private static void releaseWithAStateLackingTheRecordDoesNotInterrupt() throws Exception {
        try (Peer peer = new Peer(true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Dispatched dispatched = dispatch(adapter, peer.target());
            awaitRequestAtPeer(peer);
            check(adapter.release(NetworkEffect.NetworkState.empty(), dispatched.started())
                            instanceof ErasureDecision.Retain<?, ?, ?, ?, ?>,
                    "release retains for a state lacking the record");
            Thread.sleep(200);
            check(adapter.recordCount() == 1, "record remains for a state lacking the record");
            check(peer.openRequests() == 1, "request stays open for a state lacking the record");
            peer.release();
            var delivered = awaitDelivered(adapter, dispatched.started());
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.ResponseObservation,
                    "response is observed after the release");
            check(NetworkEffect.observe(dispatched.state(), delivered) instanceof NetworkEffect.NetworkStep.Terminal,
                    "observe on the proper state reaches terminal");
        }
    }

    private static void releasedHandlesAnswerClosed() throws Exception {
        try (Peer peer = new Peer(false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            Dispatched dispatched = dispatch(adapter, peer.target());
            var terminal = NetworkEffect.observe(dispatched.state(), awaitDelivered(adapter, dispatched.started()));
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            check(releaseWhenIdle(adapter, state, dispatched.started()) instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                    "release permitted");
            check(adapter.observe(dispatched.started()) instanceof JavaHttpAdapter.PollResult.Closed, "observe after release");
            var cancel = new NetworkEffect.CancelCommand(
                    dispatched.started().prepared().input().attempt(), dispatched.started().handle(),
                    new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("release")));
            check(adapter.cancel(cancel) instanceof JavaHttpAdapter.PollResult.Closed, "cancel after release");
        }
    }

    private static final class ThrowingFuture<T> extends CompletableFuture<T> {
        @Override public CompletableFuture<T> whenComplete(BiConsumer<? super T, ? super Throwable> action) {
            throw new IllegalStateException("completion registration");
        }
    }

    private static final class RegistrationFailureClient extends HttpClient {
        @Override public Optional<CookieHandler> cookieHandler() { return Optional.empty(); }
        @Override public Optional<Duration> connectTimeout() { return Optional.empty(); }
        @Override public Redirect followRedirects() { return Redirect.NEVER; }
        @Override public Optional<ProxySelector> proxy() { return Optional.empty(); }
        @Override public SSLContext sslContext() { return null; }
        @Override public SSLParameters sslParameters() { return new SSLParameters(); }
        @Override public Optional<Authenticator> authenticator() { return Optional.empty(); }
        @Override public Version version() { return Version.HTTP_1_1; }
        @Override public Optional<Executor> executor() { return Optional.empty(); }
        @Override public <T> HttpResponse<T> send(HttpRequest request, HttpResponse.BodyHandler<T> handler) {
            throw new UnsupportedOperationException();
        }
        @Override public <T> CompletableFuture<HttpResponse<T>> sendAsync(
                HttpRequest request, HttpResponse.BodyHandler<T> handler) {
            return new ThrowingFuture<>();
        }
        @Override public <T> CompletableFuture<HttpResponse<T>> sendAsync(
                HttpRequest request, HttpResponse.BodyHandler<T> handler,
                HttpResponse.PushPromiseHandler<T> pushPromiseHandler) {
            return new ThrowingFuture<>();
        }
    }

    private static final class UncancellableFuture<T> extends CompletableFuture<T> {
        @Override public boolean cancel(boolean mayInterruptIfRunning) { return false; }
    }

    private record StubResponse(HttpRequest request) implements HttpResponse<byte[]> {
        @Override public int statusCode() { return 200; }
        @Override public Optional<HttpResponse<byte[]>> previousResponse() { return Optional.empty(); }
        @Override public HttpHeaders headers() { return HttpHeaders.of(Map.of(), (name, value) -> true); }
        @Override public byte[] body() { return "ok".getBytes(StandardCharsets.ISO_8859_1); }
        @Override public Optional<SSLSession> sslSession() { return Optional.empty(); }
        @Override public URI uri() { return request.uri(); }
        @Override public HttpClient.Version version() { return HttpClient.Version.HTTP_1_1; }
    }

    private static final class HeldExchangeClient extends HttpClient {
        final UncancellableFuture<HttpResponse<byte[]>> exchange = new UncancellableFuture<>();
        volatile HttpRequest sent;
        @Override public Optional<CookieHandler> cookieHandler() { return Optional.empty(); }
        @Override public Optional<Duration> connectTimeout() { return Optional.empty(); }
        @Override public Redirect followRedirects() { return Redirect.NEVER; }
        @Override public Optional<ProxySelector> proxy() { return Optional.empty(); }
        @Override public SSLContext sslContext() { return null; }
        @Override public SSLParameters sslParameters() { return new SSLParameters(); }
        @Override public Optional<Authenticator> authenticator() { return Optional.empty(); }
        @Override public Version version() { return Version.HTTP_1_1; }
        @Override public Optional<Executor> executor() { return Optional.empty(); }
        @Override public <T> HttpResponse<T> send(HttpRequest request, HttpResponse.BodyHandler<T> handler) {
            throw new UnsupportedOperationException();
        }
        @SuppressWarnings("unchecked")
        @Override public <T> CompletableFuture<HttpResponse<T>> sendAsync(
                HttpRequest request, HttpResponse.BodyHandler<T> handler) {
            sent = request;
            return (CompletableFuture<HttpResponse<T>>) (CompletableFuture<?>) exchange;
        }
        @Override public <T> CompletableFuture<HttpResponse<T>> sendAsync(
                HttpRequest request, HttpResponse.BodyHandler<T> handler,
                HttpResponse.PushPromiseHandler<T> pushPromiseHandler) {
            return sendAsync(request, handler);
        }
    }

    private static void aWorkerResultAfterAnAdapterObservationIsNotQueued() throws Exception {
        HeldExchangeClient client = new HeldExchangeClient();
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                client,
                HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                        () -> new NetworkEffect.MonotonicClockObservation(
                                new NetworkEffect.ClockBasis("unused"), Nat.fromLong(0))),
                HttpPortFixtures.cancellation(REJECTED_CANCEL, handle -> HttpPortFixtures.rejected()))) {
            Dispatched dispatched = dispatchFull(adapter, "http://127.0.0.1:1/stub", Optional.empty(),
                    Optional.empty(), Optional.of(REJECTED_CANCEL));
            for (int index = 0; index < 1_000 && client.sent == null; index++) Thread.sleep(5);
            check(client.sent != null, "the request reached the client");
            rejectedCancel(adapter, dispatched);
            client.exchange.complete(new StubResponse(client.sent));
            Thread.sleep(150);
            for (int round = 0; round < 2; round++)
                check(adapter.observe(dispatched.started()) instanceof JavaHttpAdapter.PollResult.Pending,
                        "the worker result after the adapter observation is not queued");
        }
    }

    private static void aFailedCompletionRegistrationEndsTheWorkerAndQueuesAFailure() throws Exception {
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                new RegistrationFailureClient(),
                HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                        () -> new NetworkEffect.MonotonicClockObservation(new NetworkEffect.ClockBasis("unused"), Nat.fromLong(0))),
                HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION, handle -> HttpPortFixtures.accepted()))) {
            Dispatched dispatched = dispatch(adapter, "http://127.0.0.1:1/registration");
            var delivered = awaitDelivered(adapter, dispatched.started());
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().stage() == NetworkEffect.HostStage.ResponseHeaders
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                    "registration failure is a host runtime failure");
            var terminal = NetworkEffect.observe(dispatched.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "registration failure terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            check(releaseWhenIdle(adapter, state, dispatched.started())
                            instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                    "release permitted after the failed registration");
            check(adapter.recordCount() == 0, "record removed after the failed registration");
        }
    }

    private static void aDeadlineAlreadyReachedAtStartIsObservedOnce() throws Exception {
        var basis = new NetworkEffect.ClockBasis("once");
        var capability = new NetworkEffect.MonotonicClockCapability(
                new NetworkEffect.OpaqueEvidence("once-clock"), basis);
        var deadline = new NetworkEffect.Deadline(basis, Nat.fromLong(10), capability);
        try (JavaHttpAdapter adapter = new JavaHttpAdapter(
                HttpClient.newHttpClient(),
                HttpPortFixtures.clock(capability,
                        () -> new NetworkEffect.MonotonicClockObservation(basis, Nat.fromLong(10))),
                HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION, handle -> HttpPortFixtures.accepted()))) {
            Dispatched dispatched = dispatchWith(adapter, "http://127.0.0.1:1/once",
                    Optional.of(deadline), Optional.of(capability));
            List<JavaHttpAdapter.PollResult> observed = new ArrayList<>();
            observed.add(adapter.observe(dispatched.started()));
            Thread.sleep(200);
            observed.add(adapter.observe(dispatched.started()));
            observed.add(adapter.observe(dispatched.started()));
            long deadlines = observed.stream()
                    .filter(result -> result instanceof JavaHttpAdapter.PollResult.Delivered delivered
                            && delivered.observation() instanceof NetworkEffect.HostObservation.Delivered value
                            && value.observation() instanceof NetworkEffect.AdapterObservation.DeadlineObservation)
                    .count();
            check(deadlines == 1, "deadline observed exactly once");
        }
    }

    private static void releaseRightAfterTerminalRemovesTheRecordOverManyTrials() throws Exception {
        try (Peer peer = new Peer(false); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            for (int trial = 0; trial < 300; trial++) {
                Dispatched dispatched = dispatch(adapter, peer.target());
                var terminal = NetworkEffect.observe(dispatched.state(), awaitDelivered(adapter, dispatched.started()));
                check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "terminal");
                var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
                var decision = adapter.release(state, dispatched.started());
                check(!(decision instanceof ErasureDecision.Rejected<?, ?, ?, ?, ?>), "release not rejected");
                int waited = 0;
                while (adapter.recordCount() != 0 && waited < 5_000) {
                    Thread.sleep(1);
                    waited++;
                }
                check(adapter.recordCount() == 0, "record removed within the bound, trial " + trial);
                check(adapter.observe(dispatched.started()) instanceof JavaHttpAdapter.PollResult.Closed,
                        "observe after release answers closed, trial " + trial);
            }
        }
    }

    static void run() throws Exception {
        releaseRightAfterTerminalRemovesTheRecordOverManyTrials();
        releasedRecordsLeaveNoRegistration();
        futureUseIsTheOnlyReasonBeforeTerminal();
        outstandingEffectIsTheOnlyReasonWhileTheWorkerRuns();
        releaseAfterTheTerminalObservationRemovesTheRecordWithinTheLimit();
        releaseWhileTheCoreStillAwaitsKeepsTheRecordAndNoResponseFollows();
        aRejectedCancelRightAfterTheStartNeverLeavesAResponseBehindIt();
        aWorkerResultAfterAnAdapterObservationIsNotQueued();
        releaseWithAStateLackingTheRecordDoesNotInterrupt();
        releasedHandlesAnswerClosed();
        aFailedCompletionRegistrationEndsTheWorkerAndQueuesAFailure();
        aDeadlineAlreadyReachedAtStartIsObservedOnce();
    }
}
