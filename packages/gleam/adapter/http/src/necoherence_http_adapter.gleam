// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import neco_quotient_retention as retention
import necoherence/network_effect as effect
import necoherence/network_host as host
import necoherence/semantic_generation_runtime as runtime

@external(erlang, "necoherence_http_adapter_ffi", "header_to_bytes")
fn header_to_bytes(value: String) -> Result(BitArray, Nil)

pub type MonotonicClockPort {
  MonotonicClockPort(
    capability: effect.MonotonicClockCapability,
    observe: fn() ->
      Result(effect.MonotonicClockObservation, effect.HostFailure),
    until: fn(Int) -> Option(Int),
  )
}

pub type CancellationPort {
  CancellationPort(
    capability: effect.CancellationCapability,
    request: fn(effect.ExecutionHandle) -> Result(Nil, effect.HostFailure),
  )
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

@external(erlang, "necoherence_http_adapter_ffi", "queue_publish_observation")
fn queue_publish_observation(
  queue: EventQueue,
  observation: effect.AdapterObservation,
) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "queue_bind_worker")
fn queue_bind_worker(queue: EventQueue, worker: process.Pid) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "queue_publish_deadline")
fn queue_publish_deadline(
  queue: EventQueue,
  observation: effect.AdapterObservation,
) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "queue_finish")
fn queue_finish(queue: EventQueue) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "queue_stop")
fn queue_stop(queue: EventQueue) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "queue_core_done")
fn queue_core_done(queue: EventQueue) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "monotonic_millis")
fn monotonic_millis() -> Int

@external(erlang, "necoherence_http_adapter_ffi", "put_stage")
fn put_stage(stage: effect.HostStage) -> Nil

@external(erlang, "necoherence_http_adapter_ffi", "current_stage")
fn current_stage() -> effect.HostStage

type QueuePop {
  Popped(Int, effect.AdapterObservation)
  Drained
  Gone
  TimedOut
}

@external(erlang, "necoherence_http_adapter_ffi", "queue_pop")
fn queue_pop(queue: EventQueue) -> QueuePop

@external(erlang, "necoherence_http_adapter_ffi", "queue_running")
fn queue_running(queue: EventQueue) -> Bool

@external(erlang, "necoherence_http_adapter_ffi", "queue_await")
fn queue_await(queue: EventQueue) -> QueuePop

@external(erlang, "necoherence_http_adapter_ffi", "queue_await_for")
fn queue_await_for(queue: EventQueue, limit: Int) -> QueuePop

pub type RunOutcome {
  Completed
  ResponseBodyTruncated
  ClosedBeforeHeaders
  MalformedResponse
  Unclassified
}

@external(erlang, "necoherence_http_adapter_ffi", "try_call")
fn try_call(thunk: fn() -> a) -> Result(a, Nil)

@external(erlang, "necoherence_http_adapter_ffi", "queue_deadline_emitted")
fn queue_deadline_emitted(queue: EventQueue) -> Bool

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
    worker: process.Pid,
  )
}

pub type UnknownExecution {
  UnknownExecution(handle: effect.ExecutionHandle)
}

pub type StartResult {
  Started(Execution)
  StartFailed(effect.NetworkHostFailure, effect.EffectStatus)
}

pub fn default_ports() -> AdapterPorts {
  let origin = monotonic_millis()
  let elapsed = fn() { monotonic_millis() - origin }
  AdapterPorts(
    MonotonicClockPort(
      effect.MonotonicClockCapability(
        effect.OpaqueEvidence("gleam-system-monotonic-clock"),
        effect.ClockBasis("system"),
      ),
      fn() {
        Ok(effect.MonotonicClockObservation(
          effect.ClockBasis("system"),
          elapsed(),
        ))
      },
      fn(limit) { Some(int.max(limit - elapsed(), 0)) },
    ),
    CancellationPort(
      effect.CancellationCapability(effect.OpaqueEvidence(
        "gleam-cooperative-cancellation",
      )),
      fn(_) { Ok(Nil) },
    ),
  )
}

