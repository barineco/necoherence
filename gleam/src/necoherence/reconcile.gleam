// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import necoherence/core.{
  type Basis, type ResourceId, type Revision, type World, Found, Revision,
  Unknown,
}

/// One resource where the recorded history and the world disagree.
pub type Divergence {
  WorldAhead(resource: ResourceId, recorded: Revision, actual: Revision)
  WorldBehind(resource: ResourceId, recorded: Revision, actual: Revision)
  UnknownToWorld(resource: ResourceId, recorded: Revision)
}

/// Closed reconciliation product. Carries no derivable boolean field.
pub type Reconciliation {
  Reconciliation(divergences: List(Divergence), unbased: Int, dropped: Int)
}

/// Read whether the reconciliation is free of any gap.
pub fn coherent(reconciliation: Reconciliation) -> Bool {
  reconciliation.divergences == []
  && reconciliation.unbased == 0
  && reconciliation.dropped == 0
}

fn merge_step(
  resource: ResourceId,
  acc: Option(Revision),
  basis: Option(Basis),
) -> Option(Revision) {
  case basis {
    None -> acc
    Some(b) ->
      case b.resource == resource {
        False -> acc
        True ->
          case acc {
            None -> Some(b.revision)
            Some(existing) ->
              Some(
                Revision(int.max(
                  core.revision_value(existing),
                  core.revision_value(b.revision),
                )),
              )
          }
      }
  }
}

/// Highest recorded revision for `resource` across all bases, or `None` if
/// no basis names it.
fn max_revision(
  bases: List(Option(Basis)),
  resource: ResourceId,
) -> Option(Revision) {
  list.fold(bases, None, fn(acc, basis) { merge_step(resource, acc, basis) })
}

fn resource_step(
  acc: List(ResourceId),
  basis: Option(Basis),
) -> List(ResourceId) {
  case basis {
    None -> acc
    Some(b) ->
      case list.contains(acc, b.resource) {
        True -> acc
        False -> list.append(acc, [b.resource])
      }
  }
}

/// Every resource named by a basis in `bases`, without duplicates, in the
/// order each resource first appears.
fn resources_of(bases: List(Option(Basis))) -> List(ResourceId) {
  list.fold(bases, [], resource_step)
}

fn divergence_at(
  world: World,
  resource: ResourceId,
  recorded: Revision,
) -> Option(Divergence) {
  case core.lookup(world, resource) {
    Unknown(_) -> Some(UnknownToWorld(resource, recorded))
    Found(actual) -> {
      let actual_v = core.revision_value(actual)
      let recorded_v = core.revision_value(recorded)
      case actual_v > recorded_v + 1, actual_v < recorded_v {
        True, _ -> Some(WorldAhead(resource, recorded, actual))
        _, True -> Some(WorldBehind(resource, recorded, actual))
        _, _ -> None
      }
    }
  }
}

/// Reconcile the highest recorded revision per resource against `world`.
/// `dropped` is supplied by the caller as a value; it is not counted here.
pub fn reconcile(
  bases: List(Option(Basis)),
  world: World,
  dropped: Int,
) -> Reconciliation {
  let resources = resources_of(bases)
  let unbased = list.length(list.filter(bases, fn(basis) { basis == None }))
  let divergences =
    list.filter_map(resources, fn(resource) {
      case max_revision(bases, resource) {
        None -> Error(Nil)
        Some(recorded) ->
          case divergence_at(world, resource, recorded) {
            None -> Error(Nil)
            Some(d) -> Ok(d)
          }
      }
    })
  Reconciliation(divergences, unbased, dropped)
}
