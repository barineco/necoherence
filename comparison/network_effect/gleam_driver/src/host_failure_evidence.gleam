// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/network_effect as effect
import necoherence/request_progression as progression
import necoherence_http_adapter as adapter

@external(erlang, "host_failure_evidence_ffi", "read_line")
fn read_line() -> Result(String, Nil)

pub fn main() {
  loop()
}

fn loop() -> Nil {
  case read_line() {
    Error(Nil) -> Nil
    Ok(line) -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> Nil
        _ -> io.println(run_row(parse_flat(trimmed)))
      }
      loop()
    }
  }
}

fn identity(kind: String) -> effect.RequestIdentity {
  progression.RequestIdentity(kind, "host-failure-matrix", 0)
}

fn base_configuration(constructor: String) -> effect.HostConfiguration {
  let response_limit = case constructor {
    "ResponseBodyLimitExceeded" -> 4
    _ -> 16
  }
  effect.HostConfiguration(256, response_limit, None, None)
}

fn build_input(
  row: Dict(String, Option(String)),
) -> #(effect.AttemptInput, Bool) {
  let constructor = field(row, "constructor")
  let peer_host = field(row, "peerHost")
  let peer_port = field(row, "peerPort")
  let scheme = case constructor {
    "UnsupportedUriScheme" -> "ftp"
    _ -> "http"
  }
  let target =
    scheme <> "://" <> peer_host <> ":" <> peer_port <> "/host-failure-matrix"
  let configuration = base_configuration(constructor)
  let attempt = effect.AttemptIdentity(identity(constructor), 0)
  let base =
    effect.AttemptInput(
      attempt,
      effect.HttpWireInstruction(
        "GET",
        target,
        case constructor {
          "RequestHeaderEncodingUnavailable" -> [
            effect.RawHeaderField("x-forged", [128]),
          ]
          _ -> []
        },
        [],
      ),
      None,
      configuration,
    )
  case constructor {
    "DeadlineControlUnavailable" -> {
      let capability =
        effect.MonotonicClockCapability(
          effect.OpaqueEvidence("matrix-clock"),
          effect.ClockBasis("matrix"),
        )
      let deadline = effect.Deadline(effect.ClockBasis("matrix"), 5, capability)
      #(
        effect.AttemptInput(
          attempt,
          base.instruction,
          Some(deadline),
          effect.HostConfiguration(
            256,
            configuration.response_body_limit,
            None,
            Some(capability),
          ),
        ),
        False,
      )
    }
    "CancellationRejected" -> {
      let capability =
        effect.CancellationCapability(effect.OpaqueEvidence("matrix-cancel"))
      #(
        effect.AttemptInput(
          attempt,
          base.instruction,
          None,
          effect.HostConfiguration(
            256,
            configuration.response_body_limit,
            Some(capability),
            None,
          ),
        ),
        True,
      )
    }
    _ -> #(base, False)
  }
}

fn stage_of(name: String) -> effect.HostStage {
  case name {
    "Start" -> effect.Start
    "RequestWrite" -> effect.RequestWrite
    "ResponseHeaders" -> effect.ResponseHeaders
    "ResponseBody" -> effect.ResponseBody
    "Cancel" -> effect.Cancel
    "Deadline" -> effect.DeadlineStage
    _ -> effect.Start
  }
}

fn cause_of(name: String) -> effect.HostTimeoutCause {
  case name {
    "LibraryReported" -> effect.LibraryReported
    "SocketReported" -> effect.SocketReported
    "PoolAcquisition" -> effect.PoolAcquisition
    _ -> effect.HostOperation
  }
}

fn stage_name(stage: effect.HostStage) -> String {
  case stage {
    effect.Start -> "Start"
    effect.RequestWrite -> "RequestWrite"
    effect.ResponseHeaders -> "ResponseHeaders"
    effect.ResponseBody -> "ResponseBody"
    effect.Cancel -> "Cancel"
    effect.DeadlineStage -> "Deadline"
  }
}

fn cause_name(cause: effect.HostTimeoutCause) -> String {
  case cause {
    effect.LibraryReported -> "LibraryReported"
    effect.SocketReported -> "SocketReported"
    effect.PoolAcquisition -> "PoolAcquisition"
    effect.HostOperation -> "HostOperation"
  }
}

