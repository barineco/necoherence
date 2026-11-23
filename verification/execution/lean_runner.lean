-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGeneration
import Necoherence.SemanticExecution
import Lean.Data.Json

open Lean Necoherence Necoherence.ExactJson Necoherence.SemanticComposition
open Necoherence.SemanticExecution Necoherence.SemanticTypes Necoherence.SemanticValidation

private def field (value : Json) (name : String) : Except String Json := value.getObjVal? name
private def text (value : Json) (name : String) : Except String String := (field value name).bind (·.getStr?)
private def array (value : Json) (name : String) : Except String (List Json) :=
  return (← (field value name).bind (·.getArr?)).toList
private def nat (value : Json) (name : String) : Except String Nat := (field value name).bind (·.getNat?)
private def natD (value : Json) (name : String) (fallback : Nat) : Nat :=
  ((field value name).bind (·.getNat?)).toOption.getD fallback
private def obj (members : List (String × Json)) : Json := Json.mkObj members
private def bytes (value : Json) : Except String ByteString := do
  let items ← value.getArr?
  items.toList.mapM (·.getNat?)
private def headers (value : Json) : Except String (List RawHeaderField) := do
  (← value.getArr?).toList.mapM fun header => do
    pure { name := ← text header "name", value := ← bytes (← field header "value") }

private def slot (value : Json) : Except String SlotValue := do
  match ← text value "tag" with
  | "absent" => pure .absent
  | "null" => pure .null
  | "present" => pure (.present (ExactJson.fromJson (← field value "value")))
  | _ => throw "unknown slot"

private def slotJson : SlotValue → Except String Json
  | .absent => pure (obj [("tag", .str "absent")])
  | .null => pure (obj [("tag", .str "null")])
  | .present value => do pure (obj [("tag", .str "present"), ("value", ← ExactJson.toJson value)])

private def attemptInput (description : Json) : Except String AttemptInput := do
  pure {
    attempt := { logical := { kind := "semantic", provenance := (text description "provenance").toOption.getD "comparison", revision := 1 }, ordinal := natD description "ordinal" 0 }
    instruction := { method := ← text description "method", target := ← text description "target", headers := ← headers (← field description "headers"), body := ← bytes (← field description "body") }
    deadline := none
    configuration := { requestBodyLimit := 1024, responseBodyLimit := 1024, cancellation := none, monotonicClock := none }
  }

private def outputValues (description : Json) : Except String (List (PortId × SlotValue)) := do
  (← array description "outputs").mapM fun value => do
    pure (⟨← text value "id"⟩, ← slot (← field value "value"))

private def callResult (description : Json) : Except String CallResult := do
  pure { outcome := ⟨← text description "outcome"⟩, outputs := ← outputValues description }

private def providers (case : Json) (references : List FunctionRef) : Except String (List Provider) := do
  (← array case "providers").mapM fun description => do
    let index := natD description "signature" 0
    let reference := references[index]?.getD { identity := "unused", revision := "0", contentDigest := String.ofList (List.replicate 64 '0') }
    let actual := if (← text description "reference") == "declared" then reference else { reference with identity := "other" }
    let implementation ← if (← text description "effect") == "pure" then
      let returned ← callResult description
      pure (ProviderImplementation.pure fun _ => .ok returned)
    else
      let prepared :: _ ← array description "prepare" | throw "HTTP preparation required"
      let decodeRows ← (← array description "decode").mapM fun row => do
        let status ← nat row "status"
        match row.getObjVal? "failure" with
        | .ok failure => pure (status, Except.error (.provider ⟨"operation"⟩ (← text failure "message")))
        | .error _ => pure (status, Except.ok (← callResult row))
      pure (ProviderImplementation.preparedHttp {
        prepare := fun _ =>
          if (text prepared "tag").toOption == some "completed" then
            (callResult prepared).mapError (fun message => .provider ⟨"operation"⟩ message) |>.map PreparedCall.completed
          else
            (attemptInput (field prepared "request" |>.toOption.getD Json.null)).mapError
              (fun message => .provider ⟨"operation"⟩ message) |>.map PreparedCall.ready
        decode := fun response => (decodeRows.find? fun row => row.1 == response.status).map (·.2) |>.getD (.error (.provider ⟨"operation"⟩ "missing decode behavior"))
      })
    pure { reference := actual, implementation }

