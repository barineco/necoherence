// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import necoherence/composition_input
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/inclusion
import necoherence/network_effect as network
import necoherence/request_progression as progression
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence_http_adapter as http_adapter

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

type Peer

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_start")
fn peer_start(response: BitArray, mode: String) -> #(Peer, Int)

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_release")
fn peer_release(peer: Peer) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_stop")
fn peer_stop(peer: Peer) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "http_response")
fn http_response(
  status: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> BitArray

@external(erlang, "necoherence_http_release_probe_ffi", "queue_process_count")
fn queue_process_count() -> Int

type Counter

@external(erlang, "necoherence_http_drive_probe_ffi", "count_start")
fn count_start() -> Counter

@external(erlang, "necoherence_http_drive_probe_ffi", "count_stop")
fn count_stop(counter: Counter) -> Int

const repeats = 100

fn attempt_input(
  target: String,
  deadline: Option(network.Deadline),
) -> network.AttemptInput {
  let identity = progression.RequestIdentity("semantic", "http", 1)
  network.AttemptInput(
    network.AttemptIdentity(identity, 0),
    network.HttpWireInstruction("GET", target, [], <<>>),
    deadline,
    network.HostConfiguration(
      8,
      8,
      None,
      option.map(deadline, fn(deadline) { deadline.capability }),
    ),
  )
}

fn outcome(value: Bool) -> runtime.OutcomeValues {
  runtime.OutcomeValues(composition_plan.OutcomeId("done"), [
    #(composition_plan.PortId("value"), present(value)),
  ])
}

fn provider(
  target: String,
  deadline: Option(network.Deadline),
) -> runtime.Provider {
  let owner =
    runtime.PreparedNetworkOwner(
      fn(_) { Ok(runtime.Ready(attempt_input(target, deadline))) },
      fn(_) { Ok(outcome(True)) },
    )
  runtime.Provider(
    function(composition_plan.HttpRequestResponse).reference,
    runtime.PreparedHttp(owner),
  )
}

fn first(
  checked: composition_plan.CheckedComposition,
  target: String,
) -> runtime.Progress {
  first_with(checked, target, None)
}

fn first_with(
  checked: composition_plan.CheckedComposition,
  target: String,
  deadline: Option(network.Deadline),
) -> runtime.Progress {
  let assert Ok(progress) =
    runtime.start_composition(
      checked,
      [provider(target, deadline)],
      [],
      network.empty_state(),
    )
  progress
}

fn target(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/drive"
}

fn ok_response() -> BitArray {
  http_response(200, [], <<111, 107>>)
}

fn await_queue_count(expected: Int, remaining: Int) -> Int {
  let count = queue_process_count()
  case count != expected && remaining > 0 {
    True -> {
      process.sleep(5)
      await_queue_count(expected, remaining - 1)
    }
    False -> count
  }
}

fn manual(
  progress: runtime.Progress,
  executions: List(http_adapter.Execution),
) -> runtime.ExecutionResult {
  case progress {
    runtime.Completed(result, _) -> result
    runtime.Pending(pending, runtime.Send(command)) -> {
      let assert http_adapter.Started(execution) = http_adapter.start(command)
      let assert Ok(next) =
        runtime.resume(
          pending,
          runtime.Start(network.StartedObservation(
            command.prepared.input.attempt,
            http_adapter.handle(execution),
          )),
        )
      manual(next, [execution, ..executions])
    }
    runtime.Pending(pending, runtime.Observe(_)) -> {
      let assert [execution, ..] = executions
      let assert Ok(next) =
        runtime.resume(pending, runtime.Host(manual_delivery(execution, 400)))
      manual(next, executions)
    }
  }
}

fn manual_delivery(
  execution: http_adapter.Execution,
  remaining: Int,
) -> network.HostObservation {
  let assert Ok(observation) = http_adapter.observe(execution)
  case observation, remaining > 0 {
    network.Pending(_, _), True -> {
      process.sleep(5)
      manual_delivery(execution, remaining - 1)
    }
    _, _ -> observation
  }
}

fn drive_once(
  checked: composition_plan.CheckedComposition,
) -> runtime.ExecutionResult {
  let #(peer, port) = peer_start(ok_response(), "respond")
  let assert Ok(http_adapter.Driven(result, retained)) =
    http_adapter.drive(
      http_adapter.default_ports(),
      first(checked, target(port)),
    )
  assert retained == []
  peer_stop(peer)
  result
}

fn drive_times(
  checked: composition_plan.CheckedComposition,
  remaining: Int,
  last: Option(runtime.ExecutionResult),
) -> Option(runtime.ExecutionResult) {
  case remaining > 0 {
    True -> drive_times(checked, remaining - 1, Some(drive_once(checked)))
    False -> last
  }
}

pub fn drive_alone_leaves_no_queue_process_and_matches_the_manual_loop_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let before = queue_process_count()
  let assert Some(driven) = drive_times(checked, repeats, None)
  assert await_queue_count(before, 400) == before
  let #(peer, port) = peer_start(ok_response(), "respond")
  let expected = manual(first(checked, target(port)), [])
  peer_stop(peer)
  assert driven == expected
  assert await_queue_count(before + 1, 400) == before + 1
}

