// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/**
 * Closed exclusive sum of command outcomes.
 *
 * <p>{@code sealed interface} plus {@code permits} is the language machinery
 * that absorbs the discriminant: {@code switch} over an {@code Outcome} is
 * checked exhaustive by the compiler with no discriminant field declared on
 * any variant. Each variant record holds its payload directly, matching
 * Lean's inductive constructors and Rust's enum variants, without a wrapper
 * type.
 */
public sealed interface Outcome<A, R, C, F>
        permits Outcome.Applied, Outcome.Rejected, Outcome.Conflicted, Outcome.BoundaryFailed {

    record Applied<A, R, C, F>(A value) implements Outcome<A, R, C, F> {
    }

    record Rejected<A, R, C, F>(R reason) implements Outcome<A, R, C, F> {
    }

    record Conflicted<A, R, C, F>(C conflict) implements Outcome<A, R, C, F> {
    }

    record BoundaryFailed<A, R, C, F>(F failure) implements Outcome<A, R, C, F> {
    }
}