pub fn host_port(ports: AdapterPorts) -> host.AdapterPorts {
  host.AdapterPorts(fn(command) {
    case start_with_ports(command, ports) {
      Started(execution) ->
        host.Started(
          host.Execution(handle(execution), fn() {
            result.replace_error(observe(execution), Nil)
          }),
        )
      StartFailed(failure, effect) -> host.StartFailed(failure, effect)
    }
  })
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
  case validated_request(input, ports) {
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
          let worker =
            process.spawn_unlinked(fn() {
              put_stage(effect.RequestWrite)
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
                      current_stage(),
                      input.configuration,
                      effect.HostRuntimeFailure,
                    ),
                    effect.Unknown(effect.HostFailure),
                    handle,
                  )
              }
              queue_finish(queue)
            })
          queue_bind_worker(queue, worker)
          Started(Execution(handle, queue, command, ports, worker))
        }
      }
  }
}

pub fn observe(
  execution: Execution,
) -> Result(effect.HostObservation, UnknownExecution) {
  case queue_pop(execution.queue) {
    Popped(delivery, observation) -> Ok(effect.Delivered(delivery, observation))
    Gone -> Error(UnknownExecution(execution.handle))
    Drained | TimedOut ->
      case observed_deadline(execution) {
        None -> Ok(pending_observation(execution))
        Some(observation) -> {
          queue_publish_deadline(execution.queue, observation)
          case queue_pop(execution.queue) {
            Popped(delivery, observation) ->
              Ok(effect.Delivered(delivery, observation))
            Gone -> Error(UnknownExecution(execution.handle))
            Drained | TimedOut -> Ok(pending_observation(execution))
          }
        }
      }
  }
}

fn observed_deadline(
  execution: Execution,
) -> Option(effect.AdapterObservation) {
  let input = execution.command.prepared.input
  case input.deadline {
    None -> None
    Some(_) ->
      case queue_deadline_emitted(execution.queue) {
        True -> None
        False ->
          case
            try_call(fn() {
              deadline_observation(input, execution.handle, execution.ports)
            })
          {
            Ok(observation) -> observation
            Error(Nil) ->
              Some(clock_failure(execution, effect.HostRuntimeFailure))
          }
      }
  }
}

fn clock_failure(
  execution: Execution,
  cause: effect.HostFailure,
) -> effect.AdapterObservation {
  clock_failure_for(execution.command.prepared.input, execution.handle, cause)
}

fn stage_for_cause(
  default: effect.HostStage,
  cause: effect.HostFailure,
) -> effect.HostStage {
  case cause {
    effect.Timeout(stage, _) -> stage
    _ -> default
  }
}

fn clock_failure_for(
  input: effect.AttemptInput,
  handle: effect.ExecutionHandle,
  cause: effect.HostFailure,
) -> effect.AdapterObservation {
  failure_observation(
    effect.NetworkHostFailure(
      input.attempt,
      stage_for_cause(effect.DeadlineStage, cause),
      input.configuration,
      cause,
    ),
    effect.Unknown(effect.HostFailure),
    handle,
  )
}

fn pending_observation(execution: Execution) -> effect.HostObservation {
  effect.Pending(execution.command.prepared.input.attempt, execution.handle)
}

pub fn release(
  state: effect.NetworkState,
  execution: Execution,
) -> effect.HostRecordDecision {
  let running = queue_running(execution.queue)
  let decision =
    effect.release_host_record(
      state,
      fn(_) { running },
      execution.command.prepared.input.attempt,
    )
  case decision {
    retention.Dematerialize(_) -> queue_stop(execution.queue)
    _ ->
      case core_settled(state, execution, decision) {
        True -> queue_core_done(execution.queue)
        False -> Nil
      }
  }
  decision
}

pub fn cancel(
  execution: Execution,
  command: effect.CancelCommand,
) -> Result(effect.HostObservation, UnknownExecution) {
  let input = execution.command.prepared.input
  case command.handle == execution.handle && command.attempt == input.attempt {
    False -> Error(UnknownExecution(command.handle))
    True ->
      case input.configuration.cancellation {
        None ->
          publish_and_take(
            execution,
            cancel_failure(execution, effect.CancellationRejected),
          )
        Some(_) -> {
          let CancellationPort(port_capability, request) =
            execution.ports.cancellation
          case command.capability == port_capability {
            False ->
              publish_and_take(
                execution,
                cancel_failure(execution, effect.CancellationRejected),
              )
            True ->
              case try_call(fn() { request(command.handle) }) {
                Ok(Ok(Nil)) ->
                  publish_and_take(
                    execution,
                    effect.CancellationObservation(
                      input.attempt,
                      execution.handle,
                      effect.NoSource,
                      effect.Unknown(effect.CancellationReason),
                    ),
                  )
                Ok(Error(cause)) ->
                  publish_and_take(execution, cancel_failure(execution, cause))
                Error(Nil) ->
                  publish_and_take(
                    execution,
                    cancel_failure(execution, effect.HostRuntimeFailure),
                  )
              }
          }
        }
      }
  }
}

