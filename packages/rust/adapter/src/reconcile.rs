// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Reconcile a recorded call history against the world it should have
//! produced, in one call.

use std::collections::HashMap;

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
    let mut positions: HashMap<ResourceId, usize> = HashMap::new();
    let mut highest: Vec<(ResourceId, Revision)> = Vec::new();
    let mut unbased = 0usize;
    for entry in bases {
        match entry {
            None => unbased += 1,
            Some(basis) => match positions
                .get(&basis.resource)
                .and_then(|position| highest.get_mut(*position))
            {
                Some((_, recorded)) => {
                    if recorded.value < basis.revision.value {
                        *recorded = basis.revision.clone();
                    }
                }
                None => {
                    positions.insert(basis.resource.clone(), highest.len());
                    highest.push((basis.resource.clone(), basis.revision.clone()));
                }
            },
        }
    }
    let divergences = highest
        .iter()
        .filter_map(|(resource, recorded)| divergence_at(world, resource, recorded))
        .collect();
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
