-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureCompositionInput

namespace Necoherence.SemanticInvariantWire
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SemanticValidation Necoherence.SignatureWire

private instance : Wire SourceRef where
  encode value := encode ({ repository := value.repository, revision := value.revision, path := value.path, contentDigest := value.contentDigest } : SourceIdentity)
  decode json := do
    let source : SourceIdentity ← decode json
    pure { repository := source.repository, revision := source.revision, path := source.path, contentDigest := source.contentDigest, documentId := "" }

def unitTag (tag : String) : Json := Json.mkObj [("tag", .str tag)]
def tupleTag (tag : String) (value : Json) : Json := Json.mkObj [("tag", .str tag), ("value", value)]
def recordTag (tag : String) (fields : List (String × Json)) : Json :=
  Json.mkObj [("tag", .str tag), ("fields", Json.mkObj fields)]
private def liftJson (result : Except String α) : Except WireFailure α :=
  result.mapError (WireFailure.syntax "$")
def payload (json : Json) : Except WireFailure Json := liftJson (json.getObjVal? "value")
def fields (json : Json) : Except WireFailure Json := liftJson (json.getObjVal? "fields")

instance : Wire Necoherence.TokenKind where
  encode value := unitTag (match value with
    | .input => "Input" | .output => "Output" | .failure => "Failure"
    | .effect => "Effect" | .observation => "Observation" | .accepted => "Accepted")
  decode json := do
    match ← get (α := String) json "tag" with
    | "Input" => pure .input | "Output" => pure .output | "Failure" => pure .failure
    | "Effect" => pure .effect | "Observation" => pure .observation | "Accepted" => pure .accepted
    | tag => throw (WireFailure.unknownTag "$.tag" tag)
instance : Wire Necoherence.BindingMode where
  encode value := unitTag (match value with | .read => "Read" | .consume => "Consume")
  decode json := do
    match ← get (α := String) json "tag" with
    | "Read" => pure .read | "Consume" => pure .consume
    | tag => throw (WireFailure.unknownTag "$.tag" tag)
instance : Wire Necoherence.ColoredToken where
  encode value := Json.mkObj [("target", encode value.target), ("index", encode value.index), ("revision", encode value.revision), ("kind", encode value.kind)]
  decode json := do
    keys json ["target", "index", "revision", "kind"]
    pure { target := ← get json "target", index := ← get json "index", revision := ← get json "revision", kind := ← get json "kind" }
instance : Wire Necoherence.TypedPlace where
  encode value := Json.mkObj [("identity", encode value.identity), ("token_type", encode value.tokenType), ("revision", encode value.revision)]
  decode json := do
    keys json ["identity", "token_type", "revision"]
    pure { identity := ← get json "identity", tokenType := ← get json "token_type", revision := ← get json "revision" }
instance : Wire Necoherence.TypedTransition where
  encode value := Json.mkObj [("identity", encode value.identity), ("input_places", encode value.inputPlaces), ("output_places", encode value.outputPlaces), ("failure_places", encode value.failurePlaces), ("revision", encode value.revision)]
  decode json := do
    keys json ["identity", "input_places", "output_places", "failure_places", "revision"]
    pure { identity := ← get json "identity", inputPlaces := ← get json "input_places", outputPlaces := ← get json "output_places", failurePlaces := ← get json "failure_places", revision := ← get json "revision" }
instance : Wire Necoherence.InputBinding where
  encode value := Json.mkObj [("transition_id", encode value.transitionId), ("name", encode value.name), ("place", encode value.place), ("token_type", encode value.tokenType), ("identity", encode value.identity), ("provenance", encode value.provenance), ("multiplicity", encode value.multiplicity), ("mode", encode value.mode), ("required_revision", encode value.requiredRevision)]
  decode json := do
    keys json ["transition_id", "name", "place", "token_type", "identity", "provenance", "multiplicity", "mode", "required_revision"]
    pure { transitionId := ← get json "transition_id", name := ← get json "name", place := ← get json "place", tokenType := ← get json "token_type", identity := ← get json "identity", provenance := ← get json "provenance", multiplicity := ← get json "multiplicity", mode := ← get json "mode", requiredRevision := ← get json "required_revision" }
instance : Wire Necoherence.DeclarationGraph where
  encode value := Json.mkObj [("places", encode value.places), ("transitions", encode value.transitions), ("edges", encode value.edges), ("revision", encode value.revision)]
  decode json := do
    keys json ["places", "transitions", "edges", "revision"]
    pure { places := ← get json "places", transitions := ← get json "transitions", edges := ← get json "edges", revision := ← get json "revision" }
instance : Wire Necoherence.DomainBound where
  encode value := Json.mkObj [("target_identity", encode value.targetIdentity), ("index", encode value.index), ("revision", encode value.revision), ("max_bindings", encode value.maxBindings), ("max_search_steps", encode value.maxSearchSteps)]
  decode json := do
    keys json ["target_identity", "index", "revision", "max_bindings", "max_search_steps"]
    pure { targetIdentity := ← get json "target_identity", index := ← get json "index", revision := ← get json "revision", maxBindings := ← get json "max_bindings", maxSearchSteps := ← get json "max_search_steps" }
instance : Wire Necoherence.Marking where
  encode value := Json.mkObj [("places", encode value.places)]
  decode json := do
    keys json ["places"]
    pure { places := ← get json "places" }

