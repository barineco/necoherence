-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean.Data.Json
import Necoherence.NetworkEffect

namespace Necoherence

open Lean



private abbrev DecodeM := Except String

private def obj (fields : List (String × Json)) : Json := Json.mkObj fields
private def natJson (value : Nat) : Json := .num (JsonNumber.fromNat value)
private def arrJson (values : List Json) : Json := .arr values.toArray
private def optJson (encode : α → Json) : Option α → Json
  | none => .null
  | some value => encode value

private def field (value : Json) (name : String) : DecodeM Json := do
  try value.getObjVal? name
  catch error => throw s!"{name}: {error}"

private def stringField (value : Json) (name : String) : DecodeM String := do
  let encoded ← field value name
  try encoded.getStr?
  catch error => throw s!"{name}: {error}"

private def natField (value : Json) (name : String) : DecodeM Nat := do
  let encoded ← field value name
  try encoded.getNat?
  catch error => throw s!"{name}: {error}"

private def arrayField (value : Json) (name : String) : DecodeM (Array Json) := do
  let encoded ← field value name
  try encoded.getArr?
  catch error => throw s!"{name}: {error}"

private def decodeArray (decode : Json → DecodeM α) (value : Json) : DecodeM (List α) := do
  let values ← value.getArr?
  values.toList.mapM decode

private def decodeArrayField (decode : Json → DecodeM α) (value : Json) (name : String) : DecodeM (List α) := do
  decodeArray decode (← field value name)

private def decodeOption (decode : Json → DecodeM α) : Json → DecodeM (Option α)
  | .null => pure none
  | value => return some (← decode value)

private def decodeOptionField (decode : Json → DecodeM α) (value : Json) (name : String) : DecodeM (Option α) := do
  decodeOption decode (← field value name)

private def unknownTag (typeName tag : String) : DecodeM α :=
  throw s!"{typeName}.tag: unknown value {tag}"

private def encodeRequestIdentity (value : RequestIdentity) : Json :=
  obj [("kind", .str value.kind), ("provenance", .str value.provenance), ("revision", natJson value.revision)]

private def decodeRequestIdentity (value : Json) : DecodeM RequestIdentity := do
  let kind ← stringField value "kind"
  let provenance ← stringField value "provenance"
  let revision ← natField value "revision"
  pure { kind, provenance, revision }

private def encodeExecutionHandle (value : ExecutionHandle) : Json := obj [("value", .str value.value)]
private def decodeExecutionHandle (value : Json) : DecodeM ExecutionHandle :=
  return { value := (← stringField value "value") }

private def encodeOpaqueEvidence (value : OpaqueEvidence) : Json := obj [("value", .str value.value)]
private def decodeOpaqueEvidence (value : Json) : DecodeM OpaqueEvidence :=
  return { value := (← stringField value "value") }

private def encodeClockBasis (value : ClockBasis) : Json := obj [("value", .str value.value)]
private def decodeClockBasis (value : Json) : DecodeM ClockBasis :=
  return { value := (← stringField value "value") }

private def encodeRawHeaderField (value : RawHeaderField) : Json :=
  obj [("name", .str value.name), ("value", arrJson (value.value.map natJson))]

private def decodeRawHeaderField (value : Json) : DecodeM RawHeaderField := do
  let name ← stringField value "name"
  let bytes ← decodeArrayField (fun item => item.getNat?) value "value"
  pure { name, value := bytes }

private def encodeInstruction (value : HttpWireInstruction) : Json :=
  obj [("method", .str value.method), ("target", .str value.target),
    ("headers", arrJson (value.headers.map encodeRawHeaderField)),
    ("body", arrJson (value.body.map natJson))]

private def decodeInstruction (value : Json) : DecodeM HttpWireInstruction := do
  let method ← stringField value "method"
  let target ← stringField value "target"
  let headers ← decodeArrayField decodeRawHeaderField value "headers"
  let body ← decodeArrayField (fun item => item.getNat?) value "body"
  pure { method, target, headers, body }

private def encodeRawResponse (value : RawHttpResponse) : Json :=
  obj [("status", natJson value.status), ("headers", arrJson (value.headers.map encodeRawHeaderField)),
    ("body", arrJson (value.body.map natJson))]

private def decodeRawResponse (value : Json) : DecodeM RawHttpResponse := do
  let status ← natField value "status"
  let headers ← decodeArrayField decodeRawHeaderField value "headers"
  let body ← decodeArrayField (fun item => item.getNat?) value "body"
  pure { status, headers, body }

private def encodeHeaderProvenance : HeaderProvenance → Json
  | .WireObserved => obj [("tag", .str "WireObserved")]
  | .LibraryObserved => obj [("tag", .str "LibraryObserved")]
  | .LibraryNormalized => obj [("tag", .str "LibraryNormalized")]

private def decodeHeaderProvenance (value : Json) : DecodeM HeaderProvenance := do
  match ← stringField value "tag" with
  | "WireObserved" => pure .WireObserved
  | "LibraryObserved" => pure .LibraryObserved
  | "LibraryNormalized" => pure .LibraryNormalized
  | tag => unknownTag "HeaderProvenance" tag

