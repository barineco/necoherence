// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/list

pub type Revision {
  Revision(value: Int)
}

pub type ResourceId {
  ResourceId(kind: String, name: String)
}

pub type Basis {
  Basis(resource: ResourceId, revision: Revision)
}

pub type Observation(payload) {
  Observation(payload: payload, basis: Basis, observed_at: Int)
}

pub type Command(intent) {
  Command(intent: intent, basis: Basis)
}

pub type UnknownResource {
  UnknownResource(resource: ResourceId)
}

pub type StaleBasis {
  StaleBasis(expected: Revision, actual: Revision)
}

pub type Lookup {
  Found(Revision)
  Unknown(UnknownResource)
}

/// Closed four-branch outcome: applied, rejected, conflicted, or a boundary
/// failure translated from an external touchpoint.
pub type Outcome(applied, rejected, conflicted, boundary) {
  Applied(applied)
  Rejected(rejected)
  Conflicted(conflicted)
  BoundaryFailed(boundary)
}

pub opaque type World {
  World(
    slots: Dict(Int, #(ResourceId, Revision)),
    count: Int,
    first_positions: Dict(ResourceId, Int),
  )
}

pub fn revision(value: Int) -> Revision {
  Revision(value)
}

pub fn revision_value(value: Revision) -> Int {
  let Revision(number) = value
  number
}

pub fn resource(kind: String, name: String) -> ResourceId {
  ResourceId(kind, name)
}

pub fn world(entries: List(#(ResourceId, Revision))) -> World {
  list.fold(entries, World(dict.new(), 0, dict.new()), append_entry)
}

/// Add one entry after the last one, without reading the others.
@internal
pub fn world_appended(world: World, entry: #(ResourceId, Revision)) -> World {
  append_entry(world, entry)
}

pub fn world_entries(value: World) -> List(#(ResourceId, Revision)) {
  let World(slots:, count:, ..) = value
  collect_entries(slots, count - 1, [])
}

pub fn lookup(world: World, resource: ResourceId) -> Lookup {
  let World(slots:, first_positions:, ..) = world
  case dict.get(first_positions, resource) {
    Error(Nil) -> Unknown(UnknownResource(resource))
    Ok(position) ->
      case dict.get(slots, position) {
        Ok(#(_, revision)) -> Found(revision)
        Error(Nil) -> Unknown(UnknownResource(resource))
      }
  }
}

pub fn bump(world: World, resource: ResourceId) -> World {
  let World(slots:, first_positions:, ..) = world
  case dict.get(first_positions, resource) {
    Error(Nil) -> world
    Ok(position) ->
      case dict.get(slots, position) {
        Error(Nil) -> world
        Ok(#(entry_resource, revision)) ->
          World(
            ..world,
            slots: dict.insert(slots, position, #(
              entry_resource,
              Revision(revision_value(revision) + 1),
            )),
          )
      }
  }
}

pub fn command_of(
  observation: Observation(payload),
  intent: intent,
) -> Command(intent) {
  let Observation(basis:, ..) = observation
  Command(intent:, basis:)
}

/// Apply a command against `world`. `boundary` never occurs here: the
/// four-branch outcome type is shared with the other feature families
/// (`Store.apply`, file effect) that do produce boundary failures.
pub fn apply(
  world: World,
  command: Command(intent),
) -> Outcome(#(intent, World), UnknownResource, StaleBasis, boundary) {
  let Command(intent:, basis: Basis(resource:, revision: expected)) = command
  case lookup(world, resource) {
    Unknown(unknown) -> Rejected(unknown)
    Found(actual) if actual != expected ->
      Conflicted(StaleBasis(expected, actual))
    Found(_) -> Applied(#(intent, bump(world, resource)))
  }
}

fn append_entry(world: World, entry: #(ResourceId, Revision)) -> World {
  let World(slots:, count:, first_positions:) = world
  World(
    slots: dict.insert(slots, count, entry),
    count: count + 1,
    first_positions: case dict.has_key(first_positions, entry.0) {
      True -> first_positions
      False -> dict.insert(first_positions, entry.0, count)
    },
  )
}

fn collect_entries(
  slots: Dict(Int, #(ResourceId, Revision)),
  position: Int,
  accumulated: List(#(ResourceId, Revision)),
) -> List(#(ResourceId, Revision)) {
  case position < 0 {
    True -> accumulated
    False ->
      case dict.get(slots, position) {
        Ok(entry) ->
          collect_entries(slots, position - 1, [entry, ..accumulated])
        Error(Nil) -> collect_entries(slots, position - 1, accumulated)
      }
  }
}
