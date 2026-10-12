// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Core types and operations for revision-aware state updates.
//! Values are immutable, outcomes are closed, and quantities corresponding
//! to Lean `Nat` use arbitrary-precision non-negative integers.

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

/// Immutable ordered map from resource identity to revision.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct World {
    entries: Vec<(ResourceId, Revision)>,
}

/// Build a world from an ordered list of resource/revision pairs.
pub fn world_of(entries: impl IntoIterator<Item = (ResourceId, Revision)>) -> World {
    World {
        entries: entries.into_iter().collect(),
    }
}

/// Borrow the ordered entries of a world.
pub fn entries(world: &World) -> &[(ResourceId, Revision)] {
    &world.entries
}

/// Return the first revision paired with `resource`, or its absence.
pub fn lookup(world: &World, resource: &ResourceId) -> Lookup {
    for (rid, rev) in entries(world) {
        if rid == resource {
            return Lookup::Found(rev.clone());
        }
    }
    Lookup::Unknown(UnknownResource {
        resource: resource.clone(),
    })
}

/// Return a world with the first matching resource's revision incremented.
pub fn bump(world: &World, resource: &ResourceId) -> World {
    let mut rebuilt = Vec::with_capacity(world.entries.len());
    let mut found = false;
    for (rid, rev) in entries(world) {
        if !found && rid == resource {
            rebuilt.push((
                rid.clone(),
                Revision {
                    value: &rev.value + Nat::from(1u8),
                },
            ));
            found = true;
        } else {
            rebuilt.push((rid.clone(), rev.clone()));
        }
    }
    world_of(rebuilt)
}

/// Build a [`Command`] that retains the observation's basis.
pub fn command_of<A, B>(observation: &Observation<A>, intent: B) -> Command<B> {
    Command {
        intent,
        basis: observation.basis.clone(),
    }
}

/// Apply `command` to `world` and return a closed outcome.
pub fn apply<A>(
    world: &World,
    command: Command<A>,
) -> Outcome<(A, World), UnknownResource, StaleBasis, Never> {
    match lookup(world, &command.basis.resource) {
        Lookup::Unknown(unknown) => Outcome::Rejected(unknown),
        Lookup::Found(current) if current == command.basis.revision => {
            let resource = command.basis.resource.clone();
            Outcome::Applied((command.intent, bump(world, &resource)))
        }
        Lookup::Found(actual) => Outcome::Conflicted(StaleBasis {
            expected: command.basis.revision,
            actual,
        }),
    }
}
