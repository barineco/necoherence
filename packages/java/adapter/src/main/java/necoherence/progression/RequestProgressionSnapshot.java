// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import necoherence.core.Nat;
import necoherence.persistent.PersistentMap;
import necoherence.persistent.PersistentVector;

/**
 * Sole source of truth for request progression.
 *
 * <p>{@link #of} is the only way to build a snapshot; it rejects entries that
 * share an identity. Every other snapshot comes from an operation on a
 * snapshot that {@code of} accepted, so identities stay distinct. A snapshot
 * holds an index from identity to position and the totals that
 * {@link Progression#derivePending} and its siblings return; operations
 * update both together with the entry they change.
 */
public final class RequestProgressionSnapshot {
    private final RequestPolicy policy;
    private final ResourceBudget budget;
    private final Optional<RequestIdentity> currentIdentity;
    private final Nat revision;
    private final PersistentVector<RequestEntry> entries;
    private final PersistentMap<RequestIdentity, Integer> positions;
    private final PhaseTotals totals;

    private RequestProgressionSnapshot(RequestPolicy policy, ResourceBudget budget,
            Optional<RequestIdentity> currentIdentity, Nat revision, PersistentVector<RequestEntry> entries,
            PersistentMap<RequestIdentity, Integer> positions, PhaseTotals totals) {
        this.policy = policy;
        this.budget = budget;
        this.currentIdentity = currentIdentity;
        this.revision = revision;
        this.entries = entries;
        this.positions = positions;
        this.totals = totals;
    }

    public static SnapshotResult of(RequestPolicy policy, ResourceBudget budget,
            Optional<RequestIdentity> currentIdentity, List<RequestEntry> entries, Nat revision) {
        Set<RequestIdentity> seen = new HashSet<>();
        PersistentMap<RequestIdentity, Integer> positions = PersistentMap.empty();
        PhaseTotals totals = PhaseTotals.ZERO;
        for (int position = 0; position < entries.size(); position++) {
            RequestEntry entry = entries.get(position);
            if (!seen.add(entry.identity())) {
                return new SnapshotResult.Rejected(new SnapshotFailure.DuplicateIdentity(entry.identity()));
            }
            positions = positions.put(entry.identity(), position);
            totals = totals.admit(position, entry);
        }
        return new SnapshotResult.Built(new RequestProgressionSnapshot(
                policy, budget, currentIdentity, revision, PersistentVector.of(entries), positions, totals));
    }

    public RequestPolicy policy() {
        return policy;
    }

    public ResourceBudget budget() {
        return budget;
    }

    public Optional<RequestIdentity> currentIdentity() {
        return currentIdentity;
    }

    public Nat revision() {
        return revision;
    }

    /** Return the entries in submission order. */
    public List<RequestEntry> entries() {
        return List.copyOf(entries.toList());
    }

    public RequestProgressionSnapshot withBudget(ResourceBudget newBudget) {
        return new RequestProgressionSnapshot(policy, newBudget, currentIdentity, revision, entries, positions, totals);
    }

    /** Return a snapshot whose entry with the same identity is {@code replacement}; the revision is unchanged. */
    public RequestProgressionSnapshot withReplacedEntry(RequestEntry replacement) {
        int position = positionOf(replacement.identity());
        return position < 0 ? this : replacedAt(position, replacement);
    }

    /** Return the entry with {@code identity}, or empty when the snapshot holds none. */
    public Optional<RequestEntry> find(RequestIdentity identity) {
        int position = positionOf(identity);
        return position < 0 ? Optional.empty() : Optional.of(entries.get(position));
    }

    int positionOf(RequestIdentity identity) {
        Integer position = positions.get(identity);
        return position == null ? -1 : position;
    }

    RequestEntry entryAt(int position) {
        return entries.get(position);
    }

    ResourceDemand pendingTotal() {
        return totals.pending();
    }

    ResourceDemand inFlightTotal() {
        return totals.inFlight();
    }

    ResourceDemand concurrentTotal() {
        return totals.concurrent();
    }

    int firstPendingPosition() {
        return totals.pendingPositions().first();
    }

    int firstOrderedPendingPosition() {
        return totals.orderedPendingPositions().first();
    }

    List<Integer> pendingPositionList() {
        return totals.pendingPositions().toList();
    }

    RequestProgressionSnapshot replacedAt(int position, RequestEntry replacement) {
        PhaseTotals next = totals.withdraw(position, entries.get(position)).admit(position, replacement);
        return new RequestProgressionSnapshot(
                policy, budget, currentIdentity, revision, entries.set(position, replacement), positions, next);
    }

    RequestProgressionSnapshot appended(RequestEntry created) {
        int position = entries.size();
        return new RequestProgressionSnapshot(policy, budget, currentIdentity, revision, entries.append(created),
                positions.put(created.identity(), position), totals.admit(position, created));
    }

    RequestProgressionSnapshot withCurrent(RequestIdentity identity) {
        return new RequestProgressionSnapshot(
                policy, budget, Optional.of(identity), revision, entries, positions, totals);
    }

    RequestProgressionSnapshot bumped() {
        return new RequestProgressionSnapshot(
                policy, budget, currentIdentity, revision.successor(), entries, positions, totals);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof RequestProgressionSnapshot snapshot
                && policy == snapshot.policy
                && budget.equals(snapshot.budget)
                && currentIdentity.equals(snapshot.currentIdentity)
                && revision.equals(snapshot.revision)
                && entries().equals(snapshot.entries());
    }

    @Override
    public int hashCode() {
        return java.util.Objects.hash(policy, budget, currentIdentity, revision, entries());
    }

    @Override
    public String toString() {
        return "RequestProgressionSnapshot[policy=" + policy + ", budget=" + budget + ", currentIdentity="
                + currentIdentity + ", entries=" + entries() + ", revision=" + revision + "]";
    }
}
