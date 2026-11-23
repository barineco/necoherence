-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SignatureGeneration
import NecoherenceCompositionSolver.SemanticEvidence
import Lean.Data.Json

open Lean Necoherence Necoherence.SemanticComposition Necoherence.SemanticTypes Necoherence.SignatureWire

private def field (value : Json) (name : String) : Except String Json := value.getObjVal? name
private def text (value : Json) (name : String) : Except String String := (field value name).bind (·.getStr?)
private def token (target : String) : ColoredToken := { target, index := 0, revision := 1, kind := .input }
private def ready : Marking := { places := [("P-READY", [token "job-1"]), ("P-DONE", [])] }
private def fixture (goal : Nat) (closed : Bool) : SolverInput :=
  { places := [{ identity := "P-READY", tokenType := "T-JOB", revision := 1 }, { identity := "P-DONE", tokenType := "T-JOB", revision := 1 }]
    transitions := if closed then [] else [{ identity := "T-RUN", inputPlaces := ["P-READY"], outputPlaces := ["P-DONE"], failurePlaces := [], revision := 1 }]
    bindings := if closed then [] else [{ transitionId := "T-RUN", name := "job", place := "P-READY", tokenType := "T-JOB", identity := "job-1", provenance := "test", multiplicity := 1, mode := .consume, requiredRevision := 1 }]
    goal := .placeHasAtLeast "P-DONE" goal
    graph := { places := ["P-READY", "P-DONE"], transitions := if closed then [] else ["T-RUN"], edges := [("P-READY", "P-DONE")], revision := 1 }
    marking := ready
    bound := { targetIdentity := "unit", index := 0, revision := 1, maxBindings := 10, maxSearchSteps := 10 } }

private def result (case decision : String) (failure : Option String := none) : Json :=
  Json.mkObj ([ ("case", toJson case), ("decision", toJson decision) ] ++ (failure.map (fun value => [("failure", toJson value)])).getD [])
private def rejected (case failure constructor : String) (arguments : List Json := []) : Json :=
  Json.mkObj [("case", toJson case), ("decision", toJson "Rejected"), ("failure", toJson failure),
    ("detail", Json.mkObj [("constructor", toJson constructor), ("arguments", toJson arguments)])]
private def admissionFailureName : Necoherence.SignatureGeneration.AdmissionFailure → String
  | .unsupportedSchema _ => "UnsupportedSchema"
  | .entrypointsEmpty => "EntrypointsEmpty"
  | .entrypointIdentityEmpty => "EntrypointIdentityEmpty"
  | .entrypointDuplicate _ => "EntrypointDuplicate"
  | .entrypointUnresolved _ _ => "EntrypointUnresolved"
  | .library _ => "Library"
  | .certificate _ => "Certificate"
  | .wire _ => "Wire"
  | .compositionInput _ => "CompositionInput"
  | .composition _ => "Composition"
private def accepted (case : String) : Json := Json.mkObj [("case", toJson case), ("decision", toJson "Accepted"), ("failure", Json.null)]

private def pathJson (path : ValuePath) : Json :=
  toJson (path.map fun
    | .field name => Json.mkObj [("field", toJson name)]
    | .index index => Json.mkObj [("index", toJson index)]
    | .variant tag => Json.mkObj [("variant", toJson tag)])

private def sourceJson (source : SourceRef) : Json :=
  Json.mkObj [
    ("repository", toJson source.repository), ("revision", toJson source.revision),
    ("path", toJson source.path), ("contentDigest", toJson source.contentDigest),
    ("documentId", toJson source.documentId), ("declaredRevision", toJson source.declaredRevision)]

private def typeJson (ref : TypeRef) : Json :=
  Json.mkObj [
    ("source", sourceJson ref.source),
    ("definition", toJson ref.definitionName), ("pointer", toJson ref.pointer)]

private def functionJson (ref : FunctionRef) : Json :=
  Json.mkObj [("identity", toJson ref.identity), ("revision", toJson ref.revision),
    ("contentDigest", toJson ref.contentDigest)]

private def nested (constructor : String) (arguments : List Json := []) : Json :=
  Json.mkObj [("constructor", toJson constructor), ("arguments", toJson arguments)]

