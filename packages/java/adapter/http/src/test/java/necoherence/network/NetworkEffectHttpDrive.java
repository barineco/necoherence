// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import java.util.zip.GZIPInputStream;
import neco.quotient.Result;
import neco.quotient.retention.ErasureDecision;
import neco.quotient.retention.RetentionReason;
import necoherence.composition.SemanticComposition;
import necoherence.composition.SemanticExecution;
import necoherence.core.Nat;
import necoherence.progression.RequestIdentity;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import necoherence.semantic.WireJson;

final class NetworkEffectHttpDrive {
    private static final int REPEATS = 100;
    private static final String EXCHANGE = """
            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
            """;

    private static final class Peer implements AutoCloseable {
        private final ServerSocket server;
        private final Thread thread;
        private final long delayMillis;
        private final java.util.concurrent.CountDownLatch gate = new java.util.concurrent.CountDownLatch(1);
        private volatile boolean closing;
        private final java.util.concurrent.atomic.AtomicInteger heldRequests = new java.util.concurrent.atomic.AtomicInteger();

        Peer(long delayMillis) throws IOException { this(delayMillis, false); }

        Peer(long delayMillis, boolean held) throws IOException {
            this.delayMillis = delayMillis;
            if (!held) gate.countDown();
            this.server = new ServerSocket(0, 128, InetAddress.getLoopbackAddress());
            this.thread = new Thread(this::serve, "java-drive-peer");
            this.thread.setDaemon(true);
            this.thread.start();
        }

        int heldRequests() { return heldRequests.get(); }

        String target() { return "http://127.0.0.1:" + server.getLocalPort() + "/drive"; }

