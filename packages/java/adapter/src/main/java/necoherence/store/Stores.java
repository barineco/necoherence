// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.store;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import necoherence.core.Command;
import necoherence.core.Never;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.StaleBasis;
import necoherence.core.UnknownResource;
import necoherence.core.World;
import necoherence.persistent.PersistentVector;

/**
 * Payload-owning store free functions.
 *
 * <p>No public entry returns a mutable view into the store. Observation does
 * not advance revisions. Mutation replaces payload values only.
 */
public final class Stores {

    private Stores() {
    }

    /**
     * Owns each resource's payload alongside its revision.
     *
     * <p>The constructor accepts any list. {@link #entries()} returns the
     * entries in order; operations find a resource through an index of first
     * positions and replace one entry without copying the others.
     */
    public static final class Store<A> {
        private final PersistentVector<Entry<A>> entries;
        private final Map<ResourceId, Integer> firstPositions;

        public Store(List<Entry<A>> entries) {
            Map<ResourceId, Integer> positions = new HashMap<>();
            for (int position = 0; position < entries.size(); position++) {
                positions.putIfAbsent(entries.get(position).resource(), position);
            }
            this.entries = PersistentVector.of(entries);
            this.firstPositions = positions;
        }

        private Store(PersistentVector<Entry<A>> entries, Map<ResourceId, Integer> firstPositions) {
            this.entries = entries;
            this.firstPositions = firstPositions;
        }

        public List<Entry<A>> entries() {
            return List.copyOf(entries.toList());
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof Store<?> store && entries().equals(store.entries());
        }

        @Override
        public int hashCode() {
            return entries().hashCode();
        }

        @Override
        public String toString() {
            return "Store" + entries();
        }

        public record Entry<A>(ResourceId resource, Revision revision, A payload) {
        }
    }

    /** Closed sum of an observation result. */
    public sealed interface Observed<A> permits Observed.Found, Observed.Unknown {
        record Found<A>(Revision revision, A payload) implements Observed<A> {
        }

        record Unknown<A>(UnknownResource unknownResource) implements Observed<A> {
        }
    }

    public static <A> Store<A> storeOf(List<Store.Entry<A>> entries) {
        return new Store<>(entries);
    }

    public static <A> List<Store.Entry<A>> storeEntries(Store<A> store) {
        return List.copyOf(store.entries());
    }

    public static <A> Observed<A> observe(Store<A> store, ResourceId resource) {
        Integer position = store.firstPositions.get(resource);
        if (position == null) {
            return new Observed.Unknown<>(new UnknownResource(resource));
        }
        Store.Entry<A> entry = store.entries.get(position);
        return new Observed.Found<>(entry.revision(), entry.payload());
    }

    private static <A> Store<A> bump(Store<A> store, ResourceId resource, A intent) {
        Integer position = store.firstPositions.get(resource);
        if (position == null) {
            return store;
        }
        Store.Entry<A> entry = store.entries.get(position);
        return new Store<>(
                store.entries.set(position, new Store.Entry<>(entry.resource(), entry.revision().successor(), intent)),
                store.firstPositions);
    }

    public static <A> Outcome<AppliedStore<A>, UnknownResource, StaleBasis, Never> apply(
            Store<A> store, Command<A> command) {
        Observed<A> current = observe(store, command.basis().resource());
        if (current instanceof Observed.Unknown<A> unknown) {
            return new Outcome.Rejected<>(unknown.unknownResource());
        }
        Observed.Found<A> found = (Observed.Found<A>) current;
        if (!found.revision().equals(command.basis().revision())) {
            return new Outcome.Conflicted<>(
                    new StaleBasis(command.basis().revision(), found.revision()));
        }
        Store<A> next = bump(store, command.basis().resource(), command.intent());
        return new Outcome.Applied<>(new AppliedStore<>(command.intent(), next));
    }

    public static <A> World worldOfStore(Store<A> store) {
        List<World.Entry> entries = new ArrayList<>(store.entries().size());
        for (Store.Entry<A> entry : store.entries()) {
            entries.add(new World.Entry(entry.resource(), entry.revision()));
        }
        return new World(entries);
    }

    /** Applied payload paired with the next store. */
    public record AppliedStore<A>(A intent, Store<A> store) {
    }
}
