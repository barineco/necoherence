// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/network_effect as effect

@external(erlang, "necoherence_http_adapter_ffi", "bytes_to_binary")
fn bytes_to_binary(bytes: List(Int)) -> BitArray

@external(erlang, "necoherence_http_adapter_ffi", "binary_to_bytes")
fn binary_to_bytes(bytes: BitArray) -> List(Int)

@external(erlang, "necoherence_http_adapter_ffi", "header_to_bytes")
fn header_to_bytes(value: String) -> Result(List(Int), Nil)

pub type MonotonicClockPort {
  MonotonicClockPort(observe: fn() -> effect.MonotonicClockObservation)
}

pub type CancellationPort {
  CancellationPort(request: fn(effect.CancellationCapability) -> Bool)
}

pub type AdapterPorts {
  AdapterPorts(clock: MonotonicClockPort, cancellation: CancellationPort)
}

type EventQueue

@external(erlang, "necoherence_http_adapter_ffi", "queue_new")
fn queue_new() -> EventQueue

@external(erlang, "necoherence_http_adapter_ffi", "queue_publish")
fn queue_publish(
  queue: EventQueue,
  observation: effect.AdapterObservation,
) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "queue_pop")
fn queue_pop(queue: EventQueue) -> Option(#(Int, effect.AdapterObservation))

pub type RunOutcome {
  Completed
  ResponseBodyTruncated
  ClosedBeforeHeaders
  MalformedResponse
  Unclassified
}

@external(erlang, "necoherence_http_adapter_ffi", "run_safely")
fn run_safely(work: fn() -> Nil) -> RunOutcome

@external(erlang, "necoherence_http_adapter_ffi", "ensure_http_runtime")
fn ensure_http_runtime() -> Bool

pub opaque type Execution {
  Execution(
    handle: effect.ExecutionHandle,
    queue: EventQueue,
    command: effect.SendCommand,
    ports: AdapterPorts,
  )
}

pub type StartResult {
  Started(Execution)
  StartFailed(effect.NetworkHostFailure, effect.EffectStatus)
}

pub fn default_ports() -> AdapterPorts {
  AdapterPorts(
    MonotonicClockPort(fn() {
      effect.MonotonicClockObservation(effect.ClockBasis("system"), 0)
    }),
    CancellationPort(fn(_) { True }),
  )
}

pub fn handle(execution: Execution) -> effect.ExecutionHandle {
  execution.handle
}

pub fn start(command: effect.SendCommand) -> StartResult {
  start_with_ports(command, default_ports())
}

pub fn start_with_ports(
  command: effect.SendCommand,
  ports: AdapterPorts,
) -> StartResult {
  let input = command.prepared.input
  case validated_request(input) {
    Error(#(stage, cause)) ->
      StartFailed(
        effect.NetworkHostFailure(
          input.attempt,
          stage,
          input.configuration,
          cause,
        ),
        effect.Unknown(effect.HostFailure),
      )
    Ok(req) ->
      case ensure_http_runtime() {
        False ->
          StartFailed(
            effect.NetworkHostFailure(
              input.attempt,
              effect.Start,
              input.configuration,
              effect.ExecutionStartFailed,
            ),
            effect.Unknown(effect.HostFailure),
          )
        True -> {
          let handle = execution_handle(input.attempt)
          let queue = queue_new()
          let _worker =
            process.spawn_unlinked(fn() {
              case
                run_safely(fn() { perform(input, req, handle, queue, ports) })
              {
                Completed -> Nil
                ResponseBodyTruncated ->
                  publish_failure(
                    queue,
                    effect.NetworkHostFailure(
                      input.attempt,
                      effect.ResponseBody,
                      input.configuration,
                      effect.ResponseBodyFailed,
                    ),
                    effect.Unknown(effect.HostFailure),
                    handle,
                  )
                ClosedBeforeHeaders ->
                  publish_failure(
                    queue,
                    effect.NetworkHostFailure(
                      input.attempt,
                      effect.ResponseHeaders,
                      input.configuration,
                      effect.ResponseHeadersFailed,
                    ),
                    effect.Unknown(effect.HostFailure),
                    handle,
                  )
                MalformedResponse ->
                  publish_failure(
                    queue,
                    effect.NetworkHostFailure(
                      input.attempt,
                      effect.ResponseHeaders,
                      input.configuration,
                      effect.MalformedResponse,
                    ),
                    effect.Unknown(effect.HostFailure),
                    handle,
                  )
                Unclassified ->
                  publish_failure(
                    queue,
                    effect.NetworkHostFailure(
                      input.attempt,
                      effect.ResponseBody,
                      input.configuration,
                      effect.HostRuntimeFailure,
                    ),
                    effect.Unknown(effect.HostFailure),
                    handle,
                  )
              }
            })
          Started(Execution(handle, queue, command, ports))
        }
      }
  }
}

pub fn observe(execution: Execution) -> Result(effect.HostObservation, Nil) {
  case queue_pop(execution.queue) {
    Some(#(delivery, observation)) ->
      Ok(effect.Delivered(delivery, observation))
    None ->
      Ok(effect.Pending(
        execution.command.prepared.input.attempt,
        execution.handle,
      ))
  }
}

pub fn cancel(execution: Execution) -> Result(effect.HostObservation, Nil) {
  let input = execution.command.prepared.input
  case input.configuration.cancellation {
    None -> Error(Nil)
    Some(capability) -> {
      let CancellationPort(request) = execution.ports.cancellation
      case request(capability) {
        True ->
          publish_and_take(
            execution,
            effect.CancellationObservation(
              input.attempt,
              execution.handle,
              effect.NoSource,
              effect.Unknown(effect.CancellationReason),
            ),
          )
        False ->
          publish_and_take(
            execution,
            failure_observation(
              effect.NetworkHostFailure(
                input.attempt,
                effect.Cancel,
                input.configuration,
                effect.CancellationRejected,
              ),
              effect.Unknown(effect.HostFailure),
              execution.handle,
            ),
          )
      }
    }
  }
}

pub fn close(execution: Execution) -> Result(effect.HostObservation, Nil) {
  let input = execution.command.prepared.input
  publish_and_take(
    execution,
    failure_observation(
      effect.NetworkHostFailure(
        input.attempt,
        effect.Cancel,
        input.configuration,
        effect.HostClosed,
      ),
      effect.Unknown(effect.HostFailure),
      execution.handle,
    ),
  )
}

fn publish_and_take(
  execution: Execution,
  observation: effect.AdapterObservation,
) -> Result(effect.HostObservation, Nil) {
  queue_publish(execution.queue, observation)
  case queue_pop(execution.queue) {
    Some(#(delivery, delivered)) -> Ok(effect.Delivered(delivery, delivered))
    None -> Error(Nil)
  }
}

fn execution_handle(attempt: effect.AttemptIdentity) -> effect.ExecutionHandle {
  effect.ExecutionHandle(
    attempt.logical.kind
    <> ":"
    <> attempt.logical.provenance
    <> ":"
    <> int.to_string(attempt.logical.revision)
    <> ":"
    <> int.to_string(attempt.ordinal),
  )
}

fn validated_request(
  input: effect.AttemptInput,
) -> Result(request.Request(BitArray), #(effect.HostStage, effect.HostFailure)) {
  let target = string.lowercase(input.instruction.target)
  case
    string.starts_with(target, "http://")
    || string.starts_with(target, "https://")
  {
    False -> Error(#(effect.Start, effect.UnsupportedUriScheme))
    True ->
      case configuration_valid(input) {
        False -> Error(#(effect.Start, effect.InvalidHostConfiguration))
        True ->
          case deadline_control_valid(input) {
            False ->
              Error(#(effect.DeadlineStage, effect.DeadlineControlUnavailable))
            True -> build_base_request(input.instruction)
          }
      }
  }
}

fn configuration_valid(input: effect.AttemptInput) -> Bool {
  input.configuration.request_body_limit >= 0
  && input.configuration.response_body_limit >= 0
  && list.length(input.instruction.body)
  <= input.configuration.request_body_limit
}

fn deadline_control_valid(input: effect.AttemptInput) -> Bool {
  case input.deadline {
    None -> True
    Some(deadline) ->
      deadline.capability.clock_basis == deadline.clock_basis
      && input.configuration.monotonic_clock == Some(deadline.capability)
  }
}

fn encoded_headers(
  headers: List(effect.RawHeaderField),
) -> Result(List(#(String, String)), Nil) {
  list.try_map(headers, fn(header) {
    case list.all(header.value, fn(byte) { byte >= 32 && byte <= 126 }) {
      False -> Error(Nil)
      True -> {
        use value <- result.try(
          bit_array.to_string(bytes_to_binary(header.value)),
        )
        Ok(#(header.name, value))
      }
    }
  })
}

fn build_base_request(
  instruction: effect.HttpWireInstruction,
) -> Result(request.Request(BitArray), #(effect.HostStage, effect.HostFailure)) {
  use base <- result.try(
    request.to(instruction.target)
    |> result.map_error(fn(_) { #(effect.Start, effect.UnsupportedUriScheme) }),
  )
  use method <- result.try(
    http.parse_method(instruction.method)
    |> result.map_error(fn(_) {
      #(effect.Start, effect.InvalidHostConfiguration)
    }),
  )
  let with_method = request.set_method(base, method)
  Ok(request.map(with_method, fn(_) { bytes_to_binary(instruction.body) }))
}

fn perform(
  input: effect.AttemptInput,
  req: request.Request(BitArray),
  handle: effect.ExecutionHandle,
  queue: EventQueue,
  ports: AdapterPorts,
) -> Nil {
  case deadline_observation(input, ports) {
    Some(observation) -> queue_publish(queue, observation)
    None ->
      case encoded_headers(input.instruction.headers) {
        Error(_) ->
          publish_failure(
            queue,
            effect.NetworkHostFailure(
              input.attempt,
              effect.RequestWrite,
              input.configuration,
              effect.RequestHeaderEncodingUnavailable,
            ),
            effect.Unknown(effect.HostFailure),
            handle,
          )
        Ok(headers) -> {
          let with_headers =
            list.fold(headers, req, fn(current, header) {
              let #(name, value) = header
              request.prepend_header(current, name, value)
            })
          let client = httpc.configure() |> httpc.timeout(1000)
          case httpc.dispatch_bits(client, with_headers) {
            Ok(response) -> publish_response(input, response, handle, queue)
            Error(error) -> {
              let #(stage, cause) = classify_http_error(error)
              publish_failure(
                queue,
                effect.NetworkHostFailure(
                  input.attempt,
                  stage,
                  input.configuration,
                  cause,
                ),
                effect.Unknown(effect.HostFailure),
                handle,
              )
            }
          }
        }
      }
  }
}

fn deadline_observation(
  input: effect.AttemptInput,
  ports: AdapterPorts,
) -> Option(effect.AdapterObservation) {
  case input.deadline {
    None -> None
    Some(deadline) -> {
      let MonotonicClockPort(observe) = ports.clock
      let observed = observe()
      case
        observed.clock_basis == deadline.clock_basis,
        observed.value >= deadline.limit
      {
        True, True ->
          Some(effect.DeadlineObservation(
            input.attempt,
            execution_handle(input.attempt),
            effect.NoSource,
            deadline,
            observed,
            effect.Unknown(effect.DeadlineReason),
          ))
        True, False -> None
        False, _ ->
          Some(failure_observation(
            effect.NetworkHostFailure(
              input.attempt,
              effect.DeadlineStage,
              input.configuration,
              effect.DeadlineControlUnavailable,
            ),
            effect.Unknown(effect.HostFailure),
            execution_handle(input.attempt),
          ))
      }
    }
  }
}

fn classify_http_error(
  error: httpc.HttpError,
) -> #(effect.HostStage, effect.HostFailure) {
  case error {
    httpc.ResponseTimeout -> #(
      effect.ResponseHeaders,
      effect.Timeout(effect.ResponseHeaders, effect.LibraryReported),
    )
    httpc.FailedToConnect(ip4, ip6) ->
      case name_resolution_error(ip4) && name_resolution_error(ip6) {
        True -> #(effect.Start, effect.NameResolutionFailed)
        False -> #(effect.Start, effect.ConnectionFailed)
      }
    httpc.InvalidUtf8Response -> #(
      effect.ResponseBody,
      effect.ResponseBodyFailed,
    )
  }
}

fn name_resolution_error(error: httpc.ConnectError) -> Bool {
  case error {
    httpc.Posix(code) ->
      code == "nxdomain"
      || code == "noname"
      || code == "nodata"
      || code == "host_not_found"
    httpc.TlsAlert(_, _) -> False
  }
}

fn publish_response(
  input: effect.AttemptInput,
  response: response.Response(BitArray),
  handle: effect.ExecutionHandle,
  queue: EventQueue,
) -> Nil {
  let body = binary_to_bytes(response.body)
  case
    response.status >= 100 && response.status <= 999,
    list.length(body) <= input.configuration.response_body_limit
  {
    False, _ ->
      publish_failure(
        queue,
        effect.NetworkHostFailure(
          input.attempt,
          effect.ResponseHeaders,
          input.configuration,
          effect.MalformedResponse,
        ),
        effect.Unknown(effect.HostFailure),
        handle,
      )
    True, False ->
      publish_failure(
        queue,
        effect.NetworkHostFailure(
          input.attempt,
          effect.ResponseBody,
          input.configuration,
          effect.ResponseBodyLimitExceeded,
        ),
        effect.Unknown(effect.HostFailure),
        handle,
      )
    True, True ->
      case normalized_headers(response.headers) {
        Error(_) ->
          publish_failure(
            queue,
            effect.NetworkHostFailure(
              input.attempt,
              effect.ResponseHeaders,
              input.configuration,
              effect.HeaderRepresentationUnavailable,
            ),
            effect.Unknown(effect.HostFailure),
            handle,
          )
        Ok(headers) -> {
          let raw = effect.RawHttpResponse(response.status, headers, body)
          queue_publish(
            queue,
            effect.ResponseObservation(
              input.attempt,
              handle,
              effect.NoSource,
              raw,
              effect.LibraryNormalized,
              effect.Unknown(effect.NoResponse),
            ),
          )
        }
      }
  }
}

fn normalized_headers(
  headers: List(#(String, String)),
) -> Result(List(effect.RawHeaderField), Nil) {
  use normalized <- result.try(
    list.try_map(headers, fn(pair) {
      let #(name, value) = pair
      use bytes <- result.try(header_to_bytes(value))
      Ok(effect.RawHeaderField(string.lowercase(name), bytes))
    }),
  )
  Ok(
    list.sort(normalized, fn(left, right) {
      string.compare(left.name, right.name)
    }),
  )
}

fn failure_observation(
  failure: effect.NetworkHostFailure,
  status: effect.EffectStatus,
  handle: effect.ExecutionHandle,
) -> effect.AdapterObservation {
  effect.FailureObservation(
    failure.attempt,
    handle,
    effect.NoSource,
    failure,
    status,
  )
}

fn publish_failure(
  queue: EventQueue,
  failure: effect.NetworkHostFailure,
  status: effect.EffectStatus,
  handle: effect.ExecutionHandle,
) -> Nil {
  queue_publish(queue, failure_observation(failure, status, handle))
}
