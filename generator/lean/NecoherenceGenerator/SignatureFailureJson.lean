-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SignatureGeneration

namespace NecoherenceTools.SignatureFailureJson

open Lean Necoherence Necoherence.SignatureGeneration Necoherence.SignatureWire

def profilePredicateName : Necoherence.SemanticTypes.ProfilePredicate → String
  | .pr01 => "pr01" | .pr02 => "pr02" | .pr03 => "pr03" | .pr04 => "pr04"
  | .pr05 => "pr05" | .pr06 => "pr06" | .pr07 => "pr07" | .pr08 => "pr08"
  | .pr09 => "pr09" | .pr10 => "pr10" | .pr11 => "pr11" | .pr12 => "pr12"
  | .pr13 => "pr13" | .pr14 => "pr14" | .pr15 => "pr15" | .pr16 => "pr16"

def libraryPredicateName : Necoherence.TypeSignatures.LibraryPredicate → String
  | .lb01 => "lb01" | .lb02 => "lb02" | .lb03 => "lb03" | .lb04 => "lb04"
  | .lb05 => "lb05" | .lb06 => "lb06" | .lb07 => "lb07" | .lb08 => "lb08"
  | .lb09 => "lb09" | .lb10 => "lb10" | .lb11 => "lb11" | .lb12 => "lb12"
  | .lb13 => "lb13" | .lb14 => "lb14" | .lb15 => "lb15" | .lb16 => "lb16"
  | .lb17 => "lb17" | .lb18 => "lb18" | .lb19 => "lb19"

def libraryCheckReason : Necoherence.TypeSignatures.LibraryCheckFailure → String
  | .profile failure => profilePredicateName failure.predicate
  | .library failure => libraryPredicateName failure.predicate

def compositionInputReason : Necoherence.SemanticComposition.CompositionInputFailure → String
  | .basisMismatch => "basisMismatch"
  | .duplicateIdentity .. => "duplicateIdentity"
  | .unresolvedType .. => "unresolvedType"
  | .unresolvedFunction .. => "unresolvedFunction"
  | .invalidSignature .. => "invalidSignature"
  | .invalidInitialValue .. => "invalidInitialValue"
  | .siteEffectNotPermitted .. => "siteEffectNotPermitted"
  | .transformNotPermitted .. => "transformNotPermitted"
  | .emptyGoal => "emptyGoal"
  | .goalSourceConstraintUndefined .. => "goalSourceConstraintUndefined"
  | .failureEmbeddingOriginUndefined .. => "failureEmbeddingOriginUndefined"
  | .constructionNotProduct .. => "constructionNotProduct"
  | .fieldConstraintUnknownField .. => "fieldConstraintUnknownField"
  | .constrainedNestedField .. => "constrainedNestedField"
  | .constructionFieldSourceUndefined .. => "constructionFieldSourceUndefined"
  | .nestedFieldUndeclared .. => "nestedFieldUndeclared"
  | .nestedConstructionMismatch .. => "nestedConstructionMismatch"
  | .cyclicConstruction .. => "cyclicConstruction"
  | .explicitSiteOrderInvalid .. => "explicitSiteOrderInvalid"
  | .invalidEmptyTypeClosure .. => "invalidEmptyTypeClosure"
  | .invalidResourceDeclaration .. => "invalidResourceDeclaration"
  | .invalidLibrary .. => "invalidLibrary"

def witnessReason : Necoherence.SemanticComposition.WitnessFailure → String
  | .inputRevisionMismatch => "inputRevisionMismatch"
  | .initialMembership .. => "initialMembership"
  | .producerMismatch .. => "producerMismatch"
  | .projectionMismatch .. => "projectionMismatch"
  | .sourceConstraintMismatch .. => "sourceConstraintMismatch"
  | .inclusion .. => "inclusion"
  | .suppliedValueMismatch .. => "suppliedValueMismatch"
  | .constructionMismatch .. => "constructionMismatch"
  | .missingBinding .. => "missingBinding"
  | .signatureMismatch .. => "signatureMismatch"
  | .guardNotDominating .. => "guardNotDominating"
  | .incompleteBranchCoverage .. => "incompleteBranchCoverage"
  | .failureEmbeddingMismatch .. => "failureEmbeddingMismatch"
  | .goalMismatch => "goalMismatch"
  | .rankViolation => "rankViolation"
  | .resourceLoweringMismatch .. => "resourceLoweringMismatch"
  | .resourceReplayMismatch .. => "resourceReplayMismatch"
  | .forgedClosure .. => "forgedClosure"
  | .forgedAcyclicity .. => "forgedAcyclicity"
  | .missingEvidence .. => "missingEvidence"

def wireTagName : Necoherence.SignatureWire.WireFailure → String
  | .unsupportedSchema .. => "unsupportedSchema"
  | .unknownField .. => "unknownField"
  | .unknownTag .. => "unknownTag"
  | .syntax .. => "syntax"

def kindJson (kind : String) (fields : List (String × Json)) : Json :=
  Json.mkObj (("kind", Json.str kind) :: fields)

def failureJson : AdmissionFailure → Json
  | .unsupportedSchema actual => kindJson "schema" [("actual", Json.str actual)]
  | .entrypointsEmpty => kindJson "entrypoints_empty" []
  | .entrypointIdentityEmpty => kindJson "entrypoint_identity_empty" []
  | .entrypointDuplicate identity => kindJson "entrypoint_duplicate" [("identity", Json.str identity)]
  | .entrypointUnresolved identity definition =>
      kindJson "entrypoint_unresolved" [("identity", Json.str identity), ("definition", Json.str definition)]
  | .library failure => kindJson "declaration" [("reason", Json.str (libraryCheckReason failure))]
  | .certificate mismatch => certificateFailureJson mismatch
  | .wire failure => kindJson "composition" [("reason", Json.str (wireTagName failure))]
  | .compositionInput failure => kindJson "composition" [("reason", Json.str (compositionInputReason failure))]
  | .composition failure => kindJson "composition" [("reason", Json.str (witnessReason failure))]

def generationFailureJson : NecoherenceTools.SignatureGeneration.GenerationFailure → Json
  | .admission failure => kindJson "admission" [("failure", failureJson failure)]
  | .rendering message => kindJson "rendering" [("message", Json.str message)]

def originalFailureJson? : NecoherenceTools.SignatureGeneration.GenerationFailure → Option Json
  | .admission failure => some (failureJson failure)
  | .rendering _ => none

end NecoherenceTools.SignatureFailureJson
