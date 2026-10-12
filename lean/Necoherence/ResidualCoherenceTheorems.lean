-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.ResidualCoherence

/-!
General theorems over the finite residual coherence model.

Each theorem quantifies over arbitrary inputs, or states an explicit
hypothesis when the property does not hold unconditionally. Concrete numeric
witnesses and regression checks live in `Tests.ResidualCoherenceTheorems`.
-/

namespace Necoherence

/-! ### Nonnegative rational arithmetic facts used by the theorems below -/

theorem rational_add_comm (a b : NonnegativeRational) : a.add b = b.add a := by
  simp only [NonnegativeRational.add]; congr 1 <;> ac_rfl

theorem rational_add_assoc (a b c : NonnegativeRational) : (a.add b).add c = a.add (b.add c) := by
  simp only [NonnegativeRational.add]
  congr 1
  · simp only [Nat.add_mul]; ac_rfl
  · ac_rfl

theorem rational_add_left_comm (a b c : NonnegativeRational) : a.add (b.add c) = b.add (a.add c) := by
  rw [← rational_add_assoc, rational_add_comm a b, rational_add_assoc]

theorem zero_add_eq (b : NonnegativeRational) : NonnegativeRational.zero.add b = b := by
  simp only [NonnegativeRational.add, NonnegativeRational.zero]; congr 1 <;> simp

theorem add_zero_eq (a : NonnegativeRational) : a.add NonnegativeRational.zero = a := by
  simp only [NonnegativeRational.add, NonnegativeRational.zero]; congr 1 <;> simp

theorem rationalLe_refl (a : NonnegativeRational) : rationalLe a a = true := by simp [rationalLe]

theorem rationalLe_add_self (a b : NonnegativeRational) : rationalLe a (a.add b) = true := by
  simp only [rationalLe, NonnegativeRational.add, decide_eq_true_eq]
  have heq : a.numerator * (a.denominator * b.denominator) = a.numerator * b.denominator * a.denominator := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  rw [heq]
  exact Nat.mul_le_mul_right a.denominator (Nat.le_add_right _ _)

theorem rationalLe_trans (a b c : NonnegativeRational) (hab : rationalLe a b = true) (hbc : rationalLe b c = true) :
    rationalLe a c = true := by
  simp only [rationalLe, decide_eq_true_eq] at *
  have hdb := b.denominator_pos
  have h1 : a.numerator * b.denominator * c.denominator ≤ b.numerator * a.denominator * c.denominator :=
    Nat.mul_le_mul_right c.denominator hab
  have h2 : b.numerator * c.denominator * a.denominator ≤ c.numerator * b.denominator * a.denominator :=
    Nat.mul_le_mul_right a.denominator hbc
  have key : b.denominator * (a.numerator * c.denominator) ≤ b.denominator * (c.numerator * a.denominator) := by
    calc b.denominator * (a.numerator * c.denominator)
        = a.numerator * b.denominator * c.denominator := by simp [Nat.mul_comm, Nat.mul_left_comm]
      _ ≤ b.numerator * a.denominator * c.denominator := h1
      _ = b.numerator * c.denominator * a.denominator := by simp [Nat.mul_comm, Nat.mul_left_comm]
      _ ≤ c.numerator * b.denominator * a.denominator := h2
      _ = b.denominator * (c.numerator * a.denominator) := by simp [Nat.mul_comm, Nat.mul_left_comm]
  exact Nat.le_of_mul_le_mul_left key hdb

