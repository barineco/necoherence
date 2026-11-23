// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import necoherence/network_effect as network
import necoherence/semantic_generation_runtime as runtime

pub type PreparedInput(o) {
  Ready(input: network.AttemptInput)
  Completed(value: o)
}

pub type Binding(i, o) {
  Binding(
    prepare: fn(i) -> Result(PreparedInput(o), runtime.ExecutionFailure),
    decode: fn(
      network.RawHttpResponse,
      network.HeaderProvenance,
      network.EffectStatus,
    ) -> Result(o, runtime.ExecutionFailure),
    outcome_id: fn(o) -> String,
  )
}

pub fn prepare(
  input: i,
  binding: Binding(i, o),
  external_failures: List(String),
) -> Result(PreparedInput(o), runtime.ExecutionFailure) {
  case binding.prepare(input) {
    Error(failure) -> Error(failure)
    Ok(Completed(value)) ->
      case list.contains(external_failures, binding.outcome_id(value)) {
        False -> Error(runtime.InvalidPlan("undeclared external completion"))
        True -> Ok(Completed(value))
      }
    Ok(Ready(attempt)) -> Ok(Ready(attempt))
  }
}