private def encodeAttemptIdentity (value : AttemptIdentity) : Json :=
  obj [("logical", encodeRequestIdentity value.logical), ("ordinal", natJson value.ordinal)]

private def decodeAttemptIdentity (value : Json) : DecodeM AttemptIdentity := do
  let logical ← decodeRequestIdentity (← field value "logical")
  let ordinal ← natField value "ordinal"
  pure { logical, ordinal }

private def encodeClockObservation (value : MonotonicClockObservation) : Json :=
  obj [("clockBasis", encodeClockBasis value.clockBasis), ("value", natJson value.value)]

private def decodeClockObservation (value : Json) : DecodeM MonotonicClockObservation := do
  let clockBasis ← decodeClockBasis (← field value "clockBasis")
  let observedValue ← natField value "value"
  pure { clockBasis, value := observedValue }

private def encodeClockCapability (value : MonotonicClockCapability) : Json :=
  obj [("identity", encodeOpaqueEvidence value.identity), ("clockBasis", encodeClockBasis value.clockBasis)]

private def decodeClockCapability (value : Json) : DecodeM MonotonicClockCapability := do
  let identity ← decodeOpaqueEvidence (← field value "identity")
  let clockBasis ← decodeClockBasis (← field value "clockBasis")
  pure { identity, clockBasis }

private def encodeCancellationCapability (value : CancellationCapability) : Json :=
  obj [("identity", encodeOpaqueEvidence value.identity)]

private def decodeCancellationCapability (value : Json) : DecodeM CancellationCapability :=
  return { identity := (← decodeOpaqueEvidence (← field value "identity")) }

private def encodeDeadline (value : Deadline) : Json :=
  obj [("clockBasis", encodeClockBasis value.clockBasis), ("limit", natJson value.limit),
    ("capability", encodeClockCapability value.capability)]

private def decodeDeadline (value : Json) : DecodeM Deadline := do
  let clockBasis ← decodeClockBasis (← field value "clockBasis")
  let limit ← natField value "limit"
  let capability ← decodeClockCapability (← field value "capability")
  pure { clockBasis, limit, capability }

private def encodeConfiguration (value : HostConfiguration) : Json :=
  obj [("requestBodyLimit", natJson value.requestBodyLimit),
    ("responseBodyLimit", natJson value.responseBodyLimit),
    ("cancellation", optJson encodeCancellationCapability value.cancellation),
    ("monotonicClock", optJson encodeClockCapability value.monotonicClock)]

private def decodeConfiguration (value : Json) : DecodeM HostConfiguration := do
  let requestBodyLimit ← natField value "requestBodyLimit"
  let responseBodyLimit ← natField value "responseBodyLimit"
  let cancellation ← decodeOptionField decodeCancellationCapability value "cancellation"
  let monotonicClock ← decodeOptionField decodeClockCapability value "monotonicClock"
  pure { requestBodyLimit, responseBodyLimit, cancellation, monotonicClock }

private def encodeAttemptInput (value : AttemptInput) : Json :=
  obj [("attempt", encodeAttemptIdentity value.attempt), ("instruction", encodeInstruction value.instruction),
    ("deadline", optJson encodeDeadline value.deadline), ("configuration", encodeConfiguration value.configuration)]

private def decodeAttemptInput (value : Json) : DecodeM AttemptInput := do
  let attempt ← decodeAttemptIdentity (← field value "attempt")
  let instruction ← decodeInstruction (← field value "instruction")
  let deadline ← decodeOptionField decodeDeadline value "deadline"
  let configuration ← decodeConfiguration (← field value "configuration")
  pure { attempt, instruction, deadline, configuration }

private def encodeRetryAuthorization (value : RetryAuthorization) : Json :=
  obj [("logical", encodeRequestIdentity value.logical), ("from", encodeAttemptIdentity value.«from»),
    ("next", encodeAttemptIdentity value.next), ("protocolEvidence", encodeOpaqueEvidence value.protocolEvidence)]

private def decodeRetryAuthorization (value : Json) : DecodeM RetryAuthorization := do
  let logical ← decodeRequestIdentity (← field value "logical")
  let parent ← decodeAttemptIdentity (← field value "from")
  let next ← decodeAttemptIdentity (← field value "next")
  let protocolEvidence ← decodeOpaqueEvidence (← field value "protocolEvidence")
  pure { logical, «from» := parent, next, protocolEvidence }

private def encodeLineage : AttemptLineage → Json
  | .Root => obj [("tag", .str "Root")]
  | .RetryOf authorization => obj [("tag", .str "RetryOf"), ("authorization", encodeRetryAuthorization authorization)]

private def decodeLineage (value : Json) : DecodeM AttemptLineage := do
  match ← stringField value "tag" with
  | "Root" => pure .Root
  | "RetryOf" => return .RetryOf (← decodeRetryAuthorization (← field value "authorization"))
  | tag => unknownTag "AttemptLineage" tag

private def encodePrepared (value : PreparedAttempt) : Json :=
  obj [("input", encodeAttemptInput value.input), ("lineage", encodeLineage value.lineage)]

private def decodePrepared (value : Json) : DecodeM PreparedAttempt := do
  let input ← decodeAttemptInput (← field value "input")
  let lineage ← decodeLineage (← field value "lineage")
  pure { input, lineage }