theorem rationalLe_add_mono_left (a b c : NonnegativeRational) (h : rationalLe a b = true) :
    rationalLe (a.add c) (b.add c) = true := by
  simp only [rationalLe, NonnegativeRational.add, decide_eq_true_eq] at h ⊢
  have step1 : a.numerator * c.denominator * (b.denominator * c.denominator)
      = (a.numerator * b.denominator) * (c.denominator * c.denominator) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  have step2 : b.numerator * c.denominator * (a.denominator * c.denominator)
      = (b.numerator * a.denominator) * (c.denominator * c.denominator) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  have step3 : c.numerator * a.denominator * (b.denominator * c.denominator)
      = c.numerator * b.denominator * (a.denominator * c.denominator) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  have hmain : (a.numerator * b.denominator) * (c.denominator * c.denominator)
      ≤ (b.numerator * a.denominator) * (c.denominator * c.denominator) :=
    Nat.mul_le_mul_right (c.denominator * c.denominator) h
  calc (a.numerator * c.denominator + c.numerator * a.denominator) * (b.denominator * c.denominator)
      = a.numerator * c.denominator * (b.denominator * c.denominator)
          + c.numerator * a.denominator * (b.denominator * c.denominator) := by
        rw [Nat.add_mul]
    _ = (a.numerator * b.denominator) * (c.denominator * c.denominator)
          + c.numerator * b.denominator * (a.denominator * c.denominator) := by rw [step1, step3]
    _ ≤ (b.numerator * a.denominator) * (c.denominator * c.denominator)
          + c.numerator * b.denominator * (a.denominator * c.denominator) :=
        Nat.add_le_add_right hmain _
    _ = b.numerator * c.denominator * (a.denominator * c.denominator)
          + c.numerator * b.denominator * (a.denominator * c.denominator) := by rw [step2]
    _ = (b.numerator * c.denominator + c.numerator * b.denominator) * (a.denominator * c.denominator) := by
        rw [← Nat.add_mul]

theorem rationalEq_trans (a b c : NonnegativeRational) (hab : rationalEq a b = true) (hbc : rationalEq b c = true) :
    rationalEq a c = true := by
  simp only [rationalEq, decide_eq_true_eq] at *
  have hdb := b.denominator_pos
  have h1 : a.numerator * b.denominator * c.denominator = b.numerator * a.denominator * c.denominator := by rw [hab]
  have h2 : b.numerator * c.denominator * a.denominator = c.numerator * b.denominator * a.denominator := by rw [hbc]
  have key : b.denominator * (a.numerator * c.denominator) = b.denominator * (c.numerator * a.denominator) := by
    calc b.denominator * (a.numerator * c.denominator)
        = a.numerator * b.denominator * c.denominator := by simp [Nat.mul_comm, Nat.mul_left_comm]
      _ = b.numerator * a.denominator * c.denominator := h1
      _ = b.numerator * c.denominator * a.denominator := by simp [Nat.mul_comm, Nat.mul_left_comm]
      _ = c.numerator * b.denominator * a.denominator := h2
      _ = b.denominator * (c.numerator * a.denominator) := by simp [Nat.mul_comm, Nat.mul_left_comm]
  exact Nat.eq_of_mul_eq_mul_left hdb key

theorem rationalEq_add_congr_left (a b c : NonnegativeRational) (h : rationalEq a b = true) :
    rationalEq (a.add c) (b.add c) = true := by
  simp only [rationalEq, NonnegativeRational.add, decide_eq_true_eq] at h ⊢
  have step1 : a.numerator * c.denominator * (b.denominator * c.denominator)
      = (a.numerator * b.denominator) * (c.denominator * c.denominator) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  have step2 : b.numerator * c.denominator * (a.denominator * c.denominator)
      = (b.numerator * a.denominator) * (c.denominator * c.denominator) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  have step3 : c.numerator * a.denominator * (b.denominator * c.denominator)
      = c.numerator * b.denominator * (a.denominator * c.denominator) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  calc (a.numerator * c.denominator + c.numerator * a.denominator) * (b.denominator * c.denominator)
      = a.numerator * c.denominator * (b.denominator * c.denominator)
          + c.numerator * a.denominator * (b.denominator * c.denominator) := by rw [Nat.add_mul]
    _ = (a.numerator * b.denominator) * (c.denominator * c.denominator)
          + c.numerator * b.denominator * (a.denominator * c.denominator) := by rw [step1, step3]
    _ = (b.numerator * a.denominator) * (c.denominator * c.denominator)
          + c.numerator * b.denominator * (a.denominator * c.denominator) := by rw [h]
    _ = b.numerator * c.denominator * (a.denominator * c.denominator)
          + c.numerator * b.denominator * (a.denominator * c.denominator) := by rw [step2]
    _ = (b.numerator * c.denominator + c.numerator * b.denominator) * (a.denominator * c.denominator) := by
        rw [← Nat.add_mul]

