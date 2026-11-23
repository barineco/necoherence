-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureWire
import NecoQuotient.RuleTable

namespace Necoherence.SignatureGeneration
open Lean Necoherence.TypeSignatures Necoherence.SignatureWire

partial def canonicalJson : Json → String
  | .obj object => "{" ++ String.intercalate "," ((object.toList.mergeSort (fun a b => a.1 ≤ b.1)).map
      (fun (key, value) => (Json.str key).compress ++ ":" ++ canonicalJson value)) ++ "}"
  | .arr values => "[" ++ String.intercalate "," (values.toList.map canonicalJson) ++ "]"
  | .num ⟨0, _⟩ => "0"
  | value => value.compress

def hash (json : Json) : String := Necoherence.Sha256.digest (canonicalJson json)
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

/-- 合成の goal が実行結果として観測させる量の族の宣言。正規化された JSON 文字列で保持する。 -/
structure GoalObservations where
  canonical : String
  deriving Repr, DecidableEq

instance : ToString GoalObservations := ⟨GoalObservations.canonical⟩

private def member (json : Json) (key : String) : Json := (json.getObjVal? key).toOption.getD Json.null

private def rows (json : Json) (fields : List String) : Json :=
  match json with
  | .arr items => Json.arr (items.map fun item => Json.mkObj (fields.map fun key => (key, member item key)))
  | _ => Json.arr #[]

def executionFailureKinds : List String :=
  ["argumentCoverage", "invalidOutcome", "invalidPlan", "missingArgument", "missingProvider", "missingValue",
    "network", "networkTerminal", "provider", "providerCoverage", "providerEffect", "resource", "value"]

