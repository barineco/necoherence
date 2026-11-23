// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import necoherence/composition_plan.{
  type FailureEmbeddingId, type InclusionFailure, type InputId, type SiteId,
  type ValueRef,
}
import necoherence/inclusion.{distinct, index_of}
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource

pub type WitnessFailure {
  InputRevisionMismatch
  InitialMembership(input: InputId)
  ProducerMismatch(value: ValueRef)
  ProjectionMismatch(failure: validation.ProjectionFailure)
  SourceConstraintMismatch(value: ValueRef)
  InclusionMismatch(failure: InclusionFailure)
  SuppliedValueMismatch(value: ValueRef)
  ConstructionMismatch(reference: types.TypeRef)
  MissingBinding(identity: String)
  SignatureMismatch(site: SiteId)
  GuardNotDominating(value: ValueRef)
  IncompleteBranchCoverage(identity: String)
  FailureEmbeddingMismatch(embedding: FailureEmbeddingId)
  GoalMismatch
  RankViolation
  ResourceLoweringMismatch(reason: String)
  ResourceReplayMismatch(reason: String)
  ForgedClosure(reason: String)
  ForgedAcyclicity(reason: String)
  MissingEvidence(reason: String)
}

pub opaque type CheckedReachability {
  CheckedReachability(
    input: resource.SolverInput,
    witness: resource.ReachabilityWitness,
  )
}

pub opaque type CheckedResourceClosure {
  CheckedResourceClosure(
    input: resource.SolverInput,
    markings: List(resource.Marking),
  )
}

pub opaque type CheckedClosure {
  CheckedClosure(
    input: resource.SolverInput,
    witness: resource.ClosureWitness,
    closure: CheckedResourceClosure,
  )
}

pub opaque type CheckedAcyclic {
  CheckedAcyclic(
    input: resource.SolverInput,
    witness: resource.AcyclicWitness,
    closure: CheckedResourceClosure,
    order: List(resource.Marking),
  )
}

fn successor_covered(
  input: resource.SolverInput,
  markings: List(resource.Marking),
  marking: resource.Marking,
  transition: resource.TypedTransition,
) -> Bool {
  case resource.step_at(input, marking, transition.identity) {
    None -> True
    Some(next) -> list.contains(markings, next)
  }
}

fn successor_ranked(
  input: resource.SolverInput,
  order: List(resource.Marking),
  marking: resource.Marking,
  transition: resource.TypedTransition,
) -> Bool {
  case resource.step_at(input, marking, transition.identity) {
    None -> True
    Some(next) ->
      case index_of(marking, order), index_of(next, order) {
        Some(from), Some(to) -> from < to
        _, _ -> False
      }
  }
}

fn successors_covered_at(
  input: resource.SolverInput,
  markings: List(resource.Marking),
  marking: resource.Marking,
) -> Bool {
  list.all(input.transitions, fn(transition) {
    successor_covered(input, markings, marking, transition)
  })
}

fn ranked_at(
  input: resource.SolverInput,
  order: List(resource.Marking),
  marking: resource.Marking,
) -> Bool {
  list.all(input.transitions, fn(transition) {
    successor_ranked(input, order, marking, transition)
  })
}

pub fn verify_reachability_witness(
  input: resource.SolverInput,
  witness: resource.ReachabilityWitness,
) -> Result(CheckedReachability, WitnessFailure) {
  use _ <- result.try(case result.is_ok(resource.validate(input)) {
    True -> Ok(Nil)
    False -> Error(ResourceReplayMismatch("invalid resource declaration"))
  })
  use _ <- result.try(case !resource.binding_bound_exceeded(input) {
    True -> Ok(Nil)
    False -> Error(ResourceReplayMismatch("binding bound"))
  })
  use _ <- result.try(
    case list.length(witness.path) <= input.bound.max_search_steps {
      True -> Ok(Nil)
      False -> Error(ResourceReplayMismatch("path step bound"))
    },
  )
  use _ <- result.try(
    case
      resource.path_replay(input, input.marking, witness.path)
      == Some(witness.final_marking)
    {
      True -> Ok(Nil)
      False -> Error(ResourceReplayMismatch("enabled path or final marking"))
    },
  )
  use _ <- result.try(
    case resource.eval_goal(witness.final_marking, input.goal) {
      True -> Ok(Nil)
      False -> Error(ResourceReplayMismatch("terminal resource goal"))
    },
  )
  Ok(CheckedReachability(input, witness))
}

