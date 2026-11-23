// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import neco_quotient_retention as retention
import necoherence/network_effect as effect
import necoherence/request_progression as progression
import necoherence_http_adapter as http_adapter

type Peer

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_start")
fn peer_start(response: BitArray, mode: String) -> #(Peer, Int)

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_release")
fn peer_release(peer: Peer) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_count")
fn peer_count(peer: Peer) -> Int

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

@external(erlang, "necoherence_http_release_probe_ffi", "late_worker_result")
fn late_worker_result(
  execution: http_adapter.Execution,
  observation: effect.AdapterObservation,
) -> Nil

type Dispatched {
  Dispatched(
    state: effect.NetworkState,
    execution: http_adapter.Execution,
    attempt: effect.AttemptIdentity,
  )
}

fn cancel_with(
  dispatched: Dispatched,
  capability: effect.CancellationCapability,
) -> Result(effect.HostObservation, http_adapter.UnknownExecution) {
  http_adapter.cancel(
    dispatched.execution,
    effect.CancelCommand(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
      capability,
    ),
  )
}

fn ok_response() -> BitArray {
  http_response(200, [], <<111, 107>>)
}

fn target(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/release"
}

fn cancelling_ports(
  capability: effect.CancellationCapability,
) -> http_adapter.AdapterPorts {
  http_adapter.AdapterPorts(
    http_adapter.MonotonicClockPort(
      http_adapter.default_ports().clock.capability,
      fn() {
        Ok(effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0))
      },
      fn(_) { None },
    ),
    http_adapter.CancellationPort(capability, fn(_) { Ok(Nil) }),
  )
}

fn dispatch(
  port: Int,
  revision: Int,
  cancellation: Option(effect.CancellationCapability),
  ports: http_adapter.AdapterPorts,
) -> Dispatched {
  let input =
    effect.AttemptInput(
      effect.AttemptIdentity(
        progression.RequestIdentity("release", "loopback", revision),
        0,
      ),
      effect.HttpWireInstruction("POST", target(port), [], <<>>),
      None,
      effect.HostConfiguration(256, 256, cancellation, None),
    )
  let assert effect.PreparedResult(prepared_state, prepared) =
    effect.prepare(effect.empty_state(), input)
  let assert effect.CommandReady(command_state, command) =
    effect.send_command(prepared_state, prepared)
  let assert http_adapter.Started(execution) =
    http_adapter.start_with_ports(command, ports)
  let assert effect.StartedStep(started_state, _) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  Dispatched(started_state, execution, input.attempt)
}

fn await_delivered(
  execution: http_adapter.Execution,
  remaining: Int,
) -> effect.HostObservation {
  let assert Ok(observation) = http_adapter.observe(execution)
  case observation, remaining > 0 {
    effect.Pending(_, _), True -> {
      process.sleep(5)
      await_delivered(execution, remaining - 1)
    }
    _, _ -> observation
  }
}

fn await_peer_count(peer: Peer, remaining: Int) -> Int {
  let count = peer_count(peer)
  case count == 0 && remaining > 0 {
    True -> {
      process.sleep(5)
      await_peer_count(peer, remaining - 1)
    }
    False -> count
  }
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

fn effect_outstanding(
  decision: effect.HostRecordDecision,
  attempt: effect.AttemptIdentity,
) -> Bool {
  case decision {
    retention.Retain(reasons) ->
      list.contains(reasons, retention.OutstandingEffect(attempt))
    _ -> False
  }
}

fn release_when_idle(
  state: effect.NetworkState,
  dispatched: Dispatched,
  remaining: Int,
) -> effect.HostRecordDecision {
  let decision = http_adapter.release(state, dispatched.execution)
  case effect_outstanding(decision, dispatched.attempt) && remaining > 0 {
    True -> {
      process.sleep(5)
      release_when_idle(state, dispatched, remaining - 1)
    }
    False -> decision
  }
}

fn drain(total: Int, unreleased: Int) -> Int {
  let before = queue_process_count()
  list.each(
    int.range(from: 0, to: total, with: [], run: fn(all, index) {
      [index, ..all]
    })
      |> list.reverse,
    fn(index) {
      let #(peer, port) = peer_start(ok_response(), "respond")
      let dispatched = dispatch(port, index, None, http_adapter.default_ports())
      let delivered = await_delivered(dispatched.execution, 400)
      let assert effect.TerminalStep(terminal_state, _) =
        effect.observe(dispatched.state, delivered)
      case index >= unreleased {
        True -> {
          let assert retention.Dematerialize(_) =
            release_when_idle(terminal_state, dispatched, 400)
          Nil
        }
        False -> Nil
      }
      peer_stop(peer)
    },
  )
  await_queue_count(before + unreleased, 400) - before
}

pub fn released_records_leave_no_queue_process_test() {
  assert drain(500, 0) == 0
}

pub fn unreleased_records_keep_their_queue_process_test() {
  assert drain(40, 3) == 3
}

pub fn future_use_is_the_only_reason_before_terminal_test() {
  let #(peer, port) = peer_start(ok_response(), "respond")
  let dispatched = dispatch(port, 0, None, http_adapter.default_ports())
  let assert effect.Delivered(_, _) = await_delivered(dispatched.execution, 400)
  assert release_when_idle(dispatched.state, dispatched, 400)
    == retention.Retain([retention.FutureUse(dispatched.attempt)])
  assert http_adapter.observe(dispatched.execution)
    == Ok(effect.Pending(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
    ))
  peer_stop(peer)
}

pub fn released_handles_return_a_typed_failure_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("release-cancel"))
  let #(peer, port) = peer_start(ok_response(), "respond")
  let dispatched =
    dispatch(port, 0, Some(capability), cancelling_ports(capability))
  let delivered = await_delivered(dispatched.execution, 400)
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, delivered)
  let assert retention.Dematerialize(_) =
    release_when_idle(terminal_state, dispatched, 400)
  let unknown =
    Error(
      http_adapter.UnknownExecution(http_adapter.handle(dispatched.execution)),
    )
  assert http_adapter.observe(dispatched.execution) == unknown
  assert cancel_with(dispatched, capability) == unknown
  assert http_adapter.close(dispatched.execution) == unknown
  peer_stop(peer)
}

