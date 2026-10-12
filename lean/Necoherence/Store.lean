-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
Store<A>: a payload-owning container that projects onto `World`.

This module does not re-prove `Core.lean`'s theorems (`outcome_closure`,
`basis_retention`, `stale_conflict`, `apply_disjoint_comm`, etc.). It proves
only that `Store`'s `observe` and `apply` commute with the projection
`worldOf` onto `World`. Once that commutation holds, `World`'s existing
theorems apply to `Store` through the projection without restatement.

`Store` payload mutation is value replacement
only: the command's `intent` is the new payload, replacing the old one in
place while the matched entry's revision is bumped exactly as `World.bump`
does.
-/

import Necoherence.Core

namespace Necoherence

/-- A `Store` owns each resource's payload alongside its revision. -/
def Store (α : Type) := List (ResourceId × Revision × α)

/--
Closed sum of an observation result, carrying both the held revision and
payload, or the absent-resource payload. Mirrors `Lookup`'s shape.
-/
inductive Observe (α : Type) where
  | found : Revision → α → Observe α
  | unknown : UnknownResource → Observe α

namespace Observe

/-- Forget the payload, keeping only the revision part. Matches `Lookup`. -/
def toLookup : Observe α → Lookup
  | .found r _ => .found r
  | .unknown u => .unknown u

end Observe

namespace Store

/-- Read-only observation: does not change the store. -/
def observe (s : Store α) (r : ResourceId) : Observe α :=
  match s with
  | [] => .unknown ⟨r⟩
  | (rid, rev, a) :: rest =>
    if rid = r then .found rev a else observe rest r

/-- Bump the revision and replace the payload of the first matching entry. -/
def bump (s : Store α) (res : ResourceId) (intent : α) : Store α :=
  match s with
  | [] => []
  | (rid, rev, a) :: rest =>
    if rid = res then
      (rid, ⟨rev.value + 1⟩, intent) :: rest
    else
      (rid, rev, a) :: bump rest res intent

def apply (s : Store α) (c : Command α) :
    Outcome (α × Store α) UnknownResource StaleBasis Empty :=
  match observe s c.basis.resource with
  | .unknown u => .rejected u
  | .found r _ =>
    if r = c.basis.revision then
      .applied (c.intent, bump s c.basis.resource c.intent)
    else
      .conflicted ⟨c.basis.revision, r⟩

/-- Projection onto `World`: drop each entry's payload. -/
def worldOf (s : Store α) : World :=
  match s with
  | [] => []
  | (rid, rev, _) :: rest => (rid, rev) :: worldOf rest

end Store

/-! ### Projection commutation -/

/-- `observe`'s revision part agrees with `lookup` on the `worldOf` projection. -/
theorem Store.observe_worldOf {α : Type} (s : Store α) (r : ResourceId) :
    (Store.observe s r).toLookup = World.lookup (Store.worldOf s) r := by
  induction s with
  | nil => rfl
  | cons head rest ih =>
    obtain ⟨rid, rev, a⟩ := head
    dsimp [Store.observe, Store.worldOf, World.lookup]
    by_cases h : rid = r
    · simp [h, Observe.toLookup]
    · simp [h, ih]

/-- `worldOf ∘ bump` agrees with `World.bump ∘ worldOf`, regardless of intent. -/
theorem Store.worldOf_bump {α : Type}
    (s : Store α) (res : ResourceId) (intent : α) :
    Store.worldOf (Store.bump s res intent) = World.bump (Store.worldOf s) res := by
  induction s with
  | nil => rfl
  | cons head rest ih =>
    obtain ⟨rid, rev, a⟩ := head
    dsimp [Store.bump, Store.worldOf, World.bump]
    by_cases h : rid = res
    · simp [h, Store.worldOf]
    · simp [h, Store.worldOf, ih]

/--
`apply`'s projection commutes with `World.apply` branch-for-branch:
`applied` projects to `applied` with the matching world, and `rejected` /
`conflicted` project to the same payload on both sides.
-/
theorem Store.apply_worldOf {α : Type} (s : Store α) (c : Command α) :
    match Store.apply s c, World.apply (Store.worldOf s) c with
    | .applied (a, s'), .applied (a', w') => a = a' ∧ Store.worldOf s' = w'
    | .rejected u, .rejected u' => u = u'
    | .conflicted k, .conflicted k' => k = k'
    | .boundaryFailed f, _ => Empty.elim f
    | _, _ => False := by
  have hobs := Store.observe_worldOf s c.basis.resource
  dsimp [Store.apply, World.apply]
  cases hs : Store.observe s c.basis.resource with
  | unknown u =>
    have hw : World.lookup (Store.worldOf s) c.basis.resource = .unknown u := by
      rw [← hobs, hs, Observe.toLookup]
    simp [hw]
  | found r a =>
    have hw : World.lookup (Store.worldOf s) c.basis.resource = .found r := by
      rw [← hobs, hs, Observe.toLookup]
    simp only [hw]
    by_cases hrev : r = c.basis.revision
    · simp [hrev, Store.worldOf_bump]
    · simp [hrev]

end Necoherence
