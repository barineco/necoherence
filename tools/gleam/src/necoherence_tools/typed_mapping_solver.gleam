// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/list
import gleam/result
import necoherence/typed_mapping.{
  type DeadlockResult, type Marking, type ReachabilityResult, type SolverFailure,
  type SolverInput, type WellFoundednessResult, AcyclicWitness,
  BindingBoundExhausted, ClosureWitness, CycleWitness, DeadlockInvalid,
  DeadlockUnknown, DeadlockWitness, Deadlocked, Enabled, EnabledInvalid,
  NotDeadlocked, NotWellFounded, ReachabilityInvalid, ReachabilityUnknown,
  ReachabilityWitness, Reachable, SearchStepBoundExhausted, Unreachable,
  WellFounded, WellFoundednessInvalid, WellFoundednessUnknown, apply_branch_at,
  binding_bound_exceeded, bindings_for, derive_enabled_set, eval_goal,
  transition_enabled_at, validate,
}

/// The result of one exploration step: the goal was reached, the frontier
/// was exhausted while the closure remained within bound, or the
/// search-step bound was hit with the frontier still nonempty.
type ExploreOutcome {
  ExploreFound(path: List(String), marking: Marking)
  ExploreClosed(visited: List(Marking))
  ExploreBoundHit(visited: List(Marking))
}

