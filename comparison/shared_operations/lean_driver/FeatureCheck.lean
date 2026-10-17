-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT


import Necoherence
import Lean.Data.Json

open Necoherence
open Lean (Json)

namespace FeatureCheck



inductive FailureKind where
  | jsonSyntax
  | queryShape
  | unknownFeature
  | unknownOperation
  | inputShape

def failureKindStr : FailureKind → String
  | .jsonSyntax => "json_syntax"
  | .queryShape => "query_shape"
  | .unknownFeature => "unknown_feature"
  | .unknownOperation => "unknown_operation"
  | .inputShape => "input_shape"

structure DecodeFailure where
  kind : FailureKind
  detail : String

abbrev D (α : Type) := Except DecodeFailure α

def failShape (detail : String) : DecodeFailure := ⟨.inputShape, detail⟩

def liftShape (r : Except String α) : D α :=
  match r with
  | .ok v => .ok v
  | .error msg => .error (failShape msg)



def objVal (j : Json) (k : String) : D Json := liftShape (j.getObjVal? k)

def asStr (j : Json) : D String :=
  match j with
  | .str s => .ok s
  | _ => .error (failShape "expected string")

def asArr (j : Json) : D (Array Json) :=
  match j with
  | .arr a => .ok a
  | _ => .error (failShape "expected array")

def natOfStr (s : String) : D Nat :=
  if s.isEmpty then .error (failShape "empty integer")
  else if s.toList.all Char.isDigit then
    match s.toNat? with
    | some n => .ok n
    | none => .error (failShape "invalid integer")
  else .error (failShape "invalid integer")

def natField (j : Json) (k : String) : D Nat := do
  let v ← objVal j k
  let s ← asStr v
  natOfStr s

def strField (j : Json) (k : String) : D String := do
  let v ← objVal j k
  asStr v

def arrField (j : Json) (k : String) : D (Array Json) := do
  let v ← objVal j k
  asArr v

def natToJson (n : Nat) : Json := Json.str (toString n)



def decodeResourceId (j : Json) : D ResourceId := do
  let kind ← strField j "kind"
  let name ← strField j "name"
  return ⟨kind, name⟩

def encodeResourceId (r : ResourceId) : Json :=
  Json.mkObj [("kind", Json.str r.kind), ("name", Json.str r.name)]

def decodeRevision (j : Json) : D Revision := do
  let s ← asStr j
  let v ← natOfStr s
  return ⟨v⟩

def encodeRevision (r : Revision) : Json := natToJson r.value

def decodeBasis (j : Json) : D Basis := do
  let resource ← decodeResourceId (← objVal j "resource")
  let revision ← decodeRevision (← objVal j "revision")
  return ⟨resource, revision⟩

def encodeBasis (b : Basis) : Json :=
  Json.mkObj [("resource", encodeResourceId b.resource), ("revision", encodeRevision b.revision)]

def decodeWorldEntry (j : Json) : D (ResourceId × Revision) := do
  let resource ← decodeResourceId (← objVal j "resource")
  let revision ← decodeRevision (← objVal j "revision")
  return (resource, revision)

def decodeWorld (j : Json) : D World := do
  let arr ← asArr j
  arr.toList.mapM decodeWorldEntry

def encodeWorldEntry (p : ResourceId × Revision) : Json :=
  Json.mkObj [("resource", encodeResourceId p.1), ("revision", encodeRevision p.2)]

def encodeWorld (w : World) : Json := Json.arr (w.map encodeWorldEntry).toArray

def encodeLookup : Lookup → Json
  | .found r => Json.mkObj [("tag", Json.str "found"), ("revision", encodeRevision r)]
  | .unknown u => Json.mkObj [("tag", Json.str "unknown"), ("resource", encodeResourceId u.resource)]

def decodeCommand (j : Json) : D (Command Json) := do
  let intent ← objVal j "intent"
  let basis ← decodeBasis (← objVal j "basis")
  return ⟨intent, basis⟩

def encodeCommand (c : Command Json) : Json :=
  Json.mkObj [("intent", c.intent), ("basis", encodeBasis c.basis)]

def encodeApplyOutcome : Outcome (Json × World) UnknownResource StaleBasis Empty → Json
  | .applied (intent, w) =>
      Json.mkObj [("tag", Json.str "applied"), ("intent", intent), ("world", encodeWorld w)]
  | .rejected u => Json.mkObj [("tag", Json.str "rejected"), ("resource", encodeResourceId u.resource)]
  | .conflicted k =>
      Json.mkObj [("tag", Json.str "conflicted"),
        ("expected", encodeRevision k.expected), ("actual", encodeRevision k.actual)]
  | .boundaryFailed f => f.elim



def opCoreLookup (input : Json) : D Json := do
  let world ← decodeWorld (← objVal input "world")
  let resource ← decodeResourceId (← objVal input "resource")
  return encodeLookup (World.lookup world resource)

def opCoreBump (input : Json) : D Json := do
  let world ← decodeWorld (← objVal input "world")
  let resource ← decodeResourceId (← objVal input "resource")
  return encodeWorld (World.bump world resource)

def opCoreCommandOf (input : Json) : D Json := do
  let obsJ ← objVal input "observation"
  let payload ← objVal obsJ "payload"
  let basis ← decodeBasis (← objVal obsJ "basis")
  let observedAt ← natField obsJ "observedAt"
  let o : Observation Json := ⟨payload, basis, observedAt⟩
  let x ← objVal input "payload"
  return encodeCommand (commandOf o x)

def opCoreApply (input : Json) : D Json := do
  let world ← decodeWorld (← objVal input "world")
  let command ← decodeCommand (← objVal input "command")
  return encodeApplyOutcome (World.apply world command)



inductive FunctionForm where
  | identity
  | const (value : Json)
  | getField (name : String)
  | setField (name : String) (value : Json)
  | wrap (tag : String)

def decodeFunctionForm (j : Json) : D FunctionForm := do
  let kind ← strField j "kind"
  match kind with
  | "identity" => return .identity
  | "const" => return .const (← objVal j "value")
  | "getField" => return .getField (← strField j "name")
  | "setField" => return .setField (← strField j "name") (← objVal j "value")
  | "wrap" => return .wrap (← strField j "tag")
  | other => throw (failShape s!"unknown function form kind {other}")

def applyFunctionForm : FunctionForm → Json → Json
  | .identity, x => x
  | .const v, _ => v
  | .getField n, x => x.getObjValD n
  | .setField n v, x =>
      match x with
      | .obj _ => x.setObjVal! n v
      | _ => Json.mkObj [(n, v)]
  | .wrap t, x => Json.mkObj [("tag", Json.str t), ("value", x)]

def decodeRequest (j : Json) : D (Request Json) := do
  let payload ← objVal j "payload"
  let fieldsArr ← arrField j "fields"
  let fields ← fieldsArr.toList.mapM asStr
  return ⟨payload, fields⟩

def decodeImmediate (j : Json) : D (Immediate Json Json) := do
  let identity ← strField j "identity"
  let requiredArr ← arrField j "required"
  let required ← requiredArr.toList.mapM asStr
  let form ← decodeFunctionForm (← objVal j "output")
  return immediateOf identity required (applyFunctionForm form)

def decodeDeferred (j : Json) : D (Deferred Json Json) := do
  let identity ← strField j "identity"
  let requiredArr ← arrField j "required"
  let required ← requiredArr.toList.mapM asStr
  let form ← decodeFunctionForm (← objVal j "output")
  return deferredOf identity required (applyFunctionForm form)

def encodeCallResult : CallResult Json → Json
  | .ok v => Json.mkObj [("tag", Json.str "ok"), ("value", v)]
  | .failed f =>
      Json.mkObj [("tag", Json.str "failed"), ("declaration", Json.str f.declaration),
        ("fields", Json.arr (f.fields.map Json.str).toArray)]



def opCallImmediateOf (input : Json) : D Json := do
  let decl ← decodeImmediate input
  return Json.mkObj [("identity", Json.str decl.identity),
    ("required", Json.arr (decl.required.map Json.str).toArray)]

def opCallDeferredOf (input : Json) : D Json := do
  let decl ← decodeDeferred input
  return Json.mkObj [("identity", Json.str decl.identity),
    ("required", Json.arr (decl.required.map Json.str).toArray)]

def opCallIo (input : Json) : D Json := do
  let decl ← decodeImmediate (← objVal input "declaration")
  let req ← decodeRequest (← objVal input "request")
  return encodeCallResult (io decl req)

def opCallIssue (input : Json) : D Json := do
  let decl ← decodeDeferred (← objVal input "declaration")
  let req ← decodeRequest (← objVal input "request")
  return encodeCallResult (issue decl req)



inductive AdvanceForm where
  | consumeImmediately (outputs : List Json)
  | reprocessAlways (outputs : List Json)
  | consumeAfter (rounds : Nat) (outputsPerRound : List Json)

