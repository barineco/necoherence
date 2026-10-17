-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.ResidualCoherenceTheorems



namespace Necoherence

private def elemA : InputElement :=
  { elementId := "a"
    inputWeight := { numerator := 1, denominator := 1, numerator_pos := by decide, denominator_pos := by decide }
    measureContribution := { numerator := 3, denominator := 4, denominator_pos := by decide } }

private def elemB : InputElement :=
  { elementId := "b"
    inputWeight := { numerator := 1, denominator := 1, numerator_pos := by decide, denominator_pos := by decide }
    measureContribution := { numerator := 1, denominator := 4, denominator_pos := by decide } }

private def elemZero : InputElement :=
  { elementId := "z"
    inputWeight := { numerator := 1, denominator := 1, numerator_pos := by decide, denominator_pos := by decide }
    measureContribution := { numerator := 0, denominator := 1, denominator_pos := by decide } }



example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [],
        derivedReachability := ["a"] }
    ∀ measure, residualCoherence model = .ok measure →
      rationalLe NonnegativeRational.zero measure.residualExtent = true := by
  intro model measure h
  exact Nonnegativity model measure h



example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := ["a"], axiomDeclarations := [],
        derivedReachability := ["a"] }
    residualPoints model = [] := by
  intro model
  exact DeclaredZero model (fun id hid => by simpa using hid)


example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := ["a"], axiomDeclarations := [],
        derivedReachability := ["a"] }
    rationalIsZero (measureContributionSum (residualPoints model)) = true := by decide



example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemZero, inputDomain := { elements := [elemZero] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [],
        derivedReachability := ["z"] }
    ∀ e ∈ residualPoints model, rationalIsZero e.measureContribution = true := by
  intro model
  have h : rationalIsZero (measureContributionSum (residualPoints model)) = true := by decide
  exact ZeroResidualClosure model h



example :
    let model : FiniteResidualModel :=
      { inputTree := .branch "root" [.leaf elemA, .leaf elemB], inputDomain := { elements := [elemA, elemB] },
        typeDeclarations := [], valueDeclarations := [], branches := [], declaredReachability := [],
        axiomDeclarations := [], derivedReachability := ["a"] }
    rationalLe (measureContributionSum (residualPoints model))
      (measureContributionSum (residualPoints { model with derivedReachability := model.derivedReachability ++ ["b"] })) = true := by
  intro model
  exact ReachabilityMonotonicity model ["b"]



example :
    let model : FiniteResidualModel :=
      { inputTree := .branch "root" [.leaf elemA, .leaf elemB], inputDomain := { elements := [elemA, elemB] },
        typeDeclarations := [], valueDeclarations := [], branches := [], declaredReachability := [],
        axiomDeclarations := [], derivedReachability := [] }
    rationalEq (extentOnIds model (["a"] ++ ["b"]))
      (NonnegativeRational.add (extentOnIds model ["a"]) (extentOnIds model ["b"])) = true := by
  intro model
  exact BranchAdditivity model ["a"] ["b"] (by
    intro id ha hb
    simp only [List.mem_singleton] at ha hb
    rw [ha] at hb
    exact absurd hb (by decide))


example :
    let model : FiniteResidualModel :=
      { inputTree := .branch "root" [.leaf elemA, .leaf elemB], inputDomain := { elements := [elemA, elemB] },
        typeDeclarations := [], valueDeclarations := [], branches := [], declaredReachability := [],
        axiomDeclarations := [], derivedReachability := [] }
    rationalEq (extentOnIds model ["a", "b"]) { numerator := 1, denominator := 1, denominator_pos := by decide } = true := by
  decide



example :
    productContribution { numerator := 2, denominator := 3, denominator_pos := by decide }
      { numerator := 3, denominator := 5, denominator_pos := by decide } =
      { numerator := 6, denominator := 15, denominator_pos := by decide } :=
  ProductMeasure _ _

example :
    rationalEq (productContribution { numerator := 2, denominator := 3, denominator_pos := by decide }
      { numerator := 3, denominator := 5, denominator_pos := by decide })
      { numerator := 2, denominator := 5, denominator_pos := by decide } = true := by decide



example :
    rationalEq (measureContributionSum [elemA])
      (measureContributionSum [{ elemA with elementId := "a1", measureContribution := { numerator := 1, denominator := 2, denominator_pos := by decide } },
        { elemA with elementId := "a2", measureContribution := { numerator := 1, denominator := 4, denominator_pos := by decide } }]) = true := by
  have hsplit : rationalEq elemA.measureContribution
      (NonnegativeRational.add ({ numerator := 1, denominator := 2, denominator_pos := (by decide : (2:Nat) > 0) } : NonnegativeRational)
        { numerator := 1, denominator := 4, denominator_pos := by decide }) = true := by decide
  exact RefinementInvariance [] elemA
    { elemA with elementId := "a1", measureContribution := { numerator := 1, denominator := 2, denominator_pos := by decide } }
    { elemA with elementId := "a2", measureContribution := { numerator := 1, denominator := 4, denominator_pos := by decide } }
    hsplit



example : rationalEq (measureContributionSum [elemA, elemB]) (measureContributionSum [elemB, elemA]) = true :=
  WeightPreservingPermutation [elemA, elemB] [elemB, elemA] (List.Perm.swap elemB elemA [])




theorem InhabitedZeroMeasureDistinction_witness :
    ∃ model : FiniteResidualModel,
      residualInhabited model = true ∧
      rationalIsZero (measureContributionSum (residualPoints model)) = true := by
  let model : FiniteResidualModel :=
    { inputTree := .leaf elemZero, inputDomain := { elements := [elemZero] }, typeDeclarations := [],
      valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [],
      derivedReachability := ["z"] }
  exact ⟨model, by decide, by decide⟩



private def axiomAlpha : AxiomDeclaration :=
  { axiomId := "alpha", inputType := "T", outputType := "T", closedOutputCandidates := [] }

private def axiomBeta : AxiomDeclaration :=
  { axiomId := "beta", inputType := "T", outputType := "T", closedOutputCandidates := ["a"] }


example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [axiomAlpha],
        derivedReachability := ["a"] }
    residualPoints { model with axiomDeclarations := [axiomBeta] } = residualPoints model := by
  intro model
  exact AxiomOpacity model [axiomBeta]


example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [axiomAlpha],
        derivedReachability := ["a"] }
    residualCoherence { model with axiomDeclarations := [axiomBeta] } = residualCoherence model := by
  intro model
  exact AxiomOpacity_residualCoherence model [axiomBeta]



example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [],
        derivedReachability := ["a"] }
    ∀ input, composeResidualProducts model = .ok input →
      input.model = model ∧ residualCoherence model = .ok input.measure ∧
        canonicalResidualVectors model = .ok input.vectors := by
  intro model input h
  exact Composability model input h


example :
    let model : FiniteResidualModel :=
      { inputTree := .leaf elemA, inputDomain := { elements := [elemA] }, typeDeclarations := [],
        valueDeclarations := [], branches := [], declaredReachability := [], axiomDeclarations := [],
        derivedReachability := ["a"] }
    (composeResidualProducts model).isOk = true := by decide

#print axioms Nonnegativity
#print axioms DeclaredZero
#print axioms ZeroResidualClosure
#print axioms ReachabilityMonotonicity
#print axioms BranchAdditivity
#print axioms ProductMeasure
#print axioms RefinementInvariance
#print axioms WeightPreservingPermutation
#print axioms InhabitedZeroMeasureDistinction_witness
#print axioms AxiomOpacity
#print axioms AxiomOpacity_residualCoherence
#print axioms Composability

end Necoherence
