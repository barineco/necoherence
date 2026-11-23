// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

/** Value that records what was seen together with its basis and validated observation instant. */
public record Observation<A>(A payload, Basis basis, Nat observedAt) {}
