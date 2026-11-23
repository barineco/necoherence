// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import neco_quotient_application as quotient
import necoherence/composition_plan
import necoherence/exact_json as kdl
import necoherence/network_effect as network
import necoherence/semantic_generation_values as values
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource

pub type ValueFailure {
  Constraint(failure: validation.ValidationFailure)
  Wire(reference: types.TypeRef, failure: values.ValueCodecFailure)
  Representation(reference: types.TypeRef, condition: String)
}

pub fn validate_value(
  prepared: validation.PreparedGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(Nil, ValueFailure) {
  result.map(validation.validate_value(prepared, reference, value, None), fn(_) {
    Nil
  })
  |> result.map_error(Constraint)
}

pub fn validate_slot(
  prepared: validation.PreparedGraph,
  contract: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(Nil, ValueFailure) {
  case validation.accepts_slot(prepared, contract, value) {
    types.AcceptedValue -> Ok(Nil)
    types.RejectedValue(failure) ->
      Error(Constraint(validation.Rejected(failure)))
    types.UnresolvedValue(obligations) ->
      Error(Constraint(validation.Unresolved(obligations)))
  }
}

pub fn tag_object(
  profile: types.SemanticProfile,
  reference: types.TypeRef,
  value: kdl.JsonValue,
  tag: String,
) -> Result(kdl.JsonValue, ValueFailure) {
  case profile.tag, value {
    Some(model), kdl.JsonValueObj(members) ->
      Ok(
        kdl.JsonValueObj([
          #(model.key, kdl.JsonValueStr(tag)),
          ..list.filter(members, fn(member) { member.0 != model.key })
        ]),
      )
    _, _ -> Error(Representation(reference, "tagged object required"))
  }
}

pub fn member_slot(
  members: List(#(String, kdl.JsonValue)),
  name: String,
) -> types.SlotValue(kdl.JsonValue) {
  case list.key_find(members, name) {
    Error(_) -> types.Absent
    Ok(kdl.JsonValueNull) -> types.Null
    Ok(value) -> types.Present(value)
  }
}

pub fn slot_members(
  name: String,
  value: types.SlotValue(kdl.JsonValue),
) -> List(#(String, kdl.JsonValue)) {
  case value {
    types.Absent -> []
    types.Null -> [#(name, kdl.JsonValueNull)]
    types.Present(value) -> [#(name, value)]
  }
}

pub fn map_slot(
  value: types.SlotValue(a),
  convert: fn(a) -> Result(b, ValueFailure),
) -> Result(types.SlotValue(b), ValueFailure) {
  case value {
    types.Absent -> Ok(types.Absent)
    types.Null -> Ok(types.Null)
    types.Present(value) -> result.map(convert(value), types.Present)
  }
}

pub type OutcomeValues {
  OutcomeValues(
    outcome: composition_plan.OutcomeId,
    values: List(#(composition_plan.PortId, types.SlotValue(kdl.JsonValue))),
  )
}

pub type NetworkOwner {
  NetworkOwner(
    encode: fn(List(#(composition_plan.PortId, types.SlotValue(kdl.JsonValue)))) ->
      Result(network.AttemptInput, ExecutionFailure),
    decode: fn(network.RawHttpResponse) ->
      Result(OutcomeValues, ExecutionFailure),
  )
}

pub type PreparedAttempt {
  Ready(input: network.AttemptInput)
  CompletedOutcome(outcome: OutcomeValues)
}

pub type PreparedNetworkOwner {
  PreparedNetworkOwner(
    prepare: fn(
      List(#(composition_plan.PortId, types.SlotValue(kdl.JsonValue))),
    ) -> Result(PreparedAttempt, ExecutionFailure),
    decode: fn(network.RawHttpResponse) ->
      Result(OutcomeValues, ExecutionFailure),
  )
}

pub type ProviderImplementation {
  Pure(
    callback: fn(
      List(#(composition_plan.PortId, types.SlotValue(kdl.JsonValue))),
    ) -> Result(OutcomeValues, ExecutionFailure),
  )
  PreparedHttp(owner: PreparedNetworkOwner)
}

pub type Provider {
  Provider(
    reference: composition_plan.FunctionRef,
    implementation: ProviderImplementation,
  )
}

pub type ExecutionResult {
  Success(
    outputs: List(
      #(composition_plan.GoalPortId, types.SlotValue(kdl.JsonValue)),
    ),
  )
  Failure(
    embedding: composition_plan.FailureEmbeddingId,
    value: types.SlotValue(kdl.JsonValue),
  )
}

pub type ExecutionFailure {
  Value(failure: validation.ValidationFailure)
  MissingArgument(id: composition_plan.InputId)
  ArgumentCoverage(condition: String)
  MissingValue(reference: composition_plan.ValueRef)
  MissingProvider(function: composition_plan.FunctionRef)
  ProviderCoverage(condition: String)
  ProviderEffect(function: composition_plan.FunctionRef)
  ProviderFailure(site: composition_plan.SiteId, message: String)
  InvalidOutcome(
    site: composition_plan.SiteId,
    outcome: composition_plan.OutcomeId,
  )
  Resource(lot: composition_plan.ResourceLotRef, condition: String)
  InvalidPlan(condition: String)
  Network(failure: network.NetworkFailure)
  NetworkTerminal(terminal: network.NetworkTerminal)
}

pub type RunFailure {
  RunFailure(cause: ExecutionFailure, network: network.NetworkState)
}

pub type NetworkInstruction {
  Send(command: network.SendCommand)
  Observe(started: network.StartedAttempt)
}

pub type ExecutionObservation {
  Start(observation: network.StartObservation)
  Host(observation: network.HostObservation)
}

pub type Progress {
  Completed(result: ExecutionResult, network: network.NetworkState)
  Pending(execution: Execution, instruction: NetworkInstruction)
}

pub type RuntimeState {
  RuntimeState(
    values: List(
      #(composition_plan.ProducerRef, types.SlotValue(kdl.JsonValue)),
    ),
    resources: List(
      #(composition_plan.ResourceLotRef, composition_plan.ResourceLot),
    ),
  )
}

type OutcomeTable =
  Option(
    quotient.KeyedBlocks(
      composition_plan.OutcomeId,
      composition_plan.PreparedTree,
    ),
  )

pub type PendingNetwork {
  PendingStart(
    invocation: composition_plan.InvocationPlan,
    arms: OutcomeTable,
    owner: NetworkOwner,
    prepared: network.PreparedAttempt,
  )
  PendingResponse(
    invocation: composition_plan.InvocationPlan,
    arms: OutcomeTable,
    owner: NetworkOwner,
    started: network.StartedAttempt,
  )
}

pub opaque type Execution {
  Execution(
    prepared: composition_plan.PreparedCompositionInput,
    providers: List(Provider),
    state: RuntimeState,
    tree: composition_plan.PreparedTree,
    network: network.NetworkState,
    pending: Option(PendingNetwork),
  )
}

pub fn execution_network(execution: Execution) -> network.NetworkState {
  execution.network
}

fn fail(cause: ExecutionFailure) -> Result(a, ExecutionFailure) {
  Error(cause)
}

fn require(
  condition: Bool,
  cause: ExecutionFailure,
) -> Result(Nil, ExecutionFailure) {
  case condition {
    True -> Ok(Nil)
    False -> fail(cause)
  }
}

fn attach(
  state: network.NetworkState,
  value: Result(a, ExecutionFailure),
) -> Result(a, RunFailure) {
  result.map_error(value, fn(cause) { RunFailure(cause, state) })
}

fn find(values: List(a), predicate: fn(a) -> Bool) -> Option(a) {
  case list.find(values, predicate) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn signature(
  execution: Execution,
  reference: composition_plan.FunctionRef,
) -> Result(composition_plan.FunctionSignature, ExecutionFailure) {
  case
    find(
      composition_plan.prepared_input(execution.prepared).signatures,
      fn(candidate) { candidate.reference == reference },
    )
  {
    Some(value) -> Ok(value)
    None -> fail(InvalidPlan("function identity mismatch"))
  }
}

fn project(
  tag_key: String,
  value: types.SlotValue(kdl.JsonValue),
  path: types.ValuePath,
) -> Result(types.SlotValue(kdl.JsonValue), ExecutionFailure) {
  case path {
    [] -> Ok(value)
    [step, ..rest] ->
      case value, step {
        types.Present(kdl.JsonValueObj(members)), types.Field(name) -> {
          let field = case list.key_find(members, name) {
            Error(_) -> types.Absent
            Ok(kdl.JsonValueNull) -> types.Null
            Ok(value) -> types.Present(value)
          }
          project(tag_key, field, rest)
        }
        types.Present(kdl.JsonValueArr(items)), types.Index(index) -> {
          let item = case index >= 0 {
            True -> option.from_result(list.first(list.drop(items, index)))
            False -> None
          }
          case item {
            None -> fail(InvalidPlan("array projection outside value"))
            Some(kdl.JsonValueNull) -> project(tag_key, types.Null, rest)
            Some(value) -> project(tag_key, types.Present(value), rest)
          }
        }
        types.Present(kdl.JsonValueObj(members)), types.Variant(tag) ->
          case list.key_find(members, tag_key) {
            Ok(kdl.JsonValueStr(observed)) if observed == tag ->
              project(tag_key, value, rest)
            _ -> fail(InvalidPlan("variant projection mismatch"))
          }
        _, _ -> fail(InvalidPlan("projection shape mismatch"))
      }
  }
}

fn lookup(
  graph: types.SemanticGraph,
  state: RuntimeState,
  reference: composition_plan.ValueRef,
) -> Result(types.SlotValue(kdl.JsonValue), ExecutionFailure) {
  use value <- result.try(
    case find(state.values, fn(pair) { pair.0 == reference.producer }) {
      Some(pair) -> Ok(pair.1)
      None -> fail(MissingValue(reference))
    },
  )
  let tag_key = case graph.profile.tag {
    Some(model) -> model.key
    None -> ""
  }
  project(tag_key, value, reference.path)
}

fn evaluate_binding(
  graph: types.SemanticGraph,
  state: RuntimeState,
  binding: composition_plan.BindingExpr,
) -> Result(types.SlotValue(kdl.JsonValue), ExecutionFailure) {
  case binding {
    composition_plan.Source(reference, _, _) -> lookup(graph, state, reference)
    composition_plan.Product(_, _, fields) -> {
      use members <- result.try(
        list.try_map(fields, fn(field) {
          use value <- result.try(evaluate_binding(graph, state, field.1))
          Ok(slot_members(field.0, value))
        }),
      )
      Ok(types.Present(kdl.JsonValueObj(list.flatten(members))))
    }
  }
}

fn validate(
  prepared: validation.PreparedGraph,
  contract: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(Nil, ExecutionFailure) {
  case validation.accepts_slot(prepared, contract, value) {
    types.AcceptedValue -> Ok(Nil)
    types.RejectedValue(failure) -> fail(Value(validation.Rejected(failure)))
    types.UnresolvedValue(obligations) ->
      fail(Value(validation.Unresolved(obligations)))
  }
}

fn initial_state(
  prepared: composition_plan.PreparedCompositionInput,
  arguments: List(#(composition_plan.InputId, types.SlotValue(kdl.JsonValue))),
) -> Result(RuntimeState, ExecutionFailure) {
  let problem = composition_plan.prepared_input(prepared)
  use _ <- result.try(
    list.try_map(arguments, fn(argument) {
      require(
        list.length(
          list.filter(arguments, fn(candidate) { candidate.0 == argument.0 }),
        )
          == 1
          && list.any(problem.initial_inputs, fn(initial) {
          initial.id == argument.0
          && initial.source == composition_plan.Argument
        }),
        ArgumentCoverage("unique declared argument identifiers required"),
      )
    }),
  )
  use values <- result.try(
    list.try_map(problem.initial_inputs, fn(initial) {
      use value <- result.try(case initial.source {
        composition_plan.SuppliedValue(value) -> Ok(value)
        composition_plan.Argument ->
          case list.key_find(arguments, initial.id) {
            Ok(value) -> Ok(value)
            Error(_) -> fail(MissingArgument(initial.id))
          }
      })
      use _ <- result.try(validate(
        composition_plan.prepared_validation(prepared),
        initial.contract,
        value,
      ))
      Ok(#(composition_plan.Initial(initial.id), value))
    }),
  )
  let resources =
    list.map(problem.initial_resources, fn(lot) {
      #(composition_plan.InitialLot(lot.id), lot)
    })
  Ok(RuntimeState(values, resources))
}

fn bind_resources(
  signature: composition_plan.FunctionSignature,
  invocation: composition_plan.InvocationPlan,
  state: RuntimeState,
) -> Result(RuntimeState, ExecutionFailure) {
  use resources <- result.try(
    list.fold(invocation.resources, Ok(state.resources), fn(acc, binding) {
      use resources <- result.try(acc)
      use requirement <- result.try(
        case
          find(signature.resource_inputs, fn(candidate) {
            candidate.id == binding.requirement
          })
        {
          Some(value) -> Ok(value)
          None -> fail(InvalidPlan("resource requirement mismatch"))
        },
      )
      use lot <- result.try(
        case find(resources, fn(pair) { pair.0 == binding.lot }) {
          Some(pair) -> Ok(pair.1)
          None -> fail(Resource(binding.lot, "missing lot"))
        },
      )
      use _ <- result.try(require(
        lot.revision == requirement.required_revision,
        Resource(binding.lot, "revision mismatch"),
      ))
      use _ <- result.try(require(
        lot.quantity >= requirement.multiplicity,
        Resource(binding.lot, "insufficient quantity"),
      ))
      case requirement.mode {
        resource.Read -> Ok(resources)
        resource.Consume ->
          Ok(
            list.map(resources, fn(pair) {
              case pair.0 == binding.lot {
                True -> #(
                  pair.0,
                  composition_plan.ResourceLot(
                    ..pair.1,
                    quantity: pair.1.quantity - requirement.multiplicity,
                  ),
                )
                False -> pair
              }
            }),
          )
      }
    }),
  )
  Ok(RuntimeState(..state, resources: resources))
}

fn union_spec(
  graph: types.SemanticGraph,
  fuel: Int,
  reference: types.TypeRef,
) -> Option(types.UnionSpec) {
  case fuel <= 0 {
    True -> None
    False ->
      case find(graph.nodes, fn(node) { node.reference == reference }) {
        None -> None
        Some(node) ->
          case node.shape {
            types.TaggedUnionShape(spec) -> Some(spec)
            types.AliasShape(target, _) -> union_spec(graph, fuel - 1, target)
            _ -> None
          }
      }
  }
}

fn inspect_guard(
  prepared: validation.PreparedGraph,
  guard: composition_plan.DeclaredGuard,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(composition_plan.GuardArm, ExecutionFailure) {
  case guard.kind {
    composition_plan.Presence ->
      case value {
        types.Absent -> Ok(composition_plan.GuardAbsent)
        types.Null -> Ok(composition_plan.GuardNull)
        types.Present(_) -> Ok(composition_plan.GuardPresent)
      }
    composition_plan.Validate(contract) ->
      case validation.accepts_slot(prepared, contract, value) {
        types.AcceptedValue -> Ok(composition_plan.GuardAccepted)
        types.RejectedValue(_) -> Ok(composition_plan.GuardRejected)
        types.UnresolvedValue(obligations) ->
          fail(Value(validation.Unresolved(obligations)))
      }
    composition_plan.Variants -> {
      use members <- result.try(case value {
        types.Absent -> Ok([])
        types.Null -> Ok([])
        types.Present(kdl.JsonValueObj(members)) -> Ok(members)
        _ -> fail(InvalidPlan("union guard shape"))
      })
      case value {
        types.Absent -> Ok(composition_plan.GuardAbsent)
        types.Null -> Ok(composition_plan.GuardNull)
        _ -> inspect_variant_guard(prepared, guard, value, members)
      }
    }
  }
}

fn inspect_variant_guard(
  prepared: validation.PreparedGraph,
  guard: composition_plan.DeclaredGuard,
  value: types.SlotValue(kdl.JsonValue),
  members: List(#(String, kdl.JsonValue)),
) -> Result(composition_plan.GuardArm, ExecutionFailure) {
  let graph = validation.prepared_graph(prepared)
  let tag_key = case graph.profile.tag {
    Some(model) -> model.key
    None -> ""
  }
  use _tag <- result.try(case list.key_find(members, tag_key) {
    Ok(kdl.JsonValueStr(tag)) -> Ok(tag)
    _ -> fail(InvalidPlan("union guard discriminator"))
  })
  use projection <- result.try(
    case
      validation.project_slot(
        prepared,
        types.SlotContract(guard.source_type, True, False),
        guard.path,
        [],
      )
    {
      Ok(value) -> Ok(value)
      Error(_) -> fail(InvalidPlan("union guard projection"))
    },
  )
  use spec <- result.try(
    case
      union_spec(
        graph,
        list.length(graph.nodes) + 1,
        projection.destination.type_ref,
      )
    {
      Some(value) -> Ok(value)
      None -> fail(InvalidPlan("union guard declaration"))
    },
  )
  let assert types.Present(actual) = value
  case validation.select_union_branch(graph.profile, spec, actual) {
    Some(branch) -> Ok(composition_plan.GuardVariant(branch.wire_tag))
    None -> fail(InvalidPlan("union branch selection"))
  }
}

fn provider_effect_matches(
  effect: composition_plan.CompositionEffect,
  implementation: ProviderImplementation,
) -> Bool {
  case implementation {
    Pure(_) ->
      effect == composition_plan.PureFunction
      || effect == composition_plan.DataOnly
    PreparedHttp(_) -> effect == composition_plan.HttpRequestResponse
  }
}

fn validate_providers(
  prepared: composition_plan.PreparedCompositionInput,
  providers: List(Provider),
) -> Result(Nil, ExecutionFailure) {
  let signatures = composition_plan.prepared_input(prepared).signatures
  use _ <- result.try(require(
    list.length(providers) == list.length(signatures),
    ProviderCoverage("exact provider coverage required"),
  ))
  use _ <- result.try(
    list.try_map(providers, fn(provider) {
      require(
        list.length(
          list.filter(providers, fn(candidate) {
            candidate.reference == provider.reference
          }),
        )
          == 1,
        ProviderCoverage("unique provider references required"),
      )
    }),
  )
  list.try_map(signatures, fn(expected) {
    use provider <- result.try(
      case
        find(providers, fn(candidate) {
          candidate.reference == expected.reference
        })
      {
        Some(value) -> Ok(value)
        None -> fail(MissingProvider(expected.reference))
      },
    )
    require(
      provider_effect_matches(expected.effect, provider.implementation),
      ProviderEffect(expected.reference),
    )
  })
  |> result.map(fn(_) { Nil })
}

fn invocation_call(
  execution: Execution,
  invocation: composition_plan.InvocationPlan,
) -> Result(
  #(
    composition_plan.FunctionSignature,
    RuntimeState,
    List(#(composition_plan.PortId, types.SlotValue(kdl.JsonValue))),
  ),
  ExecutionFailure,
) {
  use signature <- result.try(signature(execution, invocation.function))
  use state <- result.try(bind_resources(signature, invocation, execution.state))
  use arguments <- result.try(
    list.try_map(invocation.bindings, fn(pair) {
      use port <- result.try(
        case find(signature.inputs, fn(candidate) { candidate.id == pair.0 }) {
          Some(value) -> Ok(value)
          None -> fail(InvalidPlan("input port mismatch"))
        },
      )
      use value <- result.try(evaluate_binding(
        composition_plan.prepared_graph(execution.prepared),
        state,
        pair.1,
      ))
      use _ <- result.try(validate(
        composition_plan.prepared_validation(execution.prepared),
        port.contract,
        value,
      ))
      Ok(#(pair.0, value))
    }),
  )
  Ok(#(signature, state, arguments))
}

fn accept_outcome(
  execution: Execution,
  signature: composition_plan.FunctionSignature,
  invocation: composition_plan.InvocationPlan,
  arms: OutcomeTable,
  returned: OutcomeValues,
) -> Result(Execution, ExecutionFailure) {
  use outcome <- result.try(
    case
      find(signature.outcomes, fn(candidate) {
        candidate.id == returned.outcome
      })
    {
      Some(value) -> Ok(value)
      None -> fail(InvalidOutcome(invocation.site, returned.outcome))
    },
  )
  use _ <- result.try(require(
    list.length(returned.values) == list.length(outcome.value_ports),
    InvalidPlan("output port coverage"),
  ))
  use values <- result.try(
    list.try_map(outcome.value_ports, fn(port) {
      use value <- result.try(case list.key_find(returned.values, port.id) {
        Ok(value) -> Ok(value)
        Error(_) -> fail(InvalidPlan("missing output port"))
      })
      use _ <- result.try(validate(
        composition_plan.prepared_validation(execution.prepared),
        port.contract,
        value,
      ))
      Ok(#(
        composition_plan.InvocationOutcome(invocation.site, outcome.id, port.id),
        value,
      ))
    }),
  )
  let resources =
    list.map(outcome.produced_resources, fn(production) {
      #(
        composition_plan.ProducedLot(invocation.site, outcome.id, production.id),
        composition_plan.ResourceLot(
          composition_plan.LotId(production.id.value),
          production.token_type,
          composition_plan.OutcomeResource(invocation.site, outcome.id),
          production.revision,
          production.quantity,
          production.provenance,
        ),
      )
    })
  use table <- result.try(case arms {
    Some(table) -> Ok(table)
    None -> fail(InvalidPlan("duplicate outcome branch"))
  })
  use tree <- result.try(case quotient.apply(table, outcome.id) {
    quotient.Value(value) -> Ok(value)
    quotient.Residual(_) -> fail(InvalidPlan("outcome branch mismatch"))
  })
  let RuntimeState(existing_values, existing_resources) = execution.state
  Ok(
    Execution(
      ..execution,
      state: RuntimeState(
        list.append(existing_values, values),
        list.append(existing_resources, resources),
      ),
      tree: tree,
      pending: None,
    ),
  )
}

fn start_http(
  execution: Execution,
  invocation: composition_plan.InvocationPlan,
  arms: OutcomeTable,
  arguments: List(#(composition_plan.PortId, types.SlotValue(kdl.JsonValue))),
  owner: NetworkOwner,
) -> Result(Progress, RunFailure) {
  use input <- result.try(attach(execution.network, owner.encode(arguments)))
  use prepared <- result.try(case network.prepare(execution.network, input) {
    network.PreparedResult(state, prepared) -> Ok(#(state, prepared))
    network.PrepareRejected(state, failure) ->
      Error(RunFailure(Network(failure), state))
  })
  use command <- result.try(case network.send_command(prepared.0, prepared.1) {
    network.CommandReady(state, command) -> Ok(#(state, command))
    network.CommandRejected(state, failure) ->
      Error(RunFailure(Network(failure), state))
  })
  let pending = PendingStart(invocation, arms, owner, prepared.1)
  Ok(Pending(
    Execution(..execution, network: command.0, pending: Some(pending)),
    Send(command.1),
  ))
}

fn advance(execution: Execution) -> Result(Progress, RunFailure) {
  let problem = composition_plan.prepared_input(execution.prepared)
  let graph = composition_plan.prepared_graph(execution.prepared)
  let prepared_values = composition_plan.prepared_validation(execution.prepared)
  case execution.tree {
    composition_plan.PreparedReturn(composition_plan.ReturnSuccess(outputs)) -> {
      use values <- result.try(attach(
        execution.network,
        list.try_map(outputs, fn(output) {
          use port <- result.try(
            case
              find(problem.goal.outputs, fn(candidate) {
                candidate.id == output.0
              })
            {
              Some(value) -> Ok(value)
              None -> fail(InvalidPlan("goal port mismatch"))
            },
          )
          use value <- result.try(evaluate_binding(
            graph,
            execution.state,
            output.1,
          ))
          use _ <- result.try(validate(prepared_values, port.contract, value))
          Ok(#(output.0, value))
        }),
      ))
      use _ <- result.try(attach(
        execution.network,
        list.try_map(problem.goal.final_resources, fn(required) {
          use lot <- result.try(
            case
              find(execution.state.resources, fn(pair) {
                pair.0 == required.lot
              })
            {
              Some(pair) -> Ok(pair.1)
              None -> fail(Resource(required.lot, "missing final lot"))
            },
          )
          require(
            lot.quantity >= required.multiplicity
              && lot.revision == required.revision,
            Resource(required.lot, "final resource mismatch"),
          )
        }),
      ))
      Ok(Completed(Success(values), execution.network))
    }
    composition_plan.PreparedReturn(composition_plan.ReturnFailure(
      embedding,
      binding,
    )) -> {
      use failure <- result.try(
        attach(
          execution.network,
          case
            find(problem.goal.failures, fn(candidate) {
              candidate.id == embedding
            })
          {
            Some(value) -> Ok(value)
            None -> fail(InvalidPlan("failure embedding mismatch"))
          },
        ),
      )
      use value <- result.try(attach(
        execution.network,
        evaluate_binding(graph, execution.state, binding),
      ))
      use _ <- result.try(attach(
        execution.network,
        validate(prepared_values, failure.contract, value),
      ))
      Ok(Completed(Failure(embedding, value), execution.network))
    }
    composition_plan.PreparedGuard(id, inspected, arms) -> {
      use guard <- result.try(
        attach(
          execution.network,
          case
            find(problem.invocation_domain.guards, fn(candidate) {
              candidate.id == id
            })
          {
            Some(value) -> Ok(value)
            None -> fail(InvalidPlan("guard identity mismatch"))
          },
        ),
      )
      use value <- result.try(attach(
        execution.network,
        lookup(graph, execution.state, inspected),
      ))
      use arm <- result.try(attach(
        execution.network,
        inspect_guard(prepared_values, guard, value),
      ))
      use table <- result.try(
        attach(execution.network, case arms {
          Some(table) -> Ok(table)
          None -> fail(InvalidPlan("duplicate guard branch"))
        }),
      )
      use tree <- result.try(
        attach(execution.network, case quotient.apply(table, arm) {
          quotient.Value(value) -> Ok(value)
          quotient.Residual(_) -> fail(InvalidPlan("guard branch mismatch"))
        }),
      )
      advance(Execution(..execution, tree: tree))
    }
    composition_plan.PreparedInvoke(invocation, arms) -> {
      use call <- result.try(attach(
        execution.network,
        invocation_call(execution, invocation),
      ))
      let current = Execution(..execution, state: call.1)
      use provider <- result.try(
        attach(
          current.network,
          case
            find(current.providers, fn(candidate) {
              candidate.reference == invocation.function
            })
          {
            Some(value) -> Ok(value)
            None -> fail(MissingProvider(invocation.function))
          },
        ),
      )
      case provider.implementation {
        Pure(callback) -> {
          use returned <- result.try(attach(current.network, callback(call.2)))
          use next <- result.try(attach(
            current.network,
            accept_outcome(current, call.0, invocation, arms, returned),
          ))
          advance(next)
        }
        PreparedHttp(owner) -> {
          use prepared <- result.try(attach(
            current.network,
            owner.prepare(call.2),
          ))
          case prepared {
            Ready(input) ->
              start_http(
                current,
                invocation,
                arms,
                call.2,
                NetworkOwner(fn(_) { Ok(input) }, owner.decode),
              )
            CompletedOutcome(returned) -> {
              use next <- result.try(attach(
                current.network,
                accept_outcome(current, call.0, invocation, arms, returned),
              ))
              advance(next)
            }
          }
        }
      }
    }
  }
}

pub fn start_composition(
  checked_composition: composition_plan.CheckedComposition,
  providers: List(Provider),
  arguments: List(#(composition_plan.InputId, types.SlotValue(kdl.JsonValue))),
  state: network.NetworkState,
) -> Result(Progress, RunFailure) {
  use state <- result.try(case network.read_network_state(state) {
    network.Read(state) -> Ok(state)
    network.ReadRejected(state, failure) ->
      Error(RunFailure(Network(failure), state))
  })
  let prepared = composition_plan.checked_prepared(checked_composition)
  use _ <- result.try(attach(state, validate_providers(prepared, providers)))
  use runtime_state <- result.try(attach(
    state,
    initial_state(prepared, arguments),
  ))
  advance(Execution(
    prepared,
    providers,
    runtime_state,
    composition_plan.checked_root(checked_composition),
    state,
    None,
  ))
}

pub fn resume(
  execution: Execution,
  observation: ExecutionObservation,
) -> Result(Progress, RunFailure) {
  case execution.pending, observation {
    Some(PendingStart(invocation, arms, owner, prepared)), Start(observed) ->
      case network.observe_start(execution.network, prepared, observed) {
        network.StartedStep(state, started) -> {
          let pending = PendingResponse(invocation, arms, owner, started)
          Ok(Pending(
            Execution(..execution, network: state, pending: Some(pending)),
            Observe(started),
          ))
        }
        network.TerminalStep(state, settled) ->
          Error(RunFailure(NetworkTerminal(settled.terminal), state))
        network.NetworkRejected(state, failure) ->
          Error(RunFailure(Network(failure), state))
        _ ->
          Error(RunFailure(
            InvalidPlan("network start result"),
            execution.network,
          ))
      }
    Some(PendingResponse(invocation, arms, owner, started)), Host(observed) ->
      case network.observe(execution.network, observed) {
        network.PendingStep(state, next_started) -> {
          let pending = PendingResponse(invocation, arms, owner, next_started)
          Ok(Pending(
            Execution(..execution, network: state, pending: Some(pending)),
            Observe(next_started),
          ))
        }
        network.TerminalStep(state, settled) ->
          case settled.terminal.outcome {
            network.Response(response, _) -> {
              use returned <- result.try(attach(state, owner.decode(response)))
              let current =
                Execution(..execution, network: state, pending: None)
              use function <- result.try(attach(
                state,
                signature(current, invocation.function),
              ))
              use next <- result.try(attach(
                state,
                accept_outcome(current, function, invocation, arms, returned),
              ))
              advance(next)
            }
            _ -> Error(RunFailure(NetworkTerminal(settled.terminal), state))
          }
        network.DuplicateStep(state, _, _) | network.LateStep(state, _, _) ->
          Ok(Pending(Execution(..execution, network: state), Observe(started)))
        network.NetworkRejected(state, failure) ->
          Error(RunFailure(Network(failure), state))
        network.StartedStep(state, _) ->
          Error(RunFailure(
            InvalidPlan("completion delivered a start result"),
            state,
          ))
      }
    None, _ ->
      Error(RunFailure(
        InvalidPlan("only pending executions may resume"),
        execution.network,
      ))
    _, _ ->
      Error(RunFailure(
        InvalidPlan("network observation kind mismatch"),
        execution.network,
      ))
  }
}

pub type SemanticRuntimeFailure {
  UnknownWrapper(name: String)
  WrongValueKind(expected: String)
  ConflictingMember(key: String)
  MissingMember(key: String)
  InvalidMember(key: String)
  MissingTagModel
  NoBranchSelected
  InvariantFailure(message: String)
}

pub fn named_wrapper(
  prepared: validation.PreparedGraph,
  wrapper_name: String,
) -> Result(types.Wrapper, SemanticRuntimeFailure) {
  validation.prepared_wrapper(prepared, wrapper_name)
  |> option.to_result(UnknownWrapper(wrapper_name))
}

pub fn wrap_encode(wrapper: types.Wrapper, payload: String) -> kdl.JsonValue {
  kdl.JsonValueObj([#(wrapper.key, kdl.JsonValueStr(payload))])
}

pub fn bytes_wire(
  prepared: validation.PreparedGraph,
  wire: String,
) -> kdl.JsonValue {
  case validation.prepared_graph(prepared).profile.bytes_policy {
    Some(types.BytesPolicy(wrapper: Some(name), ..)) ->
      case named_wrapper(prepared, name) {
        Ok(wrapper) -> wrap_encode(wrapper, wire)
        Error(_) -> kdl.JsonValueStr(wire)
      }
    _ -> kdl.JsonValueStr(wire)
  }
}

pub fn wrap_decode(
  wrapper: types.Wrapper,
  value: kdl.JsonValue,
) -> Result(String, SemanticRuntimeFailure) {
  case value {
    kdl.JsonValueObj([#(key, kdl.JsonValueStr(payload))])
      if key == wrapper.key
    -> Ok(payload)
    _ -> Error(InvariantFailure("validated wrapper shape"))
  }
}

pub fn ordered_members(
  members: List(#(String, kdl.JsonValue)),
  member_order: List(String),
) -> List(#(String, kdl.JsonValue)) {
  let groups =
    list.fold(list.reverse(members), dict.new(), fn(groups, member) {
      dict.upsert(groups, member.0, fn(group) {
        [member, ..option.unwrap(group, [])]
      })
    })
  let ordered =
    list.fold(member_order, dict.new(), fn(ordered, key) {
      dict.insert(ordered, key, Nil)
    })
  list.append(
    list.flat_map(list.unique(member_order), fn(key) {
      result.unwrap(dict.get(groups, key), [])
    }),
    list.filter(members, fn(member) { !dict.has_key(ordered, member.0) }),
  )
}

pub fn with_member(
  key: String,
  text: String,
  value: kdl.JsonValue,
) -> Result(kdl.JsonValue, SemanticRuntimeFailure) {
  case value {
    kdl.JsonValueObj(members) ->
      case list.key_find(members, key) {
        Error(_) ->
          Ok(kdl.JsonValueObj([#(key, kdl.JsonValueStr(text)), ..members]))
        Ok(kdl.JsonValueStr(observed)) if observed == text -> Ok(value)
        _ -> Error(ConflictingMember(key))
      }
    _ -> Error(WrongValueKind("object"))
  }
}

pub fn class_of(
  profile: types.SemanticProfile,
  value: kdl.JsonValue,
) -> types.ObjectClass {
  case value {
    kdl.JsonValueObj(members) -> validation.class_of(profile, members)
    _ -> types.OrdinaryObjectClass
  }
}

fn value_kind(value: kdl.JsonValue) -> types.ValueKind {
  case value {
    kdl.JsonValueNull -> types.NullKind
    kdl.JsonValueBool(_) -> types.BooleanKind
    kdl.JsonValueNum(_) | kdl.JsonValueDec(_) -> types.NumberKind
    kdl.JsonValueStr(_) -> types.StringKind
    kdl.JsonValueArr(_) -> types.ArrayKind
    kdl.JsonValueObj(_) -> types.ObjectKind
  }
}

fn selector_matches(
  prepared: validation.PreparedGraph,
  wire_tag: String,
  selector: types.BranchSelector,
  value: kdl.JsonValue,
) -> Bool {
  case selector {
    types.InternalTag ->
      case validation.prepared_graph(prepared).profile.tag, value {
        Some(tag), kdl.JsonValueObj(members) ->
          list.key_find(members, tag.key) == Ok(kdl.JsonValueStr(wire_tag))
        _, _ -> False
      }
    types.MemberShape(tests) ->
      case value {
        kdl.JsonValueObj(members) ->
          list.all(tests, fn(member_test) {
            case member_test.1, list.key_find(members, member_test.0) {
              types.AbsentMember, Error(_) -> True
              types.FormatMember(name), Ok(member) ->
                validation.named_format_matches(prepared, name, member)
              _, _ -> False
            }
          })
        _ -> False
      }
    types.Kind(kind) -> value_kind(value) == kind
    types.Otherwise -> True
  }
}

pub fn select_branch(
  prepared: validation.PreparedGraph,
  branches: List(#(String, types.BranchSelector)),
  value: kdl.JsonValue,
) -> Result(Int, SemanticRuntimeFailure) {
  case
    list.find(
      list.index_map(branches, fn(branch, index) { #(index, branch) }),
      fn(indexed) {
        selector_matches(prepared, indexed.1.0, indexed.1.1, value)
      },
    )
  {
    Ok(indexed) -> Ok(indexed.0)
    Error(_) -> Error(NoBranchSelected)
  }
}
