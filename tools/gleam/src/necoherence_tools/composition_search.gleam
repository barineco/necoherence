// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import necoherence/exact_json as kdl
import necoherence/semantic_composition.{
  type AvailableValue, type BranchFact, type BranchTrace, type CandidateBudget,
  type CandidateTree, type ChoiceSkeleton, type ClosedSearchState,
  type CompositionDecision, type CompositionEngineFailure,
  type ConnectionFailure, type PreparedCompositionInput, type ProducerRef,
  type ResourceCorrespondence, type ReturnPlan, type SearchState,
  type TerminalAssessment, type UnresolvedObligation, AnyFeasible,
  AnyFeasibleEvidence, BranchBoundExhausted, BranchInhabitation, BranchTrace,
  CandidateBudget, CandidateTree, ChoiceCoverage, ClosedSearchState,
  CompositionClosureWitness, CompositionUnknown, ContractViolation, EmptyValues,
  Feasible, GuardAbsent, GuardAccepted, GuardNull, GuardRejected, GuardVariant,
  Inhabitation, Initial, InitialInput, InvalidLowering, PlanTree, RawComposition,
  RejectedLowering, RequireUnique, ResourceFailure, ResourceSolverUnknown,
  ResourceTraceCertificate, ResourceUnreachable, Return, ReturnSuccess, Solved,
  StateBoundExhausted, SuppliedValue, TerminalCoverage, TerminalUnknown, Unique,
  UnknownLowering, UnresolvedMeaning, UnresolvedUniqueness, Validate, Witness,
  add_discriminator, at, bounded_slot_samples, candidate_components,
  candidate_key, check_return, choice_states, collect, decide_ambiguous,
  decide_unreachable, distinct_candidates, effective_projection, enumerate_state,
  evaluate_guard_arm, fresh_budget, guard_declaration, index_of, initial_state,
  lower_resource_trace, merge_choice, prepared_empty, prepared_graph,
  prepared_initial_obligations, prepared_input, project_owned, replace_at,
  require, resolved_shape, resource_trace_meaning, sample_value_fuel, slot_empty,
  unique, verify_acyclic_witness, verify_closure_witness, verify_composition,
  verify_reachability_witness, verify_return_values, verify_value_models,
}
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource
import necoherence_tools/typed_mapping_solver as search

