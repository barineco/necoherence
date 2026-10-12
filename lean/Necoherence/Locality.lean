-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
Locality of the effect point.

Applying a command reads and writes exactly one resource. Its outcome and
the revision that resource ends at depend on that resource's own lookup and
on the command's basis, and on nothing else the world holds. Everything
about composing calls follows from that fact together with the requirement
each call states, so nothing here introduces a syntax of programs to carry
composition: a chain is safe when each step's requirement is met by what the
step before it produced, and that is a statement about worlds and commands.

The last section relates this world to the fact set of `Cell`. Overwriting a
revision loses the earlier one, while the fact image keeps it, so the two are
not isomorphic. The map is a projection, and what it preserves is the
judgment: whether a namespace is present, and whether a requirement is met.
-/
import Necoherence.Core
import Necoherence.Cell

namespace Necoherence

/-! ### Locality of the effect point -/

/--
Two worlds that agree on a resource's lookup agree on whether a command for
that resource applies. Nothing else either world holds takes part in the
decision.
-/
theorem apply_agrees_on_lookup {α : Type} (w₁ w₂ : World) (c : Command α)
    (h : World.lookup w₁ c.basis.resource = World.lookup w₂ c.basis.resource) :
    (∃ a₁ a₂, World.apply w₁ c = .applied a₁ ∧ World.apply w₂ c = .applied a₂) ∨
    (∃ ρ, World.apply w₁ c = .rejected ρ ∧ World.apply w₂ c = .rejected ρ) ∨
    (∃ κ, World.apply w₁ c = .conflicted κ ∧ World.apply w₂ c = .conflicted κ) := by
  cases hl : World.lookup w₂ c.basis.resource with
  | unknown u =>
    refine Or.inr (Or.inl ⟨u, ?_, ?_⟩)
    · simp [World.apply, h, hl]
    · simp [World.apply, hl]
  | found r =>
    by_cases hrev : r = c.basis.revision
    · refine Or.inl ⟨(c.intent, World.bump w₁ c.basis.resource),
        (c.intent, World.bump w₂ c.basis.resource), ?_, ?_⟩
      · simp [World.apply, h, hl, hrev]
      · simp [World.apply, hl, hrev]
    · refine Or.inr (Or.inr ⟨⟨c.basis.revision, r⟩, ?_, ?_⟩)
      · simp [World.apply, h, hl, hrev]
      · simp [World.apply, hl, hrev]