private def functionJson (value : FunctionRef) : Json := obj [
  ("identity", .str value.identity), ("revision", .str value.revision), ("contentDigest", .str value.contentDigest)]

private def pathJson (path : ValuePath) : Json :=
  toJson (path.map fun
    | .field name => obj [("field", .str name)]
    | .index index => obj [("index", toJson index)]
    | .variant tag => obj [("variant", .str tag)])

private def sourceJson (source : SourceRef) : Json :=
  obj [("repository", .str source.repository), ("revision", .str source.revision),
    ("path", .str source.path), ("contentDigest", .str source.contentDigest),
    ("documentId", .str source.documentId), ("declaredRevision", toJson source.declaredRevision)]

private def typeJson (ref : TypeRef) : Json :=
  obj [
    ("source", sourceJson ref.source),
    ("definition", .str ref.definitionName), ("pointer", toJson ref.pointer)]

private def nested (constructor : String) (arguments : List Json := []) : Json :=
  obj [("constructor", .str constructor), ("arguments", toJson arguments)]

private def producerJson : ProducerRef → Json
  | .initial id => nested "initial" [.str id.value]
  | .invocationOutcome site outcome port =>
      nested "invocationOutcome" [.str site.value, .str outcome.value, .str port.value]

private def valueRefJson (ref : ValueRef) : Json :=
  obj [("producer", producerJson ref.producer), ("path", pathJson ref.path)]

private def lotJson : ResourceLotRef → Json
  | .initial id => nested "initial" [.str id.value]
  | .produced site outcome production =>
      nested "produced" [.str site.value, .str outcome.value, .str production.value]

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
private def valueFailureJson (failure : ValueFailure) : Json :=
  obj [("typeRef", typeJson failure.typeRef),
    ("definitionRef", obj [("source", sourceJson failure.definitionRef.source),
      ("name", .str failure.definitionRef.name)]),
    ("origin", obj [("source", sourceJson failure.origin.source),
      ("pointer", toJson failure.origin.pointer)]),
    ("valuePath", pathJson failure.valuePath),
    ("condition", Necoherence.SignatureWire.encode failure.condition),
    ("observed", Necoherence.SignatureWire.encode failure.observed),
    ("referenceTrace", toJson (failure.referenceTrace.map typeJson))]

private def validationFailureJson : ValidationFailure → Except String Json
  | .value failure => pure (nested "value" [valueFailureJson failure])
  | .unresolved obligations => pure (nested "unresolved" [toJson (obligations.map semanticObligationJson)])
  | .certificateMismatch condition => pure (nested "certificateMismatch" [.str condition])

private def stageName : HostStage → String
  | .Start => "Start" | .RequestWrite => "RequestWrite" | .ResponseHeaders => "ResponseHeaders"
  | .ResponseBody => "ResponseBody" | .Cancel => "Cancel" | .Deadline => "Deadline"
private def hostFailureName : HostFailure → String
  | .UnsupportedUriScheme => "UnsupportedUriScheme" | .InvalidHostConfiguration => "InvalidHostConfiguration"
  | .ExecutionStartFailed => "ExecutionStartFailed" | .NameResolutionFailed => "NameResolutionFailed"
  | .ConnectionFailed => "ConnectionFailed" | .RequestWriteFailed => "RequestWriteFailed"
  | .ResponseHeadersFailed => "ResponseHeadersFailed" | .ResponseBodyFailed => "ResponseBodyFailed"
  | .ResponseBodyLimitExceeded => "ResponseBodyLimitExceeded" | .MalformedResponse => "MalformedResponse"
  | .HeaderRepresentationUnavailable => "HeaderRepresentationUnavailable"
  | .RequestHeaderEncodingUnavailable => "RequestHeaderEncodingUnavailable"
  | .CancellationRejected => "CancellationRejected" | .DeadlineControlUnavailable => "DeadlineControlUnavailable"
  | .Timeout _ _ => "Timeout" | .HostRuntimeFailure => "HostRuntimeFailure" | .HostClosed => "HostClosed"
