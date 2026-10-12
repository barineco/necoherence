-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
Iterative call forms whose step-count upper bound is readable from the input.

Three declarations, `fold`, `recurse`, `closure`, each realized as an
`Immediate Req Prd` (the same closed call form `Call.lean` gives every
declared function): the request itself is what a caller's
`io` call projects, and `output` is the plain computable function that
carries out the run. `fold` applies a step a stated number of times;
`recurse` applies a step until it reports a settled state, requiring the
measure it also reports to strictly decrease each round; `closure` applies
a monotone step over a finite carrier until the accumulated list stops
growing. In all three the bound on how many rounds can happen is readable
from the request's own fields, or from the first round's own report,
before any further round runs: `count` for `fold`, the first round's own
measure for `recurse`, the carrier's length for `closure`. No caller-
supplied fuel argument exists anywhere in this module; every termination
argument is carried by the request or by the run itself.

Each round's step is called through `Call.io`, never applied directly, so a
round whose input fails to project returns as a declared branch of the
surrounding outcome, naming which round it was, rather than being folded
into the state itself. The field names a round's own input carries are
read from the request's own `stepFields`, an input field of every request
type here, so that the same `Req` a caller assembles for `io fold`,
`io recurse`, or `io closure` also names what an adapter in another
language would present on each round's call to `step`.
-/

import Necoherence.Call

namespace Necoherence

/-- A round's own progress measure, read from the step's output. -/
abbrev Measure := Nat

/-- Where, in a run of rounds, one round's own `io` projection failed. -/
structure StageProjectionFailed where
  position : Nat
  failure : ProjectionFailed
  deriving Repr

/-! ### fold: the bound is an input field -/

/-- Input to `fold`: a step declaration, its seed, how many rounds to run,
and the field names present on every round's own input to `step`. -/
structure FoldReq (S : Type) where
  step : Immediate S S
  seed : S
  count : Nat
  stepFields : List String

/-- Closed outcome of a fold run: the full history of settled rounds, or
the history up to the round whose projection failed. -/
inductive FoldOutcome (S : Type) where
  | trace : List S → FoldOutcome S
  | stopped : List S → StageProjectionFailed → FoldOutcome S

private def foldLoop (step : Immediate S S) (stepFields : List String) :
    Nat → S → List S → Nat → FoldOutcome S
  | 0, _, acc, _ => .trace acc.reverse
  | n + 1, state, acc, position =>
    match io step ⟨state, stepFields⟩ with
    | .ok next => foldLoop step stepFields n next (next :: acc) (position + 1)
    | .failed f =>
      .stopped acc.reverse ⟨position, f⟩

/-- Call `req.step` through `io`, `req.count` times from `req.seed`, using
`req.stepFields` as the field names present on every round's own input.
Stops at the first round whose `io` call returns `ProjectionFailed` and
reports that round's position; otherwise runs every round. -/
def foldOutput (req : FoldReq S) : FoldOutcome S :=
  foldLoop req.step req.stepFields req.count req.seed [req.seed] 0

/--
`fold`: given a step declaration, a seed, a round count, and the field
names present on every round's own input, runs `req.step` through `io` up
to `req.count` times and returns the trace of settled states, or the trace
up to whichever round's projection failed.
-/
def fold : Immediate (FoldReq S) (FoldOutcome S) :=
  immediateOf "necoherence.iteration.fold" ["step", "seed", "count", "stepFields"] foldOutput

/-- `fold` runs at most `count` rounds: the trace branch's history never
exceeds `count + 1` states (the seed plus one per round). -/
theorem foldLoop_trace_length (step : Immediate S S) (stepFields : List String) :
    ∀ n state acc position states, foldLoop step stepFields n state acc position = .trace states →
      states.length ≤ acc.length + n := by
  intro n
  induction n with
  | zero =>
    intro state acc position states h
    simp only [foldLoop] at h
    cases h
    simp
  | succ n ih =>
    intro state acc position states h
    simp only [foldLoop] at h
    cases hcall : io step ⟨state, stepFields⟩ with
    | ok next =>
      rw [hcall] at h
      have := ih next (next :: acc) (position + 1) states h
      simp at this
      omega
    | failed f =>
      rw [hcall] at h
      cases h

/-- `foldOutput` never returns more than `req.count + 1` states in its
trace. -/
theorem foldOutput_trace_bounded (req : FoldReq S)
    {states : List S} (h : foldOutput req = .trace states) :
    states.length ≤ req.count + 1 := by
  have hb := foldLoop_trace_length req.step req.stepFields req.count req.seed [req.seed] 0 states h
  simp only [List.length_cons, List.length_nil] at hb
  omega

