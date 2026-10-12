// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/**
 * Value that requests a state transition.
 *
 * <p>The public construction path is {@link Core#commandOf}. Direct
 * construction is for package-internal use and for tests that exhibit basis
 * loss.
 */
public record Command<A>(A intent, Basis basis) {
}
