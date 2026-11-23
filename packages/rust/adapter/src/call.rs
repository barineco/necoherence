// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Calls whose declarations state their required input fields.
//! `io` / `issue` take a declaration and a dynamically field-checked request.

use std::fmt;
use std::marker::PhantomData;

/// A request: a payload together with the field names present on it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request<Req> {
    pub payload: Req,
    pub fields: Vec<String>,
}

/// Declaration of a function whose output settles at the call itself.
pub struct Immediate<Req, Prd, F> {
    pub identity: String,
    pub required: Vec<String>,
    output: F,
    _request: PhantomData<fn(&Req) -> Prd>,
}

impl<Req, Prd, F> fmt::Debug for Immediate<Req, Prd, F> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Immediate")
            .field("identity", &self.identity)
            .field("required", &self.required)
            .finish_non_exhaustive()
    }
}

/// Declaration of a function whose eventual reply may stay silent.
pub struct Deferred<Req, Slot, F> {
    pub identity: String,
    pub required: Vec<String>,
    output: F,
    _request: PhantomData<fn(&Req) -> Slot>,
}

impl<Req, Slot, F> fmt::Debug for Deferred<Req, Slot, F> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Deferred")
            .field("identity", &self.identity)
            .field("required", &self.required)
            .finish_non_exhaustive()
    }
}

/// Declared failure when a request lacks required field names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectionFailed {
    pub declaration: String,
    pub fields: Vec<String>,
}

/// Closed sum of a settled output and a projection failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CallResult<Prd> {
    Ok(Prd),
    Failed(ProjectionFailed),
}

/// What a boundary failure carries: sent, expected, and observed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BoundaryDiagnosis<Outbound, Expectation, Observed> {
    pub outbound: Outbound,
    pub expectation: Expectation,
    pub observed: Observed,
}

/// Names in `required` that `present` does not carry.
pub fn missing(required: &[String], present: &[String]) -> Vec<String> {
    required
        .iter()
        .filter(|name| !present.contains(name))
        .cloned()
        .collect()
}

/// Build an [`Immediate`] declaration from an explicit required-name list.
pub fn immediate_of<Req, Prd, F>(
    identity: impl Into<String>,
    required: Vec<String>,
    output: F,
) -> Immediate<Req, Prd, F>
where
    F: Fn(&Req) -> Prd,
{
    Immediate {
        identity: identity.into(),
        required,
        output,
        _request: PhantomData,
    }
}

/// Build a [`Deferred`] declaration from an explicit required-name list.
pub fn deferred_of<Req, Slot, F>(
    identity: impl Into<String>,
    required: Vec<String>,
    output: F,
) -> Deferred<Req, Slot, F>
where
    F: Fn(&Req) -> Slot,
{
    Deferred {
        identity: identity.into(),
        required,
        output,
        _request: PhantomData,
    }
}

/// Call an immediate declaration: match field names, then apply `output`.
pub fn io<Req, Prd, F>(f: &Immediate<Req, Prd, F>, x: &Request<Req>) -> CallResult<Prd>
where
    F: Fn(&Req) -> Prd,
{
    let missing_fields = missing(&f.required, &x.fields);
    if missing_fields.is_empty() {
        CallResult::Ok((f.output)(&x.payload))
    } else {
        CallResult::Failed(ProjectionFailed {
            declaration: f.identity.clone(),
            fields: missing_fields,
        })
    }
}

/// Call a deferred declaration: match field names, then apply `output`.
pub fn issue<Req, Slot, F>(f: &Deferred<Req, Slot, F>, x: &Request<Req>) -> CallResult<Slot>
where
    F: Fn(&Req) -> Slot,
{
    let missing_fields = missing(&f.required, &x.fields);
    if missing_fields.is_empty() {
        CallResult::Ok((f.output)(&x.payload))
    } else {
        CallResult::Failed(ProjectionFailed {
            declaration: f.identity.clone(),
            fields: missing_fields,
        })
    }
}
