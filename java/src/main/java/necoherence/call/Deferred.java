// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.call;

import java.util.List;
import java.util.function.Function;

/**
 * Declaration of a function whose eventual reply may stay silent.
 *
 * <p>Same shape as {@link Immediate}, a distinct type rather than a flag on one type: the
 * distinction has to be visible to {@link Call#io}'s and {@link Call#issue}'s own parameter
 * types, since which call form accepts a declaration is exactly what separates them. {@code
 * output} returns a slot, the record of the issuance; the issuance is this step's whole output,
 * and the delegation's eventual reply is a later observation judged by a separate call.
 *
 * <p>The public construction path is {@link Call#deferredOf}.
 */
public record Deferred<Req, Slot>(String identity, List<String> required, Function<Req, Slot> output) {

    public Deferred {
        required = List.copyOf(required);
    }
}