private def producerJson : ProducerRef → Json
  | .initial id => nested "initial" [toJson id.value]
  | .invocationOutcome site outcome port =>
      nested "invocationOutcome" [toJson site.value, toJson outcome.value, toJson port.value]

private def valueRefJson (ref : ValueRef) : Json :=
  Json.mkObj [("producer", producerJson ref.producer), ("path", pathJson ref.path)]

private def semanticReasonJson : SemanticReason → Json
  | .unknownFormat name => nested "unknownFormat" [toJson name]
  | .missingGraphemeRules => nested "missingGraphemeRules"
  | .missingBytesPolicy => nested "missingBytesPolicy"
  | .unknownIntegerDomain name => nested "unknownIntegerDomain" [toJson name]
  | .unknownWrapper name => nested "unknownWrapper" [toJson name]
  | .wrapperPayload name => nested "wrapperPayload" [toJson name]
  | .unknownSealedTag tag => nested "unknownSealedTag" [toJson tag]
  | .decimalNotAdmitted => nested "decimalNotAdmitted"
  | .integerBound => nested "integerBound"
  | .opaqueType name => nested "opaqueType" [toJson name]
  | .missingTagModel => nested "missingTagModel"
  | .uninterpretedExtension key => nested "uninterpretedExtension" [toJson key]
  | .unresolvedType => nested "unresolvedType"
  | .invalidProfile condition => nested "invalidProfile" [toJson condition]
  | .membershipBound => nested "membershipBound"
  | .certificateMismatch condition => nested "certificateMismatch" [toJson condition]
  | .projectionUnavailable condition => nested "projectionUnavailable" [toJson condition]

private def semanticObligationJson (obligation : SemanticObligation) : Json :=
  Json.mkObj [("typeRef", typeJson obligation.typeRef), ("valuePath", pathJson obligation.valuePath),
    ("reason", semanticReasonJson obligation.reason)]

private def slotContractJson (contract : SlotContract) : Json :=
  Json.mkObj [("typeRef", typeJson contract.typeRef), ("required", toJson contract.required),
    ("nullable", toJson contract.nullable)]

private def typeObligationReasonJson : TypeObligationReason → Json
  | .meaning obligations => nested "meaning" [toJson (obligations.map semanticObligationJson)]
  | .constraintImplication => nested "constraintImplication"
  | .presence => nested "presence"
  | .unionRemainder => nested "unionRemainder"
  | .extraField name => nested "extraField" [toJson name]
  | .inhabitation => nested "inhabitation"
  | .obligationBoundExhausted => nested "obligationBoundExhausted"

private def typeObligationJson (obligation : TypeObligation) : Json :=
  Json.mkObj [("pair", Json.mkObj [("source", slotContractJson obligation.pair.source),
      ("destination", slotContractJson obligation.pair.destination)]),
    ("path", pathJson obligation.path), ("reason", typeObligationReasonJson obligation.reason)]

private def inclusionFailureJson : InclusionFailure → Json
  | .basisMismatch => nested "basisMismatch"
  | .contractMismatch => nested "contractMismatch"
  | .undefinedMeaning obligations => nested "undefinedMeaning" [toJson (obligations.map semanticObligationJson)]
  | .missingPair => nested "missingPair"
  | .pairMismatch index => nested "pairMismatch" [toJson index]
  | .ruleMismatch index => nested "ruleMismatch" [toJson index]
  | .childCoverage index => nested "childCoverage" [toJson index]
  | .forgedEmptiness => nested "forgedEmptiness"
  | .counterexampleMismatch => nested "counterexampleMismatch"
  | .unresolved obligation => nested "unresolved" [typeObligationJson obligation]

private def projectionFailureJson : Necoherence.SemanticValidation.ProjectionFailure → Json
  | .wrongShape ref path => nested "wrongShape" [typeJson ref, pathJson path]
  | .missingField ref name => nested "missingField" [typeJson ref, toJson name]
  | .missingVariant ref tag => nested "missingVariant" [typeJson ref, toJson tag]
  | .branchAssumptionRequired path tag => nested "branchAssumptionRequired" [pathJson path, toJson tag]
  | .variantSelectionUndetermined path tag => nested "variantSelectionUndetermined" [pathJson path, toJson tag]
  | .unresolved obligations => nested "unresolved" [toJson (obligations.map semanticObligationJson)]
  | .certificateMismatch condition => nested "certificateMismatch" [toJson condition]