private def reasonName : UnknownEffectReason → String
  | .NoResponse => "NoResponse" | .Cancellation => "Cancellation" | .Deadline => "Deadline"
  | .HostFailure => "HostFailure" | .ProtocolWitnessMissing => "ProtocolWitnessMissing" | .LateSignal => "LateSignal"

private def networkRequestIdentityJson (value : RequestIdentity) : Json := obj [
  ("kind", .str value.kind), ("provenance", .str value.provenance), ("revision", toJson value.revision)]

private def networkAttemptIdentityJson (value : AttemptIdentity) : Json := obj [
  ("logical", networkRequestIdentityJson value.logical), ("ordinal", toJson value.ordinal)]

private def networkHandleJson (value : ExecutionHandle) : Json := obj [("value", .str value.value)]
private def networkEvidenceJson (value : OpaqueEvidence) : Json := obj [("value", .str value.value)]
private def networkClockBasisJson (value : ClockBasis) : Json := obj [("value", .str value.value)]

private def networkClockObservationJson (value : MonotonicClockObservation) : Json := obj [
  ("clockBasis", networkClockBasisJson value.clockBasis), ("value", toJson value.value)]

private def networkClockCapabilityJson (value : MonotonicClockCapability) : Json := obj [
  ("identity", networkEvidenceJson value.identity), ("clockBasis", networkClockBasisJson value.clockBasis)]

private def networkCancellationCapabilityJson (value : CancellationCapability) : Json :=
  obj [("identity", networkEvidenceJson value.identity)]

private def networkDeadlineJson (value : Deadline) : Json := obj [
  ("clockBasis", networkClockBasisJson value.clockBasis), ("limit", toJson value.limit),
  ("capability", networkClockCapabilityJson value.capability)]

private def networkConfigurationJson (value : HostConfiguration) : Json := obj [
  ("requestBodyLimit", toJson value.requestBodyLimit), ("responseBodyLimit", toJson value.responseBodyLimit),
  ("cancellation", value.cancellation.map networkCancellationCapabilityJson |>.getD .null),
  ("monotonicClock", value.monotonicClock.map networkClockCapabilityJson |>.getD .null)]

private def networkHeaderJson (value : RawHeaderField) : Json :=
  obj [("name", .str value.name), ("value", toJson value.value)]

private def networkResponseJson (value : RawHttpResponse) : Json := obj [
  ("status", toJson value.status), ("headers", toJson (value.headers.map networkHeaderJson)),
  ("body", toJson value.body)]

private def networkAuthorizationJson (value : RetryAuthorization) : Json := obj [
  ("logical", networkRequestIdentityJson value.logical), ("from", networkAttemptIdentityJson value.«from»),
  ("next", networkAttemptIdentityJson value.next), ("protocolEvidence", networkEvidenceJson value.protocolEvidence)]

private def networkProvenanceJson : HeaderProvenance → Json
  | .WireObserved => obj [("tag", .str "WireObserved")]
  | .LibraryObserved => obj [("tag", .str "LibraryObserved")]
  | .LibraryNormalized => obj [("tag", .str "LibraryNormalized")]

private def networkWitnessSourceJson : EffectWitnessSource → Json
  | .Adapter => obj [("tag", .str "Adapter")]
  | .Protocol => obj [("tag", .str "Protocol")]

private def networkWitnessJson (value : EffectWitness) : Json := obj [
  ("attempt", networkAttemptIdentityJson value.attempt), ("source", networkWitnessSourceJson value.source),
  ("evidence", networkEvidenceJson value.evidence)]

private def networkUnknownReasonJson (value : UnknownEffectReason) : Json := obj [("tag", .str (reasonName value))]

private def networkEffectJson : EffectStatus → Json
  | .Unknown reason => obj [("tag", .str "Unknown"), ("reason", networkUnknownReasonJson reason)]
  | .NoEffect witness => obj [("tag", .str "NoEffect"), ("witness", networkWitnessJson witness)]
  | .EffectOccurred witness => obj [("tag", .str "EffectOccurred"), ("witness", networkWitnessJson witness)]