fn failure_tag(cause: effect.HostFailure) -> String {
  case cause {
    effect.UnsupportedUriScheme -> "UnsupportedUriScheme"
    effect.InvalidHostConfiguration -> "InvalidHostConfiguration"
    effect.ExecutionStartFailed -> "ExecutionStartFailed"
    effect.NameResolutionFailed -> "NameResolutionFailed"
    effect.ConnectionFailed -> "ConnectionFailed"
    effect.RequestWriteFailed -> "RequestWriteFailed"
    effect.ResponseHeadersFailed -> "ResponseHeadersFailed"
    effect.ResponseBodyFailed -> "ResponseBodyFailed"
    effect.ResponseBodyLimitExceeded -> "ResponseBodyLimitExceeded"
    effect.MalformedResponse -> "MalformedResponse"
    effect.HeaderRepresentationUnavailable -> "HeaderRepresentationUnavailable"
    effect.RequestHeaderEncodingUnavailable ->
      "RequestHeaderEncodingUnavailable"
    effect.CancellationRejected -> "CancellationRejected"
    effect.DeadlineControlUnavailable -> "DeadlineControlUnavailable"
    effect.Timeout(_, _) -> "Timeout"
    effect.HostRuntimeFailure -> "HostRuntimeFailure"
    effect.HostClosed -> "HostClosed"
  }
}

fn direct_failure(
  constructor: String,
  timeout_stage: String,
  timeout_cause: String,
) -> #(effect.HostStage, effect.HostFailure) {
  case constructor {
    "ExecutionStartFailed" -> #(effect.Start, effect.ExecutionStartFailed)
    "NameResolutionFailed" -> #(effect.Start, effect.NameResolutionFailed)
    "RequestWriteFailed" -> #(effect.RequestWrite, effect.RequestWriteFailed)
    "HeaderRepresentationUnavailable" -> #(
      effect.ResponseHeaders,
      effect.HeaderRepresentationUnavailable,
    )
    "InvalidHostConfiguration" -> #(
      effect.Start,
      effect.InvalidHostConfiguration,
    )
    "HostRuntimeFailure" -> #(effect.ResponseBody, effect.HostRuntimeFailure)
    "Timeout" -> {
      let stage = stage_of(timeout_stage)
      #(stage, effect.Timeout(stage, cause_of(timeout_cause)))
    }
    _ -> #(effect.Start, effect.HostRuntimeFailure)
  }
}

fn field(row: Dict(String, Option(String)), key: String) -> String {
  case dict.get(row, key) {
    Ok(Some(value)) -> value
    _ -> ""
  }
}

fn run_row(row: Dict(String, Option(String))) -> String {
  let constructor = field(row, "constructor")
  let test_only = field(row, "testOnly") == "true"
  let #(input, reject_cancellation) = build_input(row)
  case effect.prepare(effect.NetworkState([]), input) {
    effect.PrepareRejected(_, failure) ->
      error_object("prepare rejected: " <> string.inspect(failure))
    effect.PreparedResult(state, prepared) -> {
      let ledger_record_count = list.length(state.attempts)
      case effect.send_command(state, prepared) {
        effect.CommandRejected(_, failure) ->
          error_object("send_command rejected: " <> string.inspect(failure))
        effect.CommandReady(state, command) ->
          case test_only {
            True ->
              run_test_only(
                row,
                constructor,
                input,
                state,
                prepared,
                ledger_record_count,
              )
            False ->
              run_real(
                constructor,
                reject_cancellation,
                input,
                state,
                prepared,
                command,
                ledger_record_count,
              )
          }
      }
    }
  }
}

fn run_test_only(
  row: Dict(String, Option(String)),
  constructor: String,
  input: effect.AttemptInput,
  state: effect.NetworkState,
  prepared: effect.PreparedAttempt,
  ledger_record_count: Int,
) -> String {
  let #(stage, cause) =
    direct_failure(
      constructor,
      field(row, "timeoutStage"),
      field(row, "timeoutCause"),
    )
  let unknown = effect.Unknown(effect.HostFailure)
  case constructor {
    "ExecutionStartFailed" -> {
      let failure =
        effect.NetworkHostFailure(
          input.attempt,
          stage,
          input.configuration,
          cause,
        )
      let observation = effect.StartFailed(failure, unknown)
      report_step(
        "test-only-handle",
        ledger_record_count,
        effect.observe_start(state, prepared, observation),
      )
    }
    _ -> {
      let handle = effect.ExecutionHandle("gleam-test-only-handle")
      case
        effect.observe_start(
          state,
          prepared,
          effect.StartedObservation(input.attempt, handle),
        )
      {
        effect.StartedStep(state, _) -> {
          let failure =
            effect.NetworkHostFailure(
              input.attempt,
              stage,
              input.configuration,
              cause,
            )
          let observation =
            effect.FailureObservation(
              input.attempt,
              handle,
              effect.NoSource,
              failure,
              unknown,
            )
          report_step(
            handle.value,
            ledger_record_count,
            effect.observe(state, effect.Delivered(0, observation)),
          )
        }
        other ->
          error_object(
            "unexpected observe_start result: " <> string.inspect(other),
          )
      }
    }
  }
}

