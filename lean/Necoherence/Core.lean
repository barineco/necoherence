-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT



namespace Necoherence

structure Revision where
  value : Nat
  deriving Repr, DecidableEq

/--
Identity of an owned resource, determined by the resource's own name.
`kind` separates one domain of resources from another. `name` is that
domain's own name for the resource.
-/
structure ResourceId where
  kind : String
  name : String
  deriving Repr, DecidableEq

structure Basis where
  resource : ResourceId
  revision : Revision
  deriving Repr, DecidableEq

structure Observation (α : Type) where
  payload : α
  basis : Basis
  observedAt : Nat

structure Command (α : Type) where
  intent : α
  basis : Basis

inductive Outcome (α ρ κ φ : Type) where
  | applied : α → Outcome α ρ κ φ
  | rejected : ρ → Outcome α ρ κ φ
  | conflicted : κ → Outcome α ρ κ φ
  | boundaryFailed : φ → Outcome α ρ κ φ

/-- Rejection payload when the commanded resource is absent. -/
structure UnknownResource where
  resource : ResourceId
  deriving Repr, DecidableEq

/--
Conflict payload when the commanded revision differs from owned state.
`expected` is the revision carried by the command basis.
`actual` is the revision currently held by the world.
-/
structure StaleBasis where
  expected : Revision
  actual : Revision
  deriving Repr, DecidableEq

/--
Closed sum of a held revision and an absent-resource payload.
Distinct absences remain distinct values, matching `Revision | UnknownResource`.
-/
inductive Lookup where
  | found : Revision → Lookup
  | unknown : UnknownResource → Lookup
  deriving Repr, DecidableEq

namespace Lookup

def map (f : Revision → Revision) : Lookup → Lookup
  | .found r => .found (f r)
  | .unknown u => .unknown u

def isFound : Lookup → Bool
  | .found _ => true
  | .unknown _ => false

end Lookup

def World := List (ResourceId × Revision)

namespace World

def lookup (w : World) (r : ResourceId) : Lookup :=
  match w with
  | [] => .unknown ⟨r⟩
  | (rid, rev) :: rest =>
    if rid = r then .found rev else lookup rest r

/-- Increment the revision of the first matching resource entry. -/
def bump (w : World) (res : ResourceId) : World :=
  match w with
  | [] => []
  | (rid, rev) :: rest =>
    if rid = res then
      (rid, ⟨rev.value + 1⟩) :: rest
    else
      (rid, rev) :: bump rest res

def apply (w : World) (c : Command α) :
    Outcome (α × World) UnknownResource StaleBasis Empty :=
  match lookup w c.basis.resource with
  | .unknown u => .rejected u
  | .found r =>
    if r = c.basis.revision then
      .applied (c.intent, bump w c.basis.resource)
    else
      .conflicted ⟨c.basis.revision, r⟩

end World

def commandOf (o : Observation α) (x : β) : Command β :=
  ⟨x, o.basis⟩



theorem outcome_closure {α ρ κ φ : Type} :
    ∀ (o : Outcome α ρ κ φ),
      (∃ a, o = .applied a) ∨
      (∃ r, o = .rejected r) ∨
      (∃ k, o = .conflicted k) ∨
      (∃ f, o = .boundaryFailed f) := by
  intro o
  cases o with
  | applied a => exact Or.inl ⟨a, rfl⟩
  | rejected r => exact Or.inr (Or.inl ⟨r, rfl⟩)
  | conflicted k => exact Or.inr (Or.inr (Or.inl ⟨k, rfl⟩))
  | boundaryFailed f => exact Or.inr (Or.inr (Or.inr ⟨f, rfl⟩))

theorem basis_retention {α β : Type} (o : Observation α) (x : β) :
    (commandOf o x).basis = o.basis :=
  rfl

theorem stale_conflict {α : Type}
    (w : World) (c : Command α) (r : Revision)
    (hlook : World.lookup w c.basis.resource = .found r)
    (hne : r ≠ c.basis.revision) :
    World.apply w c = .conflicted ⟨c.basis.revision, r⟩ := by
  simp [World.apply, hlook, hne]

theorem World.bump_lookup_other
    (w : World) (a b : ResourceId) (hne : a ≠ b) :
    World.lookup (World.bump w a) b = World.lookup w b := by
  induction w with
  | nil =>
    rfl
  | cons head rest ih =>
    obtain ⟨rid, rev⟩ := head
    dsimp [World.bump]
    by_cases ha : rid = a
    · -- bumped this entry; resource a is not b, so lookup of b skips it
      simp only [ha, ↓reduceIte, World.lookup]
      have : ¬ a = b := hne
      simp only [this, ↓reduceIte]
    · simp only [ha, ↓reduceIte, World.lookup]
      by_cases hb : rid = b
      · simp only [hb, ↓reduceIte]
      · simp only [hb, ↓reduceIte]
        exact ih

theorem World.bump_lookup_self (w : World) (a : ResourceId) :
    World.lookup (World.bump w a) a =
      (World.lookup w a).map (fun rev => ⟨rev.value + 1⟩) := by
  induction w with
  | nil =>
    rfl
  | cons head rest ih =>
    obtain ⟨rid, rev⟩ := head
    dsimp [World.bump]
    by_cases ha : rid = a
    · simp only [ha, ↓reduceIte, World.lookup, Lookup.map]
    · simp only [ha, ↓reduceIte, World.lookup]
      exact ih

