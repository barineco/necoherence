// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Store owns each resource's payload alongside its revision.
//! No public entry point returns a mutable reference into the store.

use std::collections::HashMap;

use crate::core::{Command, Outcome, ResourceId, Revision, StaleBasis, UnknownResource, World};

/// A store owns each resource's payload alongside its revision.
/// Entries keep their insertion order; lookups go through an index of the
/// first position of each resource.
#[derive(Clone, Debug)]
pub struct Store<A> {
    entries: Vec<(ResourceId, Revision, A)>,
    first_positions: HashMap<ResourceId, usize>,
}

impl<A: PartialEq> PartialEq for Store<A> {
    fn eq(&self, other: &Self) -> bool {
        self.entries == other.entries
    }
}

impl<A: Eq> Eq for Store<A> {}

/// Closed sum of an observation result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Observed<A> {
    Found(Revision, A),
    Unknown(UnknownResource),
}

/// Build a store from an ordered list of entries.
pub fn store_of<A>(entries: impl IntoIterator<Item = (ResourceId, Revision, A)>) -> Store<A> {
    let entries: Vec<(ResourceId, Revision, A)> = entries.into_iter().collect();
    let mut first_positions = HashMap::with_capacity(entries.len());
    for (position, (rid, _, _)) in entries.iter().enumerate() {
        first_positions.entry(rid.clone()).or_insert(position);
    }
    Store {
        entries,
        first_positions,
    }
}

/// Borrow the ordered entries of a store, read-only.
pub fn store_entries<A>(store: &Store<A>) -> impl Iterator<Item = (&ResourceId, &Revision, &A)> {
    store
        .entries
        .iter()
        .map(|(rid, rev, payload)| (rid, rev, payload))
}

fn first_entry<'a, A>(
    store: &'a Store<A>,
    resource: &ResourceId,
) -> Option<&'a (ResourceId, Revision, A)> {
    store
        .first_positions
        .get(resource)
        .and_then(|position| store.entries.get(*position))
}

/// Read-only observation: does not change the store.
pub fn observe<A: Clone>(store: &Store<A>, resource: &ResourceId) -> Observed<A> {
    match first_entry(store, resource) {
        Some((_, rev, payload)) => Observed::Found(rev.clone(), payload.clone()),
        None => Observed::Unknown(UnknownResource {
            resource: resource.clone(),
        }),
    }
}

/// Bump the revision and replace the payload of the first matching entry.
fn bump<A: Clone>(mut store: Store<A>, resource: &ResourceId, intent: &A) -> Store<A> {
    let held = store
        .first_positions
        .get(resource)
        .copied()
        .and_then(|position| store.entries.get_mut(position));
    if let Some((_, rev, payload)) = held {
        rev.value += 1u8;
        *payload = intent.clone();
    }
    store
}

/// Apply a command to a store and return a closed outcome.
pub fn apply<A: Clone>(
    store: Store<A>,
    command: Command<A>,
) -> Outcome<(A, Store<A>), UnknownResource, StaleBasis, crate::core::Never> {
    let current = match first_entry(&store, &command.basis.resource) {
        None => {
            return Outcome::Rejected(UnknownResource {
                resource: command.basis.resource,
            })
        }
        Some((_, current, _)) => current.clone(),
    };
    if current == command.basis.revision {
        let next = bump(store, &command.basis.resource, &command.intent);
        Outcome::Applied((command.intent, next))
    } else {
        Outcome::Conflicted(StaleBasis {
            expected: command.basis.revision,
            actual: current,
        })
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
