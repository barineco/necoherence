-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT



import Necoherence.Core

namespace Necoherence

/--
Identity of a fact namespace. Matches `ResourceId`'s domain separation:
`kind` separates one domain from another, `name` is that domain's own name.
-/
structure Namespace where
  kind : String
  name : String
  deriving Repr, DecidableEq

structure FactId where
  value : Nat
  deriving Repr, DecidableEq

/-- One-hop provenance: the FactIds that immediately triggered production. -/
structure Provenance where
  triggeredBy : List FactId
  deriving Repr, DecidableEq

/-- Field `space` stands for the reserved Lean keyword `namespace`. -/
structure Identity where
  space : Namespace
  provenance : Provenance
  deriving Repr, DecidableEq

structure Fact where
  identity : Identity
  deriving Repr, DecidableEq

abbrev FactSet := List Fact

namespace FactSet

/-- Membership by Identity equality. -/
def contains (facts : FactSet) (f : Fact) : Bool :=
  facts.any (fun g => g.identity = f.identity)

end FactSet

structure CellRule where
  requirements : List Namespace
  produces : Namespace
  deriving Repr, DecidableEq

def hasSpace (facts : FactSet) (ns : Namespace) : Bool :=
  facts.any (fun f => f.identity.space = ns)

def satisfied (facts : FactSet) (reqs : List Namespace) : Bool :=
  reqs.all (fun ns => hasSpace facts ns)

/--
Index of the first fact whose space equals `ns`, counting from `start`.
If none match, returns `start + facts.length` (unused when `hasSpace` holds).
-/
def findFirstIndexFrom (facts : FactSet) (ns : Namespace) (start : Nat) : Nat :=
  match facts with
  | [] => start
  | f :: fs =>
    if f.identity.space = ns then start
    else findFirstIndexFrom fs ns (start + 1)

def findFirstIndex (facts : FactSet) (ns : Namespace) : Nat :=
  findFirstIndexFrom facts ns 0

/--
Deterministic provenance: for each requirement in order, take the list
index of the first fact whose `space` matches that requirement, wrapped
as `FactId`. Indices are positions in the input `FactSet`.
-/
def triggerIds (facts : FactSet) (reqs : List Namespace) : List FactId :=
  reqs.map (fun ns => ⟨findFirstIndex facts ns⟩)

def producedFact (facts : FactSet) (rule : CellRule) : Fact :=
  ⟨⟨rule.produces, ⟨triggerIds facts rule.requirements⟩⟩⟩

def fire (facts : FactSet) (rule : CellRule) : FactSet :=
  if satisfied facts rule.requirements then
    let neu := producedFact facts rule
    if FactSet.contains facts neu then facts else facts ++ [neu]
  else
    facts

def derive (facts : FactSet) (rules : List CellRule) : FactSet :=
  rules.foldl fire facts



theorem contains_append_left (facts extra : FactSet) (f : Fact)
    (h : FactSet.contains facts f = true) :
    FactSet.contains (facts ++ extra) f = true := by
  simp only [FactSet.contains, List.any_append] at h ⊢
  rw [Bool.or_eq_true]
  exact Or.inl h

theorem contains_append_right (facts : FactSet) (f : Fact) :
    FactSet.contains (facts ++ [f]) f = true := by
  simp [FactSet.contains]

theorem hasSpace_append_left (facts extra : FactSet) (ns : Namespace)
    (h : hasSpace facts ns = true) :
    hasSpace (facts ++ extra) ns = true := by
  simp only [hasSpace, List.any_append] at h ⊢
  rw [Bool.or_eq_true]
  exact Or.inl h

theorem satisfied_append_left (facts extra : FactSet) (reqs : List Namespace)
    (h : satisfied facts reqs = true) :
    satisfied (facts ++ extra) reqs = true := by
  simp only [satisfied, List.all_eq_true] at h ⊢
  intro ns hns
  exact hasSpace_append_left facts extra ns (h ns hns)

