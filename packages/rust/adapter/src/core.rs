// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Core types and operations for revision-aware state updates.
//! Operations take the state by value and return the next state; outcomes are
//! closed; quantities corresponding to Lean `Nat` are arbitrary-precision.

use std::collections::HashMap;

pub use num_bigint::BigUint;

/// Arbitrary-precision non-negative integer, matching Lean's `Nat`.
pub type Nat = BigUint;

/// Ordered generation identifier for owned state.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Revision {
    pub value: Nat,
}

/// Identity of an owned resource (`kind` + `name`).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ResourceId {
    pub kind: String,
    pub name: String,
}

/// Identity and revision that situate an observation or command.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Basis {
    pub resource: ResourceId,
    pub revision: Revision,
}

/// Value that records what was seen together with its basis.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Observation<A> {
    pub payload: A,
    pub basis: Basis,
    pub observed_at: Nat,
}

/// Value that requests a state transition.
/// Public construction path is [`command_of`]. Direct construction is for
/// tests that exhibit basis loss.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Command<A> {
    pub intent: A,
    pub basis: Basis,
}

/// Closed exclusive sum of command outcomes.
/// Variants hold payloads directly, matching Lean's inductive constructors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome<A, R, C, F> {
    Applied(A),
    Rejected(R),
    Conflicted(C),
    BoundaryFailed(F),
}

/// Empty type used where Python / Lean use `Never` / `Empty`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Never {}

impl Never {
    pub fn elim<T>(&self) -> T {
        match *self {}
    }
}

/// Rejection payload when the commanded resource is absent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnknownResource {
    pub resource: ResourceId,
}

/// Conflict payload when the commanded revision differs from owned state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StaleBasis {
    pub expected: Revision,
    pub actual: Revision,
}

/// Closed sum of a held revision and an absent-resource payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Lookup {
    Found(Revision),
    Unknown(UnknownResource),
}

/// Ordered map from resource identity to revision.
/// Entries keep their insertion order; lookups go through an index of the
/// first position of each resource.
#[derive(Clone, Debug, Default)]
pub struct World {
    entries: Vec<(ResourceId, Revision)>,
    first_positions: HashMap<ResourceId, usize>,
}

impl PartialEq for World {
    fn eq(&self, other: &Self) -> bool {
        self.entries == other.entries
    }
}

impl Eq for World {}

/// Build a world from an ordered list of resource/revision pairs.
pub fn world_of(entries: impl IntoIterator<Item = (ResourceId, Revision)>) -> World {
    let entries: Vec<(ResourceId, Revision)> = entries.into_iter().collect();
    let mut first_positions = HashMap::with_capacity(entries.len());
    for (position, (rid, _)) in entries.iter().enumerate() {
        first_positions.entry(rid.clone()).or_insert(position);
    }
    World {
        entries,
        first_positions,
    }
}

/// Borrow the ordered entries of a world.
pub fn entries(world: &World) -> &[(ResourceId, Revision)] {
    &world.entries
}

fn first_revision<'a>(world: &'a World, resource: &ResourceId) -> Option<&'a Revision> {
    world
        .first_positions
        .get(resource)
        .and_then(|position| world.entries.get(*position))
        .map(|(_, rev)| rev)
}

/// Return the first revision paired with `resource`, or its absence.
pub fn lookup(world: &World, resource: &ResourceId) -> Lookup {
    match first_revision(world, resource) {
        Some(rev) => Lookup::Found(rev.clone()),
        None => Lookup::Unknown(UnknownResource {
            resource: resource.clone(),
        }),
    }
}

/// Return the world with the first matching resource's revision incremented.
pub fn bump(mut world: World, resource: &ResourceId) -> World {
    let held = world
        .first_positions
        .get(resource)
        .copied()
        .and_then(|position| world.entries.get_mut(position));
    if let Some((_, rev)) = held {
        rev.value += 1u8;
    }
    world
}

/// Return the world with one entry added at the end; the index gains the
/// resource only when it is not yet registered.
pub(crate) fn append(mut world: World, resource: ResourceId, revision: Revision) -> World {
    let position = world.entries.len();
    world
        .first_positions
        .entry(resource.clone())
        .or_insert(position);
    world.entries.push((resource, revision));
    world
}

/// Build a [`Command`] that retains the observation's basis.
pub fn command_of<A, B>(observation: &Observation<A>, intent: B) -> Command<B> {
    Command {
        intent,
        basis: observation.basis.clone(),
    }
}

/// Apply `command` to `world`; return the resulting world and a closed outcome.
/// The world is unchanged unless the outcome is `Applied`.
pub fn apply<A>(
    world: World,
    command: Command<A>,
) -> (World, Outcome<A, UnknownResource, StaleBasis, Never>) {
    let current = match first_revision(&world, &command.basis.resource) {
        None => {
            return (
                world,
                Outcome::Rejected(UnknownResource {
                    resource: command.basis.resource,
                }),
            )
        }
        Some(current) => current.clone(),
    };
    if current == command.basis.revision {
        let world = bump(world, &command.basis.resource);
        (world, Outcome::Applied(command.intent))
    } else {
        (
            world,
            Outcome::Conflicted(StaleBasis {
                expected: command.basis.revision,
                actual: current,
            }),
        )
    }
}