fn cancel_failure(
  execution: Execution,
  cause: effect.HostFailure,
) -> effect.AdapterObservation {
  let input = execution.command.prepared.input
  failure_observation(
    effect.NetworkHostFailure(
      input.attempt,
      stage_for_cause(effect.Cancel, cause),
      input.configuration,
      cause,
    ),
    effect.Unknown(effect.HostFailure),
    execution.handle,
  )
}

pub fn close(
  execution: Execution,
) -> Result(effect.HostObservation, UnknownExecution) {
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
) -> Result(effect.HostObservation, UnknownExecution) {
  queue_publish_observation(execution.queue, observation)
  case queue_pop(execution.queue) {
    Popped(delivery, delivered) -> Ok(effect.Delivered(delivery, delivered))
    Drained | Gone | TimedOut -> Error(UnknownExecution(execution.handle))
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
  ports: AdapterPorts,
) -> Result(request.Request(BitArray), #(effect.HostStage, effect.HostFailure)) {
  let target = string.lowercase(input.instruction.target)
  case
    string.starts_with(target, "http://")
    || string.starts_with(target, "https://")
  {
    False -> Error(#(effect.Start, effect.UnsupportedUriScheme))
    True ->
      case accepted_by_core(input) {
        False -> Error(#(effect.Start, effect.InvalidHostConfiguration))
        True ->
          case clock_matches(input, ports) {
            False -> Error(#(effect.Start, effect.DeadlineControlUnavailable))
            True ->
              case cancellation_matches(input, ports) {
                False -> Error(#(effect.Start, effect.InvalidHostConfiguration))
                True -> build_base_request(input.instruction)
              }
          }
      }
  }
}

fn accepted_by_core(input: effect.AttemptInput) -> Bool {
  let root =
    effect.AttemptInput(
      ..input,
      attempt: effect.AttemptIdentity(..input.attempt, ordinal: 0),
    )
  case effect.prepare(effect.empty_state(), root) {
    effect.PreparedResult(_, _) -> True
    _ -> False
  }
}

fn clock_matches(input: effect.AttemptInput, ports: AdapterPorts) -> Bool {
  case input.deadline {
    None -> True
    Some(deadline) -> ports.clock.capability == deadline.capability
  }
}

fn cancellation_matches(
  input: effect.AttemptInput,
  ports: AdapterPorts,
) -> Bool {
  case input.configuration.cancellation {
    None -> True
    Some(capability) -> ports.cancellation.capability == capability
  }
}

fn encoded_headers(
  headers: List(effect.RawHeaderField),
) -> Result(List(#(String, String)), Nil) {
  list.try_map(headers, fn(header) {
    case printable_ascii(header.value) {
      False -> Error(Nil)
      True -> {
        use value <- result.try(bit_array.to_string(header.value))
        Ok(#(header.name, value))
      }
    }
  })
}

fn printable_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>> if byte >= 32 && byte <= 126 -> printable_ascii(rest)
    _ -> False
  }
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
  Ok(request.map(with_method, fn(_) { instruction.body }))
}

fn perform(
  input: effect.AttemptInput,
  req: request.Request(BitArray),
  handle: effect.ExecutionHandle,
  queue: EventQueue,
  ports: AdapterPorts,
) -> Nil {
  case try_call(fn() { deadline_observation(input, handle, ports) }) {
    Error(Nil) ->
      queue_publish_deadline(
        queue,
        clock_failure_for(input, handle, effect.HostRuntimeFailure),
      )
    Ok(Some(observation)) -> queue_publish_deadline(queue, observation)
    Ok(None) ->
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
          put_stage(effect.ResponseHeaders)
          case dispatch_bits(with_headers) {
            Ok(response) -> {
              put_stage(effect.ResponseBody)
              publish_response(input, response, handle, queue)
            }
            Error(Interrupted) -> Nil
            Error(error) -> {
              let #(stage, cause) = classify_http_error(error, current_stage())
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
  handle: effect.ExecutionHandle,
  ports: AdapterPorts,
) -> Option(effect.AdapterObservation) {
  case input.deadline {
    None -> None
    Some(deadline) ->
      case ports.clock.observe() {
        Error(cause) -> Some(clock_failure_for(input, handle, cause))
        Ok(observed) ->
          case
            observed.clock_basis == deadline.clock_basis,
            observed.value >= deadline.limit
          {
            True, True ->
              Some(effect.DeadlineObservation(
                input.attempt,
                handle,
                effect.NoSource,
                deadline,
                observed,
                effect.Unknown(effect.DeadlineReason),
              ))
            _, _ -> None
          }
      }
  }
}

type HttpError {
  FailedToConnect(ip4: ConnectError, ip6: ConnectError)
  Interrupted
}

type ConnectError {
  Posix(code: String)
  TlsAlert(code: String, detail: String)
}

@external(erlang, "necoherence_http_adapter_ffi", "dispatch_bits")
fn erl_dispatch_bits(
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), HttpError)

fn dispatch_bits(
  req: request.Request(BitArray),
) -> Result(response.Response(BitArray), HttpError) {
  let url = req |> request.to_uri |> uri.to_string
  let content_type =
    req
    |> request.get_header("content-type")
    |> result.unwrap("application/octet-stream")
  use #(status, headers, body) <- result.map(erl_dispatch_bits(
    req.method,
    url,
    req.headers,
    content_type,
    req.body,
  ))
  response.Response(status, headers, body)
}

fn classify_http_error(
  error: HttpError,
  stage: effect.HostStage,
) -> #(effect.HostStage, effect.HostFailure) {
  case error {
    Interrupted -> #(stage, effect.HostRuntimeFailure)
    FailedToConnect(ip4, ip6) ->
      case name_resolution_error(ip4) && name_resolution_error(ip6) {
        True -> #(effect.Start, effect.NameResolutionFailed)
        False -> #(effect.Start, effect.ConnectionFailed)
      }
  }
}

fn name_resolution_error(error: ConnectError) -> Bool {
  case error {
    Posix(code) ->
      code == "nxdomain"
      || code == "noname"
      || code == "nodata"
      || code == "host_not_found"
    TlsAlert(_, _) -> False
  }
}

fn publish_response(
  input: effect.AttemptInput,
  response: response.Response(BitArray),
  handle: effect.ExecutionHandle,
  queue: EventQueue,
) -> Nil {
  let body = response.body
  case
    response.status >= 100 && response.status <= 999,
    bit_array.byte_size(body) <= input.configuration.response_body_limit
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
              effect.Unknown(effect.ProtocolWitnessMissing),
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

pub type Driven {
  Driven(result: runtime.ExecutionResult, retained: List(Execution))
}

pub type DriveCause {
  RunFailed(runtime.RunFailure)
  ExecutionGone(effect.ExecutionHandle)
  DeadlineWaitUnavailable(effect.ExecutionHandle)
}

type AwaitFailure {
  AwaitGone
  AwaitDeadlineUnavailable
}

pub type DriveFailure {
  DriveFailure(cause: DriveCause, retained: List(Execution))
}

pub fn drive(
  ports: AdapterPorts,
  first: runtime.Progress,
) -> Result(Driven, DriveFailure) {
  drive_loop(ports, first, [])
}

fn drive_loop(
  ports: AdapterPorts,
  progress: runtime.Progress,
  candidates: List(Execution),
) -> Result(Driven, DriveFailure) {
  case progress {
    runtime.Completed(result, state) ->
      Ok(Driven(result, finish_candidates(state, candidates)))
    runtime.Pending(pending, runtime.Send(command)) -> {
      let #(observation, handled) = case start_with_ports(command, ports) {
        Started(started) -> #(
          effect.StartedObservation(
            command.prepared.input.attempt,
            handle(started),
          ),
          Some(started),
        )
        StartFailed(failure, status) -> #(
          effect.StartFailed(failure, status),
          None,
        )
      }
      drive_resume(
        ports,
        pending,
        runtime.Start(observation),
        handled,
        candidates,
      )
    }
    runtime.Pending(pending, runtime.Observe(started)) ->
      case
        list.find(candidates, fn(candidate) {
          candidate.handle == started.handle
        })
      {
        Error(Nil) ->
          Error(DriveFailure(
            ExecutionGone(started.handle),
            finish_candidates(runtime.execution_network(pending), candidates),
          ))
        Ok(execution) ->
          case await_observation(ports, execution) {
            Ok(observation) ->
              drive_resume(
                ports,
                pending,
                runtime.Host(observation),
                None,
                candidates,
              )
            Error(AwaitGone) ->
              Error(DriveFailure(
                ExecutionGone(started.handle),
                finish_candidates(
                  runtime.execution_network(pending),
                  candidates,
                ),
              ))
            Error(AwaitDeadlineUnavailable) ->
              Error(DriveFailure(
                DeadlineWaitUnavailable(started.handle),
                finish_candidates(
                  runtime.execution_network(pending),
                  candidates,
                ),
              ))
          }
      }
  }
}

fn drive_resume(
  ports: AdapterPorts,
  pending: runtime.Execution,
  observation: runtime.ExecutionObservation,
  handled: Option(Execution),
  candidates: List(Execution),
) -> Result(Driven, DriveFailure) {
  let candidates = case handled {
    Some(execution) -> list.append(candidates, [execution])
    None -> candidates
  }
  case runtime.resume(pending, observation) {
    Error(failure) ->
      Error(DriveFailure(
        RunFailed(failure),
        finish_candidates(failure.network, candidates),
      ))
    Ok(next) -> {
      let state = case next {
        runtime.Completed(_, state) -> state
        runtime.Pending(execution, _) -> runtime.execution_network(execution)
      }
      drive_loop(ports, next, sweep_candidates(state, candidates))
    }
  }
}

fn await_observation(
  ports: AdapterPorts,
  execution: Execution,
) -> Result(effect.HostObservation, AwaitFailure) {
  case observe(execution) {
    Error(UnknownExecution(_)) -> Error(AwaitGone)
    Ok(effect.Pending(_, _)) ->
      case execution.command.prepared.input.deadline {
        None ->
          case queue_await(execution.queue) {
            Popped(delivery, observation) ->
              Ok(effect.Delivered(delivery, observation))
            _ -> Error(AwaitGone)
          }
        Some(deadline) ->
          case try_call(fn() { ports.clock.until(deadline.limit) }) {
            Error(Nil) -> {
              queue_publish_deadline(
                execution.queue,
                clock_failure(execution, effect.HostRuntimeFailure),
              )
              case queue_await(execution.queue) {
                Popped(delivery, observation) ->
                  Ok(effect.Delivered(delivery, observation))
                _ -> Error(AwaitGone)
              }
            }
            Ok(None) -> Error(AwaitDeadlineUnavailable)
            Ok(Some(length)) ->
              case queue_await_for(execution.queue, int.max(length, 1)) {
                Popped(delivery, observation) ->
                  Ok(effect.Delivered(delivery, observation))
                Gone -> Error(AwaitGone)
                Drained | TimedOut -> await_observation(ports, execution)
              }
          }
      }
    Ok(delivered) -> Ok(delivered)
  }
}

fn released(decision: effect.HostRecordDecision) -> Bool {
  case decision {
    retention.Dematerialize(_) -> True
    _ -> False
  }
}

fn sweep_candidates(
  state: effect.NetworkState,
  candidates: List(Execution),
) -> List(Execution) {
  list.filter(candidates, fn(candidate) { !released(release(state, candidate)) })
}

fn core_settled(
  state: effect.NetworkState,
  execution: Execution,
  decision: effect.HostRecordDecision,
) -> Bool {
  case decision {
    retention.Retain(_) ->
      effect.host_settled(state, execution.command.prepared.input.attempt)
    _ -> False
  }
}

fn finish_candidates(
  state: effect.NetworkState,
  candidates: List(Execution),
) -> List(Execution) {
  list.filter(candidates, fn(candidate) {
    let decision = release(state, candidate)
    !released(decision) && !core_settled(state, candidate, decision)
  })
}
