// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import necoherence.persistent.PositionSet;

/**
 * Demand summed per phase group, and the positions of pending entries, kept
 * in step with the entries of a snapshot.
 *
 * <p>Every value here is derived from the entry list. {@link #admit} adds an
 * entry's contribution and {@link #withdraw} removes the same contribution.
 */
record PhaseTotals(
        ResourceDemand pending,
        ResourceDemand inFlight,
        ResourceDemand concurrent,
        PositionSet pendingPositions,
        PositionSet orderedPendingPositions) {

    static final PhaseTotals ZERO = new PhaseTotals(
            ResourceDemand.ZERO, ResourceDemand.ZERO, ResourceDemand.ZERO,
            PositionSet.empty(), PositionSet.empty());

    PhaseTotals admit(int position, RequestEntry entry) {
        return switch (entry.phase()) {
            case PENDING -> new PhaseTotals(
                    pending.plus(entry.demand()), inFlight, concurrent,
                    pendingPositions.add(position),
                    ordered(entry) ? orderedPendingPositions.add(position) : orderedPendingPositions);
            case PREPARING -> new PhaseTotals(
                    pending, inFlight.plus(entry.demand()), concurrent, pendingPositions, orderedPendingPositions);
            case PUBLISHING -> new PhaseTotals(
                    pending, inFlight.plus(entry.demand()), concurrent.plus(entry.demand()),
                    pendingPositions, orderedPendingPositions);
            default -> this;
        };
    }

    PhaseTotals withdraw(int position, RequestEntry entry) {
        return switch (entry.phase()) {
            case PENDING -> new PhaseTotals(
                    pending.minus(entry.demand()), inFlight, concurrent,
                    pendingPositions.remove(position),
                    ordered(entry) ? orderedPendingPositions.remove(position) : orderedPendingPositions);
            case PREPARING -> new PhaseTotals(
                    pending, inFlight.minus(entry.demand()), concurrent, pendingPositions, orderedPendingPositions);
            case PUBLISHING -> new PhaseTotals(
                    pending, inFlight.minus(entry.demand()), concurrent.minus(entry.demand()),
                    pendingPositions, orderedPendingPositions);
            default -> this;
        };
    }

    private static boolean ordered(RequestEntry entry) {
        return entry.footprint().effectClass() == RequestEffectClass.ORDERED_EFFECT;
    }
}
