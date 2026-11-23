// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/composition_input
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/inclusion
import necoherence/network_effect as network
import necoherence/request_progression as progression
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource

fn source() -> types.SourceRef {
  types.SourceRef("test", "1", "types.json", "digest", "test", None)
}

fn reference() -> types.TypeRef {
  types.TypeRef(source(), "truth", ["truth"])
}

fn profile() -> types.SemanticProfile {
  let profile_ref = types.ProfileRef("test", "1", "digest")
  types.SemanticProfile(
    profile_ref,
    [],
    [],
    "default",
    types.NumberModel(True),
    None,
    [],
    None,
    [],
    None,
  )
}

fn graph() -> types.SemanticGraph {
  types.SemanticGraph(
    profile(),
    [
      types.TypeNode(
        reference(),
        types.BooleanShape(types.BooleanSpec(None, None)),
        None,
        [],
        [],
      ),
    ],
    [source()],
  )
}

fn contract() -> types.SlotContract {
  types.SlotContract(reference(), True, False)
}

fn present(value: Bool) -> types.SlotValue(json.JsonValue) {
  types.Present(json.JsonValueBool(value))
}

fn source_binding(
  graph: types.SemanticGraph,
  producer: composition_plan.ProducerRef,
  value: types.SlotValue(json.JsonValue),
) -> composition_plan.BindingExpr {
  let assert Ok(projection) =
    validation.project_slot(validation.prepare(graph), contract(), [], [])
  composition_plan.Source(
    composition_plan.ValueRef(producer, []),
    projection,
    composition_plan.SuppliedBindingValue(value),
  )
}

fn inclusion_binding(
  graph: types.SemanticGraph,
  producer: composition_plan.ProducerRef,
) -> composition_plan.BindingExpr {
  let assert Ok(projection) =
    validation.project_slot(validation.prepare(graph), contract(), [], [])
  let assert inclusion.Compatible(inclusion) =
    inclusion.check_assignable(
      validation.prepare(graph),
      contract(),
      contract(),
      64,
    )
  composition_plan.Source(
    composition_plan.ValueRef(producer, []),
    projection,
    composition_plan.Inclusion(inclusion),
  )
}

fn checked(
  signatures: List(composition_plan.FunctionSignature),
  sites: List(composition_plan.InvocationSite),
  guards: List(composition_plan.DeclaredGuard),
  goal: composition_plan.GoalSpec,
  effects: List(composition_plan.CompositionEffect),
  initial_resources: List(composition_plan.ResourceLot),
  initial_source: composition_plan.InitialSource,
  tree: fn(composition_plan.PreparedCompositionInput) ->
    composition_plan.PlanTree,
) -> composition_plan.CheckedComposition {
  let graph = graph()
  let initial =
    composition_plan.InitialInput(
      composition_plan.InputId("input"),
      contract(),
      initial_source,
      None,
    )
  let input =
    composition_plan.CompositionInput(
      "composition",
      "1",
      composition_plan.semantic_basis_of(graph),
      signatures,
      [initial],
      initial_resources,
      goal,
      composition_plan.InvocationDomain(
        "domain",
        "1",
        sites,
        [],
        [],
        [],
        guards,
      ),
      effects,
      [],
      Some(composition_plan.AnyFeasible),
      composition_plan.SearchBounds(10_000, 100_000, 10_000, 100_000, 32, None),
    )
  let assert Ok(prepared) =
    composition_input.prepare_direct_composition(
      validation.prepare(graph),
      input,
      fn(_, _) { Ok(Nil) },
      fn(_, _) { [] },
    )
  let root = tree(prepared)
  composition_plan.admitted_composition(
    prepared,
    composition_plan.CompositionPlan(input.identity, input.revision, root),
  )
}

fn function(
  effect: composition_plan.CompositionEffect,
) -> composition_plan.FunctionSignature {
  composition_plan.FunctionSignature(
    composition_plan.FunctionRef("provider", "1", "digest"),
    case effect {
      composition_plan.PureFunction -> composition_plan.Pure
      _ ->
        composition_plan.Operation(types.DefinitionRef(source(), "operation"))
    },
    effect,
    [],
    [
      composition_plan.OutcomeContract(
        composition_plan.OutcomeId("done"),
        composition_plan.Success,
        [
          composition_plan.OutputPort(
            composition_plan.PortId("value"),
            contract(),
            None,
          ),
        ],
        [],
      ),
    ],
    [],
    "assumption",
    None,
  )
}

