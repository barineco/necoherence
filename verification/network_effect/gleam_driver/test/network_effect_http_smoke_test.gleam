// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/network_effect as effect
import necoherence/network_host as host
import necoherence/request_progression as progression
import necoherence_http_adapter as http_adapter

type Peer

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_start")
fn peer_start(response: BitArray, mode: String) -> #(Peer, Int)

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_release")
fn peer_release(peer: Peer) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_count")
fn peer_count(peer: Peer) -> Int

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_accepted")
fn peer_accepted(peer: Peer) -> Int

type Counter

@external(erlang, "necoherence_http_smoke_peer_ffi", "counter_new")
fn counter_new() -> Counter

@external(erlang, "necoherence_http_smoke_peer_ffi", "counter_next")
fn counter_next(counter: Counter) -> Int

@external(erlang, "necoherence_http_smoke_peer_ffi", "counter_get")
fn counter_get(counter: Counter) -> Int

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_request")
fn peer_request(peer: Peer) -> BitArray

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_stop")
fn peer_stop(peer: Peer) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_send_split_request")
fn peer_send_split_request(port: Int, body: BitArray, delay: Int) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "stop_http_runtime")
fn stop_http_runtime() -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "unused_port")
fn unused_port() -> Int

@external(erlang, "necoherence_http_smoke_peer_ffi", "bytes_to_binary")
fn bytes_to_binary(bytes: List(Int)) -> BitArray

@external(erlang, "necoherence_http_smoke_peer_ffi", "http_response")
fn http_response(
  status: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> BitArray

@external(erlang, "necoherence_http_smoke_peer_ffi", "binary_contains")
fn binary_contains(haystack: BitArray, needle: BitArray) -> Bool

@external(erlang, "necoherence_http_smoke_peer_ffi", "classify_fault")
fn classify_fault(
  stimulus: String,
  stage: effect.HostStage,
  cause: effect.HostTimeoutCause,
) -> effect.HostFailure

fn identity() -> effect.RequestIdentity {
  progression.RequestIdentity("smoke", "loopback", 0)
}

fn attempt(ordinal: Int) -> effect.AttemptIdentity {
  effect.AttemptIdentity(identity(), ordinal)
}

fn target(port: Int, path: String) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> path
}

fn configuration(
  response_limit: Int,
  cancellation: Option(effect.CancellationCapability),
  clock: Option(effect.MonotonicClockCapability),
) -> effect.HostConfiguration {
  effect.HostConfiguration(256, response_limit, cancellation, clock)
}

fn input_for(
  target_value: String,
  body: List(Int),
  response_limit: Int,
  cancellation: Option(effect.CancellationCapability),
  clock: Option(effect.MonotonicClockCapability),
  deadline: Option(effect.Deadline),
) -> effect.AttemptInput {
  effect.AttemptInput(
    attempt(0),
    effect.HttpWireInstruction(
      "POST",
      target_value,
      [effect.RawHeaderField("x-request", <<111, 107>>)],
      bytes_to_binary(body),
    ),
    deadline,
    configuration(response_limit, cancellation, clock),
  )
}

fn command_for(
  input: effect.AttemptInput,
) -> #(
  effect.NetworkState,
  effect.PreparedAttempt,
  effect.NetworkState,
  effect.SendCommand,
) {
  let assert effect.PreparedResult(prepared_state, prepared) =
    effect.prepare(effect.empty_state(), input)
  let assert effect.CommandReady(command_state, command) =
    effect.send_command(prepared_state, prepared)
  #(prepared_state, prepared, command_state, command)
}

fn direct_command(input: effect.AttemptInput) -> effect.SendCommand {
  effect.SendCommand(effect.PreparedAttempt(input, effect.Root))
}

fn started_execution(
  command: effect.SendCommand,
  ports: http_adapter.AdapterPorts,
) -> http_adapter.Execution {
  let assert http_adapter.Started(execution) =
    http_adapter.start_with_ports(command, ports)
  execution
}

fn cancel_with(
  execution: http_adapter.Execution,
  input: effect.AttemptInput,
  capability: effect.CancellationCapability,
) -> Result(effect.HostObservation, http_adapter.UnknownExecution) {
  http_adapter.cancel(
    execution,
    effect.CancelCommand(
      input.attempt,
      http_adapter.handle(execution),
      capability,
    ),
  )
}