fn observe_calls(
  checked: composition_plan.CheckedComposition,
  delay: Int,
) -> Int {
  let #(peer, port) = peer_start(ok_response(), "delay")
  let _releaser =
    process.spawn_unlinked(fn() {
      process.sleep(delay)
      peer_release(peer)
    })
  let counter = count_start()
  let assert Ok(http_adapter.Driven(_, retained)) =
    http_adapter.drive(
      http_adapter.default_ports(),
      first(checked, target(port)),
    )
  let calls = count_stop(counter)
  assert retained == []
  peer_stop(peer)
  calls
}

pub fn waiting_does_not_poll_at_a_fixed_interval_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let short = observe_calls(checked, 150)
  let long = observe_calls(checked, 300)
  assert short == long
  assert short <= 2
}

pub fn an_unknown_handle_is_the_drive_failure_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let assert runtime.Pending(sent, runtime.Send(command)) =
    first(checked, "http://127.0.0.1:1/drive")
  let handle = network.ExecutionHandle("never-started")
  let assert Ok(runtime.Pending(started, runtime.Observe(observed))) =
    runtime.resume(
      sent,
      runtime.Start(network.StartedObservation(
        command.prepared.input.attempt,
        handle,
      )),
    )
  assert observed.handle == handle
  let assert Error(http_adapter.DriveFailure(
    http_adapter.ExecutionGone(gone),
    [],
  )) =
    http_adapter.drive(
      http_adapter.default_ports(),
      runtime.Pending(started, runtime.Observe(observed)),
    )
  assert gone == handle
}

fn system_deadline(limit: Int) -> network.Deadline {
  let basis = network.ClockBasis("system")
  network.Deadline(basis, limit, http_adapter.default_ports().clock.capability)
}

type DeadlineDrive {
  WaitUnavailable(retained: Int)
  DeadlineTerminal(retained: Int)
  HostRuntimeTerminal(retained: Int)
  Succeeded(retained: Int)
  Otherwise
}