fn find(values: List(a), predicate: fn(a) -> Bool) -> Option(a) {
  case list.find(values, predicate) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn filter_options(values: List(a), action: fn(a) -> Option(b)) -> List(b) {
  list.filter_map(values, fn(value) { option.to_result(action(value), Nil) })
}

fn put_member(
  members: List(#(String, kdl.JsonValue)),
  name: String,
  value: kdl.JsonValue,
) -> List(#(String, kdl.JsonValue)) {
  case list.any(members, fn(member) { member.0 == name }) {
    True ->
      list.map(members, fn(member) {
        case member.0 == name {
          True -> #(name, value)
          False -> member
        }
      })
    False -> list.append(members, [#(name, value)])
  }
}

fn replace_projected(
  value: types.SlotValue(kdl.JsonValue),
  path: types.ValuePath,
  replacement: types.SlotValue(kdl.JsonValue),
) -> Option(types.SlotValue(kdl.JsonValue)) {
  case path {
    [] -> Some(replacement)
    _ ->
      case value {
        types.Present(value) ->
          option.map(replace_json(value, path, replacement), types.Present)
        _ -> None
      }
  }
}

fn replace_json(
  value: kdl.JsonValue,
  path: types.ValuePath,
  replacement: types.SlotValue(kdl.JsonValue),
) -> Option(kdl.JsonValue) {
  case value, path {
    kdl.JsonValueObj(members), [types.Field(name), ..rest] -> {
      let replaced = case rest {
        [] -> Some(replacement)
        _ ->
          option.then(find(members, fn(pair) { pair.0 == name }), fn(pair) {
            option.map(replace_json(pair.1, rest, replacement), types.Present)
          })
      }
      option.map(replaced, fn(replaced) {
        kdl.JsonValueObj(case replaced {
          types.Absent -> list.filter(members, fn(pair) { pair.0 != name })
          types.Null -> put_member(members, name, kdl.JsonValueNull)
          types.Present(value) -> put_member(members, name, value)
        })
      })
    }
    kdl.JsonValueArr(items), [types.Index(index), ..rest] ->
      option.then(at(items, index), fn(value) {
        let replaced = case rest {
          [] ->
            case replacement {
              types.Absent -> None
              types.Null -> Some(kdl.JsonValueNull)
              types.Present(value) -> Some(value)
            }
          _ -> replace_json(value, rest, replacement)
        }
        option.map(replaced, fn(value) {
          kdl.JsonValueArr(
            list.index_map(items, fn(item, position) {
              case position == index {
                True -> value
                False -> item
              }
            }),
          )
        })
      })
    kdl.JsonValueObj(_), [types.Variant(_), ..rest] ->
      case rest {
        [] ->
          case replacement {
            types.Present(value) -> Some(value)
            _ -> None
          }
        _ -> replace_json(value, rest, replacement)
      }
    _, _ -> None
  }
}

pub fn fact_replacements(
  prepared: PreparedCompositionInput,
  state: SearchState,
  fact: BranchFact,
) -> List(types.SlotValue(kdl.JsonValue)) {
  let limit = prepared_input(prepared).bounds.max_type_obligations
  let maximum = prepared_input(prepared).bounds.max_sample_length
  case
    guard_declaration(prepared_input(prepared), fact.guard),
    effective_projection(prepared, state, fact.inspected)
  {
    Some(guard), Ok(projected) -> {
      let values = case fact.arm {
        GuardAbsent -> [types.Absent]
        GuardNull -> [types.Null]
        GuardAccepted ->
          case guard.kind {
            Validate(contract) ->
              bounded_slot_samples(
                prepared_graph(prepared),
                contract,
                limit,
                maximum,
              ).values
            _ -> []
          }
        GuardVariant(tag) -> {
          let branch_values = case
            resolved_shape(
              prepared_graph(prepared),
              projected.destination.type_ref,
            )
          {
            Some(types.TaggedUnionShape(spec)) ->
              case find(spec.branches, fn(branch) { branch.wire_tag == tag }) {
                None -> []
                Some(branch) ->
                  list.map(
                    filter_options(
                      sample_value_fuel(
                        prepared_graph(prepared),
                        branch.target,
                        [],
                        limit,
                        maximum,
                      ).values,
                      fn(value) {
                        add_discriminator(
                          prepared_graph(prepared).profile.tag,
                          value,
                          tag,
                        )
                      },
                    ),
                    types.Present,
                  )
              }
            _ -> []
          }
          list.append(
            bounded_slot_samples(
              prepared_graph(prepared),
              projected.destination,
              limit,
              maximum,
            ).values,
            branch_values,
          )
        }
        GuardRejected ->
          case guard.kind {
            Validate(_) ->
              bounded_slot_samples(
                prepared_graph(prepared),
                projected.destination,
                limit,
                maximum,
              ).values
            _ -> []
          }
        _ ->
          bounded_slot_samples(
            prepared_graph(prepared),
            projected.destination,
            limit,
            maximum,
          ).values
      }
      list.filter(values, fn(value) {
        evaluate_guard_arm(prepared_graph(prepared), guard, value)
        == Ok(fact.arm)
      })
    }
    _, _ -> []
  }
}

fn producer_model(
  prepared: PreparedCompositionInput,
  state: SearchState,
  source: AvailableValue,
) -> Option(types.SlotValue(kdl.JsonValue)) {
  let fixed = case source.producer {
    Initial(id) ->
      option.then(
        find(prepared_input(prepared).initial_inputs, fn(initial) {
          initial.id == id
        }),
        fn(initial) {
          case initial.source {
            SuppliedValue(value) -> Some(value)
            _ -> None
          }
        },
      )
    _ -> None
  }
  let limit = prepared_input(prepared).bounds.max_type_obligations
  let candidates = case fixed {
    Some(value) -> [value]
    None ->
      bounded_slot_samples(
        prepared_graph(prepared),
        source.contract,
        limit,
        prepared_input(prepared).bounds.max_sample_length,
      ).values
  }
  let facts =
    list.filter(state.facts, fn(fact) {
      fact.inspected.producer == source.producer
    })
  let candidates = case fixed {
    Some(_) -> candidates
    None ->
      list.fold(facts, candidates, fn(candidates, fact) {
        let replacements = fact_replacements(prepared, state, fact)
        let variants =
          list.flat_map(candidates, fn(candidate) {
            filter_options(replacements, fn(replacement) {
              replace_projected(candidate, fact.inspected.path, replacement)
            })
          })
        list.take(unique(list.append(candidates, variants)), limit)
      })
  }
  find(candidates, fn(value) {
    validation.accepts_slot(prepared_graph(prepared), source.contract, value)
    && list.all(facts, fn(fact) {
      case guard_declaration(prepared_input(prepared), fact.guard) {
        Some(guard) ->
          evaluate_guard_arm(
            prepared_graph(prepared),
            guard,
            project_owned(
              prepared_graph(prepared).profile.tag,
              value,
              fact.inspected.path,
            ),
          )
          == Ok(fact.arm)
        None -> False
      }
    })
  })
}

fn derive_value_models(
  prepared: PreparedCompositionInput,
  state: SearchState,
) -> Result(
  List(#(ProducerRef, types.SlotValue(kdl.JsonValue))),
  UnresolvedObligation,
) {
  use values <- result.try(
    collect(state.available, fn(source) {
      use _ <- result.try(
        case
          validation.meaning_obligations(prepared_graph(prepared), [
            source.contract.type_ref,
          ])
        {
          [] -> Ok(Nil)
          reasons -> Error(UnresolvedMeaning(reasons))
        },
      )
      use _ <- result.try(case source.producer {
        Initial(id) ->
          case
            find(prepared_input(prepared).initial_inputs, fn(initial) {
              initial.id == id
            })
          {
            Some(InitialInput(_, _, SuppliedValue(value), _)) ->
              case
                validation.validate_slot(
                  prepared_graph(prepared),
                  source.contract,
                  value,
                )
              {
                Error(validation.Unresolved(reasons)) ->
                  Error(UnresolvedMeaning(reasons))
                _ -> Ok(Nil)
              }
            _ -> Ok(Nil)
          }
        _ -> Ok(Nil)
      })
      use value <- result.try(option.to_result(
        producer_model(prepared, state, source),
        Inhabitation(source.producer, source.contract),
      ))
      Ok(#(source.producer, value))
    }),
  )
  use _ <- result.try(
    result.map_error(verify_value_models(prepared, state, values), fn(_) {
      BranchInhabitation
    }),
  )
  Ok(values)
}

type SearchEngine {
  SearchEngine(
    prepared: PreparedCompositionInput,
    budget: CandidateBudget,
    states: List(ClosedSearchState),
    candidates: List(List(CandidateTree)),
    expanded: Int,
    unknown: List(UnresolvedObligation),
    frontier: List(SearchState),
    failures: List(ConnectionFailure),
  )
}

fn engine_candidates(engine: SearchEngine, index: Int) -> List(CandidateTree) {
  option.unwrap(at(engine.candidates, index), [])
}

fn engine_success(engine: SearchEngine, index: Int) -> Bool {
  list.any(engine_candidates(engine, index), fn(candidate) { candidate.success })
}

fn any_feasible(prepared: PreparedCompositionInput) -> Bool {
  prepared_input(prepared).selection_policy == Some(AnyFeasible)
}

fn assess_terminal(
  prepared: PreparedCompositionInput,
  state: SearchState,
  terminal: ReturnPlan,
) -> Result(TerminalAssessment, CompositionEngineFailure) {
  use _ <- result.try(result.map_error(
    check_return(prepared, state, terminal),
    Witness,
  ))
  let empty =
    list.map(
      list.filter(state.available, fn(source) {
        slot_empty(source.contract, prepared_empty(prepared))
      }),
      fn(source) { source.producer },
    )
  case empty {
    [_, ..] -> Ok(EmptyValues(empty))
    [] ->
      case derive_value_models(prepared, state) {
        Error(reason) -> Ok(TerminalUnknown([reason]))
        Ok(models) ->
          case verify_return_values(prepared, terminal, models) {
            Error(_) -> Ok(TerminalUnknown([BranchInhabitation]))
            Ok(_) -> {
              let trace = BranchTrace(state.trace, terminal)
              case lower_resource_trace(prepared, trace) {
                Error(UnknownLowering(reason)) -> Ok(TerminalUnknown([reason]))
                Error(InvalidLowering(reason)) ->
                  Ok(RejectedLowering(trace, reason))
                Ok(#(input, correspondence)) ->
                  case resource_trace_meaning(prepared, correspondence) {
                    Error(reason) -> Ok(TerminalUnknown([reason]))
                    Ok(_) ->
                      assess_resource_terminal(
                        trace,
                        input,
                        correspondence,
                        models,
                      )
                  }
              }
            }
          }
      }
  }
}

fn assess_resource_terminal(
  trace: BranchTrace,
  input: resource.SolverInput,
  correspondence: ResourceCorrespondence,
  models: List(#(ProducerRef, types.SlotValue(kdl.JsonValue))),
) -> Result(TerminalAssessment, CompositionEngineFailure) {
  use decision <- result.try(result.map_error(
    search.check_reachability(input),
    ResourceFailure,
  ))
  case decision {
    resource.Reachable(reachability) -> {
      use _ <- result.try(result.map_error(
        verify_reachability_witness(input, reachability),
        Witness,
      ))
      use _ <- result.try(require(
        reachability.path == correspondence.execution_order,
        ContractViolation(
          "resource solver path differs from the selected finite trace",
        ),
      ))
      use well_foundedness <- result.try(result.map_error(
        search.check_well_foundedness(input),
        ResourceFailure,
      ))
      case well_foundedness {
        resource.WellFounded(acyclicity) -> {
          use _ <- result.try(result.map_error(
            verify_acyclic_witness(input, acyclicity),
            Witness,
          ))
          Ok(
            Feasible(ResourceTraceCertificate(
              trace,
              input,
              correspondence,
              reachability,
              acyclicity,
              models,
            )),
          )
        }
        resource.WellFoundednessUnknown(reason) ->
          Ok(TerminalUnknown([ResourceSolverUnknown(reason)]))
        _ ->
          Error(ContractViolation(
            "finite permit-controlled trace is not acyclic",
          ))
      }
    }
    resource.Unreachable(closure) -> {
      use _ <- result.try(result.map_error(
        verify_closure_witness(input, closure),
        Witness,
      ))
      Ok(ResourceUnreachable(trace, input, correspondence, closure))
    }
    resource.ReachabilityUnknown(reason) ->
      Ok(TerminalUnknown([ResourceSolverUnknown(reason)]))
    resource.ReachabilityInvalid(_) ->
      Error(ContractViolation("validated lowering became invalid"))
  }
}

fn visit(
  engine: SearchEngine,
  state: SearchState,
) -> Result(#(Int, SearchEngine), CompositionEngineFailure) {
  case
    index_of(list.map(engine.states, fn(record) { record.state }), state, 0)
  {
    Some(index) -> Ok(#(index, engine))
    None -> {
      let index = list.length(engine.states)
      let enumeration = enumerate_state(engine.prepared, state, engine.budget)
      let record =
        ClosedSearchState(
          state,
          [],
          [],
          enumeration.failures,
          enumeration.missing,
        )
      let engine =
        SearchEngine(
          ..engine,
          budget: enumeration.budget,
          states: list.append(engine.states, [record]),
          candidates: list.append(engine.candidates, [[]]),
          failures: list.append(engine.failures, enumeration.failures),
          unknown: list.append(engine.unknown, enumeration.unknown),
        )
      use engine <- result.try(
        list.fold(enumeration.terminals, Ok(engine), fn(acc, terminal) {
          use engine <- result.try(acc)
          use assessment <- result.try(assess_terminal(
            engine.prepared,
            state,
            terminal,
          ))
          use record <- result.try(option.to_result(
            at(engine.states, index),
            ContractViolation("search state disappeared"),
          ))
          let record =
            ClosedSearchState(
              ..record,
              terminals: list.append(record.terminals, [
                TerminalCoverage(terminal, assessment),
              ]),
            )
          let engine =
            SearchEngine(
              ..engine,
              states: replace_at(engine.states, index, record),
            )
          case assessment {
            Feasible(certificate) ->
              case 1 > prepared_input(engine.prepared).bounds.max_branch_nodes {
                True ->
                  Ok(
                    SearchEngine(
                      ..engine,
                      budget: CandidateBudget(
                        ..engine.budget,
                        exhausted_branches: True,
                      ),
                    ),
                  )
                False -> {
                  let success = case terminal {
                    ReturnSuccess(_) -> True
                    _ -> False
                  }
                  let candidate =
                    CandidateTree(
                      PlanTree(list.length(state.trace), Return(terminal)),
                      success,
                      [certificate],
                      1,
                    )
                  Ok(
                    SearchEngine(
                      ..engine,
                      candidates: replace_at(
                        engine.candidates,
                        index,
                        list.append(engine_candidates(engine, index), [
                          candidate,
                        ]),
                      ),
                    ),
                  )
                }
              }
            TerminalUnknown(obligations) ->
              Ok(
                SearchEngine(
                  ..engine,
                  unknown: list.append(engine.unknown, obligations),
                ),
              )
            _ -> Ok(engine)
          }
        }),
      )
      case any_feasible(engine.prepared) && engine_success(engine, index) {
        True -> Ok(#(index, engine))
        False ->
          case
            enumeration.choices != []
            && engine.expanded
            >= prepared_input(engine.prepared).bounds.max_expanded_states
          {
            True ->
              Ok(#(
                index,
                SearchEngine(
                  ..engine,
                  unknown: list.append(engine.unknown, [StateBoundExhausted]),
                  frontier: list.append(engine.frontier, [state]),
                ),
              ))
            False -> {
              let engine = case enumeration.choices {
                [] -> engine
                _ -> SearchEngine(..engine, expanded: engine.expanded + 1)
              }
              use engine <- result.try(visit_choices(
                engine,
                state,
                index,
                enumeration.choices,
              ))
              let engine =
                SearchEngine(
                  ..engine,
                  candidates: replace_at(
                    engine.candidates,
                    index,
                    distinct_candidates(
                      prepared_input(engine.prepared),
                      engine_candidates(engine, index),
                    ),
                  ),
                )
              let engine = case engine.budget.exhausted_branches {
                True ->
                  SearchEngine(
                    ..engine,
                    unknown: list.append(engine.unknown, [BranchBoundExhausted]),
                    frontier: list.append(engine.frontier, [state]),
                  )
                False -> engine
              }
              Ok(#(index, engine))
            }
          }
      }
    }
  }
}

fn visit_choices(
  engine: SearchEngine,
  state: SearchState,
  index: Int,
  choices: List(ChoiceSkeleton),
) -> Result(SearchEngine, CompositionEngineFailure) {
  case choices {
    [] -> Ok(engine)
    [choice, ..rest] -> {
      use children <- result.try(result.map_error(
        choice_states(engine.prepared, state, choice),
        Witness,
      ))
      use visited <- result.try(
        list.fold(children, Ok(#([], engine)), fn(acc, child) {
          use acc <- result.try(acc)
          use visited <- result.try(visit(acc.1, child))
          Ok(#(list.append(acc.0, [visited.0]), visited.1))
        }),
      )
      let #(indices, engine) = visited
      let candidates =
        list.map(indices, fn(index) { engine_candidates(engine, index) })
      let #(candidates, budget) =
        merge_choice(
          prepared_input(engine.prepared),
          state,
          choice,
          candidates,
          engine.budget,
        )
      use record <- result.try(option.to_result(
        at(engine.states, index),
        ContractViolation("search state disappeared"),
      ))
      let record =
        ClosedSearchState(
          ..record,
          choices: list.append(record.choices, [ChoiceCoverage(choice, indices)]),
        )
      let engine =
        SearchEngine(
          ..engine,
          budget: budget,
          states: replace_at(engine.states, index, record),
          candidates: replace_at(
            engine.candidates,
            index,
            list.append(engine_candidates(engine, index), candidates),
          ),
        )
      case any_feasible(engine.prepared) && engine_success(engine, index) {
        True -> Ok(engine)
        False -> visit_choices(engine, state, index, rest)
      }
    }
  }
}

pub fn derive_composition(
  prepared: PreparedCompositionInput,
) -> Result(CompositionDecision, CompositionEngineFailure) {
  let unknown = case prepared_initial_obligations(prepared) {
    [] -> []
    obligations -> [UnresolvedMeaning(obligations)]
  }
  let engine =
    SearchEngine(prepared, fresh_budget(), [], [], 0, unknown, [], [])
  use visited <- result.try(visit(engine, initial_state(prepared)))
  let #(root, engine) = visited
  let feasible =
    list.filter(engine_candidates(engine, root), fn(candidate) {
      candidate.success
    })
  let policy =
    option.unwrap(prepared_input(prepared).selection_policy, RequireUnique)
  case policy, feasible {
    RequireUnique, [first, second, ..] ->
      decide_ambiguous(prepared, first, second)
    _, [candidate, ..] ->
      case policy == AnyFeasible || engine.unknown == [] {
        True -> {
          let selection = case policy {
            AnyFeasible -> AnyFeasibleEvidence
            RequireUnique ->
              Unique(
                CompositionClosureWitness(
                  prepared_input(prepared),
                  root,
                  engine.states,
                ),
                candidate_key(prepared_input(prepared), candidate),
              )
          }
          use components <- result.try(candidate_components(prepared, candidate))
          let raw = RawComposition(components.0, components.1, selection)
          use checked <- result.try(result.map_error(
            verify_composition(prepared, raw),
            Witness,
          ))
          Ok(Solved(checked, selection))
        }
        False ->
          Ok(CompositionUnknown(
            unique(list.append(engine.unknown, [UnresolvedUniqueness])),
            case engine.frontier {
              [] -> [initial_state(prepared)]
              frontier -> frontier
            },
            engine.failures,
          ))
      }
    _, _ ->
      case engine.unknown {
        [_, ..] ->
          Ok(CompositionUnknown(
            unique(engine.unknown),
            case engine.frontier {
              [] -> [initial_state(prepared)]
              frontier -> frontier
            },
            engine.failures,
          ))
        [] -> {
          let closure =
            CompositionClosureWitness(
              prepared_input(prepared),
              root,
              engine.states,
            )
          decide_unreachable(prepared, closure)
        }
      }
  }
}
