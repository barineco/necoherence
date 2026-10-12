// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/**
 * Typed token that retains an identity accepted by {@code submit}. {@code start} accepts only this token, so its
 * type excludes {@code start} for identities that have no {@code Accepted} value.
 */
public record Accepted(RequestIdentity identity) {
}