        private void serve() {
            while (!closing) {
                try {
                    Socket socket = server.accept();
                    Thread handler = new Thread(() -> answer(socket), "java-drive-peer-connection");
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
                Thread.sleep(delayMillis);
                heldRequests.incrementAndGet();
                Thread watcher = new Thread(() -> {
                    try { if (in.read() < 0) heldRequests.decrementAndGet(); }
                    catch (IOException closed) { heldRequests.decrementAndGet(); }
                }, "java-drive-peer-watcher");
                watcher.setDaemon(true);
                watcher.start();
                gate.await();
                OutputStream out = socket.getOutputStream();
                out.write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                        .getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
            } catch (IOException | InterruptedException error) {
                // the adapter may abandon the exchange; nothing to report
            }
        }

        void release() { gate.countDown(); }

        @Override public void close() throws IOException {
            closing = true;
            gate.countDown();
            server.close();
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static SemanticExecution.AdmittedComposition admitted() throws Exception {
        byte[] compressed = Base64.getMimeDecoder().decode(EXCHANGE);
        String exchange;
        try (var input = new GZIPInputStream(new ByteArrayInputStream(compressed))) {
            exchange = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        SemanticValues.WireValue wire = SemanticGeneration.readJson(exchange);
        return TypeSignatures.admitGeneration(
                SemanticGeneration.GenerationBasis.ofInput(wire), exchange).composition();
    }

    private static NetworkEffect.AttemptInput attemptInput(String target, Optional<NetworkEffect.Deadline> deadline) {
        return attemptInput(target, deadline, Optional.empty());
    }

    private static NetworkEffect.AttemptInput attemptInput(String target, Optional<NetworkEffect.Deadline> deadline,
            Optional<NetworkEffect.CancellationCapability> cancellation) {
        NetworkEffect.AttemptIdentity identity = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("semantic", "http", Nat.one()), Nat.zero());
        return new NetworkEffect.AttemptInput(identity,
                new NetworkEffect.HttpWireInstruction("GET", target, List.of(), ByteString.empty()),
                deadline, new NetworkEffect.HostConfiguration(Nat.fromLong(8), Nat.fromLong(8),
                        cancellation, deadline.map(NetworkEffect.Deadline::capability)));
    }

    private static SemanticExecution.Progress first(SemanticExecution.AdmittedComposition admitted, String target) {
        return first(admitted, target, Optional.empty());
    }

    private static SemanticExecution.Progress first(SemanticExecution.AdmittedComposition admitted, String target,
            Optional<NetworkEffect.Deadline> deadline) {
        return first(admitted, target, deadline, Optional.empty());
    }

    private static SemanticExecution.Progress first(SemanticExecution.AdmittedComposition admitted, String target,
            Optional<NetworkEffect.Deadline> deadline,
            Optional<NetworkEffect.CancellationCapability> cancellation) {
        SemanticComposition.FunctionRef function = admitted.prepared().input().signatures().getFirst().reference();
        SemanticComposition.OutcomeId outcome = new SemanticComposition.OutcomeId("success");
        SemanticExecution.PreparedNetworkOwner owner = new SemanticExecution.PreparedNetworkOwner(
                arguments -> new SemanticExecution.ProviderSuccess<>(
                        new SemanticExecution.Ready(attemptInput(target, deadline, cancellation))),
                response -> new SemanticExecution.ProviderSuccess<>(new SemanticExecution.CallResult(outcome, List.of(
                        new SemanticExecution.PortValue(new SemanticComposition.PortId("output"),
                                new SemanticValues.Present<JsonValue>(WireJson.fromWire(new SemanticValues.BooleanValue(true))))))));
        SemanticExecution.RunResult run = SemanticExecution.start(admitted,
                List.of(new SemanticExecution.Provider(function, new SemanticExecution.PreparedHttpProvider(owner))),
                List.of(new SemanticExecution.ArgumentValue(new SemanticComposition.InputId("argument"),
                        new SemanticValues.Present<JsonValue>(WireJson.fromWire(new SemanticValues.BooleanValue(true))))),
                NetworkEffect.NetworkState.empty());
        check(run instanceof SemanticExecution.Progressed, "start");
        return ((SemanticExecution.Progressed) run).progress();
    }

    private static SemanticExecution.ExecutionResult manual(JavaHttpAdapter adapter,
            SemanticExecution.Progress begin) throws InterruptedException {
        SemanticExecution.Progress progress = begin;
        for (;;) {
            if (progress instanceof SemanticExecution.Completed completed) return completed.result();
            SemanticExecution.Pending pending = (SemanticExecution.Pending) progress;
            SemanticExecution.ExecutionObservation observation;
            if (pending.instruction() instanceof SemanticExecution.Send send) {
                observation = new SemanticExecution.Start(adapter.start(send.command()).observation());
            } else {
                var started = ((SemanticExecution.Observe) pending.instruction()).started();
                for (;;) {
                    var observed = adapter.observe(started);
                    if (observed instanceof JavaHttpAdapter.PollResult.Delivered delivered) {
                        observation = new SemanticExecution.Host(delivered.observation());
                        break;
                    }
                    check(!(observed instanceof JavaHttpAdapter.PollResult.Closed), "closed");
                    Thread.sleep(1);
                }
            }
            SemanticExecution.RunResult resumed = SemanticExecution.resume(pending.execution(), observation);
            check(resumed instanceof SemanticExecution.Progressed, "resume");
            progress = ((SemanticExecution.Progressed) resumed).progress();
        }
    }

    private static void driveAloneLeavesNoRegistrationAndMatchesTheManualLoop() throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(0); JavaHttpAdapter reference = new JavaHttpAdapter();
                JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var expected = manual(reference, first(admitted, peer.target()));
            check(reference.recordCount() == 1, "the manual loop leaves its record");
            for (int index = 0; index < REPEATS; index++) {
                var driven = JavaHttpAdapter.drive(adapter, first(admitted, peer.target()));
                check(driven instanceof JavaHttpAdapter.DriveResult.Done, "drive completed");
                var value = ((JavaHttpAdapter.DriveResult.Done) driven).value();
                check(value.retained().isEmpty(), "nothing retained");
                check(value.result().equals(expected), "same result as the manual loop");
            }
            check(adapter.recordCount() == 0, "no registration after drive");
        }
    }

