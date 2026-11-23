// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.call;

/**
 * What a boundary failure carries: what was sent, expected, and seen.
 *
 * <p>{@code outbound} is the query value together with its provenance.
 * {@code expectation} is the shape of reply that was expected, including a
 * deadline's observed time and limit where one applies. {@code observed} is
 * the observation the judgment was actually made against.
 */
public record BoundaryDiagnosis<Outbound, Expectation, Observed>(
        Outbound outbound, Expectation expectation, Observed observed) {
}
