-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.Core

namespace Necoherence

structure PositiveRational where
  numerator : Nat
  denominator : Nat
  numerator_pos : numerator > 0
  denominator_pos : denominator > 0
  deriving DecidableEq, Repr

structure NonnegativeRational where
  numerator : Nat
  denominator : Nat
  denominator_pos : denominator > 0
  deriving DecidableEq, Repr

def NonnegativeRational.zero : NonnegativeRational := { numerator := 0, denominator := 1, denominator_pos := by decide }
def NonnegativeRational.ofNat (n : Nat) : NonnegativeRational := { numerator := n, denominator := 1, denominator_pos := by decide }
def NonnegativeRational.add (a b : NonnegativeRational) : NonnegativeRational := { numerator := a.numerator * b.denominator + b.numerator * a.denominator, denominator := a.denominator * b.denominator, denominator_pos := Nat.mul_pos a.denominator_pos b.denominator_pos }
def NonnegativeRational.mul (a b : NonnegativeRational) : NonnegativeRational := { numerator := a.numerator * b.numerator, denominator := a.denominator * b.denominator, denominator_pos := Nat.mul_pos a.denominator_pos b.denominator_pos }
def rationalEq (a b : NonnegativeRational) : Bool := decide (a.numerator * b.denominator = b.numerator * a.denominator)
def rationalLe (a b : NonnegativeRational) : Bool := decide (a.numerator * b.denominator ≤ b.numerator * a.denominator)
def rationalIsZero (a : NonnegativeRational) : Bool := decide (a.numerator = 0)
def rationalEqBool := rationalEq

structure InputElement where
  elementId : String
  inputWeight : PositiveRational
  measureContribution : NonnegativeRational
  deriving DecidableEq, Repr

inductive FiniteInputTree where
  | leaf : InputElement → FiniteInputTree
  | branch : String → List FiniteInputTree → FiniteInputTree

structure FiniteInputDomain where
  elements : List InputElement
  deriving DecidableEq, Repr

structure TypeDeclaration where
  typeId : String
  values : List String
  deriving DecidableEq, Repr

structure ValueDeclaration where
  valueId : String
  typeId : String
  deriving DecidableEq, Repr

structure Branch where
  branchId : String
  inputRegion : List String
  requiredType : String
  requiredValues : List String
  deriving DecidableEq, Repr

structure AxiomDeclaration where
  axiomId : String
  inputType : String
  outputType : String
  closedOutputCandidates : List String
  deriving DecidableEq, Repr

structure CanonicalResidualVector where
  label : String
  inhabited : Bool
  extent : NonnegativeRational
  deriving DecidableEq, Repr

structure FiniteResidualModelInput where
  inputTree : FiniteInputTree
  inputDomain : FiniteInputDomain
  typeDeclarations : List TypeDeclaration
  valueDeclarations : List ValueDeclaration
  branches : List Branch
  declaredReachability : List String
  axiomDeclarations : List AxiomDeclaration

structure FiniteResidualModel extends FiniteResidualModelInput where
  derivedReachability : List String

instance : Repr FiniteResidualModel where
  reprPrec _ _ := "FiniteResidualModel"

inductive ResidualCoherenceAnalysisFailure where
  | invalidFiniteModel
  | typeClosureFailure
  | branchCoverageFailure
  | axiomClosureFailure
  | arithmeticFailure
  deriving DecidableEq, Repr

structure ResidualCoherenceMeasure where
  residualInhabited : Bool
  residualExtent : NonnegativeRational
  declaredExtent : NonnegativeRational
  derivedExtent : NonnegativeRational
  deriving DecidableEq, Repr

structure ResidualCoherenceVectorSet where
  vectors : List CanonicalResidualVector
  deriving DecidableEq, Repr

structure ResidualCoherenceVerificationInput where
  model : FiniteResidualModel
  measure : ResidualCoherenceMeasure
  vectors : ResidualCoherenceVectorSet
  deriving Repr

structure ResidualCoherenceVerification where
  buildResult : Bool
  vectorResults : List Bool
  unobservedScope : List String
  deriving DecidableEq, Repr

