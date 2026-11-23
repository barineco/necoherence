// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import necoherence/composition_plan.{
  type CompositionInput, type CompositionInputFailure, type ConstructionRule,
  type FailureOrigin, type FunctionSignature, type PreparedCompositionInput,
  type ProducerRef, type ResourceLotRef, type ResourceProducer,
  type SourceConstraint, type UnresolvedObligation, AnyCompatible, Argument,
  ConstrainedNestedField, ConstructionFieldSourceUndefined,
  ConstructionNotProduct, CyclicConstruction, DeclaredFailure, DeclaredTransform,
  DuplicateIdentity, EmptyGoal, ExplicitSiteOrderInvalid,
  FailureEmbeddingOriginUndefined, FieldConstraintUnknownField, FunctionFailure,
  GoalSourceConstraintUndefined, GuardFailure, Initial, InitialLot, InitialOnly,
  InitialResource, InputBasisMismatch, InvalidEmptyTypeClosure,
  InvalidInitialValue, InvalidResourceDeclaration, InvalidSignature,
  InvocationOutcome, NestedConstructionMismatch, NestedFieldUndeclared,
  Operation, OutcomeResource, ProducedBy, ProducedLot, Pure, PureFunction,
  SiteEffectNotPermitted, SuppliedValue, TransformNotPermitted,
  UnresolvedFunction, UnresolvedType, Validate, function_identity,
  prepared_composition_input, semantic_basis_of, signature, site_signature,
}
import necoherence/inclusion.{empty_types, resolved_shape, verify_empty_types}
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

pub type LoweringFailure {
  InvalidLowering(reason: String)
  UnknownLowering(obligation: UnresolvedObligation)
}

fn unique_ids(
  kind: String,
  identities: List(String),
) -> Result(Nil, CompositionInputFailure) {
  unique_ids_from([], kind, identities)
}

fn unique_ids_from(
  seen: List(String),
  kind: String,
  identities: List(String),
) -> Result(Nil, CompositionInputFailure) {
  case identities {
    [] -> Ok(Nil)
    [identity, ..rest] ->
      case identity == "" || list.contains(seen, identity) {
        True -> Error(DuplicateIdentity(kind, identity))
        False -> unique_ids_from([identity, ..seen], kind, rest)
      }
  }
}