/-! ### recurse: the bound is the first round's own measure -/

/-- Next state together with this round's own measure toward termination,
or the confirmed final state. -/
inductive StepOutcome (S : Type) where
  | advance : S → Measure → StepOutcome S
  | settled : S → StepOutcome S

/-- Input to `recurse`: a step declaration, its seed, and the field names
present on every round's own input to `step`. -/
structure RecurseReq (S : Type) where
  step : Immediate S (StepOutcome S)
  seed : S
  stepFields : List String

/-- Closed outcome of a recurse run. -/
inductive RecurseOutcome (S : Type) where
  | settled : S → Nat → RecurseOutcome S
  | didNotDecrease : Nat → S → Measure → Measure → RecurseOutcome S
  | projectionFailed : S → StageProjectionFailed → RecurseOutcome S

/-- Rounds after the first, once a strictly-decreasing bound is
established. `bound` is the ceiling this round's own measure must fall
under; the recursion terminates because `bound : Nat` strictly decreases on
every recursive call, witnessed by `h` at the call site. -/
private def recurseLoop (step : Immediate S (StepOutcome S)) (stepFields : List String)
    (state : S) (bound : Nat) (position : Nat) : RecurseOutcome S :=
  match io step ⟨state, stepFields⟩ with
  | .failed f => .projectionFailed state ⟨position, f⟩
  | .ok (.settled value) => .settled value position
  | .ok (.advance next measure) =>
    if h : measure < bound then
      recurseLoop step stepFields next measure (position + 1)
    else
      .didNotDecrease position next measure bound
termination_by bound
decreasing_by exact h

/-- Call `req.step` through `io` from `req.seed`, using `req.stepFields` as
the field names present on every round's own input, until it settles. The
first round sets the bound from its own reported measure; every round
after that must report a measure strictly less than the prior round's, or
the run returns `didNotDecrease` instead of continuing. A round whose `io`
call fails to project returns `projectionFailed` instead. No fuel argument
is required: a genuinely strictly-decreasing run of natural-number
measures cannot exceed its first measure in length, so the first round's
own report is the entire termination bound. -/
def recurseOutput (req : RecurseReq S) : RecurseOutcome S :=
  match io req.step ⟨req.seed, req.stepFields⟩ with
  | .failed f => .projectionFailed req.seed ⟨0, f⟩
  | .ok (.settled value) => .settled value 0
  | .ok (.advance next measure) => recurseLoop req.step req.stepFields next measure 1

/--
`recurse`: given a step declaration, a seed, and the field names present on
every round's own input, calls `req.step` through `io` from `req.seed`
until it settles, checking that each round's own measure strictly
decreases from the round before it.
-/
def recurse : Immediate (RecurseReq S) (RecurseOutcome S) :=
  immediateOf "necoherence.iteration.recurse" ["step", "seed", "stepFields"] recurseOutput

/-- A rejected round's reported measure is never strictly less than the
bound it was checked against: `didNotDecrease` only ever fires on a round
that failed the strict-decrease check. -/
theorem recurseLoop_did_not_decrease_ge (step : Immediate S (StepOutcome S))
    (stepFields : List String) :
    ∀ state bound position position' s' measure prevMeasure,
      recurseLoop step stepFields state bound position =
        .didNotDecrease position' s' measure prevMeasure →
      ¬ measure < prevMeasure := by
  intro state bound
  induction bound using Nat.strongRecOn generalizing state with
  | ind bound ih =>
    intro position position' s' measure prevMeasure h
    unfold recurseLoop at h
    cases hcall : io step ⟨state, stepFields⟩ with
    | failed f => rw [hcall] at h; simp only at h; cases h
    | ok outcome =>
      rw [hcall] at h
      cases outcome with
      | settled value => simp only at h; cases h
      | advance nextState m =>
        simp only at h
        split at h
        · rename_i hlt
          exact ih m hlt nextState (position + 1) position' s' measure prevMeasure h
        · rename_i hnlt
          injection h with h1 h2 h3 h4
          subst h3; subst h4
          exact hnlt