pub fn cancel_and_close_follow_delivery_order_after_the_queue_drains_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("race-cancel"))

  let #(first_peer, first_port) = peer_start(ok_response(), "delay")
  let first =
    dispatch(first_port, 0, Some(capability), cancelling_ports(capability))
  assert await_peer_count(first_peer, 40) == 1
  let assert Ok(cancel_observation) = cancel_with(first, capability)
  let assert effect.Delivered(0, effect.CancellationObservation(_, _, _, _)) =
    cancel_observation
  let assert effect.TerminalStep(_cancelled_state, _) =
    effect.observe(first.state, cancel_observation)
  peer_release(first_peer)
  process.sleep(300)
  assert http_adapter.observe(first.execution)
    == Ok(effect.Pending(first.attempt, http_adapter.handle(first.execution)))
  peer_stop(first_peer)

  let #(second_peer, second_port) = peer_start(ok_response(), "respond")
  let second =
    dispatch(second_port, 1, Some(capability), cancelling_ports(capability))
  let response = await_delivered(second.execution, 400)
  let assert effect.Delivered(0, effect.ResponseObservation(_, _, _, _, _, _)) =
    response
  let assert effect.TerminalStep(response_state, _) =
    effect.observe(second.state, response)
  let assert Ok(late_cancel) = cancel_with(second, capability)
  let assert effect.Delivered(1, effect.CancellationObservation(_, _, _, _)) =
    late_cancel
  let assert effect.LateStep(_, _, _) =
    effect.observe(response_state, late_cancel)
  peer_stop(second_peer)

  let #(third_peer, third_port) = peer_start(ok_response(), "delay")
  let third = dispatch(third_port, 2, None, http_adapter.default_ports())
  assert await_peer_count(third_peer, 40) == 1
  let assert Ok(closed) = http_adapter.close(third.execution)
  let assert effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(_, _, _, effect.HostClosed),
      _,
    ),
  ) = closed
  peer_release(third_peer)
  process.sleep(300)
  assert http_adapter.observe(third.execution)
    == Ok(effect.Pending(third.attempt, http_adapter.handle(third.execution)))
  peer_stop(third_peer)
}

fn dispatch_with_deadline(
  port: Int,
  revision: Int,
  limit: Int,
  ports: http_adapter.AdapterPorts,
) -> Dispatched {
  let clock_capability = http_adapter.default_ports().clock.capability
  let input =
    effect.AttemptInput(
      effect.AttemptIdentity(
        progression.RequestIdentity("release", "loopback", revision),
        0,
      ),
      effect.HttpWireInstruction("POST", target(port), [], <<>>),
      Some(effect.Deadline(effect.ClockBasis("system"), limit, clock_capability)),
      effect.HostConfiguration(256, 256, None, Some(clock_capability)),
    )
  let assert effect.PreparedResult(prepared_state, prepared) =
    effect.prepare(effect.empty_state(), input)
  let assert effect.CommandReady(command_state, command) =
    effect.send_command(prepared_state, prepared)
  let assert http_adapter.Started(execution) =
    http_adapter.start_with_ports(command, ports)
  let assert effect.StartedStep(started_state, _) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  Dispatched(started_state, execution, input.attempt)
}