private def encodeStarted (value : StartedAttempt) : Json :=
  obj [("prepared", encodePrepared value.prepared), ("handle", encodeExecutionHandle value.handle)]

private def decodeStarted (value : Json) : DecodeM StartedAttempt := do
  let prepared ← decodePrepared (← field value "prepared")
  let handle ← decodeExecutionHandle (← field value "handle")
  pure { prepared, handle }

private def encodeEffectWitnessSource : EffectWitnessSource → Json
  | .Adapter => obj [("tag", .str "Adapter")]
  | .Protocol => obj [("tag", .str "Protocol")]

private def decodeEffectWitnessSource (value : Json) : DecodeM EffectWitnessSource := do
  match ← stringField value "tag" with
  | "Adapter" => pure .Adapter
  | "Protocol" => pure .Protocol
  | tag => unknownTag "EffectWitnessSource" tag

private def encodeEffectWitness (value : EffectWitness) : Json :=
  obj [("attempt", encodeAttemptIdentity value.attempt), ("source", encodeEffectWitnessSource value.source),
    ("evidence", encodeOpaqueEvidence value.evidence)]

private def decodeEffectWitness (value : Json) : DecodeM EffectWitness := do
  let attempt ← decodeAttemptIdentity (← field value "attempt")
  let source ← decodeEffectWitnessSource (← field value "source")
  let evidence ← decodeOpaqueEvidence (← field value "evidence")
  pure { attempt, source, evidence }

private def unknownReasonName : UnknownEffectReason → String
  | .NoResponse => "NoResponse" | .Cancellation => "Cancellation" | .Deadline => "Deadline"
  | .HostFailure => "HostFailure" | .ProtocolWitnessMissing => "ProtocolWitnessMissing" | .LateSignal => "LateSignal"

private def decodeUnknownReason (value : Json) : DecodeM UnknownEffectReason := do
  match ← stringField value "tag" with
  | "NoResponse" => pure .NoResponse | "Cancellation" => pure .Cancellation | "Deadline" => pure .Deadline
  | "HostFailure" => pure .HostFailure | "ProtocolWitnessMissing" => pure .ProtocolWitnessMissing
  | "LateSignal" => pure .LateSignal | tag => unknownTag "UnknownEffectReason" tag

private def encodeEffectStatus : EffectStatus → Json
  | .Unknown reason => obj [("tag", .str "Unknown"), ("reason", obj [("tag", .str (unknownReasonName reason))])]
  | .NoEffect witness => obj [("tag", .str "NoEffect"), ("witness", encodeEffectWitness witness)]
  | .EffectOccurred witness => obj [("tag", .str "EffectOccurred"), ("witness", encodeEffectWitness witness)]

private def decodeEffectStatus (value : Json) : DecodeM EffectStatus := do
  match ← stringField value "tag" with
  | "Unknown" => return .Unknown (← decodeUnknownReason (← field value "reason"))
  | "NoEffect" => return .NoEffect (← decodeEffectWitness (← field value "witness"))
  | "EffectOccurred" => return .EffectOccurred (← decodeEffectWitness (← field value "witness"))
  | tag => unknownTag "EffectStatus" tag

private def encodeEffectObservation (value : EffectObservation) : Json :=
  obj [("attempt", encodeAttemptIdentity value.attempt), ("status", encodeEffectStatus value.status)]

private def decodeEffectObservation (value : Json) : DecodeM EffectObservation := do
  let attempt ← decodeAttemptIdentity (← field value "attempt")
  let status ← decodeEffectStatus (← field value "status")
  pure { attempt, status }

private def hostStageName : HostStage → String
  | .Start => "Start" | .RequestWrite => "RequestWrite" | .ResponseHeaders => "ResponseHeaders"
  | .ResponseBody => "ResponseBody" | .Cancel => "Cancel" | .Deadline => "Deadline"

private def decodeHostStage (value : Json) : DecodeM HostStage := do
  match ← stringField value "tag" with
  | "Start" => pure .Start | "RequestWrite" => pure .RequestWrite | "ResponseHeaders" => pure .ResponseHeaders
  | "ResponseBody" => pure .ResponseBody | "Cancel" => pure .Cancel | "Deadline" => pure .Deadline
  | tag => unknownTag "HostStage" tag

private def timeoutCauseName : HostTimeoutCause → String
  | .LibraryReported => "LibraryReported" | .SocketReported => "SocketReported"
  | .PoolAcquisition => "PoolAcquisition" | .HostOperation => "HostOperation"

private def decodeTimeoutCause (value : Json) : DecodeM HostTimeoutCause := do
  match ← stringField value "tag" with
  | "LibraryReported" => pure .LibraryReported | "SocketReported" => pure .SocketReported
  | "PoolAcquisition" => pure .PoolAcquisition | "HostOperation" => pure .HostOperation
  | tag => unknownTag "HostTimeoutCause" tag