/-- `recurseOutput` never reports `didNotDecrease` against the very first
round's own measure: the first round only ever sets the bound, and every
later rejection is checked against a strictly earlier round's measure. -/
theorem recurseOutput_did_not_decrease_ge (req : RecurseReq S)
    {position' : Nat} {s' : S} {measure prevMeasure : Measure}
    (h : recurseOutput req = .didNotDecrease position' s' measure prevMeasure) :
    ¬ measure < prevMeasure := by
  unfold recurseOutput at h
  cases hcall : io req.step ⟨req.seed, req.stepFields⟩ with
  | failed f => rw [hcall] at h; simp only at h; cases h
  | ok outcome =>
    rw [hcall] at h
    cases outcome with
    | settled value => simp only at h; cases h
    | advance next measure0 =>
      simp only at h
      exact recurseLoop_did_not_decrease_ge req.step req.stepFields next measure0 1
        position' s' measure prevMeasure h

/-! ### closure: the bound is the carrier's length -/

/-- Input to a closure's step: the current accumulated subset of the
carrier, given as a list with no meaningful order or duplication. -/
structure ClosureState (T : Type) where
  elements : List T

/-- Input to `closure`: a monotone step declaration, its finite carrier, a
seed subset, and the field names present on every round's own input to
`step`. -/
structure ClosureReq (T : Type) where
  step : Immediate (ClosureState T) (List T)
  carrier : List T
  seed : List T
  stepFields : List String

/-- Closed outcome of a closure run. -/
inductive ClosureOutcome (T : Type) where
  | fixpoint : List T → Nat → ClosureOutcome T
  | violation : Nat → List T → List T → ClosureOutcome T
  | projectionFailed : List T → StageProjectionFailed → ClosureOutcome T

variable [DecidableEq T]

/-- Set equality on lists, ignoring order and duplication: mutual
inclusion. -/
def listSetEq (a b : List T) : Prop := a ⊆ b ∧ b ⊆ a

instance (a b : List T) : Decidable (listSetEq a b) := by unfold listSetEq; infer_instance

/-- The count of `carrier`'s own elements not yet accepted into `current`:
the closure's termination measure. -/
def residual (carrier current : List T) : Nat :=
  carrier.countP (fun x => decide (x ∉ current))

/-- Over any list, the count of elements a growing round's input fails to
accept is at least the count of elements the round's own output fails to
accept: accepting only ever removes elements from that count. -/
private theorem countP_not_contains_mono (l : List T) {current produced : List T}
    (hsub : current ⊆ produced) :
    l.countP (fun x => decide (x ∉ produced)) ≤ l.countP (fun x => decide (x ∉ current)) := by
  apply List.countP_mono_left
  intro x _ hx
  simp only [decide_eq_true_eq] at hx ⊢
  exact fun hc => hx (hsub hc)

/-- A witness element that `carrier` holds, that `produced` accepts, and
that `current` does not, strictly shrinks the not-yet-accepted count from
`current` to `produced`. -/
private theorem countP_not_contains_lt_of_witness :
    ∀ (carrier : List T) {current produced : List T}, current ⊆ produced →
      ∀ y, y ∈ carrier → y ∈ produced → y ∉ current →
        carrier.countP (fun x => decide (x ∉ produced)) <
          carrier.countP (fun x => decide (x ∉ current)) := by
  intro carrier
  induction carrier with
  | nil => intro current produced _ y hy; cases hy
  | cons a t ih =>
    intro current produced hsub y hy hyProduced hyCurrent
    rw [List.countP_cons, List.countP_cons]
    have hmono := countP_not_contains_mono t hsub
    rcases List.mem_cons.mp hy with rfl | hy'
    · have h1 : (if decide (y ∉ produced) then (1 : Nat) else 0) = 0 := by simp [hyProduced]
      have h2 : (if decide (y ∉ current) then (1 : Nat) else 0) = 1 := by simp [hyCurrent]
      omega
    · have hlt := ih hsub y hy' hyProduced hyCurrent
      have hac : (if decide (a ∉ produced) then (1 : Nat) else 0) ≤
          (if decide (a ∉ current) then (1 : Nat) else 0) := by
        by_cases hca : a ∈ current
        · have hpa : a ∈ produced := hsub hca
          rw [decide_eq_false (by simp [hpa]), decide_eq_false (by simp [hca])]
          decide
        · by_cases hpa : a ∈ produced
          · rw [decide_eq_false (by simp [hpa]), decide_eq_true (by simp [hca])]
            decide
          · rw [decide_eq_true (by simp [hpa]), decide_eq_true (by simp [hca])]
            decide
      omega