fn invocation_checked(
  effect: composition_plan.CompositionEffect,
) -> composition_plan.CheckedComposition {
  let signature = function(effect)
  let site = composition_plan.SiteId("site")
  let invocation =
    composition_plan.InvocationPlan(site, signature.reference, [], [])
  let goal =
    composition_plan.GoalSpec(
      [
        composition_plan.GoalPort(
          composition_plan.GoalPortId("goal"),
          contract(),
          composition_plan.AnyCompatible,
        ),
      ],
      [],
      [],
    )
  checked(
    [signature],
    [composition_plan.InvocationSite(site, signature.reference)],
    [],
    goal,
    [effect],
    [],
    composition_plan.SuppliedValue(present(False)),
    fn(prepared) {
      let producer =
        composition_plan.InvocationOutcome(
          site,
          composition_plan.OutcomeId("done"),
          composition_plan.PortId("value"),
        )
      let binding =
        inclusion_binding(composition_plan.prepared_graph(prepared), producer)
      let terminal =
        composition_plan.ReturnSuccess([
          #(composition_plan.GoalPortId("goal"), binding),
        ])
      composition_plan.Invoke(
        0,
        invocation,
        [
          #(
            composition_plan.OutcomeId("done"),
            composition_plan.ReturnValue(1, terminal),
          ),
        ],
        [],
      )
    },
  )
}

fn argument_checked() -> composition_plan.CheckedComposition {
  let goal =
    composition_plan.GoalSpec(
      [
        composition_plan.GoalPort(
          composition_plan.GoalPortId("goal"),
          contract(),
          composition_plan.AnyCompatible,
        ),
      ],
      [],
      [],
    )
  checked([], [], [], goal, [], [], composition_plan.Argument, fn(prepared) {
    let producer = composition_plan.Initial(composition_plan.InputId("input"))
    let binding =
      inclusion_binding(composition_plan.prepared_graph(prepared), producer)
    let terminal =
      composition_plan.ReturnSuccess([
        #(composition_plan.GoalPortId("goal"), binding),
      ])
    composition_plan.ReturnValue(0, terminal)
  })
}

pub fn guard_checked() -> composition_plan.CheckedComposition {
  let id = composition_plan.GuardId("presence")
  let producer = composition_plan.Initial(composition_plan.InputId("input"))
  let inspected = composition_plan.ValueRef(producer, [])
  let guard =
    composition_plan.DeclaredGuard(
      id,
      reference(),
      [],
      composition_plan.Presence,
    )
  let goal =
    composition_plan.GoalSpec(
      [
        composition_plan.GoalPort(
          composition_plan.GoalPortId("goal"),
          contract(),
          composition_plan.AnyCompatible,
        ),
      ],
      [],
      [],
    )
  checked(
    [],
    [],
    [guard],
    goal,
    [],
    [],
    composition_plan.SuppliedValue(present(False)),
    fn(prepared) {
      let terminal =
        composition_plan.ReturnSuccess([
          #(
            composition_plan.GoalPortId("goal"),
            source_binding(
              composition_plan.prepared_graph(prepared),
              producer,
              present(False),
            ),
          ),
        ])
      composition_plan.Guard(0, id, inspected, [
        #(
          composition_plan.GuardPresent,
          composition_plan.ReturnValue(1, terminal),
        ),
      ])
    },
  )
}

fn variant_reference(name: String) -> types.TypeRef {
  types.TypeRef(source(), name, [name])
}

