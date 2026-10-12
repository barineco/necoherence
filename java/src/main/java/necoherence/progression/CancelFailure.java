// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed failures of {@link Progression#decideCancel}. */
public sealed interface CancelFailure
        permits CancelFailure.UnknownRequest, CancelFailure.RequestAlreadyTerminal,
        CancelFailure.MissingExecutionHandle {

    record UnknownRequest(RequestIdentity identity) implements CancelFailure {}
    record RequestAlreadyTerminal(RequestIdentity identity) implements CancelFailure {}
    record MissingExecutionHandle(RequestIdentity identity) implements CancelFailure {}
}