fn run_real(
  constructor: String,
  reject_cancellation: Bool,
  input: effect.AttemptInput,
  state: effect.NetworkState,
  prepared: effect.PreparedAttempt,
  command: effect.SendCommand,
  ledger_record_count: Int,
) -> String {
  let ports = case reject_cancellation {
    True ->
      adapter.AdapterPorts(
        adapter.MonotonicClockPort(fn() {
          effect.MonotonicClockObservation(effect.ClockBasis("system"), 0)
        }),
        adapter.CancellationPort(fn(_) { False }),
      )
    False -> adapter.default_ports()
  }
  case adapter.start_with_ports(command, ports) {
    adapter.StartFailed(failure, status) ->
      report_step(
        "start-failed",
        ledger_record_count,
        effect.observe_start(
          state,
          prepared,
          effect.StartFailed(failure, status),
        ),
      )
    adapter.Started(execution) -> {
      case reject_cancellation {
        True -> {
          process.sleep(50)
          finish_execution(
            state,
            prepared,
            input,
            ledger_record_count,
            adapter.cancel(execution),
          )
        }
        False ->
          case constructor {
            "HostClosed" -> {
              process.sleep(50)
              finish_execution(
                state,
                prepared,
                input,
                ledger_record_count,
                adapter.close(execution),
              )
            }
            _ ->
              poll_execution(
                state,
                prepared,
                input,
                ledger_record_count,
                execution,
                0,
              )
          }
      }
    }
  }
}

fn poll_execution(
  state: effect.NetworkState,
  prepared: effect.PreparedAttempt,
  input: effect.AttemptInput,
  ledger_record_count: Int,
  execution: adapter.Execution,
  attempts: Int,
) -> String {
  case adapter.observe(execution) {
    Ok(effect.Delivered(_, _) as observation) ->
      finish_execution(
        state,
        prepared,
        input,
        ledger_record_count,
        Ok(observation),
      )
    Ok(effect.Pending(_, _)) ->
      case attempts > 300 {
        True -> error_object("polling timed out")
        False -> {
          process.sleep(10)
          poll_execution(
            state,
            prepared,
            input,
            ledger_record_count,
            execution,
            attempts + 1,
          )
        }
      }
    Error(Nil) -> error_object("execution closed")
  }
}

fn finish_execution(
  state: effect.NetworkState,
  prepared: effect.PreparedAttempt,
  input: effect.AttemptInput,
  ledger_record_count: Int,
  observation: Result(effect.HostObservation, Nil),
) -> String {
  case observation {
    Error(Nil) -> error_object("execution closed")
    Ok(host_observation) -> {
      let handle = handle_of(host_observation)
      case
        effect.observe_start(
          state,
          prepared,
          effect.StartedObservation(input.attempt, handle),
        )
      {
        effect.StartedStep(state, _) ->
          report_step(
            handle.value,
            ledger_record_count,
            effect.observe(state, host_observation),
          )
        other ->
          error_object(
            "unexpected observe_start result: " <> string.inspect(other),
          )
      }
    }
  }
}

fn handle_of(observation: effect.HostObservation) -> effect.ExecutionHandle {
  case observation {
    effect.Pending(_, handle) -> handle
    effect.Delivered(_, adapter_observation) ->
      case adapter_observation {
        effect.ResponseObservation(_, handle, _, _, _, _) -> handle
        effect.FailureObservation(_, handle, _, _, _) -> handle
        effect.CancellationObservation(_, handle, _, _) -> handle
        effect.DeadlineObservation(_, handle, _, _, _, _) -> handle
      }
  }
}

fn report_step(
  handle: String,
  ledger_record_count: Int,
  step: effect.NetworkStep,
) -> String {
  case step {
    effect.TerminalStep(_, settled) ->
      report_terminal(handle, ledger_record_count, settled.terminal)
    effect.StartedStep(_, _) | effect.PendingStep(_, _) ->
      object([
        #("ledgerRecordCount", int.to_string(ledger_record_count)),
        #("issuedCommandCount", "1"),
        #("outcomeTag", quote("Pending")),
        #("effect", quote("Unknown")),
        #("handle", quote(handle)),
      ])
    effect.NetworkRejected(_, failure) ->
      object([
        #("ledgerRecordCount", int.to_string(ledger_record_count)),
        #("issuedCommandCount", "1"),
        #("outcomeTag", quote("LedgerRejected")),
        #("cause", quote(string.inspect(failure))),
        #("handle", quote(handle)),
      ])
    other -> error_object("unexpected NetworkStep: " <> string.inspect(other))
  }
}

