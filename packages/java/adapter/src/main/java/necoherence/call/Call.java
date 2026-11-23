// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.call;

import java.util.List;
import java.util.function.Function;

/**
 * Calls whose declarations state their required input fields.
 *
 * <p>Projection checks field-name presence only: the request must carry every name the
 * declaration requires. Host-language runtime projection details are not modeled beyond that
 * name check. {@link Immediate} and {@link Deferred} keep the input type and the output type
 * distinct in the declaration itself. {@link Request} keeps the dynamic field-presence
 * projection: it carries a payload of the declared input type together with the field names
 * actually present, so {@link #io} and {@link #issue} can match declared and present names
 * before applying {@code output} to the payload.
 */
public final class Call {

    private Call() {
    }

    /** A request value: a payload together with the field names present on it. */
    public record Request<Req>(Req payload, List<String> fields) {
        public Request {
            fields = List.copyOf(fields);
        }
    }

    /** Closed sum of a settled output and a projection failure. */
    public sealed interface CallResult<A> permits CallResult.Ok, CallResult.Failed {

        record Ok<A>(A value) implements CallResult<A> {
        }

        record Failed<A>(ProjectionFailed failure) implements CallResult<A> {
        }
    }

    /** Names in {@code required} that {@code present} does not carry. */
    static List<String> missing(List<String> required, List<String> present) {
        return required.stream().filter(name -> !present.contains(name)).toList();
    }

    /** Build an {@link Immediate} declaration from an explicit required-name list. */
    public static <Req, Prd> Immediate<Req, Prd> immediateOf(
            String identity, List<String> required, Function<Req, Prd> output) {
        return new Immediate<>(identity, required, output);
    }

    /** Build a {@link Deferred} declaration from an explicit required-name list. */
    public static <Req, Slot> Deferred<Req, Slot> deferredOf(
            String identity, List<String> required, Function<Req, Slot> output) {
        return new Deferred<>(identity, required, output);
    }

    /** Call an immediate declaration: match field names, then apply {@code output} to the payload. */
    public static <Req, Prd> CallResult<Prd> io(Immediate<Req, Prd> f, Request<Req> x) {
        List<String> miss = missing(f.required(), x.fields());
        if (!miss.isEmpty()) {
            return new CallResult.Failed<>(new ProjectionFailed(f.identity(), miss));
        }
        return new CallResult.Ok<>(f.output().apply(x.payload()));
    }

    /** Call a deferred declaration: match field names, then apply {@code output} to the payload. */
    public static <Req, Slot> CallResult<Slot> issue(Deferred<Req, Slot> f, Request<Req> x) {
        List<String> miss = missing(f.required(), x.fields());
        if (!miss.isEmpty()) {
            return new CallResult.Failed<>(new ProjectionFailed(f.identity(), miss));
        }
        return new CallResult.Ok<>(f.output().apply(x.payload()));
    }
}
