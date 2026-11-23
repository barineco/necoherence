// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

/** Which adapter observation a still-open request is waiting on. */
public enum SignalKind {
    PENDING_COMPLETION,
    PENDING_CANCELLATION
}