private def valueFailureJson (failure : Necoherence.SemanticTypes.ValueFailure) : Json :=
  Json.mkObj [
    ("typeRef", typeJson failure.typeRef),
    ("definitionRef", Json.mkObj [("source", sourceJson failure.definitionRef.source),
      ("name", toJson failure.definitionRef.name)]),
    ("origin", Json.mkObj [("source", sourceJson failure.origin.source),
      ("pointer", toJson failure.origin.pointer)]),
    ("valuePath", pathJson failure.valuePath),
    ("condition", Necoherence.SignatureWire.encode failure.condition),
    ("observed", Necoherence.SignatureWire.encode failure.observed),
    ("referenceTrace", toJson (failure.referenceTrace.map typeJson))]

private def profilePredicateCode : Necoherence.SemanticTypes.ProfilePredicate → String
  | .pr01 => "pr01" | .pr02 => "pr02" | .pr03 => "pr03" | .pr04 => "pr04"
  | .pr05 => "pr05" | .pr06 => "pr06" | .pr07 => "pr07" | .pr08 => "pr08"
  | .pr09 => "pr09" | .pr10 => "pr10" | .pr11 => "pr11" | .pr12 => "pr12"
  | .pr13 => "pr13" | .pr14 => "pr14" | .pr15 => "pr15" | .pr16 => "pr16"

private def libraryPredicateCode : Necoherence.TypeSignatures.LibraryPredicate → String
  | .lb01 => "lb01" | .lb02 => "lb02" | .lb03 => "lb03" | .lb04 => "lb04"
  | .lb05 => "lb05" | .lb06 => "lb06" | .lb07 => "lb07" | .lb08 => "lb08"
  | .lb09 => "lb09" | .lb10 => "lb10" | .lb11 => "lb11" | .lb12 => "lb12"
  | .lb13 => "lb13" | .lb14 => "lb14" | .lb15 => "lb15" | .lb16 => "lb16"
  | .lb17 => "lb17" | .lb18 => "lb18" | .lb19 => "lb19"

private def profileRefJson (ref : ProfileRef) : Json :=
  Json.mkObj [("identity", toJson ref.identity), ("revision", toJson ref.revision),
    ("contentDigest", toJson ref.contentDigest)]

private def libraryCheckFailureJson : Necoherence.TypeSignatures.LibraryCheckFailure → Json
  | .profile failure => nested "profile" [profileRefJson failure.reference,
      toJson (profilePredicateCode failure.predicate), toJson failure.location]
  | .library failure => nested "library" [toJson failure.reference,
      toJson (libraryPredicateCode failure.predicate), toJson failure.location]

private def compositionInputFailureJson : CompositionInputFailure → Json
  | .basisMismatch => nested "basisMismatch"
  | .duplicateIdentity kind identity => nested "duplicateIdentity" [toJson kind, toJson identity]
  | .unresolvedType ref => nested "unresolvedType" [typeJson ref]
  | .unresolvedFunction ref => nested "unresolvedFunction" [functionJson ref]
  | .invalidSignature ref reason => nested "invalidSignature" [functionJson ref, toJson reason]
  | .invalidInitialValue id failure => nested "invalidInitialValue" [toJson id.value, valueFailureJson failure]
  | .siteEffectNotPermitted site effect => nested "siteEffectNotPermitted" [toJson site.value, Necoherence.SignatureWire.encode effect]
  | .transformNotPermitted ref => nested "transformNotPermitted" [functionJson ref]
  | .emptyGoal => nested "emptyGoal"
  | .goalSourceConstraintUndefined port constraint => nested "goalSourceConstraintUndefined" [toJson port.value, Necoherence.SignatureWire.encode constraint]
  | .failureEmbeddingOriginUndefined embedding origin => nested "failureEmbeddingOriginUndefined" [toJson embedding.value, Necoherence.SignatureWire.encode origin]
  | .constructionNotProduct identity ref => nested "constructionNotProduct" [toJson identity, typeJson ref]
  | .fieldConstraintUnknownField identity field => nested "fieldConstraintUnknownField" [toJson identity, toJson field]
  | .constrainedNestedField identity field => nested "constrainedNestedField" [toJson identity, toJson field]
  | .constructionFieldSourceUndefined identity constraint => nested "constructionFieldSourceUndefined" [toJson identity, Necoherence.SignatureWire.encode constraint]
  | .nestedFieldUndeclared identity field => nested "nestedFieldUndeclared" [toJson identity, toJson field]
  | .nestedConstructionMismatch identity field target ref => nested "nestedConstructionMismatch" [toJson identity, toJson field, toJson target, typeJson ref]
  | .cyclicConstruction identity => nested "cyclicConstruction" [toJson identity]
  | .explicitSiteOrderInvalid before after => nested "explicitSiteOrderInvalid" [toJson before.value, toJson after.value]
  | .invalidEmptyTypeClosure failure => nested "invalidEmptyTypeClosure" [inclusionFailureJson failure]
  | .invalidResourceDeclaration reason => nested "invalidResourceDeclaration" [toJson reason]
  | .invalidLibrary failure => nested "invalidLibrary" [libraryCheckFailureJson failure]