/-- A round that extends its own input (`current ⊆ produced`), stays
within the carrier (`produced ⊆ carrier`), and is not itself set-equal to
`current` strictly reduces the residual. -/
theorem residual_lt {carrier current produced : List T}
    (hsub : current ⊆ produced) (hbound : produced ⊆ carrier)
    (hnot : ¬ listSetEq produced current) :
    residual carrier produced < residual carrier current := by
  have hnotSub : ¬ produced ⊆ current := fun hp => hnot ⟨hp, hsub⟩
  have hex : ∃ y, y ∈ produced ∧ y ∉ current :=
    Decidable.byContradiction fun h =>
      hnotSub fun y hy =>
        Decidable.byContradiction fun hyc => h ⟨y, hy, hyc⟩
  obtain ⟨y, hyProduced, hyCurrent⟩ := hex
  exact countP_not_contains_lt_of_witness carrier hsub y (hbound hyProduced) hyProduced hyCurrent

/-- A growing round, once accepted by the `if`/`else if` guards below, has
its residual strictly decrease: this is the proof obligation `closureLoop`
discharges at every recursive call. -/
private def closureLoop (step : Immediate (ClosureState T) (List T)) (stepFields : List String)
    (carrier : List T) (current : List T) (position : Nat) : ClosureOutcome T :=
  match io step ⟨⟨current⟩, stepFields⟩ with
  | .failed f => .projectionFailed current ⟨position, f⟩
  | .ok produced =>
    if heq : listSetEq produced current then
      .fixpoint current position
    else if hext : current ⊆ produced ∧ produced ⊆ carrier then
      closureLoop step stepFields carrier produced (position + 1)
    else
      .violation position current produced
termination_by residual carrier current
decreasing_by exact residual_lt hext.1 hext.2 heq

/-- Call `req.step` through `io` from `req.seed`, using `req.stepFields` as
the field names present on every round's own input, until the set stops
growing. Each round's output must be a superset of that round's own input
and a subset of `req.carrier`; either failing returns as a declared
branch. No fuel argument is required: the count of carrier elements not
yet in the accumulated set strictly decreases on every round that grows
it, so the run cannot outlast `req.carrier`'s own length. -/
def closureOutput (req : ClosureReq T) : ClosureOutcome T :=
  closureLoop req.step req.stepFields req.carrier req.seed 0

/--
`closure`: given a monotone step declaration, a finite carrier, a seed
subset, and the field names present on every round's own input, calls
`req.step` through `io` from `req.seed` until the accumulated subset of
`req.carrier` stops growing.
-/
def closure : Immediate (ClosureReq T) (ClosureOutcome T) :=
  immediateOf "necoherence.iteration.closure" ["step", "carrier", "seed", "stepFields"] closureOutput

/-- The round number a `closureLoop` outcome reports. -/
private def closureOutcomePosition : ClosureOutcome T → Nat
  | .fixpoint _ p => p
  | .violation p _ _ => p
  | .projectionFailed _ st => st.position

/-- `closureLoop` never reports a round number earlier than the one it
started from: recursion only moves the reported round forward. -/
theorem closureLoop_position_ge (step : Immediate (ClosureState T) (List T))
    (stepFields : List String) (carrier : List T) :
    ∀ current position,
      position ≤ closureOutcomePosition (closureLoop step stepFields carrier current position) := by
  have key : ∀ n current, residual carrier current = n →
      ∀ position, position ≤ closureOutcomePosition (closureLoop step stepFields carrier current position) := by
    intro n
    induction n using Nat.strongRecOn with
    | ind n ih =>
      intro current hn position
      unfold closureLoop
      cases hcall : io step ⟨⟨current⟩, stepFields⟩ with
      | failed f => simp [closureOutcomePosition]
      | ok produced =>
        simp only
        by_cases heq : listSetEq produced current
        · rw [dif_pos heq]; simp [closureOutcomePosition]
        · rw [dif_neg heq]
          by_cases hext : current ⊆ produced ∧ produced ⊆ carrier
          · rw [dif_pos hext]
            have hlt := residual_lt hext.1 hext.2 heq
            rw [hn] at hlt
            exact Nat.le_trans (Nat.le_succ position)
              (ih (residual carrier produced) hlt produced rfl (position + 1))
          · rw [dif_neg hext]; simp [closureOutcomePosition]
  intro current position
  exact key (residual carrier current) current rfl position

