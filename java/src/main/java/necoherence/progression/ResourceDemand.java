// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import necoherence.core.Nat;

/** Demand or occupancy along the pending, in-flight, and concurrent axes. Each component is a Nat. */
public record ResourceDemand(Nat pending, Nat inFlight, Nat concurrent) {
    public static final ResourceDemand ZERO = new ResourceDemand(Nat.zero(), Nat.zero(), Nat.zero());
    public ResourceDemand plus(ResourceDemand other) { return new ResourceDemand(pending.plus(other.pending), inFlight.plus(other.inFlight), concurrent.plus(other.concurrent)); }
}