def decodeAdvanceForm (j : Json) : D AdvanceForm := do
  let mode ← strField j "mode"
  match mode with
  | "consumeImmediately" =>
      let arr ← arrField j "outputs"
      return .consumeImmediately arr.toList
  | "reprocessAlways" =>
      let arr ← arrField j "outputs"
      return .reprocessAlways arr.toList
  | "consumeAfter" =>
      let rounds ← natField j "rounds"
      let arr ← arrField j "outputsPerRound"
      return .consumeAfter rounds arr.toList
  | other => throw (failShape s!"unknown advance mode {other}")


def roundOf (state : Json) : Nat :=
  match state.getObjValD "round" with
  | .str s => s.toNat?.getD 0
  | _ => 0

def stateWithRound (n : Nat) : Json := Json.mkObj [("round", Json.str (toString n))]

def advanceEval (form : AdvanceForm) (state _input : Json) : Consumption Json Json :=
  match form with
  | .consumeImmediately outputs => .consumed state outputs
  | .reprocessAlways outputs => .reprocess state outputs
  | .consumeAfter rounds outputs =>
      let r := roundOf state + 1
      let newState := stateWithRound r
      if r >= rounds then .consumed newState outputs else .reprocess newState outputs

def encodeStepFailure : StepFailure → Json
  | .reprocessLimitExhausted n =>
      Json.mkObj [("tag", Json.str "reprocess_limit_exhausted"), ("applications", natToJson n)]
  | .capacityExceeded c a =>
      Json.mkObj [("tag", Json.str "capacity_exceeded"),
        ("capacity", natToJson c), ("attempted", natToJson a)]

def encodeStepTransition : StepTransition Json Json → Json
  | .settled s o n =>
      Json.mkObj [("tag", Json.str "settled"), ("state", s),
        ("outputs", Json.arr o.toArray), ("applications", natToJson n)]
  | .failed s o f =>
      Json.mkObj [("tag", Json.str "failed"), ("state", s),
        ("outputs", Json.arr o.toArray), ("failure", encodeStepFailure f)]



def opStepTransitionStep (input : Json) : D Json := do
  let state ← objVal input "state"
  let inp ← objVal input "input"
  let form ← decodeAdvanceForm (← objVal input "advance")
  let limitN ← natField input "limit"
  let capacityN ← natField input "capacity"
  if h : 0 < limitN then
    let limit : PositiveLimit := ⟨limitN, h⟩
    let capacity : Capacity := ⟨capacityN⟩
    return encodeStepTransition (Necoherence.step state inp (advanceEval form) limit capacity)
  else
    throw (failShape "limit must be positive")



def encodeStageProjectionFailed (s : StageProjectionFailed) : Json :=
  Json.mkObj [("position", natToJson s.position),
    ("declaration", Json.str s.failure.declaration),
    ("fields", Json.arr (s.failure.fields.map Json.str).toArray)]


def decodeFoldReq (j : Json) : D (FoldReq Json × List String) := do
  let step ← decodeImmediate (← objVal j "step")
  let seed ← objVal j "seed"
  let count ← natField j "count"
  let fieldsArr ← arrField j "stepFields"
  let stepFields ← fieldsArr.toList.mapM asStr
  return (⟨step, seed, count, stepFields⟩, stepFields)

def encodeFoldOutcome : FoldOutcome Json → Json
  | .trace states => Json.mkObj [("tag", Json.str "trace"), ("states", Json.arr states.toArray)]
  | .stopped states stopped =>
      Json.mkObj [("tag", Json.str "stopped"), ("states", Json.arr states.toArray),
        ("stopped", encodeStageProjectionFailed stopped)]


inductive StepOutcomeForm where
  | settled
  | advance (measure : Nat)

def decodeStepOutcomeForm (j : Json) : D StepOutcomeForm := do
  let tag ← strField j "tag"
  match tag with
  | "settled" => return .settled
  | "advance" => return .advance (← natField j "measure")
  | other => throw (failShape s!"unknown step outcome tag {other}")


def decodeRecurseTable (j : Json) : D (List (Json × StepOutcomeForm)) := do
  let arr ← asArr j
  arr.toList.mapM (fun entry => do
    let payload ← objVal entry "payload"
    let form ← decodeStepOutcomeForm (← objVal entry "outcome")
    return (payload, form))

def recurseStepOutput (table : List (Json × StepOutcomeForm)) (nextOf : Json → Json) (state : Json) :
    StepOutcome Json :=
  match table.find? (fun (p, _) => p == state) with
  | some (_, .settled) => .settled state
  | some (_, .advance m) => .advance (nextOf state) m
  | none => .settled state

def decodeRecurseReq (j : Json) : D (RecurseReq Json × List String) := do
  let requiredArr ← arrField j "required"
  let required ← requiredArr.toList.mapM asStr
  let table ← decodeRecurseTable (← objVal j "table")
  let nextForm ← decodeFunctionForm (← objVal j "next")
  let seed ← objVal j "seed"
  let fieldsArr ← arrField j "stepFields"
  let stepFields ← fieldsArr.toList.mapM asStr
  let identity := "necoherence.iteration.recurse.adapter.step"
  let step : Immediate Json (StepOutcome Json) :=
    immediateOf identity required (recurseStepOutput table (applyFunctionForm nextForm))
  return (⟨step, seed, stepFields⟩, stepFields)

def encodeRecurseOutcome : RecurseOutcome Json → Json
  | .settled value steps =>
      Json.mkObj [("tag", Json.str "settled"), ("value", value), ("steps", natToJson steps)]
  | .didNotDecrease position state measure prevMeasure =>
      Json.mkObj [("tag", Json.str "did_not_decrease"), ("position", natToJson position),
        ("state", state), ("measure", natToJson measure), ("previousMeasure", natToJson prevMeasure)]
  | .projectionFailed lastState stopped =>
      Json.mkObj [("tag", Json.str "projection_failed"), ("lastState", lastState),
        ("stopped", encodeStageProjectionFailed stopped)]


def jsonElements (j : Json) : List Json :=
  match j with
  | .arr a => a.toList
  | _ => []


def closureElemToJson (s : String) : Json := (Json.parse s).toOption.getD Json.null

def closureElemOfJson (j : Json) : String := j.compress


def decodeClosureReq (j : Json) : D (ClosureReq String × List String) := do
  let identity ← strField (← objVal j "step") "identity"
  let requiredArr ← arrField (← objVal j "step") "required"
  let required ← requiredArr.toList.mapM asStr
  let form ← decodeFunctionForm (← objVal (← objVal j "step") "output")
  let step : Immediate (ClosureState String) (List String) :=
    immediateOf identity required (fun cs =>
      let elemsJson := Json.arr (cs.elements.map closureElemToJson).toArray
      let producedJson := applyFunctionForm form elemsJson
      (jsonElements producedJson).map closureElemOfJson)
  let carrierArr ← arrField j "carrier"
  let carrier := carrierArr.toList.map closureElemOfJson
  let seedArr ← arrField j "seed"
  let seed := seedArr.toList.map closureElemOfJson
  let fieldsArr ← arrField j "stepFields"
  let stepFields ← fieldsArr.toList.mapM asStr
  return (⟨step, carrier, seed, stepFields⟩, stepFields)

def encodeClosureElems (elems : List String) : Json := Json.arr (elems.map closureElemToJson).toArray

def encodeClosureOutcome : ClosureOutcome String → Json
  | .fixpoint result position =>
      Json.mkObj [("tag", Json.str "fixpoint"), ("result", encodeClosureElems result),
        ("position", natToJson position)]
  | .violation position current produced =>
      Json.mkObj [("tag", Json.str "violation"), ("position", natToJson position),
        ("current", encodeClosureElems current), ("produced", encodeClosureElems produced)]
  | .projectionFailed current stopped =>
      Json.mkObj [("tag", Json.str "projection_failed"), ("current", encodeClosureElems current),
        ("stopped", encodeStageProjectionFailed stopped)]



def opIterationFold (input : Json) : D Json := do
  let (req, _) ← decodeFoldReq input
  return encodeFoldOutcome (foldOutput req)

def opIterationRecurse (input : Json) : D Json := do
  let (req, _) ← decodeRecurseReq input
  return encodeRecurseOutcome (recurseOutput req)

def opIterationClosure (input : Json) : D Json := do
  let (req, _) ← decodeClosureReq input
  return encodeClosureOutcome (closureOutput req)



def decodeStoreEntry (j : Json) : D (ResourceId × Revision × Json) := do
  let resource ← decodeResourceId (← objVal j "resource")
  let revision ← decodeRevision (← objVal j "revision")
  let payload ← objVal j "payload"
  return (resource, revision, payload)

def decodeStore (j : Json) : D (Store Json) := do
  let arr ← asArr j
  arr.toList.mapM decodeStoreEntry

def encodeStoreEntry (e : ResourceId × Revision × Json) : Json :=
  Json.mkObj [("resource", encodeResourceId e.1), ("revision", encodeRevision e.2.1), ("payload", e.2.2)]

def encodeStore (s : Store Json) : Json := Json.arr (s.map encodeStoreEntry).toArray

