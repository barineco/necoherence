-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureCompositionWire

open Lean Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition
open Necoherence.SignatureWire Necoherence.SemanticInvariantWire Necoherence.SemanticInvariantDerivation

private def library : Library :=
  { identity := "contract", revision := "1",
    profile := { reference := { identity := "synthetic", revision := "1", contentDigest := "contract" } },
    sources := [], definitions := [],
    nodes := [{ id := "empty", shape := .unit }] }

private def slot : SlotContract :=
  { typeRef := Necoherence.TypeSignatures.typeRef "empty", required := true, nullable := false }

private def valueRef : ValueRef := { producer := .initial ⟨"input"⟩, path := [] }

private def outcomeProducer : ProducerRef := .invocationOutcome ⟨"site"⟩ ⟨"outcome"⟩ ⟨"port"⟩

private def projection : ProjectionCertificate :=
  { profile := { identity := "profile", revision := "1", contentDigest := "d" }, sourceRefs := [],
    source := slot, path := [], assumptions := [.variant [] "tag"], destination := slot }

private def productBinding : BindingExpr := .product "build" slot.typeRef []

private def sourceBinding : BindingExpr := .source valueRef projection (.suppliedValue .absent)

private def invocation : InvocationPlan :=
  { site := ⟨"site"⟩, function := { identity := "function", revision := "1", contentDigest := "d" },
    bindings := [], resources := [] }

private def inclusionJson : Except WireFailure Json := do
  let some node := library.graph.nodes.head? | throw (WireFailure.syntax "$" "library node")
  let entry : PairEntry :=
    { pair := { source := slot, destination := slot }, sourceShape := node.shape,
      destinationShape := node.shape, rule := .sameDefinedType, children := [] }
  inclusionEncode library
    { basis := SemanticBasis.of library.graph, source := slot, destination := slot, emptyTypes := [],
      pairs := [entry], root := 0 }

private def treeNode (tree : PlanTree) : Except WireFailure Json := do
  liftJson ((← treeEncode library tree).getObjVal? "node")

private def treeNodeDecode (node : Json) : Except WireFailure Unit := do
  let _ ← treeDecode library (Json.mkObj [("rank", encode (0 : Nat)), ("node", node)])
  pure ()

private def ruleJson : Except WireFailure Json := do
  liftJson ((← liftJson ((← liftJson ((← inclusionJson).getObjVal? "pairs")).getArr?))[0]!.getObjVal? "rule")

private def requireFailure (name variant : String) (result : Except WireFailure Unit) (expected : WireFailure → Bool) : IO Unit :=
  match result with
  | .error failure =>
      if expected failure then pure () else throw (IO.userError (s!"{name} {variant}: {reprStr failure}"))
  | .ok _ => throw (IO.userError (s!"{name} {variant}: accepted"))

private def checkSum (name : String) (encoded : Except WireFailure Json) (decode : Json → Except WireFailure Unit) : IO Unit := do
  let encoded ← match encoded with
    | .ok json => pure json
    | .error failure => throw (IO.userError (s!"{name}: encoding failed: {reprStr failure}"))
  match decode encoded with
  | .ok _ => pure ()
  | .error failure => throw (IO.userError (s!"{name}: valid wire rejected: {reprStr failure}"))
  let extra : Json → Json := fun json => json.setObjVal! "extra" (.num 1)
  requireFailure name "unknown tag" (decode (Json.mkObj [("tag", .str "Bogus")])) fun
    | .unknownTag _ "Bogus" => true
    | _ => false
  requireFailure name "unknown tag with extra key" (decode (Json.mkObj [("tag", .str "Bogus"), ("extra", .num 1)])) fun
    | .unknownTag _ "Bogus" => true
    | _ => false
  requireFailure name "known tag with extra key" (decode (extra encoded)) fun
    | .unknownField _ "extra" => true
    | _ => false
  requireFailure name "tag missing" (decode (Json.mkObj [])) fun
    | .syntax _ _ => true
    | _ => false
  if let .ok members := encoded.getObjVal? "fields" then
    requireFailure name "fields with extra key" (decode (encoded.setObjVal! "fields" (extra members))) fun
      | .unknownField _ "extra" => true
      | _ => false

