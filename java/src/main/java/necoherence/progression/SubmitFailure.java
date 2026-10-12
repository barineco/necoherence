// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Reason why submit rejects a request. */
public sealed interface SubmitFailure permits SubmitFailure.DuplicateIdentity, SubmitFailure.PendingLimitExceeded {

    record DuplicateIdentity(RequestIdentity identity) implements SubmitFailure {
    }

    record PendingLimitExceeded(ResourceDemand demand, ResourceBudget budget) implements SubmitFailure {
    }
}