private def networkTimeoutCauseName : HostTimeoutCause → String
  | .LibraryReported => "LibraryReported" | .SocketReported => "SocketReported"
  | .PoolAcquisition => "PoolAcquisition" | .HostOperation => "HostOperation"

private def networkHostFailureJson : HostFailure → Json
  | .Timeout stage cause => obj [("tag", .str "Timeout"), ("stage", obj [("tag", .str (stageName stage))]),
      ("cause", obj [("tag", .str (networkTimeoutCauseName cause))])]
  | value => obj [("tag", .str (hostFailureName value))]

private def networkHostJson (value : NetworkHostFailure) : Json := obj [
  ("attempt", networkAttemptIdentityJson value.attempt), ("stage", obj [("tag", .str (stageName value.stage))]),
  ("configuration", networkConfigurationJson value.configuration), ("cause", networkHostFailureJson value.cause)]

private def networkSourceJson : SourceSequence → Json
  | .none => .null
  | .some value => toJson value

private def networkAdapterJson : AdapterObservation → Json
  | .ResponseObservation attempt handle source response provenance effect => obj [
      ("tag", .str "ResponseObservation"), ("attempt", networkAttemptIdentityJson attempt),
      ("handle", networkHandleJson handle), ("sourceSequence", networkSourceJson source),
      ("response", networkResponseJson response), ("provenance", networkProvenanceJson provenance),
      ("effect", networkEffectJson effect)]
  | .FailureObservation attempt handle source failure effect => obj [
      ("tag", .str "FailureObservation"), ("attempt", networkAttemptIdentityJson attempt),
      ("handle", networkHandleJson handle), ("sourceSequence", networkSourceJson source),
      ("failure", networkHostJson failure), ("effect", networkEffectJson effect)]
  | .CancellationObservation attempt handle source effect => obj [
      ("tag", .str "CancellationObservation"), ("attempt", networkAttemptIdentityJson attempt),
      ("handle", networkHandleJson handle), ("sourceSequence", networkSourceJson source),
      ("effect", networkEffectJson effect)]
  | .DeadlineObservation attempt handle source deadline observed effect => obj [
      ("tag", .str "DeadlineObservation"), ("attempt", networkAttemptIdentityJson attempt),
      ("handle", networkHandleJson handle), ("sourceSequence", networkSourceJson source),
      ("deadline", networkDeadlineJson deadline), ("observedAt", networkClockObservationJson observed),
      ("effect", networkEffectJson effect)]

private def networkStateViolationJson : NetworkStateViolation → Json
  | .DuplicateAttemptKey attempt => obj [("tag", .str "DuplicateAttemptKey"), ("attempt", networkAttemptIdentityJson attempt)]
  | .NonRootFirstAttempt attempt => obj [("tag", .str "NonRootFirstAttempt"), ("attempt", networkAttemptIdentityJson attempt)]
  | .OrdinalGap attempt => obj [("tag", .str "OrdinalGap"), ("attempt", networkAttemptIdentityJson attempt)]
  | .ChainMismatch attempt => obj [("tag", .str "ChainMismatch"), ("attempt", networkAttemptIdentityJson attempt)]
  | .RetryAuthorizationReuse authorization => obj [("tag", .str "RetryAuthorizationReuse"),
      ("authorization", networkAuthorizationJson authorization)]
  | .DispositionEvidenceMismatch attempt => obj [("tag", .str "DispositionEvidenceMismatch"),
      ("attempt", networkAttemptIdentityJson attempt)]
  | .DeliveryLogMismatch attempt => obj [("tag", .str "DeliveryLogMismatch"),
      ("attempt", networkAttemptIdentityJson attempt)]

private def networkAttemptConditionName : AttemptCondition → String
  | .IsPrepared => "IsPrepared" | .IsCommandIssued => "IsCommandIssued"
  | .IsStarted => "IsStarted" | .IsSettled => "IsSettled"

private def networkTokenFieldName : AttemptTokenField → String
  | .Instruction => "Instruction" | .Deadline => "Deadline" | .Configuration => "Configuration"
  | .Chain => "Chain" | .Handle => "Handle"