private def simpleHostFailureName : HostFailure → Option String
  | .UnsupportedUriScheme => some "UnsupportedUriScheme" | .InvalidHostConfiguration => some "InvalidHostConfiguration"
  | .ExecutionStartFailed => some "ExecutionStartFailed" | .NameResolutionFailed => some "NameResolutionFailed"
  | .ConnectionFailed => some "ConnectionFailed" | .RequestWriteFailed => some "RequestWriteFailed"
  | .ResponseHeadersFailed => some "ResponseHeadersFailed" | .ResponseBodyFailed => some "ResponseBodyFailed"
  | .ResponseBodyLimitExceeded => some "ResponseBodyLimitExceeded" | .MalformedResponse => some "MalformedResponse"
  | .HeaderRepresentationUnavailable => some "HeaderRepresentationUnavailable"
  | .RequestHeaderEncodingUnavailable => some "RequestHeaderEncodingUnavailable"
  | .CancellationRejected => some "CancellationRejected" | .DeadlineControlUnavailable => some "DeadlineControlUnavailable"
  | .HostRuntimeFailure => some "HostRuntimeFailure" | .HostClosed => some "HostClosed" | .Timeout _ _ => none

private def encodeHostFailure (value : HostFailure) : Json :=
  match value with
  | .Timeout stage cause => obj [("tag", .str "Timeout"), ("stage", obj [("tag", .str (hostStageName stage))]),
      ("cause", obj [("tag", .str (timeoutCauseName cause))])]
  | other => obj [("tag", .str ((simpleHostFailureName other).getD "HostRuntimeFailure"))]

private def decodeHostFailure (value : Json) : DecodeM HostFailure := do
  match ← stringField value "tag" with
  | "UnsupportedUriScheme" => pure .UnsupportedUriScheme | "InvalidHostConfiguration" => pure .InvalidHostConfiguration
  | "ExecutionStartFailed" => pure .ExecutionStartFailed | "NameResolutionFailed" => pure .NameResolutionFailed
  | "ConnectionFailed" => pure .ConnectionFailed | "RequestWriteFailed" => pure .RequestWriteFailed
  | "ResponseHeadersFailed" => pure .ResponseHeadersFailed | "ResponseBodyFailed" => pure .ResponseBodyFailed
  | "ResponseBodyLimitExceeded" => pure .ResponseBodyLimitExceeded | "MalformedResponse" => pure .MalformedResponse
  | "HeaderRepresentationUnavailable" => pure .HeaderRepresentationUnavailable
  | "RequestHeaderEncodingUnavailable" => pure .RequestHeaderEncodingUnavailable
  | "CancellationRejected" => pure .CancellationRejected | "DeadlineControlUnavailable" => pure .DeadlineControlUnavailable
  | "HostRuntimeFailure" => pure .HostRuntimeFailure | "HostClosed" => pure .HostClosed
  | "Timeout" => return .Timeout (← decodeHostStage (← field value "stage")) (← decodeTimeoutCause (← field value "cause"))
  | tag => unknownTag "HostFailure" tag

private def encodeNetworkHostFailure (value : NetworkHostFailure) : Json :=
  obj [("attempt", encodeAttemptIdentity value.attempt), ("stage", obj [("tag", .str (hostStageName value.stage))]),
    ("configuration", encodeConfiguration value.configuration), ("cause", encodeHostFailure value.cause)]

private def decodeNetworkHostFailure (value : Json) : DecodeM NetworkHostFailure := do
  let attempt ← decodeAttemptIdentity (← field value "attempt")
  let stage ← decodeHostStage (← field value "stage")
  let configuration ← decodeConfiguration (← field value "configuration")
  let cause ← decodeHostFailure (← field value "cause")
  pure { attempt, stage, configuration, cause }

private def encodeOutcome : NetworkOutcome → Json
  | .Response response provenance => obj [("tag", .str "Response"), ("response", encodeRawResponse response),
      ("provenance", encodeHeaderProvenance provenance)]
  | .Failed failure => obj [("tag", .str "Failed"), ("failure", encodeNetworkHostFailure failure)]
  | .Cancelled => obj [("tag", .str "Cancelled")]
  | .DeadlineExceeded deadline observedAt => obj [("tag", .str "DeadlineExceeded"), ("deadline", encodeDeadline deadline),
      ("observedAt", encodeClockObservation observedAt)]

private def decodeOutcome (value : Json) : DecodeM NetworkOutcome := do
  match ← stringField value "tag" with
  | "Response" =>
      let response ← decodeRawResponse (← field value "response")
      let provenance ← decodeHeaderProvenance (← field value "provenance")
      pure (.Response response provenance)
  | "Failed" => return .Failed (← decodeNetworkHostFailure (← field value "failure"))
  | "Cancelled" => pure .Cancelled
  | "DeadlineExceeded" =>
      let deadline ← decodeDeadline (← field value "deadline")
      let observedAt ← decodeClockObservation (← field value "observedAt")
      pure (.DeadlineExceeded deadline observedAt)
  | tag => unknownTag "NetworkOutcome" tag

private def encodeTerminal (value : NetworkTerminal) : Json :=
  obj [("outcome", encodeOutcome value.outcome), ("effect", encodeEffectStatus value.effect)]

private def decodeTerminal (value : Json) : DecodeM NetworkTerminal := do
  let outcome ← decodeOutcome (← field value "outcome")
  let effect ← decodeEffectStatus (← field value "effect")
  pure { outcome, effect }

