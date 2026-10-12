// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/http_adapter
import necoherence/network_effect as effect
import necoherence/request_progression as progression

type Peer

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_start")
fn peer_start(response: BitArray, mode: String) -> #(Peer, Int)

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_release")
fn peer_release(peer: Peer) -> Nil

@external(erlang, "necoherence_http_smoke_peer_ffi", "peer_count")
fn peer_count(peer: Peer) -> Int

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

@external(erlang, "necoherence_http_adapter_ffi", "bytes_to_binary")
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
      [effect.RawHeaderField("x-request", [111, 107])],
      body,
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
  let ledger_record_count = list.length(prepared_state.attempts)
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
      effect.Unknown(effect.NoResponse),
    ),
  ) = delivered
  assert observed_attempt == input.attempt
  assert observed_handle == http_adapter.handle(execution)
  assert raw.status == 201
  assert raw.body == [0, 128, 255]
  let duplicate_headers =
    list.filter(raw.headers, fn(header) { header.name == "x-a" })
  assert list.length(duplicate_headers) == 2
  let assert Ok(utf_header) =
    list.find(raw.headers, fn(header) { header.name == "x-utf" })
  assert utf_header.value == [195, 169]
  let header_names = list.map(raw.headers, fn(header) { header.name })
  assert header_names == list.sort(header_names, string.compare)
  let assert effect.TerminalStep(terminal_state, settled) =
    effect.observe(started_state, delivered)
  assert settled.terminal.outcome
    == effect.Response(raw, effect.LibraryNormalized)
  assert list.length(terminal_state.attempts) == 1

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
              effect.RawHeaderField("content-type", [
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
              ]),
              effect.RawHeaderField("x-api-key", [116, 111, 107, 101, 110]),
              effect.RawHeaderField("x-api-version", [
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
              ]),
            ],
            body,
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
      assert raw.body == [111, 107]
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
  assert raw.body == [111, 107]
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

pub fn cancellation_wins_and_response_is_late_test() {
  let #(peer, port) = peer_start(response(200, [], [114, 97, 119]), "delay")
  let capability =
    effect.CancellationCapability(effect.OpaqueEvidence("cancel"))
  let input =
    input_for(target(port, "/cancel"), [], 16, Some(capability), None, None)
  let #(_, prepared, command_state, command) = command_for(input)
  let ports =
    http_adapter.AdapterPorts(
      http_adapter.MonotonicClockPort(fn() {
        effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0)
      }),
      http_adapter.CancellationPort(fn(received) { received == capability }),
    )
  let execution = started_execution(command, ports)
  let assert effect.StartedStep(started_state, _) =
    effect.observe_start(
      command_state,
      prepared,
      effect.StartedObservation(input.attempt, http_adapter.handle(execution)),
    )
  assert await_peer_count(peer, 40) == 1

  let assert Ok(cancelled) = http_adapter.cancel(execution)
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
  let late_response = await_observation(execution, 80)
  let assert effect.Delivered(1, fresh) = late_response
  let assert effect.LateStep(late_state, _, _) =
    effect.observe(cancelled_state, late_response)
  assert effect.observe(cancelled_state, cancelled)
    == effect.DuplicateStep(cancelled_state, input.attempt, 0)
  let conflicting = effect.Delivered(0, fresh)
  let assert effect.NetworkRejected(_, effect.ConflictingDelivery(_, 0, _, _)) =
    effect.observe(cancelled_state, conflicting)
  assert list.length(late_state.attempts) == 1
  peer_stop(peer)
}

pub fn deadline_and_library_timeout_are_distinct_test() {
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
      http_adapter.MonotonicClockPort(fn() {
        effect.MonotonicClockObservation(basis, 5)
      }),
      http_adapter.CancellationPort(fn(_) { True }),
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

  let #(peer, port) = peer_start(response(200, [], []), "delay")
  let timeout_input =
    input_for(target(port, "/timeout"), [], 8, None, None, None)
  let #(_, _, _, timeout_command) = command_for(timeout_input)
  let timeout_execution =
    started_execution(timeout_command, http_adapter.default_ports())
  assert await_peer_count(peer, 40) == 1
  let timeout_failure =
    timeout_execution |> await_observation(300) |> failure_from_observation
  assert timeout_failure.cause
    == effect.Timeout(effect.ResponseHeaders, effect.LibraryReported)
  assert timeout_failure.stage == effect.ResponseHeaders
  peer_release(peer)
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
      effect.HttpWireInstruction("POST", target(port, "/forged"), [], []),
      prepared.input.deadline,
      prepared.input.configuration,
    )
  let forged = effect.PreparedAttempt(forged_input, prepared.lineage)
  let assert effect.CommandRejected(
    _,
    effect.AttemptTokenMismatch(_, effect.Instruction),
  ) = effect.send_command(prepared_state, forged)

  let execution = started_execution(command, http_adapter.default_ports())
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
  let assert Ok(cancelled) = http_adapter.cancel(execution)
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
  assert retried.lineage == effect.RetryOf(authorization)
  assert list.length(retried_state.attempts) == 2
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
  let ledger_record_count = list.length(prepared_state.attempts)
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
  assert list.length(root_terminal_state.attempts) == ledger_record_count
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
  assert list.length(retried_state.attempts) == ledger_record_count + 1
  assert issued_command_count == 1
  assert peer_count(retry_peer) == 0
  assert retried.lineage == effect.RetryOf(authorization)
  let assert [prepared_root_record, prepared_retry_record] =
    retried_state.attempts
  assert prepared_root_record.lineage == effect.Root
  assert prepared_retry_record.lineage == effect.RetryOf(authorization)

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
  assert list.length(retry_terminal_state.attempts) == ledger_record_count + 1
  let assert [final_root_record, final_retry_record] =
    retry_terminal_state.attempts
  assert final_retry_record.lineage == effect.RetryOf(authorization)
  assert final_retry_record.lineage != final_root_record.lineage
  assert final_root_record.lineage == effect.Root

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
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], []),
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
      None,
      Some(effect.Deadline(basis, 1, clock)),
    )
  assert missing_control |> direct_command |> start_failure_cause
    == effect.DeadlineControlUnavailable
}

pub fn request_header_encoding_failure_is_post_handle_test() {
  let #(peer, port) = peer_start(response(200, [], []), "respond")
  let bad_header =
    effect.AttemptInput(
      attempt(0),
      effect.HttpWireInstruction(
        "GET",
        target(port, "/bad-header"),
        [effect.RawHeaderField("x-invalid", [255])],
        [],
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
  assert failure.stage == effect.ResponseBody
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
      http_adapter.MonotonicClockPort(fn() {
        effect.MonotonicClockObservation(effect.ClockBasis("unused"), 0)
      }),
      http_adapter.CancellationPort(fn(_) { False }),
    )
  let execution = started_execution(command, ports)
  assert await_peer_count(peer, 40) == 1
  let assert Ok(rejected) = http_adapter.cancel(execution)
  assert failure_from_observation(rejected).cause == effect.CancellationRejected
  let assert Ok(closed) = http_adapter.close(execution)
  assert failure_from_observation(closed).cause == effect.HostClosed
  peer_release(peer)
  peer_stop(peer)
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