private def compositionInputResult (case : String) (failure : CompositionInputFailure) : Json :=
  Json.mkObj [("case", toJson case), ("decision", toJson "Rejected"),
    ("failure", toJson "compositionInput"), ("detail", compositionInputFailureJson failure)]

private def witnessResult (case : String) : WitnessFailure → Json
  | .inputRevisionMismatch => rejected case "composition" "inputRevisionMismatch"
  | .initialMembership id => rejected case "composition" "initialMembership" [toJson id.value]
  | .producerMismatch ref => rejected case "composition" "producerMismatch" [valueRefJson ref]
  | .projectionMismatch failure => rejected case "composition" "projectionMismatch" [projectionFailureJson failure]
  | .sourceConstraintMismatch ref => rejected case "composition" "sourceConstraintMismatch" [valueRefJson ref]
  | .inclusion failure => rejected case "composition" "inclusion" [inclusionFailureJson failure]
  | .suppliedValueMismatch ref => rejected case "composition" "suppliedValueMismatch" [valueRefJson ref]
  | .constructionMismatch ref => rejected case "composition" "constructionMismatch" [typeJson ref]
  | .missingBinding identity => rejected case "composition" "missingBinding" [toJson identity]
  | .signatureMismatch site => rejected case "composition" "signatureMismatch" [toJson site.value]
  | .guardNotDominating ref => rejected case "composition" "guardNotDominating" [valueRefJson ref]
  | .incompleteBranchCoverage identity => rejected case "composition" "incompleteBranchCoverage" [toJson identity]
  | .failureEmbeddingMismatch id => rejected case "composition" "failureEmbeddingMismatch" [toJson id.value]
  | .goalMismatch => rejected case "composition" "goalMismatch"
  | .rankViolation => rejected case "composition" "rankViolation"
  | .resourceLoweringMismatch reason => rejected case "composition" "resourceLoweringMismatch" [toJson reason]
  | .resourceReplayMismatch reason => rejected case "composition" "resourceReplayMismatch" [toJson reason]
  | .forgedClosure reason => rejected case "composition" "forgedClosure" [toJson reason]
  | .forgedAcyclicity reason => rejected case "composition" "forgedAcyclicity" [toJson reason]
  | .missingEvidence reason => rejected case "composition" "missingEvidence" [toJson reason]

private def wireResult (case : String) : Necoherence.SignatureWire.WireFailure → Json
  | Necoherence.SignatureWire.WireFailure.unsupportedSchema path schema => rejected case "wire" "unsupportedSchema" [toJson path, toJson schema]
  | Necoherence.SignatureWire.WireFailure.unknownField path field => rejected case "wire" "unknownField" [toJson path, toJson field]
  | Necoherence.SignatureWire.WireFailure.unknownTag path tag => rejected case "wire" "unknownTag" [toJson path, toJson tag]
  | Necoherence.SignatureWire.WireFailure.syntax path message => rejected case "wire" "syntax" [toJson path, toJson message]

