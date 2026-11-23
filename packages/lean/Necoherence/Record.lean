-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT



import Necoherence.Core

namespace Necoherence

/-- One call: which declaration ran, on what input, and what settled. -/
structure CallRecord (Input : Type) (Product : Type) where
  declaration : String
  input : Input
  product : Product
  basis : Option Basis
  deriving Repr

/-- Build a record without a basis. -/
def recordOf (declaration : String) (input : Input) (product : Product) :
    CallRecord Input Product :=
  ⟨declaration, input, product, none⟩

/-- Build a record that carries the basis its command was situated on. -/
def recordOnBasis (declaration : String) (input : Input) (product : Product)
    (basis : Basis) : CallRecord Input Product :=
  ⟨declaration, input, product, some basis⟩

/-- Hold where `later` reads the resource `earlier` settled. -/
def hasEdge (earlier : CallRecord α β) (later : CallRecord γ δ) : Prop :=
  match earlier.basis, later.basis with
  | some settled, some read => settled.resource = read.resource
  | _, _ => False

/-- Resource equality is symmetric, so edges between records are too. -/
theorem has_edge_symm (earlier : CallRecord α β) (later : CallRecord γ δ) :
    hasEdge earlier later ↔ hasEdge later earlier := by
  unfold hasEdge
  cases earlier.basis with
  | none =>
    cases later.basis with
    | none => simp
    | some _ => simp
  | some settled =>
    cases later.basis with
    | none => simp
    | some read =>
      constructor
      · intro h; exact h.symm
      · intro h; exact h.symm

/-- Shared resource identity is transitive along a chain of edges. -/
theorem has_edge_trans
    (a : CallRecord α β) (b : CallRecord γ δ) (c : CallRecord ε ζ) :
    hasEdge a b → hasEdge b c → hasEdge a c := by
  unfold hasEdge
  cases ha : a.basis with
  | none => intro h; exact False.elim h
  | some sa =>
    cases hb : b.basis with
    | none => intro h; exact False.elim h
    | some sb =>
      cases hc : c.basis with
      | none => intro _ h; exact False.elim h
      | some sc =>
        intro hab hbc
        exact hab.trans hbc

/--
When both records carry a basis, absence of an edge means their resources
differ. That difference is the independence witness used by disjoint apply.
-/
theorem no_edge_witnesses_disjoint
    (a : CallRecord α β) (b : CallRecord γ δ)
    (sa : Basis) (sb : Basis)
    (ha : a.basis = some sa) (hb : b.basis = some sb) :
    ¬ hasEdge a b → sa.resource ≠ sb.resource := by
  unfold hasEdge
  intro hne
  simp [ha, hb] at hne
  exact hne

#print axioms has_edge_symm
#print axioms has_edge_trans
#print axioms no_edge_witnesses_disjoint

end Necoherence