def encodeObserve : Observe Json → Json
  | .found r a => Json.mkObj [("tag", Json.str "found"), ("revision", encodeRevision r), ("payload", a)]
  | .unknown u => Json.mkObj [("tag", Json.str "unknown"), ("resource", encodeResourceId u.resource)]

def encodeStoreApplyOutcome : Outcome (Json × Store Json) UnknownResource StaleBasis Empty → Json
  | .applied (intent, s) =>
      Json.mkObj [("tag", Json.str "applied"), ("intent", intent), ("store", encodeStore s)]
  | .rejected u => Json.mkObj [("tag", Json.str "rejected"), ("resource", encodeResourceId u.resource)]
  | .conflicted k =>
      Json.mkObj [("tag", Json.str "conflicted"),
        ("expected", encodeRevision k.expected), ("actual", encodeRevision k.actual)]
  | .boundaryFailed f => f.elim



def opStoreStoreOf (input : Json) : D Json := do
  let s ← decodeStore input
  return encodeStore s

def opStoreStoreEntries (input : Json) : D Json := do
  let s ← decodeStore (← objVal input "store")
  return encodeStore s

def opStoreObserve (input : Json) : D Json := do
  let s ← decodeStore (← objVal input "store")
  let resource ← decodeResourceId (← objVal input "resource")
  return encodeObserve (Store.observe s resource)

def opStoreApply (input : Json) : D Json := do
  let s ← decodeStore (← objVal input "store")
  let command ← decodeCommand (← objVal input "command")
  return encodeStoreApplyOutcome (Store.apply s command)

def opStoreWorldOf (input : Json) : D Json := do
  let s ← decodeStore input
  return encodeWorld (Store.worldOf s)



def decodeCallRecord (j : Json) : D (CallRecord Json Json) := do
  let declaration ← strField j "declaration"
  let input ← objVal j "input"
  let product ← objVal j "product"
  let basisJ ← objVal j "basis"
  let basis ←
    match basisJ with
    | .null => pure none
    | _ => pure (some (← decodeBasis basisJ))
  return ⟨declaration, input, product, basis⟩

def encodeCallRecord (r : CallRecord Json Json) : Json :=
  Json.mkObj [("declaration", Json.str r.declaration), ("input", r.input), ("product", r.product),
    ("basis", match r.basis with | none => Json.null | some b => encodeBasis b)]



def opRecordRecordOf (input : Json) : D Json := do
  let declaration ← strField input "declaration"
  let ins ← objVal input "input"
  let product ← objVal input "product"
  return encodeCallRecord (recordOf declaration ins product)

def opRecordRecordOnBasis (input : Json) : D Json := do
  let declaration ← strField input "declaration"
  let ins ← objVal input "input"
  let product ← objVal input "product"
  let basis ← decodeBasis (← objVal input "basis")
  return encodeCallRecord (recordOnBasis declaration ins product basis)

def opRecordHasEdge (input : Json) : D Json := do
  let earlier ← decodeCallRecord (← objVal input "earlier")
  let later ← decodeCallRecord (← objVal input "later")
  let holds :=
    match earlier.basis, later.basis with
    | some settledBasis, some readBasis => decide (settledBasis.resource = readBasis.resource)
    | _, _ => false
  return Json.mkObj [("holds", Json.bool holds)]




def resourceIdLe (a b : ResourceId) : Bool :=
  match compare a.kind b.kind with
  | .lt => true
  | .gt => false
  | .eq => compare a.name b.name != .gt

def divergenceResource : Divergence → ResourceId
  | .worldAhead r _ _ => r
  | .worldBehind r _ _ => r
  | .unknownToWorld r _ => r

def encodeDivergence : Divergence → Json
  | .worldAhead r recorded actual =>
      Json.mkObj [("tag", Json.str "world_ahead"), ("resource", encodeResourceId r),
        ("recorded", encodeRevision recorded), ("actual", encodeRevision actual)]
  | .worldBehind r recorded actual =>
      Json.mkObj [("tag", Json.str "world_behind"), ("resource", encodeResourceId r),
        ("recorded", encodeRevision recorded), ("actual", encodeRevision actual)]
  | .unknownToWorld r recorded =>
      Json.mkObj [("tag", Json.str "unknown_to_world"), ("resource", encodeResourceId r),
        ("recorded", encodeRevision recorded)]

def encodeReconciliation (r : Reconciliation) : Json :=
  let sorted := r.divergences.mergeSort (fun a b => resourceIdLe (divergenceResource a) (divergenceResource b))
  Json.mkObj [("divergences", Json.arr (sorted.map encodeDivergence).toArray),
    ("unbased", natToJson r.unbased), ("dropped", natToJson r.dropped)]

def decodeOptionBasis (j : Json) : D (Option Basis) := do
  match j with
  | .null => pure none
  | _ => pure (some (← decodeBasis j))



def opReconcileReconcile (input : Json) : D Json := do
  let basesArr ← arrField input "bases"
  let bases ← basesArr.toList.mapM decodeOptionBasis
  let world ← decodeWorld (← objVal input "world")
  let dropped ← natField input "dropped"
  return encodeReconciliation (reconcile bases world dropped)

def opReconcileCoherent (input : Json) : D Json := do
  let divergencesArr ← arrField input "divergences"
  let divergences ← divergencesArr.toList.mapM (fun j => do
    let tag ← strField j "tag"
    match tag with
    | "world_ahead" =>
        return Divergence.worldAhead (← decodeResourceId (← objVal j "resource"))
          (← decodeRevision (← objVal j "recorded")) (← decodeRevision (← objVal j "actual"))
    | "world_behind" =>
        return Divergence.worldBehind (← decodeResourceId (← objVal j "resource"))
          (← decodeRevision (← objVal j "recorded")) (← decodeRevision (← objVal j "actual"))
    | "unknown_to_world" =>
        return Divergence.unknownToWorld (← decodeResourceId (← objVal j "resource"))
          (← decodeRevision (← objVal j "recorded"))
    | other => throw (failShape s!"unknown divergence tag {other}"))
  let unbased ← natField input "unbased"
  let dropped ← natField input "dropped"
  let r : Reconciliation := ⟨divergences, unbased, dropped⟩
  return Json.mkObj [("coherent", Json.bool (Necoherence.coherent r))]



def decodeRequestPolicy (j : Json) : D RequestPolicy := do
  let s ← asStr j
  match s with
  | "latestWins" => return .latestWins
  | "fifo" => return .fifo
  | "allExecute" => return .allExecute
  | other => throw (failShape s!"unknown policy {other}")

def encodeRequestPolicy : RequestPolicy → Json
  | .latestWins => Json.str "latestWins"
  | .fifo => Json.str "fifo"
  | .allExecute => Json.str "allExecute"

def decodeRequestPhase (j : Json) : D RequestPhase := do
  let s ← asStr j
  match s with
  | "pending" => return .pending
  | "preparing" => return .preparing
  | "publishing" => return .publishing
  | "published" => return .published
  | "superseded" => return .superseded
  | "cancelled" => return .cancelled
  | "failed" => return .failed
  | other => throw (failShape s!"unknown phase {other}")

def encodeRequestPhase : RequestPhase → Json
  | .pending => Json.str "pending"
  | .preparing => Json.str "preparing"
  | .publishing => Json.str "publishing"
  | .published => Json.str "published"
  | .superseded => Json.str "superseded"
  | .cancelled => Json.str "cancelled"
  | .failed => Json.str "failed"

def decodeRequestEffectClass (j : Json) : D RequestEffectClass := do
  let s ← asStr j
  match s with
  | "pure" => return .pure
  | "orderedEffect" => return .orderedEffect
  | other => throw (failShape s!"unknown effect class {other}")

def encodeRequestEffectClass : RequestEffectClass → Json
  | .pure => Json.str "pure"
  | .orderedEffect => Json.str "orderedEffect"

def decodeRequestIdentity (j : Json) : D RequestIdentity := do
  let kind ← strField j "kind"
  let provenance ← strField j "provenance"
  let revision ← natField j "revision"
  return ⟨kind, provenance, revision⟩

def encodeRequestIdentity (i : RequestIdentity) : Json :=
  Json.mkObj [("kind", Json.str i.kind), ("provenance", Json.str i.provenance),
    ("revision", natToJson i.revision)]

def decodeRequestFootprint (j : Json) : D RequestFootprint := do
  let readsArr ← arrField j "reads"
  let reads ← readsArr.toList.mapM asStr
  let writesArr ← arrField j "writes"
  let writes ← writesArr.toList.mapM asStr
  let effectClass ← decodeRequestEffectClass (← objVal j "effectClass")
  return ⟨reads, writes, effectClass⟩

def encodeRequestFootprint (f : RequestFootprint) : Json :=
  Json.mkObj [("reads", Json.arr (f.reads.map Json.str).toArray),
    ("writes", Json.arr (f.writes.map Json.str).toArray),
    ("effectClass", encodeRequestEffectClass f.effectClass)]

def decodeResourceDemand (j : Json) : D ResourceDemand := do
  let pending ← natField j "pending"
  let inFlight ← natField j "inFlight"
  let concurrent ← natField j "concurrent"
  return ⟨pending, inFlight, concurrent⟩