theorem add_numerator_zero_iff (a b : NonnegativeRational) :
    (a.add b).numerator = 0 ↔ a.numerator = 0 ∧ b.numerator = 0 := by
  simp only [NonnegativeRational.add]
  constructor
  · intro h
    have hden_a := a.denominator_pos
    have hden_b := b.denominator_pos
    have h1 : a.numerator * b.denominator = 0 := by omega
    have h2 : b.numerator * a.denominator = 0 := by omega
    constructor
    · rcases Nat.mul_eq_zero.mp h1 with h' | h'
      · exact h'
      · omega
    · rcases Nat.mul_eq_zero.mp h2 with h' | h'
      · exact h'
      · omega
  · rintro ⟨ha, hb⟩
    simp [ha, hb]

/-! ### `measureContributionSum` combinators over the underlying `foldl` -/

theorem measureContributionSum_nil :
    measureContributionSum ([] : List InputElement) = NonnegativeRational.zero := rfl

theorem foldl_add_eq_fold_add_acc (l : List InputElement) (acc : NonnegativeRational) :
    List.foldl (fun total el => total.add el.measureContribution) acc l =
      acc.add (List.foldl (fun total el => total.add el.measureContribution) NonnegativeRational.zero l) := by
  induction l generalizing acc with
  | nil => simp [add_zero_eq]
  | cons hd tl ih =>
    simp only [List.foldl_cons]
    rw [ih (acc.add hd.measureContribution), ih (NonnegativeRational.zero.add hd.measureContribution), zero_add_eq,
      rational_add_assoc]

theorem measureContributionSum_cons (e : InputElement) (l : List InputElement) :
    measureContributionSum (e :: l) = e.measureContribution.add (measureContributionSum l) := by
  simp only [measureContributionSum, List.foldl_cons]
  rw [foldl_add_eq_fold_add_acc l (NonnegativeRational.zero.add e.measureContribution), zero_add_eq]

theorem measureContributionSum_append (l1 l2 : List InputElement) :
    measureContributionSum (l1 ++ l2) =
      (measureContributionSum l1).add (measureContributionSum l2) := by
  induction l1 with
  | nil => simp [measureContributionSum_nil, zero_add_eq]
  | cons hd tl ih =>
    simp only [List.cons_append, measureContributionSum_cons, ih, rational_add_assoc]