private def networkObservationFieldName : ObservationField → String
  | .FailureConfiguration => "FailureConfiguration" | .FailureStage => "FailureStage"
  | .DeadlineValue => "DeadlineValue" | .ClockBasisValue => "ClockBasisValue"
  | .ClockObservationValue => "ClockObservationValue" | .EffectWitnessValue => "EffectWitnessValue"

private def networkCapabilityName : CapabilityKind → String
  | .Cancellation => "Cancellation"
  | .MonotonicClock => "MonotonicClock"

private def networkFailureJson : NetworkFailure → Json
  | .InvalidWireInstruction method => obj [("tag", .str "InvalidWireInstruction"), ("method", .str method)]
  | .InvalidDeadline => obj [("tag", .str "InvalidDeadline")]
  | .InvalidNetworkState violation => obj [("tag", .str "InvalidNetworkState"),
      ("violation", networkStateViolationJson violation)]
  | .RootAttemptRequired attempt => obj [("tag", .str "RootAttemptRequired"), ("attempt", networkAttemptIdentityJson attempt)]
  | .DuplicateAttempt attempt => obj [("tag", .str "DuplicateAttempt"), ("attempt", networkAttemptIdentityJson attempt)]
  | .UnknownAttempt attempt => obj [("tag", .str "UnknownAttempt"), ("attempt", networkAttemptIdentityJson attempt)]
  | .AttemptConditionMismatch attempt expected actual => obj [("tag", .str "AttemptConditionMismatch"),
      ("attempt", networkAttemptIdentityJson attempt), ("expected", .str (networkAttemptConditionName expected)),
      ("actual", .str (networkAttemptConditionName actual))]
  | .AttemptTokenMismatch attempt field => obj [("tag", .str "AttemptTokenMismatch"),
      ("attempt", networkAttemptIdentityJson attempt), ("field", .str (networkTokenFieldName field))]
  | .ObservationRelationMismatch attempt field => obj [("tag", .str "ObservationRelationMismatch"),
      ("attempt", networkAttemptIdentityJson attempt), ("field", .str (networkObservationFieldName field))]
  | .RequiredCapabilityUnavailable attempt capability => obj [("tag", .str "RequiredCapabilityUnavailable"),
      ("attempt", networkAttemptIdentityJson attempt), ("capability", .str (networkCapabilityName capability))]
  | .CommandAlreadyIssued attempt => obj [("tag", .str "CommandAlreadyIssued"), ("attempt", networkAttemptIdentityJson attempt)]
  | .IdentityMismatch expected actual => obj [("tag", .str "IdentityMismatch"),
      ("expected", networkAttemptIdentityJson expected), ("actual", networkAttemptIdentityJson actual)]
  | .HandleMismatch expected actual => obj [("tag", .str "HandleMismatch"),
      ("expected", networkHandleJson expected), ("actual", networkHandleJson actual)]
  | .ClockBasisMismatch expected actual => obj [("tag", .str "ClockBasisMismatch"),
      ("expected", networkClockBasisJson expected), ("actual", networkClockBasisJson actual)]
  | .DeadlineNotReached deadline observed => obj [("tag", .str "DeadlineNotReached"),
      ("deadline", networkDeadlineJson deadline), ("observedAt", networkClockObservationJson observed)]
  | .DeliveryOrderViolation attempt expected actual => obj [("tag", .str "DeliveryOrderViolation"),
      ("attempt", networkAttemptIdentityJson attempt), ("expected", toJson expected), ("actual", toJson actual)]
  | .ConflictingDelivery attempt delivery old fresh => obj [("tag", .str "ConflictingDelivery"),
      ("attempt", networkAttemptIdentityJson attempt), ("delivery", toJson delivery),
      ("old", networkAdapterJson old), ("fresh", networkAdapterJson fresh)]
  | .MalformedAdapterObservation => obj [("tag", .str "MalformedAdapterObservation")]
  | .Host failure => obj [("tag", .str "Host"), ("failure", networkHostJson failure)]
  | .RetryNotPermitted attempt => obj [("tag", .str "RetryNotPermitted"), ("attempt", networkAttemptIdentityJson attempt)]
  | .RetryIdentityMismatch expected actual => obj [("tag", .str "RetryIdentityMismatch"),
      ("expected", networkRequestIdentityJson expected), ("actual", networkRequestIdentityJson actual)]
  | .RetryParentMismatch expected actual => obj [("tag", .str "RetryParentMismatch"),
      ("expected", networkAttemptIdentityJson expected), ("actual", networkAttemptIdentityJson actual)]
  | .RetryParentNotSettled attempt => obj [("tag", .str "RetryParentNotSettled"),
      ("attempt", networkAttemptIdentityJson attempt)]
  | .RetryOrderViolation expected actual => obj [("tag", .str "RetryOrderViolation"),
      ("expected", networkAttemptIdentityJson expected), ("actual", networkAttemptIdentityJson actual)]
  | .RetryAuthorizationAlreadyUsed authorization => obj [("tag", .str "RetryAuthorizationAlreadyUsed"),
      ("authorization", networkAuthorizationJson authorization)]
  | .EffectWitnessMissing attempt => obj [("tag", .str "EffectWitnessMissing"),
      ("attempt", networkAttemptIdentityJson attempt)]
  | .EffectKnowledgeConflict attempt => obj [("tag", .str "EffectKnowledgeConflict"),
      ("attempt", networkAttemptIdentityJson attempt)]

