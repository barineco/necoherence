-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureWire

namespace Necoherence.SignatureGeneration
open Lean Necoherence.TypeSignatures Necoherence.SignatureWire

partial def canonicalJson : Json → String
  | .obj object => "{" ++ String.intercalate "," ((object.toList.mergeSort (fun a b => a.1 ≤ b.1)).map
      (fun (key, value) => (Json.str key).compress ++ ":" ++ canonicalJson value)) ++ "}"
  | .arr values => "[" ++ String.intercalate "," (values.toList.map canonicalJson) ++ "]"
  | value => value.compress

private def hash (json : Json) : String := Necoherence.Sha256.digest (canonicalJson json)
private def ordered [Wire α] (values : List α) : List α :=
  values.mergeSort (fun a b => canonicalJson (encode a) ≤ canonicalJson (encode b))
private def lexLe : List String → List String → Bool
  | [], _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => if a == b then lexLe as bs else a < b
private def array (values : List Json) : Json := .arr values.toArray
private def replace (json : Json) (key : String) (value : Json) : Json :=
  match json.getObj? with
  | .ok object => Json.mkObj ((object.toList.filter (fun item => item.1 != key)) ++ [(key, value)])
  | .error _ => json

private def graphDefinition (definition : Necoherence.TypeSignatures.Definition) : Json :=
  let json := encode definition
  match definition.shape with
  | .operation operation =>
      let outcomes := operation.outcomes.map fun outcome =>
        replace (encode outcome) "cause" (Json.mkObj [("tag", .str (match outcome.cause with
          | .valueContract _ => "ValueContract"
          | .externalCondition _ => "ExternalCondition"))])
      replace json "shape" (Json.mkObj [("tag", .str "Operation"), ("value", replace (encode operation) "outcomes" (array outcomes))])
  | _ => json

def graphProjection (library : TypeSignatureLibrary) : Json :=
  Json.mkObj [("profile", encode library.profile),
    ("nodes", encode (library.nodes.mergeSort (fun a b => a.id ≤ b.id))),
    ("definitions", array ((library.definitions.mergeSort (fun a b => a.id ≤ b.id)).map graphDefinition))]

def provenanceProjection (library : TypeSignatureLibrary) : Json :=
  Json.mkObj [("sources", encode (library.sources.mergeSort (fun a b =>
      lexLe [a.repository, a.revision, a.path, a.contentDigest] [b.repository, b.revision, b.path, b.contentDigest]))),
    ("provenance", encode ((library.provenance.mergeSort (fun a b => canonicalJson (encode a.target) ≤ canonicalJson (encode b.target))).map
      (fun binding => { binding with origins := ordered binding.origins }))),
    ("outcome_origins", array ((library.definitions.mergeSort (fun a b => a.id ≤ b.id)).flatMap fun definition =>
      match definition.shape with
      | .operation operation => (operation.outcomes.mergeSort (fun a b => a.id ≤ b.id)).map fun outcome =>
          Json.mkObj [("definition", .str definition.id), ("outcome", .str outcome.id), ("cause", encode outcome.cause)]
      | _ => []))]

def metadataProjection (library : TypeSignatureLibrary) : Json :=
  Json.mkObj [("groups", encode ((library.groups.mergeSort (fun a b => a.id ≤ b.id)).map
      (fun group => { group with members := group.members.mergeSort (· ≤ ·) }))),
    ("annotations", encode (library.annotations.mergeSort (fun a b =>
      lexLe [canonicalJson (encode a.target), a.key, canonicalJson (encode a.value)]
        [canonicalJson (encode b.target), b.key, canonicalJson (encode b.value)])))]

structure Entrypoint where
  identity : String
  definition : DefinitionId
  deriving Repr, DecidableEq

instance : Wire Entrypoint where
  encode value := Json.mkObj [("identity", encode value.identity), ("definition", encode value.definition)]
  decode json := do
    keys json ["identity", "definition"]
    pure { identity := ← get json "identity", definition := ← get json "definition" }

structure Basis where
  signatureSchema : String
  libraryIdentity : String
  libraryRevision : String
  profile : Necoherence.SemanticTypes.ProfileRef
  graphSha256 : String
  provenanceSha256 : String
  metadataSha256 : String
  problemSha256 : Option String
  entrypointsSha256 : String
  deriving Repr, DecidableEq