fn neighbors_of(
  input: SolverInput,
  path: List(String),
  marking: Marking,
) -> List(#(List(String), Marking)) {
  list.filter_map(input.transitions, fn(t) {
    let bs = bindings_for(input, t.identity)
    case transition_enabled_at(bs, marking) {
      True ->
        Ok(#(list.append(path, [t.identity]), apply_branch_at(marking, t, bs)))
      False -> Error(Nil)
    }
  })
}

/// The neighbours that are genuinely new: marking not among the
/// `blocked` visited or pending markings and not produced by another
/// neighbour in the same batch; convergent markings enqueue at most once.
fn fresh_neighbors(
  neighbors: List(#(List(String), Marking)),
  blocked: List(Marking),
) -> List(#(List(String), Marking)) {
  let #(kept, _) =
    list.fold(neighbors, #([], blocked), fn(acc, pr) {
      let #(kept, blocked) = acc
      case list.contains(blocked, pr.1) {
        True -> acc
        False -> #(list.append(kept, [pr]), [pr.1, ..blocked])
      }
    })
  kept
}

/// Bounded breadth-first exploration of the hypothetical marking graph,
/// one declared branch at a time, fuel-limited by the search-step bound.
fn explore(
  input: SolverInput,
  fuel: Int,
  frontier: List(#(List(String), Marking)),
  visited: List(Marking),
) -> ExploreOutcome {
  case frontier {
    [] -> ExploreClosed(visited)
    [#(path, m), ..rest] ->
      case fuel <= 0 {
        True ->
          case eval_goal(m, input.goal) {
            True -> ExploreFound(path, m)
            False -> ExploreBoundHit([m, ..visited])
          }
        False ->
          case eval_goal(m, input.goal) {
            True -> ExploreFound(path, m)
            False -> {
              let visited = [m, ..visited]
              let blocked =
                list.append(visited, list.map(rest, fn(pr) { pr.1 }))
              let neighbors =
                fresh_neighbors(neighbors_of(input, path, m), blocked)
              explore(input, fuel - 1, list.append(rest, neighbors), visited)
            }
          }
      }
  }
}

fn total_tokens(marking: Marking) -> Int {
  list.fold(marking.places, 0, fn(acc, p) { acc + list.length(p.1) })
}

type CycleOutcome {
  CycleFound(
    prefix_path: List(String),
    cycle_path: List(String),
    cycle_start: Marking,
    cycle_end: Marking,
    closing_source: Marking,
  )
  CycleClosedNoCycle(visited: List(Marking))
  CycleBoundHit(visited: List(Marking))
}

type WfEntry {
  WfEntry(path: List(String), path_ms: List(Marking), marking: Marking)
}

fn marking_index(
  markings: List(Marking),
  target: Marking,
  index: Int,
) -> Result(Int, Nil) {
  case markings {
    [] -> Error(Nil)
    [marking, ..rest] ->
      case marking == target {
        True -> Ok(index)
        False -> marking_index(rest, target, index + 1)
      }
  }
}

fn cycle_paths(
  path: List(String),
  path_ms: List(Marking),
  cycle_start: Marking,
) -> Result(#(List(String), List(String)), Nil) {
  let active_markings = list.reverse(path_ms)
  use cycle_index <- result.try(marking_index(active_markings, cycle_start, 0))
  case path {
    [] -> Error(Nil)
    _ -> Ok(#(list.take(path, cycle_index), list.drop(path, cycle_index)))
  }
}

/// Bounded depth-first search for the first cycle, fuel-limited by the
/// search-step bound. A back edge to the active path closes a real cycle;
/// a marking expanded through another path is a convergence edge.
fn explore_wf(
  input: SolverInput,
  fuel: Int,
  frontier: List(WfEntry),
  explored: List(Marking),
) -> CycleOutcome {
  case frontier {
    [] -> CycleClosedNoCycle(explored)
    [WfEntry(path, path_ms, m), ..rest] ->
      case fuel <= 0 {
        True -> CycleBoundHit(explored)
        False ->
          case list.contains(explored, m) {
            True -> explore_wf(input, fuel, rest, explored)
            False -> {
              let neighbors = neighbors_of(input, path, m)
              case
                list.find(neighbors, fn(pr) { list.contains(path_ms, pr.1) })
              {
                Ok(#(p, m2)) ->
                  case cycle_paths(p, path_ms, m2) {
                    Ok(#(prefix, segment)) ->
                      CycleFound(prefix, segment, m2, m2, m)
                    Error(_) -> CycleBoundHit(explored)
                  }
                Error(_) -> {
                  let explored = [m, ..explored]
                  let blocked = list.append(path_ms, explored)
                  let fresh = fresh_neighbors(neighbors, blocked)
                  let entries =
                    list.map(fresh, fn(pr) {
                      WfEntry(pr.0, [pr.1, ..path_ms], pr.1)
                    })
                  explore_wf(
                    input,
                    fuel - 1,
                    list.append(entries, rest),
                    explored,
                  )
                }
              }
            }
          }
      }
  }
}

/// Check whether `input.goal` is reachable within the declared search
/// bound, after validating the declaration. `Unreachable` is only reported
/// with a fully-explored closure witness; a hit bound reports `Unknown`.
pub fn check_reachability(
  input: SolverInput,
) -> Result(ReachabilityResult, SolverFailure) {
  case validate(input) {
    Error(reason) -> Ok(ReachabilityInvalid(reason))
    Ok(_) ->
      case binding_bound_exceeded(input) {
        True ->
          Ok(
            ReachabilityUnknown(BindingBoundExhausted(input.bound.max_bindings)),
          )
        False ->
          case
            explore(
              input,
              input.bound.max_search_steps,
              [#([], input.marking)],
              [],
            )
          {
            ExploreFound(path, m) ->
              Ok(Reachable(ReachabilityWitness(path: path, final_marking: m)))
            ExploreClosed(visited) ->
              Ok(
                Unreachable(
                  ClosureWitness(
                    explored_markings: visited,
                    steps: list.length(visited),
                    frontier: [],
                  ),
                ),
              )
            ExploreBoundHit(_) ->
              Ok(
                ReachabilityUnknown(SearchStepBoundExhausted(
                  input.bound.max_search_steps,
                )),
              )
          }
      }
  }
}

/// A marking is deadlocked when the goal is not satisfied and no
/// transition is enabled; this is a separate proposition from goal
/// satisfaction and from reachability.
pub fn check_deadlock(
  input: SolverInput,
) -> Result(DeadlockResult, SolverFailure) {
  case validate(input) {
    Error(reason) -> Ok(DeadlockInvalid(reason))
    Ok(_) ->
      case binding_bound_exceeded(input) {
        True ->
          Ok(DeadlockUnknown(BindingBoundExhausted(input.bound.max_bindings)))
        False ->
          case derive_enabled_set(input) {
            EnabledInvalid(reason) -> Ok(DeadlockInvalid(reason))
            Enabled(s) ->
              case eval_goal(input.marking, input.goal) {
                True -> Ok(NotDeadlocked(s))
                False ->
                  case s.enabled {
                    [] ->
                      Ok(Deadlocked(DeadlockWitness(marking: input.marking)))
                    _ -> Ok(NotDeadlocked(s))
                  }
              }
          }
      }
  }
}

/// Check the finite marking closure for an active-path cycle.
pub fn check_well_foundedness(
  input: SolverInput,
) -> Result(WellFoundednessResult, SolverFailure) {
  case validate(input) {
    Error(reason) -> Ok(WellFoundednessInvalid(reason))
    Ok(_) ->
      case binding_bound_exceeded(input) {
        True ->
          Ok(
            WellFoundednessUnknown(BindingBoundExhausted(
              input.bound.max_bindings,
            )),
          )
        False ->
          case
            explore_wf(
              input,
              input.bound.max_search_steps,
              [WfEntry([], [input.marking], input.marking)],
              [],
            )
          {
            CycleFound(prefix, segment, start, end, closing_source) ->
              Ok(
                NotWellFounded(CycleWitness(
                  prefix_path: prefix,
                  cycle_path: segment,
                  cycle_start: start,
                  cycle_end: end,
                  measure_decreasing: total_tokens(end)
                    < total_tokens(closing_source),
                )),
              )
            CycleClosedNoCycle(explored) ->
              Ok(
                WellFounded(
                  AcyclicWitness(
                    explored_markings: explored,
                    steps: list.length(explored),
                    frontier: [],
                  ),
                ),
              )
            CycleBoundHit(_) ->
              Ok(
                WellFoundednessUnknown(SearchStepBoundExhausted(
                  input.bound.max_search_steps,
                )),
              )
          }
      }
  }
}
