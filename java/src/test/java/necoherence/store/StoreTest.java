// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigInteger;
import java.util.List;
import necoherence.core.Basis;
import necoherence.core.Command;
import necoherence.core.Core;
import necoherence.core.Never;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.StaleBasis;
import necoherence.core.UnknownResource;
import necoherence.core.World;
import necoherence.store.Stores.AppliedStore;
import necoherence.store.Stores.Observed;
import necoherence.store.Stores.Store;
import org.junit.jupiter.api.Test;

final class StoreTest {

    private static ResourceId rid(int name) {
        return new ResourceId("store", Integer.toString(name));
    }

    private static Revision rev(long value) {
        return ((necoherence.core.Validation.Valid<Revision>) Revision.of(BigInteger.valueOf(value))).value();
    }

    private static Basis basis(int resource, long revision) {
        return new Basis(rid(resource), rev(revision));
    }

    private static Store<String> one(int resource, long revision, String payload) {
        return Stores.storeOf(List.of(new Store.Entry<>(rid(resource), rev(revision), payload)));
    }

    @Test
    void storeEntriesReturnsAReadOnlyCopyOfTheEntries() {
        Store<String> store = one(0, 3, "alpha");
        List<Store.Entry<String>> entries = Stores.storeEntries(store);
        assertEquals(store.entries(), entries);
        assertThrows(UnsupportedOperationException.class, () -> entries.add(null));
    }

    @Test
    void observeDoesNotChangeTheStore() {
        Store<String> store = one(0, 3, "alpha");
        World before = Stores.worldOfStore(store);
        Stores.observe(store, rid(0));
        assertEquals(before, Stores.worldOfStore(store));
    }

    @Test
    void applyAppliesWhenRevisionMatches() {
        Store<String> store = one(0, 3, "alpha");
        Command<String> command = new Command<>("beta", basis(0, 3));
        Outcome<AppliedStore<String>, UnknownResource, StaleBasis, Never> outcome =
                Stores.apply(store, command);
        @SuppressWarnings("unchecked")
        Outcome.Applied<AppliedStore<String>, UnknownResource, StaleBasis, Never> applied =
                assertInstanceOf(Outcome.Applied.class, outcome);
        assertEquals("beta", applied.value().intent());
        assertEquals(
                new Observed.Found<>(rev(4), "beta"),
                Stores.observe(applied.value().store(), rid(0)));
    }

    @Test
    void applyRejectsWhenResourceAbsent() {
        Store<String> store = one(0, 3, "alpha");
        Command<String> command = new Command<>("beta", basis(99, 0));
        Outcome<AppliedStore<String>, UnknownResource, StaleBasis, Never> outcome =
                Stores.apply(store, command);
        @SuppressWarnings("unchecked")
        Outcome.Rejected<AppliedStore<String>, UnknownResource, StaleBasis, Never> rejected =
                assertInstanceOf(Outcome.Rejected.class, outcome);
        assertEquals(rid(99), rejected.reason().resource());
    }

    @Test
    void applyConflictsWhenRevisionStale() {
        Store<String> store = one(0, 5, "alpha");
        Command<String> command = new Command<>("beta", basis(0, 4));
        Outcome<AppliedStore<String>, UnknownResource, StaleBasis, Never> outcome =
                Stores.apply(store, command);
        @SuppressWarnings("unchecked")
        Outcome.Conflicted<AppliedStore<String>, UnknownResource, StaleBasis, Never> conflicted =
                assertInstanceOf(Outcome.Conflicted.class, outcome);
        assertEquals(new StaleBasis(rev(4), rev(5)), conflicted.conflict());
    }

    @Test
    void applyProjectionCommutesOnApplied() {
        Store<String> store = one(0, 3, "alpha");
        Command<String> command = new Command<>("beta", basis(0, 3));
        var storeOutcome = Stores.apply(store, command);
        var worldOutcome = Core.apply(Stores.worldOfStore(store), command);
        @SuppressWarnings("unchecked")
        Outcome.Applied<AppliedStore<String>, UnknownResource, StaleBasis, Never> appliedStore =
                assertInstanceOf(Outcome.Applied.class, storeOutcome);
        @SuppressWarnings("unchecked")
        Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never> appliedWorld =
                assertInstanceOf(Outcome.Applied.class, worldOutcome);
        assertEquals(Stores.worldOfStore(appliedStore.value().store()), appliedWorld.value().world());
    }

    @Test
    void applyProjectionCommutesOnRejected() {
        Store<String> store = one(0, 3, "alpha");
        Command<String> command = new Command<>("beta", basis(99, 0));
        var storeOutcome = Stores.apply(store, command);
        var worldOutcome = Core.apply(Stores.worldOfStore(store), command);
        @SuppressWarnings("unchecked")
        Outcome.Rejected<?, UnknownResource, ?, ?> rejectedStore =
                assertInstanceOf(Outcome.Rejected.class, storeOutcome);
        @SuppressWarnings("unchecked")
        Outcome.Rejected<?, UnknownResource, ?, ?> rejectedWorld =
                assertInstanceOf(Outcome.Rejected.class, worldOutcome);
        assertEquals(rejectedStore.reason(), rejectedWorld.reason());
    }

    @Test
    void applyProjectionCommutesOnConflicted() {
        Store<String> store = one(0, 5, "alpha");
        Command<String> command = new Command<>("beta", basis(0, 4));
        var storeOutcome = Stores.apply(store, command);
        var worldOutcome = Core.apply(Stores.worldOfStore(store), command);
        @SuppressWarnings("unchecked")
        Outcome.Conflicted<?, ?, StaleBasis, ?> conflictedStore =
                assertInstanceOf(Outcome.Conflicted.class, storeOutcome);
        @SuppressWarnings("unchecked")
        Outcome.Conflicted<?, ?, StaleBasis, ?> conflictedWorld =
                assertInstanceOf(Outcome.Conflicted.class, worldOutcome);
        assertEquals(conflictedStore.conflict(), conflictedWorld.conflict());
    }

    @Test
    void observeReturnsUnknownForAbsentResource() {
        Store<String> store = one(0, 3, "alpha");
        assertInstanceOf(Observed.Unknown.class, Stores.observe(store, rid(99)));
    }

    @Test
    void worldOfStoreProjectsResourceAndRevisionOnly() {
        Store<String> store = one(0, 3, "alpha");
        assertEquals(
                new World(List.of(new World.Entry(rid(0), rev(3)))),
                Stores.worldOfStore(store));
    }

    @Test
    void applyReplacesOnlyTheFirstMatch() {
        Store<String> store = Stores.storeOf(List.of(
                new Store.Entry<>(rid(0), rev(1), "first"),
                new Store.Entry<>(rid(0), rev(9), "shadowed"),
                new Store.Entry<>(rid(7), rev(7), "other")));
        Command<String> command = new Command<>("replaced", basis(0, 1));
        @SuppressWarnings("unchecked")
        Outcome.Applied<AppliedStore<String>, UnknownResource, StaleBasis, Never> applied =
                assertInstanceOf(Outcome.Applied.class, Stores.apply(store, command));
        assertEquals(
                new Observed.Found<>(rev(2), "replaced"),
                Stores.observe(applied.value().store(), rid(0)));
        assertEquals(
                new Observed.Found<>(rev(7), "other"),
                Stores.observe(applied.value().store(), rid(7)));
        assertEquals(3, applied.value().store().entries().size());
        assertEquals("shadowed", applied.value().store().entries().get(1).payload());
    }
}
