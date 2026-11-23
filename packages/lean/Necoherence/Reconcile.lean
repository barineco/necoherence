-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT



import Necoherence.Core

namespace Necoherence

/-- One resource where the recorded history and the world disagree. -/
inductive Divergence where
  | worldAhead : ResourceId → Revision → Revision → Divergence
  | worldBehind : ResourceId → Revision → Revision → Divergence
  | unknownToWorld : ResourceId → Revision → Divergence
  deriving Repr, DecidableEq

/-- Closed reconciliation product. Carries no derivable boolean field. -/
structure Reconciliation where
  divergences : List Divergence
  unbased : Nat
  dropped : Nat
  deriving Repr, DecidableEq

/-- Read whether the reconciliation is free of any gap. -/
def coherent (r : Reconciliation) : Bool :=
  r.divergences.isEmpty && r.unbased == 0 && r.dropped == 0



/-- Fold one input entry into the running maximum revision for resource `r`. -/
def mergeStep (r : ResourceId) (acc : Option Revision) (mb : Option Basis) : Option Revision :=
  match mb with
  | none => acc
  | some b =>
    if b.resource = r then
      match acc with
      | none => some b.revision
      | some existing => some ⟨max existing.value b.revision.value⟩
    else acc

/-- Highest recorded revision for resource `r` across all bases, or `none`
if no basis in `bases` names `r`. Absent entries and bases on other
resources leave the running maximum unchanged. -/
def maxRevision (bases : List (Option Basis)) (r : ResourceId) : Option Revision :=
  bases.foldl (mergeStep r) none

theorem mergeStep_comm (r : ResourceId) (x y : Option Basis) (z : Option Revision) :
    mergeStep r (mergeStep r z x) y = mergeStep r (mergeStep r z y) x := by
  cases x with
  | none =>
    cases y with
    | none => rfl
    | some by_ =>
      unfold mergeStep
      by_cases hy : by_.resource = r <;> simp [hy]
  | some bx =>
    cases y with
    | none =>
      unfold mergeStep
      by_cases hx : bx.resource = r <;> simp [hx]
    | some by_ =>
      unfold mergeStep
      by_cases hx : bx.resource = r <;> by_cases hy : by_.resource = r <;>
        simp only [hx, hy, if_pos] <;>
        cases z <;> simp <;> omega

/-- The per-resource maximum revision does not depend on the order of `bases`. -/
theorem maxRevision_perm {bases₁ bases₂ : List (Option Basis)}
    (h : bases₁.Perm bases₂) (r : ResourceId) :
    maxRevision bases₁ r = maxRevision bases₂ r :=
  h.foldl_eq' (fun x _ y _ z => mergeStep_comm r x y z) none

private def orle : Option Revision → Option Revision → Prop
  | none, _ => True
  | some _, none => False
  | some a, some b => a.value ≤ b.value

private theorem orle_refl : ∀ x, orle x x
  | none => trivial
  | some a => Nat.le_refl a.value

private theorem orle_trans : ∀ x y z, orle x y → orle y z → orle x z
  | none, _, _, _, _ => trivial
  | some _, none, _, h, _ => absurd h (by simp [orle])
  | some _, some _, none, _, h => absurd h (by simp [orle])
  | some a, some b, some c, hxy, hyz => Nat.le_trans hxy hyz

private theorem mergeStep_orle_self (r : ResourceId) (acc : Option Revision) (mb : Option Basis) :
    orle acc (mergeStep r acc mb) := by
  cases mb with
  | none => exact orle_refl acc
  | some b =>
    unfold mergeStep
    by_cases hres : b.resource = r
    · simp only [hres, if_pos]
      cases acc with
      | none => trivial
      | some a => simp only [orle]; omega
    · simp only [hres, if_neg, not_false_iff]
      exact orle_refl acc

private theorem mergeStep_orle_hit (r : ResourceId) (acc : Option Revision) (b : Basis)
    (hres : b.resource = r) :
    orle (some b.revision) (mergeStep r acc (some b)) := by
  unfold mergeStep
  simp only [hres, if_pos]
  cases acc with
  | none => exact orle_refl _
  | some a => simp only [orle]; omega

private theorem foldl_orle (r : ResourceId) (bases : List (Option Basis)) :
    ∀ acc, orle acc (bases.foldl (mergeStep r) acc) := by
  induction bases with
  | nil => intro acc; exact orle_refl acc
  | cons head rest ih =>
    intro acc
    rw [List.foldl_cons]
    exact orle_trans _ _ _ (mergeStep_orle_self r acc head) (ih (mergeStep r acc head))

