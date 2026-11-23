// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_signature_http as http

type Outcome {
  Success
  ExternalFailure
}

fn outcome_id(outcome: Outcome) -> String {
  case outcome {
    Success -> "success"
    ExternalFailure -> "external"
  }
}

fn binding(
  prepared: Result(http.PreparedInput(Outcome), runtime.ExecutionFailure),
) -> http.Binding(Nil, Outcome) {
  http.Binding(
    fn(_) { prepared },
    fn(_, _, _) { Error(runtime.InvalidPlan("unused")) },
    outcome_id,
  )
}

pub fn declared_external_completion_is_prepared_test() {
  let assert Ok(http.Completed(ExternalFailure)) =
    http.prepare(Nil, binding(Ok(http.Completed(ExternalFailure))), ["external"])
  Nil
}

pub fn undeclared_completion_is_an_execution_failure_test() {
  let assert Error(runtime.InvalidPlan("undeclared external completion")) =
    http.prepare(Nil, binding(Ok(http.Completed(Success))), ["external"])
  Nil
}

pub fn preparation_failure_is_preserved_test() {
  let failure = runtime.ProviderCoverage("missing provider")
  let assert Error(returned) = http.prepare(Nil, binding(Error(failure)), [])
  let assert True = returned == failure
}
