// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{type Option, None, Some}
import necoherence/network_effect as network
import necoherence/network_host as adapter
import necoherence/semantic_generation_runtime as runtime

pub type Failure {
  Callback(runtime.CallbackFailure)
  Network(network.NetworkFailure)
  Transport(network.NetworkTerminal)
  ObservationUnavailable
}

pub type Outcome(o) {
  Completed(state: network.NetworkState, value: o)
  Pending(state: network.NetworkState, pending: PendingCall(o))
  Failed(state: network.NetworkState, failure: Failure)
  Observed(state: network.NetworkState, observation: network.NetworkStep)
}

pub opaque type PendingCall(o) {
  PendingCall(
    state: network.NetworkState,
    execution: adapter.Execution,
    decode: fn(
      network.RawHttpResponse,
      network.HeaderProvenance,
      network.EffectStatus,
    ) -> Result(o, runtime.CallbackFailure),
  )
}

pub fn dispatch(
  state: network.NetworkState,
  input: network.AttemptInput,
  decode: fn(
    network.RawHttpResponse,
    network.HeaderProvenance,
    network.EffectStatus,
  ) -> Result(o, runtime.CallbackFailure),
  ports: adapter.AdapterPorts,
) -> Outcome(o) {
  case network.prepare(state, input) {
    network.PrepareRejected(state, failure) -> Failed(state, Network(failure))
    network.PreparedResult(state, prepared) ->
      case network.send_command(state, prepared) {
        network.CommandRejected(state, failure) ->
          Failed(state, Network(failure))
        network.CommandReady(state, command) ->
          case adapter.start_with_ports(command, ports) {
            adapter.StartFailed(failure, effect) ->
              finish(
                network.observe_start(
                  state,
                  prepared,
                  network.StartFailed(failure, effect),
                ),
                None,
                decode,
              )
            adapter.Started(execution) ->
              finish(
                network.observe_start(
                  state,
                  prepared,
                  network.StartedObservation(
                    prepared.input.attempt,
                    adapter.handle(execution),
                  ),
                ),
                Some(execution),
                decode,
              )
          }
      }
  }
}

pub fn resume(pending: PendingCall(o)) -> Outcome(o) {
  case adapter.observe(pending.execution) {
    Error(_) -> Failed(pending.state, ObservationUnavailable)
    Ok(observation) ->
      finish(
        network.observe(pending.state, observation),
        Some(pending.execution),
        pending.decode,
      )
  }
}

fn finish(
  step: network.NetworkStep,
  execution: Option(adapter.Execution),
  decode: fn(
    network.RawHttpResponse,
    network.HeaderProvenance,
    network.EffectStatus,
  ) -> Result(o, runtime.CallbackFailure),
) -> Outcome(o) {
  case step {
    network.NetworkRejected(state, failure) -> Failed(state, Network(failure))
    network.TerminalStep(state, settled)
    | network.LateStep(state, settled, _) ->
      case settled.terminal.outcome {
        network.Response(response, provenance) ->
          case decode(response, provenance, settled.terminal.effect) {
            Ok(value) -> Completed(state, value)
            Error(failure) -> Failed(state, Callback(failure))
          }
        _ -> Failed(state, Transport(settled.terminal))
      }
    network.StartedStep(state, _) | network.PendingStep(state, _) ->
      case execution {
        Some(execution) -> Pending(state, PendingCall(state, execution, decode))
        None -> Failed(state, ObservationUnavailable)
      }
    network.DuplicateStep(state, _, _) -> Observed(state, step)
  }
}