def measureContributionSum (elements : List InputElement) : NonnegativeRational := elements.foldl (fun total element => total.add element.measureContribution) NonnegativeRational.zero
def residualExtent := measureContributionSum
def idsOfTree : FiniteInputTree → List String | .leaf e => [e.elementId] | .branch _ children => children.flatMap idsOfTree
def treeIds (input : FiniteResidualModelInput) : List String := idsOfTree input.inputTree
def domainIds (input : FiniteResidualModelInput) : List String := input.inputDomain.elements.map InputElement.elementId
def allIn (xs ys : List String) : Bool := xs.all (fun x => ys.contains x)
def noDup (xs : List String) : Bool := xs.Nodup
def validateInputTree (input : FiniteResidualModelInput) : Bool := noDup (treeIds input) && noDup (domainIds input) && allIn (treeIds input) (domainIds input) && allIn (domainIds input) (treeIds input)
def validateWeights (input : FiniteResidualModelInput) : Bool := input.inputDomain.elements.all (fun e => decide (e.inputWeight.numerator > 0))
def validateTypes (input : FiniteResidualModelInput) : Bool := input.valueDeclarations.all (fun v => input.typeDeclarations.any (fun t => t.typeId = v.typeId))
def validateBranches (input : FiniteResidualModelInput) : Bool := input.branches.all (fun b => allIn b.inputRegion (domainIds input))
def validateAxioms (input : FiniteResidualModelInput) : Bool := input.axiomDeclarations.all (fun a => input.typeDeclarations.any (fun t => t.typeId = a.inputType) && input.typeDeclarations.any (fun t => t.typeId = a.outputType))
def derivedReachabilityOf (input : FiniteResidualModelInput) : List String := ((input.branches.flatMap Branch.inputRegion ++ input.valueDeclarations.map ValueDeclaration.valueId ++ input.axiomDeclarations.flatMap AxiomDeclaration.closedOutputCandidates).filter (fun id => (domainIds input).contains id)).eraseDups

def validateFiniteResidualModel (input : FiniteResidualModelInput) : Except ResidualCoherenceAnalysisFailure FiniteResidualModel := if !validateInputTree input then .error .invalidFiniteModel else if !validateWeights input then .error .arithmeticFailure else if !validateTypes input then .error .typeClosureFailure else if !validateBranches input then .error .branchCoverageFailure else if !validateAxioms input then .error .axiomClosureFailure else .ok { input with derivedReachability := derivedReachabilityOf input }
def residualPoints (model : FiniteResidualModel) : List InputElement := model.inputDomain.elements.filter (fun e => model.derivedReachability.contains e.elementId && !model.declaredReachability.contains e.elementId)
def residualInhabited (model : FiniteResidualModel) : Bool := decide (residualPoints model != [])
def extentOnIds (model : FiniteResidualModel) (ids : List String) : NonnegativeRational := measureContributionSum (model.inputDomain.elements.filter (fun e => ids.contains e.elementId))
def residualCoherence (model : FiniteResidualModel) : Except ResidualCoherenceAnalysisFailure ResidualCoherenceMeasure := .ok { residualInhabited := residualInhabited model, residualExtent := measureContributionSum (residualPoints model), declaredExtent := extentOnIds model model.declaredReachability, derivedExtent := extentOnIds model model.derivedReachability }
def canonicalResidualVectors (model : FiniteResidualModel) : Except ResidualCoherenceAnalysisFailure ResidualCoherenceVectorSet := .ok { vectors := model.inputDomain.elements.map (fun e => { label := e.elementId, inhabited := (residualPoints model).any (fun r => r.elementId = e.elementId), extent := e.measureContribution }) }
def composeResidualProducts (model : FiniteResidualModel) : Except ResidualCoherenceAnalysisFailure ResidualCoherenceVerificationInput := do let measure ← residualCoherence model; let vectors ← canonicalResidualVectors model; pure { model := model, measure := measure, vectors := vectors }
def vectorResultsFor (model : FiniteResidualModel) (vectors : ResidualCoherenceVectorSet) : List Bool := vectors.vectors.map (fun v => model.inputDomain.elements.any (fun e => e.elementId = v.label))
def sameMeasure (left right : ResidualCoherenceMeasure) : Bool := rationalEq left.residualExtent right.residualExtent && left.residualInhabited == right.residualInhabited && rationalEq left.declaredExtent right.declaredExtent && rationalEq left.derivedExtent right.derivedExtent
def sameExtentList : List NonnegativeRational → List NonnegativeRational → Bool
  | [], [] => true
  | a :: as, b :: bs => rationalEq a b && sameExtentList as bs
  | _, _ => false
def sameVectorSet (left right : ResidualCoherenceVectorSet) : Bool := left.vectors.map CanonicalResidualVector.label = right.vectors.map CanonicalResidualVector.label && left.vectors.map CanonicalResidualVector.inhabited = right.vectors.map CanonicalResidualVector.inhabited && sameExtentList (left.vectors.map CanonicalResidualVector.extent) (right.vectors.map CanonicalResidualVector.extent)
def residualCoherenceVerification (input : ResidualCoherenceVerificationInput) : Except ResidualCoherenceAnalysisFailure ResidualCoherenceVerification := do let recomputed ← composeResidualProducts input.model; let measureOk := sameMeasure recomputed.measure input.measure; let vectorOk := sameVectorSet recomputed.vectors input.vectors; pure { buildResult := measureOk && vectorOk, vectorResults := vectorResultsFor input.model input.vectors, unobservedScope := (if measureOk then [] else ["measure"]) ++ (if vectorOk then [] else ["vectors"]) }
def productContribution (a b : NonnegativeRational) := NonnegativeRational.mul a b

end Necoherence
