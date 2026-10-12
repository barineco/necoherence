// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list

/// A request value: a payload of the declared input type together with the
/// field names present on it.
pub type Request(req) {
  Request(payload: req, fields: List(String))
}

/// Declaration whose output settles at the call itself.
pub type Immediate(req, prd) {
  Immediate(identity: String, required: List(String), output: fn(req) -> prd)
}

/// Declaration whose issuance returns a slot; the reply is a later
/// observation.
pub type Deferred(req, slot) {
  Deferred(identity: String, required: List(String), output: fn(req) -> slot)
}

/// Declared failure when the request lacks required field names.
pub type ProjectionFailed {
  ProjectionFailed(declaration: String, fields: List(String))
}

/// What a boundary failure carries: the query sent, the reply shape
/// expected, and the observation the judgment was actually made against.
pub type BoundaryDiagnosis(outbound, expectation, observed) {
  BoundaryDiagnosis(
    outbound: outbound,
    expectation: expectation,
    observed: observed,
  )
}

/// Closed sum of a settled output and a projection failure.
pub type CallResult(a) {
  CallOk(a)
  CallFailed(ProjectionFailed)
}

/// Names in `required` that `present` does not carry.
fn missing(required: List(String), present: List(String)) -> List(String) {
  list.filter(required, fn(name) { !list.contains(present, name) })
}

/// Build an immediate declaration from an explicit required-name list.
pub fn immediate_of(
  identity: String,
  required: List(String),
  output: fn(req) -> prd,
) -> Immediate(req, prd) {
  Immediate(identity, required, output)
}

/// Build a deferred declaration from an explicit required-name list.
pub fn deferred_of(
  identity: String,
  required: List(String),
  output: fn(req) -> slot,
) -> Deferred(req, slot) {
  Deferred(identity, required, output)
}

/// Call an immediate declaration: match field names, then apply `output` to
/// the payload.
pub fn io(
  declaration: Immediate(req, prd),
  request: Request(req),
) -> CallResult(prd) {
  case missing(declaration.required, request.fields) {
    [] -> CallOk(declaration.output(request.payload))
    m -> CallFailed(ProjectionFailed(declaration.identity, m))
  }
}

/// Call a deferred declaration: match field names, then apply `output` to
/// the payload.
pub fn issue(
  declaration: Deferred(req, slot),
  request: Request(req),
) -> CallResult(slot) {
  case missing(declaration.required, request.fields) {
    [] -> CallOk(declaration.output(request.payload))
    m -> CallFailed(ProjectionFailed(declaration.identity, m))
  }
}