private def decodedComposition (input : Necoherence.SignatureGeneration.Input) :
    Except (Sum Necoherence.SignatureWire.WireFailure (Sum CompositionInputFailure WitnessFailure)) (PreparedCompositionInput × RawComposition) := do
  let some composition := input.composition | throw (Sum.inl (Necoherence.SignatureWire.WireFailure.syntax "$.composition" "composition required"))
  let problemJson ← (Necoherence.SignatureWire.liftJson (composition.getObjVal? "problem")).mapError Sum.inl
  let (problem, causes) ← (Necoherence.SignatureComposition.decodeProblem input.signatures problemJson).mapError Sum.inl
  let prepared ← (Necoherence.SignatureComposition.prepare input.signatures input.basis.graphSha256 problem causes).mapError (fun failure => Sum.inr (Sum.inl failure))
  let derivationJson ← (Necoherence.SignatureWire.liftJson (composition.getObjVal? "derivation")).mapError Sum.inl
  let supplied ← (Necoherence.SignatureCompositionWire.decodeDerivation input.signatures problemJson prepared derivationJson).mapError fun
    | .inl failure => Sum.inl failure
    | .inr failure => Sum.inr (Sum.inr failure)
  pure ⟨prepared, supplied.proofProjection⟩

private def decodeFailureResult (identity : String) :
    Sum Necoherence.SignatureWire.WireFailure (Sum CompositionInputFailure WitnessFailure) → Json
  | .inl failure => wireResult identity failure
  | .inr (.inl failure) => compositionInputResult identity failure
  | .inr (.inr failure) => witnessResult identity failure

private def closureCounts (prepared : PreparedCompositionInput) (nodes : List CompositionClosureNode) :
    Except WitnessFailure (Nat × Nat) := do
  let bindings := nodes.foldl (fun count node => count + closureBindingCandidates prepared node.state) 0
  let branches ← nodes.foldlM (fun count node => do
    pure (count + (← closureBranchCount prepared node.state node.actions))) 0
  pure (bindings, branches)

private def mutateClosure (prepared : PreparedCompositionInput) (closure : CompositionClosureWitness)
    (mutation : String) : Except WitnessFailure CompositionClosureWitness :=
  if mutation == "frontier" then pure { closure with frontier := [closureInitialState prepared] }
  else if mutation == "obligations" then pure { closure with obligations := [.stateBoundExhausted] }
  else do
    let nodes := if mutation == "local" then
        match closure.nodes with
        | [] => []
        | node :: rest => { node with actions := [] } :: rest
      else if mutation == "initial" then closure.nodes.drop 1
      else if mutation == "successor" then
        match closure.nodes with
        | [] => []
        | node :: rest => node :: rest.drop 1
      else closure.nodes
    let counts ← closureCounts prepared nodes
    pure { closure with nodes, steps := nodes.length - 1, bindingCandidates := counts.1, branchNodes := counts.2 }

private def closureCase (identity mutation : String) (input : Necoherence.SignatureGeneration.Input) : Json :=
  match decodedComposition input with
  | .error failure => decodeFailureResult identity failure
  | .ok ⟨prepared, raw⟩ =>
    match raw.selection with
    | .anyFeasible => rejected identity "composition" "missingEvidence" [toJson "Unique evidence required"]
    | .unique closure _ =>
      match mutateClosure prepared closure mutation with
      | .error failure => witnessResult identity failure
      | .ok mutated =>
        match verifyCompositionClosure prepared mutated with
        | .ok _ => accepted identity
        | .error failure => witnessResult identity failure

private def selectionCase (identity : String) (input : Necoherence.SignatureGeneration.Input) : Json :=
  match decodedComposition input with
  | .error failure => decodeFailureResult identity failure
  | .ok ⟨prepared, raw⟩ =>
    match raw.selection with
    | .anyFeasible => rejected identity "composition" "missingEvidence" [toJson "Unique evidence required"]
    | .unique closure _ =>
      match verifyComposition prepared { raw with selection := .unique closure "forged" } with
      | .ok _ => accepted identity
      | .error failure => witnessResult identity failure