theorem World.bump_comm_lookup
    (w : World) (a b : ResourceId) (hne : a ≠ b) :
    ∀ r, World.lookup (World.bump (World.bump w a) b) r =
      World.lookup (World.bump (World.bump w b) a) r := by
  intro r
  by_cases hr_a : r = a
  · -- r = a
    have hba : b ≠ a := fun h => hne h.symm
    rw [hr_a]
    calc
      World.lookup (World.bump (World.bump w a) b) a
          = World.lookup (World.bump w a) a :=
            World.bump_lookup_other (World.bump w a) b a hba
      _ = (World.lookup w a).map (fun rev => ⟨rev.value + 1⟩) :=
            World.bump_lookup_self w a
      _ = (World.lookup (World.bump w b) a).map (fun rev => ⟨rev.value + 1⟩) := by
            rw [World.bump_lookup_other w b a hba]
      _ = World.lookup (World.bump (World.bump w b) a) a :=
            (World.bump_lookup_self (World.bump w b) a).symm
  · by_cases hr_b : r = b
    · -- r = b, r ≠ a
      rw [hr_b]
      calc
        World.lookup (World.bump (World.bump w a) b) b
            = (World.lookup (World.bump w a) b).map (fun rev => ⟨rev.value + 1⟩) :=
              World.bump_lookup_self (World.bump w a) b
        _ = (World.lookup w b).map (fun rev => ⟨rev.value + 1⟩) := by
              rw [World.bump_lookup_other w a b hne]
        _ = World.lookup (World.bump w b) b :=
              (World.bump_lookup_self w b).symm
        _ = World.lookup (World.bump (World.bump w b) a) b :=
              (World.bump_lookup_other (World.bump w b) a b hne).symm
    · -- r ≠ a, r ≠ b
      calc
        World.lookup (World.bump (World.bump w a) b) r
            = World.lookup (World.bump w a) r :=
              World.bump_lookup_other (World.bump w a) b r (Ne.symm hr_b)
        _ = World.lookup w r :=
              World.bump_lookup_other w a r (Ne.symm hr_a)
        _ = World.lookup (World.bump w b) r :=
              (World.bump_lookup_other w b r (Ne.symm hr_b)).symm
        _ = World.lookup (World.bump (World.bump w b) a) r :=
              (World.bump_lookup_other (World.bump w b) a r (Ne.symm hr_a)).symm

/-- Successful apply replaces the matched entry exactly as `bump` does. -/
theorem World.apply_success_eq_bump {α : Type}
    (w : World) (c : Command α) (w' : World)
    (h : World.apply w c = .applied (c.intent, w')) :
    w' = World.bump w c.basis.resource := by
  simp [World.apply] at h
  split at h
  · next u hunknown => cases h
  · next r hfound =>
    split at h
    · next hrev =>
      injection h with hpair
      injection hpair with _ hw
      exact hw.symm
    · next hne => cases h

/--
Disjoint successful applies commute observationally: every resource's
lookup agrees after either order. Structural list equality is not claimed.
-/
theorem apply_disjoint_comm {α β : Type}
    (w : World) (c₁ : Command α) (c₂ : Command β)
    (hres : c₁.basis.resource ≠ c₂.basis.resource)
    {w₁ w₁₂ w₂ w₂₁ : World}
    (h₁ : World.apply w c₁ = .applied (c₁.intent, w₁))
    (h₁₂ : World.apply w₁ c₂ = .applied (c₂.intent, w₁₂))
    (h₂ : World.apply w c₂ = .applied (c₂.intent, w₂))
    (h₂₁ : World.apply w₂ c₁ = .applied (c₁.intent, w₂₁)) :
    ∀ r, World.lookup w₁₂ r = World.lookup w₂₁ r := by
  intro r
  have hw₁ : w₁ = World.bump w c₁.basis.resource :=
    World.apply_success_eq_bump w c₁ w₁ h₁
  have hw₁₂ : w₁₂ = World.bump w₁ c₂.basis.resource :=
    World.apply_success_eq_bump w₁ c₂ w₁₂ h₁₂
  have hw₂ : w₂ = World.bump w c₂.basis.resource :=
    World.apply_success_eq_bump w c₂ w₂ h₂
  have hw₂₁ : w₂₁ = World.bump w₂ c₁.basis.resource :=
    World.apply_success_eq_bump w₂ c₁ w₂₁ h₂₁
  rw [hw₁₂, hw₁, hw₂₁, hw₂]
  exact World.bump_comm_lookup w c₁.basis.resource c₂.basis.resource hres r



/--
Concrete witness: rebuilding a `Command` from payload alone with a wrong
(stale) basis yields `conflicted`, so the guarantee of `stale_conflict`
depends on retaining the observation's basis rather than inventing one.
-/
example :
    let res : ResourceId := ⟨"core", "0"⟩
    let w : World := [(res, ⟨5⟩)]
    let o : Observation Nat := ⟨42, ⟨res, ⟨5⟩⟩, 0⟩

    let c : Command Nat := ⟨o.payload, ⟨res, ⟨4⟩⟩⟩
    World.apply w c = .conflicted ⟨⟨4⟩, ⟨5⟩⟩ := by
  simp [World.apply, World.lookup]

#print axioms outcome_closure
#print axioms basis_retention
#print axioms stale_conflict
#print axioms apply_disjoint_comm

end Necoherence
