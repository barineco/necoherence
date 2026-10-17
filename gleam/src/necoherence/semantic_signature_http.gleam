// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/result
import necoherence/network_effect as network
import necoherence/network_host as adapter
import necoherence/semantic_generation_http as http
import necoherence/semantic_generation_runtime as runtime

pub type PreparedInput(o) {
  Ready(input: network.AttemptInput)
  Completed(value: o)
}

pub type Binding(i, o) {
  Binding(
    prepare: fn(i) -> Result(PreparedInput(o), runtime.CallbackFailure),
    decode: fn(
      network.RawHttpResponse,
      network.HeaderProvenance,
      network.EffectStatus,
    ) -> Result(o, runtime.CallbackFailure),
    ports: adapter.AdapterPorts,
  )
}

pub fn call(
  state: network.NetworkState,
  input: i,
  binding: Binding(i, o),
  validate: fn(o) -> Result(Nil, runtime.CallbackFailure),
  external_failure: fn(o) -> Bool,
) -> http.Outcome(o) {
  case binding.prepare(input) {
    Error(failure) -> http.Failed(state, http.Callback(failure))
    Ok(Completed(value)) ->
      case external_failure(value) {
        False ->
          http.Failed(
            state,
            http.Callback(runtime.CallbackFailure(
              "prepare completed requires a declared external failure",
            )),
          )
        True ->
          case validate(value) {
            Ok(_) -> http.Completed(state, value)
            Error(failure) -> http.Failed(state, http.Callback(failure))
          }
      }
    Ok(Ready(attempt)) ->
      http.dispatch(
        state,
        attempt,
        fn(response, provenance, effect) {
          use value <- result.try(binding.decode(response, provenance, effect))
          use _ <- result.try(validate(value))
          Ok(value)
        },
        binding.ports,
      )
  }
}
