// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/list
import necoherence/core.{
  type Command, type Outcome, type ResourceId, type Revision, type StaleBasis,
  type UnknownResource, type World, Applied, Basis, Command, Conflicted,
  Rejected, Revision, StaleBasis, UnknownResource,
}

/// A store owns each resource's payload alongside its revision. Entries keep
/// their order in numbered slots, and an index finds the first slot of each
/// resource, so a read or a one-entry update does not walk the other entries.
pub opaque type Store(payload) {
  Store(
    slots: Dict(Int, #(ResourceId, Revision, payload)),
    count: Int,
    first_positions: Dict(ResourceId, Int),
  )
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
  list.fold(entries, Store(dict.new(), 0, dict.new()), append_entry)
}

pub fn store_entries(
  store: Store(payload),
) -> List(#(ResourceId, Revision, payload)) {
  let Store(slots:, count:, ..) = store
  collect_entries(slots, count - 1, [])
}

/// Read-only observation: does not change the store.
pub fn observe(
  store: Store(payload),
  resource: ResourceId,
) -> Observe(payload) {
  let Store(slots:, first_positions:, ..) = store
  case dict.get(first_positions, resource) {
    Error(Nil) -> ObserveUnknown(UnknownResource(resource))
    Ok(position) ->
      case dict.get(slots, position) {
        Ok(#(_, revision, payload)) -> ObserveFound(revision, payload)
        Error(Nil) -> ObserveUnknown(UnknownResource(resource))
      }
  }
}

fn bump_first(
  store: Store(payload),
  target: ResourceId,
  intent: payload,
) -> Store(payload) {
  let Store(slots:, first_positions:, ..) = store
  case dict.get(first_positions, target) {
    Error(Nil) -> store
    Ok(position) ->
      case dict.get(slots, position) {
        Error(Nil) -> store
        Ok(#(resource, revision, _)) ->
          Store(
            ..store,
            slots: dict.insert(slots, position, #(
              resource,
              Revision(core.revision_value(revision) + 1),
              intent,
            )),
          )
      }
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
      Applied(#(intent, bump_first(store, resource, intent)))
  }
}

fn append_entry(
  store: Store(payload),
  entry: #(ResourceId, Revision, payload),
) -> Store(payload) {
  let Store(slots:, count:, first_positions:) = store
  Store(
    slots: dict.insert(slots, count, entry),
    count: count + 1,
    first_positions: case dict.has_key(first_positions, entry.0) {
      True -> first_positions
      False -> dict.insert(first_positions, entry.0, count)
    },
  )
}

fn collect_entries(
  slots: Dict(Int, #(ResourceId, Revision, payload)),
  position: Int,
  accumulated: List(#(ResourceId, Revision, payload)),
) -> List(#(ResourceId, Revision, payload)) {
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

/// Projection onto `World`: drop each entry's payload.
pub fn world_of(store: Store(payload)) -> World {
  core.world(
    list.map(store_entries(store), fn(entry) {
      let #(resource, revision, _) = entry
      #(resource, revision)
    }),
  )
}