/-- A fixpoint round's accepted set is unchanged from the round before it
(as a set, ignoring list order and duplication). -/
theorem closureLoop_fixpoint_stable (step : Immediate (ClosureState T) (List T))
    (stepFields : List String) (carrier : List T) (current : List T)
    {position : Nat} {result : List T}
    (h : closureLoop step stepFields carrier current position = .fixpoint result position) :
    ∃ produced, io step ⟨⟨current⟩, stepFields⟩ = .ok produced ∧
      listSetEq produced current ∧ result = current := by
  unfold closureLoop at h
  cases hcall : io step ⟨⟨current⟩, stepFields⟩ with
  | failed f => rw [hcall] at h; cases h
  | ok produced =>
    rw [hcall] at h
    simp only at h
    by_cases heq : listSetEq produced current
    · rw [dif_pos heq] at h
      injection h with h1 h2
      exact ⟨produced, rfl, heq, h1.symm⟩
    · rw [dif_neg heq] at h
      by_cases hext : current ⊆ produced ∧ produced ⊆ carrier
      · rw [dif_pos hext] at h
        exfalso
        have hlt := residual_lt hext.1 hext.2 heq
        have hge := closureLoop_position_ge step stepFields carrier produced (position + 1)
        rw [h] at hge
        simp only [closureOutcomePosition] at hge
        omega
      · rw [dif_neg hext] at h
        cases h

/-- A growing round's produced set strictly extends the round's own input
(as a set): every accepted element of `current` is carried into `produced`,
and a violation is returned whenever `current` is not a subset of
`produced` or `produced` is not a subset of `carrier`. -/
theorem closureLoop_violation_extensivity_or_bound
    (step : Immediate (ClosureState T) (List T)) (stepFields : List String)
    (carrier : List T) (current : List T)
    {position : Nat} {produced : List T}
    (h : closureLoop step stepFields carrier current position = .violation position current produced) :
    io step ⟨⟨current⟩, stepFields⟩ = .ok produced ∧
      ¬ listSetEq produced current ∧
      ¬ (current ⊆ produced ∧ produced ⊆ carrier) := by
  unfold closureLoop at h
  cases hcall : io step ⟨⟨current⟩, stepFields⟩ with
  | failed f => rw [hcall] at h; cases h
  | ok result =>
    rw [hcall] at h
    simp only at h
    by_cases heq : listSetEq result current
    · rw [dif_pos heq] at h; cases h
    · rw [dif_neg heq] at h
      by_cases hext : current ⊆ result ∧ result ⊆ carrier
      · rw [dif_pos hext] at h
        exfalso
        have hlt := residual_lt hext.1 hext.2 heq
        have hge := closureLoop_position_ge step stepFields carrier result (position + 1)
        rw [h] at hge
        simp only [closureOutcomePosition] at hge
        omega
      · rw [dif_neg hext] at h
        injection h with h1 h2 h3
        subst h3
        exact ⟨rfl, heq, hext⟩

/-- `fold`, applied through `io`, agrees with `foldOutput` on the payload
whenever `fold.required` is satisfied. -/
theorem io_fold_eq (request : Request (FoldReq S))
    (h : missing (fold (S := S)).required request.fields = []) :
    io fold request = .ok (foldOutput request.payload) := by
  exact io_applies_output fold request h

/-- `recurse`, applied through `io`, agrees with `recurseOutput` on the
payload whenever `recurse.required` is satisfied. -/
theorem io_recurse_eq (request : Request (RecurseReq S))
    (h : missing (recurse (S := S)).required request.fields = []) :
    io recurse request = .ok (recurseOutput request.payload) := by
  exact io_applies_output recurse request h

/-- `closure`, applied through `io`, agrees with `closureOutput` on the
payload whenever `closure.required` is satisfied. -/
theorem io_closure_eq (request : Request (ClosureReq T))
    (h : missing (closure (T := T)).required request.fields = []) :
    io closure request = .ok (closureOutput request.payload) := by
  exact io_applies_output closure request h

#print axioms foldLoop_trace_length
#print axioms foldOutput_trace_bounded
#print axioms recurseLoop_did_not_decrease_ge
#print axioms recurseOutput_did_not_decrease_ge
#print axioms residual_lt
#print axioms closureLoop_position_ge
#print axioms closureLoop_fixpoint_stable
#print axioms closureLoop_violation_extensivity_or_bound
#print axioms io_fold_eq
#print axioms io_recurse_eq
#print axioms io_closure_eq

end Necoherence
