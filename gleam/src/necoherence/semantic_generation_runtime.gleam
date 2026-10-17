// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import necoherence/exact_json as kdl
import necoherence/network_effect as network
import necoherence/network_host as adapter
import necoherence/semantic_composition as composition
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
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  value: kdl.JsonValue,
) -> Result(Nil, ValueFailure) {
  result.map(validation.validate_value(graph, reference, value), fn(_) { Nil })
  |> result.map_error(Constraint)
}

pub fn validate_slot(
  graph: types.SemanticGraph,
  contract: types.SlotContract,
  value: types.SlotValue(kdl.JsonValue),
) -> Result(Nil, ValueFailure) {
  result.map(validation.validate_slot(graph, contract, value), fn(_) { Nil })
  |> result.map_error(Constraint)
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

pub type CallbackFailure {
  CallbackFailure(condition: String)
  CallbackValue(failure: ValueFailure)
}

pub type OutcomeValues {
  OutcomeValues(
    outcome: composition.OutcomeId,
    values: List(#(composition.PortId, types.SlotValue(kdl.JsonValue))),
  )
}

pub type NetworkOwner {
  NetworkOwner(
    encode: fn(List(#(composition.PortId, types.SlotValue(kdl.JsonValue)))) ->
      Result(network.AttemptInput, CallbackFailure),
    decode: fn(network.RawHttpResponse) ->
      Result(OutcomeValues, CallbackFailure),
    ports: adapter.AdapterPorts,
  )
}

pub type PreparedAttempt {
  Ready(input: network.AttemptInput)
  CompletedOutcome(outcome: OutcomeValues)
}

pub type PreparedNetworkOwner {
  PreparedNetworkOwner(
    prepare: fn(List(#(composition.PortId, types.SlotValue(kdl.JsonValue)))) ->
      Result(PreparedAttempt, CallbackFailure),
    decode: fn(network.RawHttpResponse) ->
      Result(OutcomeValues, CallbackFailure),
    ports: adapter.AdapterPorts,
  )
}

pub type ProviderImplementation {
  Pure(
    callback: fn(List(#(composition.PortId, types.SlotValue(kdl.JsonValue)))) ->
      Result(OutcomeValues, CallbackFailure),
  )
  Http(owner: NetworkOwner)
  PreparedHttp(owner: PreparedNetworkOwner)
}

pub type Provider {
  Provider(
    reference: composition.FunctionRef,
    implementation: ProviderImplementation,
  )
}

pub type TerminalValues {
  Success(
    outputs: List(#(composition.GoalPortId, types.SlotValue(kdl.JsonValue))),
  )
  DeclaredFailure(
    embedding: composition.FailureEmbeddingId,
    value: types.SlotValue(kdl.JsonValue),
  )
}

pub type FailureCause {
  MissingComposition
  MissingInput(input: composition.InputId)
  InvalidInput(
    input: composition.InputId,
    failure: validation.ValidationFailure,
  )
  InputCoverage(condition: String)
  MissingProvider(function: composition.FunctionRef)
  ProviderCoverage(condition: String)
  ProviderEffect(function: composition.FunctionRef)
  ProviderFailed(function: composition.FunctionRef, failure: CallbackFailure)
  InvalidOutput(
    function: composition.FunctionRef,
    port: composition.PortId,
    failure: validation.ValidationFailure,
  )
  OutcomeCoverage(function: composition.FunctionRef, condition: String)
  BindingProjection(failure: validation.ProjectionValueFailure)
  BindingValue(condition: String)
  GuardMeaning(obligations: List(types.SemanticObligation))
  InvalidGuard(failure: types.ValueFailure)
  GuardCertificateMismatch(condition: String)
  MissingGuard(guard: composition.GuardId)
  MissingProducer(producer: composition.ProducerRef)
  MissingBranch(condition: String)
  InvalidTerminal(port: String, failure: validation.ValidationFailure)
  ResourceCondition(condition: String)
  Network(failure: network.NetworkFailure)
  NetworkTerminal(terminal: network.NetworkTerminal)
}

pub type RunFailure {
  RunFailure(cause: FailureCause, network: network.NetworkState)
}

pub type Progress {
  Completed(terminal: TerminalValues, network: network.NetworkState)
  Pending(execution: Execution)
}

type ResourceBranch {
  ResourceBranch(
    certificate: composition.ResourceTraceCertificate,
    remaining_steps: List(composition.TraceStep),
    remaining_phases: List(String),
    marking: resource.Marking,
  )
}

type PendingHttp {
  PendingHttp(
    invocation: composition.InvocationPlan,
    arms: List(#(composition.OutcomeId, composition.PlanTree)),
    owner: NetworkOwner,
    adapter: adapter.Execution,
  )
}

pub opaque type Execution {
  Execution(
    graph: types.SemanticGraph,
    problem: composition.CompositionInput,
    tree: composition.PlanTree,
    providers: List(Provider),
    available: List(#(composition.ProducerRef, types.SlotValue(kdl.JsonValue))),
    resources: List(ResourceBranch),
    network: network.NetworkState,
    pending: Option(PendingHttp),
    external_failure: fn(composition.FunctionRef, composition.OutcomeId) -> Bool,
  )
}

pub fn execution_network(execution: Execution) -> network.NetworkState {
  execution.network
}

fn fail(cause: FailureCause) -> Result(a, FailureCause) {
  Error(cause)
}

fn require(condition: Bool, cause: FailureCause) -> Result(Nil, FailureCause) {
  case condition {
    True -> Ok(Nil)
    False -> fail(cause)
  }
}

fn attach(
  state: network.NetworkState,
  value: Result(a, FailureCause),
) -> Result(a, RunFailure) {
  result.map_error(value, fn(cause) { RunFailure(cause, state) })
}

fn find(values: List(a), predicate: fn(a) -> Bool) -> Option(a) {
  case list.find(values, predicate) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn unique(values: List(a)) -> Bool {
  case values {
    [] -> True
    [first, ..rest] -> !list.contains(rest, first) && unique(rest)
  }
}

fn signature(
  execution: Execution,
  reference: composition.FunctionRef,
) -> Result(composition.FunctionSignature, FailureCause) {
  case
    find(execution.problem.signatures, fn(signature) {
      signature.reference == reference
    })
  {
    Some(signature) -> Ok(signature)
    None -> fail(MissingProvider(reference))
  }
}

pub fn start_composition(
  checked_composition: composition.CheckedComposition,
  arguments: List(#(composition.InputId, types.SlotValue(kdl.JsonValue))),
  providers: List(Provider),
  expected: List(composition.FunctionSignature),
  state: network.NetworkState,
  external_failure: fn(composition.FunctionRef, composition.OutcomeId) -> Bool,
) -> Result(Progress, RunFailure) {
  use state <- result.try(case network.read_network_state(state) {
    network.Read(state) -> Ok(state)
    network.ReadRejected(state, failure) ->
      Error(RunFailure(Network(failure), state))
  })
  let prepared = composition.checked_prepared(checked_composition)
  let problem = composition.prepared_input(prepared)
  let graph = composition.prepared_graph(prepared)
  use _ <- result.try(attach(
    state,
    require(
      unique(list.map(arguments, fn(argument) { argument.0 }))
        && list.all(arguments, fn(argument) {
        list.any(problem.initial_inputs, fn(initial) {
          initial.id == argument.0 && initial.source == composition.Argument
        })
      }),
      InputCoverage("unique declared argument IDs required"),
    ),
  ))
  use available <- result.try(attach(
    state,
    list.try_map(problem.initial_inputs, fn(initial) {
      use value <- result.try(case initial.source {
        composition.SuppliedValue(value) -> Ok(value)
        composition.Argument ->
          case list.key_find(arguments, initial.id) {
            Ok(value) -> Ok(value)
            Error(_) -> fail(MissingInput(initial.id))
          }
      })
      use _ <- result.try(
        result.map_error(
          validation.validate_slot(graph, initial.contract, value),
          fn(failure) { InvalidInput(initial.id, failure) },
        ),
      )
      Ok(#(composition.Initial(initial.id), value))
    }),
  ))
  use _ <- result.try(attach(
    state,
    require(
      unique(list.map(providers, fn(provider) { provider.reference }))
        && list.length(providers) == list.length(expected)
        && list.all(expected, fn(signature) {
        list.any(providers, fn(provider) {
          provider.reference == signature.reference
        })
      }),
      ProviderCoverage(
        "exact provider identity/revision/digest coverage required",
      ),
    ),
  ))
  use _ <- result.try(attach(
    state,
    list.try_map(expected, fn(signature) {
      case
        find(providers, fn(provider) {
          provider.reference == signature.reference
        })
      {
        None -> fail(MissingProvider(signature.reference))
        Some(provider) ->
          require(
            case signature.effect, provider.implementation {
              composition.PureFunction, Pure(_)
              | composition.DataOnly, Pure(_)
              | composition.HttpRequestResponse, Http(_)
              | composition.HttpRequestResponse, PreparedHttp(_)
              -> True
              _, _ -> False
            },
            ProviderEffect(signature.reference),
          )
      }
    }),
  ))
  let resources =
    list.map(
      composition.checked_witness(checked_composition).resource_traces,
      fn(certificate) {
        ResourceBranch(
          certificate,
          certificate.trace.steps,
          certificate.correspondence.execution_order,
          certificate.lowering.marking,
        )
      },
    )
  advance(Execution(
    graph,
    problem,
    composition.checked_plan(checked_composition).root,
    providers,
    available,
    resources,
    state,
    None,
    external_failure,
  ))
}

fn source_value(
  execution: Execution,
  reference: composition.ValueRef,
) -> Result(types.SlotValue(kdl.JsonValue), FailureCause) {
  case list.key_find(execution.available, reference.producer) {
    Error(_) -> fail(MissingProducer(reference.producer))
    Ok(types.Absent) -> Ok(types.Absent)
    Ok(types.Null) ->
      case reference.path {
        [] -> Ok(types.Null)
        _ -> Ok(types.Absent)
      }
    Ok(types.Present(value)) ->
      Ok(validation.value_at_path(
        execution.graph.profile.tag,
        value,
        reference.path,
      ))
  }
}

fn bind(
  execution: Execution,
  binding: composition.BindingExpr,
) -> Result(types.SlotValue(kdl.JsonValue), FailureCause) {
  case binding {
    composition.Source(reference, projection, compatibility) -> {
      use source <- result.try(
        case list.key_find(execution.available, reference.producer) {
          Ok(value) -> Ok(value)
          Error(_) -> fail(MissingProducer(reference.producer))
        },
      )
      let prefix_length =
        list.length(reference.path) - list.length(projection.path)
      use _ <- result.try(require(
        prefix_length >= 0
          && list.drop(reference.path, prefix_length) == projection.path,
        BindingValue("projection path is outside the binding path"),
      ))
      let refined = case source {
        types.Present(root) ->
          validation.value_at_path(
            execution.graph.profile.tag,
            root,
            list.take(reference.path, prefix_length),
          )
        other -> other
      }
      use projected <- result.try(result.map_error(
        validation.project_value(execution.graph, projection, refined),
        BindingProjection,
      ))
      let value = validation.validated_slot_value(projected)
      use _ <- result.try(case compatibility {
        composition.Inclusion(_) -> Ok(Nil)
        composition.SuppliedBindingValue(expected) ->
          require(
            value == expected,
            BindingValue(
              "actual supplied binding value differs from certificate",
            ),
          )
      })
      Ok(value)
    }
    composition.Product(_, _, fields) -> {
      use members <- result.try(
        list.try_map(fields, fn(field) {
          use value <- result.try(bind(execution, field.1))
          Ok(slot_members(field.0, value))
        }),
      )
      Ok(types.Present(kdl.JsonValueObj(list.flatten(members))))
    }
  }
}

fn invocation_inputs(
  execution: Execution,
  invocation: composition.InvocationPlan,
  function: composition.FunctionSignature,
) -> Result(
  List(#(composition.PortId, types.SlotValue(kdl.JsonValue))),
  FailureCause,
) {
  list.try_map(function.inputs, fn(port) {
    use binding <- result.try(case list.key_find(invocation.bindings, port.id) {
      Ok(value) -> Ok(value)
      Error(_) -> fail(BindingValue("checked input binding missing"))
    })
    use value <- result.try(bind(execution, binding))
    use _ <- result.try(
      result.map_error(
        validation.validate_slot(execution.graph, port.contract, value),
        fn(failure) { InvalidOutput(function.reference, port.id, failure) },
      ),
    )
    Ok(#(port.id, value))
  })
}

fn next_resource_step(branch: ResourceBranch) -> Option(composition.TraceStep) {
  case branch.remaining_steps {
    [step, ..] -> Some(step)
    [] -> None
  }
}

fn phase_enabled(branch: ResourceBranch) -> Bool {
  case branch.remaining_phases {
    [] -> False
    [identity, ..] ->
      resource.transition_enabled_at(
        resource.bindings_for(branch.certificate.lowering, identity),
        branch.marking,
      )
  }
}

fn apply_phases(
  branch: ResourceBranch,
  count: Int,
) -> Result(ResourceBranch, FailureCause) {
  case count {
    0 ->
      case branch.remaining_steps {
        [_, ..rest] -> Ok(ResourceBranch(..branch, remaining_steps: rest))
        [] -> fail(ResourceCondition("resource trace exhausted"))
      }
    _ -> {
      use phase <- result.try(case branch.remaining_phases {
        [identity, ..rest] -> Ok(#(identity, rest))
        [] -> fail(ResourceCondition("resource phase missing"))
      })
      let identity = phase.0
      let input = branch.certificate.lowering
      use transition <- result.try(
        case
          find(input.transitions, fn(transition) {
            transition.identity == identity
          })
        {
          Some(transition) -> Ok(transition)
          None -> fail(ResourceCondition("resource transition missing"))
        },
      )
      let bindings = resource.bindings_for(input, identity)
      use _ <- result.try(require(
        resource.transition_enabled_at(bindings, branch.marking),
        ResourceCondition(
          "actual read/consume/multiplicity/revision/producer/control condition failed",
        ),
      ))
      apply_phases(
        ResourceBranch(
          ..branch,
          remaining_phases: phase.1,
          marking: resource.apply_branch_at(
            branch.marking,
            transition,
            bindings,
          ),
        ),
        count - 1,
      )
    }
  }
}

fn reserve_invocation(
  execution: Execution,
  invocation: composition.InvocationPlan,
) -> Result(Nil, FailureCause) {
  let candidates =
    list.filter(execution.resources, fn(branch) {
      case next_resource_step(branch) {
        Some(composition.InvocationStep(expected, _)) -> expected == invocation
        _ -> False
      }
    })
  require(
    candidates != [] && list.all(candidates, phase_enabled),
    ResourceCondition("no enabled certified invocation resource branch"),
  )
}

fn resource_step(
  execution: Execution,
  step: composition.TraceStep,
  phases: Int,
) -> Result(List(ResourceBranch), FailureCause) {
  let candidates =
    list.filter(execution.resources, fn(branch) {
      next_resource_step(branch) == Some(step)
    })
  use _ <- result.try(require(
    candidates != [],
    ResourceCondition("actual branch has no resource certificate"),
  ))
  list.try_map(candidates, fn(branch) { apply_phases(branch, phases) })
}

fn accept_outcome(
  execution: Execution,
  invocation: composition.InvocationPlan,
  arms: List(#(composition.OutcomeId, composition.PlanTree)),
  outcome: OutcomeValues,
) -> Result(Execution, FailureCause) {
  use function <- result.try(signature(execution, invocation.function))
  use contract <- result.try(
    case
      find(function.outcomes, fn(contract) { contract.id == outcome.outcome })
    {
      Some(contract) -> Ok(contract)
      None -> fail(OutcomeCoverage(function.reference, "undeclared outcome"))
    },
  )
  use _ <- result.try(require(
    unique(list.map(outcome.values, fn(value) { value.0 }))
      && list.length(outcome.values) == list.length(contract.value_ports)
      && list.all(contract.value_ports, fn(port) {
      list.any(outcome.values, fn(value) { value.0 == port.id })
    }),
    OutcomeCoverage(
      function.reference,
      "exact declared value-port coverage required",
    ),
  ))
  use produced <- result.try(
    list.try_map(contract.value_ports, fn(port) {
      use value <- result.try(case list.key_find(outcome.values, port.id) {
        Ok(value) -> Ok(value)
        Error(_) ->
          fail(OutcomeCoverage(function.reference, "missing output port"))
      })
      use _ <- result.try(
        result.map_error(
          validation.validate_slot(execution.graph, port.contract, value),
          fn(failure) { InvalidOutput(function.reference, port.id, failure) },
        ),
      )
      Ok(#(
        composition.InvocationOutcome(invocation.site, outcome.outcome, port.id),
        value,
      ))
    }),
  )
  use child <- result.try(case list.key_find(arms, outcome.outcome) {
    Ok(child) -> Ok(child)
    Error(_) ->
      fail(MissingBranch("actual callback returned an outcome certified empty"))
  })
  use resources <- result.try(resource_step(
    execution,
    composition.InvocationStep(invocation, outcome.outcome),
    1 + list.length(contract.produced_resources),
  ))
  Ok(
    Execution(
      ..execution,
      tree: child,
      available: list.append(execution.available, produced),
      resources: resources,
      pending: None,
    ),
  )
}

fn guard_arm(
  execution: Execution,
  id: composition.GuardId,
  inspected: composition.ValueRef,
) -> Result(composition.GuardArm, FailureCause) {
  use guard <- result.try(
    case
      find(execution.problem.invocation_domain.guards, fn(guard) {
        guard.id == id
      })
    {
      Some(guard) -> Ok(guard)
      None -> fail(MissingGuard(id))
    },
  )
  use value <- result.try(source_value(execution, inspected))
  case composition.evaluate_guard_arm(execution.graph, guard, value) {
    Ok(arm) -> Ok(arm)
    Error(types.UnresolvedValue(obligations)) -> fail(GuardMeaning(obligations))
    Error(types.RejectedValue(failure)) -> fail(InvalidGuard(failure))
    Error(types.CertificateMismatchValue(condition)) ->
      fail(GuardCertificateMismatch(condition))
    Error(types.AcceptedValue) ->
      fail(BindingValue("guard returned no branch decision"))
  }
}

fn terminal(
  execution: Execution,
  returned: composition.ReturnPlan,
) -> Result(TerminalValues, FailureCause) {
  let problem = execution.problem
  use _ <- result.try(require(
    list.any(execution.resources, fn(branch) {
      branch.certificate.trace.terminal == returned
      && branch.remaining_steps == []
      && branch.remaining_phases == []
      && branch.marking == branch.certificate.reachability.final_marking
      && resource.eval_goal(branch.marking, branch.certificate.lowering.goal)
    }),
    ResourceCondition(
      "actual371resource marking does not satisfy certified terminal",
    ),
  ))
  case returned {
    composition.ReturnSuccess(outputs) -> {
      use outputs <- result.try(
        list.try_map(outputs, fn(output) {
          use goal <- result.try(
            case find(problem.goal.outputs, fn(goal) { goal.id == output.0 }) {
              Some(goal) -> Ok(goal)
              None -> fail(BindingValue("goal missing"))
            },
          )
          use value <- result.try(bind(execution, output.1))
          use _ <- result.try(
            result.map_error(
              validation.validate_slot(execution.graph, goal.contract, value),
              fn(failure) { InvalidTerminal(goal.id.value, failure) },
            ),
          )
          Ok(#(goal.id, value))
        }),
      )
      Ok(Success(outputs))
    }
    composition.ReturnFailure(id, binding) -> {
      use embedding <- result.try(
        case find(problem.goal.failures, fn(embedding) { embedding.id == id }) {
          Some(embedding) -> Ok(embedding)
          None -> fail(BindingValue("failure embedding missing"))
        },
      )
      use value <- result.try(bind(execution, binding))
      use _ <- result.try(
        result.map_error(
          validation.validate_slot(execution.graph, embedding.contract, value),
          fn(failure) { InvalidTerminal(id.value, failure) },
        ),
      )
      Ok(DeclaredFailure(id, value))
    }
  }
}

fn advance(execution: Execution) -> Result(Progress, RunFailure) {
  case execution.tree.node {
    composition.Return(returned) ->
      result.map(
        attach(execution.network, terminal(execution, returned)),
        fn(terminal) { Completed(terminal, execution.network) },
      )
    composition.Guard(guard, inspected, arms) -> {
      use arm <- result.try(attach(
        execution.network,
        guard_arm(execution, guard, inspected),
      ))
      use child <- result.try(
        attach(execution.network, case list.key_find(arms, arm) {
          Ok(child) -> Ok(child)
          Error(_) -> fail(MissingBranch("actual guard arm omitted"))
        }),
      )
      use resources <- result.try(attach(
        execution.network,
        resource_step(
          execution,
          composition.GuardStep(guard, inspected, arm),
          1,
        ),
      ))
      advance(Execution(..execution, tree: child, resources: resources))
    }
    composition.Invoke(invocation, arms, _) -> {
      use function <- result.try(attach(
        execution.network,
        signature(execution, invocation.function),
      ))
      use inputs <- result.try(attach(
        execution.network,
        invocation_inputs(execution, invocation, function),
      ))
      use _ <- result.try(attach(
        execution.network,
        reserve_invocation(execution, invocation),
      ))
      use provider <- result.try(
        attach(
          execution.network,
          case
            find(execution.providers, fn(provider) {
              provider.reference == invocation.function
            })
          {
            Some(provider) -> Ok(provider)
            None -> fail(MissingProvider(invocation.function))
          },
        ),
      )
      case provider.implementation {
        Pure(callback) -> {
          use outcome <- result.try(
            result.map_error(callback(inputs), fn(message) {
              RunFailure(
                ProviderFailed(invocation.function, message),
                execution.network,
              )
            }),
          )
          use execution <- result.try(attach(
            execution.network,
            accept_outcome(execution, invocation, arms, outcome),
          ))
          advance(execution)
        }
        Http(owner) -> start_http(execution, invocation, arms, inputs, owner)
        PreparedHttp(owner) -> {
          use prepared <- result.try(
            result.map_error(owner.prepare(inputs), fn(failure) {
              RunFailure(
                ProviderFailed(invocation.function, failure),
                execution.network,
              )
            }),
          )
          case prepared {
            Ready(input) ->
              start_http(
                execution,
                invocation,
                arms,
                inputs,
                NetworkOwner(fn(_) { Ok(input) }, owner.decode, owner.ports),
              )
            CompletedOutcome(outcome) -> {
              use _ <- result.try(attach(
                execution.network,
                require(
                  execution.external_failure(
                    invocation.function,
                    outcome.outcome,
                  ),
                  OutcomeCoverage(
                    invocation.function,
                    "prepare completed requires a declared external failure",
                  ),
                ),
              ))
              use execution <- result.try(attach(
                execution.network,
                accept_outcome(execution, invocation, arms, outcome),
              ))
              advance(execution)
            }
          }
        }
      }
    }
  }
}

fn start_http(
  execution: Execution,
  invocation: composition.InvocationPlan,
  arms: List(#(composition.OutcomeId, composition.PlanTree)),
  inputs: List(#(composition.PortId, types.SlotValue(kdl.JsonValue))),
  owner: NetworkOwner,
) -> Result(Progress, RunFailure) {
  use input <- result.try(
    result.map_error(owner.encode(inputs), fn(message) {
      RunFailure(
        ProviderFailed(invocation.function, message),
        execution.network,
      )
    }),
  )
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
  case adapter.start_with_ports(command.1, owner.ports) {
    adapter.Started(adapter_execution) -> {
      let observation =
        network.StartedObservation(
          input.attempt,
          adapter.handle(adapter_execution),
        )
      case network.observe_start(command.0, prepared.1, observation) {
        network.StartedStep(state, _) ->
          Ok(Pending(
            Execution(
              ..execution,
              network: state,
              pending: Some(PendingHttp(
                invocation,
                arms,
                owner,
                adapter_execution,
              )),
            ),
          ))
        network.NetworkRejected(state, failure) ->
          Error(RunFailure(Network(failure), state))
        _ ->
          Error(RunFailure(
            MissingBranch("unexpected start observation result"),
            command.0,
          ))
      }
    }
    adapter.StartFailed(failure, effect) ->
      case
        network.observe_start(
          command.0,
          prepared.1,
          network.StartFailed(failure, effect),
        )
      {
        network.TerminalStep(state, settled) ->
          Error(RunFailure(NetworkTerminal(settled.terminal), state))
        network.NetworkRejected(state, failure) ->
          Error(RunFailure(Network(failure), state))
        _ ->
          Error(RunFailure(
            MissingBranch("unexpected failed-start result"),
            command.0,
          ))
      }
  }
}

pub fn resume(execution: Execution) -> Result(Progress, RunFailure) {
  case execution.pending {
    None ->
      Error(RunFailure(
        MissingBranch("only pending executions may resume"),
        execution.network,
      ))
    Some(pending) ->
      case adapter.observe(pending.adapter) {
        Error(_) -> Ok(Pending(execution))
        Ok(observation) ->
          case network.observe(execution.network, observation) {
            network.PendingStep(state, _) ->
              Ok(Pending(Execution(..execution, network: state)))
            network.TerminalStep(state, settled) ->
              case settled.terminal.outcome {
                network.Response(response, _) -> {
                  use outcome <- result.try(
                    result.map_error(
                      pending.owner.decode(response),
                      fn(message) {
                        RunFailure(
                          ProviderFailed(pending.invocation.function, message),
                          state,
                        )
                      },
                    ),
                  )
                  let execution = Execution(..execution, network: state)
                  use execution <- result.try(attach(
                    state,
                    accept_outcome(
                      execution,
                      pending.invocation,
                      pending.arms,
                      outcome,
                    ),
                  ))
                  advance(execution)
                }
                _ -> Error(RunFailure(NetworkTerminal(settled.terminal), state))
              }
            network.NetworkRejected(state, failure) ->
              Error(RunFailure(Network(failure), state))
            network.DuplicateStep(state, _, _) ->
              Ok(Pending(Execution(..execution, network: state)))
            network.LateStep(state, _, _) ->
              Ok(Pending(Execution(..execution, network: state)))
            network.StartedStep(state, _) ->
              Error(RunFailure(
                MissingBranch("completion delivered a start result"),
                state,
              ))
          }
      }
  }
}

pub type SemanticRuntimeFailure {
  UnknownWrapper(name: String)
  WrongWrapperPayload(name: String)
  WrongValueKind(expected: String)
  ConflictingMember(key: String)
  MissingMember(key: String)
  InvalidMember(key: String)
  MissingTagModel
  NoBranchSelected
}

pub fn wrap_encode(
  profile: types.SemanticProfile,
  wrapper_name: String,
  payload: kdl.JsonValue,
) -> Result(kdl.JsonValue, SemanticRuntimeFailure) {
  case
    list.find(profile.wrappers, fn(wrapper) { wrapper.name == wrapper_name })
  {
    Error(_) -> Error(UnknownWrapper(wrapper_name))
    Ok(wrapper) ->
      case wrapper.payload, payload {
        types.WrapperBytes, kdl.JsonValueStr(_) ->
          Ok(kdl.JsonValueObj([#(wrapper.key, payload)]))
        types.WrapperText(_), kdl.JsonValueStr(_) ->
          Ok(kdl.JsonValueObj([#(wrapper.key, payload)]))
        _, _ -> Error(WrongWrapperPayload(wrapper_name))
      }
  }
}

pub fn wrap_decode(
  profile: types.SemanticProfile,
  wrapper_name: String,
  value: kdl.JsonValue,
) -> Result(kdl.JsonValue, SemanticRuntimeFailure) {
  case
    list.find(profile.wrappers, fn(wrapper) { wrapper.name == wrapper_name })
  {
    Error(_) -> Error(UnknownWrapper(wrapper_name))
    Ok(wrapper) ->
      validation.wrapper_payload_text(profile, wrapper, value)
      |> result.map(kdl.JsonValueStr)
      |> result.map_error(fn(_) { WrongWrapperPayload(wrapper_name) })
  }
}

pub fn ordered_members(
  members: List(#(String, kdl.JsonValue)),
  member_order: List(String),
) -> List(#(String, kdl.JsonValue)) {
  list.append(
    list.flat_map(list.unique(member_order), fn(key) {
      list.filter(members, fn(member) { member.0 == key })
    }),
    list.filter(members, fn(member) { !list.contains(member_order, member.0) }),
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
  validation.object_class(profile, value)
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

fn named_format_accepts(
  profile: types.SemanticProfile,
  name: String,
  value: kdl.JsonValue,
) -> Bool {
  case value {
    kdl.JsonValueStr(text) ->
      case
        list.find(profile.format_bindings, fn(binding) { binding.name == name })
      {
        Ok(binding) -> validation.recognizes(binding.rule, text)
        Error(_) -> False
      }
    _ -> False
  }
}

fn selector_matches(
  profile: types.SemanticProfile,
  wire_tag: String,
  selector: types.BranchSelector,
  value: kdl.JsonValue,
) -> Bool {
  case selector {
    types.InternalTag ->
      case profile.tag, value {
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
                named_format_accepts(profile, name, member)
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
  profile: types.SemanticProfile,
  branches: List(#(String, types.BranchSelector)),
  value: kdl.JsonValue,
) -> Result(Int, SemanticRuntimeFailure) {
  case
    list.find(
      list.index_map(branches, fn(branch, index) { #(index, branch) }),
      fn(indexed) { selector_matches(profile, indexed.1.0, indexed.1.1, value) },
    )
  {
    Ok(indexed) -> Ok(indexed.0)
    Error(_) -> Error(NoBranchSelected)
  }
}
