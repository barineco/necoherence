// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

// Calls whose declarations state their required input fields. Projection checks
// field-name presence only against a Request<Req>'s carried field names.

export interface Request<Req> {
  readonly payload: Req;
  readonly fields: readonly string[];
}

export function requestOf<Req>(payload: Req, fields: readonly string[]): Request<Req> {
  return Object.freeze({ payload, fields: Object.freeze([...fields]) });
}

export interface Immediate<Req, Prd> {
  readonly identity: string;
  readonly required: readonly string[];
  readonly output: (req: Req) => Prd;
}

export interface Deferred<Req, Slot> {
  readonly identity: string;
  readonly required: readonly string[];
  readonly output: (req: Req) => Slot;
}

export interface ProjectionFailed {
  readonly declaration: string;
  readonly fields: readonly string[];
}

export function projectionFailed(
  declaration: string,
  fields: readonly string[]
): ProjectionFailed {
  return Object.freeze({ declaration, fields: Object.freeze([...fields]) });
}

export interface BoundaryDiagnosis<Outbound, Expectation, Observed> {
  readonly outbound: Outbound;
  readonly expectation: Expectation;
  readonly observed: Observed;
}

export function boundaryDiagnosis<Outbound, Expectation, Observed>(
  outbound: Outbound,
  expectation: Expectation,
  observed: Observed
): BoundaryDiagnosis<Outbound, Expectation, Observed> {
  return Object.freeze({ outbound, expectation, observed });
}

export function immediateOf<Req, Prd>(
  identity: string,
  required: readonly string[],
  output: (req: Req) => Prd
): Immediate<Req, Prd> {
  return Object.freeze({ identity, required: Object.freeze([...required]), output });
}

export function deferredOf<Req, Slot>(
  identity: string,
  required: readonly string[],
  output: (req: Req) => Slot
): Deferred<Req, Slot> {
  return Object.freeze({ identity, required: Object.freeze([...required]), output });
}

function missing(required: readonly string[], present: readonly string[]): readonly string[] {
  return required.filter((name) => !present.includes(name));
}

export interface CallOk<A> {
  readonly tag: "Ok";
  readonly value: A;
}

export interface CallFailed {
  readonly tag: "Failed";
  readonly failure: ProjectionFailed;
}

export type CallResult<A> = CallOk<A> | CallFailed;

function callOk<A>(value: A): CallOk<A> {
  return Object.freeze({ tag: "Ok", value });
}

function callFailed(failure: ProjectionFailed): CallFailed {
  return Object.freeze({ tag: "Failed", failure });
}

export function io<Req, Prd>(f: Immediate<Req, Prd>, x: Request<Req>): CallResult<Prd> {
  const m = missing(f.required, x.fields);
  if (m.length > 0) {
    return callFailed(projectionFailed(f.identity, m));
  }
  return callOk(f.output(x.payload));
}

export function issue<Req, Slot>(f: Deferred<Req, Slot>, x: Request<Req>): CallResult<Slot> {
  const m = missing(f.required, x.fields);
  if (m.length > 0) {
    return callFailed(projectionFailed(f.identity, m));
  }
  return callOk(f.output(x.payload));
}