theorem findFirstIndexFrom_append (facts extra : FactSet) (ns : Namespace)
    (start : Nat) (h : hasSpace facts ns = true) :
    findFirstIndexFrom (facts ++ extra) ns start =
      findFirstIndexFrom facts ns start := by
  induction facts generalizing start with
  | nil =>
    simp only [hasSpace, List.any_nil] at h
    exact (Bool.false_ne_true h).elim
  | cons f fs ih =>
    by_cases hf : f.identity.space = ns
    · simp [findFirstIndexFrom, hf]
    · simp [findFirstIndexFrom, hf]
      have hfs : hasSpace fs ns = true := by
        simp only [hasSpace, List.any_cons] at h
        have hdec : decide (f.identity.space = ns) = false :=
          decide_eq_false hf
        simp only [hdec, Bool.false_or] at h
        exact h
      exact ih (start + 1) hfs

theorem findFirstIndex_append (facts extra : FactSet) (ns : Namespace)
    (h : hasSpace facts ns = true) :
    findFirstIndex (facts ++ extra) ns = findFirstIndex facts ns := by
  simp only [findFirstIndex]
  exact findFirstIndexFrom_append facts extra ns 0 h

theorem triggerIds_append (facts extra : FactSet) (reqs : List Namespace)
    (h : satisfied facts reqs = true) :
    triggerIds (facts ++ extra) reqs = triggerIds facts reqs := by
  simp only [triggerIds]
  refine List.map_congr_left ?_
  intro ns hns
  have hspace : hasSpace facts ns = true := by
    simp only [satisfied, List.all_eq_true] at h
    exact h ns hns
  congr 1
  exact findFirstIndex_append facts extra ns hspace

theorem producedFact_append (facts extra : FactSet) (rule : CellRule)
    (h : satisfied facts rule.requirements = true) :
    producedFact (facts ++ extra) rule = producedFact facts rule := by
  simp only [producedFact, triggerIds_append facts extra rule.requirements h]



theorem fire_monotone (facts : FactSet) (rule : CellRule) (f : Fact)
    (h : FactSet.contains facts f = true) :
    FactSet.contains (fire facts rule) f = true := by
  simp only [fire]
  split
  · next hs =>
    split
    · next => exact h
    · next => exact contains_append_left facts _ f h
  · next => exact h

theorem derive_monotone (facts : FactSet) (rules : List CellRule) (f : Fact)
    (h : FactSet.contains facts f = true) :
    FactSet.contains (derive facts rules) f = true := by
  induction rules generalizing facts with
  | nil =>
    simpa [derive] using h
  | cons r rs ih =>
    simp only [derive, List.foldl_cons]
    exact ih (fire facts r) (fire_monotone facts r f h)

theorem unfired_unchanged (facts : FactSet) (rule : CellRule)
    (h : satisfied facts rule.requirements = false) :
    fire facts rule = facts := by
  simp [fire, h]

theorem fire_idempotent (facts : FactSet) (rule : CellRule) :
    ∀ f, FactSet.contains (fire (fire facts rule) rule) f =
      FactSet.contains (fire facts rule) f := by
  intro f
  cases hs : satisfied facts rule.requirements with
  | false =>
    have hfire : fire facts rule = facts := by simp [fire, hs]
    rw [hfire, hfire]
  | true =>
    cases hc : FactSet.contains facts (producedFact facts rule) with
    | true =>
      have hfire : fire facts rule = facts := by simp [fire, hs, hc]
      rw [hfire, hfire]
    | false =>
      have hfire : fire facts rule =
          facts ++ [producedFact facts rule] := by
        simp [fire, hs, hc]
      rw [hfire]


      have hs' : satisfied (facts ++ [producedFact facts rule])
          rule.requirements = true :=
        satisfied_append_left facts [producedFact facts rule]
          rule.requirements hs
      have hprod : producedFact (facts ++ [producedFact facts rule]) rule =
          producedFact facts rule :=
        producedFact_append facts [producedFact facts rule] rule hs
      have hc' : FactSet.contains (facts ++ [producedFact facts rule])
          (producedFact facts rule) = true :=
        contains_append_right facts (producedFact facts rule)
      have hfire2 : fire (facts ++ [producedFact facts rule]) rule =
          facts ++ [producedFact facts rule] := by
        simp only [fire, hs', hprod, hc', ↓reduceIte]
      rw [hfire2]

#print axioms fire_monotone
#print axioms derive_monotone
#print axioms fire_idempotent
#print axioms unfired_unchanged

end Necoherence
