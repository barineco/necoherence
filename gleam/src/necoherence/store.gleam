// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import necoherence/core.{
  type Command, type Outcome, type ResourceId, type Revision, type StaleBasis,
  type UnknownResource, type World, Applied, Basis, Command, Conflicted,
  Rejected, Revision, StaleBasis, UnknownResource,
}

/// A store owns each resource's payload alongside its revision.
pub type Store(payload) {
  Store(entries: List(#(ResourceId, Revision, payload)))
}

/// Closed sum of an observation result, carrying both the held revision and
/// payload, or the absent-resource payload.
pub type Observe(payload) {
  ObserveFound(revision: Revision, payload: payload)
  ObserveUnknown(UnknownResource)
}

pub fn store_of(
  entries: List(#(ResourceId, Revision, payload)),
) -> Store(payload) {
  Store(entries)
}

pub fn store_entries(
  store: Store(payload),
) -> List(#(ResourceId, Revision, payload)) {
  let Store(entries) = store
  entries
}

/// Read-only observation: does not change the store.
pub fn observe(
  store: Store(payload),
  resource: ResourceId,
) -> Observe(payload) {
  observe_entries(store_entries(store), resource)
}

fn observe_entries(
  entries: List(#(ResourceId, Revision, payload)),
  target: ResourceId,
) -> Observe(payload) {
  case entries {
    [] -> ObserveUnknown(UnknownResource(target))
    [#(resource, revision, payload), ..] if resource == target ->
      ObserveFound(revision, payload)
    [_, ..rest] -> observe_entries(rest, target)
  }
}

fn bump_entries(
  entries: List(#(ResourceId, Revision, payload)),
  target: ResourceId,
  intent: payload,
  found: Bool,
) -> List(#(ResourceId, Revision, payload)) {
  case entries {
    [] -> []
    [#(resource, revision, _), ..rest] if !found && resource == target -> [
      #(resource, Revision(core.revision_value(revision) + 1), intent),
      ..bump_entries(rest, target, intent, True)
    ]
    [entry, ..rest] -> [entry, ..bump_entries(rest, target, intent, found)]
  }
}

/// Apply a command against `store`, bumping the revision and replacing the
/// payload of the matched entry.
pub fn apply(
  store: Store(payload),
  command: Command(payload),
) -> Outcome(#(payload, Store(payload)), UnknownResource, StaleBasis, boundary) {
  let Command(intent:, basis: Basis(resource:, revision: expected)) = command
  case observe(store, resource) {
    ObserveUnknown(unknown) -> Rejected(unknown)
    ObserveFound(actual, _) if actual != expected ->
      Conflicted(StaleBasis(expected, actual))
    ObserveFound(_, _) ->
      Applied(#(
        intent,
        Store(bump_entries(store_entries(store), resource, intent, False)),
      ))
  }
}

/// Projection onto `World`: drop each entry's payload.
pub fn world_of(store: Store(payload)) -> World {
  core.world(
    list.map(store_entries(store), fn(entry) {
      let #(resource, revision, _) = entry
      #(resource, revision)
    }),
  )
}
