// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.net.ConnectException;
import java.net.ProtocolException;
import java.net.UnknownHostException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import neco.quotient.Result;
import neco.quotient.retention.ErasureDecision;
import necoherence.composition.SemanticExecution;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;
import necoherence.semantic.SemanticValues;

public final class JavaHttpAdapter implements AutoCloseable {
    interface MonotonicClockPort {
        NetworkEffect.MonotonicClockCapability capability();
        Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe();
        default Optional<Duration> until(Nat limit) { return Optional.empty(); }
    }
    interface CancellationPort {
        NetworkEffect.CancellationCapability capability();
        Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle);
    }
    static final NetworkEffect.MonotonicClockCapability SYSTEM_CLOCK_CAPABILITY =
            new NetworkEffect.MonotonicClockCapability(
                    new NetworkEffect.OpaqueEvidence("java-system-monotonic-clock"),
                    new NetworkEffect.ClockBasis("system-nano"));
    static final NetworkEffect.CancellationCapability COOPERATIVE_CANCELLATION_CAPABILITY =
            new NetworkEffect.CancellationCapability(
                    new NetworkEffect.OpaqueEvidence("java-cooperative-cancellation"));
    interface WorkerFactory { ExecutorService create(NetworkEffect.PreparedAttempt prepared); }
    interface WorkerHook { void beforeSend(); }
    public record StartResult(NetworkEffect.StartObservation observation, Optional<NetworkEffect.StartedAttempt> started) {
        public StartResult { started = started == null ? Optional.empty() : started; }
        public static StartResult started(NetworkEffect.StartedAttempt value) {
            return new StartResult(new NetworkEffect.StartObservation.Started(value.prepared().input().attempt(), value.handle()), Optional.of(value));
        }
        public static StartResult failed(NetworkEffect.StartObservation.StartFailed value) { return new StartResult(value, Optional.empty()); }
    }
    public sealed interface PollResult permits PollResult.Pending, PollResult.Delivered, PollResult.Closed {
        record Pending(NetworkEffect.HostObservation observation) implements PollResult {}
        record Delivered(NetworkEffect.HostObservation observation) implements PollResult {}
        record Closed(NetworkEffect.HostObservation observation) implements PollResult {}
    }

    private static final Duration MAXIMUM_WAIT = Duration.ofDays(365);
    private record Envelope(Nat delivery, NetworkEffect.AdapterObservation observation) {}
    private final HttpClient client;
    private final MonotonicClockPort clock;
    private final CancellationPort cancellation;
    private final WorkerFactory workerFactory;
    private final WorkerHook workerHook;
    private final AtomicLong handleOrdinal = new AtomicLong();
    private final AtomicLong observeCalls = new AtomicLong();
    private final ConcurrentHashMap<ExecutionHandle, Job> jobs = new ConcurrentHashMap<>();
    private volatile boolean closed;

    private enum Lifecycle { RUNNING, RUNNING_SETTLED, FINISHED, RELEASED }

    private final class Job {
        final NetworkEffect.PreparedAttempt prepared;
        final ExecutionHandle handle;
        final ConcurrentLinkedQueue<Envelope> queue = new ConcurrentLinkedQueue<>();
        final AtomicLong deliveryCounter = new AtomicLong();
        final ExecutorService worker;
        volatile Future<?> future;
        volatile CompletableFuture<HttpResponse<byte[]>> pending;
        volatile boolean deadlineDelivered;
        final Object signal = new Object();
        final Object deadlineLock = new Object();
        final Object publication = new Object();
        boolean observed;
        final AtomicReference<Lifecycle> lifecycle = new AtomicReference<>(Lifecycle.RUNNING);
        volatile boolean stopped;
        volatile NetworkEffect.HostStage stage = NetworkEffect.HostStage.RequestWrite;

        Job(NetworkEffect.PreparedAttempt prepared, ExecutionHandle handle) {
            this.prepared = prepared;
            this.handle = handle;
            this.worker = workerFactory.create(prepared);
        }
        boolean running() {
            CompletableFuture<HttpResponse<byte[]>> exchange = pending;
            Future<?> submitted = future;
            return exchange != null
                    ? !exchange.isDone()
                    : submitted != null && !submitted.isDone();
        }
        boolean active() {
            Lifecycle current = lifecycle.get();
            return current == Lifecycle.RUNNING || current == Lifecycle.RUNNING_SETTLED;
        }
        boolean isReleased() {
            return lifecycle.get() == Lifecycle.RELEASED;
        }
        void enqueue(NetworkEffect.AdapterObservation observation) {
            queue.add(new Envelope(Nat.fromLong(deliveryCounter.getAndIncrement()), observation));
            wake();
        }
        void publish(NetworkEffect.AdapterObservation observation) {
            synchronized (publication) {
                enqueue(observation);
                observed = true;
                stop();
            }
        }
        void enqueueResult(NetworkEffect.AdapterObservation observation) {
            synchronized (publication) {
                if (!observed) enqueue(observation);
            }
        }
        void wake() {
            synchronized (signal) { signal.notifyAll(); }
        }
        void awaitQueuedOrReleased() throws InterruptedException {
            synchronized (signal) {
                while (queue.isEmpty() && !isReleased()) signal.wait();
            }
        }
        void awaitQueuedOrReleased(Duration bound) throws InterruptedException {
            Duration capped = bound.compareTo(MAXIMUM_WAIT) > 0 ? MAXIMUM_WAIT : bound;
            long end = java.lang.System.nanoTime() + Math.max(1_000_000L, capped.toNanos());
            synchronized (signal) {
                while (queue.isEmpty() && !isReleased()) {
                    long remaining = end - java.lang.System.nanoTime();
                    if (remaining <= 0) return;
                    signal.wait(remaining / 1_000_000L, (int) (remaining % 1_000_000L));
                }
            }
        }
        void detach() {
            jobs.remove(handle);
            wake();
        }
        void ended() {
            Lifecycle previous = lifecycle.getAndUpdate(current -> switch (current) {
                case RUNNING -> Lifecycle.FINISHED;
                case RUNNING_SETTLED -> Lifecycle.RELEASED;
                case FINISHED, RELEASED -> current;
            });
            if (previous == Lifecycle.RUNNING_SETTLED) detach();
        }
        Lifecycle settle() {
            return lifecycle.getAndUpdate(current -> switch (current) {
                case RUNNING -> Lifecycle.RUNNING_SETTLED;
                case FINISHED -> Lifecycle.RELEASED;
                case RUNNING_SETTLED, RELEASED -> current;
            });
        }
        boolean discard() {
            return lifecycle.getAndSet(Lifecycle.RELEASED) != Lifecycle.RELEASED;
        }
        void stop() {
            stopped = true;
            worker.shutdownNow();
            Future<?> submitted = future;
            if (submitted != null) submitted.cancel(true);
            if (pending != null) pending.cancel(true);
            if (pending == null && submitted != null && submitted.isCancelled()) ended();
        }
    }

    public JavaHttpAdapter() {
        this(HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build(),
                new SystemClock(), new CooperativeCancellation(),
                JavaHttpAdapter::sharedWorker, () -> {});
    }
    JavaHttpAdapter(HttpClient client, MonotonicClockPort clock, CancellationPort cancellation) {
        this(client, clock, cancellation, JavaHttpAdapter::sharedWorker, () -> {});
    }
    JavaHttpAdapter(HttpClient client, MonotonicClockPort clock, CancellationPort cancellation,
            WorkerFactory workerFactory, WorkerHook workerHook) {
        this.client = client;
        this.clock = clock;
        this.cancellation = cancellation;
        this.workerFactory = workerFactory;
        this.workerHook = workerHook;
    }
    private static ExecutorService sharedWorker(NetworkEffect.PreparedAttempt prepared) {
        return ForkJoinPool.commonPool();
    }

    public StartResult start(NetworkEffect.SendCommand command) {
        NetworkEffect.PreparedAttempt prepared = command.prepared();
        if (closed)
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.HostClosed()));
        NetworkEffect.AttemptInput input = prepared.input();
        URI target;
        try { target = URI.create(input.instruction().target()); }
        catch (IllegalArgumentException error) {
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.UnsupportedUriScheme()));
        }
        if (!"http".equalsIgnoreCase(target.getScheme())
                && !"https".equalsIgnoreCase(target.getScheme()))
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.UnsupportedUriScheme()));
        if (!acceptedByCore(input))
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.InvalidHostConfiguration()));
        try {
            if (input.deadline().isPresent()
                    && !clock.capability().equals(input.deadline().get().capability()))
                return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                        new NetworkEffect.HostFailure.DeadlineControlUnavailable()));
            if (input.configuration().cancellation().isPresent()
                    && !cancellation.capability().equals(input.configuration().cancellation().get()))
                return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                        new NetworkEffect.HostFailure.InvalidHostConfiguration()));
        } catch (RuntimeException error) {
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.HostRuntimeFailure()));
        }
        ExecutionHandle handle =
                new ExecutionHandle("java-" + handleOrdinal.getAndIncrement());
        Job job;
        try {
            job = new Job(prepared, handle);
            jobs.put(handle, job);
            job.future = job.worker.submit(() -> execute(job, target));
        } catch (RuntimeException error) {
            jobs.remove(handle);
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.ExecutionStartFailed()));
        }
        return StartResult.started(new NetworkEffect.StartedAttempt(prepared, handle));
    }

    private static boolean acceptedByCore(NetworkEffect.AttemptInput input) {
        NetworkEffect.AttemptInput root = new NetworkEffect.AttemptInput(
                new NetworkEffect.AttemptIdentity(input.attempt().logical(), Nat.zero()),
                input.instruction(), input.deadline(), input.configuration());
        return NetworkEffect.prepare(NetworkEffect.NetworkState.empty(), root)
                instanceof NetworkEffect.PrepareStep.Prepared;
    }

    public PollResult observe(NetworkEffect.StartedAttempt started) {
        observeCalls.incrementAndGet();
        Job job = jobs.get(started.handle());
        if (job == null) return new PollResult.Closed(new NetworkEffect.HostObservation.Pending(started.prepared().input().attempt(), started.handle()));
        Envelope envelope = job.queue.poll();
        if (envelope != null) return new PollResult.Delivered(new NetworkEffect.HostObservation.Delivered(envelope.delivery(), envelope.observation()));
        checkDeadline(job);
        envelope = job.queue.poll();
        if (envelope != null) return new PollResult.Delivered(new NetworkEffect.HostObservation.Delivered(envelope.delivery(), envelope.observation()));
        return new PollResult.Pending(new NetworkEffect.HostObservation.Pending(started.prepared().input().attempt(), started.handle()));
    }

    public PollResult cancel(NetworkEffect.CancelCommand command) {
        Job job = jobs.get(command.handle());
        if (job == null || !job.prepared.input().attempt().equals(command.attempt()))
            return new PollResult.Closed(new NetworkEffect.HostObservation.Pending(command.attempt(), command.handle()));
        boolean accepted;
        NetworkEffect.HostFailure rejection = new NetworkEffect.HostFailure.CancellationRejected();
        try {
            if (command.capability().equals(cancellation.capability())) {
                Result<SemanticValues.Unit, NetworkEffect.HostFailure> requested = cancellation.request(command.handle());
                accepted = requested instanceof Result.Accepted<SemanticValues.Unit, NetworkEffect.HostFailure>;
                if (requested instanceof Result.Rejected<SemanticValues.Unit, NetworkEffect.HostFailure> failed)
                    rejection = failed.error();
            } else {
                accepted = false;
            }
        }
        catch (RuntimeException error) {
            accepted = false;
            rejection = new NetworkEffect.HostFailure.HostRuntimeFailure();
        }
        if (!accepted) {
            NetworkEffect.NetworkHostFailure failure = new NetworkEffect.NetworkHostFailure(
                    command.attempt(), stageForCause(NetworkEffect.HostStage.Cancel, rejection),
                    job.prepared.input().configuration(),
                    rejection);
            job.publish(new NetworkEffect.AdapterObservation.FailureObservation(
                    command.attempt(), command.handle(),
                    new NetworkEffect.SourceSequence.None(), failure,
                    unknown(NetworkEffect.UnknownEffectReason.HostFailure)));
            return observe(commandToStarted(job));
        }
        job.publish(new NetworkEffect.AdapterObservation.CancellationObservation(
                command.attempt(), command.handle(),
                new NetworkEffect.SourceSequence.None(),
                unknown(NetworkEffect.UnknownEffectReason.Cancellation)));
        return observe(commandToStarted(job));
    }

    public ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> release(
            NetworkEffect.NetworkState state, NetworkEffect.StartedAttempt started) {
        NetworkEffect.AttemptIdentity attempt = started.prepared().input().attempt();
        Job job = jobs.get(started.handle());
        boolean running = job != null && job.active();
        ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> decision =
                NetworkEffect.releaseHostRecord(state, key -> running, attempt);
        if (job != null && decision instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>) {
            if (job.discard()) job.detach();
        } else if (job != null
                && decision instanceof ErasureDecision.Retain<?, ?, ?, ?, ?>
                && NetworkEffect.hostSettled(state, attempt)) {
            if (job.settle() == Lifecycle.FINISHED) job.detach();
        }
        return decision;
    }

    private PollResult awaitObservation(NetworkEffect.StartedAttempt started)
            throws InterruptedException, DeadlineWaitUnavailableSignal {
        for (;;) {
            PollResult observed = observe(started);
            if (!(observed instanceof PollResult.Pending)) return observed;
            Job job = jobs.get(started.handle());
            if (job == null) return new PollResult.Closed(hostOf(observed));
            if (job.prepared.input().deadline().isEmpty() || job.deadlineDelivered) {
                job.awaitQueuedOrReleased();
            } else {
                Optional<Duration> wait;
                try {
                    wait = clock.until(job.prepared.input().deadline().get().limit());
                } catch (RuntimeException error) {
                    enqueueClockFailure(job, new NetworkEffect.HostFailure.HostRuntimeFailure());
                    continue;
                }
                Duration length = wait.orElseThrow(() -> new DeadlineWaitUnavailableSignal(started));
                job.awaitQueuedOrReleased(length);
            }
        }
    }

    private static final class DeadlineWaitUnavailableSignal extends Exception {
        private static final long serialVersionUID = 1L;
        private final transient NetworkEffect.StartedAttempt started;
        DeadlineWaitUnavailableSignal(NetworkEffect.StartedAttempt started) {
            super("DeadlineWaitUnavailable", null, false, false);
            this.started = started;
        }
        NetworkEffect.StartedAttempt started() { return started; }
    }

    public record Driven(SemanticExecution.ExecutionResult result, List<NetworkEffect.StartedAttempt> retained) {
        public Driven { retained = List.copyOf(retained); }
    }

    public sealed interface DriveCause permits DriveCause.Run, DriveCause.Unknown, DriveCause.DeadlineWaitUnavailable {
        record Run(SemanticExecution.RunFailure failure) implements DriveCause {}
        record Unknown(PollResult.Closed closed) implements DriveCause {}
        record DeadlineWaitUnavailable(NetworkEffect.StartedAttempt started) implements DriveCause {}
    }

    public record DriveFailure(DriveCause cause, List<NetworkEffect.StartedAttempt> retained) {
        public DriveFailure { retained = List.copyOf(retained); }
    }

    public sealed interface DriveResult permits DriveResult.Done, DriveResult.Failed {
        record Done(Driven value) implements DriveResult {}
        record Failed(DriveFailure failure) implements DriveResult {}
    }

    private static NetworkEffect.HostObservation hostOf(PollResult result) {
        return switch (result) {
            case PollResult.Pending pending -> pending.observation();
            case PollResult.Delivered delivered -> delivered.observation();
            case PollResult.Closed closed -> closed.observation();
        };
    }

    private static boolean released(ErasureDecision<?, ?, ?, ?, ?> decision) {
        return decision instanceof ErasureDecision.Dematerialize<?, ?, ?, ?, ?>;
    }

    private List<NetworkEffect.StartedAttempt> sweep(NetworkEffect.NetworkState state,
            List<NetworkEffect.StartedAttempt> candidates) {
        List<NetworkEffect.StartedAttempt> remaining = new ArrayList<>();
        for (NetworkEffect.StartedAttempt started : candidates)
            if (!released(release(state, started))) remaining.add(started);
        return remaining;
    }

    private List<NetworkEffect.StartedAttempt> finish(NetworkEffect.NetworkState state,
            List<NetworkEffect.StartedAttempt> candidates) throws InterruptedException {
        List<NetworkEffect.StartedAttempt> remaining = new ArrayList<>();
        for (NetworkEffect.StartedAttempt started : candidates) {
            ErasureDecision<NetworkEffect.AttemptIdentity, Void, Void, Void, NetworkEffect.HostRecordObservation> decision =
                    release(state, started);
            if (released(decision)) continue;
            if (decision instanceof ErasureDecision.Retain<?, ?, ?, ?, ?>
                    && NetworkEffect.hostSettled(state, started.prepared().input().attempt())) {
                continue;
            }
            remaining.add(started);
        }
        return remaining;
    }

    public static DriveResult drive(JavaHttpAdapter adapter, SemanticExecution.Progress first)
            throws InterruptedException {
        List<NetworkEffect.StartedAttempt> candidates = new ArrayList<>();
        SemanticExecution.Progress progress = first;
        for (;;) {
            if (progress instanceof SemanticExecution.Completed completed)
                return new DriveResult.Done(new Driven(completed.result(),
                        adapter.finish(completed.network(), candidates)));
            SemanticExecution.Pending pending = (SemanticExecution.Pending) progress;
            SemanticExecution.ExecutionObservation observation;
            NetworkEffect.StartedAttempt handled;
            if (pending.instruction() instanceof SemanticExecution.Send send) {
                StartResult start = adapter.start(send.command());
                handled = start.started().orElse(null);
                observation = new SemanticExecution.Start(start.observation());
            } else {
                handled = ((SemanticExecution.Observe) pending.instruction()).started();
                PollResult observed;
                try { observed = adapter.awaitObservation(handled); }
                catch (DeadlineWaitUnavailableSignal unavailable) {
                    return new DriveResult.Failed(new DriveFailure(
                            new DriveCause.DeadlineWaitUnavailable(unavailable.started()),
                            adapter.finish(pending.execution().network(), candidates)));
                }
                if (observed instanceof PollResult.Closed closed)
                    return new DriveResult.Failed(new DriveFailure(new DriveCause.Unknown(closed),
                            adapter.finish(pending.execution().network(), candidates)));
                observation = new SemanticExecution.Host(hostOf(observed));
            }
            SemanticExecution.RunResult resumed = SemanticExecution.resume(pending.execution(), observation);
            if (handled != null && candidates.stream().noneMatch(known -> known.handle().equals(handled.handle())))
                candidates.add(handled);
            if (resumed instanceof SemanticExecution.RunRejected rejected)
                return new DriveResult.Failed(new DriveFailure(new DriveCause.Run(rejected.failure()),
                        adapter.finish(rejected.failure().network(), candidates)));
            progress = ((SemanticExecution.Progressed) resumed).progress();
            NetworkEffect.NetworkState state = progress instanceof SemanticExecution.Completed completed
                    ? completed.network() : ((SemanticExecution.Pending) progress).execution().network();
            candidates = adapter.sweep(state, candidates);
        }
    }

    int recordCount() { return jobs.size(); }
    long observeCalls() { return observeCalls.get(); }

    private NetworkEffect.StartedAttempt commandToStarted(Job job) { return new NetworkEffect.StartedAttempt(job.prepared, job.handle); }

    private void execute(Job job, URI target) {
        AtomicBoolean responseHeadersReceived = new AtomicBoolean();
        boolean completionRegistered = false;
        NetworkEffect.AttemptInput input = job.prepared.input();
        try {
            checkDeadline(job);
            if (job.deadlineDelivered) return;
            HttpRequest request;
            try {
                HttpRequest.Builder builder = HttpRequest.newBuilder(target).method(input.instruction().method(),
                        HttpRequest.BodyPublishers.ofByteArray(toBytes(input.instruction().body())));
                for (NetworkEffect.RawHeaderField header : input.instruction().headers()) {
                    if (!isVisibleAscii(header.value())) {
                        enqueueFailure(job, NetworkEffect.HostStage.RequestWrite,
                                new NetworkEffect.HostFailure.RequestHeaderEncodingUnavailable());
                        return;
                    }
                    builder.header(header.name(), ascii(header.value()));
                }
                request = builder.build();
            } catch (IllegalArgumentException error) {
                enqueueFailure(job, NetworkEffect.HostStage.RequestWrite,
                        new NetworkEffect.HostFailure.RequestHeaderEncodingUnavailable());
                return;
            }
            workerHook.beforeSend();
            job.stage = NetworkEffect.HostStage.ResponseHeaders;
            job.pending = client.sendAsync(request, information -> {
                responseHeadersReceived.set(true);
                job.stage = NetworkEffect.HostStage.ResponseBody;
                return HttpResponse.BodySubscribers.ofByteArray();
            });
            if (job.stopped) job.pending.cancel(true);
            job.pending.whenComplete((response, error) -> {
                try { onExchangeComplete(job, response, error, responseHeadersReceived); }
                finally {
                    job.wake();
                    job.ended();
                }
            });
            completionRegistered = true;
        } catch (RuntimeException error) {
            enqueueFailure(job, job.stage, new NetworkEffect.HostFailure.HostRuntimeFailure());
        } finally {
            job.worker.shutdown();
            job.wake();
            if (!completionRegistered) job.ended();
        }
    }

    private void onExchangeComplete(Job job, HttpResponse<byte[]> response, Throwable error,
            AtomicBoolean responseHeadersReceived) {
        if (error == null) {
            ByteString body = fromBytes(response.body());
            if (Nat.fromLong(body.size()).compareTo(
                    job.prepared.input().configuration().responseBodyLimit()) > 0) {
                enqueueFailure(job, NetworkEffect.HostStage.ResponseBody,
                        new NetworkEffect.HostFailure.ResponseBodyLimitExceeded());
                return;
            }
            List<NetworkEffect.RawHeaderField> headers;
            try { headers = responseHeaders(response.headers().map()); }
            catch (HeaderEncodingException headerError) {
                enqueueFailure(job, NetworkEffect.HostStage.ResponseHeaders,
                        new NetworkEffect.HostFailure.HeaderRepresentationUnavailable());
                return;
            }
            if (response.statusCode() < 100 || response.statusCode() > 999) {
                enqueueFailure(job, NetworkEffect.HostStage.ResponseHeaders,
                        new NetworkEffect.HostFailure.MalformedResponse());
                return;
            }
            job.enqueueResult(new NetworkEffect.AdapterObservation.ResponseObservation(
                    job.prepared.input().attempt(), job.handle,
                    new NetworkEffect.SourceSequence.None(),
                    new NetworkEffect.RawHttpResponse(
                            response.statusCode(), headers, body),
                    NetworkEffect.HeaderProvenance.LibraryNormalized,
                    unknown(NetworkEffect.UnknownEffectReason.ProtocolWitnessMissing)));
            return;
        }
        if (job.pending.isCancelled()) return;
        Throwable cause = error instanceof java.util.concurrent.CompletionException && error.getCause() != null
                ? error.getCause() : error;
        if (cause instanceof java.util.concurrent.CancellationException) return;
        if (cause instanceof HttpTimeoutException) {
            enqueueFailure(job, NetworkEffect.HostStage.ResponseHeaders,
                    new NetworkEffect.HostFailure.Timeout(
                            NetworkEffect.HostStage.ResponseHeaders,
                            NetworkEffect.HostTimeoutCause.LibraryReported));
        } else if (cause instanceof InterruptedException) {
            Thread.currentThread().interrupt();
            enqueueFailure(job, NetworkEffect.HostStage.RequestWrite,
                    new NetworkEffect.HostFailure.HostClosed());
        } else if (cause instanceof java.io.IOException ioError) {
            if (hasCause(ioError, UnknownHostException.class))
                enqueueFailure(job, NetworkEffect.HostStage.Start,
                        new NetworkEffect.HostFailure.NameResolutionFailed());
            else if (hasCause(ioError, ConnectException.class))
                enqueueFailure(job, NetworkEffect.HostStage.Start,
                        new NetworkEffect.HostFailure.ConnectionFailed());
            else if (hasCause(ioError, ProtocolException.class))
                enqueueFailure(job, NetworkEffect.HostStage.ResponseHeaders,
                        new NetworkEffect.HostFailure.MalformedResponse());
            else if (responseHeadersReceived.get())
                enqueueFailure(job, NetworkEffect.HostStage.ResponseBody,
                        new NetworkEffect.HostFailure.ResponseBodyFailed());
            else
                enqueueFailure(job, NetworkEffect.HostStage.ResponseHeaders,
                        new NetworkEffect.HostFailure.ResponseHeadersFailed());
        } else {
            enqueueFailure(job, job.stage, new NetworkEffect.HostFailure.HostRuntimeFailure());
        }
    }

    private void checkDeadline(Job job) {
        synchronized (job.deadlineLock) {
            if (job.deadlineDelivered || job.prepared.input().deadline().isEmpty()) return;
            NetworkEffect.Deadline deadline = job.prepared.input().deadline().get();
            NetworkEffect.MonotonicClockObservation observed;
            try {
                Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> result = clock.observe();
                if (result instanceof Result.Rejected<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> failed) {
                    enqueueClockFailure(job, failed.error());
                    return;
                }
                observed = ((Result.Accepted<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure>) result).value();
            } catch (RuntimeException error) {
                enqueueClockFailure(job, new NetworkEffect.HostFailure.HostRuntimeFailure());
                return;
            }
            if (deadline.clockBasis().equals(observed.clockBasis()) && deadline.limit().compareTo(observed.value()) <= 0) {
                job.deadlineDelivered = true;
                job.publish(new NetworkEffect.AdapterObservation.DeadlineObservation(
                        job.prepared.input().attempt(), job.handle,
                        new NetworkEffect.SourceSequence.None(), deadline, observed,
                        unknown(NetworkEffect.UnknownEffectReason.Deadline)));
            }
        }
    }

    private void enqueueClockFailure(Job job, NetworkEffect.HostFailure cause) {
        synchronized (job.deadlineLock) {
            if (job.deadlineDelivered) return;
            job.deadlineDelivered = true;
            job.publish(failureObservation(job, stageForCause(NetworkEffect.HostStage.Deadline, cause), cause));
        }
    }

    private static NetworkEffect.HostStage stageForCause(NetworkEffect.HostStage fallback, NetworkEffect.HostFailure cause) {
        return cause instanceof NetworkEffect.HostFailure.Timeout timeout ? timeout.stage() : fallback;
    }

    private void enqueueFailure(Job job, NetworkEffect.HostStage stage, NetworkEffect.HostFailure cause) {
        job.enqueueResult(failureObservation(job, stage, cause));
    }

    private static NetworkEffect.AdapterObservation failureObservation(Job job, NetworkEffect.HostStage stage,
            NetworkEffect.HostFailure cause) {
        return new NetworkEffect.AdapterObservation.FailureObservation(job.prepared.input().attempt(), job.handle,
                new NetworkEffect.SourceSequence.None(), new NetworkEffect.NetworkHostFailure(job.prepared.input().attempt(), stage,
                        job.prepared.input().configuration(), cause), unknown(NetworkEffect.UnknownEffectReason.HostFailure));
    }
    private static NetworkEffect.StartObservation.StartFailed failed(NetworkEffect.PreparedAttempt prepared,
            NetworkEffect.HostStage stage, NetworkEffect.HostFailure cause) {
        NetworkEffect.NetworkHostFailure failure = new NetworkEffect.NetworkHostFailure(prepared.input().attempt(), stage,
                prepared.input().configuration(), cause);
        return new NetworkEffect.StartObservation.StartFailed(failure, unknown(NetworkEffect.UnknownEffectReason.HostFailure));
    }
    private static NetworkEffect.EffectStatus unknown(NetworkEffect.UnknownEffectReason reason) {
        return new NetworkEffect.EffectStatus.Unknown(reason);
    }
    private static boolean hasCause(Throwable error, Class<? extends Throwable> type) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            if (type.isInstance(current)) return true;
        }
        return false;
    }
    private static byte[] toBytes(ByteString bytes) { return bytes.toArray(); }
    private static ByteString fromBytes(byte[] bytes) { return ByteString.copyOf(bytes); }
    private static boolean isVisibleAscii(ByteString bytes) {
        for (int i = 0; i < bytes.size(); i++) if (bytes.unsigned(i) < 0x20 || bytes.unsigned(i) > 0x7e) return false;
        return true;
    }
    private static String ascii(ByteString bytes) {
        StringBuilder value = new StringBuilder(bytes.size());
        for (int i = 0; i < bytes.size(); i++) value.append((char) bytes.unsigned(i));
        return value.toString();
    }

    static List<NetworkEffect.RawHeaderField> normalizeResponseHeaders(Map<String, List<String>> input) {
        try {
            return responseHeaders(input);
        } catch (HeaderEncodingException error) {
            throw new HeaderRepresentationException();
        }
    }
    private static List<NetworkEffect.RawHeaderField> responseHeaders(Map<String, List<String>> input) throws HeaderEncodingException {
        List<NetworkEffect.RawHeaderField> result = new ArrayList<>();
        for (Map.Entry<String, List<String>> entry : input.entrySet()) {
            String name = entry.getKey().toLowerCase(Locale.ROOT);
            if (!token(name) || hasSurrogate(name)) throw new HeaderEncodingException();
            for (String value : entry.getValue()) result.add(new NetworkEffect.RawHeaderField(name, utf8(value)));
        }
        result.sort((left, right) -> {
            int names = compareBytes(utf8Unchecked(left.name()), utf8Unchecked(right.name()));
            return names != 0 ? names : compareBytes(left.value(), right.value());
        });
        return result;
    }
    private static int compareBytes(ByteString left, ByteString right) {
        for (int i = 0; i < Math.min(left.size(), right.size()); i++) {
            int compare = Integer.compare(left.unsigned(i), right.unsigned(i));
            if (compare != 0) return compare;
        }
        return Integer.compare(left.size(), right.size());
    }
    private static ByteString utf8(String value) throws HeaderEncodingException {
        if (value == null || hasSurrogate(value)) throw new HeaderEncodingException();
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value));
            byte[] result = new byte[encoded.remaining()];
            encoded.get(result);
            return ByteString.copyOf(result);
        } catch (CharacterCodingException error) { throw new HeaderEncodingException(); }
    }
    private static ByteString utf8Unchecked(String value) {
        try { return utf8(value); } catch (HeaderEncodingException error) { throw new AssertionError(error); }
    }
    private static boolean hasSurrogate(String value) {
        for (int i = 0; i < value.length(); i++) {
            char current = value.charAt(i);
            if (Character.isHighSurrogate(current)) {
                if (i + 1 >= value.length() || !Character.isLowSurrogate(value.charAt(++i))) return true;
            } else if (Character.isLowSurrogate(current)) return true;
        }
        return false;
    }
    private static boolean token(String value) {
        if (value == null || value.isEmpty()) return false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (!(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
                    || "!#$%&'*+-.^_`|~".indexOf(c) >= 0)) return false;
        }
        return true;
    }
    private static final class HeaderEncodingException extends Exception { private static final long serialVersionUID = 1L; }
    static final class HeaderRepresentationException extends IllegalArgumentException {
        private static final long serialVersionUID = 1L;
        HeaderRepresentationException() { super("HeaderRepresentationUnavailable"); }
    }
    @Override public void close() {
        if (closed) return;
        closed = true;
        for (Job job : jobs.values()) {
            if (job.running()) {
                job.publish(failureObservation(job, NetworkEffect.HostStage.Cancel,
                        new NetworkEffect.HostFailure.HostClosed()));
            } else {
                job.stop();
            }
        }
    }
    private static final class CooperativeCancellation implements CancellationPort {
        @Override public NetworkEffect.CancellationCapability capability() { return COOPERATIVE_CANCELLATION_CAPABILITY; }
        @Override public Result<SemanticValues.Unit, NetworkEffect.HostFailure> request(ExecutionHandle handle) {
            return new Result.Accepted<>(SemanticValues.Unit.VALUE);
        }
    }
    private static final class SystemClock implements MonotonicClockPort {
        @Override public NetworkEffect.MonotonicClockCapability capability() { return SYSTEM_CLOCK_CAPABILITY; }
        @Override public Result<NetworkEffect.MonotonicClockObservation, NetworkEffect.HostFailure> observe() {
            return new Result.Accepted<>(System.nanoClock());
        }
        @Override public Optional<Duration> until(Nat limit) {
            Nat remaining = limit.minusWhenOrdered(System.nanoClock().value());
            java.math.BigInteger nanos = new java.math.BigInteger(remaining.toString());
            return Optional.of(Duration.ofNanos(nanos.bitLength() < 63 ? nanos.longValue() : Long.MAX_VALUE));
        }
    }
    private static final class System {
        static NetworkEffect.MonotonicClockObservation nanoClock() {
            return new NetworkEffect.MonotonicClockObservation(new NetworkEffect.ClockBasis("system-nano"), Nat.fromTrusted(java.math.BigInteger.valueOf(Math.max(0L, java.lang.System.nanoTime()))));
        }
    }
}
