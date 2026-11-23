-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT



namespace Necoherence

/-- A request value: a payload of the declared input type together with
the field names present on it. Projection checks the field-name list; the
payload itself is opaque to `io` and `issue`. -/
structure Request (Req : Type) where
  payload : Req
  fields : List String
  deriving DecidableEq, Repr

/-- Declaration whose output settles at the call itself. -/
structure Immediate (Req Prd : Type) where
  identity : String
  required : List String
  output : Req → Prd

/-- Declaration whose issuance returns a slot; the reply is a later observation. -/
structure Deferred (Req Slot : Type) where
  identity : String
  required : List String
  output : Req → Slot

/-- Declared failure when the request lacks required field names. -/
structure ProjectionFailed where
  declaration : String
  fields : List String
  deriving DecidableEq, Repr

/-- What a boundary failure carries: the query sent, the reply shape
expected, and the observation the judgment was actually made against. -/
structure BoundaryDiagnosis (Outbound Expectation Observed : Type) where
  outbound : Outbound
  expectation : Expectation
  observed : Observed

/-- Closed sum of a settled output and a projection failure. -/
inductive CallResult (α : Type) where
  | ok : α → CallResult α
  | failed : ProjectionFailed → CallResult α

/-- Names in `required` that `present` does not carry. -/
def missing (required present : List String) : List String :=
  required.filter (fun n => !present.contains n)

/-- Build an immediate declaration from an explicit required-name list. -/
def immediateOf (identity : String) (required : List String)
    (output : Req → Prd) : Immediate Req Prd :=
  ⟨identity, required, output⟩

/-- Build a deferred declaration from an explicit required-name list. -/
def deferredOf (identity : String) (required : List String)
    (output : Req → Slot) : Deferred Req Slot :=
  ⟨identity, required, output⟩

/-- Call an immediate declaration: match field names, then apply `output` to the payload. -/
def io (f : Immediate Req Prd) (x : Request Req) : CallResult Prd :=
  match missing f.required x.fields with
  | [] => .ok (f.output x.payload)
  | m => .failed ⟨f.identity, m⟩

/-- Call a deferred declaration: match field names, then apply `output` to the payload. -/
def issue (f : Deferred Req Slot) (x : Request Req) : CallResult Slot :=
  match missing f.required x.fields with
  | [] => .ok (f.output x.payload)
  | m => .failed ⟨f.identity, m⟩

/-- When every required name is present, `io` applies the declaration's `output`. -/
theorem io_applies_output (f : Immediate Req Prd) (x : Request Req)
    (h : missing f.required x.fields = []) :
    io f x = .ok (f.output x.payload) := by
  simp [io, h]

/-- When at least one required name is absent, `io` returns that failure branch. -/
theorem io_fails_when_missing (f : Immediate Req Prd) (x : Request Req)
    (h : missing f.required x.fields ≠ []) :
    io f x = .failed ⟨f.identity, missing f.required x.fields⟩ := by
  unfold io
  cases hmiss : missing f.required x.fields with
  | nil =>
    exact False.elim (h hmiss)
  | cons head tail =>
    rfl

#print axioms io_applies_output
#print axioms io_fails_when_missing

end Necoherence
