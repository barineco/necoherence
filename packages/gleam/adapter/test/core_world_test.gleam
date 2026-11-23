// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import necoherence/core

fn resource(name: String) -> core.ResourceId {
  core.resource("core", name)
}

fn duplicated_world() -> core.World {
  core.world([
    #(resource("a"), core.revision(1)),
    #(resource("b"), core.revision(2)),
    #(resource("a"), core.revision(7)),
  ])
}

pub fn world_entries_keep_the_order_of_construction_test() {
  let entries = [
    #(resource("a"), core.revision(1)),
    #(resource("b"), core.revision(2)),
    #(resource("a"), core.revision(7)),
  ]
  assert core.world_entries(core.world(entries)) == entries
}

pub fn lookup_reads_the_first_entry_of_a_duplicated_resource_test() {
  assert core.lookup(duplicated_world(), resource("a"))
    == core.Found(core.revision(1))
}

pub fn bump_changes_only_the_first_entry_of_a_duplicated_resource_test() {
  assert core.world_entries(core.bump(duplicated_world(), resource("a")))
    == [
      #(resource("a"), core.revision(2)),
      #(resource("b"), core.revision(2)),
      #(resource("a"), core.revision(7)),
    ]
}

pub fn bump_of_an_unknown_resource_keeps_the_world_test() {
  let world = duplicated_world()
  assert core.bump(world, resource("missing")) == world
}

pub fn generated_updates_keep_lookup_and_entries_consistent_test() {
  let names = ["a", "b", "c", "a", "d", "b"]
  let world =
    core.world(
      list.map(names, fn(name) { #(resource(name), core.revision(1)) }),
    )
  let updated =
    list.fold(["b", "a", "c", "b", "a", "a"], world, fn(current, name) {
      let command =
        core.Command(
          name,
          core.Basis(resource(name), expected_revision(current, name)),
        )
      case core.apply(current, command) {
        core.Applied(#(_, next)) -> next
        _ -> panic as "a command on the current basis must apply"
      }
    })
  assert list.map(core.world_entries(updated), fn(entry) {
      core.revision_value(entry.1)
    })
    == [4, 3, 2, 1, 1, 1]
  assert core.lookup(updated, resource("a")) == core.Found(core.revision(4))
}

fn expected_revision(world: core.World, name: String) -> core.Revision {
  case core.lookup(world, resource(name)) {
    core.Found(revision) -> revision
    core.Unknown(_) -> panic as "the resource is in the world"
  }
}
