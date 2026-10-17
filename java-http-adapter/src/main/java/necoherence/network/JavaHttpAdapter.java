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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicBoolean;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;

/** Small asynchronous adapter around Java's standard HTTP client. */
public final class JavaHttpAdapter implements AutoCloseable {
    public necoherence.semantic.SemanticValues.HostAdapter semanticPort() {
        return new necoherence.semantic.SemanticValues.HostAdapter() {
            public NetworkEffect.StartObservation start(NetworkEffect.SendCommand command) {
                return JavaHttpAdapter.this.start(command).observation();
            }
            public NetworkEffect.HostObservation observe(NetworkEffect.StartedAttempt started) {
                return switch (JavaHttpAdapter.this.observe(started)) {
                    case PollResult.Pending pending -> pending.observation();
                    case PollResult.Delivered delivered -> delivered.observation();
                    case PollResult.Closed closed -> closed.observation();
                };
            }
        };
    }
    interface MonotonicClockPort { NetworkEffect.MonotonicClockObservation now(); }
    interface CancellationPort { boolean cancel(NetworkEffect.AttemptIdentity attempt, ExecutionHandle handle); }
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

    private record Envelope(Nat delivery, NetworkEffect.AdapterObservation observation) {}
    private final HttpClient client;
    private final MonotonicClockPort clock;
    private final CancellationPort cancellation;
    private final WorkerFactory workerFactory;
    private final WorkerHook workerHook;
    private final AtomicLong handleOrdinal = new AtomicLong();
    private final ConcurrentHashMap<ExecutionHandle, Job> jobs = new ConcurrentHashMap<>();
    private volatile boolean closed;

    private final class Job {
        final NetworkEffect.PreparedAttempt prepared;
        final ExecutionHandle handle;
        final ConcurrentLinkedQueue<Envelope> queue = new ConcurrentLinkedQueue<>();
        final AtomicLong deliveryCounter = new AtomicLong();
        final ExecutorService worker;
        volatile Future<?> future;
        volatile CompletableFuture<HttpResponse<byte[]>> pending;
        volatile boolean deadlineDelivered;

        Job(NetworkEffect.PreparedAttempt prepared, ExecutionHandle handle) {
            this.prepared = prepared;
            this.handle = handle;
            this.worker = workerFactory.create(prepared);
        }
        void enqueue(NetworkEffect.AdapterObservation observation) {
            queue.add(new Envelope(Nat.fromLong(deliveryCounter.getAndIncrement()), observation));
        }
        /** Stops the worker thread and, if an exchange is in flight, cancels it so a
         * retried connection cannot keep blocking after the job is no longer observed. */
        void stop() {
            worker.shutdownNow();
            if (pending != null) pending.cancel(true);
        }
    }