fn assert_worker_ended_without_release(
  dispatched: Dispatched,
  terminal_state: effect.NetworkState,
  before: Int,
) -> Nil {
  assert release_when_idle(dispatched.state, dispatched, 400)
    == retention.Retain([retention.FutureUse(dispatched.attempt)])
  assert http_adapter.observe(dispatched.execution)
    == Ok(effect.Pending(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
    ))
  let assert retention.Dematerialize(_) =
    release_when_idle(terminal_state, dispatched, 400)
  assert await_queue_count(before, 400) == before
  Nil
}

pub fn a_deadline_ends_the_worker_without_releasing_the_peer_test() {
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let ports = http_adapter.default_ports()
  let assert Ok(now) = ports.clock.observe()
  let dispatched = dispatch_with_deadline(port, 10, now.value + 300, ports)
  assert await_peer_count(peer, 40) == 1
  let delivered = await_delivered(dispatched.execution, 400)
  let assert effect.Delivered(0, effect.DeadlineObservation(_, _, _, _, _, _)) =
    delivered
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, delivered)
  assert_worker_ended_without_release(dispatched, terminal_state, before)
  peer_stop(peer)
}

pub fn an_accepted_cancellation_ends_the_worker_without_releasing_the_peer_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("interrupt-cancel"))
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let dispatched =
    dispatch(port, 11, Some(capability), cancelling_ports(capability))
  assert await_peer_count(peer, 40) == 1
  let assert Ok(cancelled) = cancel_with(dispatched, capability)
  let assert effect.Delivered(0, effect.CancellationObservation(_, _, _, _)) =
    cancelled
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, cancelled)
  assert_worker_ended_without_release(dispatched, terminal_state, before)
  peer_stop(peer)
}

pub fn close_ends_the_worker_without_releasing_the_peer_test() {
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let dispatched = dispatch(port, 12, None, http_adapter.default_ports())
  assert await_peer_count(peer, 40) == 1
  let assert Ok(closed) = http_adapter.close(dispatched.execution)
  let assert effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(_, _, _, effect.HostClosed),
      _,
    ),
  ) = closed
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, closed)
  assert_worker_ended_without_release(dispatched, terminal_state, before)
  peer_stop(peer)
}

fn assert_worker_ended_and_no_late_observation_after_the_peer_release(
  dispatched: Dispatched,
  terminal_state: effect.NetworkState,
  before: Int,
  peer: Peer,
) -> Nil {
  assert release_when_idle(dispatched.state, dispatched, 400)
    == retention.Retain([retention.FutureUse(dispatched.attempt)])
  peer_release(peer)
  process.sleep(300)
  assert http_adapter.observe(dispatched.execution)
    == Ok(effect.Pending(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
    ))
  let assert retention.Dematerialize(_) =
    release_when_idle(terminal_state, dispatched, 400)
  assert await_queue_count(before, 400) == before
  Nil
}

pub fn a_rejected_cancellation_ends_the_worker_without_releasing_the_peer_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("interrupt-reject"))
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.default_ports().clock,
      http_adapter.CancellationPort(capability, fn(_) {
        Error(effect.CancellationRejected)
      }),
    )
  let dispatched = dispatch(port, 13, Some(capability), ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(rejected) = cancel_with(dispatched, capability)
  let assert effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(
        _,
        effect.Cancel,
        _,
        effect.CancellationRejected,
      ),
      effect.Unknown(effect.HostFailure),
    ),
  ) = rejected
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, rejected)
  assert_worker_ended_and_no_late_observation_after_the_peer_release(
    dispatched,
    terminal_state,
    before,
    peer,
  )
  peer_stop(peer)
}

pub fn a_cancellation_port_failure_ends_the_worker_without_releasing_the_peer_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence(
      "interrupt-port-failure",
    ))
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.default_ports().clock,
      http_adapter.CancellationPort(capability, fn(_) {
        panic as "cancellation port failure"
      }),
    )
  let dispatched = dispatch(port, 17, Some(capability), ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(failed) = cancel_with(dispatched, capability)
  let assert effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(_, effect.Cancel, _, effect.HostRuntimeFailure),
      effect.Unknown(effect.HostFailure),
    ),
  ) = failed
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, failed)
  assert_worker_ended_and_no_late_observation_after_the_peer_release(
    dispatched,
    terminal_state,
    before,
    peer,
  )
  peer_stop(peer)
}

