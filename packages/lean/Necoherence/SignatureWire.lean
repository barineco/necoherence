-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.TypeSignatures
import Necoherence.SignatureProfileWire
import Necoherence.SignatureJson

namespace Necoherence.SignatureWire
open Lean Necoherence.SemanticTypes Necoherence.TypeSignatures
private def unitTag (tag : String) : Json := Json.mkObj [("tag", .str tag)]
private def tupleTag (tag : String) (value : Json) : Json :=
  Json.mkObj [("tag", .str tag), ("value", value)]
private def recordTag (tag : String) (fields : List (String × Json)) : Json :=
  Json.mkObj [("tag", .str tag), ("fields", Json.mkObj fields)]
private def payload (json : Json) : Except WireFailure Json := do
  keys json ["tag", "value"]
  liftJson (json.getObjVal? "value")
private def fields (json : Json) : Except WireFailure Json := do
  keys json ["tag", "fields"]
  liftJson (json.getObjVal? "fields")


instance : Wire OutcomeForm where
  encode
    | .success => unitTag "Success"
    | .declaredFailure => unitTag "DeclaredFailure"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Success" => keys json ["tag"]; pure .success
    | "DeclaredFailure" => keys json ["tag"]; pure .declaredFailure
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire ValueProfile where
  encode value := Json.mkObj [
    ("reference", encode value.reference), ("source_refs", encode value.sourceRefs),
    ("integer_domains", encode value.integerDomains),
    ("default_integer_domain", encode value.defaultIntegerDomain), ("numbers", encode value.numbers),
    ("grapheme_rules", encode value.graphemeRules), ("format_bindings", encode value.formatBindings),
    ("bytes_policy", encode value.bytesPolicy), ("wrappers", encode value.wrappers), ("tag", encode value.tag)]
  decode json := do
    keys json ["reference", "source_refs", "integer_domains", "default_integer_domain", "numbers",
      "grapheme_rules", "format_bindings", "bytes_policy", "wrappers", "tag"]
    let reference ← get json "reference"
    let sourceRefs ← get json "source_refs"
    let integerDomains ← get json "integer_domains"
    let defaultIntegerDomain ← get json "default_integer_domain"
    let numbers ← get json "numbers"
    let graphemeRules ← get json "grapheme_rules"
    let formatBindings ← get json "format_bindings"
    let bytesPolicy ← get json "bytes_policy"
    let wrappers ← get json "wrappers"
    let tag ← get json "tag"
    pure ({
      reference := reference
      sourceRefs := sourceRefs
      integerDomains := integerDomains
      defaultIntegerDomain := defaultIntegerDomain
      numbers := numbers
      graphemeRules := graphemeRules
      formatBindings := formatBindings
      bytesPolicy := bytesPolicy
      wrappers := wrappers
      tag := tag } : ValueProfile)