    public JavaHttpAdapter() {
        this(HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build(),
                System::nanoClock, (attempt, handle) -> true,
                JavaHttpAdapter::newWorker, () -> {});
    }
    JavaHttpAdapter(HttpClient client, MonotonicClockPort clock, CancellationPort cancellation) {
        this(client, clock, cancellation, JavaHttpAdapter::newWorker, () -> {});
    }
    JavaHttpAdapter(HttpClient client, MonotonicClockPort clock, CancellationPort cancellation,
            WorkerFactory workerFactory, WorkerHook workerHook) {
        this.client = client;
        this.clock = clock;
        this.cancellation = cancellation;
        this.workerFactory = workerFactory;
        this.workerHook = workerHook;
    }
    private static ExecutorService newWorker(NetworkEffect.PreparedAttempt prepared) {
        return Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(
                    runnable, "java.worker[" + prepared.input().attempt() + "]");
            thread.setDaemon(true);
            return thread;
        });
    }

    public StartResult start(NetworkEffect.SendCommand command) {
        NetworkEffect.PreparedAttempt prepared = command.prepared();
        if (closed)
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.HostClosed()));
        NetworkEffect.AttemptInput input = prepared.input();
        if (input.configuration().requestBodyLimit().isZero()
                || input.configuration().responseBodyLimit().isZero()
                || Nat.fromLong(input.instruction().body().size()).compareTo(
                        input.configuration().requestBodyLimit()) > 0)
            return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                    new NetworkEffect.HostFailure.InvalidHostConfiguration()));
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
        if (input.deadline().isPresent()) {
            NetworkEffect.Deadline deadline = input.deadline().get();
            if (input.configuration().monotonicClock().isEmpty()
                    || !input.configuration().monotonicClock().get().equals(deadline.capability())
                    || !deadline.clockBasis().equals(deadline.capability().clockBasis()))
                return StartResult.failed(failed(prepared, NetworkEffect.HostStage.Start,
                        new NetworkEffect.HostFailure.DeadlineControlUnavailable()));
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

    public PollResult observe(NetworkEffect.StartedAttempt started) {
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
        if (!cancellation.cancel(command.attempt(), command.handle())) {
            NetworkEffect.NetworkHostFailure failure = new NetworkEffect.NetworkHostFailure(
                    command.attempt(), NetworkEffect.HostStage.Cancel,
                    job.prepared.input().configuration(),
                    new NetworkEffect.HostFailure.CancellationRejected());
            job.enqueue(new NetworkEffect.AdapterObservation.FailureObservation(
                    command.attempt(), command.handle(),
                    new NetworkEffect.SourceSequence.None(), failure,
                    unknown(NetworkEffect.UnknownEffectReason.Cancellation)));
            return observe(commandToStarted(job));
        }
        NetworkEffect.AdapterObservation observation =
                new NetworkEffect.AdapterObservation.CancellationObservation(
                        command.attempt(), command.handle(),
                        new NetworkEffect.SourceSequence.None(),
                        unknown(NetworkEffect.UnknownEffectReason.Cancellation));
        job.enqueue(observation);
        job.stop();
        return observe(commandToStarted(job));
    }

    private NetworkEffect.StartedAttempt commandToStarted(Job job) { return new NetworkEffect.StartedAttempt(job.prepared, job.handle); }

    /**
     * Validates headers and runs the worker hook synchronously on the dedicated
     * per-job worker thread, then dispatches the exchange asynchronously via
     * {@link HttpClient#sendAsync}. The worker thread is released as soon as the
     * exchange is in flight; the pending {@link CompletableFuture} is kept on the Job
     * so {@link #checkDeadline} and {@link #cancel} can abort a still-open exchange
     * (including a JDK-retried connection on a closed peer) without blocking on it.
     */
    private void execute(Job job, URI target) {
        AtomicBoolean responseHeadersReceived = new AtomicBoolean();
        NetworkEffect.AttemptInput input = job.prepared.input();
        try {
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
            job.pending = client.sendAsync(request, information -> {
                responseHeadersReceived.set(true);
                return HttpResponse.BodySubscribers.ofByteArray();
            });
            job.pending.whenComplete((response, error) -> onExchangeComplete(job, response, error, responseHeadersReceived));
        } catch (RuntimeException error) {
            enqueueFailure(job, NetworkEffect.HostStage.ResponseBody,
                    new NetworkEffect.HostFailure.HostRuntimeFailure());
        } finally {
            job.worker.shutdown();
        }
    }

    private void onExchangeComplete(Job job, HttpResponse<byte[]> response, Throwable error,
            AtomicBoolean responseHeadersReceived) {
        if (error == null) {
            List<Integer> body = fromBytes(response.body());
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
            job.enqueue(new NetworkEffect.AdapterObservation.ResponseObservation(
                    job.prepared.input().attempt(), job.handle,
                    new NetworkEffect.SourceSequence.None(),
                    new NetworkEffect.RawHttpResponse(
                            response.statusCode(), headers, body),
                    NetworkEffect.HeaderProvenance.LibraryNormalized,
                    unknown(NetworkEffect.UnknownEffectReason.NoResponse)));
            return;
        }
        // The exchange ended because checkDeadline/cancel cancelled the pending
        // future; that path already queued its own DeadlineObservation or
        // CancellationObservation, so no additional failure is queued here.
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
            enqueueFailure(job, NetworkEffect.HostStage.ResponseBody,
                    new NetworkEffect.HostFailure.HostRuntimeFailure());
        }
    }

    /**
     * Deadline events are derived only from the injected monotonic clock reaching
     * the matching capability's limit; a concrete library timeout is never treated
     * as evidence of a reached deadline. When the clock has caught up to the limit,
     * this queues {@code DeadlineObservation} and cancels the job's in-flight
     * exchange (including a JDK-retried connection on a closed peer) so it cannot
     * keep blocking once the deadline has been observed.
     */
    private void checkDeadline(Job job) {
        if (job.deadlineDelivered || job.prepared.input().deadline().isEmpty()) return;
        NetworkEffect.Deadline deadline = job.prepared.input().deadline().get();
        NetworkEffect.MonotonicClockObservation observed = clock.now();
        if (deadline.clockBasis().equals(observed.clockBasis()) && deadline.limit().compareTo(observed.value()) <= 0) {
            job.deadlineDelivered = true;
            job.enqueue(new NetworkEffect.AdapterObservation.DeadlineObservation(
                    job.prepared.input().attempt(), job.handle,
                    new NetworkEffect.SourceSequence.None(), deadline, observed,
                    unknown(NetworkEffect.UnknownEffectReason.Deadline)));
            job.stop();
        }
    }

    private void enqueueFailure(Job job, NetworkEffect.HostStage stage, NetworkEffect.HostFailure cause) {
        job.enqueue(new NetworkEffect.AdapterObservation.FailureObservation(job.prepared.input().attempt(), job.handle,
                new NetworkEffect.SourceSequence.None(), new NetworkEffect.NetworkHostFailure(job.prepared.input().attempt(), stage,
                        job.prepared.input().configuration(), cause), unknown(NetworkEffect.UnknownEffectReason.HostFailure)));
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
    private static byte[] toBytes(List<Integer> bytes) {
        byte[] result = new byte[bytes.size()];
        for (int i = 0; i < bytes.size(); i++) result[i] = (byte) bytes.get(i).intValue();
        return result;
    }
    private static List<Integer> fromBytes(byte[] bytes) {
        List<Integer> result = new ArrayList<>(bytes.length);
        for (byte value : bytes) result.add(Byte.toUnsignedInt(value));
        return result;
    }
    private static boolean isVisibleAscii(List<Integer> bytes) { return bytes.stream().allMatch(value -> value >= 0x20 && value <= 0x7e); }
    private static String ascii(List<Integer> bytes) {
        StringBuilder value = new StringBuilder(bytes.size());
        for (int byteValue : bytes) value.append((char) byteValue);
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
    private static int compareStrings(String left, String right) { return left.compareTo(right); }
    private static int compareBytes(List<Integer> left, List<Integer> right) {
        for (int i = 0; i < Math.min(left.size(), right.size()); i++) {
            int compare = Integer.compare(left.get(i), right.get(i));
            if (compare != 0) return compare;
        }
        return Integer.compare(left.size(), right.size());
    }
    private static List<Integer> utf8(String value) throws HeaderEncodingException {
        if (value == null || hasSurrogate(value)) throw new HeaderEncodingException();
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value));
            List<Integer> result = new ArrayList<>(encoded.remaining());
            while (encoded.hasRemaining()) result.add(Byte.toUnsignedInt(encoded.get()));
            return result;
        } catch (CharacterCodingException error) { throw new HeaderEncodingException(); }
    }
    private static List<Integer> utf8Unchecked(String value) {
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
    private static final class HeaderEncodingException extends Exception {}
    static final class HeaderRepresentationException extends IllegalArgumentException {
        HeaderRepresentationException() { super("HeaderRepresentationUnavailable"); }
    }
    @Override public void close() {
        if (closed) return;
        closed = true;
        for (Job job : jobs.values()) {
            boolean stillActive = job.pending != null
                    ? !job.pending.isDone()
                    : job.future != null && !job.future.isDone();
            if (stillActive) {
                enqueueFailure(job, NetworkEffect.HostStage.Cancel,
                        new NetworkEffect.HostFailure.HostClosed());
            }
            job.stop();
        }
    }
    private static final class System {
        static NetworkEffect.MonotonicClockObservation nanoClock() {
            return new NetworkEffect.MonotonicClockObservation(new NetworkEffect.ClockBasis("system-nano"), Nat.fromTrusted(java.math.BigInteger.valueOf(Math.max(0L, java.lang.System.nanoTime()))));
        }
    }
}
