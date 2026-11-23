// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.call;

import java.util.List;
import java.util.function.Function;

/**
 * Declaration of a function whose output settles at the call itself.
 *
 * <p>{@code identity} names the declaration for provenance: it is what lets a caller's own
 * record of outcomes point back to the step that produced one. {@code required} holds the
 * request's field names that {@link Call#io} projects a {@link Call.Request} against before
 * applying {@code output}. {@code output} is the function from input to output, total over
 * {@code Req} and closed over its own outcome. {@code Prd} is expected to already be a closed
 * union of that function's own branches, so this declaration adds no failure vocabulary of its
 * own.
 *
 * <p>The public construction path is {@link Call#immediateOf}. Direct construction is for
 * package-internal use and for tests.
 */
public record Immediate<Req, Prd>(String identity, List<String> required, Function<Req, Prd> output) {

    public Immediate {
        required = List.copyOf(required);
    }
}