partial def goalEncode : Necoherence.GoalPredicate → Json
  | .placeHasAtLeast place count => recordTag "PlaceHasAtLeast" [("place", encode place), ("count", encode count)]
  | .placeHasToken place target index revision => recordTag "PlaceHasToken" [("place", encode place), ("target", encode target), ("index", encode index), ("revision", encode revision)]
  | .glAnd a b => tupleTag "And" (.arr #[goalEncode a, goalEncode b])
  | .glOr a b => tupleTag "Or" (.arr #[goalEncode a, goalEncode b])
  | .glNot a => tupleTag "Not" (goalEncode a)
partial def goalDecode (json : Json) : Except WireFailure Necoherence.GoalPredicate := do
  match ← get (α := String) json "tag" with
  | "PlaceHasAtLeast" => let row ← fields json; pure (.placeHasAtLeast (← get row "place") (← get row "count"))
  | "PlaceHasToken" => let row ← fields json; pure (.placeHasToken (← get row "place") (← get row "target") (← get row "index") (← get row "revision"))
  | "And" | "Or" =>
    let pair ← liftJson (← payload json).getArr?
    if pair.size != 2 then throw (WireFailure.syntax "$.value" "binary goal size")
    let a ← goalDecode pair[0]!
    let b ← goalDecode pair[1]!
    pure (if (← get (α := String) json "tag") == "And" then .glAnd a b else .glOr a b)
  | "Not" => return .glNot (← goalDecode (← payload json))
  | tag => throw (WireFailure.unknownTag "$.tag" tag)
instance : Wire Necoherence.GoalPredicate := ⟨goalEncode, goalDecode⟩
instance : Wire Necoherence.SolverInput where
  encode value := Json.mkObj [("places", encode value.places), ("transitions", encode value.transitions), ("bindings", encode value.bindings), ("goal", encode value.goal), ("graph", encode value.graph), ("marking", encode value.marking), ("bound", encode value.bound)]
  decode json := do
    keys json ["places", "transitions", "bindings", "goal", "graph", "marking", "bound"]
    pure { places := ← get json "places", transitions := ← get json "transitions", bindings := ← get json "bindings", goal := ← get json "goal", graph := ← get json "graph", marking := ← get json "marking", bound := ← get json "bound" }
instance : Wire Necoherence.ReachabilityWitness where
  encode value := Json.mkObj [("path", encode value.path), ("final_marking", encode value.finalMarking)]
  decode json := do
    keys json ["path", "final_marking"]
    pure { path := ← get json "path", finalMarking := ← get json "final_marking" }
instance : Wire Necoherence.AcyclicWitness where
  encode value := Json.mkObj [("explored_markings", encode value.exploredMarkings), ("steps", encode value.steps), ("frontier", encode value.frontier)]
  decode json := do
    keys json ["explored_markings", "steps", "frontier"]
    pure { exploredMarkings := ← get json "explored_markings", steps := ← get json "steps", frontier := ← get json "frontier" }

instance : Wire ProducerRef where
  encode
    | .initial id => tupleTag "Initial" (encode id)
    | .invocationOutcome site outcome port => recordTag "InvocationOutcome" [("site", encode site), ("outcome", encode outcome), ("port", encode port)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Initial" => return .initial (← decode (← payload json))
    | "InvocationOutcome" => let row ← fields json; pure (.invocationOutcome (← get row "site") (← get row "outcome") (← get row "port"))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)
instance : Wire ValueRef where
  encode value := Json.mkObj [("producer", encode value.producer), ("path", encode value.path)]
  decode json := do
    keys json ["producer", "path"]
    pure { producer := ← get json "producer", path := ← get json "path" }
instance : Wire ValueCorrespondence where
  encode value := Json.mkObj [("producer", encode value.producer), ("place", encode value.place), ("token_target", encode value.tokenTarget), ("revision", encode value.revision)]
  decode json := do
    keys json ["producer", "place", "token_target", "revision"]
    pure { producer := ← get json "producer", place := ← get json "place", tokenTarget := ← get json "token_target", revision := ← get json "revision" }

instance : Wire ProjectionAssumption where
  encode
    | .present path => tupleTag "Present" (encode path)
    | .nonNull path => tupleTag "NonNull" (encode path)
    | .variant path tag => recordTag "Variant" [("path", encode path), ("tag", encode tag)]
    | .indexPresent path index => recordTag "IndexPresent" [("path", encode path), ("index", encode index)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Present" => return .present (← decode (← payload json))
    | "NonNull" => return .nonNull (← decode (← payload json))
    | "Variant" => let row ← fields json; pure (.variant (← get row "path") (← get row "tag"))
    | "IndexPresent" => let row ← fields json; pure (.indexPresent (← get row "path") (← get row "index"))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)
instance : Wire ProjectionCertificate where
  encode value := Json.mkObj [("profile", encode value.profile), ("source_refs", encode value.sourceRefs), ("source", encode value.source), ("path", encode value.path), ("assumptions", encode value.assumptions), ("destination", encode value.destination)]
  decode json := do
    keys json ["profile", "source_refs", "source", "path", "assumptions", "destination"]
    pure { profile := ← get json "profile", sourceRefs := ← get json "source_refs", source := ← get json "source", path := ← get json "path", assumptions := ← get json "assumptions", destination := ← get json "destination" }
instance : Wire TypePair where
  encode value := Json.mkObj [("source", encode value.source), ("destination", encode value.destination), ("source_tag", encode value.sourceTag)]
  decode json := do
    keys json ["source", "destination", "source_tag"]
    pure { source := ← get json "source", destination := ← get json "destination", sourceTag := ← get json "source_tag" }

end Necoherence.SemanticInvariantWire