def goalObservations (composition : Json) : GoalObservations :=
  let goal := member (member composition "problem") "goal"
  ⟨canonicalJson (Json.mkObj [
    ("outputs", rows (member goal "outputs") ["id", "contract"]),
    ("failures", rows (member goal "failures") ["id", "contract", "final_resources"]),
    ("final_resources", member goal "final_resources"),
    ("effects", Json.arr #[Json.str "network_instruction", Json.str "pending"]),
    ("residuals", Json.str "residual_set"),
    ("execution_failures", Json.arr (executionFailureKinds.map Json.str).toArray),
    ("provenance", Json.str "certificate_basis")])⟩

private partial def planReturns (tree : Json) : List Json :=
  let node := member tree "node"
  match (member node "tag").getStr? with
  | .ok "Return" => [member node "value"]
  | .ok "Invoke" | .ok "Guard" =>
    match member (member node "fields") "arms" with
    | .arr arms => arms.toList.flatMap fun arm =>
      match arm with
      | .arr pair => if h : pair.size = 2 then planReturns pair[1] else []
      | _ => []
    | _ => []
  | _ => []

private def returnedPorts (value : Json) : List String :=
  match member value "value" with
  | .arr pairs => pairs.toList.filterMap fun pair =>
    match pair with
    | .arr items => if h : 0 < items.size then items[0].getStr?.toOption else none
    | _ => none
  | _ => []

private def rowIds (json : Json) : List String :=
  match json with
  | .arr items => items.toList.filterMap fun item => (member item "id").getStr?.toOption
  | _ => []

private def keptRows (json : Json) (fields : List String) (kept : String → Bool) (extra : List String) : Json :=
  let declared := match json with
    | .arr items => items.toList.filter fun item => kept (((member item "id").getStr?.toOption).getD "")
    | _ => []
  let undeclared := extra.map fun id => Json.mkObj (fields.map fun key => (key, if key == "id" then Json.str id else Json.null))
  rows (Json.arr (declared ++ undeclared).toArray) fields

/-- 合成の導出の Return 節点が出力する値と失敗の埋め込みから作る観測関数族。Return 節点の集まりが goal の宣言と一致する時に、goal から作る観測関数族と等しい。 -/
def planObservations (composition : Json) : GoalObservations :=
  let goal := member (member composition "problem") "goal"
  let returns := planReturns (member (member (member composition "derivation") "plan") "root")
  let successes := returns.filterMap fun value =>
    match (member value "tag").getStr? with
    | .ok "Success" => some (returnedPorts value)
    | _ => none
  let embeddings := returns.filterMap fun value =>
    match (member value "tag").getStr? with
    | .ok "Success" => none
    | _ => (member (member value "fields") "embedding").getStr?.toOption
  let outputIds := rowIds (member goal "outputs")
  let failureIds := rowIds (member goal "failures")
  let returnedOutput := fun id => !successes.isEmpty && successes.all (·.contains id)
  ⟨canonicalJson (Json.mkObj [
    ("outputs", keptRows (member goal "outputs") ["id", "contract"] returnedOutput
      (successes.flatten.filter (!outputIds.contains ·)).eraseDups),
    ("failures", keptRows (member goal "failures") ["id", "contract", "final_resources"] embeddings.contains
      (embeddings.filter (!failureIds.contains ·)).eraseDups),
    ("final_resources", member goal "final_resources"),
    ("effects", Json.arr #[Json.str "network_instruction", Json.str "pending"]),
    ("residuals", Json.str "residual_set"),
    ("execution_failures", Json.arr (executionFailureKinds.map Json.str).toArray),
    ("provenance", Json.str "certificate_basis")])⟩

def GoalObservations.digest (observations : GoalObservations) : String :=
  Necoherence.Sha256.digest observations.canonical

instance : Wire GoalObservations where
  encode observations := (Json.parse observations.canonical).toOption.getD Json.null
  decode json := do
    keys json ["outputs", "failures", "final_resources", "effects", "residuals", "execution_failures", "provenance"]
    pure ⟨canonicalJson json⟩

structure Basis where
  signatureSchema : String
  libraryIdentity : String
  libraryRevision : String
  profile : Necoherence.SemanticTypes.ProfileRef
  graphSha256 : String
  provenanceSha256 : String
  metadataSha256 : String
  problemSha256 : Option String
  observationsSha256 : Option String
  entrypointsSha256 : String
  deriving Repr, DecidableEq

instance : Wire Basis where
  encode value := Json.mkObj [("signature_schema", encode value.signatureSchema),
    ("library_identity", encode value.libraryIdentity), ("library_revision", encode value.libraryRevision),
    ("profile", encode value.profile), ("graph_sha256", encode value.graphSha256),
    ("provenance_sha256", encode value.provenanceSha256), ("metadata_sha256", encode value.metadataSha256),
    ("problem_sha256", encode value.problemSha256), ("observations_sha256", encode value.observationsSha256),
    ("entrypoints_sha256", encode value.entrypointsSha256)]
  decode json := do
    keys json ["signature_schema", "library_identity", "library_revision", "profile", "graph_sha256",
      "provenance_sha256", "metadata_sha256", "problem_sha256", "observations_sha256", "entrypoints_sha256"]
    pure { signatureSchema := ← get json "signature_schema", libraryIdentity := ← get json "library_identity", libraryRevision := ← get json "library_revision", profile := ← get json "profile", graphSha256 := ← get json "graph_sha256", provenanceSha256 := ← get json "provenance_sha256", metadataSha256 := ← get json "metadata_sha256", problemSha256 := ← get json "problem_sha256", observationsSha256 := ← get json "observations_sha256", entrypointsSha256 := ← get json "entrypoints_sha256" }

def basis (library : TypeSignatureLibrary) (entrypoints : List Entrypoint) (composition : Option Json := none) : Basis :=
  { signatureSchema := library.schema, libraryIdentity := library.identity, libraryRevision := library.revision,
    profile := library.profile.reference, graphSha256 := hash (graphProjection library),
    provenanceSha256 := hash (provenanceProjection library), metadataSha256 := hash (metadataProjection library),
    problemSha256 := composition.map hash,
    observationsSha256 := composition.map fun value => (goalObservations value).digest,
    entrypointsSha256 := hash (encode (entrypoints.mergeSort (fun a b => a.identity ≤ b.identity))) }

structure ExpectedBasis where
  basis : Basis
  observations : Option GoalObservations
  deriving Repr, DecidableEq

instance : Wire ExpectedBasis where
  encode value := Json.mkObj [("basis", encode value.basis), ("observations", encode value.observations)]
  decode json := do
    keys json ["basis", "observations"]
    pure { basis := ← get json "basis", observations := ← get json "observations" }

def expectedBasis (library : TypeSignatureLibrary) (entrypoints : List Entrypoint) (composition : Option Json := none) : ExpectedBasis :=
  { basis := basis library entrypoints composition, observations := composition.map goalObservations }

structure Input where
  schema : String := "ncoh-checked-generation@5"
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
    if schema != "ncoh-checked-generation@5" then
      throw (WireFailure.unsupportedSchema "$.schema" schema)
    pure {
      schema := schema
      basis := ← get json "basis"
      signatures := ← get json "signatures"
      composition := ← get json "composition"
      entrypoints := ← get json "entrypoints" }

def ExpectedBasis.ofInput (input : Input) : ExpectedBasis :=
  { basis := input.basis, observations := input.composition.map goalObservations }

structure CheckedInput (input : Input) : Type where
  library : CheckedLibrary input.signatures
  trusted : input.basis = basis input.signatures input.entrypoints input.composition

/-- 規則の表による照合の不一致から、6 つの条件の状態を得る。 -/
def conditionStatus (mismatch : NecoQuotient.Mismatch String) (condition : NecoQuotient.Condition) : String :=
  match mismatch.statusAt condition with
  | .matched => "Matched"
  | .mismatched => "Mismatched"
  | .uncheckedByDecode _ => "UncheckedByDecode"
  | .uncheckedBySource _ => "UncheckedBySource"

def certificateFailures (mismatch : NecoQuotient.Mismatch String) : List (String × String) :=
  let checks := mismatch.checks
  let decode := match checks.decode with
    | .failed failure => [("decode", failure.operation)]
    | .established _ => []
  let source := match checks.source with
    | .failed failure => [("source", failure.operation)]
    | .established children =>
      (match children.coordinate with
        | .matched => []
        | .mismatched failure => [("coordinate", failure.operation)]) ++
      (match children.observations with
        | .matched => []
        | .mismatched failure => [("observations", failure.operation)]) ++
      (match children.residual with
        | .matched => []
        | .mismatched failure => [("residual", failure.operation)])
  decode ++ source

def projectionResultName : NecoQuotient.ProjectionResult → String
  | .matched _ => "matched"
  | .certificateOnly _ => "certificateOnly"
  | .recomputedOnly _ => "recomputedOnly"
  | .different _ _ => "different"

def certificateDigestsJson (mismatch : NecoQuotient.Mismatch String) : Lean.Json :=
  match mismatch.checks.decode with
  | .failed _ => Lean.Json.null
  | .established digests => Lean.Json.mkObj (digests.entries.map fun (name, result) =>
      (name, Lean.Json.str (projectionResultName result)))

def certificateFailureJson (mismatch : NecoQuotient.Mismatch String) : Lean.Json :=
  Lean.Json.mkObj [("kind", .str "certificate"),
    ("conditions", Lean.Json.mkObj [("decode", .str (conditionStatus mismatch .decode)),
      ("source", .str (conditionStatus mismatch .source)),
      ("coordinate", .str (conditionStatus mismatch .coordinate)),
      ("observations", .str (conditionStatus mismatch .observations)),
      ("digest", .str (conditionStatus mismatch .digest)),
      ("residual", .str (conditionStatus mismatch .residual))]),
    ("failures", .arr ((certificateFailures mismatch).map (fun (condition, operation) =>
      Lean.Json.mkObj [("condition", .str condition), ("operation", .str operation)])).toArray),
    ("origin", Lean.Json.mkObj [("rule_revision", .str mismatch.checks.origin.ruleRevision),
      ("source_identity", .str mismatch.checks.origin.sourceIdentity),
      ("source_revision", .str mismatch.checks.origin.sourceRevision)]),
    ("digests", certificateDigestsJson mismatch),
    ("provenance", .str mismatch.checks.provenance)]

instance : Repr (NecoQuotient.Mismatch String) where
  reprPrec mismatch _ := Std.Format.text (Lean.Json.compress (certificateFailureJson mismatch))

inductive AdmissionFailure where
  | unsupportedSchema (schema : String)
  | entrypointsEmpty
  | entrypointIdentityEmpty
  | entrypointDuplicate (identity : String)
  | entrypointUnresolved (identity : String) (definition : DefinitionId)
  | library (failure : LibraryCheckFailure)
  | certificate (failure : NecoQuotient.Mismatch String)
  | wire (failure : WireFailure)
  | compositionInput (failure : Necoherence.SemanticComposition.CompositionInputFailure)
  | composition (failure : Necoherence.SemanticComposition.WitnessFailure)
  deriving Repr

inductive InputDecodeFailure where
  | json (failure : WireFailure)
  | wire (failure : WireFailure)
  deriving BEq, Repr

def decodeInput (text : String) : Except InputDecodeFailure Input := do
  let json ← (Necoherence.SignatureJson.parse text).mapError InputDecodeFailure.json
  decode json |>.mapError InputDecodeFailure.wire
def encodeInput (input : Input) : String := canonicalJson (encode input)


end Necoherence.SignatureGeneration