def encodeResourceDemand (d : ResourceDemand) : Json :=
  Json.mkObj [("pending", natToJson d.pending), ("inFlight", natToJson d.inFlight),
    ("concurrent", natToJson d.concurrent)]

def decodeConfiguredSafetyLimit (j : Json) : D ConfiguredSafetyLimit := do
  let resource ← strField j "resource"
  let maximum ← natField j "maximum"
  return ⟨resource, maximum⟩

def encodeConfiguredSafetyLimit (l : ConfiguredSafetyLimit) : Json :=
  Json.mkObj [("resource", Json.str l.resource), ("maximum", natToJson l.maximum)]

def decodeResourceBudget (j : Json) : D ResourceBudget := do
  let pendingMaximum ← decodeConfiguredSafetyLimit (← objVal j "pendingMaximum")
  let inFlightMaximum ← decodeConfiguredSafetyLimit (← objVal j "inFlightMaximum")
  let concurrentMaximum ← decodeConfiguredSafetyLimit (← objVal j "concurrentMaximum")
  return ⟨pendingMaximum, inFlightMaximum, concurrentMaximum⟩

def encodeResourceBudget (b : ResourceBudget) : Json :=
  Json.mkObj [("pendingMaximum", encodeConfiguredSafetyLimit b.pendingMaximum),
    ("inFlightMaximum", encodeConfiguredSafetyLimit b.inFlightMaximum),
    ("concurrentMaximum", encodeConfiguredSafetyLimit b.concurrentMaximum)]

def decodeEvidenceVersion (j : Json) : D EvidenceVersion := do
  let identifier ← strField j "identifier"
  let digest ← strField j "digest"
  let artifactPath ← strField j "artifactPath"
  return ⟨identifier, digest, artifactPath⟩

def encodeEvidenceVersion (e : EvidenceVersion) : Json :=
  Json.mkObj [("identifier", Json.str e.identifier), ("digest", Json.str e.digest),
    ("artifactPath", Json.str e.artifactPath)]

def decodePermissionDenial (j : Json) : D PermissionDenial := do
  let s ← asStr j
  return .denial s

def encodePermissionDenial : PermissionDenial → Json
  | .denial s => Json.str s

def decodeMeaningPermission (j : Json) : D MeaningPermission := do
  let tag ← strField j "tag"
  match tag with
  | "permitted" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let evArr ← arrField j "evidence"
      let evidence ← evArr.toList.mapM decodeEvidenceVersion
      return .permitted identity evidence
  | "ordered" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let evArr ← arrField j "evidence"
      let evidence ← evArr.toList.mapM decodeEvidenceVersion
      return .ordered identity evidence
  | "denied" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let reason ← decodePermissionDenial (← objVal j "reason")
      return .denied identity reason
  | other => throw (failShape s!"unknown meaning permission tag {other}")

def encodeMeaningPermission : MeaningPermission → Json
  | .permitted identity evidence =>
      Json.mkObj [("tag", Json.str "permitted"), ("identity", encodeRequestIdentity identity),
        ("evidence", Json.arr (evidence.map encodeEvidenceVersion).toArray)]
  | .ordered identity evidence =>
      Json.mkObj [("tag", Json.str "ordered"), ("identity", encodeRequestIdentity identity),
        ("evidence", Json.arr (evidence.map encodeEvidenceVersion).toArray)]
  | .denied identity reason =>
      Json.mkObj [("tag", Json.str "denied"), ("identity", encodeRequestIdentity identity),
        ("reason", encodePermissionDenial reason)]

def decodeExecutionHandle (j : Json) : D ExecutionHandle := do
  let s ← asStr j
  return ⟨s⟩

def encodeExecutionHandle (h : ExecutionHandle) : Json := Json.str h.value

def decodeCostSelection (j : Json) : D CostSelection := do
  let tag ← strField j "tag"
  let identity ← decodeRequestIdentity (← objVal j "identity")
  let evidence ← decodeEvidenceVersion (← objVal j "evidence")
  let cost ← natField j "cost"
  match tag with
  | "executeNow" => return .executeNow identity evidence cost
  | "remainPending" => return .remainPending identity evidence cost
  | other => throw (failShape s!"unknown cost selection tag {other}")

def encodeCostSelection : CostSelection → Json
  | .executeNow identity evidence cost =>
      Json.mkObj [("tag", Json.str "executeNow"), ("identity", encodeRequestIdentity identity),
        ("evidence", encodeEvidenceVersion evidence), ("cost", natToJson cost)]
  | .remainPending identity evidence cost =>
      Json.mkObj [("tag", Json.str "remainPending"), ("identity", encodeRequestIdentity identity),
        ("evidence", encodeEvidenceVersion evidence), ("cost", natToJson cost)]

def decodeRequestEntry (j : Json) : D RequestEntry := do
  let identity ← decodeRequestIdentity (← objVal j "identity")
  let footprint ← decodeRequestFootprint (← objVal j "footprint")
  let demand ← decodeResourceDemand (← objVal j "demand")
  let phase ← decodeRequestPhase (← objVal j "phase")
  let meaningPermission ← decodeMeaningPermission (← objVal j "meaningPermission")
  let costSelectionJ ← objVal j "costSelection"
  let costSelection ←
    match costSelectionJ with
    | .null => pure none
    | _ => pure (some (← decodeCostSelection costSelectionJ))
  let handleJ ← objVal j "executionHandle"
  let executionHandle ←
    match handleJ with
    | .null => pure none
    | _ => pure (some (← decodeExecutionHandle handleJ))
  return ⟨identity, footprint, demand, phase, meaningPermission, costSelection, executionHandle⟩

def encodeRequestEntry (e : RequestEntry) : Json :=
  Json.mkObj [("identity", encodeRequestIdentity e.identity), ("footprint", encodeRequestFootprint e.footprint),
    ("demand", encodeResourceDemand e.demand), ("phase", encodeRequestPhase e.phase),
    ("meaningPermission", encodeMeaningPermission e.meaningPermission),
    ("costSelection", match e.costSelection with | none => Json.null | some s => encodeCostSelection s),
    ("executionHandle", match e.executionHandle with | none => Json.null | some h => encodeExecutionHandle h)]

def decodeRequestProgressionSnapshot (j : Json) : D RequestProgressionSnapshot := do
  let policy ← decodeRequestPolicy (← objVal j "policy")
  let budget ← decodeResourceBudget (← objVal j "budget")
  let currentIdentityJ ← objVal j "currentIdentity"
  let currentIdentity ←
    match currentIdentityJ with
    | .null => pure none
    | _ => pure (some (← decodeRequestIdentity currentIdentityJ))
  let entriesArr ← arrField j "entries"
  let entries ← entriesArr.toList.mapM decodeRequestEntry
  let revision ← natField j "revision"
  return ⟨policy, budget, currentIdentity, entries, revision⟩

def encodeRequestProgressionSnapshot (s : RequestProgressionSnapshot) : Json :=
  Json.mkObj [("policy", encodeRequestPolicy s.policy), ("budget", encodeResourceBudget s.budget),
    ("currentIdentity",
      match s.currentIdentity with | none => Json.null | some i => encodeRequestIdentity i),
    ("entries", Json.arr (s.entries.map encodeRequestEntry).toArray), ("revision", natToJson s.revision)]

def decodeRequestInput (j : Json) : D RequestInput := do
  let identity ← decodeRequestIdentity (← objVal j "identity")
  let footprint ← decodeRequestFootprint (← objVal j "footprint")
  let demand ← decodeResourceDemand (← objVal j "demand")
  let permission ← decodeMeaningPermission (← objVal j "permission")
  return ⟨identity, footprint, demand, permission⟩

def decodeAccepted (j : Json) : D Accepted := do
  let identity ← decodeRequestIdentity (← objVal j "identity")
  return ⟨identity⟩

def encodeAccepted (a : Accepted) : Json := Json.mkObj [("identity", encodeRequestIdentity a.identity)]

def decodeRunning (j : Json) : D Running := do
  let identity ← decodeRequestIdentity (← objVal j "identity")
  let handle ← decodeExecutionHandle (← objVal j "handle")
  return ⟨identity, handle⟩

def encodeRunning (r : Running) : Json :=
  Json.mkObj [("identity", encodeRequestIdentity r.identity), ("handle", encodeExecutionHandle r.handle)]

def encodeAdapterCommand : AdapterCommand → Json
  | .startCommand identity footprint =>
      Json.mkObj [("tag", Json.str "startCommand"), ("identity", encodeRequestIdentity identity),
        ("footprint", encodeRequestFootprint footprint)]
  | .cancelCommand identity handle =>
      Json.mkObj [("tag", Json.str "cancelCommand"), ("identity", encodeRequestIdentity identity),
        ("handle", encodeExecutionHandle handle)]

def decodeAdapterCommand (j : Json) : D AdapterCommand := do
  let tag ← strField j "tag"
  match tag with
  | "startCommand" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let footprint ← decodeRequestFootprint (← objVal j "footprint")
      return .startCommand identity footprint
  | "cancelCommand" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let handle ← decodeExecutionHandle (← objVal j "handle")
      return .cancelCommand identity handle
  | other => throw (failShape s!"unknown adapter command tag {other}")