/-- The recorded maximum for a resource dominates every basis recorded on it:
`maxRevision` is truly the maximum, not merely the last entry seen. -/
theorem maxRevision_ge (r : ResourceId) (bases : List (Option Basis)) (b : Basis)
    (hmem : some b ∈ bases) (hres : b.resource = r) :
    ∃ rev, maxRevision bases r = some rev ∧ b.revision.value ≤ rev.value := by
  unfold maxRevision
  suffices h : ∀ acc, orle (some b.revision) (bases.foldl (mergeStep r) acc) by
    have h' := h none
    cases hfold : bases.foldl (mergeStep r) none with
    | none => rw [hfold] at h'; exact absurd h' (by simp [orle])
    | some rev =>
      refine ⟨rev, rfl, ?_⟩
      rw [hfold] at h'
      simpa [orle] using h'
  intro acc
  induction bases generalizing acc with
  | nil => cases hmem
  | cons head rest ih =>
    rw [List.foldl_cons]
    cases hmem with
    | head =>
      exact orle_trans _ _ _ (mergeStep_orle_hit r acc b hres) (foldl_orle r rest _)
    | tail _ hmem' =>
      exact ih hmem' (mergeStep r acc head)

private theorem mergeStep_split (r : ResourceId) (acc : Option Revision) (b : Basis) (v : Revision)
    (h : mergeStep r acc (some b) = some v) :
    acc = some v ∨ (b.resource = r ∧ b.revision = v) := by
  unfold mergeStep at h
  by_cases hres : b.resource = r
  · simp only [hres, if_pos] at h
    cases acc with
    | none =>
      simp only [Option.some.injEq] at h
      exact Or.inr ⟨hres, h⟩
    | some existing =>
      simp only [Option.some.injEq] at h
      rcases (by omega :
          max existing.value b.revision.value = existing.value ∨
          max existing.value b.revision.value = b.revision.value) with hm | hm
      · exact Or.inl (by rw [← h, hm])
      · exact Or.inr ⟨hres, by rw [← h, hm]⟩
  · simp only [hres, if_neg, not_false_iff] at h
    exact Or.inl h

private theorem foldl_attained (r : ResourceId) (bases : List (Option Basis)) :
    ∀ acc v, bases.foldl (mergeStep r) acc = some v →
      acc = some v ∨ ∃ b, some b ∈ bases ∧ b.resource = r ∧ b.revision = v := by
  induction bases with
  | nil => intro acc v h; exact Or.inl h
  | cons head rest ih =>
    intro acc v h
    rw [List.foldl_cons] at h
    rcases ih (mergeStep r acc head) v h with hleft | ⟨b, hb, hres, hrev⟩
    · cases head with
      | none =>
        unfold mergeStep at hleft
        exact Or.inl hleft
      | some b =>
        rcases mergeStep_split r acc b v hleft with hacc | ⟨hres, hrev⟩
        · exact Or.inl hacc
        · exact Or.inr ⟨b, List.mem_cons_self, hres, hrev⟩
    · exact Or.inr ⟨b, List.mem_cons_of_mem _ hb, hres, hrev⟩

/-- The recorded maximum for a resource is itself the revision of some basis
recorded on it: it is not invented from thin air. -/
theorem maxRevision_attained (r : ResourceId) (bases : List (Option Basis)) (v : Revision)
    (h : maxRevision bases r = some v) :
    ∃ b, some b ∈ bases ∧ b.resource = r ∧ b.revision = v := by
  unfold maxRevision at h
  rcases foldl_attained r bases none v h with hleft | hright
  · exact absurd hleft (by simp)
  · exact hright



/-- Fold one input entry into the accumulated distinct resource list. -/
def resourceStep (acc : List ResourceId) (mb : Option Basis) : List ResourceId :=
  match mb with
  | none => acc
  | some b => if b.resource ∈ acc then acc else acc ++ [b.resource]

/-- Every resource named by a basis in `bases`, without duplicates, in the
order each resource first appears. -/
def resourcesOf (bases : List (Option Basis)) : List ResourceId :=
  bases.foldl resourceStep []

private theorem resourceStep_nodup (acc : List ResourceId) (mb : Option Basis) (h : acc.Nodup) :
    (resourceStep acc mb).Nodup := by
  cases mb with
  | none => exact h
  | some b =>
    unfold resourceStep
    by_cases hmem : b.resource ∈ acc
    · simp only [hmem, if_pos]; exact h
    · simp only [hmem, if_neg, not_false_iff]
      rw [List.nodup_append]
      refine ⟨h, ?_, ?_⟩
      · rw [List.nodup_cons]; exact ⟨List.not_mem_nil, List.nodup_nil⟩
      · intro a ha c hc
        have hceq : c = b.resource := List.eq_of_mem_singleton hc
        rw [hceq]
        exact fun heq => hmem (heq ▸ ha)