instance : Wire Basis where
  encode value := Json.mkObj [("signature_schema", encode value.signatureSchema),
    ("library_identity", encode value.libraryIdentity), ("library_revision", encode value.libraryRevision),
    ("profile", encode value.profile), ("graph_sha256", encode value.graphSha256),
    ("provenance_sha256", encode value.provenanceSha256), ("metadata_sha256", encode value.metadataSha256),
    ("problem_sha256", encode value.problemSha256), ("entrypoints_sha256", encode value.entrypointsSha256)]
  decode json := do
    keys json ["signature_schema", "library_identity", "library_revision", "profile", "graph_sha256",
      "provenance_sha256", "metadata_sha256", "problem_sha256", "entrypoints_sha256"]
    pure { signatureSchema := ← get json "signature_schema", libraryIdentity := ← get json "library_identity", libraryRevision := ← get json "library_revision", profile := ← get json "profile", graphSha256 := ← get json "graph_sha256", provenanceSha256 := ← get json "provenance_sha256", metadataSha256 := ← get json "metadata_sha256", problemSha256 := ← get json "problem_sha256", entrypointsSha256 := ← get json "entrypoints_sha256" }

def basis (library : TypeSignatureLibrary) (entrypoints : List Entrypoint) (composition : Option Json := none) : Basis :=
  { signatureSchema := library.schema, libraryIdentity := library.identity, libraryRevision := library.revision,
    profile := library.profile.reference, graphSha256 := hash (graphProjection library),
    provenanceSha256 := hash (provenanceProjection library), metadataSha256 := hash (metadataProjection library),
    problemSha256 := composition.map hash,
    entrypointsSha256 := hash (encode (entrypoints.mergeSort (fun a b => a.identity ≤ b.identity))) }

structure Input where
  schema : String := "ncoh-checked-generation@4"
  basis : Basis
  signatures : TypeSignatureLibrary
  composition : Option Json := none
  entrypoints : List Entrypoint

instance : Wire Json := ⟨id, Except.ok⟩
instance : Wire Input where
  encode value := Json.mkObj [("schema", encode value.schema), ("basis", encode value.basis),
    ("signatures", encode value.signatures), ("composition", encode value.composition), ("entrypoints", encode value.entrypoints)]
  decode json := do
    keys json ["schema", "basis", "signatures", "composition", "entrypoints"]
    let schema : String ← get json "schema"
    if schema != "ncoh-checked-generation@4" then
      throw (WireFailure.unsupportedSchema "$.schema" schema)
    pure {
      schema := schema
      basis := ← get json "basis"
      signatures := ← get json "signatures"
      composition := ← get json "composition"
      entrypoints := ← get json "entrypoints" }

structure CheckedInput (input : Input) : Type where
  library : CheckedLibrary input.signatures
  trusted : input.basis = basis input.signatures input.entrypoints input.composition

inductive AdmissionFailure where
  | unsupportedSchema (schema : String)
  | basisMismatch
  | invalidEntrypoints
  | unresolvedEntrypoint (definition : DefinitionId)
  | library (failure : LibraryCheckFailure)
  | digestMismatch
  | wire (failure : WireFailure)
  | composition (failure : String)
  | generation (failure : String)
  deriving BEq, Repr


def admitBasis (input : Input) (expected : Basis) :
    Except AdmissionFailure (CheckedInput input) := do
  if input.schema != "ncoh-checked-generation@4" then
    throw (.unsupportedSchema input.schema)
  if input.basis != expected then throw .basisMismatch
  if !unique (input.entrypoints.map (·.identity)) ||
      (input.entrypoints.isEmpty && input.composition.isNone) then
    throw .invalidEntrypoints
  match input.entrypoints.find? (fun entry =>
      !input.signatures.definitions.any (fun definition => definition.id == entry.definition)) with
  | some entry => throw (.unresolvedEntrypoint entry.definition)
  | none => pure ()
  let library ← (checkLibrary input.signatures).mapError AdmissionFailure.library
  if h : input.basis = basis input.signatures input.entrypoints input.composition then
    pure { library, trusted := h }
  else throw .digestMismatch

inductive InputDecodeFailure where
  | json (message : String)
  | wire (failure : WireFailure)
  deriving BEq, Repr

def decodeInput (text : String) : Except InputDecodeFailure Input := do
  let json ← (Necoherence.SignatureJson.parse text).mapError InputDecodeFailure.json
  decode json |>.mapError InputDecodeFailure.wire
def encodeInput (input : Input) : String := canonicalJson (encode input)


end Necoherence.SignatureGeneration
