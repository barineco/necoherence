-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
Closed bounded single-owner transition.

One input is evaluated to a closed result in a single call. The caller's
`advance` function may ask for the same input again, but only a positive
number of times, and accumulated outputs never exceed a declared capacity.
-/

namespace Necoherence

/-- A positive bound on how many times one input may be reprocessed. -/
structure PositiveLimit where
  value : Nat
  positive : 0 < value
  deriving Repr

/-- A bound on how many outputs one transition may accumulate. -/
structure Capacity where
  value : Nat
  deriving Repr, DecidableEq

/-- What one application of `advance` decided about the input it was given. -/
inductive Consumption (σ ω : Type) where
  | consumed (state : σ) (outputs : List ω)
  | reprocess (state : σ) (outputs : List ω)

namespace Consumption

def state : Consumption σ ω → σ
  | .consumed s _ => s
  | .reprocess s _ => s

def outputs : Consumption σ ω → List ω
  | .consumed _ o => o
  | .reprocess _ o => o

def isConsumed : Consumption σ ω → Bool
  | .consumed _ _ => true
  | .reprocess _ _ => false

end Consumption

/-- Why a transition stopped without consuming its input. -/
inductive StepFailure where
  | reprocessLimitExhausted (applications : Nat)
  | capacityExceeded (capacity attempted : Nat)
  deriving Repr, DecidableEq

/-- The closed result of one transition. -/
inductive StepTransition (σ ω : Type) where
  | settled (state : σ) (outputs : List ω) (applications : Nat)
  | failed (state : σ) (outputs : List ω) (failure : StepFailure)

namespace StepTransition

def outputs : StepTransition σ ω → List ω
  | .settled _ o _ => o
  | .failed _ o _ => o

end StepTransition

private def accumulate (acc : List ω) (produced : List ω) : List ω :=
  produced.reverse ++ acc

private def loop (advance : σ → ι → Consumption σ ω) (input : ι)
    (capacity : Nat) : Nat → σ → List ω → Nat → StepTransition σ ω
  | 0, state, acc, applications =>
      .failed state acc.reverse (.reprocessLimitExhausted applications)
  | fuel + 1, state, acc, applications =>
      let decision := advance state input
      let next := decision.state
      let acc' := accumulate acc decision.outputs
      if acc'.length > capacity then
        .failed next acc'.reverse (.capacityExceeded capacity acc'.length)
      else if decision.isConsumed then
        .settled next acc'.reverse (applications + 1)
      else
        loop advance input capacity fuel next acc' (applications + 1)

/--
Evaluate one input to a closed result in a single call.

`advance` is applied to the same input until it reports `consumed`, at most
`limit.value` times. Outputs keep the order in which `advance` produced them
and never exceed `capacity.value`.
-/
def step (state : σ) (input : ι) (advance : σ → ι → Consumption σ ω)
    (limit : PositiveLimit) (capacity : Capacity) : StepTransition σ ω :=
  loop advance input capacity.value limit.value state [] 0

/-- Every transition returns one of exactly two closed results. -/
theorem step_result_closed (result : StepTransition σ ω) :
    (∃ s o n, result = .settled s o n) ∨ (∃ s o f, result = .failed s o f) := by
  cases result with
  | settled s o n => exact Or.inl ⟨s, o, n, rfl⟩
  | failed s o f => exact Or.inr ⟨s, o, f, rfl⟩

private theorem loop_settled_bounded
    (advance : σ → ι → Consumption σ ω) (input : ι) (capacity : Nat) :
    ∀ fuel state acc applications s o n,
      acc.length ≤ capacity →
      loop advance input capacity fuel state acc applications = .settled s o n →
      o.length ≤ capacity := by
  intro fuel
  induction fuel with
  | zero =>
      intro state acc applications s o n _ h
      simp [loop] at h
  | succ fuel ih =>
      intro state acc applications s o n hacc h
      simp only [loop] at h
      split at h
      · simp at h
      · rename_i hcap
        split at h
        · injection h with _ ho _
          subst ho
          simp [List.length_reverse]
          omega
        · exact ih _ _ _ _ _ _ (by omega) h

/-- A settled transition never accumulates more outputs than its capacity. -/
theorem step_bounded_capacity (state : σ) (input : ι)
    (advance : σ → ι → Consumption σ ω) (limit : PositiveLimit)
    (capacity : Capacity) {s : σ} {o : List ω} {n : Nat}
    (h : step state input advance limit capacity = .settled s o n) :
    o.length ≤ capacity.value :=
  loop_settled_bounded advance input capacity.value limit.value state [] 0 s o n
    (by simp) h

/-- Consuming the input immediately settles after exactly one application. -/
theorem step_consumed_once (state : σ) (input : ι)
    (advance : σ → ι → Consumption σ ω) (fuel : Nat)
    (capacity : Capacity) (next : σ) (produced : List ω)
    (hadvance : advance state input = .consumed next produced)
    (hcapacity : produced.length ≤ capacity.value) :
    step state input advance ⟨fuel + 1, by omega⟩ capacity =
      .settled next produced 1 := by
  have hlen : ¬ (accumulate [] produced).length > capacity.value := by
    simp only [accumulate, List.append_nil, List.length_reverse]
    omega
  simp only [step, loop, hadvance, Consumption.state, Consumption.outputs,
    Consumption.isConsumed]
  rw [if_neg hlen]
  simp [accumulate]

/-- Producing no output still settles, even when capacity is zero. -/
theorem step_zero_output (state : σ) (input : ι)
    (advance : σ → ι → Consumption σ ω) (fuel : Nat)
    (next : σ) (hadvance : advance state input = .consumed next ([] : List ω)) :
    step state input advance ⟨fuel + 1, by omega⟩ ⟨0⟩ = .settled next [] 1 := by
  simp only [step, loop, hadvance, Consumption.state, Consumption.outputs,
    Consumption.isConsumed, accumulate]
  simp

/-- Exhausting the reprocess limit reports the number of applications made. -/
theorem step_reprocess_limit_exhausted (state : σ) (input : ι)
    (advance : σ → ι → Consumption σ ω) (capacity : Capacity)
    (hadvance : advance state input = .reprocess state ([] : List ω)) :
    step state input advance ⟨1, by omega⟩ capacity =
      .failed state [] (.reprocessLimitExhausted 1) := by
  simp only [step, loop, hadvance, Consumption.state, Consumption.outputs,
    Consumption.isConsumed, accumulate]
  simp

end Necoherence