private def failureJson : ExecutionFailure → Except String Json
  | .value value => return obj [("tag", .str "value"), ("detail", ← validationFailureJson value)]
  | .missingArgument id => pure (obj [("tag", .str "missingArgument"), ("input", .str id.value)])
  | .argumentCoverage condition => pure (obj [("tag", .str "argumentCoverage"), ("condition", .str condition)])
  | .missingValue value => pure (obj [("tag", .str "missingValue"), ("detail", valueRefJson value)])
  | .missingProvider function => pure (obj [("tag", .str "missingProvider"), ("function", functionJson function)])
  | .providerCoverage condition => pure (obj [("tag", .str "providerCoverage"), ("condition", .str condition)])
  | .providerEffect function => pure (obj [("tag", .str "providerEffect"), ("function", functionJson function)])
  | .provider site message => pure (obj [("tag", .str "provider"), ("site", .str site.value), ("message", .str message)])
  | .invalidOutcome site outcome => pure (obj [("tag", .str "invalidOutcome"), ("site", .str site.value), ("outcome", .str outcome.value)])
  | .resource lot condition => pure (obj [("tag", .str "resource"), ("lot", lotJson lot), ("condition", .str condition)])
  | .invalidPlan condition => pure (obj [("tag", .str "invalidPlan"), ("condition", .str condition)])
  | .network value => pure (obj [("tag", .str "network"), ("detail", networkFailureJson value)])
  | .networkTerminal terminal =>
      let (outcome, stage, cause) := match terminal.outcome with
        | .Failed failure => ("Failed", some (stageName failure.stage), some (hostFailureName failure.cause))
        | .Response _ _ => ("Response", none, none) | .Cancelled => ("Cancelled", none, none)
        | .DeadlineExceeded _ _ => ("DeadlineExceeded", none, none)
      let (effect, reason) := match terminal.effect with
        | .NoEffect _ => ("NoEffect", none) | .EffectOccurred _ => ("EffectOccurred", none)
        | .Unknown reason => ("Unknown", some (reasonName reason))
      pure (obj [("tag", .str "networkTerminal"), ("outcome", .str outcome),
        ("stage", stage.map Json.str |>.getD .null), ("cause", cause.map Json.str |>.getD .null),
        ("effect", .str effect), ("reason", reason.map Json.str |>.getD .null)])

private def requestFor (case : Json) (index : Nat) : Except String AttemptInput := do
  let descriptions ← array case "providers"
  let prepared ← descriptions.flatMapM fun description => do
    match array description "prepare" with | .ok rows => pure rows | .error _ => pure []
  let ready := prepared.filter fun row => (text row "tag").toOption == some "ready"
  let some selected := ready[index]? | throw "request index unavailable"
  attemptInput (← field selected "request")