theorem foldl_add_sublist_le (l l' : List InputElement) (hsub : l.Sublist l') :
    ∀ acc : NonnegativeRational, rationalLe (List.foldl (fun total el => total.add el.measureContribution) acc l)
      (List.foldl (fun total el => total.add el.measureContribution) acc l') = true := by
  have foldl_acc_mono : ∀ (l : List InputElement) (acc1 acc2 : NonnegativeRational),
      rationalLe acc1 acc2 = true →
      rationalLe (List.foldl (fun total el => total.add el.measureContribution) acc1 l)
        (List.foldl (fun total el => total.add el.measureContribution) acc2 l) = true := by
    intro l
    induction l with
    | nil => intro acc1 acc2 h; simpa using h
    | cons hd tl ih =>
      intro acc1 acc2 h
      simp only [List.foldl_cons]
      exact ih _ _ (rationalLe_add_mono_left acc1 acc2 hd.measureContribution h)
  induction hsub with
  | slnil => intro acc; exact rationalLe_refl acc
  | cons hd h ih =>
    intro acc
    simp only [List.foldl_cons]
    exact rationalLe_trans _ _ _ (ih acc)
      (foldl_acc_mono _ acc (acc.add hd.measureContribution) (rationalLe_add_self acc hd.measureContribution))
  | cons_cons hd h ih =>
    intro acc
    simp only [List.foldl_cons]
    exact ih (acc.add hd.measureContribution)

theorem filter_sublist_of_implies (l : List InputElement) (p q : InputElement → Bool)
    (h : ∀ x ∈ l, p x = true → q x = true) :
    (l.filter p).Sublist (l.filter q) := by
  induction l with
  | nil => simp
  | cons hd tl ih =>
    simp only [List.filter_cons]
    by_cases hp : p hd = true
    · have hq : q hd = true := h hd List.mem_cons_self hp
      simp only [hp, hq, if_true]
      exact List.Sublist.cons_cons hd (ih (fun x hx => h x (List.mem_cons_of_mem hd hx)))
    · simp only [hp]
      by_cases hq : q hd = true
      · simp only [hq, if_true]
        exact List.Sublist.cons hd (ih (fun x hx => h x (List.mem_cons_of_mem hd hx)))
      · simp only [hq]
        exact ih (fun x hx => h x (List.mem_cons_of_mem hd hx))

theorem partition_sum (l : List InputElement) (p q : InputElement → Bool)
    (hdisjoint : ∀ e ∈ l, ¬ (p e = true ∧ q e = true)) :
    measureContributionSum (l.filter (fun e => p e || q e)) =
      (measureContributionSum (l.filter p)).add (measureContributionSum (l.filter q)) := by
  induction l with
  | nil => simp [measureContributionSum_nil, zero_add_eq]
  | cons hd tl ih =>
    have ih' := ih (fun e he => hdisjoint e (List.mem_cons_of_mem hd he))
    rw [List.filter_cons, List.filter_cons, List.filter_cons]
    by_cases hp : p hd = true
    · have hqf : q hd = false := by
        cases hqc : q hd with
        | false => rfl
        | true => exact absurd ⟨hp, hqc⟩ (hdisjoint hd List.mem_cons_self)
      rw [if_pos (by simp [hp]), if_pos hp, if_neg (by simp [hqf])]
      rw [measureContributionSum_cons, measureContributionSum_cons, ih', rational_add_assoc]
    · have hpf : p hd = false := by simpa using hp
      by_cases hq : q hd = true
      · rw [if_pos (by simp [hq]), if_neg (by simp [hpf]), if_pos hq]
        rw [measureContributionSum_cons, measureContributionSum_cons, ih']
        rw [rational_add_left_comm]
      · have hqf : q hd = false := by simpa using hq
        rw [if_neg (by simp [hpf, hqf]), if_neg (by simp [hpf]), if_neg (by simp [hqf])]
        exact ih'

theorem foldl_add_numerator_zero (l : List InputElement) : ∀ acc : NonnegativeRational,
    (List.foldl (fun total el => total.add el.measureContribution) acc l).numerator = 0 →
    acc.numerator = 0 ∧ ∀ e ∈ l, e.measureContribution.numerator = 0 := by
  induction l with
  | nil => intro acc h; simpa using h
  | cons hd tl ih =>
    intro acc h
    simp only [List.foldl_cons] at h
    obtain ⟨hacc', hall⟩ := ih (acc.add hd.measureContribution) h
    obtain ⟨ha, hhd⟩ := add_numerator_zero_iff acc hd.measureContribution |>.mp hacc'
    refine ⟨ha, ?_⟩
    intro e he
    rcases List.mem_cons.mp he with heq | hmem
    · subst heq; exact hhd
    · exact hall e hmem

/-! ### The residual coherence theorems -/

/-- The residual coherence measure never reports a negative extent. -/
theorem Nonnegativity (model : FiniteResidualModel) (measure : ResidualCoherenceMeasure)
    (h : residualCoherence model = .ok measure) :
    rationalLe NonnegativeRational.zero measure.residualExtent = true := by
  simp only [residualCoherence] at h
  injection h with hm
  subst hm
  simp [rationalLe, NonnegativeRational.zero]

/-- If every derived-reachable element is also declared reachable, the
residual points set is empty: there is nothing left over to attribute to the
residual. -/
theorem DeclaredZero (model : FiniteResidualModel)
    (h : ∀ id, id ∈ model.derivedReachability → id ∈ model.declaredReachability) :
    residualPoints model = [] := by
  simp only [residualPoints, List.filter_eq_nil_iff]
  intro e _
  simp only [Bool.and_eq_true, Bool.not_eq_true']
  intro hmem
  have hin : e.elementId ∈ model.derivedReachability := List.contains_iff_mem.mp hmem.1
  have hdecl : model.declaredReachability.contains e.elementId = true :=
    List.contains_iff_mem.mpr (h e.elementId hin)
  rw [hdecl] at hmem
  exact absurd hmem.2 (by simp)

/-- If the residual extent is zero, every residual point individually
contributes zero measure: no residual point can be masked by cancellation,
since contributions are nonnegative. -/
theorem ZeroResidualClosure (model : FiniteResidualModel)
    (h : rationalIsZero (measureContributionSum (residualPoints model)) = true) :
    ∀ e ∈ residualPoints model, rationalIsZero e.measureContribution = true := by
  simp only [rationalIsZero, decide_eq_true_eq] at h
  intro e he
  have := (foldl_add_numerator_zero (residualPoints model) NonnegativeRational.zero h).2 e he
  simp only [rationalIsZero, decide_eq_true_eq]
  exact this

/-- Widening the derived reachability set never decreases the residual
extent: the extra ids can only grow the residual point set, and every
element's contribution is nonnegative. -/
theorem ReachabilityMonotonicity (model : FiniteResidualModel) (extra : List String) :
    rationalLe (measureContributionSum (residualPoints model))
      (measureContributionSum (residualPoints
        { model with derivedReachability := model.derivedReachability ++ extra })) = true := by
  have hsub : (residualPoints model).Sublist
      (residualPoints { model with derivedReachability := model.derivedReachability ++ extra }) := by
    apply filter_sublist_of_implies
    intro e _ he
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at he ⊢
    obtain ⟨hd, hc⟩ := he
    refine ⟨?_, hc⟩
    have hin : e.elementId ∈ model.derivedReachability := List.contains_iff_mem.mp hd
    exact List.contains_iff_mem.mpr (List.mem_append_left extra hin)
  exact foldl_add_sublist_le _ _ hsub NonnegativeRational.zero

/-- Contributions over two id lists that never share a domain id add without
interference: the extent of the union equals the sum of the separate
extents. -/
theorem BranchAdditivity (model : FiniteResidualModel) (idsA idsB : List String)
    (hdisjoint : ∀ id, id ∈ idsA → id ∈ idsB → False) :
    rationalEq (extentOnIds model (idsA ++ idsB))
      (NonnegativeRational.add (extentOnIds model idsA) (extentOnIds model idsB)) = true := by
  simp only [extentOnIds]
  have hfilter : model.inputDomain.elements.filter (fun e => (idsA ++ idsB).contains e.elementId) =
      model.inputDomain.elements.filter (fun e => idsA.contains e.elementId || idsB.contains e.elementId) := by
    congr 1
    funext e
    simp
  rw [hfilter, partition_sum]
  · simp [rationalEq]
  · intro e _ ⟨ha, hb⟩
    exact hdisjoint e.elementId (List.contains_iff_mem.mp ha) (List.contains_iff_mem.mp hb)

/-- The product contribution of two nonnegative rationals is exactly their
multiplicative combination, matching the independent-coordinate reading of a
product measure. -/
theorem ProductMeasure (a b : NonnegativeRational) :
    productContribution a b = NonnegativeRational.mul a b := rfl

/-- Replacing one domain element by a weight-preserving pair of finer
elements whose combined measure contribution equals the original leaves the
total measure contribution over the domain unchanged. -/
theorem RefinementInvariance (elements : List InputElement) (e replacementA replacementB : InputElement)
    (hsplit : rationalEq e.measureContribution
      (NonnegativeRational.add replacementA.measureContribution replacementB.measureContribution) = true) :
    rationalEq (measureContributionSum (e :: elements))
      (measureContributionSum (replacementA :: replacementB :: elements)) = true := by
  rw [measureContributionSum_cons, measureContributionSum_cons, measureContributionSum_cons,
    ← rational_add_assoc]
  exact rationalEq_add_congr_left e.measureContribution
    (replacementA.measureContribution.add replacementB.measureContribution) (measureContributionSum elements) hsplit

/-- Reordering the input elements does not change the total measure
contribution: `measureContributionSum` only depends on the multiset of
contributions, since `NonnegativeRational.add` is commutative and
associative. -/
theorem WeightPreservingPermutation (elements elements' : List InputElement)
    (hperm : elements.Perm elements') :
    rationalEq (measureContributionSum elements) (measureContributionSum elements') = true := by
  have foldl_add_left_comm : ∀ z : NonnegativeRational, ∀ x y : InputElement,
      (z.add x.measureContribution).add y.measureContribution =
        (z.add y.measureContribution).add x.measureContribution := by
    intro z x y
    rw [rational_add_assoc, rational_add_assoc, rational_add_comm x.measureContribution y.measureContribution]
  have heq : measureContributionSum elements = measureContributionSum elements' := by
    simp only [measureContributionSum]
    exact List.Perm.foldl_eq' hperm (fun x _ y _ z => foldl_add_left_comm z x y) NonnegativeRational.zero
  rw [heq]
  simp [rationalEq]

/-- Replacing a `FiniteResidualModel`'s `axiomDeclarations` by any other list
leaves `residualPoints` unchanged: once the input tree, domain, types,
branches, and both reachability sets are fixed, `residualPoints` never reads
`axiomDeclarations` again, so the axiom declaration's content is not
reinterpreted after the model has been validated and its reachability
determined. -/
theorem AxiomOpacity (model : FiniteResidualModel) (axiomDeclarations' : List AxiomDeclaration) :
    residualPoints { model with axiomDeclarations := axiomDeclarations' } = residualPoints model := rfl

/-- The same opacity fact restated at the level of the published measure:
replacing `axiomDeclarations` by any other list leaves `residualCoherence`
unchanged. -/
theorem AxiomOpacity_residualCoherence (model : FiniteResidualModel) (axiomDeclarations' : List AxiomDeclaration) :
    residualCoherence { model with axiomDeclarations := axiomDeclarations' } = residualCoherence model := rfl

/-- Composing the model, measure, and vector products always yields a
verification input whose model component is the original model, whose
measure component is exactly what `residualCoherence` computes for that
model, and whose vectors component is exactly what `canonicalResidualVectors`
computes for that model: a downstream Cell can uniquely recover not just the
model but every product it built from a successful composition. -/
theorem Composability (model : FiniteResidualModel) (input : ResidualCoherenceVerificationInput)
    (h : composeResidualProducts model = .ok input) :
    input.model = model ∧ residualCoherence model = .ok input.measure ∧
      canonicalResidualVectors model = .ok input.vectors := by
  cases hMeasure : residualCoherence model with
  | error failure =>
    exact absurd hMeasure (by simp [residualCoherence])
  | ok measure =>
    cases hVectors : canonicalResidualVectors model with
    | error failure =>
      exact absurd hVectors (by simp [canonicalResidualVectors])
    | ok vectors =>
      have hbuild : composeResidualProducts model = .ok { model := model, measure := measure, vectors := vectors } := by
        unfold composeResidualProducts
        rw [hMeasure, hVectors]
        rfl
      rw [hbuild] at h
      injection h with hinput
      subst hinput
      exact ⟨rfl, rfl, rfl⟩

end Necoherence