def decodeStarting (j : Json) : D Starting := do
  let identity ← decodeRequestIdentity (← objVal j "identity")
  let command ← decodeAdapterCommand (← objVal j "command")
  return ⟨identity, command⟩

def encodeStarting (s : Starting) : Json :=
  Json.mkObj [("identity", encodeRequestIdentity s.identity), ("command", encodeAdapterCommand s.command)]


def decodeAdapterSignal (j : Json) : D (AdapterSignal Json) := do
  let tag ← strField j "tag"
  match tag with
  | "started" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let handle ← decodeExecutionHandle (← objVal j "handle")
      return .started identity handle
  | "completed" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let handle ← decodeExecutionHandle (← objVal j "handle")
      let value ← objVal j "value"
      return .completed identity handle value
  | "cancelledAtAdapter" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let handle ← decodeExecutionHandle (← objVal j "handle")
      return .cancelledAtAdapter identity handle
  | other => throw (failShape s!"unknown adapter signal tag {other}")

def decodeAdapterFailure (j : Json) : D AdapterFailure := do
  let tag ← strField j "tag"
  match tag with
  | "startAdapterFailure" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let detail ← strField j "detail"
      return .startAdapterFailure identity detail
  | "completionAdapterFailure" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let handle ← decodeExecutionHandle (← objVal j "handle")
      let detail ← strField j "detail"
      return .completionAdapterFailure identity handle detail
  | "cancellationAdapterFailure" =>
      let identity ← decodeRequestIdentity (← objVal j "identity")
      let handle ← decodeExecutionHandle (← objVal j "handle")
      let detail ← strField j "detail"
      return .cancellationAdapterFailure identity handle detail
  | other => throw (failShape s!"unknown adapter failure tag {other}")

def decodeAdapterResult (j : Json) : D (AdapterResult (AdapterSignal Json) AdapterFailure) := do
  let tag ← strField j "tag"
  match tag with
  | "appliedSignal" => return .appliedSignal (← decodeAdapterSignal (← objVal j "signal"))
  | "adapterFailed" => return .adapterFailed (← decodeAdapterFailure (← objVal j "failure"))
  | other => throw (failShape s!"unknown adapter result tag {other}")

def encodeSubmitFailure : SubmitFailure → Json
  | .duplicateIdentity identity =>
      Json.mkObj [("tag", Json.str "duplicateIdentity"), ("identity", encodeRequestIdentity identity)]
  | .pendingLimitExceeded demand budget =>
      Json.mkObj [("tag", Json.str "pendingLimitExceeded"), ("demand", encodeResourceDemand demand),
        ("budget", encodeResourceBudget budget)]