pub fn a_clock_failure_seen_by_observe_ends_the_worker_without_releasing_the_peer_test() {
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let system = http_adapter.default_ports()
  let assert Ok(start) = system.clock.observe()
  let trigger = start.value + 400
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        system.clock.capability,
        fn() {
          let assert Ok(observed) = system.clock.observe()
          case observed.value >= trigger {
            True -> panic as "clock failure"
            False -> Ok(observed)
          }
        },
        fn(_) { None },
      ),
      system.cancellation,
    )
  let dispatched =
    dispatch_with_deadline(port, 18, start.value + 600_000, ports)
  assert await_peer_count(peer, 40) == 1
  process.sleep(500)
  let assert Ok(failed) = http_adapter.observe(dispatched.execution)
  let assert effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(
        _,
        effect.DeadlineStage,
        _,
        effect.HostRuntimeFailure,
      ),
      effect.Unknown(effect.HostFailure),
    ),
  ) = failed
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, failed)
  assert_worker_ended_and_no_late_observation_after_the_peer_release(
    dispatched,
    terminal_state,
    before,
    peer,
  )
  peer_stop(peer)
}

fn rejecting_ports(
  capability: effect.CancellationCapability,
) -> http_adapter.AdapterPorts {
  http_adapter.AdapterPorts(
    http_adapter.default_ports().clock,
    http_adapter.CancellationPort(capability, fn(_) {
      Error(effect.CancellationRejected)
    }),
  )
}

fn rejected_cancel(
  dispatched: Dispatched,
  capability: effect.CancellationCapability,
) -> effect.HostObservation {
  let assert Ok(rejected) = cancel_with(dispatched, capability)
  let assert effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(
        _,
        effect.Cancel,
        _,
        effect.CancellationRejected,
      ),
      _,
    ),
  ) = rejected
  rejected
}

pub fn a_worker_result_after_an_adapter_observation_is_not_queued_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("late-result"))
  let #(peer, port) = peer_start(ok_response(), "delay")
  let dispatched =
    dispatch(port, 19, Some(capability), rejecting_ports(capability))
  assert await_peer_count(peer, 40) == 1
  let _ = rejected_cancel(dispatched, capability)
  late_worker_result(
    dispatched.execution,
    effect.ResponseObservation(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
      effect.NoSource,
      effect.RawHttpResponse(200, [], <<>>),
      effect.LibraryNormalized,
      effect.Unknown(effect.ProtocolWitnessMissing),
    ),
  )
  process.sleep(100)
  assert http_adapter.observe(dispatched.execution)
    == Ok(effect.Pending(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
    ))
  peer_release(peer)
  peer_stop(peer)
}

pub fn release_after_the_terminal_observation_removes_the_record_within_the_limit_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("release-reject"))
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let dispatched =
    dispatch(port, 14, Some(capability), rejecting_ports(capability))
  assert await_peer_count(peer, 40) == 1
  assert queue_process_count() == before + 1
  let rejected = rejected_cancel(dispatched, capability)
  let assert effect.TerminalStep(terminal_state, _) =
    effect.observe(dispatched.state, rejected)
  case http_adapter.release(terminal_state, dispatched.execution) {
    retention.Retain(_) -> Nil
    retention.Dematerialize(_) -> Nil
    retention.Rejected(_) -> panic as "release rejected"
  }
  assert await_queue_count(before, 400) == before
  peer_release(peer)
  peer_stop(peer)
}

pub fn release_with_a_state_lacking_the_record_does_not_interrupt_the_worker_test() {
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let dispatched = dispatch(port, 16, None, http_adapter.default_ports())
  assert await_peer_count(peer, 40) == 1
  let assert retention.Retain(_) =
    http_adapter.release(effect.empty_state(), dispatched.execution)
  process.sleep(100)
  assert queue_process_count() == before + 1
  peer_release(peer)
  let delivered = await_delivered(dispatched.execution, 400)
  let assert effect.Delivered(0, effect.ResponseObservation(_, _, _, _, _, _)) =
    delivered
  let assert effect.TerminalStep(_, _) =
    effect.observe(dispatched.state, delivered)
  peer_stop(peer)
}

pub fn release_while_the_core_still_awaits_keeps_the_record_and_no_late_observation_follows_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("release-awaits"))
  let before = queue_process_count()
  let #(peer, port) = peer_start(ok_response(), "delay")
  let dispatched =
    dispatch(port, 15, Some(capability), rejecting_ports(capability))
  assert await_peer_count(peer, 40) == 1
  let _ = rejected_cancel(dispatched, capability)
  assert release_when_idle(dispatched.state, dispatched, 400)
    == retention.Retain([retention.FutureUse(dispatched.attempt)])
  process.sleep(100)
  assert queue_process_count() == before + 1
  peer_release(peer)
  process.sleep(300)
  assert http_adapter.observe(dispatched.execution)
    == Ok(effect.Pending(
      dispatched.attempt,
      http_adapter.handle(dispatched.execution),
    ))
  peer_stop(peer)
}