private def encodeSourceSequence : SourceSequence → Json
  | .none => .null | .some value => natJson value

private def decodeSourceSequence : Json → DecodeM SourceSequence
  | .null => pure .none
  | value => return .some (← value.getNat?)

private def encodeAdapterObservation : AdapterObservation → Json
  | .ResponseObservation attempt handle source response provenance effect =>
      obj [("tag", .str "ResponseObservation"), ("attempt", encodeAttemptIdentity attempt),
        ("handle", encodeExecutionHandle handle), ("sourceSequence", encodeSourceSequence source),
        ("response", encodeRawResponse response), ("provenance", encodeHeaderProvenance provenance),
        ("effect", encodeEffectStatus effect)]
  | .FailureObservation attempt handle source failure effect =>
      obj [("tag", .str "FailureObservation"), ("attempt", encodeAttemptIdentity attempt),
        ("handle", encodeExecutionHandle handle), ("sourceSequence", encodeSourceSequence source),
        ("failure", encodeNetworkHostFailure failure), ("effect", encodeEffectStatus effect)]
  | .CancellationObservation attempt handle source effect =>
      obj [("tag", .str "CancellationObservation"), ("attempt", encodeAttemptIdentity attempt),
        ("handle", encodeExecutionHandle handle), ("sourceSequence", encodeSourceSequence source),
        ("effect", encodeEffectStatus effect)]
  | .DeadlineObservation attempt handle source deadline observedAt effect =>
      obj [("tag", .str "DeadlineObservation"), ("attempt", encodeAttemptIdentity attempt),
        ("handle", encodeExecutionHandle handle), ("sourceSequence", encodeSourceSequence source),
        ("deadline", encodeDeadline deadline), ("observedAt", encodeClockObservation observedAt),
        ("effect", encodeEffectStatus effect)]

private def decodeAdapterObservation (value : Json) : DecodeM AdapterObservation := do
  let tag ← stringField value "tag"
  let attempt ← decodeAttemptIdentity (← field value "attempt")
  let handle ← decodeExecutionHandle (← field value "handle")
  let source ← decodeSourceSequence (← field value "sourceSequence")
  match tag with
  | "ResponseObservation" =>
      let response ← decodeRawResponse (← field value "response")
      let provenance ← decodeHeaderProvenance (← field value "provenance")
      let effect ← decodeEffectStatus (← field value "effect")
      pure (.ResponseObservation attempt handle source response provenance effect)
  | "FailureObservation" =>
      let failure ← decodeNetworkHostFailure (← field value "failure")
      let effect ← decodeEffectStatus (← field value "effect")
      pure (.FailureObservation attempt handle source failure effect)
  | "CancellationObservation" =>
      return .CancellationObservation attempt handle source (← decodeEffectStatus (← field value "effect"))
  | "DeadlineObservation" =>
      let deadline ← decodeDeadline (← field value "deadline")
      let observedAt ← decodeClockObservation (← field value "observedAt")
      let effect ← decodeEffectStatus (← field value "effect")
      pure (.DeadlineObservation attempt handle source deadline observedAt effect)
  | other => unknownTag "AdapterObservation" other

private def encodeDelivered (value : DeliveredObservation) : Json :=
  obj [("delivery", natJson value.delivery), ("observation", encodeAdapterObservation value.observation)]

private def decodeDelivered (value : Json) : DecodeM DeliveredObservation := do
  let delivery ← natField value "delivery"
  let observation ← decodeAdapterObservation (← field value "observation")
  pure { delivery, observation }

private def encodeLate (value : LateObservation) : Json := obj [("delivered", encodeDelivered value.delivered)]
private def decodeLate (value : Json) : DecodeM LateObservation :=
  return { delivered := (← decodeDelivered (← field value "delivered")) }

private def encodeDisposition : AttemptDisposition → Json
  | .Prepared => obj [("tag", .str "Prepared")]
  | .CommandIssued => obj [("tag", .str "CommandIssued")]
  | .Started handle => obj [("tag", .str "Started"), ("handle", encodeExecutionHandle handle)]
  | .Settled handle terminal => obj [("tag", .str "Settled"),
      ("handle", optJson encodeExecutionHandle handle), ("terminal", encodeTerminal terminal)]

private def decodeDisposition (value : Json) : DecodeM AttemptDisposition := do
  match ← stringField value "tag" with
  | "Prepared" => pure AttemptDisposition.Prepared
  | "CommandIssued" => pure AttemptDisposition.CommandIssued
  | "Started" => return AttemptDisposition.Started (← decodeExecutionHandle (← field value "handle"))
  | "Settled" =>
      let handle ← decodeOptionField decodeExecutionHandle value "handle"
      let terminal ← decodeTerminal (← field value "terminal")
      pure (.Settled handle terminal)
  | tag => unknownTag "AttemptDisposition" tag

private def encodeAttemptRecord (value : AttemptRecord) : Json :=
  obj [("input", encodeAttemptInput value.input), ("lineage", encodeLineage value.lineage),
    ("disposition", encodeDisposition value.disposition),
    ("firstDelivery", optJson encodeDelivered value.firstDelivery),
    ("late", arrJson (value.late.map encodeLate))]

