// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.store;

import java.util.ArrayList;
import java.util.List;
import necoherence.core.Command;
import necoherence.core.Never;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.StaleBasis;
import necoherence.core.UnknownResource;
import necoherence.core.World;

/**
 * Payload-owning store free functions.
 *
 * <p>No public entry returns a mutable view into the store. Observation does
 * not advance revisions. Mutation replaces payload values only.
 */
public final class Stores {

    private Stores() {
    }

    /** Owns each resource's payload alongside its revision. */
    public record Store<A>(List<Entry<A>> entries) {
        public Store {
            entries = List.copyOf(entries);
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
        for (Store.Entry<A> entry : store.entries()) {
            if (entry.resource().equals(resource)) {
                return new Observed.Found<>(entry.revision(), entry.payload());
            }
        }
        return new Observed.Unknown<>(new UnknownResource(resource));
    }

    private static <A> Store<A> bump(Store<A> store, ResourceId resource, A intent) {
        List<Store.Entry<A>> rebuilt = new ArrayList<>(store.entries().size());
        boolean found = false;
        for (Store.Entry<A> entry : store.entries()) {
            if (!found && entry.resource().equals(resource)) {
                rebuilt.add(new Store.Entry<>(
                        entry.resource(),
                        entry.revision().successor(),
                        intent));
                found = true;
            } else {
                rebuilt.add(entry);
            }
        }
        return storeOf(rebuilt);
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
