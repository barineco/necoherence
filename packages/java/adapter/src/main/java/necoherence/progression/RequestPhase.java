// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Progress phase of a request entry. {@code PREPARING} is an intermediate phase constructed only by start. */
public enum RequestPhase {
    PENDING,
    PREPARING,
    PUBLISHING,
    PUBLISHED,
    SUPERSEDED,
    CANCELLED,
    FAILED
}