instance : Wire Target where
  encode
    | .library => unitTag "Library"
    | .group value => tupleTag "Group" (encode value)
    | .definition value => tupleTag "Definition" (encode value)
    | .type value => tupleTag "Type" (encode value)
    | .outcome definition outcome => recordTag "Outcome" [("definition", encode definition), ("outcome", encode outcome)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Library" => do keys json ["tag"]; pure .library
    | "Group" => return .group (← decode (← payload json))
    | "Definition" => return .definition (← decode (← payload json))
    | "Type" => return .type (← decode (← payload json))
    | "Outcome" => do
      let row ← fields json
      keys row ["definition", "outcome"]
      pure (.outcome (← get row "definition") (← get row "outcome"))
    | tag => throw (.unknownTag "$.tag" tag)

partial def encodeExact : Necoherence.ExactJson.JsonValue → Json
  | .null => unitTag "Null"
  | .bool value => tupleTag "Bool" (encode value)
  | .num value => tupleTag "Integer" (encode value)
  | .dec text => Json.mkObj [("tag", .str "Decimal"), ("text", .str text)]
  | .str value => tupleTag "String" (encode value)
  | .arr values => Json.mkObj [("tag", .str "Array"), ("items", .arr (values.map encodeExact).toArray)]
  | .obj values => Json.mkObj [("tag", .str "Object"), ("members", .arr (values.map (fun (key, value) => Json.mkObj [("key", .str key), ("value", encodeExact value)])).toArray)]
partial def decodeExact (json : Json) : Except WireFailure Necoherence.ExactJson.JsonValue := do
  match ← get (α := String) json "tag" with
  | "Null" => do keys json ["tag"]; pure .null
  | "Bool" => return .bool (← decode (← payload json))
  | "Integer" => return .num (← decode (← payload json))
  | "String" => return .str (← decode (← payload json))
  | "Decimal" => do
    keys json ["tag", "text"]
    let text : String ← get json "text"
    if text.trimAscii.toString != text then
      throw (WireFailure.syntax "$.text" "decimal whitespace")
    match Necoherence.SignatureJson.parse text with
    | .ok (.num _) => pure (.dec text)
    | _ => throw (WireFailure.syntax "$.text" "invalid exact decimal")
  | "Array" => do
    keys json ["tag", "items"]
    return .arr (← (← liftJson (← liftJson (json.getObjVal? "items")).getArr?).toList.mapM decodeExact)
  | "Object" => do
    keys json ["tag", "members"]
    let entries ← (← liftJson (← liftJson (json.getObjVal? "members")).getArr?).toList.mapM fun entry => do
      keys entry ["key", "value"]
      pure (← get (α := String) entry "key", ← decodeExact (← liftJson (entry.getObjVal? "value")))
    pure (.obj entries)
  | tag => throw (.unknownTag "$.tag" tag)
instance : Wire Necoherence.ExactJson.JsonValue := ⟨encodeExact, decodeExact⟩

instance : Wire Annotation where
  encode value := Json.mkObj [("target", encode value.target), ("key", encode value.key), ("value", encode value.value)]
  decode json := do
    keys json ["target", "key", "value"]
    pure { target := ← get json "target", key := ← get json "key", value := ← get json "value" }

instance : Wire ProvenanceBinding where
  encode value := Json.mkObj [("target", encode value.target), ("origins", encode value.origins)]
  decode json := do
    keys json ["target", "origins"]
    pure { target := ← get json "target", origins := ← get json "origins" }

instance : Wire DefinitionGroup where
  encode value := Json.mkObj [("id", encode value.id), ("members", encode value.members)]
  decode json := do
    keys json ["id", "members"]
    pure { id := ← get json "id", members := ← get json "members" }

instance : Wire Slot where
  encode value := Json.mkObj [("type_id", encode value.typeId), ("required", encode value.required), ("nullable", encode value.nullable)]
  decode json := do
    keys json ["type_id", "required", "nullable"]
    pure { typeId := ← get json "type_id", required := ← get json "required", nullable := ← get json "nullable" }

instance : Wire Field where
  encode value := Json.mkObj [("wire_name", encode value.wireName), ("slot", encode value.slot)]
  decode json := do
    keys json ["wire_name", "slot"]
    pure { wireName := ← get json "wire_name", slot := ← get json "slot" }

instance : Wire Port where
  encode value := Json.mkObj [("id", encode value.id), ("contract", encode value.contract)]
  decode json := do
    keys json ["id", "contract"]
    pure { id := ← get json "id", contract := ← get json "contract" }

instance : Wire Necoherence.TypeSignatures.ResourceProduction where
  encode value := Json.mkObj [("id", encode value.id), ("token_type", encode value.tokenType), ("revision", encode value.revision), ("quantity", encode value.quantity), ("provenance", encode value.provenance)]
  decode json := do
    keys json ["id", "token_type", "revision", "quantity", "provenance"]
    pure { id := ← get json "id", tokenType := ← get json "token_type", revision := ← get json "revision", quantity := ← get json "quantity", provenance := ← get json "provenance" }

instance : Wire OutcomeCause where
  encode
    | .valueContract origin => recordTag "ValueContract" [("origin", encode origin)]
    | .externalCondition specification => recordTag "ExternalCondition" [("specification", encode specification)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "ValueContract" => do
      let row ← fields json
      keys row ["origin"]
      pure (.valueContract (← get row "origin"))
    | "ExternalCondition" => do
      let row ← fields json
      keys row ["specification"]
      pure (.externalCondition (← get row "specification"))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Necoherence.TypeSignatures.OutcomeContract where
  encode value := Json.mkObj [("id", encode value.id), ("form", encode value.form), ("cause", encode value.cause), ("value_ports", encode value.valuePorts), ("produced_resources", encode value.producedResources)]
  decode json := do
    keys json ["id", "form", "cause", "value_ports", "produced_resources"]
    pure { id := ← get json "id", form := ← get json "form", cause := ← get json "cause", valuePorts := ← get json "value_ports", producedResources := ← get json "produced_resources" }

instance : Wire OperationContract where
  encode value := Json.mkObj [("effect", encode value.effect), ("inputs", encode value.inputs), ("outcomes", encode value.outcomes)]
  decode json := do
    keys json ["effect", "inputs", "outcomes"]
    pure { effect := ← get json "effect", inputs := ← get json "inputs", outcomes := ← get json "outcomes" }

instance : Wire DecimalBound where
  encode value := Json.mkObj [
    ("mantissa", encode value.mantissa), ("scale", encode value.scale),
    ("exclusive", encode value.exclusive)]
  decode json := do
    keys json ["mantissa", "scale", "exclusive"]
    let mantissa ← get json "mantissa"
    let scale ← get json "scale"
    let exclusive ← get json "exclusive"
    pure { mantissa := mantissa, scale := scale, exclusive := exclusive }

instance : Wire DecimalSpec where
  encode value := Json.mkObj [("minimum", encode value.minimum), ("maximum", encode value.maximum)]
  decode json := do
    keys json ["minimum", "maximum"]
    pure { minimum := ← get json "minimum", maximum := ← get json "maximum" }

instance : Wire ValueKind where
  encode
    | .null => unitTag "Null" | .boolean => unitTag "Boolean" | .number => unitTag "Number"
    | .string => unitTag "String" | .array => unitTag "Array" | .object => unitTag "Object"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Null" => keys json ["tag"]; pure .null
    | "Boolean" => keys json ["tag"]; pure .boolean
    | "Number" => keys json ["tag"]; pure .number
    | "String" => keys json ["tag"]; pure .string
    | "Array" => keys json ["tag"]; pure .array
    | "Object" => keys json ["tag"]; pure .object
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire MemberTest where
  encode
    | .absent => unitTag "Absent"
    | .format name => tupleTag "Format" (encode name)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Absent" => keys json ["tag"]; pure .absent
    | "Format" => return .format (← decode (← payload json))
    | tag => throw (.unknownTag "$.tag" tag)

private def encodeMemberCheck (check : String × MemberTest) : Json :=
  Json.mkObj [("key", encode check.1), ("test", encode check.2)]

private def decodeMemberCheck (json : Json) : Except WireFailure (String × MemberTest) := do
  keys json ["key", "test"]
  return (← get json "key", ← get json "test")

instance : Wire BranchSelector where
  encode
    | .internalTag => unitTag "InternalTag"
    | .memberShape tests => tupleTag "MemberShape" (.arr (tests.map encodeMemberCheck).toArray)
    | .kind kind => tupleTag "Kind" (encode kind)
    | .otherwise => unitTag "Otherwise"
  decode json := do
    match ← get (α := String) json "tag" with
    | "InternalTag" => keys json ["tag"]; pure .internalTag
    | "MemberShape" =>
      return .memberShape (← (← liftJson (← payload json).getArr?).toList.mapM decodeMemberCheck)
    | "Kind" => return .kind (← decode (← payload json))
    | "Otherwise" => keys json ["tag"]; pure .otherwise
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Necoherence.TypeSignatures.ElementContract where
  encode value := Json.mkObj [("type_id", encode value.typeId), ("nullable", encode value.nullable)]
  decode json := do
    keys json ["type_id", "nullable"]
    pure { typeId := ← get json "type_id", nullable := ← get json "nullable" }

instance : Wire Necoherence.TypeSignatures.ExtraMembers where
  encode
    | .reject => unitTag "Reject"
    | .allow keyFormat value =>
      recordTag "Allow" [("key_format", encode keyFormat), ("value", encode value)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Reject" => keys json ["tag"]; pure .reject
    | "Allow" => do
      let row ← fields json
      keys row ["key_format", "value"]
      pure (.allow (← get row "key_format") (← get row "value"))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Necoherence.TypeSignatures.ProductSpec where
  encode value := Json.mkObj [("fields", encode value.fields), ("extras", encode value.extras)]
  decode json := do
    keys json ["fields", "extras"]
    pure { fields := ← get json "fields", extras := ← get json "extras" }

instance : Wire Necoherence.TypeSignatures.ArraySpec where
  encode value := Json.mkObj [
    ("item", encode value.item), ("min_length", encode value.minimum),
    ("max_length", encode value.maximum)]
  decode json := do
    keys json ["item", "min_length", "max_length"]
    let item ← get json "item"
    let minimum ← get json "min_length"
    let maximum ← get json "max_length"
    pure { item := item, minimum := minimum, maximum := maximum }

instance : Wire Necoherence.TypeSignatures.UnionBranch where
  encode value := Json.mkObj [
    ("target", encode value.target), ("wire_tag", encode value.wireTag),
    ("selector", encode value.selector)]
  decode json := do
    keys json ["target", "wire_tag", "selector"]
    let target ← get json "target"
    let wireTag ← get json "wire_tag"
    let selector ← get json "selector"
    pure { target := target, wireTag := wireTag, selector := selector }

instance : Wire Necoherence.TypeSignatures.UnionSpec where
  encode value := Json.mkObj [("branches", encode value.branches)]
  decode json := do
    keys json ["branches"]
    pure { branches := ← get json "branches" }

instance : Wire Necoherence.TypeSignatures.SealedRefinement where
  encode value := Json.mkObj [("key", encode value.key), ("leaf", encode value.leaf)]
  decode json := do
    keys json ["key", "leaf"]
    pure { key := ← get json "key", leaf := ← get json "leaf" }

instance : Wire UnknownKind where
  encode
    | .any => unitTag "Any"
    | .ordinaryObject => unitTag "OrdinaryObject"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Any" => keys json ["tag"]; pure .any
    | "OrdinaryObject" => keys json ["tag"]; pure .ordinaryObject
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Shape where
  encode
    | .unknown kind => tupleTag "Unknown" (encode kind)
    | .unit => unitTag "Unit"
    | .boolean spec => tupleTag "Boolean" (encode spec)
    | .integer spec => tupleTag "Integer" (encode spec)
    | .decimal spec => tupleTag "Decimal" (encode spec)
    | .string spec => tupleTag "String" (encode spec)
    | .bytes spec => tupleTag "Bytes" (encode spec)
    | .product spec => tupleTag "Product" (encode spec)
    | .array spec => tupleTag "Array" (encode spec)
    | .taggedUnion spec => tupleTag "TaggedUnion" (encode spec)
    | .sealed tag refinements =>
      recordTag "Sealed" [("tag", encode tag), ("refinements", encode refinements)]
    | .never => unitTag "Never"
    | .alias target => recordTag "Alias" [("target", encode target)]
    | .rawBody encoding => recordTag "RawBody" [("encoding", encode encoding)]
    | .opaque name => recordTag "Opaque" [("type_name", encode name)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Unknown" => return .unknown (← decode (← payload json))
    | "Unit" => keys json ["tag"]; pure .unit
    | "Boolean" => return .boolean (← decode (← payload json))
    | "Integer" => return .integer (← decode (← payload json))
    | "Decimal" => return .decimal (← decode (← payload json))
    | "String" => return .string (← decode (← payload json))
    | "Bytes" => return .bytes (← decode (← payload json))
    | "Product" => return .product (← decode (← payload json))
    | "Array" => return .array (← decode (← payload json))
    | "TaggedUnion" => return .taggedUnion (← decode (← payload json))
    | "Sealed" => do
      let row ← fields json
      keys row ["tag", "refinements"]
      pure (.sealed (← get row "tag") (← get row "refinements"))
    | "Never" => keys json ["tag"]; pure .never
    | "Alias" => do
      let row ← fields json
      keys row ["target"]
      pure (.alias (← get row "target"))
    | "RawBody" => do
      let row ← fields json
      keys row ["encoding"]
      pure (.rawBody (← get row "encoding"))
    | "Opaque" => do
      let row ← fields json
      keys row ["type_name"]
      pure (.opaque (← get row "type_name"))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Node where
  encode value := Json.mkObj [("id", encode value.id), ("shape", encode value.shape)]
  decode json := do
    keys json ["id", "shape"]
    pure { id := ← get json "id", shape := ← get json "shape" }

instance : Wire Necoherence.TypeSignatures.DefinitionShape where
  encode
    | .value value => tupleTag "Value" (encode value)
    | .symbol value => tupleTag "Symbol" (encode value)
    | .operation value => tupleTag "Operation" (encode value)
    | .message value => tupleTag "Message" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Value" => return .value (← decode (← payload json))
    | "Symbol" => return .symbol (← decode (← payload json))
    | "Operation" => return .operation (← decode (← payload json))
    | "Message" => return .message (← decode (← payload json))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Necoherence.TypeSignatures.Definition where
  encode value := Json.mkObj [("id", encode value.id), ("wire_identity", encode value.wireIdentity), ("shape", encode value.shape)]
  decode json := do
    keys json ["id", "wire_identity", "shape"]
    pure { id := ← get json "id", wireIdentity := ← get json "wire_identity", shape := ← get json "shape" }

instance : Wire TypeSignatureLibrary where
  encode value := Json.mkObj [("schema", encode value.schema), ("identity", encode value.identity), ("revision", encode value.revision), ("profile", encode value.profile), ("sources", encode value.sources), ("provenance", encode value.provenance), ("groups", encode value.groups), ("annotations", encode value.annotations), ("nodes", encode value.nodes), ("definitions", encode value.definitions)]
  decode json := do
    keys json ["schema", "identity", "revision", "profile", "sources", "provenance", "groups", "annotations", "nodes", "definitions"]
    pure { schema := ← get json "schema", identity := ← get json "identity", revision := ← get json "revision", profile := ← get json "profile", sources := ← get json "sources", provenance := ← get json "provenance", groups := ← get json "groups", annotations := ← get json "annotations", nodes := ← get json "nodes", definitions := ← get json "definitions" }

end Necoherence.SignatureWire