private def decodeAttemptRecord (value : Json) : DecodeM AttemptRecord := do
  let input ← decodeAttemptInput (← field value "input")
  let lineage ← decodeLineage (← field value "lineage")
  let disposition ← decodeDisposition (← field value "disposition")
  let firstDelivery ← decodeOptionField decodeDelivered value "firstDelivery"
  let late ← decodeArrayField decodeLate value "late"
  pure { input, lineage, disposition, firstDelivery, late }

private def encodeState (value : NetworkState) : Json :=
  obj [("attempts", arrJson (value.attempts.map encodeAttemptRecord))]

private def decodeState (value : Json) : DecodeM NetworkState :=
  return { attempts := (← decodeArrayField decodeAttemptRecord value "attempts") }

private def encodeRetryPermission : RetryPermission → Json
  | .RetryAllowed authorization => obj [("tag", .str "RetryAllowed"), ("authorization", encodeRetryAuthorization authorization)]
  | .RetryDenied logical parent evidence => obj [("tag", .str "RetryDenied"),
      ("logical", encodeRequestIdentity logical), ("parent", encodeAttemptIdentity parent),
      ("evidence", encodeOpaqueEvidence evidence)]

private def decodeRetryPermission (value : Json) : DecodeM RetryPermission := do
  match ← stringField value "tag" with
  | "RetryAllowed" => return .RetryAllowed (← decodeRetryAuthorization (← field value "authorization"))
  | "RetryDenied" =>
      let logical ← decodeRequestIdentity (← field value "logical")
      let parent ← decodeAttemptIdentity (← field value "parent")
      let evidence ← decodeOpaqueEvidence (← field value "evidence")
      pure (.RetryDenied logical parent evidence)
  | tag => unknownTag "RetryPermission" tag

private def encodeRetryRequest (value : RetryRequest) : Json :=
  obj [("permission", encodeRetryPermission value.permission), ("instruction", encodeInstruction value.instruction),
    ("deadline", optJson encodeDeadline value.deadline), ("configuration", encodeConfiguration value.configuration)]

private def decodeRetryRequest (value : Json) : DecodeM RetryRequest := do
  let permission ← decodeRetryPermission (← field value "permission")
  let instruction ← decodeInstruction (← field value "instruction")
  let deadline ← decodeOptionField decodeDeadline value "deadline"
  let configuration ← decodeConfiguration (← field value "configuration")
  pure { permission, instruction, deadline, configuration }

private def encodeStartObservation : StartObservation → Json
  | .Started attempt handle => obj [("tag", .str "Started"), ("attempt", encodeAttemptIdentity attempt),
      ("handle", encodeExecutionHandle handle)]
  | .StartFailed failure effect => obj [("tag", .str "StartFailed"),
      ("failure", encodeNetworkHostFailure failure), ("effect", encodeEffectStatus effect)]

private def decodeStartObservation (value : Json) : DecodeM StartObservation := do
  match ← stringField value "tag" with
  | "Started" =>
      let attempt ← decodeAttemptIdentity (← field value "attempt")
      let handle ← decodeExecutionHandle (← field value "handle")
      pure (.Started attempt handle)
  | "StartFailed" =>
      let failure ← decodeNetworkHostFailure (← field value "failure")
      let effect ← decodeEffectStatus (← field value "effect")
      pure (.StartFailed failure effect)
  | tag => unknownTag "StartObservation" tag

private def encodeHostObservation : HostObservation → Json
  | .Pending attempt handle => obj [("tag", .str "Pending"), ("attempt", encodeAttemptIdentity attempt),
      ("handle", encodeExecutionHandle handle)]
  | .Delivered delivery observation => obj [("tag", .str "Delivered"), ("delivery", natJson delivery),
      ("observation", encodeAdapterObservation observation)]

private def decodeHostObservation (value : Json) : DecodeM HostObservation := do
  match ← stringField value "tag" with
  | "Pending" =>
      let attempt ← decodeAttemptIdentity (← field value "attempt")
      let handle ← decodeExecutionHandle (← field value "handle")
      pure (.Pending attempt handle)
  | "Delivered" =>
      let delivery ← natField value "delivery"
      let observation ← decodeAdapterObservation (← field value "observation")
      pure (.Delivered delivery observation)
  | tag => unknownTag "HostObservation" tag

private def encodeSettled (value : SettledAttempt) : Json :=
  obj [("prepared", encodePrepared value.prepared), ("handle", optJson encodeExecutionHandle value.handle),
    ("terminal", encodeTerminal value.terminal)]

private def encodeStateViolation : NetworkStateViolation → Json
  | .DuplicateAttemptKey attempt => obj [("tag", .str "DuplicateAttemptKey"), ("attempt", encodeAttemptIdentity attempt)]
  | .NonRootFirstAttempt attempt => obj [("tag", .str "NonRootFirstAttempt"), ("attempt", encodeAttemptIdentity attempt)]
  | .OrdinalGap attempt => obj [("tag", .str "OrdinalGap"), ("attempt", encodeAttemptIdentity attempt)]
  | .LineageMismatch attempt => obj [("tag", .str "LineageMismatch"), ("attempt", encodeAttemptIdentity attempt)]
  | .RetryAuthorizationReuse authorization => obj [("tag", .str "RetryAuthorizationReuse"),
      ("authorization", encodeRetryAuthorization authorization)]
  | .DispositionEvidenceMismatch attempt => obj [("tag", .str "DispositionEvidenceMismatch"), ("attempt", encodeAttemptIdentity attempt)]
  | .DeliveryLogMismatch attempt => obj [("tag", .str "DeliveryLogMismatch"), ("attempt", encodeAttemptIdentity attempt)]