def checkDerivationSumShapes : IO Unit := do
  checkSum "plan-node-return" (treeNode (.returnValue 0 (.success [(⟨"goal"⟩, productBinding)]))) treeNodeDecode
  checkSum "plan-node-invoke" (treeNode (.invoke 0 invocation [] [])) treeNodeDecode
  checkSum "plan-node-guard" (treeNode (.guard 0 ⟨"guard"⟩ valueRef [])) treeNodeDecode
  checkSum "return-success" (returnEncode library (.success [(⟨"goal"⟩, productBinding)]))
    (fun json => (returnDecode library json).map fun _ => ())
  checkSum "return-failure" (returnEncode library (.failure ⟨"embedding"⟩ productBinding))
    (fun json => (returnDecode library json).map fun _ => ())
  checkSum "binding-source" (bindingEncode library sourceBinding)
    (fun json => (bindingDecode library json).map fun _ => ())
  checkSum "binding-product" (bindingEncode library productBinding)
    (fun json => (bindingDecode library json).map fun _ => ())
  let compatibility (binding : BindingExpr) : Except WireFailure Json := do
    liftJson ((← liftJson ((← bindingEncode library binding).getObjVal? "fields")).getObjVal? "compatibility")
  let sourceWithCompatibility (compatibility : Json) : Except WireFailure Json := do
    let encoded ← bindingEncode library sourceBinding
    let row ← liftJson (encoded.getObjVal? "fields")
    pure (encoded.setObjVal! "fields" (row.setObjVal! "compatibility" compatibility))
  checkSum "binding-compatibility-supplied" (compatibility sourceBinding) fun json => do
    let _ ← bindingDecode library (← sourceWithCompatibility json)
    pure ()
  checkSum "binding-compatibility-inclusion" (do pure (tupleTag "Inclusion" (← inclusionJson))) fun json => do
    let _ ← bindingDecode library (← sourceWithCompatibility json)
    pure ()
  checkSum "inclusion-rule" ruleJson fun json => do
    let certificate ← inclusionJson
    let rows ← liftJson (← liftJson (certificate.getObjVal? "pairs")).getArr?
    let row := rows[0]!.setObjVal! "rule" json
    let _ ← inclusionDecode library (certificate.setObjVal! "pairs" (.arr (rows.set! 0 row)))
    pure ()
  checkSum "binding-producer-initial" (pure (encode (ProducerRef.initial ⟨"input"⟩)))
    (fun json => (decode json : Except WireFailure ProducerRef).map fun _ => ())
  checkSum "binding-producer-outcome" (pure (encode outcomeProducer))
    (fun json => (decode json : Except WireFailure ProducerRef).map fun _ => ())
  checkSum "projection-assumption-present" (pure (encode (ProjectionAssumption.present [])))
    (fun json => (decode json : Except WireFailure ProjectionAssumption).map fun _ => ())
  checkSum "projection-assumption-variant" (pure (encode (ProjectionAssumption.variant [] "tag")))
    (fun json => (decode json : Except WireFailure ProjectionAssumption).map fun _ => ())
  checkSum "trace-step-invocation" (stepEncode library (.invocation invocation ⟨"outcome"⟩))
    (fun json => (stepDecode library json).map fun _ => ())
  checkSum "trace-step-guard" (stepEncode library (.guard ⟨"guard"⟩ valueRef .present))
    (fun json => (stepDecode library json).map fun _ => ())
  checkSum "goal-place-has-at-least" (pure (encode (Necoherence.GoalPredicate.placeHasAtLeast "place" 1)))
    (fun json => (decode json : Except WireFailure Necoherence.GoalPredicate).map fun _ => ())
  checkSum "goal-not" (pure (encode (Necoherence.GoalPredicate.glNot (.placeHasAtLeast "place" 1))))
    (fun json => (decode json : Except WireFailure Necoherence.GoalPredicate).map fun _ => ())
  checkSum "token-kind" (pure (encode Necoherence.TokenKind.input))
    (fun json => (decode json : Except WireFailure Necoherence.TokenKind).map fun _ => ())
  checkSum "binding-mode" (pure (encode Necoherence.BindingMode.read))
    (fun json => (decode json : Except WireFailure Necoherence.BindingMode).map fun _ => ())
  IO.println "derivation_sums=wire_shape tag=unknownTag keys=checked fields=checked"

#eval checkDerivationSumShapes