    private static long observeCalls(long delayMillis) throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(delayMillis); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var driven = JavaHttpAdapter.drive(adapter, first(admitted, peer.target()));
            check(driven instanceof JavaHttpAdapter.DriveResult.Done, "drive completed");
            check(((JavaHttpAdapter.DriveResult.Done) driven).value().retained().isEmpty(), "nothing retained");
            return adapter.observeCalls();
        }
    }

    private static void waitingDoesNotPollAtAFixedInterval() throws Exception {
        long shortWait = observeCalls(150);
        long longWait = observeCalls(300);
        check(shortWait == longWait, "observe calls do not grow with the wait");
        check(shortWait <= 2, "observe calls are bounded by instructions plus wakeups");
    }

    private static void anUnknownHandleIsTheDriveFailure() throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(0); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var begun = (SemanticExecution.Pending) first(admitted, peer.target());
            var send = (SemanticExecution.Send) begun.instruction();
            var start = adapter.start(send.command());
            var resumed = (SemanticExecution.Progressed) SemanticExecution.resume(begun.execution(),
                    new SemanticExecution.Start(start.observation()));
            var observing = (SemanticExecution.Pending) resumed.progress();
            var started = ((SemanticExecution.Observe) observing.instruction()).started();
            var stale = new NetworkEffect.StartedAttempt(started.prepared(),
                    new necoherence.progression.ExecutionHandle("never-started"));
            var failure = JavaHttpAdapter.drive(adapter,
                    new SemanticExecution.Pending(observing.execution(), new SemanticExecution.Observe(stale)));
            check(failure instanceof JavaHttpAdapter.DriveResult.Failed failed
                    && failed.failure().cause() instanceof JavaHttpAdapter.DriveCause.Unknown, "unknown handle");
        }
    }

    private static final NetworkEffect.ClockBasis SYSTEM_BASIS = new NetworkEffect.ClockBasis("system-nano");
    private static final NetworkEffect.MonotonicClockCapability SYSTEM_CAPABILITY =
            JavaHttpAdapter.SYSTEM_CLOCK_CAPABILITY;

    private static NetworkEffect.Deadline deadlineAfterMillis(long millis) {
        long limit = Math.max(0L, java.lang.System.nanoTime()) + millis * 1_000_000L;
        return new NetworkEffect.Deadline(SYSTEM_BASIS, Nat.fromLong(limit), SYSTEM_CAPABILITY);
    }

    private record Driven(JavaHttpAdapter.DriveResult result, long elapsedMillis) {}

    private static Driven driveWithin(JavaHttpAdapter adapter, SemanticExecution.Progress begin, long withinMillis)
            throws Exception {
        var box = new java.util.concurrent.ArrayBlockingQueue<Driven>(1);
        var failure = new java.util.concurrent.atomic.AtomicReference<Throwable>();
        Thread runner = new Thread(() -> {
            long began = java.lang.System.nanoTime();
            try {
                var result = JavaHttpAdapter.drive(adapter, begin);
                box.add(new Driven(result, (java.lang.System.nanoTime() - began) / 1_000_000));
            } catch (Throwable error) { failure.set(error); }
        }, "java-drive-runner");
        runner.setDaemon(true);
        runner.start();
        Driven driven = box.poll(withinMillis, java.util.concurrent.TimeUnit.MILLISECONDS);
        check(failure.get() == null, "drive threw " + failure.get());
        check(driven != null, "drive did not return within " + withinMillis + "ms");
        return driven;
    }

    private static void deadlineEndsAWaitOnAHeldPeer() throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(0, true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var deadline = deadlineAfterMillis(300);
            var driven = driveWithin(adapter, first(admitted, peer.target(), Optional.of(deadline)), 2000);
            check(driven.result() instanceof JavaHttpAdapter.DriveResult.Failed failed
                    && failed.failure().cause() instanceof JavaHttpAdapter.DriveCause.Run run
                    && run.failure().cause() instanceof SemanticExecution.NetworkTerminal terminal
                    && terminal.terminal().outcome() instanceof NetworkEffect.NetworkOutcome.DeadlineExceeded exceeded
                    && exceeded.observed().value().minusWhenOrdered(deadline.limit())
                            .compareTo(Nat.fromLong(250_000_000L)) < 0,
                    "deadline terminal observed near the limit");
            check(((JavaHttpAdapter.DriveResult.Failed) driven.result()).failure().retained().isEmpty(), "nothing retained");
            peer.release();
            long released = java.lang.System.nanoTime();
            while (adapter.recordCount() != 0) {
                check((java.lang.System.nanoTime() - released) / 1_000_000 < 2000,
                        "the record stayed after the peer was released");
                Thread.sleep(5);
            }
        }
    }

    private static void deadlineRecordCountReachesZeroWithoutReleasingThePeer() throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(0, true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var deadline = deadlineAfterMillis(300);
            driveWithin(adapter, first(admitted, peer.target(), Optional.of(deadline)), 2000);
            long returned = java.lang.System.nanoTime();
            while (adapter.recordCount() != 0) {
                long waited = (java.lang.System.nanoTime() - returned) / 1_000_000;
                if (waited >= 5000) {
                    check(false, "the record stayed with the peer unreleased");
                }
                Thread.sleep(5);
            }
        }
    }

    private static void cancelledRecordCountWithoutReleasingThePeer() throws Exception {
        var cancellation = new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("cancel"));
        try (Peer peer = new Peer(0, true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        java.net.http.HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("unused"), Nat.zero())),
                        HttpPortFixtures.cancellation(cancellation, handle -> HttpPortFixtures.accepted()))) {
            var attempt = new NetworkEffect.AttemptIdentity(
                    new RequestIdentity("semantic", "http-cancel", Nat.one()), Nat.zero());
            var input = new NetworkEffect.AttemptInput(attempt,
                    new NetworkEffect.HttpWireInstruction("GET", peer.target(), List.of(), ByteString.empty()),
                    Optional.empty(), new NetworkEffect.HostConfiguration(Nat.fromLong(8), Nat.fromLong(8),
                            Optional.of(cancellation), Optional.empty()));
            var prepared = NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), input);
            check(prepared instanceof NetworkEffect.PrepareStep.Prepared, "prepare");
            var preparedStep = (NetworkEffect.PrepareStep.Prepared) prepared;
            var send = NetworkEffect.sendCommand(preparedStep.state(), preparedStep.prepared());
            check(send instanceof NetworkEffect.CommandStep.CommandReady<?>, "send command");
            @SuppressWarnings("unchecked")
            var sendReady = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) send;
            JavaHttpAdapter.StartResult start = adapter.start(sendReady.command());
            check(start.started().isPresent(), "start");
            var step = NetworkEffect.observeStart(sendReady.state(), preparedStep.prepared(), start.observation());
            check(step instanceof NetworkEffect.NetworkStep.Started, "observe start");
            var startedStep = (NetworkEffect.NetworkStep.Started) step;
            var cancel = NetworkEffect.cancelCommand(startedStep.state(), startedStep.started());
            check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>, "cancel command ready");
            @SuppressWarnings("unchecked")
            var cancelReady = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
            awaitHeldRequests(peer, 1, 5000, "the peer received the request");
            JavaHttpAdapter.PollResult result = adapter.cancel(cancelReady.command());
            awaitHeldRequests(peer, 0, 3000, "the request stayed open at the peer after the accepted cancellation");
            check(result instanceof JavaHttpAdapter.PollResult.Delivered
                    && ((JavaHttpAdapter.PollResult.Delivered) result).observation()
                            instanceof NetworkEffect.HostObservation.Delivered, "cancel observation delivered");
            var delivered = (NetworkEffect.HostObservation.Delivered)
                    ((JavaHttpAdapter.PollResult.Delivered) result).observation();
            var terminal = NetworkEffect.observe(cancelReady.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "cancellation reaches terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            adapter.release(state, startedStep.started());
            long released = java.lang.System.nanoTime();
            while (adapter.recordCount() != 0) {
                long waited = (java.lang.System.nanoTime() - released) / 1_000_000;
                if (waited >= 5000) {
                    check(false, "the cancelled record stayed with the peer unreleased");
                }
                Thread.sleep(5);
            }
            Thread.sleep(500);
            long settle = java.lang.System.nanoTime();
            while (peer.heldRequests() != 0) {
                check((java.lang.System.nanoTime() - settle) / 1_000_000 < 3000,
                        "a request stayed open at the peer after the accepted cancellation");
                Thread.sleep(5);
            }
        }
    }

    private static void deadlineEndsTheRequestAtThePeerBeforeAnyRelease() throws Exception {
        try (Peer peer = new Peer(0, true); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var deadline = Optional.of(deadlineAfterMillis(300));
            var attempt = new NetworkEffect.AttemptIdentity(
                    new RequestIdentity("semantic", "http-deadline-manual", Nat.one()), Nat.zero());
            var input = new NetworkEffect.AttemptInput(attempt,
                    new NetworkEffect.HttpWireInstruction("GET", peer.target(), List.of(), ByteString.empty()),
                    deadline, new NetworkEffect.HostConfiguration(Nat.fromLong(8), Nat.fromLong(8),
                            Optional.empty(), deadline.map(NetworkEffect.Deadline::capability)));
            var prepared = NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), input);
            check(prepared instanceof NetworkEffect.PrepareStep.Prepared, "prepare");
            var preparedStep = (NetworkEffect.PrepareStep.Prepared) prepared;
            var send = NetworkEffect.sendCommand(preparedStep.state(), preparedStep.prepared());
            check(send instanceof NetworkEffect.CommandStep.CommandReady<?>, "send command");
            @SuppressWarnings("unchecked")
            var sendReady = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) send;
            JavaHttpAdapter.StartResult start = adapter.start(sendReady.command());
            check(start.started().isPresent(), "start");
            var step = NetworkEffect.observeStart(sendReady.state(), preparedStep.prepared(), start.observation());
            check(step instanceof NetworkEffect.NetworkStep.Started, "observe start");
            var startedStep = (NetworkEffect.NetworkStep.Started) step;
            awaitHeldRequests(peer, 1, 5000, "the peer received the request");
            long began = java.lang.System.nanoTime();
            NetworkEffect.HostObservation.Delivered delivered = null;
            while (delivered == null) {
                check((java.lang.System.nanoTime() - began) / 1_000_000 < 3000, "the deadline observation arrived");
                var observed = adapter.observe(startedStep.started());
                if (observed instanceof JavaHttpAdapter.PollResult.Delivered taken
                        && taken.observation() instanceof NetworkEffect.HostObservation.Delivered host) {
                    delivered = host;
                } else {
                    Thread.sleep(5);
                }
            }
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.DeadlineObservation,
                    "a deadline observation");
            awaitHeldRequests(peer, 0, 3000, "the request stayed open at the peer after the deadline observation");
            var terminal = NetworkEffect.observe(startedStep.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "deadline reaches terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            adapter.release(state, startedStep.started());
            long released = java.lang.System.nanoTime();
            while (adapter.recordCount() != 0) {
                check((java.lang.System.nanoTime() - released) / 1_000_000 < 5000,
                        "the record stayed with the peer unreleased");
                Thread.sleep(5);
            }
        }
    }

    private static NetworkEffect.SendCommand sendCommandFor(String target, long number) {
        var attempt = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("semantic", "http-close-" + number, Nat.fromLong(number)), Nat.zero());
        var input = new NetworkEffect.AttemptInput(attempt,
                new NetworkEffect.HttpWireInstruction("GET", target, List.of(), ByteString.empty()),
                Optional.empty(), new NetworkEffect.HostConfiguration(Nat.fromLong(8), Nat.fromLong(8),
                        Optional.empty(), Optional.empty()));
        var prepared = NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), input);
        check(prepared instanceof NetworkEffect.PrepareStep.Prepared, "prepare");
        var preparedStep = (NetworkEffect.PrepareStep.Prepared) prepared;
        var send = NetworkEffect.sendCommand(preparedStep.state(), preparedStep.prepared());
        check(send instanceof NetworkEffect.CommandStep.CommandReady<?>, "send command");
        @SuppressWarnings("unchecked")
        var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) send;
        return ready.command();
    }

    private static void awaitHeldRequests(Peer peer, int expected, long limitMillis, String message)
            throws InterruptedException {
        long began = java.lang.System.nanoTime();
        while (peer.heldRequests() != expected) {
            check((java.lang.System.nanoTime() - began) / 1_000_000 < limitMillis, message);
            Thread.sleep(5);
        }
    }

    private static void closeEndsRequestsInFlightAtThePeer() throws Exception {
        try (Peer peer = new Peer(0, true)) {
            JavaHttpAdapter adapter = new JavaHttpAdapter();
            check(adapter.start(sendCommandFor(peer.target(), 1)).started().isPresent(), "first start");
            check(adapter.start(sendCommandFor(peer.target(), 2)).started().isPresent(), "second start");
            awaitHeldRequests(peer, 2, 5000, "the peer received both requests");
            adapter.close();
            awaitHeldRequests(peer, 0, 3000, "a request stayed open at the peer after close");
            var after = adapter.start(sendCommandFor(peer.target(), 3));
            check(after.started().isEmpty()
                    && ((NetworkEffect.StartObservation.StartFailed) after.observation())
                            .failure().cause() instanceof NetworkEffect.HostFailure.HostClosed,
                    "a start after close fails with HostClosed");
            peer.release();
        }
    }

    private static void aResponseBeforeTheDeadlineCompletes() throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(100); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var driven = driveWithin(adapter, first(admitted, peer.target(), Optional.of(deadlineAfterMillis(300))), 3000);
            check(driven.result() instanceof JavaHttpAdapter.DriveResult.Done done && done.value().retained().isEmpty(),
                    "completed by the response");
            check(adapter.recordCount() == 0, "no registration after drive");
            check(adapter.observeCalls() <= 3, "observe calls are bounded with a deadline");
        }
    }

    private static void aClockWithoutAWaitLengthIsTheTypedFailure() throws Exception {
        var admitted = admitted();
        MonotonicClockPortProbe clock = new MonotonicClockPortProbe();
        try (Peer peer = new Peer(0, true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        java.net.http.HttpClient.newHttpClient(), clock,
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            var deadline = new NetworkEffect.Deadline(SYSTEM_BASIS, Nat.fromLong(300), SYSTEM_CAPABILITY);
            var driven = driveWithin(adapter, first(admitted, peer.target(), Optional.of(deadline)), 1000);
            check(driven.result() instanceof JavaHttpAdapter.DriveResult.Failed failed
                    && failed.failure().cause() instanceof JavaHttpAdapter.DriveCause.DeadlineWaitUnavailable
                    && failed.failure().retained().size() == 1, "typed failure without waiting");
        }
    }

    private static void aClockUntilExceptionEndsTheDriveWithAHostFailure() throws Exception {
        var admitted = admitted();
        JavaHttpAdapter.MonotonicClockPort clock = new JavaHttpAdapter.MonotonicClockPort() {
            @Override public NetworkEffect.MonotonicClockCapability capability() { return SYSTEM_CAPABILITY; }
            @Override public Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe() {
                return new Result.Accepted<>(new NetworkEffect.MonotonicClockObservation(SYSTEM_BASIS, Nat.zero()));
            }
            @Override public Optional<java.time.Duration> until(Nat limit) {
                throw new IllegalStateException("until failure");
            }
        };
        try (Peer peer = new Peer(0, true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        java.net.http.HttpClient.newHttpClient(), clock,
                        HttpPortFixtures.cancellation(HttpPortFixtures.UNUSED_CANCELLATION,
                                handle -> HttpPortFixtures.accepted()))) {
            var deadline = new NetworkEffect.Deadline(SYSTEM_BASIS, Nat.fromLong(300), SYSTEM_CAPABILITY);
            var driven = driveWithin(adapter, first(admitted, peer.target(), Optional.of(deadline)), 2000);
            check(driven.result() instanceof JavaHttpAdapter.DriveResult.Failed failed
                            && failed.failure().cause() instanceof JavaHttpAdapter.DriveCause.Run run
                            && run.failure().cause() instanceof SemanticExecution.NetworkTerminal terminal
                            && terminal.terminal().outcome() instanceof NetworkEffect.NetworkOutcome.Failed outcome
                            && outcome.failure().stage() == NetworkEffect.HostStage.Deadline
                            && outcome.failure().cause() instanceof NetworkEffect.HostFailure.HostRuntimeFailure,
                    "clock until exception is a deadline stage host runtime failure terminal");
            awaitHeldRequests(peer, 0, 3000, "the request stayed open at the peer after the clock failure");
            long returned = java.lang.System.nanoTime();
            while (adapter.recordCount() != 0) {
                check((java.lang.System.nanoTime() - returned) / 1_000_000 < 5000,
                        "the record stayed with the peer unreleased");
                Thread.sleep(5);
            }
            peer.release();
        }
    }

    private record Observing(SemanticExecution.Pending pending, NetworkEffect.StartedAttempt started) {
        NetworkEffect.NetworkState state() { return pending.execution().network(); }
    }

    private static Observing beginObserving(JavaHttpAdapter adapter, SemanticExecution.AdmittedComposition admitted,
            String target, Optional<NetworkEffect.CancellationCapability> cancellation) {
        var begun = (SemanticExecution.Pending) first(admitted, target, Optional.empty(), cancellation);
        var send = (SemanticExecution.Send) begun.instruction();
        var start = adapter.start(send.command());
        var resumed = (SemanticExecution.Progressed) SemanticExecution.resume(begun.execution(),
                new SemanticExecution.Start(start.observation()));
        var observing = (SemanticExecution.Pending) resumed.progress();
        return new Observing(observing, ((SemanticExecution.Observe) observing.instruction()).started());
    }

    private static final class Waiter {
        final java.util.concurrent.ArrayBlockingQueue<JavaHttpAdapter.DriveResult> results =
                new java.util.concurrent.ArrayBlockingQueue<>(1);
        volatile Throwable failure;
        Thread thread;
    }

    private static Waiter spawnWaiter(JavaHttpAdapter adapter, Observing observing) throws InterruptedException {
        long baseline = adapter.observeCalls();
        Waiter waiter = new Waiter();
        waiter.thread = new Thread(() -> {
            try { waiter.results.add(JavaHttpAdapter.drive(adapter, observing.pending())); }
            catch (Throwable error) { waiter.failure = error; }
        }, "java-drive-waiter");
        waiter.thread.setDaemon(true);
        waiter.thread.start();
        long began = java.lang.System.nanoTime();
        while (adapter.observeCalls() <= baseline || waiter.thread.getState() != Thread.State.WAITING) {
            check(waiter.failure == null, "the waiter threw " + waiter.failure);
            check((java.lang.System.nanoTime() - began) / 1_000_000 < 5000, "the waiter never started waiting");
            Thread.sleep(1);
        }
        return waiter;
    }

    private static void checkWaiterReturnsClosed(Waiter waiter) throws InterruptedException {
        var result = waiter.results.poll(5, java.util.concurrent.TimeUnit.SECONDS);
        check(waiter.failure == null, "the waiter threw " + waiter.failure);
        check(result != null, "the waiter did not return within the limit");
        check(result instanceof JavaHttpAdapter.DriveResult.Failed failed
                        && failed.failure().cause() instanceof JavaHttpAdapter.DriveCause.Unknown,
                "the waiter returned the unknown handle");
    }

    private static void aWaiterReturnsClosedWhenTheWorkerEndsAfterASettledRelease() throws Exception {
        var admitted = admitted();
        var capability = new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("waiter-cancel"));
        try (Peer peer = new Peer(0, true);
                JavaHttpAdapter adapter = new JavaHttpAdapter(
                        java.net.http.HttpClient.newHttpClient(),
                        HttpPortFixtures.clock(HttpPortFixtures.UNUSED_CLOCK,
                                () -> new NetworkEffect.MonotonicClockObservation(
                                        new NetworkEffect.ClockBasis("unused"), Nat.zero())),
                        HttpPortFixtures.cancellation(capability, handle -> HttpPortFixtures.rejected()))) {
            var observing = beginObserving(adapter, admitted, peer.target(), Optional.of(capability));
            awaitHeldRequests(peer, 1, 5000, "the peer received the request");
            var cancel = NetworkEffect.cancelCommand(observing.state(), observing.started());
            check(cancel instanceof NetworkEffect.CommandStep.CommandReady<?>, "cancel command ready");
            @SuppressWarnings("unchecked")
            var ready = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.CancelCommand>) cancel;
            var rejected = adapter.cancel(ready.command());
            check(rejected instanceof JavaHttpAdapter.PollResult.Delivered, "rejected cancel delivered");
            var delivered = (NetworkEffect.HostObservation.Delivered)
                    ((JavaHttpAdapter.PollResult.Delivered) rejected).observation();
            check(delivered.observation() instanceof NetworkEffect.AdapterObservation.FailureObservation failure
                            && failure.failure().cause() instanceof NetworkEffect.HostFailure.CancellationRejected,
                    "cancellation rejected");
            var terminal = NetworkEffect.observe(observing.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "rejected cancel reaches terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            Waiter waiter = spawnWaiter(adapter, observing);
            var decision = adapter.release(state, observing.started());
            check(decision instanceof ErasureDecision.Retain<?, ?, ?, ?, ?>
                            || decision instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                    "release retains or dematerializes");
            checkWaiterReturnsClosed(waiter);
            check(adapter.recordCount() == 0, "the record was removed");
        }
    }

    private static boolean effectOutstanding(
            ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> decision) {
        return decision instanceof ErasureDecision.Retain<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> retain
                && retain.reasons().stream().anyMatch(reason -> reason instanceof RetentionReason.OutstandingEffect<?, ?, ?>);
    }

    private static void aWaiterReturnsClosedWhenAFinishedWorkerIsReleasedAndDematerialized() throws Exception {
        var admitted = admitted();
        try (Peer peer = new Peer(0); JavaHttpAdapter adapter = new JavaHttpAdapter()) {
            var observing = beginObserving(adapter, admitted, peer.target(), Optional.empty());
            NetworkEffect.HostObservation.Delivered delivered = null;
            for (int index = 0; index < 5000 && delivered == null; index++) {
                if (adapter.observe(observing.started()) instanceof JavaHttpAdapter.PollResult.Delivered taken
                        && taken.observation() instanceof NetworkEffect.HostObservation.Delivered host) {
                    delivered = host;
                } else {
                    Thread.sleep(1);
                }
            }
            check(delivered != null, "the response arrived");
            var terminal = NetworkEffect.observe(observing.state(), delivered);
            check(terminal instanceof NetworkEffect.NetworkStep.Terminal, "response reaches terminal");
            var state = ((NetworkEffect.NetworkStep.Terminal) terminal).state();
            long began = java.lang.System.nanoTime();
            while (effectOutstanding(adapter.release(observing.state(), observing.started()))) {
                check((java.lang.System.nanoTime() - began) / 1_000_000 < 5000, "the worker kept running");
                Thread.sleep(1);
            }
            Waiter waiter = spawnWaiter(adapter, observing);
            check(adapter.release(state, observing.started()) instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>,
                    "release dematerializes");
            checkWaiterReturnsClosed(waiter);
            check(adapter.recordCount() == 0, "the record was removed");
        }
    }

    private static final class MonotonicClockPortProbe implements JavaHttpAdapter.MonotonicClockPort {
        @Override public NetworkEffect.MonotonicClockCapability capability() { return SYSTEM_CAPABILITY; }
        @Override public Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe() {
            return new Result.Accepted<>(new NetworkEffect.MonotonicClockObservation(SYSTEM_BASIS, Nat.zero()));
        }
    }

    static void run() throws Exception {
        driveAloneLeavesNoRegistrationAndMatchesTheManualLoop();
        waitingDoesNotPollAtAFixedInterval();
        anUnknownHandleIsTheDriveFailure();
        deadlineEndsAWaitOnAHeldPeer();
        deadlineRecordCountReachesZeroWithoutReleasingThePeer();
        cancelledRecordCountWithoutReleasingThePeer();
        deadlineEndsTheRequestAtThePeerBeforeAnyRelease();
        closeEndsRequestsInFlightAtThePeer();
        aResponseBeforeTheDeadlineCompletes();
        aClockWithoutAWaitLengthIsTheTypedFailure();
        aClockUntilExceptionEndsTheDriveWithAHostFailure();
        aWaiterReturnsClosedWhenTheWorkerEndsAfterASettledRelease();
        aWaiterReturnsClosedWhenAFinishedWorkerIsReleasedAndDematerialized();
    }
}