private def attemptConditionName : AttemptCondition → String
  | .IsPrepared => "IsPrepared" | .IsCommandIssued => "IsCommandIssued" | .IsStarted => "IsStarted" | .IsSettled => "IsSettled"
private def tokenFieldName : AttemptTokenField → String
  | .Instruction => "Instruction" | .Deadline => "Deadline" | .Configuration => "Configuration"
  | .Lineage => "Lineage" | .Handle => "Handle"
private def observationFieldName : ObservationField → String
  | .FailureConfiguration => "FailureConfiguration" | .FailureStage => "FailureStage" | .DeadlineValue => "DeadlineValue"
  | .ClockBasisValue => "ClockBasisValue" | .ClockObservationValue => "ClockObservationValue"
  | .EffectWitnessValue => "EffectWitnessValue"
private def capabilityName : CapabilityKind → String
  | .Cancellation => "Cancellation" | .MonotonicClock => "MonotonicClock"

private def encodeFailure : NetworkFailure → Json
  | .InvalidWireInstruction method => obj [("tag", .str "InvalidWireInstruction"), ("method", .str method)]
  | .InvalidDeadline => obj [("tag", .str "InvalidDeadline")]
  | .InvalidNetworkState violation => obj [("tag", .str "InvalidNetworkState"), ("violation", encodeStateViolation violation)]
  | .RootAttemptRequired attempt => obj [("tag", .str "RootAttemptRequired"), ("attempt", encodeAttemptIdentity attempt)]
  | .DuplicateAttempt attempt => obj [("tag", .str "DuplicateAttempt"), ("attempt", encodeAttemptIdentity attempt)]
  | .UnknownAttempt attempt => obj [("tag", .str "UnknownAttempt"), ("attempt", encodeAttemptIdentity attempt)]
  | .AttemptConditionMismatch attempt expected actual => obj [("tag", .str "AttemptConditionMismatch"),
      ("attempt", encodeAttemptIdentity attempt), ("expected", .str (attemptConditionName expected)),
      ("actual", .str (attemptConditionName actual))]
  | .AttemptTokenMismatch attempt tokenField => obj [("tag", .str "AttemptTokenMismatch"),
      ("attempt", encodeAttemptIdentity attempt), ("field", .str (tokenFieldName tokenField))]
  | .ObservationRelationMismatch attempt observationField => obj [("tag", .str "ObservationRelationMismatch"),
      ("attempt", encodeAttemptIdentity attempt), ("field", .str (observationFieldName observationField))]
  | .RequiredCapabilityUnavailable attempt capability => obj [("tag", .str "RequiredCapabilityUnavailable"),
      ("attempt", encodeAttemptIdentity attempt), ("capability", .str (capabilityName capability))]
  | .CommandAlreadyIssued attempt => obj [("tag", .str "CommandAlreadyIssued"), ("attempt", encodeAttemptIdentity attempt)]
  | .IdentityMismatch expected actual => obj [("tag", .str "IdentityMismatch"),
      ("expected", encodeAttemptIdentity expected), ("actual", encodeAttemptIdentity actual)]
  | .HandleMismatch expected actual => obj [("tag", .str "HandleMismatch"),
      ("expected", encodeExecutionHandle expected), ("actual", encodeExecutionHandle actual)]
  | .ClockBasisMismatch expected actual => obj [("tag", .str "ClockBasisMismatch"),
      ("expected", encodeClockBasis expected), ("actual", encodeClockBasis actual)]
  | .DeadlineNotReached deadline observedAt => obj [("tag", .str "DeadlineNotReached"),
      ("deadline", encodeDeadline deadline), ("observedAt", encodeClockObservation observedAt)]
  | .DeliveryOrderViolation attempt expected actual => obj [("tag", .str "DeliveryOrderViolation"),
      ("attempt", encodeAttemptIdentity attempt), ("expected", natJson expected), ("actual", natJson actual)]
  | .ConflictingDelivery attempt delivery old fresh => obj [("tag", .str "ConflictingDelivery"),
      ("attempt", encodeAttemptIdentity attempt), ("delivery", natJson delivery),
      ("old", encodeAdapterObservation old), ("fresh", encodeAdapterObservation fresh)]
  | .MalformedAdapterObservation => obj [("tag", .str "MalformedAdapterObservation")]
  | .Host failure => obj [("tag", .str "Host"), ("failure", encodeNetworkHostFailure failure)]
  | .RetryNotPermitted attempt => obj [("tag", .str "RetryNotPermitted"), ("attempt", encodeAttemptIdentity attempt)]
  | .RetryIdentityMismatch expected actual => obj [("tag", .str "RetryIdentityMismatch"),
      ("expected", encodeRequestIdentity expected), ("actual", encodeRequestIdentity actual)]
  | .RetryParentMismatch expected actual => obj [("tag", .str "RetryParentMismatch"),
      ("expected", encodeAttemptIdentity expected), ("actual", encodeAttemptIdentity actual)]
  | .RetryParentNotSettled attempt => obj [("tag", .str "RetryParentNotSettled"), ("attempt", encodeAttemptIdentity attempt)]
  | .RetryOrderViolation expected actual => obj [("tag", .str "RetryOrderViolation"),
      ("expected", encodeAttemptIdentity expected), ("actual", encodeAttemptIdentity actual)]
  | .RetryAuthorizationAlreadyUsed authorization => obj [("tag", .str "RetryAuthorizationAlreadyUsed"),
      ("authorization", encodeRetryAuthorization authorization)]
  | .EffectWitnessMissing attempt => obj [("tag", .str "EffectWitnessMissing"), ("attempt", encodeAttemptIdentity attempt)]
  | .EffectKnowledgeConflict attempt => obj [("tag", .str "EffectKnowledgeConflict"), ("attempt", encodeAttemptIdentity attempt)]