/--
On success the commanded resource ends at one past what it held. The new
revision is a function of that resource's own prior lookup, so two worlds
agreeing there end that resource at the same revision.
-/
theorem apply_advances_locally {α : Type} (w : World) (c : Command α)
    (v : Revision) (h : World.lookup w c.basis.resource = .found v)
    (_hrev : v = c.basis.revision) {w' : World}
    (happ : World.apply w c = .applied (c.intent, w')) :
    World.lookup w' c.basis.resource = .found ⟨v.value + 1⟩ := by
  have hbump : w' = World.bump w c.basis.resource :=
    World.apply_success_eq_bump w c w' happ
  rw [hbump, World.bump_lookup_self, h]
  rfl

/--
Where the commanded resource lands, for two worlds that agree on its lookup
and both of which the command applied to. Whether they both apply is a
separate statement, `apply_agrees_on_lookup`; the two together are what makes
the effect point local, and neither half states it alone. Resources other
than the commanded one appear in neither.
-/
theorem apply_local {α : Type} (w₁ w₂ : World) (c : Command α) (v : Revision)
    (h₁ : World.lookup w₁ c.basis.resource = .found v)
    (h₂ : World.lookup w₂ c.basis.resource = .found v)
    (hrev : v = c.basis.revision)
    {w₁' w₂' : World}
    (happ₁ : World.apply w₁ c = .applied (c.intent, w₁'))
    (happ₂ : World.apply w₂ c = .applied (c.intent, w₂')) :
    World.lookup w₁' c.basis.resource = World.lookup w₂' c.basis.resource := by
  rw [apply_advances_locally w₁ c v h₁ hrev happ₁,
    apply_advances_locally w₂ c v h₂ hrev happ₂]

/--
Untouched resources keep their revision. Together with `apply_local` this is
the whole of what one apply does to a world: one resource advances, the rest
are as they were.

`Core.apply_disjoint_comm` follows this shape: two applies on disjoint
resources commute because each leaves the other's resource alone, which is
what this states. That theorem is proved from its own bump lemmas, and what
it says is a case of what this says.
-/
theorem apply_leaves_others {α : Type} (w : World) (c : Command α)
    {w' : World} (happ : World.apply w c = .applied (c.intent, w'))
    (r : ResourceId) (hne : c.basis.resource ≠ r) :
    World.lookup w' r = World.lookup w r := by
  have hbump : w' = World.bump w c.basis.resource :=
    World.apply_success_eq_bump w c w' happ
  rw [hbump]
  exact World.bump_lookup_other w c.basis.resource r hne

/-! ### Composition as a chain of met requirements -/

/--
What a step requires: the resource it names holds the revision its basis
carries. This is the same condition `apply` checks, stated as a proposition
so that a chain can be built out of it.
-/
def Requires {α : Type} (w : World) (c : Command α) : Prop :=
  World.lookup w c.basis.resource = .found c.basis.revision

/-- A step whose requirement is met applies. -/
theorem requires_applies {α : Type} (w : World) (c : Command α)
    (h : Requires w c) :
    World.apply w c = .applied (c.intent, World.bump w c.basis.resource) := by
  simp [World.apply, Requires] at h ⊢
  simp [h]

/-- A step whose requirement is not met does not apply. -/
theorem not_requires_not_applied {α : Type} (w : World) (c : Command α)
    (h : ¬ Requires w c) :
    (∃ ρ, World.apply w c = .rejected ρ) ∨
    (∃ κ, World.apply w c = .conflicted κ) := by
  simp only [Requires] at h
  cases hl : World.lookup w c.basis.resource with
  | unknown u =>
    refine Or.inl ⟨u, ?_⟩
    simp [World.apply, hl]
  | found r =>
    have hne : r ≠ c.basis.revision := by
      intro heq
      exact h (by rw [hl, heq])
    refine Or.inr ⟨⟨c.basis.revision, r⟩, ?_⟩
    simp [World.apply, hl, hne]

/--
A second step on a resource the first did not touch requires exactly what it
required before. Composition over disjoint resources needs no reasoning about
the first step at all.
-/
theorem requires_preserved_on_others {α β : Type} (w : World)
    (c₁ : Command α) (c₂ : Command β)
    (hne : c₁.basis.resource ≠ c₂.basis.resource)
    {w' : World} (happ : World.apply w c₁ = .applied (c₁.intent, w'))
    (h₂ : Requires w c₂) :
    Requires w' c₂ := by
  simp only [Requires] at h₂ ⊢
  rw [apply_leaves_others w c₁ happ c₂.basis.resource hne]
  exact h₂

/--
A second step on the same resource requires the revision the first step
produced. This is the chain: what the earlier step produced is what the later
step must name.
-/
theorem requires_after_same_resource {α β : Type} (w : World)
    (c₁ : Command α) (c₂ : Command β) (v : Revision)
    (hsame : c₁.basis.resource = c₂.basis.resource)
    (hlook : World.lookup w c₁.basis.resource = .found v)
    (h₁ : Requires w c₁)
    {w' : World} (happ : World.apply w c₁ = .applied (c₁.intent, w'))
    (hnext : c₂.basis.revision = ⟨v.value + 1⟩) :
    Requires w' c₂ := by
  simp only [Requires] at h₁ ⊢
  have hrev : v = c₁.basis.revision := by
    rw [hlook] at h₁
    cases h₁
    rfl
  rw [hnext, ← hsame, apply_advances_locally w c₁ v hlook hrev happ]


/-! ### The fact image is a projection, not an isomorphism -/

/--
Map a resource identity into Cell's `Namespace`. The namespace carries the same
`kind` and `name` fields as `ResourceId`, so the map is the identity on those
coordinates and injectivity is immediate.
-/
def nsOf (r : ResourceId) : Namespace := ⟨r.kind, r.name⟩

def coreRid (n : Nat) : ResourceId := ⟨"core", toString n⟩

def provOf (v : Nat) : Provenance := ⟨[⟨v⟩]⟩

def factOf (r : ResourceId) (v : Nat) : Fact := ⟨⟨nsOf r, provOf v⟩⟩

/-- Every revision up to the current one, as facts. -/
def histFacts (r : ResourceId) : Nat → FactSet
  | 0 => [factOf r 0]
  | v + 1 => factOf r (v + 1) :: histFacts r v

def worldToFacts : World → FactSet
  | [] => []
  | (r, rev) :: rest => histFacts r rev.value ++ worldToFacts rest

@[simp] theorem worldToFacts_nil : worldToFacts ([] : World) = [] := rfl

@[simp] theorem worldToFacts_cons (r : ResourceId) (rev : Revision)
    (rest : World) :
    worldToFacts ((r, rev) :: rest) =
      histFacts r rev.value ++ worldToFacts rest := rfl

theorem nsOf_eq_iff (a b : ResourceId) : nsOf a = nsOf b ↔ a = b := by
  cases a; cases b
  simp [nsOf]

theorem hasSpace_append (a b : FactSet) (ns : Namespace) :
    hasSpace (a ++ b) ns = (hasSpace a ns || hasSpace b ns) := by
  simp [hasSpace, List.any_append]

theorem hasSpace_histFacts (r : ResourceId) (v : Nat) (ns : Namespace) :
    hasSpace (histFacts r v) ns = decide (nsOf r = ns) := by
  induction v with
  | zero => simp [histFacts, hasSpace, factOf]
  | succ v ih =>
    simp only [histFacts, hasSpace, List.any_cons] at ih ⊢
    rw [ih]
    simp [factOf]

/--
What the projection preserves: a resource is in the world exactly when its
namespace is in the fact image. Presence is the judgment `apply` makes when
it decides between `rejected` and the other two outcomes, so the projection
carries that decision.
-/
theorem presence_preserved (w : World) (r : ResourceId) :
    hasSpace (worldToFacts w) (nsOf r) = (World.lookup w r).isFound := by
  induction w with
  | nil => rfl
  | cons head rest ih =>
    obtain ⟨rid, rev⟩ := head
    by_cases hr : rid = r
    · subst hr
      simp [hasSpace_append, hasSpace_histFacts, World.lookup, Lookup.isFound]
    · simp [hasSpace_append, hasSpace_histFacts, nsOf_eq_iff, hr,
        World.lookup, Lookup.isFound, ih]

/--
A single-requirement rule is met exactly when the resource is present. The
projection therefore carries requirement satisfaction, which is the judgment
composition is built out of.
-/
theorem requirement_preserved (w : World) (r : ResourceId) :
    satisfied (worldToFacts w) [nsOf r] = (World.lookup w r).isFound := by
  simp [satisfied, presence_preserved]

/--
What the projection loses: two worlds whose current revisions differ can have
the same fact image. `lookup` reads the first entry for a resource, while the
image accumulates every entry's history, so a world holding revision 0 ahead
of an entry at revision 1 images exactly as a world holding revision 1 alone.
No observation of the image separates them, which is what makes this a
projection rather than an isomorphism.
-/
theorem revision_not_recovered :
    ∃ (w₁ w₂ : World) (r : ResourceId),
      World.lookup w₁ r ≠ World.lookup w₂ r ∧
      ∀ f, FactSet.contains (worldToFacts w₁) f =
        FactSet.contains (worldToFacts w₂) f := by
  refine ⟨[(coreRid 0, ⟨1⟩)], [(coreRid 0, ⟨0⟩), (coreRid 0, ⟨1⟩)], coreRid 0, ?_, ?_⟩
  · decide
  · intro f
    simp only [worldToFacts_cons, worldToFacts_nil, histFacts,
      List.append_nil, List.cons_append, FactSet.contains, List.any_cons,
      List.any_nil, Bool.or_false]
    cases h₁ : decide ((factOf (coreRid 0) 1).identity = f.identity) <;>
      cases h₀ : decide ((factOf (coreRid 0) 0).identity = f.identity) <;> simp_all

/-! ### Writes that do not go through a basis -/

theorem contains_append (a b : FactSet) (f : Fact) :
    FactSet.contains (a ++ b) f =
      (FactSet.contains a f || FactSet.contains b f) := by
  simp [FactSet.contains, List.any_append]

theorem contains_cons (g : Fact) (facts : FactSet) (f : Fact) :
    FactSet.contains (g :: facts) f =
      (decide (g.identity = f.identity) || FactSet.contains facts f) := by
  simp [FactSet.contains]

/--
A bump never removes a fact. The image of a bumped world contains everything
the image of the original did, because `histFacts` at `v + 1` is the fact for
`v + 1` in front of the history at `v`.
-/
theorem bump_keeps_facts (w : World) (r : ResourceId) (f : Fact)
    (h : FactSet.contains (worldToFacts w) f = true) :
    FactSet.contains (worldToFacts (World.bump w r)) f = true := by
  induction w with
  | nil =>
    simp only [worldToFacts_nil, FactSet.contains, List.any_nil] at h
    exact Bool.noConfusion h
  | cons head rest ih =>
    obtain ⟨rid, rev⟩ := head
    rw [worldToFacts_cons, contains_append] at h
    by_cases hr : rid = r
    · subst hr
      have hb : World.bump ((rid, rev) :: rest) rid =
          (rid, ⟨rev.value + 1⟩) :: rest := by
        simp [World.bump]
      rw [hb, worldToFacts_cons,
        show histFacts rid (rev.value + 1) =
          factOf rid (rev.value + 1) :: histFacts rid rev.value from rfl,
        List.cons_append, contains_cons, contains_append, h]
      simp
    · have hb : World.bump ((rid, rev) :: rest) r =
          (rid, rev) :: World.bump rest r := by
        simp [World.bump, hr]
      rw [hb, worldToFacts_cons, contains_append]
      cases hch : FactSet.contains (histFacts rid rev.value) f with
      | true => simp
      | false =>
        rw [hch] at h
        simp only [Bool.false_or] at h ⊢
        exact ih h

/--
An applied command never removes a fact either, since a success is a bump.
This is what `direct_write_drops_a_fact` contrasts with: writing through a
basis keeps the image growing, writing around one does not.
-/
theorem apply_keeps_facts {α : Type} (w : World) (c : Command α) (f : Fact)
    {w' : World} (happ : World.apply w c = .applied (c.intent, w'))
    (h : FactSet.contains (worldToFacts w) f = true) :
    FactSet.contains (worldToFacts w') f = true := by
  have hbump : w' = World.bump w c.basis.resource :=
    World.apply_success_eq_bump w c w' happ
  rw [hbump]
  exact bump_keeps_facts w c.basis.resource f h

/-- Set a resource's revision outright, consulting no basis. -/
def setRev : World → ResourceId → Revision → World
  | [], r, v => [(r, v)]
  | (rid, rev) :: rest, r, v =>
    if rid = r then (rid, v) :: rest else (rid, rev) :: setRev rest r v

/--
A direct write can lower a revision, so the fact image loses a fact it held.
`apply_keeps_facts` above states the contrast: a command that applies never
removes one. A step that removes facts has no rule list standing for it,
since deriving only ever adds.

This is why the basis is not decoration on a write. Writing through one is
what makes the image monotone, and monotonicity is what lets a rule list
stand for the step at all.
-/
theorem direct_write_drops_a_fact :
    ∃ (w : World) (r : ResourceId) (v : Revision) (f : Fact),
      FactSet.contains (worldToFacts w) f = true ∧
      FactSet.contains (worldToFacts (setRev w r v)) f = false := by
  refine ⟨[(coreRid 0, ⟨1⟩)], coreRid 0, ⟨0⟩, factOf (coreRid 0) 1, ?_, ?_⟩ <;> decide

/-- Write a resource without reading it: create it, or bump it blindly. -/
def ambientWrite (w : World) (r : ResourceId) : World :=
  match World.lookup w r with
  | .found _ => World.bump w r
  | .unknown _ => (r, ⟨0⟩) :: w

/--
An ambient write succeeds against a world where the resource is absent. A
command cannot: `apply` rejects what it cannot look up, and `Requires` is
false there. So the requirement a rule states, which
`requirement_preserved` ties to presence, has nothing to match an ambient
write against. The write happens where no requirement could have been met.
-/
theorem ambient_write_needs_no_requirement :
    ∃ (w : World) (r : ResourceId),
      World.lookup w r = .unknown ⟨r⟩ ∧
      World.lookup (ambientWrite w r) r = .found ⟨0⟩ ∧
      satisfied (worldToFacts w) [nsOf r] = false := by
  refine ⟨[], coreRid 0, rfl, rfl, ?_⟩
  decide

#print axioms apply_agrees_on_lookup
#print axioms apply_advances_locally
#print axioms apply_local
#print axioms apply_leaves_others
#print axioms requires_applies
#print axioms not_requires_not_applied
#print axioms requires_preserved_on_others
#print axioms requires_after_same_resource
#print axioms presence_preserved
#print axioms requirement_preserved
#print axioms revision_not_recovered
#print axioms bump_keeps_facts
#print axioms apply_keeps_facts
#print axioms direct_write_drops_a_fact
#print axioms ambient_write_needs_no_requirement

end Necoherence