fn verify_finite_resource_closure(
  input: resource.SolverInput,
  markings: List(resource.Marking),
  steps: Int,
  frontier: List(resource.Marking),
) -> Result(CheckedResourceClosure, WitnessFailure) {
  use _ <- result.try(case result.is_ok(resource.validate(input)) {
    True -> Ok(Nil)
    False -> Error(ForgedClosure("invalid resource declaration"))
  })
  use _ <- result.try(case !resource.binding_bound_exceeded(input) {
    True -> Ok(Nil)
    False -> Error(ForgedClosure("resource binding bound"))
  })
  use _ <- result.try(
    case
      !{
        frontier != []
        || steps != list.length(markings)
        || input.bound.max_search_steps < steps
      }
    {
      True -> Ok(Nil)
      False -> Error(ForgedClosure("frontier, steps, or resource bound"))
    },
  )
  use _ <- result.try(case list.contains(markings, input.marking) {
    True -> Ok(Nil)
    False -> Error(ForgedClosure("initial marking omitted"))
  })
  use _ <- result.try(case distinct(markings) == markings {
    True -> Ok(Nil)
    False -> Error(ForgedClosure("duplicated explored marking"))
  })
  use _ <- result.try(
    case
      list.all(markings, fn(marking) {
        successors_covered_at(input, markings, marking)
      })
    {
      True -> Ok(Nil)
      False -> Error(ForgedClosure("enabled successor omitted"))
    },
  )
  Ok(CheckedResourceClosure(input, markings))
}

pub fn verify_closure_witness(
  input: resource.SolverInput,
  witness: resource.ClosureWitness,
) -> Result(CheckedClosure, WitnessFailure) {
  use closure <- result.try(verify_finite_resource_closure(
    input,
    witness.explored_markings,
    witness.steps,
    witness.frontier,
  ))
  use _ <- result.try(
    case
      list.all(witness.explored_markings, fn(marking) {
        !resource.eval_goal(marking, input.goal)
      })
    {
      True -> Ok(Nil)
      False -> Error(ForgedClosure("closed marking satisfies the goal"))
    },
  )
  Ok(CheckedClosure(input, witness, closure))
}

fn topological_markings(
  input: resource.SolverInput,
  fuel: Int,
  remaining: List(resource.Marking),
  ordered: List(resource.Marking),
) -> List(resource.Marking) {
  case fuel, remaining {
    0, _ -> ordered
    _, [] -> ordered
    _, _ -> {
      let root =
        option.from_result(
          list.find(remaining, fn(candidate) {
            list.all(remaining, fn(predecessor) {
              list.all(input.transitions, fn(transition) {
                case resource.step_at(input, predecessor, transition.identity) {
                  None -> True
                  Some(next) -> next != candidate
                }
              })
            })
          }),
        )
      case root {
        None -> ordered
        Some(selected) ->
          topological_markings(
            input,
            fuel - 1,
            list.filter(remaining, fn(marking) { marking != selected }),
            list.append(ordered, [selected]),
          )
      }
    }
  }
}

fn order_covers_explored(
  explored: List(resource.Marking),
  order: List(resource.Marking),
) -> Result(Nil, WitnessFailure) {
  case list.all(explored, fn(marking) { list.contains(order, marking) }) {
    True -> Ok(Nil)
    False -> Error(ForgedAcyclicity("explored marking omitted from order"))
  }
}

pub fn verify_acyclic_witness(
  input: resource.SolverInput,
  witness: resource.AcyclicWitness,
) -> Result(CheckedAcyclic, WitnessFailure) {
  use closure <- result.try(verify_finite_resource_closure(
    input,
    witness.explored_markings,
    witness.steps,
    witness.frontier,
  ))
  let order =
    topological_markings(
      input,
      list.length(witness.explored_markings),
      witness.explored_markings,
      [],
    )
  use _ <- result.try(
    case
      list.all(witness.explored_markings, fn(marking) {
        ranked_at(input, order, marking)
      })
    {
      True -> Ok(Nil)
      False -> Error(ForgedAcyclicity("closed resource graph contains a cycle"))
    },
  )
  use _ <- result.try(order_covers_explored(witness.explored_markings, order))
  Ok(CheckedAcyclic(input, witness, closure, order))
}