fn drive_deadline_with(
  ports: http_adapter.AdapterPorts,
  checked: composition_plan.CheckedComposition,
  target: String,
  limit: Int,
  within: Int,
) -> Result(DeadlineDrive, Nil) {
  let results = process.new_subject()
  let _runner =
    process.spawn_unlinked(fn() {
      let driven =
        http_adapter.drive(
          ports,
          first_with(checked, target, Some(system_deadline(limit))),
        )
      process.send(results, case driven {
        Ok(http_adapter.Driven(_, retained)) -> Succeeded(list.length(retained))
        Error(http_adapter.DriveFailure(
          http_adapter.DeadlineWaitUnavailable(_),
          retained,
        )) -> WaitUnavailable(list.length(retained))
        Error(http_adapter.DriveFailure(
          http_adapter.RunFailed(failure),
          retained,
        )) ->
          case failure.cause {
            runtime.NetworkTerminal(network.NetworkTerminal(
              network.DeadlineExceeded(_, _),
              _,
            )) -> DeadlineTerminal(list.length(retained))
            runtime.NetworkTerminal(network.NetworkTerminal(
              network.Failed(network.NetworkHostFailure(
                _,
                network.DeadlineStage,
                _,
                network.HostRuntimeFailure,
              )),
              _,
            )) -> HostRuntimeTerminal(list.length(retained))
            _ -> Otherwise
          }
        _ -> Otherwise
      })
    })
  process.receive(results, within)
}

fn drive_deadline_within(
  checked: composition_plan.CheckedComposition,
  target: String,
  limit: Int,
  within: Int,
) -> Result(DeadlineDrive, Nil) {
  drive_deadline_with(
    http_adapter.default_ports(),
    checked,
    target,
    limit,
    within,
  )
}

fn fixed_clock_ports() -> http_adapter.AdapterPorts {
  http_adapter.AdapterPorts(
    http_adapter.MonotonicClockPort(
      http_adapter.default_ports().clock.capability,
      fn() {
        Ok(network.MonotonicClockObservation(network.ClockBasis("system"), 0))
      },
      fn(_) { None },
    ),
    http_adapter.default_ports().cancellation,
  )
}

fn deadline_in(ports: http_adapter.AdapterPorts, millis: Int) -> Int {
  let assert Ok(now) = ports.clock.observe()
  now.value + millis
}

pub fn a_held_peer_ends_at_the_deadline_and_the_record_leaves_by_itself_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let ports = http_adapter.default_ports()
  let driven =
    drive_deadline_with(
      ports,
      checked,
      target(port),
      deadline_in(ports, 300),
      2000,
    )
  assert driven == Ok(DeadlineTerminal(0))
  assert await_queue_count(before, 400) == before
  peer_release(peer)
  peer_stop(peer)
}

pub fn a_response_before_the_default_clock_deadline_completes_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let #(peer, port) = peer_start(ok_response(), "delay")
  let _releaser =
    process.spawn_unlinked(fn() {
      process.sleep(100)
      peer_release(peer)
    })
  let ports = http_adapter.default_ports()
  let driven =
    drive_deadline_with(
      ports,
      checked,
      target(port),
      deadline_in(ports, 300),
      2000,
    )
  assert driven == Ok(Succeeded(0))
  peer_stop(peer)
}

pub fn a_deadline_the_clock_cannot_wait_for_is_the_typed_failure_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let #(peer, port) = peer_start(ok_response(), "delay")
  let driven =
    drive_deadline_with(fixed_clock_ports(), checked, target(port), 300, 1000)
  peer_release(peer)
  assert driven == Ok(WaitUnavailable(1))
  peer_stop(peer)
}

pub fn a_clock_until_exception_ends_the_drive_with_a_host_failure_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(..fixed_clock_ports().clock, until: fn(_) {
        panic as "until failure"
      }),
      http_adapter.default_ports().cancellation,
    )
  let driven = drive_deadline_with(ports, checked, target(port), 300, 2000)
  assert await_queue_count(before, 400) == before
  peer_release(peer)
  let assert Ok(HostRuntimeTerminal(_)) = driven
  peer_stop(peer)
}

pub fn a_deadline_already_reached_at_the_start_is_the_deadline_terminal_test() {
  let checked = invocation_checked(composition_plan.HttpRequestResponse)
  let #(peer, port) = peer_start(ok_response(), "delay")
  let driven = drive_deadline_within(checked, target(port), 0, 3000)
  peer_release(peer)
  let assert Ok(DeadlineTerminal(_)) = driven
  peer_stop(peer)
}
