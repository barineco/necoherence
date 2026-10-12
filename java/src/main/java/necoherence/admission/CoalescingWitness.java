// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.progression.RequestIdentity;

/** Whether a restored pending duplicate was absorbed idempotently, or why it was not. */
public sealed interface CoalescingWitness permits CoalescingWitness.Coalesced, CoalescingWitness.NotCoalesced {

    record Coalesced(RequestIdentity identity) implements CoalescingWitness {
    }

    record NotCoalesced(String reason) implements CoalescingWitness {
    }
}