private def rejectedJson (state : NetworkState) (failure : NetworkFailure) : Json :=
  obj [("result", .str "Rejected"), ("state", encodeState state), ("failure", encodeFailure failure)]

private def encodeReadStep : ReadStateStep → Json
  | .Read state => obj [("result", .str "Read"), ("state", encodeState state)]
  | .Rejected state failure => rejectedJson state failure

private def encodePrepareStep : PrepareStep → Json
  | .Prepared state prepared => obj [("result", .str "Prepared"), ("state", encodeState state),
      ("prepared", encodePrepared prepared)]
  | .Rejected state failure => rejectedJson state failure

private def encodeSendCommand (value : SendCommand) : Json := obj [("prepared", encodePrepared value.prepared)]
private def encodeCancelCommandValue (value : CancelCommand) : Json :=
  obj [("attempt", encodeAttemptIdentity value.attempt), ("handle", encodeExecutionHandle value.handle),
    ("capability", encodeCancellationCapability value.capability)]

private def encodeCommandStep (encode : α → Json) : CommandStep α → Json
  | .CommandReady state command => obj [("result", .str "CommandReady"), ("state", encodeState state),
      ("command", encode command)]
  | .Rejected state failure => rejectedJson state failure

private def encodeNetworkStep : NetworkStep → Json
  | .Started state started => obj [("result", .str "Started"), ("state", encodeState state),
      ("started", encodeStarted started)]
  | .Pending state started => obj [("result", .str "Pending"), ("state", encodeState state),
      ("started", encodeStarted started)]
  | .Terminal state settled => obj [("result", .str "Terminal"), ("state", encodeState state),
      ("settled", encodeSettled settled)]
  | .Late state settled late => obj [("result", .str "Late"), ("state", encodeState state),
      ("settled", encodeSettled settled), ("late", encodeLate late)]
  | .Duplicate state attempt delivery => obj [("result", .str "Duplicate"), ("state", encodeState state),
      ("attempt", encodeAttemptIdentity attempt), ("delivery", natJson delivery)]
  | .Rejected state failure => rejectedJson state failure

private def encodeStateStep : StateStep → Json
  | .Applied state => obj [("result", .str "Applied"), ("state", encodeState state)]
  | .Rejected state failure => rejectedJson state failure

private def runInvocation (value : Json) : DecodeM Json := do
  let operation ← stringField value "operation"
  let state ← decodeState (← field value "state")
  match operation with
  | "readNetworkState" => pure (encodeReadStep (readNetworkState state))
  | "prepare" => pure (encodePrepareStep (prepare state (← decodeAttemptInput (← field value "input"))))
  | "sendCommand" => pure (encodeCommandStep encodeSendCommand (sendCommand state (← decodePrepared (← field value "prepared"))))
  | "cancelCommand" => pure (encodeCommandStep encodeCancelCommandValue (cancelCommand state (← decodeStarted (← field value "started"))))
  | "observeStart" => pure (encodeNetworkStep (observeStart state
      (← decodePrepared (← field value "prepared")) (← decodeStartObservation (← field value "observation"))))
  | "observe" => pure (encodeNetworkStep (observe state (← decodeHostObservation (← field value "observation"))))
  | "annotateEffect" => pure (encodeStateStep (annotateEffect state (← decodeEffectObservation (← field value "effect"))))
  | "retry" => pure (encodePrepareStep (retry state (← decodeRetryRequest (← field value "request"))))
  | other => throw s!"operation: unknown value {other}"

private def invalidInvocation (error : String) : Json :=
  obj [("result", .str "InvalidInvocation"), ("error", .str error)]

private def runLine (line : String) : Json :=
  match Json.parse line with
  | .error error => invalidInvocation error
  | .ok invocation =>
      match runInvocation invocation with
      | .error error => invalidInvocation error
      | .ok result => result

def runnerMain : IO Unit := do
  let stdin ← IO.getStdin
  let input ← stdin.readToEnd
  IO.println (Json.compress (runLine input))

end Necoherence

def main : IO Unit := Necoherence.runnerMain
