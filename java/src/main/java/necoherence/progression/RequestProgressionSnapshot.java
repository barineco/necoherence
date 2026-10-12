// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import java.util.List;
import java.util.Optional;
import necoherence.core.Nat;

/** Sole source of truth for request progression. */
public record RequestProgressionSnapshot(RequestPolicy policy, ResourceBudget budget,
        Optional<RequestIdentity> currentIdentity, List<RequestEntry> entries, Nat revision) {
    public RequestProgressionSnapshot { entries = List.copyOf(entries); }
    public RequestProgressionSnapshot withEntries(List<RequestEntry> newEntries) { return new RequestProgressionSnapshot(policy,budget,currentIdentity,newEntries,revision); }
    public RequestProgressionSnapshot withEntriesAndRevisionBump(List<RequestEntry> newEntries) { return new RequestProgressionSnapshot(policy,budget,currentIdentity,newEntries,revision.successor()); }
    public RequestProgressionSnapshot withCurrentIdentityAndRevisionBump(List<RequestEntry> newEntries, RequestIdentity identity) { return new RequestProgressionSnapshot(policy,budget,Optional.of(identity),newEntries,revision.successor()); }
    public RequestProgressionSnapshot withBudget(ResourceBudget newBudget) { return new RequestProgressionSnapshot(policy,newBudget,currentIdentity,entries,revision); }
}