pub fn variant_checked() -> composition_plan.CheckedComposition {
  let any = variant_reference("any")
  let variant = variant_reference("variant")
  let origin = types.OccurrenceRef(source(), [])
  let base_profile = profile()
  let graph =
    types.SemanticGraph(
      types.SemanticProfile(
        ..base_profile,
        tag: Some(types.TagModel("kind", None, [])),
      ),
      [
        types.TypeNode(any, types.UnknownShape(types.AnyValue), None, [], []),
        types.TypeNode(
          variant,
          types.TaggedUnionShape(
            types.UnionSpec([
              types.UnionBranch(any, "known", types.InternalTag, origin),
              types.UnionBranch(any, "fallback", types.InternalTag, origin),
              types.UnionBranch(any, "otherwise", types.Otherwise, origin),
            ]),
          ),
          None,
          [],
          [],
        ),
      ],
      [source()],
    )
  let contract = types.SlotContract(variant, True, False)
  let value =
    types.Present(json.JsonValueObj([#("kind", json.JsonValueStr("other"))]))
  let id = composition_plan.GuardId("variant")
  let producer = composition_plan.Initial(composition_plan.InputId("input"))
  let inspected = composition_plan.ValueRef(producer, [])
  let input =
    composition_plan.CompositionInput(
      "variant-composition",
      "1",
      composition_plan.semantic_basis_of(graph),
      [],
      [
        composition_plan.InitialInput(
          composition_plan.InputId("input"),
          contract,
          composition_plan.SuppliedValue(value),
          None,
        ),
      ],
      [],
      composition_plan.GoalSpec(
        [
          composition_plan.GoalPort(
            composition_plan.GoalPortId("goal"),
            contract,
            composition_plan.AnyCompatible,
          ),
        ],
        [],
        [],
      ),
      composition_plan.InvocationDomain("domain", "1", [], [], [], [], [
        composition_plan.DeclaredGuard(
          id,
          variant,
          [],
          composition_plan.Variants,
        ),
      ]),
      [],
      [],
      Some(composition_plan.AnyFeasible),
      composition_plan.SearchBounds(10_000, 100_000, 10_000, 100_000, 32, None),
    )
  let assert Ok(prepared) =
    composition_input.prepare_direct_composition(
      validation.prepare(graph),
      input,
      fn(_, _) { Ok(Nil) },
      fn(_, _) { [] },
    )
  let assert Ok(projection) =
    validation.project_slot(validation.prepare(graph), contract, [], [
      validation.Variant([], "otherwise"),
    ])
  let binding =
    composition_plan.Source(
      inspected,
      projection,
      composition_plan.SuppliedBindingValue(value),
    )
  let terminal =
    composition_plan.ReturnSuccess([
      #(composition_plan.GoalPortId("goal"), binding),
    ])
  let arm = composition_plan.GuardVariant("otherwise")
  let tree =
    composition_plan.Guard(0, id, inspected, [
      #(arm, composition_plan.ReturnValue(1, terminal)),
    ])
  composition_plan.admitted_composition(
    prepared,
    composition_plan.CompositionPlan(input.identity, input.revision, tree),
  )
}

fn declared_failure_checked() -> composition_plan.CheckedComposition {
  let site = composition_plan.SiteId("site")
  let reference = composition_plan.FunctionRef("provider", "1", "digest")
  let success_id = composition_plan.OutcomeId("done")
  let failure_id = composition_plan.OutcomeId("failed")
  let output =
    composition_plan.OutputPort(
      composition_plan.PortId("value"),
      contract(),
      None,
    )
  let signature =
    composition_plan.FunctionSignature(
      reference,
      composition_plan.Pure,
      composition_plan.PureFunction,
      [],
      [
        composition_plan.OutcomeContract(
          success_id,
          composition_plan.Success,
          [output],
          [],
        ),
        composition_plan.OutcomeContract(
          failure_id,
          composition_plan.DeclaredFailure,
          [output],
          [],
        ),
      ],
      [],
      "assumption",
      None,
    )
  let embedding = composition_plan.FailureEmbeddingId("failure")
  let goal =
    composition_plan.GoalSpec(
      [
        composition_plan.GoalPort(
          composition_plan.GoalPortId("unused"),
          contract(),
          composition_plan.AnyCompatible,
        ),
      ],
      [
        composition_plan.FailureEmbedding(
          embedding,
          composition_plan.FunctionFailure(reference, failure_id),
          contract(),
          [],
        ),
      ],
      [],
    )
  let invocation = composition_plan.InvocationPlan(site, reference, [], [])
  checked(
    [signature],
    [composition_plan.InvocationSite(site, reference)],
    [],
    goal,
    [composition_plan.PureFunction],
    [],
    composition_plan.SuppliedValue(present(False)),
    fn(prepared) {
      let success_producer =
        composition_plan.InvocationOutcome(
          site,
          success_id,
          composition_plan.PortId("value"),
        )
      let failure_producer =
        composition_plan.InvocationOutcome(
          site,
          failure_id,
          composition_plan.PortId("value"),
        )
      let success_terminal =
        composition_plan.ReturnSuccess([
          #(
            composition_plan.GoalPortId("unused"),
            inclusion_binding(
              composition_plan.prepared_graph(prepared),
              success_producer,
            ),
          ),
        ])
      let failure_terminal =
        composition_plan.ReturnFailure(
          embedding,
          inclusion_binding(
            composition_plan.prepared_graph(prepared),
            failure_producer,
          ),
        )
      composition_plan.Invoke(
        0,
        invocation,
        [
          #(success_id, composition_plan.ReturnValue(1, success_terminal)),
          #(failure_id, composition_plan.ReturnValue(1, failure_terminal)),
        ],
        [],
      )
    },
  )
}

fn resource_checked() -> composition_plan.CheckedComposition {
  let site = composition_plan.SiteId("resource-site")
  let function_ref =
    composition_plan.FunctionRef("resource-provider", "1", "digest")
  let outcome_id = composition_plan.OutcomeId("done")
  let requirement_id = composition_plan.RequirementId("required")
  let lot_id = composition_plan.LotId("lot")
  let lot =
    composition_plan.ResourceLot(
      lot_id,
      reference(),
      composition_plan.InitialResource("resource", "1"),
      1,
      2,
      "test",
    )
  let requirement =
    composition_plan.ResourceRequirement(
      requirement_id,
      reference(),
      resource.Consume,
      1,
      1,
      composition_plan.AnyResource,
    )
  let signature =
    composition_plan.FunctionSignature(
      function_ref,
      composition_plan.Pure,
      composition_plan.PureFunction,
      [],
      [
        composition_plan.OutcomeContract(
          outcome_id,
          composition_plan.Success,
          [],
          [],
        ),
      ],
      [requirement],
      "assumption",
      None,
    )
  let assert inclusion.Compatible(inclusion) =
    inclusion.check_assignable(
      validation.prepare(graph()),
      contract(),
      contract(),
      64,
    )
  let invocation =
    composition_plan.InvocationPlan(site, function_ref, [], [
      composition_plan.ResourceBinding(
        requirement_id,
        composition_plan.InitialLot(lot_id),
        inclusion,
      ),
    ])
  let goal =
    composition_plan.GoalSpec(
      [
        composition_plan.GoalPort(
          composition_plan.GoalPortId("goal"),
          contract(),
          composition_plan.AnyCompatible,
        ),
      ],
      [],
      [composition_plan.ResourceGoal(composition_plan.InitialLot(lot_id), 1, 1)],
    )
  checked(
    [signature],
    [composition_plan.InvocationSite(site, function_ref)],
    [],
    goal,
    [composition_plan.PureFunction],
    [lot],
    composition_plan.SuppliedValue(present(False)),
    fn(prepared) {
      let producer = composition_plan.Initial(composition_plan.InputId("input"))
      let terminal =
        composition_plan.ReturnSuccess([
          #(
            composition_plan.GoalPortId("goal"),
            source_binding(
              composition_plan.prepared_graph(prepared),
              producer,
              present(False),
            ),
          ),
        ])
      composition_plan.Invoke(
        0,
        invocation,
        [
          #(outcome_id, composition_plan.ReturnValue(1, terminal)),
        ],
        [],
      )
    },
  )
}

fn attempt_input() -> network.AttemptInput {
  let identity = progression.RequestIdentity("semantic", "http", 1)
  network.AttemptInput(
    network.AttemptIdentity(identity, 0),
    network.HttpWireInstruction("GET", "http://127.0.0.1/test", [], <<>>),
    None,
    network.HostConfiguration(8, 8, None, None),
  )
}

fn outcome(value: Bool) -> runtime.OutcomeValues {
  runtime.OutcomeValues(composition_plan.OutcomeId("done"), [
    #(composition_plan.PortId("value"), present(value)),
  ])
}

pub fn pure_composition_completes_synchronously_test() {
  let provider =
    runtime.Provider(
      function(composition_plan.PureFunction).reference,
      runtime.Pure(fn(_) { Ok(outcome(True)) }),
    )
  let assert Ok(runtime.Completed(runtime.Success(outputs), state)) =
    runtime.start_composition(
      invocation_checked(composition_plan.PureFunction),
      [provider],
      [],
      network.empty_state(),
    )
  assert outputs == [#(composition_plan.GoalPortId("goal"), present(True))]
  assert state == network.empty_state()
}

pub fn http_composition_returns_send_observe_and_completed_test() {
  let owner =
    runtime.PreparedNetworkOwner(
      fn(_) { Ok(runtime.Ready(attempt_input())) },
      fn(_) { Ok(outcome(True)) },
    )
  let provider =
    runtime.Provider(
      function(composition_plan.HttpRequestResponse).reference,
      runtime.PreparedHttp(owner),
    )
  let assert Ok(runtime.Pending(sent, runtime.Send(command))) =
    runtime.start_composition(
      invocation_checked(composition_plan.HttpRequestResponse),
      [provider],
      [],
      network.empty_state(),
    )
  let handle = network.ExecutionHandle("handle")
  let assert Ok(runtime.Pending(started, runtime.Observe(observed))) =
    runtime.resume(
      sent,
      runtime.Start(network.StartedObservation(attempt_input().attempt, handle)),
    )
  assert observed == network.StartedAttempt(command.prepared, handle)
  let effect =
    network.EffectOccurred(network.EffectWitness(
      attempt_input().attempt,
      network.Adapter,
      network.OpaqueEvidence("response"),
    ))
  let delivered =
    network.Delivered(
      0,
      network.ResponseObservation(
        attempt_input().attempt,
        handle,
        network.NoSource,
        network.RawHttpResponse(200, [], <<>>),
        network.WireObserved,
        effect,
      ),
    )
  let assert Ok(runtime.Completed(runtime.Success(outputs), _)) =
    runtime.resume(started, runtime.Host(delivered))
  assert outputs == [#(composition_plan.GoalPortId("goal"), present(True))]
}

pub fn prepared_http_completion_emits_no_network_instruction_test() {
  let owner =
    runtime.PreparedNetworkOwner(
      fn(_) { Ok(runtime.CompletedOutcome(outcome(True))) },
      fn(_) { Error(runtime.InvalidPlan("unused")) },
    )
  let provider =
    runtime.Provider(
      function(composition_plan.HttpRequestResponse).reference,
      runtime.PreparedHttp(owner),
    )
  let assert Ok(runtime.Completed(runtime.Success(outputs), state)) =
    runtime.start_composition(
      invocation_checked(composition_plan.HttpRequestResponse),
      [provider],
      [],
      network.empty_state(),
    )
  assert outputs == [#(composition_plan.GoalPortId("goal"), present(True))]
  assert state == network.empty_state()
}

pub fn provider_failures_match_execution_failure_test() {
  let checked = invocation_checked(composition_plan.PureFunction)
  let assert Error(runtime.RunFailure(runtime.ProviderCoverage(_), _)) =
    runtime.start_composition(checked, [], [], network.empty_state())
  let http =
    runtime.Provider(
      function(composition_plan.PureFunction).reference,
      runtime.PreparedHttp(
        runtime.PreparedNetworkOwner(
          fn(_) { Ok(runtime.Ready(attempt_input())) },
          fn(_) { Ok(outcome(False)) },
        ),
      ),
    )
  let assert Error(runtime.RunFailure(runtime.ProviderEffect(_), _)) =
    runtime.start_composition(checked, [http], [], network.empty_state())
  let wrong_reference =
    runtime.Provider(
      composition_plan.FunctionRef("other", "1", "digest"),
      runtime.Pure(fn(_) { Ok(outcome(False)) }),
    )
  let assert Error(runtime.RunFailure(runtime.MissingProvider(_), _)) =
    runtime.start_composition(
      checked,
      [wrong_reference],
      [],
      network.empty_state(),
    )
}

pub fn missing_and_duplicate_arguments_match_execution_failure_test() {
  let checked = argument_checked()
  let assert Error(runtime.RunFailure(runtime.MissingArgument(_), _)) =
    runtime.start_composition(checked, [], [], network.empty_state())
  let argument = #(composition_plan.InputId("input"), present(False))
  let assert Error(runtime.RunFailure(runtime.ArgumentCoverage(_), _)) =
    runtime.start_composition(
      checked,
      [],
      [argument, argument],
      network.empty_state(),
    )
}

pub fn output_failures_match_execution_failure_test() {
  let checked = invocation_checked(composition_plan.PureFunction)
  let missing =
    runtime.Provider(
      function(composition_plan.PureFunction).reference,
      runtime.Pure(fn(_) {
        Ok(runtime.OutcomeValues(composition_plan.OutcomeId("done"), []))
      }),
    )
  let assert Error(runtime.RunFailure(
    runtime.InvalidPlan("output port coverage"),
    _,
  )) = runtime.start_composition(checked, [missing], [], network.empty_state())
  let invalid =
    runtime.Provider(
      function(composition_plan.PureFunction).reference,
      runtime.Pure(fn(_) {
        Ok(
          runtime.OutcomeValues(composition_plan.OutcomeId("done"), [
            #(
              composition_plan.PortId("value"),
              types.Present(json.JsonValueStr("wrong")),
            ),
          ]),
        )
      }),
    )
  let assert Error(runtime.RunFailure(runtime.Value(_), _)) =
    runtime.start_composition(checked, [invalid], [], network.empty_state())
  let undeclared =
    runtime.Provider(
      function(composition_plan.PureFunction).reference,
      runtime.Pure(fn(_) {
        Ok(runtime.OutcomeValues(composition_plan.OutcomeId("other"), []))
      }),
    )
  let assert Error(runtime.RunFailure(runtime.InvalidOutcome(_, _), _)) =
    runtime.start_composition(checked, [undeclared], [], network.empty_state())
}

pub fn guard_follows_the_checked_plan_test() {
  let assert Ok(runtime.Completed(runtime.Success(outputs), _)) =
    runtime.start_composition(guard_checked(), [], [], network.empty_state())
  assert outputs == [#(composition_plan.GoalPortId("goal"), present(False))]
}

pub fn variant_guard_uses_the_selected_otherwise_branch_test() {
  let value =
    types.Present(json.JsonValueObj([#("kind", json.JsonValueStr("other"))]))
  let assert Ok(runtime.Completed(runtime.Success(outputs), _)) =
    runtime.start_composition(variant_checked(), [], [], network.empty_state())
  assert outputs == [#(composition_plan.GoalPortId("goal"), value)]
}

pub fn declared_failure_follows_the_checked_plan_test() {
  let provider =
    runtime.Provider(
      composition_plan.FunctionRef("provider", "1", "digest"),
      runtime.Pure(fn(_) {
        Ok(
          runtime.OutcomeValues(composition_plan.OutcomeId("failed"), [
            #(composition_plan.PortId("value"), present(True)),
          ]),
        )
      }),
    )
  let assert Ok(runtime.Completed(runtime.Failure(embedding, value), _)) =
    runtime.start_composition(
      declared_failure_checked(),
      [provider],
      [],
      network.empty_state(),
    )
  assert embedding == composition_plan.FailureEmbeddingId("failure")
  assert value == present(True)
}

pub fn resource_bindings_and_final_resource_checks_follow_the_plan_test() {
  let provider =
    runtime.Provider(
      composition_plan.FunctionRef("resource-provider", "1", "digest"),
      runtime.Pure(fn(_) {
        Ok(runtime.OutcomeValues(composition_plan.OutcomeId("done"), []))
      }),
    )
  let assert Ok(runtime.Completed(runtime.Success(outputs), _)) =
    runtime.start_composition(
      resource_checked(),
      [provider],
      [],
      network.empty_state(),
    )
  assert outputs == [#(composition_plan.GoalPortId("goal"), present(False))]
}

pub fn resume_rejects_wrong_observation_kind_test() {
  let provider =
    runtime.Provider(
      function(composition_plan.HttpRequestResponse).reference,
      runtime.PreparedHttp(
        runtime.PreparedNetworkOwner(
          fn(_) { Ok(runtime.Ready(attempt_input())) },
          fn(_) { Ok(outcome(False)) },
        ),
      ),
    )
  let assert Ok(runtime.Pending(pending, runtime.Send(_))) =
    runtime.start_composition(
      invocation_checked(composition_plan.HttpRequestResponse),
      [provider],
      [],
      network.empty_state(),
    )
  let assert Error(runtime.RunFailure(
    runtime.InvalidPlan("network observation kind mismatch"),
    _,
  )) =
    runtime.resume(
      pending,
      runtime.Host(network.Pending(
        attempt_input().attempt,
        network.ExecutionHandle("handle"),
      )),
    )
}

pub fn pending_observations_preserve_the_observe_instruction_test() {
  let input = attempt_input()
  let provider =
    runtime.Provider(
      function(composition_plan.HttpRequestResponse).reference,
      runtime.PreparedHttp(
        runtime.PreparedNetworkOwner(fn(_) { Ok(runtime.Ready(input)) }, fn(_) {
          Ok(outcome(False))
        }),
      ),
    )
  let assert Ok(runtime.Pending(issued, runtime.Send(_))) =
    runtime.start_composition(
      invocation_checked(composition_plan.HttpRequestResponse),
      [provider],
      [],
      network.empty_state(),
    )
  let handle = network.ExecutionHandle("handle")
  let assert Ok(runtime.Pending(started, runtime.Observe(observed))) =
    runtime.resume(
      issued,
      runtime.Start(network.StartedObservation(input.attempt, handle)),
    )
  let assert Ok(runtime.Pending(pending, runtime.Observe(reobserved))) =
    runtime.resume(
      started,
      runtime.Host(network.Pending(input.attempt, handle)),
    )
  assert reobserved == observed
  assert runtime.execution_network(pending)
    == runtime.execution_network(started)
}