fn await_observation(
  execution: http_adapter.Execution,
  remaining: Int,
) -> effect.HostObservation {
  let assert Ok(observation) = http_adapter.observe(execution)
  case observation, remaining > 0 {
    effect.Pending(_, _), True -> {
      process.sleep(5)
      await_observation(execution, remaining - 1)
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

fn response(
  status: Int,
  headers: List(#(String, String)),
  body: List(Int),
) -> BitArray {
  http_response(status, headers, bytes_to_binary(body))
}

fn response_from_observation(
  observation: effect.HostObservation,
) -> effect.RawHttpResponse {
  let assert effect.Delivered(_, effect.ResponseObservation(_, _, _, raw, _, _)) =
    observation
  raw
}

fn failure_from_observation(
  observation: effect.HostObservation,
) -> effect.NetworkHostFailure {
  let assert effect.Delivered(_, effect.FailureObservation(_, _, _, failure, _)) =
    observation
  failure
}

pub fn host_port_preserves_failed_start_test() {
  let input = input_for("ftp://example.test/", [], 0, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let port = http_adapter.host_port(http_adapter.default_ports())
  let assert host.StartFailed(failure, status) =
    host.start_with_ports(command, port)
  let assert http_adapter.StartFailed(expected_failure, expected_status) =
    http_adapter.start(command)
  assert failure == expected_failure
  assert status == expected_status
}

pub fn loopback_preserves_response_and_three_counts_test() {
  let response_bytes =
    response(
      201,
      [
        #("X-B", "two"),
        #("X-A", "first"),
        #("X-A", "second"),
        #("X-Utf", "é"),
      ],
      [0, 128, 255],
    )
  let #(peer, port) = peer_start(response_bytes, "delay")
  let input =
    input_for(target(port, "/causal"), [0, 128, 255], 16, None, None, None)
  let #(prepared_state, prepared, command_state, command) = command_for(input)
  let ledger_record_count = list.length(effect.network_attempts(prepared_state))
  let issued_command_count = 1
  let execution = started_execution(command, http_adapter.default_ports())
  assert http_adapter.handle(execution)
    == effect.ExecutionHandle("smoke:loopback:0:0")

  let assert Ok(pending) = http_adapter.observe(execution)
  assert pending
    == effect.Pending(input.attempt, http_adapter.handle(execution))
  let assert effect.StartedStep(started_state, started) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  assert effect.observe(started_state, pending)
    == effect.PendingStep(started_state, started)
  assert await_peer_count(peer, 40) == 1

  peer_release(peer)
  let delivered = await_observation(execution, 80)
  let assert effect.Delivered(
    0,
    effect.ResponseObservation(
      observed_attempt,
      observed_handle,
      effect.NoSource,
      raw,
      effect.LibraryNormalized,
      effect.Unknown(effect.ProtocolWitnessMissing),
    ),
  ) = delivered
  assert observed_attempt == input.attempt
  assert observed_handle == http_adapter.handle(execution)
  assert raw.status == 201
  assert raw.body == <<0, 128, 255>>
  let duplicate_headers =
    list.filter(raw.headers, fn(header) { header.name == "x-a" })
  assert list.length(duplicate_headers) == 2
  let assert Ok(utf_header) =
    list.find(raw.headers, fn(header) { header.name == "x-utf" })
  assert utf_header.value == <<195, 169>>
  let header_names = list.map(raw.headers, fn(header) { header.name })
  assert header_names == list.sort(header_names, string.compare)
  let assert effect.TerminalStep(terminal_state, settled) =
    effect.observe(started_state, delivered)
  assert settled.terminal.outcome
    == effect.Response(raw, effect.LibraryNormalized)
  assert list.length(effect.network_attempts(terminal_state)) == 1

  let request_bytes = peer_request(peer)
  assert binary_contains(request_bytes, bit_array.from_string("POST /causal"))
  assert binary_contains(request_bytes, bytes_to_binary([0, 128, 255]))
  let peer_received_count = peer_count(peer)
  assert ledger_record_count == 1
  assert issued_command_count == 1
  assert peer_received_count == 1
  assert peer_received_count <= issued_command_count
  peer_stop(peer)
}

pub fn post_with_three_headers_and_body_reaches_terminal_response_test() {
  repeat_post_with_three_headers(8)
}

fn repeat_post_with_three_headers(remaining: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let #(peer, port) =
        peer_start(
          response(200, [#("x-loopback", "ok")], [111, 107]),
          "respond",
        )
      let body = list.repeat(97, times: 16_384)
      let input =
        effect.AttemptInput(
          attempt(0),
          effect.HttpWireInstruction(
            "POST",
            target(port, "/v1/items"),
            [
              effect.RawHeaderField("content-type", <<
                97,
                112,
                112,
                108,
                105,
                99,
                97,
                116,
                105,
                111,
                110,
                47,
                106,
                115,
                111,
                110,
              >>),
              effect.RawHeaderField("x-api-key", <<116, 111, 107, 101, 110>>),
              effect.RawHeaderField("x-api-version", <<
                50,
                48,
                50,
                51,
                45,
                48,
                54,
                45,
                48,
                49,
              >>),
            ],
            bytes_to_binary(body),
          ),
          None,
          effect.HostConfiguration(list.length(body), 16, None, None),
        )
      let #(_, prepared, command_state, command) = command_for(input)
      let execution = started_execution(command, http_adapter.default_ports())
      let started_observation =
        effect.StartedObservation(input.attempt, http_adapter.handle(execution))
      let assert effect.StartedStep(started_state, _) =
        effect.observe_start(command_state, prepared, started_observation)
      let delivered = await_observation(execution, 240)
      let assert effect.TerminalStep(_, settled) =
        effect.observe(started_state, delivered)
      let assert effect.Response(raw, effect.LibraryNormalized) =
        settled.terminal.outcome
      assert raw.status == 200
      assert raw.body == <<111, 107>>
      assert peer_count(peer) == 1
      assert binary_contains(peer_request(peer), bytes_to_binary(body))
      peer_stop(peer)
      repeat_post_with_three_headers(remaining - 1)
    }
  }
}

pub fn loopback_waits_for_a_split_request_body_test() {
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "respond")
  let body = bytes_to_binary(list.repeat(98, times: 4096))
  peer_send_split_request(port, body, 150)
  assert peer_count(peer) == 1
  assert binary_contains(peer_request(peer), body)
  peer_stop(peer)
}

pub fn adapter_starts_required_otp_applications_test() {
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "respond")
  stop_http_runtime()
  let input =
    input_for(target(port, "/runtime-start"), [1, 2, 3], 8, None, None, None)
  let #(_, prepared, command_state, command) = command_for(input)
  let assert http_adapter.Started(execution) = http_adapter.start(command)
  let assert effect.StartedStep(started_state, _) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  let delivered = await_observation(execution, 120)
  let assert effect.TerminalStep(_, settled) =
    effect.observe(started_state, delivered)
  let assert effect.Response(raw, effect.LibraryNormalized) =
    settled.terminal.outcome
  assert raw.status == 200
  assert raw.body == <<111, 107>>
  assert peer_count(peer) == 1
  peer_stop(peer)
}

fn assert_raw_status(status: Int) {
  let #(peer, port) = peer_start(response(status, [], []), "respond")
  let input = input_for(target(port, "/status"), [], 8, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  let raw = execution |> await_observation(80) |> response_from_observation
  assert raw.status == status
  assert peer_count(peer) == 1
  peer_stop(peer)
}

pub fn non_success_statuses_remain_raw_test() {
  list.each([404, 429, 500], assert_raw_status)
}

pub fn cancellation_wins_and_no_response_is_delivered_after_it_test() {
  let #(peer, port) = peer_start(response(200, [], [114, 97, 119]), "delay")
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("cancel"))
  let input =
    input_for(target(port, "/cancel"), [], 16, Some(capability), None, None)
  let #(_, prepared, command_state, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        unused_clock(),
        fn() {
          Ok(effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0))
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(capability, fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  let assert effect.StartedStep(started_state, _) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  assert await_peer_count(peer, 40) == 1

  let assert Ok(cancelled) = cancel_with(execution, input, capability)
  let assert effect.Delivered(
    0,
    effect.CancellationObservation(
      _,
      _,
      effect.NoSource,
      effect.Unknown(effect.CancellationReason),
    ),
  ) = cancelled
  let assert effect.TerminalStep(cancelled_state, _) =
    effect.observe(started_state, cancelled)

  peer_release(peer)
  process.sleep(300)
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  assert effect.observe(cancelled_state, cancelled)
    == effect.DuplicateStep(cancelled_state, input.attempt, 0)
  assert list.length(effect.network_attempts(cancelled_state)) == 1
  peer_stop(peer)
}

pub fn deadline_is_observed_from_the_clock_test() {
  let basis = effect.ClockBasis("clock")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let deadline_input =
    input_for(
      target(unused_port(), "/deadline"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, deadline_command) = command_for(deadline_input)
  let deadline_ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() { Ok(effect.MonotonicClockObservation(basis, 5)) },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let deadline_execution = started_execution(deadline_command, deadline_ports)
  let assert effect.Delivered(
    0,
    effect.DeadlineObservation(
      _,
      _,
      _,
      observed_deadline,
      observed_at,
      effect.Unknown(effect.DeadlineReason),
    ),
  ) = await_observation(deadline_execution, 40)
  assert observed_deadline == deadline
  assert observed_at == effect.MonotonicClockObservation(basis, 5)
}

pub fn a_clock_below_the_limit_leaves_observe_pending_test() {
  let basis = effect.ClockBasis("clock-below")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability-below"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input =
    input_for(
      target(port, "/below"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() { Ok(effect.MonotonicClockObservation(basis, 4)) },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  peer_release(peer)
  peer_stop(peer)
}

pub fn a_clock_at_the_limit_from_the_start_sends_no_request_test() {
  let basis = effect.ClockBasis("clock-at-limit")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability-at-limit"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input =
    input_for(
      target(port, "/at-limit"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() { Ok(effect.MonotonicClockObservation(basis, 5)) },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  process.sleep(300)
  assert peer_accepted(peer) == 0
  let observed = http_adapter.observe(execution)
  assert case observed {
    Ok(effect.Delivered(_, effect.DeadlineObservation(_, _, _, _, _, _))) ->
      True
    _ -> False
  }
  assert peer_accepted(peer) == 0
  peer_release(peer)
  peer_stop(peer)
}

pub fn a_clock_with_another_basis_never_reaches_the_deadline_test() {
  let basis = effect.ClockBasis("clock-basis")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability-basis"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input =
    input_for(
      target(port, "/basis"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() {
          Ok(effect.MonotonicClockObservation(effect.ClockBasis("other"), 100))
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  peer_release(peer)
  peer_stop(peer)
}

pub fn a_clock_observe_exception_is_one_host_runtime_failure_test() {
  let basis = effect.ClockBasis("clock-raising")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability-raising"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input =
    input_for(
      target(port, "/raising"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, command) = command_for(input)
  let calls = counter_new()
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() {
          case counter_next(calls) {
            1 -> Ok(effect.MonotonicClockObservation(basis, 0))
            _ -> panic as "clock failure"
          }
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  assert counter_get(calls) == 1
  let assert Ok(effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(_, stage, _, cause),
      effect_status,
    ),
  )) = http_adapter.observe(execution)
  assert stage == effect.DeadlineStage
  assert cause == effect.HostRuntimeFailure
  assert effect_status == effect.Unknown(effect.HostFailure)
  assert counter_get(calls) == 2
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  assert counter_get(calls) == 2
  peer_release(peer)
  process.sleep(300)
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  assert counter_get(calls) == 2
  peer_stop(peer)
}

pub fn a_clock_observe_failure_value_is_one_deadline_stage_failure_test() {
  let basis = effect.ClockBasis("clock-failing-value")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability-failing-value"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input =
    input_for(
      target(port, "/failing-value"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, command) = command_for(input)
  let calls = counter_new()
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() {
          case counter_next(calls) {
            1 -> Ok(effect.MonotonicClockObservation(basis, 0))
            _ -> Error(effect.DeadlineControlUnavailable)
          }
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(effect.Delivered(
    0,
    effect.FailureObservation(
      _,
      _,
      _,
      effect.NetworkHostFailure(_, stage, _, cause),
      effect_status,
    ),
  )) = http_adapter.observe(execution)
  assert stage == effect.DeadlineStage
  assert cause == effect.DeadlineControlUnavailable
  assert effect_status == effect.Unknown(effect.HostFailure)
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  assert counter_get(calls) == 2
  peer_release(peer)
  peer_stop(peer)
}

pub fn deadline_already_reached_at_start_is_observed_once_test() {
  let basis = effect.ClockBasis("clock-once")
  let clock_capability =
    effect.MonotonicClockCapability(
      effect.OpaqueEvidence("clock-capability-once"),
      basis,
    )
  let deadline = effect.Deadline(basis, 5, clock_capability)
  let deadline_input =
    input_for(
      target(unused_port(), "/deadline-once"),
      [],
      8,
      None,
      Some(clock_capability),
      Some(deadline),
    )
  let #(_, _, _, deadline_command) = command_for(deadline_input)
  let deadline_ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock_capability,
        fn() { Ok(effect.MonotonicClockObservation(basis, 5)) },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(deadline_command, deadline_ports)
  let first = http_adapter.observe(execution)
  process.sleep(200)
  let second = http_adapter.observe(execution)
  let third = http_adapter.observe(execution)
  let deadlines =
    list.filter([first, second, third], fn(observed) {
      case observed {
        Ok(effect.Delivered(_, effect.DeadlineObservation(_, _, _, _, _, _))) ->
          True
        _ -> False
      }
    })
  assert list.length(deadlines) == 1
}

pub fn response_delayed_three_seconds_without_deadline_is_observed_test() {
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input = input_for(target(port, "/slow"), [], 8, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  assert await_peer_count(peer, 40) == 1
  process.sleep(3000)
  peer_release(peer)
  let raw = execution |> await_observation(200) |> response_from_observation
  assert raw.status == 200
  assert raw.body == <<111, 107>>
  peer_stop(peer)
}

pub fn retry_and_forged_tokens_do_not_dispatch_test() {
  let #(peer, port) = peer_start(response(200, [], []), "delay")
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("retry-cancel"))
  let input =
    input_for(target(port, "/retry"), [], 8, Some(capability), None, None)
  let #(prepared_state, prepared, command_state, command) = command_for(input)
  let forged_input =
    effect.AttemptInput(
      prepared.input.attempt,
      effect.HttpWireInstruction("POST", target(port, "/forged"), [], <<>>),
      prepared.input.deadline,
      prepared.input.configuration,
    )
  let forged = effect.PreparedAttempt(forged_input, prepared.chain)
  let assert effect.CommandRejected(
    _,
    effect.AttemptTokenMismatch(_, effect.Instruction),
  ) = effect.send_command(prepared_state, forged)

  let ports =
    http_adapter.AdapterPorts(
      http_adapter.default_ports().clock,
      http_adapter.CancellationPort(capability, fn(_) { Ok(Nil) }),
    )
  let execution = started_execution(command, ports)
  let assert effect.StartedStep(started_state, started) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  let forged_started =
    effect.StartedAttempt(started.prepared, effect.ExecutionHandle("forged"))
  let assert effect.CommandRejected(_, effect.HandleMismatch(_, _)) =
    effect.cancel_command(started_state, forged_started)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(cancelled) = cancel_with(execution, input, capability)
  let assert effect.TerminalStep(settled_state, _) =
    effect.observe(started_state, cancelled)

  let authorization =
    effect.RetryAuthorization(
      input.attempt.logical,
      input.attempt,
      attempt(1),
      effect.OpaqueEvidence("retry"),
    )
  let request =
    effect.RetryRequest(
      effect.RetryAllowed(authorization),
      input.instruction,
      input.deadline,
      input.configuration,
    )
  let assert effect.PreparedResult(retried_state, retried) =
    effect.retry(settled_state, request)
  assert retried.chain == effect.RetryOf(authorization)
  assert list.length(effect.network_attempts(retried_state)) == 2
  let assert effect.PrepareRejected(_, effect.RetryNotPermitted(_)) =
    effect.retry(retried_state, request)
  let denied =
    effect.RetryRequest(
      effect.RetryDenied(
        input.attempt.logical,
        input.attempt,
        effect.OpaqueEvidence("denied"),
      ),
      input.instruction,
      input.deadline,
      input.configuration,
    )
  let assert effect.PrepareRejected(_, effect.RetryNotPermitted(_)) =
    effect.retry(settled_state, denied)
  assert peer_count(peer) == 1
  peer_release(peer)
  peer_stop(peer)
}

pub fn retry_after_settled_root_dispatches_ordinal_one_test() {
  let #(root_peer, root_port) =
    peer_start(response(200, [], [1, 2, 3]), "delay")
  let input = input_for(target(root_port, "/retry"), [], 16, None, None, None)
  let #(prepared_state, prepared, command_state, command) = command_for(input)
  let ledger_record_count = list.length(effect.network_attempts(prepared_state))
  let issued_command_count = 1
  let execution = started_execution(command, http_adapter.default_ports())
  let assert effect.StartedStep(started_state, _started) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  assert await_peer_count(root_peer, 40) == 1
  peer_release(root_peer)
  let delivered = await_observation(execution, 80)
  let assert effect.Delivered(_, effect.ResponseObservation(_, _, _, _, _, _)) =
    delivered
  let assert effect.TerminalStep(root_terminal_state, root_settled) =
    effect.observe(started_state, delivered)
  let assert effect.Response(_, _) = root_settled.terminal.outcome

  let root_peer_received_count = peer_count(root_peer)
  assert ledger_record_count == 1
  assert issued_command_count == 1
  assert root_peer_received_count == 1
  assert list.length(effect.network_attempts(root_terminal_state))
    == ledger_record_count
  peer_stop(root_peer)

  let #(retry_peer, retry_port) =
    peer_start(response(200, [], [4, 5, 6]), "delay")
  let authorization =
    effect.RetryAuthorization(
      input.attempt.logical,
      input.attempt,
      attempt(1),
      effect.OpaqueEvidence("retry-auth"),
    )
  let retry_instruction =
    effect.HttpWireInstruction(
      input.instruction.method,
      target(retry_port, "/retry"),
      input.instruction.headers,
      input.instruction.body,
    )
  let request =
    effect.RetryRequest(
      effect.RetryAllowed(authorization),
      retry_instruction,
      input.deadline,
      input.configuration,
    )
  let assert effect.PreparedResult(retried_state, retried) =
    effect.retry(root_terminal_state, request)
  assert list.length(effect.network_attempts(retried_state))
    == ledger_record_count + 1
  assert issued_command_count == 1
  assert peer_count(retry_peer) == 0
  assert retried.chain == effect.RetryOf(authorization)
  let assert [prepared_root_record, prepared_retry_record] =
    effect.network_attempts(retried_state)
  assert prepared_root_record.chain == effect.Root
  assert prepared_retry_record.chain == effect.RetryOf(authorization)

  let assert effect.CommandReady(command_state2, command2) =
    effect.send_command(retried_state, retried)
  let retry_execution =
    started_execution(command2, http_adapter.default_ports())
  let assert effect.StartedStep(retry_started_state, _retry_started) =
    effect.observe_start(
      command_state2,
      retried,
      effect.StartedObservation(
        retried.input.attempt,
        http_adapter.handle(retry_execution),
      ),
    )
  let issued_command_count = issued_command_count + 1
  assert await_peer_count(retry_peer, 40) == 1
  peer_release(retry_peer)
  let retry_delivered = await_observation(retry_execution, 80)
  let assert effect.Delivered(_, effect.ResponseObservation(_, _, _, _, _, _)) =
    retry_delivered
  let assert effect.TerminalStep(retry_terminal_state, retry_settled) =
    effect.observe(retry_started_state, retry_delivered)
  let assert effect.Response(_, _) = retry_settled.terminal.outcome

  assert issued_command_count == 2
  assert peer_count(retry_peer) == 1
  assert list.length(effect.network_attempts(retry_terminal_state))
    == ledger_record_count + 1
  let assert [final_root_record, final_retry_record] =
    effect.network_attempts(retry_terminal_state)
  assert final_retry_record.chain == effect.RetryOf(authorization)
  assert final_retry_record.chain != final_root_record.chain
  assert final_root_record.chain == effect.Root

  let assert effect.PrepareRejected(_, effect.RetryNotPermitted(_)) =
    effect.retry(retry_terminal_state, request)
  assert peer_count(retry_peer) == 1
  peer_stop(retry_peer)
}

fn start_failure_cause(command: effect.SendCommand) -> effect.HostFailure {
  let assert http_adapter.StartFailed(failure, effect.Unknown(_)) =
    http_adapter.start(command)
  failure.cause
}

pub fn prehandle_validation_is_typed_test() {
  let unsupported =
    input_for("ftp://127.0.0.1/resource", [], 8, None, None, None)
  assert unsupported |> direct_command |> start_failure_cause
    == effect.UnsupportedUriScheme

  let invalid =
    effect.AttemptInput(
      attempt(0),
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<>>),
      None,
      effect.HostConfiguration(-1, 8, None, None),
    )
  assert invalid |> direct_command |> start_failure_cause
    == effect.InvalidHostConfiguration

  let basis = effect.ClockBasis("missing")
  let clock =
    effect.MonotonicClockCapability(effect.OpaqueEvidence("clock"), basis)
  let missing_control =
    input_for(
      "http://127.0.0.1/",
      [],
      8,
      None,
      Some(clock),
      Some(effect.Deadline(basis, 1, clock)),
    )
  assert missing_control |> direct_command |> start_failure_cause
    == effect.DeadlineControlUnavailable
  let assert http_adapter.StartFailed(missing_failure, _) =
    http_adapter.start(direct_command(missing_control))
  assert missing_failure.stage == effect.Start

  let unconfigured =
    input_for(
      "http://127.0.0.1/",
      [],
      8,
      None,
      None,
      Some(effect.Deadline(basis, 1, clock)),
    )
  assert unconfigured |> direct_command |> start_failure_cause
    == effect.InvalidHostConfiguration
}

pub fn start_checks_run_in_the_fixed_order_test() {
  let basis = effect.ClockBasis("order")
  let clock =
    effect.MonotonicClockCapability(effect.OpaqueEvidence("clock"), basis)
  let deadline = Some(effect.Deadline(basis, 1, clock))
  let oversize = list.repeat(1, 300)
  assert input_for("ftp://127.0.0.1/", oversize, 8, None, Some(clock), deadline)
    |> direct_command
    |> start_failure_cause
    == effect.UnsupportedUriScheme
  assert input_for(
      "http://127.0.0.1/",
      oversize,
      8,
      None,
      Some(clock),
      deadline,
    )
    |> direct_command
    |> start_failure_cause
    == effect.InvalidHostConfiguration
  let #(peer, port) = peer_start(response(200, [], []), "respond")
  let #(_, _, _, command) =
    command_for(input_for(
      target(port, "/order"),
      [],
      8,
      None,
      Some(clock),
      deadline,
    ))
  let assert http_adapter.StartFailed(failure, _) = http_adapter.start(command)
  assert failure.cause == effect.DeadlineControlUnavailable
  assert failure.stage == effect.Start
  assert peer_count(peer) == 0
  peer_stop(peer)
}

pub fn a_clock_capability_differing_from_the_port_is_a_start_failure_test() {
  let basis = effect.ClockBasis("shared-basis")
  let configured =
    effect.MonotonicClockCapability(effect.OpaqueEvidence("configured"), basis)
  let port_capability =
    effect.MonotonicClockCapability(effect.OpaqueEvidence("port"), basis)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        port_capability,
        fn() { Ok(effect.MonotonicClockObservation(basis, 0)) },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let #(peer, port) = peer_start(response(200, [], []), "respond")
  let #(_, _, _, command) =
    command_for(input_for(
      target(port, "/clock-capability"),
      [],
      8,
      None,
      Some(configured),
      Some(effect.Deadline(basis, 1_000_000_000, configured)),
    ))
  let assert http_adapter.StartFailed(failure, _) =
    http_adapter.start_with_ports(command, ports)
  assert failure.cause == effect.DeadlineControlUnavailable
  assert failure.stage == effect.Start
  assert peer_count(peer) == 0
  peer_stop(peer)
}

pub fn a_cancellation_capability_differing_from_the_port_is_a_start_failure_test() {
  let configured =
    effect.CancellationCapability(effect.OpaqueEvidence("configured-cancel"))
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.default_ports().clock,
      http_adapter.CancellationPort(
        effect.CancellationCapability(effect.OpaqueEvidence("port-cancel")),
        fn(_) { Ok(Nil) },
      ),
    )
  let #(peer, port) = peer_start(response(200, [], []), "respond")
  let #(_, _, _, command) =
    command_for(input_for(
      target(port, "/cancel-capability"),
      [],
      8,
      Some(configured),
      None,
      None,
    ))
  let assert http_adapter.StartFailed(failure, _) =
    http_adapter.start_with_ports(command, ports)
  assert failure.cause == effect.InvalidHostConfiguration
  assert failure.stage == effect.Start
  assert peer_count(peer) == 0
  peer_stop(peer)
}

pub fn matching_capabilities_start_and_return_the_response_test() {
  let basis = effect.ClockBasis("matching-basis")
  let clock =
    effect.MonotonicClockCapability(effect.OpaqueEvidence("matching"), basis)
  let cancellation =
    effect.CancellationCapability(effect.OpaqueEvidence("matching-cancel"))
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock,
        fn() { Ok(effect.MonotonicClockObservation(basis, 0)) },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(cancellation, fn(_) { Ok(Nil) }),
    )
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "respond")
  let #(_, _, _, command) =
    command_for(input_for(
      target(port, "/matching"),
      [],
      8,
      Some(cancellation),
      Some(clock),
      Some(effect.Deadline(basis, 1_000_000_000, clock)),
    ))
  let execution = started_execution(command, ports)
  let raw = execution |> await_observation(200) |> response_from_observation
  assert raw.status == 200
  peer_stop(peer)
}

pub fn a_clock_exception_in_the_worker_is_one_deadline_failure_test() {
  let basis = effect.ClockBasis("panicking")
  let clock =
    effect.MonotonicClockCapability(effect.OpaqueEvidence("clock"), basis)
  let caller = process.self()
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        clock,
        fn() {
          case process.self() == caller {
            True -> Ok(effect.MonotonicClockObservation(basis, 0))
            False -> panic as "worker clock"
          }
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(unused_cancellation(), fn(_) { Ok(Nil) }),
    )
  let input =
    input_for(
      target(unused_port(), "/panicking-clock"),
      [],
      8,
      None,
      Some(clock),
      Some(effect.Deadline(basis, 1000, clock)),
    )
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, ports)
  let assert effect.Delivered(
    _,
    effect.FailureObservation(_, _, _, failure, status),
  ) = execution |> await_observation(80)
  assert failure.cause == effect.HostRuntimeFailure
  assert failure.stage == effect.DeadlineStage
  assert status == effect.Unknown(effect.HostFailure)
  let later = [
    http_adapter.observe(execution),
    http_adapter.observe(execution),
    http_adapter.observe(execution),
  ]
  assert list.all(later, fn(result) {
    case result {
      Ok(effect.Delivered(_, effect.FailureObservation(..))) -> False
      _ -> True
    }
  })
}

pub fn request_header_encoding_failure_is_post_handle_test() {
  let #(peer, port) = peer_start(response(200, [], []), "respond")
  let bad_header =
    effect.AttemptInput(
      attempt(0),
      effect.HttpWireInstruction(
        "GET",
        target(port, "/bad-header"),
        [effect.RawHeaderField("x-invalid", <<255>>)],
        <<>>,
      ),
      None,
      configuration(8, None, None),
    )
  let #(_, _, _, command) = command_for(bad_header)
  let execution = started_execution(command, http_adapter.default_ports())
  let failure = execution |> await_observation(80) |> failure_from_observation
  assert failure.stage == effect.RequestWrite
  assert failure.cause == effect.RequestHeaderEncodingUnavailable
  assert peer_count(peer) == 0
  peer_stop(peer)
}

pub fn truncated_response_body_is_response_body_failed_test() {
  let #(peer, port) = peer_start(<<>>, "close_body")
  let input = input_for(target(port, "/truncated"), [], 16, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  let failure = execution |> await_observation(80) |> failure_from_observation
  assert failure.stage == effect.ResponseBody
  assert failure.cause == effect.ResponseBodyFailed
  peer_stop(peer)
}

pub fn real_connection_body_limit_and_runtime_failures_are_typed_test() {
  let refused_input =
    input_for(target(unused_port(), "/refused"), [], 8, None, None, None)
  let #(_, _, _, refused_command) = command_for(refused_input)
  let refused_execution =
    started_execution(refused_command, http_adapter.default_ports())
  let refused =
    refused_execution |> await_observation(80) |> failure_from_observation
  assert refused.cause == effect.ConnectionFailed
  assert refused.attempt == refused_input.attempt
  assert refused.configuration == refused_input.configuration

  let resolution_input =
    input_for(
      "http://unresolvable.invalid/name-resolution",
      [],
      8,
      None,
      None,
      None,
    )
  let #(_, _, _, resolution_command) = command_for(resolution_input)
  let resolution_execution =
    started_execution(resolution_command, http_adapter.default_ports())
  let resolution =
    resolution_execution |> await_observation(80) |> failure_from_observation
  assert resolution.cause == effect.NameResolutionFailed

  let #(limit_peer, limit_port) =
    peer_start(response(200, [], [1, 2, 3]), "respond")
  let limit_input =
    input_for(target(limit_port, "/limit"), [], 2, None, None, None)
  let #(_, _, _, limit_command) = command_for(limit_input)
  let limit_execution =
    started_execution(limit_command, http_adapter.default_ports())
  let limit_failure =
    limit_execution |> await_observation(80) |> failure_from_observation
  assert limit_failure.cause == effect.ResponseBodyLimitExceeded
  assert limit_failure.stage == effect.ResponseBody
  peer_stop(limit_peer)

  let #(malformed_peer, malformed_port) = peer_start(<<>>, "malformed")
  let malformed_input =
    input_for(target(malformed_port, "/malformed"), [], 8, None, None, None)
  let #(_, _, _, malformed_command) = command_for(malformed_input)
  let malformed_execution =
    started_execution(malformed_command, http_adapter.default_ports())
  let malformed_failure =
    malformed_execution |> await_observation(80) |> failure_from_observation
  assert malformed_failure.cause == effect.MalformedResponse
  assert malformed_failure.stage == effect.ResponseHeaders
  peer_stop(malformed_peer)
}

pub fn closed_before_headers_is_response_headers_failed_test() {
  let #(peer, port) = peer_start(<<>>, "close_headers")
  let input =
    input_for(target(port, "/closed-before-headers"), [], 8, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  let failure = execution |> await_observation(80) |> failure_from_observation
  assert failure.cause == effect.ResponseHeadersFailed
  assert failure.stage == effect.ResponseHeaders
  peer_stop(peer)
}

pub fn unclassified_httpc_crash_is_host_runtime_failure_test() {
  let #(peer, port) = peer_start(<<>>, "invalid_framing")
  let input =
    input_for(target(port, "/invalid-framing"), [], 8, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  let failure = execution |> await_observation(80) |> failure_from_observation
  assert failure.cause == effect.HostRuntimeFailure
  assert failure.stage == effect.ResponseHeaders
  peer_stop(peer)
}

pub fn cancellation_rejection_and_host_close_are_typed_test() {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("reject"))
  let #(peer, port) = peer_start(response(200, [], []), "delay")
  let input =
    input_for(target(port, "/close"), [], 8, Some(capability), None, None)
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        unused_clock(),
        fn() {
          Ok(effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0))
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(capability, fn(_) {
        Error(effect.CancellationRejected)
      }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(rejected) = cancel_with(execution, input, capability)
  assert failure_from_observation(rejected).cause == effect.CancellationRejected
  let assert Ok(closed) = http_adapter.close(execution)
  assert failure_from_observation(closed).cause == effect.HostClosed
  assert failure_from_observation(closed).stage == effect.Cancel
  peer_release(peer)
  peer_stop(peer)
}

pub fn a_cancellation_failure_value_is_a_cancel_stage_failure_test() {
  let #(peer, port) = peer_start(response(200, [], []), "delay")
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("failing-cancel"))
  let input =
    input_for(target(port, "/failing"), [], 8, Some(capability), None, None)
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.default_ports().clock,
      http_adapter.CancellationPort(capability, fn(_) {
        Error(effect.ConnectionFailed)
      }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(failed) = cancel_with(execution, input, capability)
  let failure = failure_from_observation(failed)
  assert failure.stage == effect.Cancel
  assert failure.cause == effect.ConnectionFailed
  peer_release(peer)
  peer_stop(peer)
}

pub fn the_cancellation_port_receives_the_execution_handle_test() {
  let fixture = counting_cancel_fixture("/cancel-handle")
  let assert Ok(_) =
    cancel_with(fixture.execution, fixture.input, fixture.capability)
  let assert Ok(received) = process.receive(fixture.requests, 50)
  assert received == http_adapter.handle(fixture.execution)
  peer_release(fixture.peer)
  peer_stop(fixture.peer)
}

pub fn crashing_cancellation_port_is_host_runtime_failure_test() {
  let #(peer, port) = peer_start(response(200, [], []), "delay")
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("crashing-cancel"))
  let input =
    input_for(target(port, "/crash"), [], 8, Some(capability), None, None)
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        unused_clock(),
        fn() {
          Ok(effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0))
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(capability, fn(_) {
        panic as "cancellation port"
      }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(rejected) = cancel_with(execution, input, capability)
  let failure = failure_from_observation(rejected)
  assert failure.stage == effect.Cancel
  assert failure.cause == effect.HostRuntimeFailure
  peer_release(peer)
  process.sleep(300)
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  peer_stop(peer)
}

pub fn cancel_without_a_configured_capability_is_a_rejection_test() {
  let #(peer, port) = peer_start(response(200, [], []), "delay")
  let input = input_for(target(port, "/no-cancel"), [], 8, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  assert await_peer_count(peer, 40) == 1
  let assert Ok(rejected) = cancel_with(execution, input, unused_cancellation())
  let failure = failure_from_observation(rejected)
  assert failure.stage == effect.Cancel
  assert failure.cause == effect.CancellationRejected
  peer_release(peer)
  peer_stop(peer)
}

type CancelFixture {
  CancelFixture(
    peer: Peer,
    input: effect.AttemptInput,
    execution: http_adapter.Execution,
    capability: effect.CancellationCapability,
    requests: process.Subject(effect.ExecutionHandle),
  )
}

fn counting_cancel_fixture(path: String) -> CancelFixture {
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("counting-cancel"))
  let requests = process.new_subject()
  let #(peer, port) = peer_start(response(200, [], [111, 107]), "delay")
  let input = input_for(target(port, path), [], 8, Some(capability), None, None)
  let #(_, _, _, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(
        unused_clock(),
        fn() {
          Ok(effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0))
        },
        fn(_) { None },
      ),
      http_adapter.CancellationPort(capability, fn(received) {
        process.send(requests, received)
        Ok(Nil)
      }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  CancelFixture(peer, input, execution, capability, requests)
}

fn port_calls(fixture: CancelFixture) -> Int {
  case process.receive(fixture.requests, 50) {
    Ok(_) -> 1 + port_calls(fixture)
    Error(Nil) -> 0
  }
}

fn assert_response_arrives(fixture: CancelFixture) -> Nil {
  peer_release(fixture.peer)
  let assert effect.Delivered(_, effect.ResponseObservation(_, _, _, _, _, _)) =
    await_observation(fixture.execution, 400)
  peer_stop(fixture.peer)
}

fn assert_no_late_observation(fixture: CancelFixture) -> Nil {
  peer_release(fixture.peer)
  process.sleep(300)
  assert http_adapter.observe(fixture.execution)
    == Ok(effect.Pending(
      fixture.input.attempt,
      http_adapter.handle(fixture.execution),
    ))
  peer_stop(fixture.peer)
}

pub fn a_matching_cancel_calls_the_port_once_test() {
  let fixture = counting_cancel_fixture("/cancel-matching")
  let assert Ok(cancelled) =
    cancel_with(fixture.execution, fixture.input, fixture.capability)
  let assert effect.Delivered(0, effect.CancellationObservation(_, _, _, _)) =
    cancelled
  assert port_calls(fixture) == 1
  peer_release(fixture.peer)
  peer_stop(fixture.peer)
}

pub fn a_cancel_with_a_foreign_capability_never_reaches_the_port_test() {
  let fixture = counting_cancel_fixture("/cancel-foreign-capability")
  let foreign =
    effect.CancellationCapability(effect.OpaqueEvidence("foreign-cancel"))
  let assert Ok(rejected) =
    cancel_with(fixture.execution, fixture.input, foreign)
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
  assert port_calls(fixture) == 0
  assert_no_late_observation(fixture)
}

pub fn a_cancel_with_a_foreign_handle_is_unknown_and_never_reaches_the_port_test() {
  let fixture = counting_cancel_fixture("/cancel-foreign-handle")
  let foreign = effect.ExecutionHandle("foreign-handle")
  assert http_adapter.cancel(
      fixture.execution,
      effect.CancelCommand(fixture.input.attempt, foreign, fixture.capability),
    )
    == Error(http_adapter.UnknownExecution(foreign))
  assert port_calls(fixture) == 0
  assert_response_arrives(fixture)
}

pub fn host_failure_matrix_covers_closed_causes_test() {
  let matrix = [
    #("unsupported_uri", effect.UnsupportedUriScheme),
    #("invalid_configuration", effect.InvalidHostConfiguration),
    #("execution_start", effect.ExecutionStartFailed),
    #("resolver", effect.NameResolutionFailed),
    #("connect", effect.ConnectionFailed),
    #("partial_write", effect.RequestWriteFailed),
    #("headers", effect.ResponseHeadersFailed),
    #("body", effect.ResponseBodyFailed),
    #("body_limit", effect.ResponseBodyLimitExceeded),
    #("malformed", effect.MalformedResponse),
    #("header_codec", effect.HeaderRepresentationUnavailable),
    #("request_header", effect.RequestHeaderEncodingUnavailable),
    #("cancel", effect.CancellationRejected),
    #("deadline_control", effect.DeadlineControlUnavailable),
    #("timeout", effect.Timeout(effect.Start, effect.LibraryReported)),
    #("runtime", effect.HostRuntimeFailure),
    #("closed", effect.HostClosed),
  ]
  assert list.length(matrix) == 17
  list.each(matrix, fn(entry) {
    let #(stimulus, expected) = entry
    let cause = classify_fault(stimulus, effect.Start, effect.LibraryReported)
    assert cause == expected
    let failure =
      effect.NetworkHostFailure(
        attempt(0),
        effect.Start,
        configuration(8, None, None),
        cause,
      )
    assert failure.attempt == attempt(0)
    assert failure.configuration == configuration(8, None, None)
  })

  let stages = [
    effect.Start,
    effect.RequestWrite,
    effect.ResponseHeaders,
    effect.ResponseBody,
    effect.Cancel,
    effect.DeadlineStage,
  ]
  let causes = [
    effect.LibraryReported,
    effect.SocketReported,
    effect.PoolAcquisition,
    effect.HostOperation,
  ]
  let timeout_pairs =
    list.flat_map(stages, fn(stage) {
      list.map(causes, fn(cause) { #(stage, cause) })
    })
  assert list.length(timeout_pairs) == 24
  list.each(timeout_pairs, fn(pair) {
    let #(stage, cause) = pair
    assert classify_fault("timeout", stage, cause)
      == effect.Timeout(stage, cause)
  })
}

pub fn observation_is_retained_five_seconds_after_the_response_test() {
  let #(peer, port) =
    peer_start(response(200, [#("x-retained", "yes")], [111, 107]), "respond")
  let input = input_for(target(port, "/retained"), [], 16, None, None, None)
  let #(_, _, _, command) = command_for(input)
  let execution = started_execution(command, http_adapter.default_ports())
  assert await_peer_count(peer, 40) == 1
  process.sleep(5000)
  let assert Ok(observed) = http_adapter.observe(execution)
  let assert effect.Delivered(
    0,
    effect.ResponseObservation(_, _, effect.NoSource, raw, _, _),
  ) = observed
  assert raw.status == 200
  assert raw.body == <<111, 107>>
  assert http_adapter.observe(execution)
    == Ok(effect.Pending(input.attempt, http_adapter.handle(execution)))
  peer_stop(peer)
}

fn unused_clock() -> effect.MonotonicClockCapability {
  effect.MonotonicClockCapability(
    effect.OpaqueEvidence("unused-clock"),
    effect.ClockBasis("unused"),
  )
}

fn unused_cancellation() -> effect.CancellationCapability {
  effect.CancellationCapability(effect.OpaqueEvidence("unused-cancel"))
}
