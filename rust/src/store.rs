// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Store owns each resource's payload alongside its revision.
//! No public entry point returns a mutable reference into the store.

use crate::core::{
    Command, Nat, Outcome, ResourceId, Revision, StaleBasis, UnknownResource, World,
};

/// A store owns each resource's payload alongside its revision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Store<A> {
    entries: Vec<(ResourceId, Revision, A)>,
}

/// Closed sum of an observation result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Observed<A> {
    Found(Revision, A),
    Unknown(UnknownResource),
}

/// Build a store from an ordered list of entries.
pub fn store_of<A>(entries: impl IntoIterator<Item = (ResourceId, Revision, A)>) -> Store<A> {
    Store {
        entries: entries.into_iter().collect(),
    }
}

/// Borrow the ordered entries of a store, read-only.
pub fn store_entries<A>(store: &Store<A>) -> impl Iterator<Item = (&ResourceId, &Revision, &A)> {
    store
        .entries
        .iter()
        .map(|(rid, rev, payload)| (rid, rev, payload))
}

/// Read-only observation: does not change the store.
pub fn observe<A: Clone>(store: &Store<A>, resource: &ResourceId) -> Observed<A> {
    for (rid, rev, payload) in &store.entries {
        if rid == resource {
            return Observed::Found(rev.clone(), payload.clone());
        }
    }
    Observed::Unknown(UnknownResource {
        resource: resource.clone(),
    })
}

/// Bump the revision and replace the payload of the first matching entry.
fn bump<A: Clone>(store: &Store<A>, resource: &ResourceId, intent: &A) -> Store<A> {
    let mut rebuilt = Vec::with_capacity(store.entries.len());
    let mut found = false;
    for (rid, rev, payload) in &store.entries {
        if !found && rid == resource {
            rebuilt.push((
                rid.clone(),
                Revision {
                    value: &rev.value + Nat::from(1u8),
                },
                intent.clone(),
            ));
            found = true;
        } else {
            rebuilt.push((rid.clone(), rev.clone(), payload.clone()));
        }
    }
    store_of(rebuilt)
}

/// Apply a command to a store and return a closed outcome.
pub fn apply<A: Clone>(
    store: &Store<A>,
    command: Command<A>,
) -> Outcome<(A, Store<A>), UnknownResource, StaleBasis, crate::core::Never> {
    match observe(store, &command.basis.resource) {
        Observed::Unknown(unknown) => Outcome::Rejected(unknown),
        Observed::Found(current, _) if current == command.basis.revision => {
            let resource = command.basis.resource.clone();
            let next = bump(store, &resource, &command.intent);
            Outcome::Applied((command.intent, next))
        }
        Observed::Found(actual, _) => Outcome::Conflicted(StaleBasis {
            expected: command.basis.revision,
            actual,
        }),
    }
}

/// Projection onto World: drop each entry's payload.
pub fn world_of_store<A>(store: &Store<A>) -> World {
    crate::core::world_of(
        store
            .entries
            .iter()
            .map(|(rid, rev, _)| (rid.clone(), rev.clone())),
    )
}
