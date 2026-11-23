// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import necoherence/core.{
  type Basis, type ResourceId, type Revision, type World, Found, Unknown,
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

type Scan {
  Scan(
    order: List(ResourceId),
    highest: Dict(ResourceId, Revision),
    unbased: Int,
  )
}

fn scan_step(scan: Scan, basis: Option(Basis)) -> Scan {
  case basis {
    None -> Scan(..scan, unbased: scan.unbased + 1)
    Some(b) ->
      case dict.get(scan.highest, b.resource) {
        Error(Nil) ->
          Scan(
            ..scan,
            order: [b.resource, ..scan.order],
            highest: dict.insert(scan.highest, b.resource, b.revision),
          )
        Ok(existing) ->
          case core.revision_value(b.revision) > core.revision_value(existing) {
            True ->
              Scan(
                ..scan,
                highest: dict.insert(scan.highest, b.resource, b.revision),
              )
            False -> scan
          }
      }
  }
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
  let Scan(order:, highest:, unbased:) =
    list.fold(bases, Scan([], dict.new(), 0), scan_step)
  let divergences =
    list.filter_map(list.reverse(order), fn(resource) {
      case dict.get(highest, resource) {
        Error(Nil) -> Error(Nil)
        Ok(recorded) ->
          case divergence_at(world, resource, recorded) {
            None -> Error(Nil)
            Some(d) -> Ok(d)
          }
      }
    })
  Reconciliation(divergences, unbased, dropped)
}
