// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Reconcile a recorded call history against the world it should have
//! produced, in one call.

use crate::core::{lookup, Basis, Lookup, Nat, ResourceId, Revision, World};

/// One resource where the recorded history and the world disagree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Divergence {
    WorldAhead {
        resource: ResourceId,
        recorded: Revision,
        actual: Revision,
    },
    WorldBehind {
        resource: ResourceId,
        recorded: Revision,
        actual: Revision,
    },
    UnknownToWorld {
        resource: ResourceId,
        recorded: Revision,
    },
}

fn divergence_resource(d: &Divergence) -> &ResourceId {
    match d {
        Divergence::WorldAhead { resource, .. } => resource,
        Divergence::WorldBehind { resource, .. } => resource,
        Divergence::UnknownToWorld { resource, .. } => resource,
    }
}

/// Closed reconciliation product. Carries no derivable boolean field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reconciliation {
    pub divergences: Vec<Divergence>,
    pub unbased: Nat,
    pub dropped: Nat,
}

/// Read whether the reconciliation is free of any gap.
pub fn coherent(reconciliation: &Reconciliation) -> bool {
    reconciliation.divergences.is_empty()
        && reconciliation.unbased == Nat::from(0u8)
        && reconciliation.dropped == Nat::from(0u8)
}

/// Every resource named by a basis in `bases`, without duplicates, in the
/// order each resource first appears.
fn resources_of(bases: &[Option<Basis>]) -> Vec<ResourceId> {
    let mut order = Vec::new();
    for basis in bases.iter().flatten() {
        if !order.contains(&basis.resource) {
            order.push(basis.resource.clone());
        }
    }
    order
}

/// Highest recorded revision for `resource` across all bases.
fn max_revision(bases: &[Option<Basis>], resource: &ResourceId) -> Option<Revision> {
    let mut acc: Option<Revision> = None;
    for basis in bases.iter().flatten() {
        if basis.resource == *resource {
            acc = Some(match acc {
                None => basis.revision.clone(),
                Some(existing) if existing.value >= basis.revision.value => existing,
                Some(_) => basis.revision.clone(),
            });
        }
    }
    acc
}

fn divergence_at(world: &World, resource: &ResourceId, recorded: &Revision) -> Option<Divergence> {
    match lookup(world, resource) {
        Lookup::Unknown(_) => Some(Divergence::UnknownToWorld {
            resource: resource.clone(),
            recorded: recorded.clone(),
        }),
        Lookup::Found(actual) => {
            let recorded_plus_one = &recorded.value + Nat::from(1u8);
            if actual.value > recorded_plus_one {
                Some(Divergence::WorldAhead {
                    resource: resource.clone(),
                    recorded: recorded.clone(),
                    actual,
                })
            } else if actual.value < recorded.value {
                Some(Divergence::WorldBehind {
                    resource: resource.clone(),
                    recorded: recorded.clone(),
                    actual,
                })
            } else {
                None
            }
        }
    }
}

/// Reconcile the highest recorded revision per resource against `world`.
/// `dropped` is supplied by the caller as a value; it is not counted here.
pub fn reconcile(bases: &[Option<Basis>], world: &World, dropped: Nat) -> Reconciliation {
    let resources = resources_of(bases);
    let unbased = bases.iter().filter(|b| b.is_none()).count();
    let mut divergences = Vec::new();
    for resource in &resources {
        if let Some(recorded) = max_revision(bases, resource) {
            if let Some(d) = divergence_at(world, resource, &recorded) {
                divergences.push(d);
            }
        }
    }
    Reconciliation {
        divergences,
        unbased: Nat::from(unbased),
        dropped,
    }
}

/// Sort a reconciliation's divergences by `(kind, name)`, for adapter output.
pub fn sorted_divergences(reconciliation: &Reconciliation) -> Vec<Divergence> {
    let mut sorted = reconciliation.divergences.clone();
    sorted.sort_by(|a, b| {
        let ra = divergence_resource(a);
        let rb = divergence_resource(b);
        (ra.kind.as_str(), ra.name.as_str()).cmp(&(rb.kind.as_str(), rb.name.as_str()))
    });
    sorted
}