def encodeSubmitResult : SubmitResult → Json
  | .accepted snapshot accepted =>
      Json.mkObj [("tag", Json.str "accepted"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("accepted", encodeAccepted accepted)]
  | .submitRejected snapshot failure =>
      Json.mkObj [("tag", Json.str "submitRejected"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("failure", encodeSubmitFailure failure)]

def encodeStartDecisionFailure : StartDecisionFailure → Json
  | .unknownRequest identity =>
      Json.mkObj [("tag", Json.str "unknownRequest"), ("identity", encodeRequestIdentity identity)]
  | .requestNotPending identity =>
      Json.mkObj [("tag", Json.str "requestNotPending"), ("identity", encodeRequestIdentity identity)]
  | .policyOrderBlocked identity =>
      Json.mkObj [("tag", Json.str "policyOrderBlocked"), ("identity", encodeRequestIdentity identity)]
  | .permissionDenied identity reason =>
      Json.mkObj [("tag", Json.str "permissionDenied"), ("identity", encodeRequestIdentity identity),
        ("reason", encodePermissionDenial reason)]
  | .permissionIdentityMismatch a b =>
      Json.mkObj [("tag", Json.str "permissionIdentityMismatch"), ("identity", encodeRequestIdentity a),
        ("other", encodeRequestIdentity b)]
  | .permissionNotOrdered identity =>
      Json.mkObj [("tag", Json.str "permissionNotOrdered"), ("identity", encodeRequestIdentity identity)]
  | .costSelectionIdentityMismatch a b =>
      Json.mkObj [("tag", Json.str "costSelectionIdentityMismatch"), ("identity", encodeRequestIdentity a),
        ("other", encodeRequestIdentity b)]
  | .inFlightLimitExceeded demand budget =>
      Json.mkObj [("tag", Json.str "inFlightLimitExceeded"), ("demand", encodeResourceDemand demand),
        ("budget", encodeResourceBudget budget)]
  | .concurrentLimitExceeded demand budget =>
      Json.mkObj [("tag", Json.str "concurrentLimitExceeded"), ("demand", encodeResourceDemand demand),
        ("budget", encodeResourceBudget budget)]

def encodeStartDecisionResult : StartDecisionResult → Json
  | .execute snapshot starting command =>
      Json.mkObj [("tag", Json.str "execute"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("starting", encodeStarting starting), ("command", encodeAdapterCommand command)]
  | .deferred snapshot accepted =>
      Json.mkObj [("tag", Json.str "deferred"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("accepted", encodeAccepted accepted)]
  | .rejected snapshot failure =>
      Json.mkObj [("tag", Json.str "rejected"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("failure", encodeStartDecisionFailure failure)]

def encodeStartObservationFailure : StartObservationFailure → Json
  | .unknownRequest identity =>
      Json.mkObj [("tag", Json.str "unknownRequest"), ("identity", encodeRequestIdentity identity)]
  | .requestNotStarting identity =>
      Json.mkObj [("tag", Json.str "requestNotStarting"), ("identity", encodeRequestIdentity identity)]
  | .startIdentityMismatch a b =>
      Json.mkObj [("tag", Json.str "startIdentityMismatch"), ("identity", encodeRequestIdentity a),
        ("other", encodeRequestIdentity b)]
  | .startSignalMismatch identity =>
      Json.mkObj [("tag", Json.str "startSignalMismatch"), ("identity", encodeRequestIdentity identity)]
  | .startAdapterFailureObserved identity detail =>
      Json.mkObj [("tag", Json.str "startAdapterFailureObserved"), ("identity", encodeRequestIdentity identity),
        ("detail", Json.str detail)]

def encodeStartObservationResult : StartObservationResult → Json
  | .publishing snapshot running =>
      Json.mkObj [("tag", Json.str "publishing"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("running", encodeRunning running)]
  | .failed snapshot failure =>
      Json.mkObj [("tag", Json.str "failed"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("failure", encodeStartObservationFailure failure)]

def encodeCompletionObservationFailure : CompletionObservationFailure → Json
  | .unknownCompletion identity =>
      Json.mkObj [("tag", Json.str "unknownCompletion"), ("identity", encodeRequestIdentity identity)]
  | .completionNotRunning identity =>
      Json.mkObj [("tag", Json.str "completionNotRunning"), ("identity", encodeRequestIdentity identity)]
  | .handleMismatch identity =>
      Json.mkObj [("tag", Json.str "handleMismatch"), ("identity", encodeRequestIdentity identity)]
  | .completionIdentityMismatch a b =>
      Json.mkObj [("tag", Json.str "completionIdentityMismatch"), ("identity", encodeRequestIdentity a),
        ("other", encodeRequestIdentity b)]
  | .completionSignalMismatch identity =>
      Json.mkObj [("tag", Json.str "completionSignalMismatch"), ("identity", encodeRequestIdentity identity)]
  | .completionAdapterFailureObserved identity detail =>
      Json.mkObj [("tag", Json.str "completionAdapterFailureObserved"),
        ("identity", encodeRequestIdentity identity), ("detail", Json.str detail)]
  | .cancellationAdapterFailureObserved identity detail =>
      Json.mkObj [("tag", Json.str "cancellationAdapterFailureObserved"),
        ("identity", encodeRequestIdentity identity), ("detail", Json.str detail)]

def encodeCompletionObservationResult : CompletionObservationResult Json → Json
  | .applied snapshot identity value =>
      Json.mkObj [("tag", Json.str "applied"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("identity", encodeRequestIdentity identity), ("value", value)]
  | .superseded snapshot identity =>
      Json.mkObj [("tag", Json.str "superseded"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("identity", encodeRequestIdentity identity)]
  | .cancelled snapshot identity =>
      Json.mkObj [("tag", Json.str "cancelled"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("identity", encodeRequestIdentity identity)]
  | .failed snapshot failure =>
      Json.mkObj [("tag", Json.str "failed"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("failure", encodeCompletionObservationFailure failure)]

def encodeCancelFailure : CancelFailure → Json
  | .unknownRequest identity =>
      Json.mkObj [("tag", Json.str "unknownRequest"), ("identity", encodeRequestIdentity identity)]
  | .requestAlreadyTerminal identity =>
      Json.mkObj [("tag", Json.str "requestAlreadyTerminal"), ("identity", encodeRequestIdentity identity)]
  | .missingExecutionHandle identity =>
      Json.mkObj [("tag", Json.str "missingExecutionHandle"), ("identity", encodeRequestIdentity identity)]

def encodeCancelDecisionResult : CancelDecisionResult → Json
  | .cancelled snapshot identity =>
      Json.mkObj [("tag", Json.str "cancelled"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("identity", encodeRequestIdentity identity)]
  | .cancelCommand snapshot running command =>
      Json.mkObj [("tag", Json.str "cancelCommand"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("running", encodeRunning running), ("command", encodeAdapterCommand command)]
  | .rejected snapshot failure =>
      Json.mkObj [("tag", Json.str "rejected"), ("snapshot", encodeRequestProgressionSnapshot snapshot),
        ("failure", encodeCancelFailure failure)]



def opRequestProgressionEmpty (input : Json) : D Json := do
  let policy ← decodeRequestPolicy (← objVal input "policy")
  let budget ← decodeResourceBudget (← objVal input "budget")
  return encodeRequestProgressionSnapshot (empty policy budget)

def opRequestProgressionSubmit (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  let request ← decodeRequestInput (← objVal input "request")
  return encodeSubmitResult (submit snapshot request)

def opRequestProgressionDecideStart (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  let accepted ← decodeAccepted (← objVal input "accepted")
  let selection ← decodeCostSelection (← objVal input "selection")
  return encodeStartDecisionResult (decideStart snapshot accepted selection)

def opRequestProgressionApplyStartObservation (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  let starting ← decodeStarting (← objVal input "starting")
  let observed ← decodeAdapterResult (← objVal input "observed")
  return encodeStartObservationResult (applyStartObservation snapshot starting observed)

def opRequestProgressionApplyCompletionObservation (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  let running ← decodeRunning (← objVal input "running")
  let observed ← decodeAdapterResult (← objVal input "observed")
  return encodeCompletionObservationResult (applyCompletionObservation snapshot running observed)

def opRequestProgressionDecideCancel (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  let identity ← decodeRequestIdentity (← objVal input "identity")
  return encodeCancelDecisionResult (decideCancel snapshot identity)

def opRequestProgressionDerivePending (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  return encodeResourceDemand (derivePending snapshot)

def opRequestProgressionDeriveInFlight (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  return encodeResourceDemand (deriveInFlight snapshot)

def opRequestProgressionDeriveConcurrent (input : Json) : D Json := do
  let snapshot ← decodeRequestProgressionSnapshot (← objVal input "snapshot")
  return encodeResourceDemand (deriveConcurrent snapshot)



def decodeEnvironmentSpecification (j : Json) : D EnvironmentSpecification := do
  let maxObservationAge ← natField j "maxObservationAge"
  return ⟨maxObservationAge⟩

def decodeCapacityObservation (j : Json) : D CapacityObservation := do
  let observed ← decodeResourceBudget (← objVal j "observed")
  let observedAt ← natField j "observedAt"
  return ⟨observed, observedAt⟩

def decodeSignalKind (j : Json) : D SignalKind := do
  let s ← asStr j
  match s with
  | "pendingCompletion" => return .pendingCompletion
  | "pendingCancellation" => return .pendingCancellation
  | other => throw (failShape s!"unknown signal kind {other}")

def encodeSignalKind : SignalKind → Json
  | .pendingCompletion => Json.str "pendingCompletion"
  | .pendingCancellation => Json.str "pendingCancellation"

def decodeAdmissionSignal (j : Json) : D AdmissionSignal := do
  let identity ← decodeRequestIdentity (← objVal j "identity")
  let handle ← decodeExecutionHandle (← objVal j "handle")
  let kind ← decodeSignalKind (← objVal j "kind")
  return ⟨identity, handle, kind⟩

def encodeAdmissionSignal (s : AdmissionSignal) : Json :=
  Json.mkObj [("identity", encodeRequestIdentity s.identity), ("handle", encodeExecutionHandle s.handle),
    ("kind", encodeSignalKind s.kind)]

def decodeAdmissionProvenance (j : Json) : D AdmissionProvenance := do
  let futureArr ← arrField j "futureUses"
  let futureUses ← futureArr.toList.mapM decodeRequestIdentity
  let signalsArr ← arrField j "outstandingSignals"
  let outstandingSignals ← signalsArr.toList.mapM decodeAdmissionSignal
  return ⟨futureUses, outstandingSignals⟩

def encodeAdmissionProvenance (p : AdmissionProvenance) : Json :=
  Json.mkObj [("futureUses", Json.arr (p.futureUses.map encodeRequestIdentity).toArray),
    ("outstandingSignals", Json.arr (p.outstandingSignals.map encodeAdmissionSignal).toArray)]

def decodeDynamicAdmissionState (j : Json) : D DynamicAdmissionState := do
  let progression ← decodeRequestProgressionSnapshot (← objVal j "progression")
  let configuredSafetyLimit ← decodeResourceBudget (← objVal j "configuredSafetyLimit")
  let provenance ← decodeAdmissionProvenance (← objVal j "provenance")
  return ⟨progression, configuredSafetyLimit, provenance⟩

def encodeDynamicAdmissionState (s : DynamicAdmissionState) : Json :=
  Json.mkObj [("progression", encodeRequestProgressionSnapshot s.progression),
    ("configuredSafetyLimit", encodeResourceBudget s.configuredSafetyLimit),
    ("provenance", encodeAdmissionProvenance s.provenance)]

def decodeDynamicAdmissionInput (j : Json) : D DynamicAdmissionInput := do
  let state ← decodeDynamicAdmissionState (← objVal j "state")
  let request ← decodeRequestInput (← objVal j "request")
  let environmentSpecification ← decodeEnvironmentSpecification (← objVal j "environmentSpecification")
  let capacityObservation ← decodeCapacityObservation (← objVal j "capacityObservation")
  let observedAt ← natField j "observedAt"
  let startJ ← objVal j "start"
  let start ←
    match startJ with
    | .null => pure none
    | _ => pure (some (← decodeCostSelection startJ))
  return ⟨state, request, environmentSpecification, capacityObservation, observedAt, start⟩

def encodeDynamicAdmissionFailure : DynamicAdmissionFailure → Json
  | .capacityObservationUnavailable age maxAge =>
      Json.mkObj [("tag", Json.str "capacityObservationUnavailable"), ("age", natToJson age),
        ("maxAge", natToJson maxAge)]
  | .resourceCoordinateMismatch configuredResource observedResource =>
      Json.mkObj [("tag", Json.str "resourceCoordinateMismatch"),
        ("configuredResource", Json.str configuredResource), ("observedResource", Json.str observedResource)]
  | .configuredSafetyLimitExceeded resource occupied allowed =>
      Json.mkObj [("tag", Json.str "configuredSafetyLimitExceeded"), ("resource", Json.str resource),
        ("occupied", natToJson occupied), ("allowed", natToJson allowed)]
  | .meaningDenied identity reason =>
      Json.mkObj [("tag", Json.str "meaningDenied"), ("identity", encodeRequestIdentity identity),
        ("reason", encodePermissionDenial reason)]
  | .permissionIdentityMismatch a b =>
      Json.mkObj [("tag", Json.str "permissionIdentityMismatch"), ("requestIdentity", encodeRequestIdentity a),
        ("permissionIdentity", encodeRequestIdentity b)]
  | .adapterBindingUnavailable identity =>
      Json.mkObj [("tag", Json.str "adapterBindingUnavailable"), ("identity", encodeRequestIdentity identity)]
  | .bindingSelectionMismatch identity =>
      Json.mkObj [("tag", Json.str "bindingSelectionMismatch"), ("identity", encodeRequestIdentity identity)]
  | .progressionSubmitFailure failure =>
      Json.mkObj [("tag", Json.str "progressionSubmitFailure"), ("failure", encodeSubmitFailure failure)]
  | .progressionStartFailure failure =>
      Json.mkObj [("tag", Json.str "progressionStartFailure"), ("failure", encodeStartDecisionFailure failure)]
  | .provenanceRetentionRequired identity =>
      Json.mkObj [("tag", Json.str "provenanceRetentionRequired"), ("identity", encodeRequestIdentity identity)]
  | .unknownRequest identity =>
      Json.mkObj [("tag", Json.str "unknownRequest"), ("identity", encodeRequestIdentity identity)]
  | .requestNotTerminal identity =>
      Json.mkObj [("tag", Json.str "requestNotTerminal"), ("identity", encodeRequestIdentity identity)]

def encodeAdmissionDecision : AdmissionDecision → Json
  | .submitted state accepted =>
      Json.mkObj [("tag", Json.str "submitted"), ("state", encodeDynamicAdmissionState state),
        ("accepted", encodeAccepted accepted)]
  | .started state result =>
      Json.mkObj [("tag", Json.str "started"), ("state", encodeDynamicAdmissionState state),
        ("result", encodeStartDecisionResult result)]
  | .coalesced state identity =>
      Json.mkObj [("tag", Json.str "coalesced"), ("state", encodeDynamicAdmissionState state),
        ("identity", encodeRequestIdentity identity)]

def encodeProvenanceErasureWitness : ProvenanceErasureWitness → Json
  | .erased identity => Json.mkObj [("tag", Json.str "erased"), ("identity", encodeRequestIdentity identity)]
  | .retained identity reason =>
      Json.mkObj [("tag", Json.str "retained"), ("identity", encodeRequestIdentity identity),
        ("reason", Json.str reason)]

def encodeCoalescingWitness : CoalescingWitness → Json
  | .coalesced identity => Json.mkObj [("tag", Json.str "coalesced"), ("identity", encodeRequestIdentity identity)]
  | .notCoalesced reason => Json.mkObj [("tag", Json.str "notCoalesced"), ("reason", Json.str reason)]

def encodeDynamicAdmissionResult (r : DynamicAdmissionResult) : Json :=
  Json.mkObj [("effectiveBudget", encodeResourceBudget r.effectiveBudget),
    ("admissionDecision", encodeAdmissionDecision r.admissionDecision),
    ("futureUseSet", Json.arr (r.futureUseSet.identities.map encodeRequestIdentity).toArray),
    ("outstandingSignalSet", Json.arr (r.outstandingSignalSet.signals.map encodeAdmissionSignal).toArray),
    ("provenanceErasureWitness",
      match r.provenanceErasureWitness with | none => Json.null | some w => encodeProvenanceErasureWitness w),
    ("coalescingWitness", encodeCoalescingWitness r.coalescingWitness)]

def encodeDynamicAdmissionOutcome :
    Outcome DynamicAdmissionResult DynamicAdmissionFailure Empty Empty → Json
  | .applied r => Json.mkObj [("tag", Json.str "applied"), ("value", encodeDynamicAdmissionResult r)]
  | .rejected f => Json.mkObj [("tag", Json.str "rejected"), ("failure", encodeDynamicAdmissionFailure f)]
  | .conflicted f => f.elim
  | .boundaryFailed f => f.elim

def encodeElisionOutcome :
    Outcome (DynamicAdmissionState × ProvenanceErasureWitness) DynamicAdmissionFailure Empty Empty → Json
  | .applied (state, witness) =>
      Json.mkObj [("tag", Json.str "applied"), ("state", encodeDynamicAdmissionState state),
        ("witness", encodeProvenanceErasureWitness witness)]
  | .rejected f => Json.mkObj [("tag", Json.str "rejected"), ("failure", encodeDynamicAdmissionFailure f)]
  | .conflicted f => f.elim
  | .boundaryFailed f => f.elim



def opDynamicAdmissionElideAdmissionProvenance (input : Json) : D Json := do
  let state ← decodeDynamicAdmissionState (← objVal input "state")
  let identity ← decodeRequestIdentity (← objVal input "identity")
  return encodeElisionOutcome (elideAdmissionProvenance state identity)

def opDynamicAdmissionAdmitDynamicRequest (input : Json) : D Json := do
  let admissionInput ← decodeDynamicAdmissionInput input
  return encodeDynamicAdmissionOutcome (admitDynamicRequest admissionInput)



def decodeNormalizedPath (j : Json) : D NormalizedPath := do
  let root ←
    match ← objVal j "root" with
    | .bool b => pure b
    | _ => throw (failShape "expected bool root")
  let segmentsArr ← arrField j "segments"
  let segments ← segmentsArr.toList.mapM asStr
  return ⟨root, segments⟩

def encodeNormalizedPath (p : NormalizedPath) : Json :=
  Json.mkObj [("root", Json.bool p.root), ("segments", Json.arr (p.segments.map Json.str).toArray)]

def decodeContentDigest (j : Json) : D ContentDigest := do
  let s ← asStr j
  return ⟨s⟩

def encodeContentDigest (d : ContentDigest) : Json := Json.str d.value

def decodeByte (j : Json) : D UInt8 := do
  let s ← asStr j
  let n ← natOfStr s
  if n < 256 then return UInt8.ofNat n
  else throw (failShape "byte out of range")

def encodeByte (b : UInt8) : Json := natToJson b.toBitVec.toNat

def decodeBytes (j : Json) : D (List UInt8) := do
  let arr ← asArr j
  arr.toList.mapM decodeByte

def encodeBytes (bs : List UInt8) : Json := Json.arr (bs.map encodeByte).toArray

def decodeFileRecord (j : Json) : D FileRecord := do
  let digest ← decodeContentDigest (← objVal j "digest")
  let bytes ← decodeBytes (← objVal j "bytes")
  return ⟨digest, bytes⟩

def encodeFileRecord (r : FileRecord) : Json :=
  Json.mkObj [("digest", encodeContentDigest r.digest), ("bytes", encodeBytes r.bytes)]

def decodeExternalFileState (j : Json) : D ExternalFileState := do
  let filesArr ← arrField j "files"
  let files ← filesArr.toList.mapM (fun e => do
    let path ← decodeNormalizedPath (← objVal e "path")
    let record ← decodeFileRecord (← objVal e "record")
    return (path, record))
  let readFailuresArr ← arrField j "readFailures"
  let readFailures ← readFailuresArr.toList.mapM decodeNormalizedPath
  let writeFailuresArr ← arrField j "writeFailures"
  let writeFailures ← writeFailuresArr.toList.mapM decodeNormalizedPath
  return ⟨files, readFailures, writeFailures⟩

def encodeExternalFileState (s : ExternalFileState) : Json :=
  Json.mkObj [("files", Json.arr (s.files.map (fun (path, record) =>
      Json.mkObj [("path", encodeNormalizedPath path), ("record", encodeFileRecord record)])).toArray),
    ("readFailures", Json.arr (s.readFailures.map encodeNormalizedPath).toArray),
    ("writeFailures", Json.arr (s.writeFailures.map encodeNormalizedPath).toArray)]

def decodeDigests (j : Json) : D Digests := do
  let arr ← asArr j
  let entries ← arr.toList.mapM (fun e => do
    let resource ← decodeResourceId (← objVal e "resource")
    let digest ← decodeContentDigest (← objVal e "digest")
    return (resource, digest))
  return ⟨entries⟩

def encodeDigests (d : Digests) : Json :=
  Json.arr (d.entries.map (fun (resource, digest) =>
    Json.mkObj [("resource", encodeResourceId resource), ("digest", encodeContentDigest digest)])).toArray

def encodeDigestLookup : DigestLookup → Json
  | .found d => Json.mkObj [("tag", Json.str "found"), ("digest", encodeContentDigest d)]
  | .unobserved u => Json.mkObj [("tag", Json.str "unobserved"), ("resource", encodeResourceId u.resource)]

def encodeObservation (encodePayload : α → Json) (o : Observation α) : Json :=
  Json.mkObj [("payload", encodePayload o.payload), ("basis", encodeBasis o.basis),
    ("observedAt", natToJson o.observedAt)]

def encodeFileSnapshot (s : FileSnapshot) : Json :=
  Json.mkObj [("path", encodeNormalizedPath s.path), ("contents", encodeBytes s.contents),
    ("digest", encodeContentDigest s.digest)]

def encodeTrackResult : TrackResult → Json
  | .applied t =>
      Json.mkObj [("tag", Json.str "applied"), ("observation", encodeObservation encodeRevision t.observation),
        ("world", encodeWorld t.world)]
  | .rejected f => f.elim
  | .conflicted f => f.elim
  | .boundaryFailed f => f.elim

def encodeReadResult : ReadResult → Json
  | .applied r =>
      Json.mkObj [("tag", Json.str "applied"),
        ("observation", encodeObservation encodeFileSnapshot r.observation),
        ("world", encodeWorld r.world), ("digests", encodeDigests r.digests)]
  | .rejected u => Json.mkObj [("tag", Json.str "rejected"), ("resource", encodeResourceId u.resource)]
  | .conflicted f => f.elim
  | .boundaryFailed f => Json.mkObj [("tag", Json.str "boundaryFailed"), ("path", encodeNormalizedPath f.path)]

def decodeReplaceContents (j : Json) : D ReplaceContents := do
  let newContents ← decodeBytes (← objVal j "newContents")
  let newDigest ← decodeContentDigest (← objVal j "newDigest")
  return ⟨newContents, newDigest⟩

def encodeReplaceRejection : ReplaceRejection → Json
  | .resourcePathMismatch m =>
      Json.mkObj [("tag", Json.str "resourcePathMismatch"), ("resource", encodeResourceId m.resource),
        ("path", encodeNormalizedPath m.path)]
  | .unknownResource u => Json.mkObj [("tag", Json.str "unknownResource"), ("resource", encodeResourceId u.resource)]
  | .unobservedContents u =>
      Json.mkObj [("tag", Json.str "unobservedContents"), ("resource", encodeResourceId u.resource)]

def encodeReplaceConflict : ReplaceConflict → Json
  | .staleBasis s =>
      Json.mkObj [("tag", Json.str "staleBasis"), ("expected", encodeRevision s.expected),
        ("actual", encodeRevision s.actual)]
  | .externalMutation m =>
      Json.mkObj [("tag", Json.str "externalMutation"), ("expected", encodeContentDigest m.expected),
        ("actual", encodeContentDigest m.actual)]

def encodeReplaceResult : ReplaceResult → Json
  | .applied r =>
      Json.mkObj [("tag", Json.str "applied"),
        ("observation", encodeObservation encodeFileSnapshot r.observation),
        ("world", encodeWorld r.world), ("digests", encodeDigests r.digests),
        ("state", encodeExternalFileState r.state)]
  | .rejected r => Json.mkObj [("tag", Json.str "rejected"), ("rejection", encodeReplaceRejection r)]
  | .conflicted c => Json.mkObj [("tag", Json.str "conflicted"), ("conflict", encodeReplaceConflict c)]
  | .boundaryFailed f => Json.mkObj [("tag", Json.str "boundaryFailed"), ("path", encodeNormalizedPath f.path)]



def opFileEffectNormalizePath (input : Json) : D Json := do
  let root ←
    match ← objVal input "root" with
    | .bool b => pure b
    | _ => throw (failShape "expected bool root")
  let rawArr ← arrField input "raw"
  let raw ← rawArr.toList.mapM asStr
  return encodeNormalizedPath (normalizePath root raw)

def opFileEffectLookupDigest (input : Json) : D Json := do
  let digests ← decodeDigests (← objVal input "digests")
  let resource ← decodeResourceId (← objVal input "resource")
  return encodeDigestLookup (lookupDigest digests resource)

def opFileEffectSetDigest (input : Json) : D Json := do
  let digests ← decodeDigests (← objVal input "digests")
  let resource ← decodeResourceId (← objVal input "resource")
  let digest ← decodeContentDigest (← objVal input "digest")
  return encodeDigests (setDigest digests resource digest)

def opFileEffectTrack (input : Json) : D Json := do
  let path ← decodeNormalizedPath (← objVal input "path")
  let world ← decodeWorld (← objVal input "world")
  let observedAt ← natField input "observedAt"
  return encodeTrackResult (track ⟨path, world, observedAt⟩)

def opFileEffectRead (input : Json) : D Json := do
  let path ← decodeNormalizedPath (← objVal input "path")
  let world ← decodeWorld (← objVal input "world")
  let digests ← decodeDigests (← objVal input "digests")
  let state ← decodeExternalFileState (← objVal input "state")
  let observedAt ← natField input "observedAt"
  return encodeReadResult (read ⟨path, world, digests, state, observedAt⟩)

def opFileEffectReplace (input : Json) : D Json := do
  let intent ← decodeReplaceContents (← objVal input "intent")
  let basis ← decodeBasis (← objVal input "basis")
  let command : Command ReplaceContents := ⟨intent, basis⟩
  let path ← decodeNormalizedPath (← objVal input "path")
  let world ← decodeWorld (← objVal input "world")
  let digests ← decodeDigests (← objVal input "digests")
  let state ← decodeExternalFileState (← objVal input "state")
  let observedAt ← natField input "observedAt"
  return encodeReplaceResult (replace ⟨command, path, world, digests, state, observedAt⟩)



def surfaceEntries : List (String × List String) :=
  [("core", ["lookup", "bump", "commandOf", "apply"]),
   ("call", ["immediateOf", "deferredOf", "io", "issue"]),
   ("iteration", ["fold", "recurse", "closure"]),
   ("store", ["storeOf", "storeEntries", "observe", "apply", "worldOf"]),
   ("record", ["recordOf", "recordOnBasis", "hasEdge"]),
   ("reconcile", ["reconcile", "coherent"]),
   ("request_progression",
     ["empty", "submit", "decideStart", "applyStartObservation", "applyCompletionObservation", "decideCancel",
      "derivePending", "deriveInFlight", "deriveConcurrent"]),
   ("dynamic_admission", ["elideAdmissionProvenance", "admitDynamicRequest"]),
   ("step_transition", ["step"]),
   ("file_effect", ["normalizePath", "lookupDigest", "setDigest", "track", "read", "replace"])]

def knownFeatures : List String := surfaceEntries.map Prod.fst

def knownOperations : List (String × String) :=
  surfaceEntries.flatMap (fun (feature, ops) => ops.map (fun op => (feature, op)))

def surfaceJson : Json :=
  Json.mkObj [("kind", Json.str "surface"),
    ("features", Json.arr (surfaceEntries.map (fun (feature, ops) =>
      Json.mkObj [("feature", Json.str feature),
        ("operations", Json.arr (ops.map Json.str).toArray)])).toArray)]



def dispatch (feature operation : String) (input : Json) : D Json :=
  match feature, operation with
  | "core", "lookup" => opCoreLookup input
  | "core", "bump" => opCoreBump input
  | "core", "commandOf" => opCoreCommandOf input
  | "core", "apply" => opCoreApply input
  | "call", "immediateOf" => opCallImmediateOf input
  | "call", "deferredOf" => opCallDeferredOf input
  | "call", "io" => opCallIo input
  | "call", "issue" => opCallIssue input
  | "iteration", "fold" => opIterationFold input
  | "iteration", "recurse" => opIterationRecurse input
  | "iteration", "closure" => opIterationClosure input
  | "store", "storeOf" => opStoreStoreOf input
  | "store", "storeEntries" => opStoreStoreEntries input
  | "store", "observe" => opStoreObserve input
  | "store", "apply" => opStoreApply input
  | "store", "worldOf" => opStoreWorldOf input
  | "record", "recordOf" => opRecordRecordOf input
  | "record", "recordOnBasis" => opRecordRecordOnBasis input
  | "record", "hasEdge" => opRecordHasEdge input
  | "reconcile", "reconcile" => opReconcileReconcile input
  | "reconcile", "coherent" => opReconcileCoherent input
  | "request_progression", "empty" => opRequestProgressionEmpty input
  | "request_progression", "submit" => opRequestProgressionSubmit input
  | "request_progression", "decideStart" => opRequestProgressionDecideStart input
  | "request_progression", "applyStartObservation" => opRequestProgressionApplyStartObservation input
  | "request_progression", "applyCompletionObservation" => opRequestProgressionApplyCompletionObservation input
  | "request_progression", "decideCancel" => opRequestProgressionDecideCancel input
  | "request_progression", "derivePending" => opRequestProgressionDerivePending input
  | "request_progression", "deriveInFlight" => opRequestProgressionDeriveInFlight input
  | "request_progression", "deriveConcurrent" => opRequestProgressionDeriveConcurrent input
  | "dynamic_admission", "elideAdmissionProvenance" => opDynamicAdmissionElideAdmissionProvenance input
  | "dynamic_admission", "admitDynamicRequest" => opDynamicAdmissionAdmitDynamicRequest input
  | "step_transition", "step" => opStepTransitionStep input
  | "file_effect", "normalizePath" => opFileEffectNormalizePath input
  | "file_effect", "lookupDigest" => opFileEffectLookupDigest input
  | "file_effect", "setDigest" => opFileEffectSetDigest input
  | "file_effect", "track" => opFileEffectTrack input
  | "file_effect", "read" => opFileEffectRead input
  | "file_effect", "replace" => opFileEffectReplace input
  | _, _ =>
      if knownFeatures.contains feature then
        throw ⟨.unknownOperation, s!"{feature}.{operation}"⟩
      else
        throw ⟨.unknownFeature, feature⟩

def processRequest (j : Json) : D Json := do
  let feature ← strField j "feature"
  let operation ← strField j "operation"
  let input ← objVal j "input"
  let result ← dispatch feature operation input
  return Json.mkObj [("feature", Json.str feature), ("operation", Json.str operation), ("result", result)]



def topKind (j : Json) : D String :=
  match j.getObjVal? "kind" with
  | .ok (.str s) => .ok s
  | _ => .error ⟨.queryShape, "missing or invalid top-level kind"⟩

def decodeQuery (j : Json) : D Json := do
  let kind ← topKind j
  match kind with
  | "surface" => return surfaceJson
  | "evaluate" =>
      let reqsJson ←
        match j.getObjVal? "requests" with
        | .ok (.arr a) => pure a
        | _ => throw ⟨.queryShape, "missing or invalid requests array"⟩
      let results ← reqsJson.toList.mapM processRequest
      return Json.mkObj [("kind", Json.str "results"), ("results", Json.arr results.toArray)]
  | other => throw ⟨.queryShape, s!"unknown query kind {other}"⟩

def renderInvalid (f : DecodeFailure) : Json :=
  Json.mkObj [("kind", Json.str "invalid"),
    ("failure", Json.mkObj [("kind", Json.str (failureKindStr f.kind)), ("detail", Json.str f.detail)])]

end FeatureCheck

def main : IO Unit := do
  let stdin ← IO.getStdin
  let content ← stdin.readToEnd
  let outJson : Lean.Json :=
    match Lean.Json.parse content with
    | .error msg => FeatureCheck.renderInvalid ⟨.jsonSyntax, msg⟩
    | .ok j =>
        match FeatureCheck.decodeQuery j with
        | .ok result => result
        | .error f => FeatureCheck.renderInvalid f
  IO.println outJson.compress
