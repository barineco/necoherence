// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/**
 * Typed token that retains the identity advanced to {@code Publishing} by {@code start} and the observed handle.
 * {@code complete} accepts only this token, so its type excludes {@code complete} for identities that have no
 * {@code Running} value.
 */
public record Running(RequestIdentity identity, ExecutionHandle handle) {
}