fn check_type(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> Result(Nil, CompositionInputFailure) {
  case
    option.from_result(
      list.find(graph.nodes, fn(node) { node.reference == reference }),
    )
    != None
  {
    True -> Ok(Nil)
    False -> Error(UnresolvedType(reference))
  }
}

fn source_constraint_defined(
  prepared: validation.PreparedGraph,
  input: CompositionInput,
  constraint: SourceConstraint,
) -> Bool {
  case constraint {
    AnyCompatible -> True
    InitialOnly(id, path) ->
      option.unwrap(
        option.map(declared_value(input, Initial(id)), fn(contract) {
          constraint_path_defined(prepared, contract.0, path)
        }),
        False,
      )
    ProducedBy(site, outcome, port, path) ->
      option.unwrap(
        option.map(
          declared_value(input, InvocationOutcome(site, outcome, port)),
          fn(contract) { constraint_path_defined(prepared, contract.0, path) },
        ),
        False,
      )
  }
}

fn constraint_path_defined(
  prepared: validation.PreparedGraph,
  contract: types.SlotContract,
  path: types.ValuePath,
) -> Bool {
  let assumptions =
    option.values(
      list.index_map(path, fn(step, index) {
        case step {
          types.Variant(tag) ->
            Some(validation.Variant(list.take(path, index), tag))
          _ -> None
        }
      }),
    )
  result.is_ok(validation.project_slot(prepared, contract, path, assumptions))
}

pub type ConstructionFieldSelection {
  ConstructionFieldSelection(
    wire_name: String,
    slot: types.SlotContract,
    constraint: SourceConstraint,
    required: Bool,
    nested: List(String),
  )
}

fn failure_origin_defined(
  input: CompositionInput,
  origin: FailureOrigin,
) -> Bool {
  case origin {
    FunctionFailure(reference, id) ->
      option.unwrap(
        option.map(signature(input, reference), fn(function) {
          list.any(function.outcomes, fn(outcome) {
            outcome.id == id && outcome.form == DeclaredFailure
          })
        }),
        False,
      )
    GuardFailure(id, _) ->
      list.any(input.invocation_domain.guards, fn(guard) { guard.id == id })
  }
}

pub type LotDeclaration {
  LotDeclaration(
    token_type: types.TypeRef,
    producer: ResourceProducer,
    revision: Int,
    quantity: Int,
    provenance: String,
  )
}

pub fn declared_lot(
  input: CompositionInput,
  reference: ResourceLotRef,
) -> Option(LotDeclaration) {
  case reference {
    InitialLot(id) ->
      option.map(
        option.from_result(
          list.find(input.initial_resources, fn(lot) { lot.id == id }),
        ),
        fn(lot) {
          LotDeclaration(
            lot.token_type,
            lot.producer,
            lot.revision,
            lot.quantity,
            lot.provenance,
          )
        },
      )
    ProducedLot(site, outcome, id) ->
      option.then(
        option.then(site_signature(input, site), fn(function) {
          option.from_result(
            list.find(function.outcomes, fn(contract) { contract.id == outcome }),
          )
        }),
        fn(outcome_contract) {
          option.map(
            option.from_result(
              list.find(outcome_contract.produced_resources, fn(production) {
                production.id == id
              }),
            ),
            fn(production) {
              LotDeclaration(
                production.token_type,
                OutcomeResource(site, outcome),
                production.revision,
                production.quantity,
                production.provenance,
              )
            },
          )
        },
      )
  }
}

fn construction_reachable(
  rules: List(ConstructionRule),
  fuel: Int,
  pending: List(String),
  seen: List(String),
) -> List(String) {
  case fuel <= 0, pending {
    True, _ -> seen
    False, [] -> seen
    False, [identity, ..rest] ->
      case list.contains(seen, identity) {
        True -> construction_reachable(rules, fuel - 1, rest, seen)
        False -> {
          let children =
            option.unwrap(
              option.map(
                option.from_result(
                  list.find(rules, fn(rule) { rule.identity == identity }),
                ),
                fn(rule) { list.map(rule.nested_fields, fn(pair) { pair.1 }) },
              ),
              [],
            )
          construction_reachable(rules, fuel - 1, list.append(children, rest), [
            identity,
            ..seen
          ])
        }
      }
  }
}

fn validate_composition_input(
  prepared: validation.PreparedGraph,
  input: CompositionInput,
  operation_checker: fn(FunctionSignature, types.DefinitionRef) ->
    Result(Nil, CompositionInputFailure),
) -> Result(Nil, CompositionInputFailure) {
  let graph = validation.prepared_graph(prepared)
  use _ <- result.try(case input.basis == semantic_basis_of(graph) {
    True -> Ok(Nil)
    False -> Error(InputBasisMismatch)
  })
  use _ <- result.try(unique_ids(
    "input",
    list.map(input.initial_inputs, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "site",
    list.map(input.invocation_domain.sites, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "lot",
    list.map(input.initial_resources, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "goal",
    list.map(input.goal.outputs, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "failure embedding",
    list.map(input.goal.failures, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "function",
    list.map(input.signatures, fn(function) {
      function_identity(function.reference)
    }),
  ))
  use _ <- result.try(unique_ids(
    "guard",
    list.map(input.invocation_domain.guards, fn(value) { value.id.value }),
  ))
  use _ <- result.try(
    list.try_each(input.signatures, fn(function) {
      let invalid = fn(reason) { InvalidSignature(function.reference, reason) }
      use _ <- result.try(
        case
          function.reference.identity != ""
          && function.reference.revision != ""
          && function.reference.content_digest != ""
          && function.assumption_ref != ""
          && function.outcomes != []
        {
          True -> Ok(Nil)
          False ->
            Error(invalid(
              "identity, revision, digest, assumptions, or outcomes",
            ))
        },
      )
      use _ <- result.try(unique_ids(
        "input port",
        list.map(function.inputs, fn(port) { port.id.value }),
      ))
      use _ <- result.try(unique_ids(
        "outcome",
        list.map(function.outcomes, fn(outcome) { outcome.id.value }),
      ))
      use _ <- result.try(unique_ids(
        "resource requirement",
        list.map(function.resource_inputs, fn(requirement) {
          requirement.id.value
        }),
      ))
      use _ <- result.try(case function.form {
        Pure | DeclaredTransform ->
          case function.effect == PureFunction {
            True -> Ok(Nil)
            False -> Error(invalid("pure function effect"))
          }
        Operation(reference) -> operation_checker(function, reference)
      })
      use _ <- result.try(
        list.try_each(function.inputs, fn(port) {
          use _ <- result.try(check_type(graph, port.contract.type_ref))
          use _ <- result.try(
            case
              source_constraint_defined(prepared, input, port.source_constraint)
            {
              True -> Ok(Nil)
              False -> Error(invalid("input source constraint"))
            },
          )
          case
            !option.unwrap(
              option.map(port.resource_requirement, fn(requirement) {
                !list.any(function.resource_inputs, fn(declared) {
                  declared.id == requirement
                })
              }),
              False,
            )
          {
            True -> Ok(Nil)
            False -> Error(invalid("input resource requirement"))
          }
        }),
      )
      use _ <- result.try(
        list.try_each(function.resource_inputs, fn(requirement) {
          use _ <- result.try(check_type(graph, requirement.token_type))
          case requirement.multiplicity != 0 {
            True -> Ok(Nil)
            False -> Error(invalid("zero resource multiplicity"))
          }
        }),
      )
      use _ <- result.try(
        list.try_each(function.outcomes, fn(outcome) {
          use _ <- result.try(unique_ids(
            "output port",
            list.map(outcome.value_ports, fn(port) { port.id.value }),
          ))
          use _ <- result.try(unique_ids(
            "resource production",
            list.map(outcome.produced_resources, fn(production) {
              production.id.value
            }),
          ))
          use _ <- result.try(
            list.try_each(outcome.value_ports, fn(port) {
              use _ <- result.try(check_type(graph, port.contract.type_ref))
              case
                !option.unwrap(
                  option.map(port.resource_production, fn(production) {
                    !list.any(outcome.produced_resources, fn(declared) {
                      declared.id == production
                    })
                  }),
                  False,
                )
              {
                True -> Ok(Nil)
                False -> Error(invalid("output resource production"))
              }
            }),
          )
          list.try_each(outcome.produced_resources, fn(production) {
            check_type(graph, production.token_type)
          })
        }),
      )
      case
        !option.unwrap(
          option.map(function.handles_failure, fn(origin) {
            !failure_origin_defined(input, origin)
          }),
          False,
        )
      {
        True -> Ok(Nil)
        False -> Error(invalid("failure handler origin"))
      }
    }),
  )
  use _ <- result.try(
    list.try_each(input.invocation_domain.sites, fn(site) {
      case signature(input, site.function) {
        None -> Error(UnresolvedFunction(site.function))
        Some(function) -> {
          use _ <- result.try(
            case list.contains(input.allowed_effects, function.effect) {
              True -> Ok(Nil)
              False -> Error(SiteEffectNotPermitted(site.id, function.effect))
            },
          )
          case
            !{
              function.form == DeclaredTransform
              && !list.contains(
                input.invocation_domain.permitted_transforms,
                function.reference,
              )
            }
          {
            True -> Ok(Nil)
            False -> Error(TransformNotPermitted(function.reference))
          }
        }
      }
    }),
  )
  use _ <- result.try(
    list.try_each(input.initial_inputs, fn(initial) {
      use _ <- result.try(check_type(graph, initial.contract.type_ref))
      use _ <- result.try(case initial.source {
        SuppliedValue(value) ->
          case validation.accepts_slot(prepared, initial.contract, value) {
            types.RejectedValue(failure) ->
              Error(InvalidInitialValue(initial.id, failure))
            _ -> Ok(Nil)
          }
        Argument -> Ok(Nil)
      })
      case
        !option.unwrap(
          option.map(initial.resource, fn(id) {
            !list.any(input.initial_resources, fn(lot) { lot.id == id })
          }),
          False,
        )
      {
        True -> Ok(Nil)
        False -> Error(InvalidResourceDeclaration("initial backing lot"))
      }
    }),
  )
  use _ <- result.try(
    list.try_each(input.initial_resources, fn(lot) {
      use _ <- result.try(check_type(graph, lot.token_type))
      case lot.producer {
        InitialResource(identity, revision) ->
          case !{ identity == "" || revision == "" || lot.provenance == "" } {
            True -> Ok(Nil)
            False ->
              Error(InvalidResourceDeclaration("initial producer or provenance"))
          }
        _ ->
          Error(InvalidResourceDeclaration(
            "initial lot has an invocation producer",
          ))
      }
    }),
  )
  use _ <- result.try(case input.goal.outputs != [] {
    True -> Ok(Nil)
    False -> Error(EmptyGoal)
  })
  use _ <- result.try(
    list.try_each(input.goal.outputs, fn(goal) {
      use _ <- result.try(check_type(graph, goal.contract.type_ref))
      case source_constraint_defined(prepared, input, goal.source_constraint) {
        True -> Ok(Nil)
        False ->
          Error(GoalSourceConstraintUndefined(goal.id, goal.source_constraint))
      }
    }),
  )
  use _ <- result.try(
    list.try_each(input.goal.failures, fn(embedding) {
      use _ <- result.try(check_type(graph, embedding.contract.type_ref))
      case failure_origin_defined(input, embedding.origin) {
        True -> Ok(Nil)
        False ->
          Error(FailureEmbeddingOriginUndefined(embedding.id, embedding.origin))
      }
    }),
  )
  use _ <- result.try(
    list.try_each(input.invocation_domain.permitted_projections, fn(projection) {
      check_type(graph, projection.source_type)
    }),
  )
  use _ <- result.try(unique_ids(
    "construction",
    list.map(input.invocation_domain.permitted_constructions, fn(rule) {
      rule.identity
    }),
  ))
  let construction_edges =
    list.fold(
      input.invocation_domain.permitted_constructions,
      0,
      fn(count, rule) { count + list.length(rule.nested_fields) },
    )
  use _ <- result.try(
    list.try_each(
      input.invocation_domain.permitted_constructions,
      fn(construction) {
        use _ <- result.try(check_type(graph, construction.type_ref))
        case resolved_shape(graph, construction.type_ref) {
          Some(types.ProductShape(product)) -> {
            use _ <- result.try(unique_ids(
              "nested field",
              list.map(construction.nested_fields, fn(pair) { pair.0 }),
            ))
            use _ <- result.try(unique_ids(
              "field constraint",
              list.map(construction.field_constraints, fn(constraint) {
                constraint.field
              }),
            ))
            use _ <- result.try(
              list.try_each(construction.field_constraints, fn(constraint) {
                use _ <- result.try(
                  case
                    list.any(product.fields, fn(field) {
                      field.wire_name == constraint.field
                    })
                  {
                    True -> Ok(Nil)
                    False ->
                      Error(FieldConstraintUnknownField(
                        construction.identity,
                        constraint.field,
                      ))
                  },
                )
                use _ <- result.try(
                  case
                    !list.any(construction.nested_fields, fn(nested) {
                      nested.0 == constraint.field
                    })
                  {
                    True -> Ok(Nil)
                    False ->
                      Error(ConstrainedNestedField(
                        construction.identity,
                        constraint.field,
                      ))
                  },
                )
                case
                  source_constraint_defined(prepared, input, constraint.source)
                {
                  True -> Ok(Nil)
                  False ->
                    Error(ConstructionFieldSourceUndefined(
                      construction.identity,
                      constraint,
                    ))
                }
              }),
            )
            list.try_each(construction.nested_fields, fn(nested_field) {
              let #(name, nested) = nested_field
              use field <- result.try(result.replace_error(
                list.find(product.fields, fn(field) { field.wire_name == name }),
                NestedFieldUndeclared(construction.identity, name),
              ))
              use _ <- result.try(
                case
                  list.any(
                    input.invocation_domain.permitted_constructions,
                    fn(rule) {
                      rule.identity == nested
                      && rule.type_ref == field.slot.type_ref
                    },
                  )
                {
                  True -> Ok(Nil)
                  False ->
                    Error(NestedConstructionMismatch(
                      construction.identity,
                      name,
                      nested,
                      field.slot.type_ref,
                    ))
                },
              )
              let reached =
                construction_reachable(
                  input.invocation_domain.permitted_constructions,
                  list.length(input.invocation_domain.permitted_constructions)
                    + construction_edges
                    + 1,
                  [nested],
                  [],
                )
              case !list.contains(reached, construction.identity) {
                True -> Ok(Nil)
                False -> Error(CyclicConstruction(construction.identity))
              }
            })
          }
          _ ->
            Error(ConstructionNotProduct(
              construction.identity,
              construction.type_ref,
            ))
        }
      },
    ),
  )
  use _ <- result.try(
    list.try_each(input.invocation_domain.guards, fn(guard) {
      use _ <- result.try(check_type(graph, guard.source_type))
      case guard.kind {
        Validate(contract) -> check_type(graph, contract.type_ref)
        _ -> Ok(Nil)
      }
    }),
  )
  use _ <- result.try(
    list.try_each(input.explicit_order, fn(pair) {
      case
        !{
          pair.0 == pair.1
          || site_signature(input, pair.0) == None
          || site_signature(input, pair.1) == None
        }
      {
        True -> Ok(Nil)
        False -> Error(ExplicitSiteOrderInvalid(pair.0, pair.1))
      }
    }),
  )
  list.try_each(
    list.append(
      input.goal.final_resources,
      list.flat_map(input.goal.failures, fn(embedding) {
        embedding.final_resources
      }),
    ),
    fn(goal) {
      case declared_lot(input, goal.lot) != None {
        True -> Ok(Nil)
        False -> Error(InvalidResourceDeclaration("terminal resource lot"))
      }
    },
  )
}

pub fn prepare_direct_composition(
  prepared: validation.PreparedGraph,
  input: CompositionInput,
  operation_checker: fn(FunctionSignature, types.DefinitionRef) ->
    Result(Nil, CompositionInputFailure),
  operation_meaning: fn(FunctionSignature, types.DefinitionRef) ->
    List(types.SemanticObligation),
) -> Result(PreparedCompositionInput, CompositionInputFailure) {
  use _ <- result.try(validate_composition_input(
    prepared,
    input,
    operation_checker,
  ))
  let empty_refs = empty_types(prepared)
  use _ <- result.try(verify_empty_closure_input(prepared, empty_refs))
  Ok(prepared_composition_input(
    prepared,
    input,
    operation_checker,
    operation_meaning,
    empty_refs,
  ))
}

fn verify_empty_closure_input(
  prepared: validation.PreparedGraph,
  refs: List(types.TypeRef),
) -> Result(Nil, CompositionInputFailure) {
  case verify_empty_types(prepared, refs) {
    Error(failure) -> Error(InvalidEmptyTypeClosure(failure))
    Ok(_) -> Ok(Nil)
  }
}

pub fn declared_value(
  input: CompositionInput,
  producer: ProducerRef,
) -> Option(#(types.SlotContract, Option(ResourceLotRef))) {
  case producer {
    Initial(id) ->
      option.map(
        option.from_result(
          list.find(input.initial_inputs, fn(initial) { initial.id == id }),
        ),
        fn(initial) {
          #(initial.contract, option.map(initial.resource, InitialLot))
        },
      )
    InvocationOutcome(site, outcome, port) ->
      option.then(
        option.then(site_signature(input, site), fn(function) {
          option.from_result(
            list.find(function.outcomes, fn(contract) { contract.id == outcome }),
          )
        }),
        fn(outcome_contract) {
          option.map(
            option.from_result(
              list.find(outcome_contract.value_ports, fn(output) {
                output.id == port
              }),
            ),
            fn(output) {
              #(
                output.contract,
                option.map(output.resource_production, fn(production) {
                  ProducedLot(site, outcome, production)
                }),
              )
            },
          )
        },
      )
  }
}