private theorem resourceStep_mem (acc : List ResourceId) (mb : Option Basis) (r : ResourceId) :
    r ∈ resourceStep acc mb ↔ r ∈ acc ∨ (∃ b, mb = some b ∧ r = b.resource) := by
  cases mb with
  | none =>
    unfold resourceStep
    constructor
    · intro h; exact Or.inl h
    · rintro (h | ⟨_, hcontra, _⟩)
      · exact h
      · exact absurd hcontra (by simp)
  | some b =>
    unfold resourceStep
    by_cases hmem : b.resource ∈ acc
    · simp only [hmem, if_pos]
      constructor
      · intro h; exact Or.inl h
      · rintro (h | ⟨b', hb', hr⟩)
        · exact h
        · cases hb'; rw [hr]; exact hmem
    · simp only [hmem, if_neg, not_false_iff, List.mem_append, List.mem_singleton]
      constructor
      · rintro (h | h)
        · exact Or.inl h
        · exact Or.inr ⟨b, rfl, h⟩
      · rintro (h | ⟨b', hb', hr⟩)
        · exact Or.inl h
        · cases hb'; exact Or.inr hr

theorem resourcesOf_nodup (bases : List (Option Basis)) : (resourcesOf bases).Nodup := by
  unfold resourcesOf
  suffices h : ∀ acc : List ResourceId, acc.Nodup → (bases.foldl resourceStep acc).Nodup by
    exact h [] List.nodup_nil
  induction bases with
  | nil => intro acc h; exact h
  | cons head rest ih =>
    intro acc h
    rw [List.foldl_cons]
    exact ih (resourceStep acc head) (resourceStep_nodup acc head h)

/-- A resource appears in `resourcesOf bases` exactly when some basis in
`bases` names it. -/
theorem resourcesOf_mem (bases : List (Option Basis)) (r : ResourceId) :
    r ∈ resourcesOf bases ↔ ∃ b, some b ∈ bases ∧ r = b.resource := by
  unfold resourcesOf
  suffices h : ∀ acc : List ResourceId,
      r ∈ bases.foldl resourceStep acc ↔
        r ∈ acc ∨ ∃ b, some b ∈ bases ∧ r = b.resource by
    rw [h []]; simp
  induction bases with
  | nil => intro acc; simp
  | cons head rest ih =>
    intro acc
    rw [List.foldl_cons, ih (resourceStep acc head), resourceStep_mem]
    constructor
    · rintro ((h | h) | ⟨b, hb, hr⟩)
      · exact Or.inl h
      · obtain ⟨b, hbeq, hr⟩ := h
        exact Or.inr ⟨b, hbeq ▸ List.mem_cons_self, hr⟩
      · exact Or.inr ⟨b, List.mem_cons_of_mem _ hb, hr⟩
    · rintro (h | ⟨b, hb, hr⟩)
      · exact Or.inl (Or.inl h)
      · cases hb with
        | head => exact Or.inl (Or.inr ⟨b, rfl, hr⟩)
        | tail _ hb' => exact Or.inr ⟨b, hb', hr⟩

/-- The set of resources named by the input does not depend on input order:
`resourcesOf` on a permuted input is itself a permutation of the original. -/
theorem resourcesOf_perm {bases₁ bases₂ : List (Option Basis)} (h : bases₁.Perm bases₂) :
    (resourcesOf bases₁).Perm (resourcesOf bases₂) := by
  have hmem : ∀ r, r ∈ resourcesOf bases₁ ↔ r ∈ resourcesOf bases₂ := by
    intro r
    rw [resourcesOf_mem, resourcesOf_mem]
    constructor
    · rintro ⟨b, hb, hr⟩; exact ⟨b, h.mem_iff.mp hb, hr⟩
    · rintro ⟨b, hb, hr⟩; exact ⟨b, h.mem_iff.mpr hb, hr⟩
  rw [List.perm_iff_count]
  intro a
  rw [List.Nodup.count (resourcesOf_nodup bases₁), List.Nodup.count (resourcesOf_nodup bases₂)]
  by_cases ha : a ∈ resourcesOf bases₁
  · have ha2 : a ∈ resourcesOf bases₂ := (hmem a).mp ha
    simp [ha, ha2]
  · have ha2 : a ∉ resourcesOf bases₂ := fun h' => ha ((hmem a).mpr h')
    simp [ha, ha2]



/-- One resource's divergence between its recorded revision and the world,
or `none` if the world agrees (equal, or exactly one step ahead: a
successful apply that has not yet been recorded). -/
def divergenceAt (world : World) (r : ResourceId) (recorded : Revision) : Option Divergence :=
  match World.lookup world r with
  | .unknown _ => some (.unknownToWorld r recorded)
  | .found actual =>
    if actual.value > recorded.value + 1 then
      some (.worldAhead r recorded actual)
    else if actual.value < recorded.value then
      some (.worldBehind r recorded actual)
    else none

