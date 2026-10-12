// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

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

pub type World {
  World(entries: List(#(ResourceId, Revision)))
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
  World(entries)
}

pub fn world_entries(value: World) -> List(#(ResourceId, Revision)) {
  let World(entries) = value
  entries
}

pub fn lookup(world: World, resource: ResourceId) -> Lookup {
  let World(entries) = world
  lookup_entries(entries, resource)
}

pub fn bump(world: World, resource: ResourceId) -> World {
  let World(entries) = world
  World(bump_entries(entries, resource, False))
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

fn lookup_entries(
  entries: List(#(ResourceId, Revision)),
  target: ResourceId,
) -> Lookup {
  case entries {
    [] -> Unknown(UnknownResource(target))
    [#(resource, revision), ..] if resource == target -> Found(revision)
    [_, ..rest] -> lookup_entries(rest, target)
  }
}

fn bump_entries(
  entries: List(#(ResourceId, Revision)),
  target: ResourceId,
  found: Bool,
) -> List(#(ResourceId, Revision)) {
  case entries {
    [] -> []
    [#(resource, revision), ..rest] if !found && resource == target -> [
      #(resource, Revision(revision_value(revision) + 1)),
      ..bump_entries(rest, target, True)
    ]
    [entry, ..rest] -> [entry, ..bump_entries(rest, target, found)]
  }
}