fn report_terminal(
  handle: String,
  ledger_record_count: Int,
  terminal: effect.NetworkTerminal,
) -> String {
  let effect_tag = case terminal.effect {
    effect.NoEffect(_) -> "NoEffect"
    effect.EffectOccurred(_) -> "EffectOccurred"
    effect.Unknown(_) -> "Unknown"
  }
  let base = [
    #("ledgerRecordCount", int.to_string(ledger_record_count)),
    #("issuedCommandCount", "1"),
    #("effect", quote(effect_tag)),
    #("handle", quote(handle)),
  ]
  case terminal.outcome {
    effect.Failed(failure) -> {
      let #(inner_stage, inner_cause) = case failure.cause {
        effect.Timeout(stage, cause) -> #(
          quote(stage_name(stage)),
          quote(cause_name(cause)),
        )
        _ -> #("null", "null")
      }
      object(
        list.append(base, [
          #("outcomeTag", quote("Failed")),
          #("stage", quote(stage_name(failure.stage))),
          #("cause", quote(failure_tag(failure.cause))),
          #("innerStage", inner_stage),
          #("innerCause", inner_cause),
        ]),
      )
    }
    effect.Cancelled ->
      object(
        list.append(base, [
          #("outcomeTag", quote("Cancelled")),
          #("stage", quote("Cancel")),
          #("cause", quote("Cancelled")),
        ]),
      )
    other ->
      object(list.append(base, [#("outcomeTag", quote(string.inspect(other)))]))
  }
}

fn error_object(reason: String) -> String {
  object([#("error", quote(reason))])
}

fn object(fields: List(#(String, String))) -> String {
  "{"
  <> string.join(
    list.map(fields, fn(pair) { quote(pair.0) <> ":" <> pair.1 }),
    ",",
  )
  <> "}"
}

fn quote(value: String) -> String {
  "\""
  <> string.replace(string.replace(value, "\\", "\\\\"), "\"", "\\\"")
  <> "\""
}

fn parse_flat(line: String) -> Dict(String, Option(String)) {
  let inner = string.slice(line, 1, string.length(line) - 2)
  split_pairs(inner, dict.new())
}

fn split_pairs(
  remaining: String,
  acc: Dict(String, Option(String)),
) -> Dict(String, Option(String)) {
  case string.trim(remaining) {
    "" -> acc
    trimmed -> {
      let assert Ok(#(key, after_key)) = string.split_once(trimmed, ":")
      let key = unquote(string.trim(key))
      let #(value, rest) = read_value(string.trim(after_key))
      split_pairs(rest, dict.insert(acc, key, value))
    }
  }
}

fn read_value(text: String) -> #(Option(String), String) {
  case string.starts_with(text, "\"") {
    True -> {
      let #(value, rest) = read_quoted(string.drop_start(text, 1), "")
      #(Some(value), drop_leading_comma(rest))
    }
    False ->
      case string.starts_with(text, "null") {
        True -> #(None, drop_leading_comma(string.drop_start(text, 4)))
        False -> {
          let #(value, rest) = split_at_comma(text, "")
          #(Some(string.trim(value)), rest)
        }
      }
  }
}

fn read_quoted(text: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(text) {
    Error(Nil) -> #(acc, "")
    Ok(#("\"", rest)) -> #(acc, rest)
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Error(Nil) -> #(acc, "")
        Ok(#(escaped, after)) -> read_quoted(after, acc <> escaped)
      }
    Ok(#(grapheme, rest)) -> read_quoted(rest, acc <> grapheme)
  }
}

fn split_at_comma(text: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(text) {
    Error(Nil) -> #(acc, "")
    Ok(#(",", rest)) -> #(acc, rest)
    Ok(#(grapheme, rest)) -> split_at_comma(rest, acc <> grapheme)
  }
}

fn drop_leading_comma(text: String) -> String {
  case string.starts_with(string.trim(text), ",") {
    True -> string.drop_start(string.trim(text), 1)
    False -> text
  }
}

fn unquote(text: String) -> String {
  case string.starts_with(text, "\"") {
    True -> string.slice(text, 1, string.length(text) - 2)
    False -> text
  }
}