/-- Reconcile the highest recorded revision per resource against `world`.
`dropped` is supplied by the caller as a value; it is not counted here. -/
def reconcile (bases : List (Option Basis)) (world : World) (dropped : Nat) : Reconciliation :=
  let resources := resourcesOf bases
  let unbased := (bases.filter (fun mb => mb.isNone)).length
  let divergences :=
    resources.filterMap (fun r =>
      match maxRevision bases r with
      | none => none
      | some recorded => divergenceAt world r recorded)
  { divergences := divergences, unbased := unbased, dropped := dropped }



/-- `unbased` counts exactly the entries with no basis, regardless of order. -/
theorem unbased_perm {bases₁ bases₂ : List (Option Basis)} (h : bases₁.Perm bases₂) :
    (bases₁.filter (fun mb => mb.isNone)).length =
      (bases₂.filter (fun mb => mb.isNone)).length :=
  (h.filter _).length_eq

/-- The set of resources carrying a divergence does not depend on input
order: permuting the recorded history permutes the recorded maxima and the
named resources together, so the divergence list is itself a permutation. -/
theorem reconcile_divergences_perm {bases₁ bases₂ : List (Option Basis)}
    (h : bases₁.Perm bases₂) (world : World) :
    (resourcesOf bases₁).filterMap (fun r =>
        match maxRevision bases₁ r with
        | none => none
        | some recorded => divergenceAt world r recorded) |>.Perm
    ((resourcesOf bases₂).filterMap (fun r =>
        match maxRevision bases₂ r with
        | none => none
        | some recorded => divergenceAt world r recorded)) := by
  have hres := resourcesOf_perm h
  have hstep : ∀ r,
      (match maxRevision bases₁ r with
        | none => none
        | some recorded => divergenceAt world r recorded) =
      (match maxRevision bases₂ r with
        | none => none
        | some recorded => divergenceAt world r recorded) := by
    intro r; rw [maxRevision_perm h r]
  have := List.Perm.filterMap
      (fun r => match maxRevision bases₁ r with
        | none => none
        | some recorded => divergenceAt world r recorded) hres
  simpa [funext hstep] using this

/-- `reconcile`'s result does not depend on the order of the input: `dropped`
is passed through unchanged, `unbased` and each resource's maximum recorded
revision (hence every divergence) depend only on the input as a set. -/
theorem reconcile_perm {bases₁ bases₂ : List (Option Basis)} (h : bases₁.Perm bases₂)
    (world : World) (dropped : Nat) :
    (reconcile bases₁ world dropped).divergences.Perm
        (reconcile bases₂ world dropped).divergences ∧
      (reconcile bases₁ world dropped).unbased = (reconcile bases₂ world dropped).unbased ∧
      (reconcile bases₁ world dropped).dropped = (reconcile bases₂ world dropped).dropped := by
  refine ⟨?_, unbased_perm h, rfl⟩
  exact reconcile_divergences_perm h world

/-- `coherent` reads exactly the closed structure: no divergences, no
unbased entries, and no dropped entries. -/
theorem coherent_iff (r : Reconciliation) :
    coherent r = true ↔ r.divergences = [] ∧ r.unbased = 0 ∧ r.dropped = 0 := by
  unfold coherent
  simp [List.isEmpty_iff, and_assoc]

/-- Coherence is itself order-independent: reconciling a permuted history
against the same world and the same `dropped` value yields the same
coherence verdict. -/
theorem coherent_perm {bases₁ bases₂ : List (Option Basis)} (h : bases₁.Perm bases₂)
    (world : World) (dropped : Nat) :
    coherent (reconcile bases₁ world dropped) = coherent (reconcile bases₂ world dropped) := by
  obtain ⟨hdiv, hunb, hdrop⟩ := reconcile_perm h world dropped
  unfold coherent
  rw [hunb, hdrop]
  have hempty : (reconcile bases₁ world dropped).divergences.isEmpty =
      (reconcile bases₂ world dropped).divergences.isEmpty := by
    generalize hl1 : (reconcile bases₁ world dropped).divergences = l1 at hdiv
    generalize hl2 : (reconcile bases₂ world dropped).divergences = l2 at hdiv
    have hlen := hdiv.length_eq
    cases l1 <;> cases l2 <;> simp_all
  rw [hempty]

#print axioms mergeStep_comm
#print axioms maxRevision_perm
#print axioms maxRevision_ge
#print axioms maxRevision_attained
#print axioms resourcesOf_nodup
#print axioms resourcesOf_mem
#print axioms resourcesOf_perm
#print axioms unbased_perm
#print axioms reconcile_divergences_perm
#print axioms reconcile_perm
#print axioms coherent_iff
#print axioms coherent_perm

end Necoherence