private def instructionJson : NetworkInstruction → Json
  | .send _ => obj [("tag", .str "pending"), ("instruction", .str "send")]
  | .observe _ => obj [("tag", .str "pending"), ("instruction", .str "observe")]

private def resultJson : ExecutionResult → Except String Json
  | .success outputs => do
      let values ← outputs.mapM fun (name, value) => do pure (Json.arr #[.str name.value, ← slotJson value])
      pure (obj [("tag", .str "success"), ("outcome", .arr values.toArray)])
  | .failure embedding value => do
      pure (obj [("tag", .str "failure"), ("embedding", .str embedding.value), ("value", ← slotJson value)])

private partial def drive (identity : String) (case : Json) (observations : List Json)
    (progress : List Json) : Except RunFailure Progress → Except String Json
  | .error failure => do
      pure (obj [("case", .str identity), ("progress", .arr progress.toArray), ("failure", ← failureJson failure.cause)])
  | .ok (.completed result _) => do
      pure (obj [("case", .str identity), ("progress", .arr (progress ++ [obj [("tag", .str "completed")]]).toArray), ("result", ← resultJson result)])
  | .ok (.pending execution instruction) => do
      let observation :: rest := observations | throw "observation required"
      let request ← requestFor case (natD observation "request" 0)
      let handle : ExecutionHandle := ⟨match text observation "handle" with | .ok value => value | .error _ => "handle"⟩
      let supplied ← if (← text observation "tag") == "start" then
        if (← text observation "kind") == "started" then
          pure (ExecutionObservation.start (.Started request.attempt handle))
        else
          let failure : NetworkHostFailure := { attempt := request.attempt, stage := .Start, configuration := request.configuration, cause := .ExecutionStartFailed }
          pure (ExecutionObservation.start (.StartFailed failure (.Unknown .NoResponse)))
      else
        let response : RawHttpResponse := { status := ← nat observation "status", headers := ← headers (← field observation "headers"), body := ← bytes (← field observation "body") }
        let observed := AdapterObservation.ResponseObservation request.attempt handle .none response .LibraryNormalized (.Unknown .NoResponse)
        pure (ExecutionObservation.host (.Delivered (natD observation "delivery" 0) observed))
      drive identity case rest (progress ++ [instructionJson instruction]) (resume execution supplied)

private def runCase (case : Json) : Except String Json := do
  let identity ← text case "case"
  let exchange ← text case "exchange"
  let input ← (Necoherence.SignatureGeneration.decodeInput exchange).mapError (fun failure => reprStr failure)
  let _ ← (Necoherence.SignatureGeneration.admit input (Necoherence.SignatureGeneration.ExpectedBasis.ofInput input)).mapError (fun failure => reprStr failure)
  let some ⟨prepared, verified⟩ ← (Necoherence.SignatureComposition.verifyInput input input.basis).mapError (fun failure => reprStr failure) | throw s!"{identity}: composition required"
  let references := if prepared.input.signatures.isEmpty then
      [{ identity := "unused", revision := "0", contentDigest := String.ofList (List.replicate 64 '0') }]
    else prepared.input.signatures.map (·.reference)
  let arguments ← (← array case "arguments").mapM fun value => do
    pure (⟨← text value "id"⟩, ← slot (← field value "value"))
  let implementations ← providers case references
  drive identity case (← array case "observations") [] (start prepared verified.checked implementations arguments { attempts := [] })

def main (args : List String) : IO UInt32 := do
  let some path := args.head? | IO.eprintln "input path required"; return 2
  let .ok document := Json.parse (← IO.FS.readFile path) | IO.eprintln "invalid input"; return 2
  let .ok cases := (field document "cases").bind (·.getArr?) | IO.eprintln "cases required"; return 2
  let mut rows := #[]
  for case in cases do
    match runCase case with
    | .ok row => rows := rows.push row
    | .error message =>
      let identity := (field case "case").bind (·.getStr?) |>.toOption |>.getD ""
      rows := rows.push (Json.mkObj [("case", identity), ("progress", Json.arr #[]), ("driverFailure", message)])
  IO.println (Json.compress (.arr rows))
  return 0
