// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/** Closed exclusive sum of command outcomes. */
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