private def witness (case : Json) : Except String Json := do
  let identity ← text case "case"; let operation ← text case "operation"; let mutation ← text case "mutation"
  if operation == "reachability" then
    let input := fixture 1 false
    let finalMarking := if mutation == "final-marking" then input.marking else match input.transitions with | transition :: _ => applyBranchAt input.marking transition input.bindings | [] => input.marking
    return match verifyReachabilityWitness input { path := ["T-RUN"], finalMarking } with
      | .ok _ => accepted identity
      | .error failure => witnessResult identity failure
  else
    let input := fixture 2 true; let markings := [input.marking]
    let steps := if mutation == "steps" then 0 else 1
    let frontier := if mutation == "frontier" then markings else []
    if operation == "closure" then return match verifyClosureWitness input { exploredMarkings := markings, steps, frontier } with
      | .ok _ => accepted identity
      | .error failure => witnessResult identity failure
    else
      if mutation == "cycle" then
        let marking : Marking := { places := [("P", [token "token"])] }
        let cyclic : SolverInput := { places := [{ identity := "P", tokenType := "T", revision := 1 }], transitions := [{ identity := "LOOP", inputPlaces := ["P"], outputPlaces := [], failurePlaces := [], revision := 1 }], bindings := [{ transitionId := "LOOP", name := "read", place := "P", tokenType := "T", identity := "token", provenance := "test", multiplicity := 1, mode := .read, requiredRevision := 1 }], goal := .placeHasAtLeast "P" 2, graph := { places := ["P"], transitions := ["LOOP"], edges := [("P", "LOOP"), ("LOOP", "P")], revision := 1 }, marking, bound := { targetIdentity := "unit", index := 0, revision := 1, maxBindings := 10, maxSearchSteps := 10 } }
        return match verifyAcyclicWitness cyclic { exploredMarkings := [marking], steps := 1, frontier := [] } with
          | .ok _ => accepted identity
          | .error failure => witnessResult identity failure
      else
        return match verifyAcyclicWitness input { exploredMarkings := markings, steps, frontier } with
          | .ok _ => accepted identity
          | .error failure => witnessResult identity failure

private def runCase (case : Json) : Except String Json := do
  let identity ← text case "case"; let kind ← text case "kind"
  if kind == "witness" then witness case else
  let exchange ← text case "exchange"
  let input ← match Necoherence.SignatureGeneration.decodeInput exchange with
    | .ok value => pure value
    | .error (.wire failure) => return wireResult identity failure
    | .error (.json failure) => return wireResult identity failure
  if kind == "closure" then return closureCase identity (← text case "mutation") input
  if kind == "selection" then return selectionCase identity input
  if kind == "generation" then
    return match Necoherence.SignatureGeneration.admitWithComposition input (Necoherence.SignatureGeneration.ExpectedBasis.ofInput input) with
      | .ok _ => accepted identity
      | .error (.compositionInput failure) => compositionInputResult identity failure
      | .error (.composition failure) => witnessResult identity failure
      | .error (.wire failure) => wireResult identity failure
      | .error failure => result identity "Rejected" (some (admissionFailureName failure))
  else
    let sourceName ← text case "source"; let destinationName ← text case "destination"
    let graph := input.signatures.graph
    let source ← graph.nodes.find? (fun node => node.ref.definitionName == sourceName) |>.toExcept "source type"
    let destination ← graph.nodes.find? (fun node => node.ref.definitionName == destinationName) |>.toExcept "destination type"
    let decision := match checkAssignable graph { typeRef := source.ref, required := true, nullable := false } { typeRef := destination.ref, required := true, nullable := false } with | .compatible _ => "Compatible" | .incompatible _ => "Incompatible" | .unknown _ => "Unknown"
    return result identity decision

def main (args : List String) : IO UInt32 := do
  let some path := args.head? | IO.eprintln "input path required"; return 2
  let parsed := Json.parse (← IO.FS.readFile path)
  let .ok document := parsed | IO.eprintln "invalid input"; return 2
  let .ok cases := (document.getObjVal? "cases").bind (·.getArr?) | IO.eprintln "cases required"; return 2
  let mut rows := #[]
  for case in cases do
    match runCase case with | .ok row => rows := rows.push row | .error error => IO.eprintln error; return 2
  IO.println (Json.compress (Json.arr rows))
  return 0
