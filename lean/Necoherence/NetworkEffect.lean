-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.RequestProgression

namespace Necoherence

abbrev ByteString := List Nat

structure RawHeaderField where
  name : String
  value : ByteString
  deriving DecidableEq, Repr

structure HttpWireInstruction where
  method : String
  target : String
  headers : List RawHeaderField
  body : ByteString
  deriving DecidableEq, Repr

structure RawHttpResponse where
  status : Nat
  headers : List RawHeaderField
  body : ByteString
  deriving DecidableEq, Repr

inductive HeaderProvenance where
  | WireObserved
  | LibraryObserved
  | LibraryNormalized
  deriving DecidableEq, Repr

structure AttemptIdentity where
  logical : RequestIdentity
  ordinal : Nat
  deriving DecidableEq, Repr

structure OpaqueEvidence where
  value : String
  deriving DecidableEq, Repr

structure ClockBasis where
  value : String
  deriving DecidableEq, Repr

structure MonotonicClockObservation where
  clockBasis : ClockBasis
  value : Nat
  deriving DecidableEq, Repr

structure MonotonicClockCapability where
  identity : OpaqueEvidence
  clockBasis : ClockBasis
  deriving DecidableEq, Repr

structure CancellationCapability where
  identity : OpaqueEvidence
  deriving DecidableEq, Repr

structure Deadline where
  clockBasis : ClockBasis
  limit : Nat
  capability : MonotonicClockCapability
  deriving DecidableEq, Repr

structure HostConfiguration where
  requestBodyLimit : Nat
  responseBodyLimit : Nat
  cancellation : Option CancellationCapability
  monotonicClock : Option MonotonicClockCapability
  deriving DecidableEq, Repr

structure AttemptInput where
  attempt : AttemptIdentity
  instruction : HttpWireInstruction
  deadline : Option Deadline
  configuration : HostConfiguration
  deriving DecidableEq, Repr
structure RetryAuthorization where
  logical : RequestIdentity
  «from» : AttemptIdentity
  next : AttemptIdentity
  protocolEvidence : OpaqueEvidence
  deriving DecidableEq, Repr

inductive AttemptLineage where
  | Root
  | RetryOf : RetryAuthorization → AttemptLineage
  deriving DecidableEq, Repr

structure PreparedAttempt where
  input : AttemptInput
  lineage : AttemptLineage
  deriving DecidableEq, Repr


structure StartedAttempt where
  prepared : PreparedAttempt
  handle : ExecutionHandle
  deriving DecidableEq, Repr

structure SendCommand where
  prepared : PreparedAttempt
  deriving DecidableEq, Repr

structure CancelCommand where
  attempt : AttemptIdentity
  handle : ExecutionHandle
  capability : CancellationCapability
  deriving DecidableEq, Repr

inductive EffectWitnessSource where
  | Adapter
  | Protocol
  deriving DecidableEq, Repr

structure EffectWitness where
  attempt : AttemptIdentity
  source : EffectWitnessSource
  evidence : OpaqueEvidence
  deriving DecidableEq, Repr

inductive UnknownEffectReason where
  | NoResponse
  | Cancellation
  | Deadline
  | HostFailure
  | ProtocolWitnessMissing
  | LateSignal
  deriving DecidableEq, Repr

inductive EffectStatus where
  | NoEffect : EffectWitness → EffectStatus
  | EffectOccurred : EffectWitness → EffectStatus
  | Unknown : UnknownEffectReason → EffectStatus
  deriving DecidableEq, Repr

structure EffectObservation where
  attempt : AttemptIdentity
  status : EffectStatus
  deriving DecidableEq, Repr

inductive HostStage where
  | Start
  | RequestWrite
  | ResponseHeaders
  | ResponseBody
  | Cancel
  | Deadline
  deriving DecidableEq, Repr

inductive HostTimeoutCause where
  | LibraryReported
  | SocketReported
  | PoolAcquisition
  | HostOperation
  deriving DecidableEq, Repr

inductive HostFailure where
  | UnsupportedUriScheme
  | InvalidHostConfiguration
  | ExecutionStartFailed
  | NameResolutionFailed
  | ConnectionFailed
  | RequestWriteFailed
  | ResponseHeadersFailed
  | ResponseBodyFailed
  | ResponseBodyLimitExceeded
  | MalformedResponse
  | HeaderRepresentationUnavailable
  | RequestHeaderEncodingUnavailable
  | CancellationRejected
  | DeadlineControlUnavailable
  | Timeout : HostStage → HostTimeoutCause → HostFailure
  | HostRuntimeFailure
  | HostClosed
  deriving DecidableEq, Repr

structure NetworkHostFailure where
  attempt : AttemptIdentity
  stage : HostStage
  configuration : HostConfiguration
  cause : HostFailure
  deriving DecidableEq, Repr

inductive NetworkOutcome where
  | Response : RawHttpResponse → HeaderProvenance → NetworkOutcome
  | Failed : NetworkHostFailure → NetworkOutcome
  | Cancelled : NetworkOutcome
  | DeadlineExceeded : Deadline → MonotonicClockObservation → NetworkOutcome
  deriving DecidableEq, Repr

structure NetworkTerminal where
  outcome : NetworkOutcome
  effect : EffectStatus
  deriving DecidableEq, Repr

inductive AttemptDisposition where
  | Prepared
  | CommandIssued
  | Started : ExecutionHandle → AttemptDisposition
  | Settled : Option ExecutionHandle → NetworkTerminal → AttemptDisposition
  deriving DecidableEq, Repr

inductive SourceSequence where
  | none
  | some : Nat → SourceSequence
  deriving DecidableEq, Repr

abbrev DeliveryOrdinal := Nat
inductive AdapterObservation where
  | ResponseObservation : AttemptIdentity → ExecutionHandle → SourceSequence → RawHttpResponse → HeaderProvenance → EffectStatus → AdapterObservation
  | FailureObservation : AttemptIdentity → ExecutionHandle → SourceSequence → NetworkHostFailure → EffectStatus → AdapterObservation
  | CancellationObservation : AttemptIdentity → ExecutionHandle → SourceSequence → EffectStatus → AdapterObservation
  | DeadlineObservation : AttemptIdentity → ExecutionHandle → SourceSequence → Deadline → MonotonicClockObservation → EffectStatus → AdapterObservation
  deriving DecidableEq, Repr

structure DeliveredObservation where
  delivery : DeliveryOrdinal
  observation : AdapterObservation
  deriving DecidableEq, Repr

structure LateObservation where
  delivered : DeliveredObservation
  deriving DecidableEq, Repr

structure AttemptRecord where
  input : AttemptInput
  lineage : AttemptLineage
  disposition : AttemptDisposition
  firstDelivery : Option DeliveredObservation
  late : List LateObservation
  deriving DecidableEq, Repr

structure NetworkState where
  attempts : List AttemptRecord
  deriving DecidableEq, Repr


inductive RetryPermission where
  | RetryAllowed : RetryAuthorization → RetryPermission
  | RetryDenied : RequestIdentity → AttemptIdentity → OpaqueEvidence → RetryPermission
  deriving DecidableEq, Repr

structure RetryRequest where
  permission : RetryPermission
  instruction : HttpWireInstruction
  deadline : Option Deadline
  configuration : HostConfiguration
  deriving DecidableEq, Repr

inductive StartObservation where
  | Started : AttemptIdentity → ExecutionHandle → StartObservation
  | StartFailed : NetworkHostFailure → EffectStatus → StartObservation
  deriving DecidableEq, Repr


inductive HostObservation where
  | Pending : AttemptIdentity → ExecutionHandle → HostObservation
  | Delivered : DeliveryOrdinal → AdapterObservation → HostObservation
  deriving DecidableEq, Repr

inductive NetworkStateViolation where
  | DuplicateAttemptKey : AttemptIdentity → NetworkStateViolation
  | NonRootFirstAttempt : AttemptIdentity → NetworkStateViolation
  | OrdinalGap : AttemptIdentity → NetworkStateViolation
  | LineageMismatch : AttemptIdentity → NetworkStateViolation
  | RetryAuthorizationReuse : RetryAuthorization → NetworkStateViolation
  | DispositionEvidenceMismatch : AttemptIdentity → NetworkStateViolation
  | DeliveryLogMismatch : AttemptIdentity → NetworkStateViolation
  deriving DecidableEq, Repr

inductive AttemptCondition where
  | IsPrepared
  | IsCommandIssued
  | IsStarted
  | IsSettled
  deriving DecidableEq, Repr

inductive AttemptTokenField where
  | Instruction
  | Deadline
  | Configuration
  | Lineage
  | Handle
  deriving DecidableEq, Repr

inductive ObservationField where
  | FailureConfiguration
  | FailureStage
  | DeadlineValue
  | ClockBasisValue
  | ClockObservationValue
  | EffectWitnessValue
  deriving DecidableEq, Repr

inductive CapabilityKind where
  | Cancellation
  | MonotonicClock
  deriving DecidableEq, Repr

inductive NetworkFailure where
  | InvalidWireInstruction : String → NetworkFailure
  | InvalidDeadline
  | InvalidNetworkState : NetworkStateViolation → NetworkFailure
  | RootAttemptRequired : AttemptIdentity → NetworkFailure
  | DuplicateAttempt : AttemptIdentity → NetworkFailure
  | UnknownAttempt : AttemptIdentity → NetworkFailure
  | AttemptConditionMismatch : AttemptIdentity → AttemptCondition → AttemptCondition → NetworkFailure
  | AttemptTokenMismatch : AttemptIdentity → AttemptTokenField → NetworkFailure
  | ObservationRelationMismatch : AttemptIdentity → ObservationField → NetworkFailure
  | RequiredCapabilityUnavailable : AttemptIdentity → CapabilityKind → NetworkFailure
  | CommandAlreadyIssued : AttemptIdentity → NetworkFailure
  | IdentityMismatch : AttemptIdentity → AttemptIdentity → NetworkFailure
  | HandleMismatch : ExecutionHandle → ExecutionHandle → NetworkFailure
  | ClockBasisMismatch : ClockBasis → ClockBasis → NetworkFailure
  | DeadlineNotReached : Deadline → MonotonicClockObservation → NetworkFailure
  | DeliveryOrderViolation : AttemptIdentity → DeliveryOrdinal → DeliveryOrdinal → NetworkFailure
  | ConflictingDelivery : AttemptIdentity → DeliveryOrdinal → AdapterObservation → AdapterObservation → NetworkFailure
  | MalformedAdapterObservation
  | Host : NetworkHostFailure → NetworkFailure
  | RetryNotPermitted : AttemptIdentity → NetworkFailure
  | RetryIdentityMismatch : RequestIdentity → RequestIdentity → NetworkFailure
  | RetryParentMismatch : AttemptIdentity → AttemptIdentity → NetworkFailure
  | RetryParentNotSettled : AttemptIdentity → NetworkFailure
  | RetryOrderViolation : AttemptIdentity → AttemptIdentity → NetworkFailure
  | RetryAuthorizationAlreadyUsed : RetryAuthorization → NetworkFailure
  | EffectWitnessMissing : AttemptIdentity → NetworkFailure
  | EffectKnowledgeConflict : AttemptIdentity → NetworkFailure
  deriving DecidableEq, Repr

inductive ReadStateStep where
  | Read : NetworkState → ReadStateStep
  | Rejected : NetworkState → NetworkFailure → ReadStateStep
  deriving DecidableEq, Repr

inductive PrepareStep where
  | Prepared : NetworkState → PreparedAttempt → PrepareStep
  | Rejected : NetworkState → NetworkFailure → PrepareStep
  deriving DecidableEq, Repr

inductive CommandStep (α : Type) where
  | CommandReady : NetworkState → α → CommandStep α
  | Rejected : NetworkState → NetworkFailure → CommandStep α
  deriving DecidableEq, Repr

inductive StateStep where
  | Applied : NetworkState → StateStep
  | Rejected : NetworkState → NetworkFailure → StateStep
  deriving DecidableEq, Repr

structure SettledAttempt where
  prepared : PreparedAttempt
  handle : Option ExecutionHandle
  terminal : NetworkTerminal
  deriving DecidableEq, Repr

inductive NetworkStep where
  | Started : NetworkState → StartedAttempt → NetworkStep
  | Pending : NetworkState → StartedAttempt → NetworkStep
  | Terminal : NetworkState → SettledAttempt → NetworkStep
  | Late : NetworkState → SettledAttempt → LateObservation → NetworkStep
  | Duplicate : NetworkState → AttemptIdentity → DeliveryOrdinal → NetworkStep
  | Rejected : NetworkState → NetworkFailure → NetworkStep
  deriving DecidableEq, Repr

structure ProgressionProjection where
  terminal : Option NetworkTerminal
  deriving DecidableEq, Repr

structure ProgressionBridgeInput where
  progression : RequestProgressionSnapshot
  attempt : AttemptIdentity
  deriving DecidableEq, Repr

structure ProgressionBridgeOutput where
  progression : RequestProgressionSnapshot
  projection : ProgressionProjection
  deriving DecidableEq, Repr

inductive NetworkFailureCategory where
  | Wire
  | Deadline
  | State
  | Token
  | Capability
  | Identity
  | Handle
  | Observation
  | Delivery
  | Host
  | Retry
  | Effect
  deriving DecidableEq, Repr

private def byteOk (b : Nat) : Bool := decide (b ≤ 255)

private def bytesOk : ByteString → Bool
  | [] => true
  | b :: bs => byteOk b && bytesOk bs

private def tokenCharOk (c : Char) : Bool :=
  let n := c.toNat
  ((65 ≤ n) && (n ≤ 90)) ||
  ((97 ≤ n) && (n ≤ 122)) ||
  ((48 ≤ n) && (n ≤ 57)) ||
  n == 33 || n == 35 || n == 36 || n == 37 || n == 38 ||
  n == 39 || n == 42 || n == 43 || n == 45 || n == 46 ||
  n == 94 || n == 95 || n == 96 || n == 124 || n == 126

private def alphaCharOk (c : Char) : Bool :=
  let n := c.toNat
  ((65 ≤ n) && (n ≤ 90)) || ((97 ≤ n) && (n ≤ 122))

private def tokenOk (value : String) : Bool :=
  value != "" && value.toList.all tokenCharOk

private def digitCharOk (c : Char) : Bool :=
  '0' ≤ c && c ≤ '9'

private def hexCharOk (c : Char) : Bool :=
  digitCharOk c || ('A' ≤ c && c ≤ 'F') || ('a' ≤ c && c ≤ 'f')

private def uriUnreservedOk (c : Char) : Bool :=
  alphaCharOk c || digitCharOk c || c == '-' || c == '.' || c == '_' || c == '~'

private def uriSubDelimOk (c : Char) : Bool :=
  c == '!' || c == '$' || c == '&' || c == '\'' || c == '(' || c == ')' ||
  c == '*' || c == '+' || c == ',' || c == ';' || c == '='

private def uriPcharOk (c : Char) : Bool :=
  uriUnreservedOk c || uriSubDelimOk c || c == ':' || c == '@'

private def uriComponentOk (allowQuestion : Bool) : List Char → Bool
  | [] => true
  | '%' :: high :: low :: rest =>
      hexCharOk high && hexCharOk low && uriComponentOk allowQuestion rest
  | '%' :: _ => false
  | c :: rest =>
      (uriPcharOk c || c == '/' || (allowQuestion && c == '?')) &&
      uriComponentOk allowQuestion rest

private def splitAtChar (delimiter : Char) : List Char → List Char × Option (List Char)
  | [] => ([], none)
  | c :: rest =>
      if c == delimiter then ([], some rest)
      else
        let (before, after) := splitAtChar delimiter rest
        (c :: before, after)

private def uriRegNameOk : List Char → Bool
  | [] => true
  | '%' :: high :: low :: rest =>
      hexCharOk high && hexCharOk low && uriRegNameOk rest
  | '%' :: _ => false
  | c :: rest => (uriUnreservedOk c || uriSubDelimOk c) && uriRegNameOk rest

private def uriUserInfoOk : List Char → Bool
  | [] => true
  | '%' :: high :: low :: rest =>
      hexCharOk high && hexCharOk low && uriUserInfoOk rest
  | '%' :: _ => false
  | c :: rest =>
      (uriUnreservedOk c || uriSubDelimOk c || c == ':') && uriUserInfoOk rest

private def uriPortOk : List Char → Bool
  | [] => true
  | c :: rest => digitCharOk c && uriPortOk rest

private def uriIpLiteralOk (address : List Char) : Bool :=
  address ≠ [] &&
  (address.any (fun c => c == ':' || c == '.') = true) &&
  address.all (fun c =>
    hexCharOk c || c == ':' || c == '.' || c == 'v' || c == 'V' ||
    uriUnreservedOk c || uriSubDelimOk c)

private def uriPortSuffixOk : List Char → Bool
  | [] => true
  | ':' :: port => uriPortOk port
  | _ => false

private def uriHostPortOk : List Char → Bool
  | '[' :: rest =>
      let address := rest.takeWhile (fun c => c != ']')
      match rest.drop address.length with
      | ']' :: suffix => uriIpLiteralOk address && uriPortSuffixOk suffix
      | _ => false
  | hostPort =>
      let (host, port) := splitAtChar ':' hostPort
      uriRegNameOk host &&
        match port with
        | none => true
        | some digits => uriPortOk digits

private def authorityOk (authority : List Char) : Bool :=
  let (userinfo, hostPort) := splitAtChar '@' authority
  match hostPort with
  | none => uriHostPortOk userinfo
  | some hostPort =>
      !hostPort.any (fun c => c == '@') &&
      uriUserInfoOk userinfo &&
      uriHostPortOk hostPort

private def uriHierPartOk : List Char → Bool
  | '/' :: '/' :: rest =>
      let authority := rest.takeWhile (fun c => c != '/')
      let path := rest.drop authority.length
      authorityOk authority && uriComponentOk false path
  | path => uriComponentOk false path

private def uriTailOk (uri : List Char) : Bool :=
  let (beforeFragment, fragment) := splitAtChar '#' uri
  let (path, query) := splitAtChar '?' beforeFragment
  uriHierPartOk path &&
    (match query with
     | none => true
     | some value => uriComponentOk true value) &&
    (match fragment with
     | none => true
     | some value => uriComponentOk true value)

private def uriSchemeCharOk (c : Char) : Bool :=
  alphaCharOk c || digitCharOk c || c == '+' || c == '-' || c == '.'

private def absoluteUriOk : List Char → Bool
  | [] => false
  | first :: rest =>
      let schemeTail := rest.takeWhile (fun c => c != ':')
      match rest.drop schemeTail.length with
      | ':' :: uri =>
          alphaCharOk first && schemeTail.all uriSchemeCharOk && uriTailOk uri
      | _ => false

private def targetOk (target : String) : Bool :=
  absoluteUriOk target.toList
private def headersOk : List RawHeaderField → Bool
  | [] => true
  | h :: hs => tokenOk h.name && bytesOk h.value && headersOk hs

private def instructionOk (i : HttpWireInstruction) : Bool :=
  tokenOk i.method && targetOk i.target && headersOk i.headers && bytesOk i.body

private def responseOk (r : RawHttpResponse) : Bool :=
  decide (100 ≤ r.status) && decide (r.status ≤ 999) && headersOk r.headers && bytesOk r.body

private def deadlineOk (configuration : HostConfiguration) (deadline : Option Deadline) : Bool :=
  match deadline with
  | none => true
  | some d =>
      decide (d.capability.clockBasis = d.clockBasis) &&
      decide (configuration.monotonicClock = some d.capability)

private def validAttemptInputBool (i : AttemptInput) : Bool :=
  instructionOk i.instruction &&
  decide (i.instruction.body.length ≤ i.configuration.requestBodyLimit) &&
  deadlineOk i.configuration i.deadline

def ValidAttemptInput (i : AttemptInput) : Prop := validAttemptInputBool i = true

def ClockReaches (deadline : Deadline) (observation : MonotonicClockObservation) : Prop :=
  deadline.capability.clockBasis = deadline.clockBasis ∧
  observation.clockBasis = deadline.clockBasis ∧
  deadline.limit ≤ observation.value

instance clockReachesDecidable (deadline : Deadline) (observation : MonotonicClockObservation) :
    Decidable (ClockReaches deadline observation) := by
  unfold ClockReaches
  infer_instance

def EffectMatches (k : AttemptIdentity) (status : EffectStatus) : Prop :=
  match status with
  | .Unknown _ => True
  | .NoEffect witness => witness.attempt = k
  | .EffectOccurred witness => witness.attempt = k

def attemptOf : AdapterObservation → AttemptIdentity
  | .ResponseObservation k _ _ _ _ _ => k
  | .FailureObservation k _ _ _ _ => k
  | .CancellationObservation k _ _ _ => k
  | .DeadlineObservation k _ _ _ _ _ => k

def handleOf : AdapterObservation → ExecutionHandle
  | .ResponseObservation _ h _ _ _ _ => h
  | .FailureObservation _ h _ _ _ => h
  | .CancellationObservation _ h _ _ => h
  | .DeadlineObservation _ h _ _ _ _ => h

def sourceOf : AdapterObservation → SourceSequence
  | .ResponseObservation _ _ source _ _ _ => source
  | .FailureObservation _ _ source _ _ => source
  | .CancellationObservation _ _ source _ => source
  | .DeadlineObservation _ _ source _ _ _ => source

def effectOfObservation : AdapterObservation → EffectStatus
  | .ResponseObservation _ _ _ _ _ effect => effect
  | .FailureObservation _ _ _ _ effect => effect
  | .CancellationObservation _ _ _ effect => effect
  | .DeadlineObservation _ _ _ _ _ effect => effect

def terminalOf : AdapterObservation → NetworkTerminal
  | .ResponseObservation _ _ _ raw provenance effect => { outcome := .Response raw provenance, effect := effect }
  | .FailureObservation _ _ _ failure effect => { outcome := .Failed failure, effect := effect }
  | .CancellationObservation _ _ _ effect => { outcome := .Cancelled, effect := effect }
  | .DeadlineObservation _ _ _ deadline observed effect =>
      { outcome := .DeadlineExceeded deadline observed, effect := effect }

def dispositionHandle : AttemptDisposition → Option ExecutionHandle
  | .Prepared => none
  | .CommandIssued => none
  | .Started handle => some handle
  | .Settled handle _ => handle

def dispositionCondition : AttemptDisposition → AttemptCondition
  | .Prepared => .IsPrepared
  | .CommandIssued => .IsCommandIssued
  | .Started _ => .IsStarted
  | .Settled _ _ => .IsSettled

def isSettled : AttemptDisposition → Bool
  | .Settled _ _ => true
  | _ => false

def terminalOfDisposition : AttemptDisposition → Option NetworkTerminal
  | .Settled _ terminal => some terminal
  | _ => none

private def effectMatchesBool (k : AttemptIdentity) (status : EffectStatus) : Bool :=
  match status with
  | .Unknown _ => true
  | .NoEffect witness => witness.attempt == k
  | .EffectOccurred witness => witness.attempt == k

private def outcomeMatchesAttempt (k : AttemptIdentity) (outcome : NetworkOutcome) : Bool :=
  match outcome with
  | .Failed failure => failure.attempt == k
  | _ => true

private def terminalEvidenceOk (k : AttemptIdentity) (terminal : NetworkTerminal) : Bool :=
  effectMatchesBool k terminal.effect && outcomeMatchesAttempt k terminal.outcome

private def lateEvidenceOk (k : AttemptIdentity) (handle : ExecutionHandle) (previous : Nat)
    : List LateObservation → Bool
  | [] => true
  | late :: rest =>
      decide (previous < late.delivered.delivery) &&
      attemptOf late.delivered.observation == k &&
      handleOf late.delivered.observation == handle &&
      lateEvidenceOk k handle late.delivered.delivery rest

private def recordEvidenceOk (record : AttemptRecord) : Bool :=
  let key := record.input.attempt
  match record.disposition with
  | .Prepared => record.firstDelivery == none && record.late == []
  | .CommandIssued => record.firstDelivery == none && record.late == []
  | .Started _ => record.firstDelivery == none && record.late == []
  | .Settled none terminal =>
      record.firstDelivery == none && record.late == [] && terminalEvidenceOk key terminal
  | .Settled (some handle) terminal =>
      terminalEvidenceOk key terminal &&
      match record.firstDelivery with
      | none => false
      | some first =>
          first.delivery == 0 &&
          attemptOf first.observation == key &&
          handleOf first.observation == handle &&
          lateEvidenceOk key handle first.delivery record.late

private def rootForLogical (records : List AttemptRecord) (logical : RequestIdentity) : Bool :=
  records.any (fun record =>
    record.input.attempt.logical == logical &&
    record.input.attempt.ordinal == 0 &&
    record.lineage == .Root)

private def settledKey (records : List AttemptRecord) (key : AttemptIdentity) : Bool :=
  records.any (fun record => record.input.attempt == key && isSettled record.disposition)

private def lineageOk (records : List AttemptRecord) (record : AttemptRecord) : Bool :=
  rootForLogical records record.input.attempt.logical &&
  match record.lineage with
  | .Root => record.input.attempt.ordinal == 0
  | .RetryOf authorization =>
      authorization.logical == record.input.attempt.logical &&
      authorization.«from».logical == record.input.attempt.logical &&
      authorization.next == record.input.attempt &&
      authorization.next.ordinal == authorization.«from».ordinal + 1 &&
      settledKey records authorization.«from»

private def authorizationUsed (records : List AttemptRecord) (authorization : RetryAuthorization) : Bool :=
  records.any (fun record =>
    match record.lineage with
    | .Root => false
    | .RetryOf candidate => candidate == authorization)

private def authorizationUnique : List AttemptRecord → Bool
  | [] => true
  | record :: rest =>
      (match record.lineage with
       | .Root => true
       | .RetryOf authorization => !authorizationUsed rest authorization) &&
      authorizationUnique rest

private def keysUnique : List AttemptIdentity → Bool
  | [] => true
  | key :: rest => !rest.any (fun candidate => candidate == key) && keysUnique rest

private def recordListEvidence : List AttemptRecord → Bool
  | [] => true
  | record :: rest => recordEvidenceOk record && recordListEvidence rest

private def lineageListEvidence (records : List AttemptRecord) : Bool :=
  records.all (fun record => lineageOk records record)

private def rootsListEvidence (records : List AttemptRecord) : Bool :=
  records.all (fun record => rootForLogical records record.input.attempt.logical)

private def stateInvariantBool (state : NetworkState) : Bool :=
  keysUnique (state.attempts.map (fun record => record.input.attempt)) &&
  recordListEvidence state.attempts &&
  lineageListEvidence state.attempts &&
  rootsListEvidence state.attempts &&
  authorizationUnique state.attempts

def ValidState (state : NetworkState) : Prop := stateInvariantBool state = true

def emptyAttemptIdentity : AttemptIdentity :=
  { logical := { kind := "", provenance := "", revision := 0 }, ordinal := 0 }

private def firstDuplicateViolation : List AttemptRecord → Option NetworkStateViolation
  | [] => none
  | record :: rest =>
      if rest.any (fun candidate => candidate.input.attempt == record.input.attempt) then
        some (.DuplicateAttemptKey record.input.attempt)
      else firstDuplicateViolation rest

private def recordEvidenceViolation (record : AttemptRecord) : Option NetworkStateViolation :=
  if recordEvidenceOk record then none
  else
    match record.disposition with
    | .Prepared | .CommandIssued | .Started _ => some (.DeliveryLogMismatch record.input.attempt)
    | .Settled none _ =>
        if record.firstDelivery == none && record.late == [] then
          some (.DispositionEvidenceMismatch record.input.attempt)
        else some (.DeliveryLogMismatch record.input.attempt)
    | .Settled (some _) terminal =>
        if terminalEvidenceOk record.input.attempt terminal then
          some (.DeliveryLogMismatch record.input.attempt)
        else some (.DispositionEvidenceMismatch record.input.attempt)

private def firstRecordViolation : List AttemptRecord → Option NetworkStateViolation
  | [] => none
  | record :: rest =>
      match recordEvidenceViolation record with
      | some violation => some violation
      | none => firstRecordViolation rest

private def lineageViolation (records : List AttemptRecord)
    (record : AttemptRecord) : Option NetworkStateViolation :=
  if lineageOk records record then none
  else if !rootForLogical records record.input.attempt.logical then
    some (.NonRootFirstAttempt record.input.attempt)
  else
    match record.lineage with
    | .Root => some (.NonRootFirstAttempt record.input.attempt)
    | .RetryOf authorization =>
        if authorization.next.ordinal != authorization.«from».ordinal + 1 then
          some (.OrdinalGap record.input.attempt)
        else some (.LineageMismatch record.input.attempt)

private def firstLineageViolation (records : List AttemptRecord) :
    List AttemptRecord → Option NetworkStateViolation
  | [] => none
  | record :: rest =>
      match lineageViolation records record with
      | some violation => some violation
      | none => firstLineageViolation records rest

private def firstRootViolation (records : List AttemptRecord) :
    List AttemptRecord → Option NetworkStateViolation
  | [] => none
  | record :: rest =>
      if rootForLogical records record.input.attempt.logical then
        firstRootViolation records rest
      else some (.NonRootFirstAttempt record.input.attempt)

private def firstAuthorizationViolation : List AttemptRecord → Option NetworkStateViolation
  | [] => none
  | record :: rest =>
      match record.lineage with
      | .Root => firstAuthorizationViolation rest
      | .RetryOf authorization =>
          if authorizationUsed rest authorization then
            some (.RetryAuthorizationReuse authorization)
          else firstAuthorizationViolation rest

private theorem firstDuplicateViolation_none :
    ∀ records, firstDuplicateViolation records = none →
      keysUnique (records.map (fun record => record.input.attempt)) = true := by
  intro records
  induction records with
  | nil => simp [firstDuplicateViolation, keysUnique]
  | cons record rest ih =>
      simp only [firstDuplicateViolation]
      split
      · simp
      · rename_i unused
        intro none
        have anyFalse :
            (rest.map (fun candidate => candidate.input.attempt)).any
                (fun key => key == record.input.attempt) = false := by
          apply List.any_eq_false.mpr
          intro key keyMember keyEqual
          rcases List.mem_map.mp keyMember with ⟨candidate, candidateMember, rfl⟩
          apply unused
          apply List.any_eq_true.mpr
          exact ⟨candidate, candidateMember, keyEqual⟩
        simp [keysUnique, anyFalse, ih none]

private theorem recordEvidenceViolation_none (record : AttemptRecord) :
    recordEvidenceViolation record = none → recordEvidenceOk record = true := by
  intro equation
  by_cases valid : recordEvidenceOk record = true
  · exact valid
  · have notNone : recordEvidenceViolation record ≠ none := by
      unfold recordEvidenceViolation
      rw [if_neg valid]
      cases disposition : record.disposition with
      | Prepared => simp [disposition]
      | CommandIssued => simp [disposition]
      | Started handle => simp [disposition]
      | Settled handle terminal =>
          cases handle
          · simp [disposition]
            split <;> simp
          · simp [disposition]
            split <;> simp
    exact False.elim (notNone equation)

private theorem firstRecordViolation_none :
    ∀ records, firstRecordViolation records = none → recordListEvidence records = true := by
  intro records
  induction records with
  | nil => simp [firstRecordViolation, recordListEvidence]
  | cons record rest ih =>
      simp only [firstRecordViolation]
      cases found : recordEvidenceViolation record with
      | some violation => simp
      | none =>
          intro none
          simp [recordListEvidence, recordEvidenceViolation_none record found, ih none]

private theorem lineageViolation_none (records : List AttemptRecord) (record : AttemptRecord) :
    lineageViolation records record = none → lineageOk records record = true := by
  intro equation
  by_cases valid : lineageOk records record = true
  · exact valid
  · unfold lineageViolation at equation
    rw [if_neg valid] at equation
    split at equation
    · contradiction
    · cases lineage : record.lineage <;> simp [lineage] at equation
      split at equation <;> contradiction

private theorem firstLineageViolation_none (records : List AttemptRecord) :
    ∀ remaining, firstLineageViolation records remaining = none →
      remaining.all (fun record => lineageOk records record) = true := by
  intro remaining
  induction remaining with
  | nil => simp [firstLineageViolation]
  | cons record rest ih =>
      simp only [firstLineageViolation]
      cases found : lineageViolation records record with
      | some violation => simp
      | none =>
          intro none
          simp [lineageViolation_none records record found, ih none]

private theorem firstRootViolation_none (records : List AttemptRecord) :
    ∀ remaining, firstRootViolation records remaining = none →
      remaining.all (fun record => rootForLogical records record.input.attempt.logical) = true := by
  intro remaining
  induction remaining with
  | nil => simp [firstRootViolation]
  | cons record rest ih =>
      simp only [firstRootViolation]
      split
      · rename_i root
        intro none
        simp [root, ih none]
      · simp

private theorem firstAuthorizationViolation_none :
    ∀ records, firstAuthorizationViolation records = none → authorizationUnique records = true := by
  intro records
  induction records with
  | nil => simp [firstAuthorizationViolation, authorizationUnique]
  | cons record rest ih =>
      cases lineage : record.lineage with
      | Root =>
          intro equation
          have restNone : firstAuthorizationViolation rest = none := by
            simpa only [firstAuthorizationViolation, lineage] using equation
          simp [authorizationUnique, lineage, ih restNone]
      | RetryOf authorization =>
          by_cases used : authorizationUsed rest authorization = true
          · intro equation
            simp [firstAuthorizationViolation, lineage, used] at equation
          · intro equation
            have restNone : firstAuthorizationViolation rest = none := by
              simpa only [firstAuthorizationViolation, lineage, if_neg used] using equation
            simp [authorizationUnique, lineage, used, ih restNone]

def StateViolationMatches (state : NetworkState) (violation : NetworkStateViolation) : Prop :=
  match firstDuplicateViolation state.attempts with
  | some found => found = violation
  | none =>
      match firstRecordViolation state.attempts with
      | some found => found = violation
      | none =>
          match firstLineageViolation state.attempts state.attempts with
          | some found => found = violation
          | none =>
              match firstRootViolation state.attempts state.attempts with
              | some found => found = violation
              | none =>
                  match firstAuthorizationViolation state.attempts with
                  | some found => found = violation
                  | none => False

def stateViolation (state : NetworkState) : NetworkStateViolation :=
  match firstDuplicateViolation state.attempts with
  | some violation => violation
  | none =>
      match firstRecordViolation state.attempts with
      | some violation => violation
      | none =>
          match firstLineageViolation state.attempts state.attempts with
          | some violation => violation
          | none =>
              match firstRootViolation state.attempts state.attempts with
              | some violation => violation
              | none =>
                  match firstAuthorizationViolation state.attempts with
                  | some violation => violation
                  | none => .DuplicateAttemptKey emptyAttemptIdentity

theorem stateViolation_reports_failed_check :
    ∀ state : NetworkState, ¬ ValidState state →
      StateViolationMatches state (stateViolation state) := by
  intro state invalid
  unfold StateViolationMatches stateViolation
  cases duplicate : firstDuplicateViolation state.attempts with
  | some violation => simp
  | none =>
      simp only [duplicate]
      cases record : firstRecordViolation state.attempts with
      | some violation => simp
      | none =>
          simp only [record]
          cases lineage : firstLineageViolation state.attempts state.attempts with
          | some violation => simp
          | none =>
              simp only [lineage]
              cases root : firstRootViolation state.attempts state.attempts with
              | some violation => simp
              | none =>
                  simp only [root]
                  cases authorization : firstAuthorizationViolation state.attempts with
                  | some violation => simp
                  | none =>
                      exfalso
                      apply invalid
                      have keyOk := firstDuplicateViolation_none state.attempts duplicate
                      have recordOk := firstRecordViolation_none state.attempts record
                      have lineageOk' := firstLineageViolation_none state.attempts state.attempts lineage
                      have rootOk := firstRootViolation_none state.attempts state.attempts root
                      have authorizationOk := firstAuthorizationViolation_none state.attempts authorization
                      unfold ValidState stateInvariantBool lineageListEvidence rootsListEvidence
                      simp [keyOk, recordOk, lineageOk', rootOk, authorizationOk]

def lookupAttempt (state : NetworkState) (key : AttemptIdentity) : Option AttemptRecord :=
  state.attempts.find? (fun record => record.input.attempt == key)

def replaceRecord (state : NetworkState) (key : AttemptIdentity)
    (replacement : AttemptRecord) : NetworkState :=
  { attempts := state.attempts.map (fun record => if record.input.attempt = key then replacement else record) }
private theorem findAfterReplace (records : List AttemptRecord) (key : AttemptIdentity)
    (replacement : AttemptRecord) :
    ∀ old, records.find? (fun record => record.input.attempt == key) = some old →
      replacement.input = old.input →
      (records.map (fun record => if record.input.attempt = key then replacement else record)).find?
        (fun record => record.input.attempt == key) = some replacement := by
  intro old found sameInput
  induction records with
  | nil => simp at found
  | cons record rest ih =>
      by_cases same : record.input.attempt = key
      · have recordEq : record = old := by
          have hSome : some record = some old := by simpa [same] using found
          injection hSome with recordEq
        have replacementKey : replacement.input.attempt = key := by
          calc
            replacement.input.attempt = old.input.attempt :=
              congrArg AttemptInput.attempt sameInput
            _ = record.input.attempt := by rw [recordEq]
            _ = key := same
        simp [same, replacementKey]
      · have foundRest : rest.find? (fun item => item.input.attempt == key) = some old := by
          simpa [same] using found
        simpa [same] using ih foundRest

private theorem lookupAttempt_replaceRecord_self (state : NetworkState) (key : AttemptIdentity)
    (replacement existing : AttemptRecord)
    (found : lookupAttempt state key = some existing)
    (sameInput : replacement.input = existing.input) :
    lookupAttempt (replaceRecord state key replacement) key = some replacement := by
  unfold lookupAttempt replaceRecord at *
  exact findAfterReplace state.attempts key replacement existing found sameInput

private theorem lookupAttempt_result_key (state : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (found : lookupAttempt state key = some record) :
    record.input.attempt = key := by
  unfold lookupAttempt at found
  exact beq_iff_eq.mp (List.find?_eq_some_iff_getElem.mp found).1

private theorem findAfterReplaceOther (records : List AttemptRecord)
    (key target : AttemptIdentity) (replacement : AttemptRecord)
    (replacementKey : replacement.input.attempt = key) (different : target ≠ key) :
    (records.map (fun record => if record.input.attempt = key then replacement else record)).find?
        (fun record => record.input.attempt == target) =
      records.find? (fun record => record.input.attempt == target) := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      by_cases recordKey : record.input.attempt = key
      · have recordNotTarget :
            ¬(record.input.attempt == target) = true := by
          intro equal
          exact different ((beq_iff_eq.mp equal).symm.trans recordKey)
        have replacementNotTarget :
            ¬(replacement.input.attempt == target) = true := by
          intro equal
          exact different ((beq_iff_eq.mp equal).symm.trans replacementKey)
        simp only [List.map_cons, if_pos recordKey]
        rw [List.find?_cons_of_neg
              (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
              (a := replacement) replacementNotTarget,
            List.find?_cons_of_neg
              (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
              (a := record) recordNotTarget, ih]
      · simp only [List.map_cons, if_neg recordKey]
        by_cases recordTarget : (record.input.attempt == target) = true
        · rw [List.find?_cons_of_pos
                (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget,
              List.find?_cons_of_pos
                (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget]
        · rw [List.find?_cons_of_neg
                (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget,
              List.find?_cons_of_neg
                (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget, ih]

private theorem lookupAttempt_replaceRecord_other (state : NetworkState)
    (key target : AttemptIdentity) (replacement : AttemptRecord)
    (replacementKey : replacement.input.attempt = key) (different : target ≠ key) :
    lookupAttempt (replaceRecord state key replacement) target = lookupAttempt state target := by
  unfold lookupAttempt replaceRecord
  exact findAfterReplaceOther state.attempts key target replacement replacementKey different

private theorem keysUnique_lookup_member_eq (records : List AttemptRecord)
    (key : AttemptIdentity) (existing candidate : AttemptRecord)
    (unique : keysUnique (records.map (fun record => record.input.attempt)) = true)
    (found : records.find? (fun record => record.input.attempt == key) = some existing)
    (membership : candidate ∈ records) (candidateKey : candidate.input.attempt = key) :
    candidate = existing := by
  induction records with
  | nil => simp at found
  | cons head rest ih =>
      simp [keysUnique] at unique
      rcases unique with ⟨headFresh, restUnique⟩
      by_cases headKey : head.input.attempt = key
      · have headEq : head = existing := by
          simpa [headKey] using found
        rcases List.mem_cons.mp membership with candidateEq | restMember
        · subst candidate
          exact headEq
        · exact False.elim
            (headFresh candidate restMember (candidateKey.trans headKey.symm))
      · have foundRest :
            rest.find? (fun record => record.input.attempt == key) = some existing := by
          simpa [headKey] using found
        rcases List.mem_cons.mp membership with candidateEq | restMember
        · subst candidate
          exact False.elim (headKey candidateKey)
        · exact ih restUnique foundRest restMember

private theorem replaceRecord_input_lineage_projection (state : NetworkState)
    (key : AttemptIdentity) (replacement existing : AttemptRecord)
    (valid : ValidState state) (found : lookupAttempt state key = some existing)
    (sameInput : replacement.input = existing.input)
    (sameLineage : replacement.lineage = existing.lineage) :
    (replaceRecord state key replacement).attempts.map (fun record => (record.input, record.lineage)) =
      state.attempts.map (fun record => (record.input, record.lineage)) := by
  have invariant := valid
  unfold ValidState stateInvariantBool at invariant
  simp only [Bool.and_eq_true] at invariant
  have unique := invariant.1.1.1.1
  have foundList := found
  unfold lookupAttempt at foundList
  unfold replaceRecord
  simp only [List.map_map]
  apply List.map_eq_map_iff.mpr
  intro candidate membership
  by_cases candidateKey : candidate.input.attempt = key
  · have candidateEq :=
      keysUnique_lookup_member_eq state.attempts key existing candidate unique foundList
        membership candidateKey
    subst candidate
    simp [candidateKey, sameInput, sameLineage]
  · simp [candidateKey]

private theorem rootForLogical_projection_congr (left right : List AttemptRecord)
    (projection :
      left.map (fun record => (record.input, record.lineage)) =
        right.map (fun record => (record.input, record.lineage)))
    (logical : RequestIdentity) :
    rootForLogical left logical = rootForLogical right logical := by
  have mapped := congrArg
    (fun values : List (AttemptInput × AttemptLineage) =>
      values.any (fun value =>
        value.1.attempt.logical == logical &&
        value.1.attempt.ordinal == 0 &&
        value.2 == .Root))
    projection
  simpa [rootForLogical, Function.comp_def] using mapped

private theorem authorizationUsed_projection_congr (left right : List AttemptRecord)
    (projection :
      left.map (fun record => (record.input, record.lineage)) =
        right.map (fun record => (record.input, record.lineage)))
    (authorization : RetryAuthorization) :
    authorizationUsed left authorization = authorizationUsed right authorization := by
  have mapped := congrArg
    (fun values : List (AttemptInput × AttemptLineage) =>
      values.any (fun value =>
        match value.2 with
        | .Root => false
        | .RetryOf candidate => candidate == authorization))
    projection
  simpa [authorizationUsed, Function.comp_def] using mapped

private def authorizationUniqueProjection : List (AttemptInput × AttemptLineage) → Bool
  | [] => true
  | value :: rest =>
      (match value.2 with
       | .Root => true
       | .RetryOf authorization =>
           !rest.any (fun candidate =>
             match candidate.2 with
             | .Root => false
             | .RetryOf other => other == authorization)) &&
      authorizationUniqueProjection rest

private theorem authorizationUnique_eq_projection (records : List AttemptRecord) :
    authorizationUnique records =
      authorizationUniqueProjection (records.map (fun record => (record.input, record.lineage))) := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      cases lineage : record.lineage <;>
        simp [authorizationUnique, authorizationUniqueProjection, authorizationUsed, lineage, ih,
          Function.comp_def]



def appendRecord (state : NetworkState) (record : AttemptRecord) : NetworkState :=
  { attempts := state.attempts ++ [record] }

def NoLogicalRecord (state : NetworkState) (logical : RequestIdentity) : Prop :=
  state.attempts.all (fun record => record.input.attempt.logical != logical) = true

def NoAttemptRecord (state : NetworkState) (key : AttemptIdentity) : Prop :=
  state.attempts.all (fun record => record.input.attempt != key) = true

private def commandIssuedMatches (state : NetworkState) (prepared : PreparedAttempt) : Bool :=
  state.attempts.any (fun record =>
    record.input == prepared.input && record.lineage == prepared.lineage &&
    record.disposition == .CommandIssued)

def PreparedRelation (state : NetworkState) (prepared : PreparedAttempt) : Prop :=
  ValidState state ∧
  match lookupAttempt state prepared.input.attempt with
  | some record => record.input = prepared.input ∧ record.lineage = prepared.lineage
  | none => False

def PreparedReady (state : NetworkState) (prepared : PreparedAttempt) : Prop :=
  PreparedRelation state prepared ∧
  match lookupAttempt state prepared.input.attempt with
  | some record => record.disposition = .Prepared
  | none => False

def CommandIssuedRelation (state : NetworkState) (prepared : PreparedAttempt) : Prop :=
  PreparedRelation state prepared ∧
  match lookupAttempt state prepared.input.attempt with
  | some record => record.disposition = .CommandIssued
  | none => False

def StartedRelation (state : NetworkState) (started : StartedAttempt) : Prop :=
  ValidState state ∧
  match lookupAttempt state started.prepared.input.attempt with
  | some record =>
      record.input = started.prepared.input ∧
      record.lineage = started.prepared.lineage ∧
      record.disposition = .Started started.handle ∧
      record.firstDelivery = none ∧
      record.late = []
  | none => False

def AuthoritativePreparedAt (state : NetworkState) (key : AttemptIdentity)
    (prepared : PreparedAttempt) : Prop :=
  prepared.input.attempt = key ∧
  match lookupAttempt state key with
  | some record => record.input = prepared.input ∧ record.lineage = prepared.lineage
  | none => False

def SameExceptDisposition (state state' : NetworkState) (key : AttemptIdentity) : Prop :=
  state' = replaceRecord state key (match lookupAttempt state key with
    | some record => { record with disposition := .CommandIssued }
    | none => { input := { attempt := key, instruction := { method := "", target := "", headers := [], body := [] },
                            deadline := none, configuration := {
                              requestBodyLimit := 0, responseBodyLimit := 0,
                              cancellation := none, monotonicClock := none } },
                 lineage := .Root, disposition := .CommandIssued, firstDelivery := none, late := [] })
private def responseFieldsMatch (record : AttemptRecord) (observation : AdapterObservation) : Bool :=
  match observation with
  | .ResponseObservation _ _ _ response _ _ =>
      responseOk response && decide (response.body.length ≤ record.input.configuration.responseBodyLimit)
  | .CancellationObservation _ _ _ _ => true
  | _ => false

private def failureFieldsMatch (record : AttemptRecord) (observation : AdapterObservation) : Bool :=
  match observation with
  | .FailureObservation key _ _ failure _ =>
      failure.attempt == key && failure.configuration == record.input.configuration &&
      (match failure.cause with
       | .Timeout inner _ => inner == failure.stage
       | _ => true)
  | _ => false

private def deadlineFieldsMatchBool (deadline : Option Deadline)
    (clock : Option MonotonicClockCapability) (observation : AdapterObservation) : Bool :=
  match deadline, clock, observation with
  | some expected, some capability, .DeadlineObservation _ _ _ observedDeadline observedClock _ =>
      expected == observedDeadline && capability == expected.capability &&
      decide (ClockReaches expected observedClock)
  | _, _, _ => false

def ResponseOrCancellationFieldsMatch (record : AttemptRecord) (observation : AdapterObservation) : Prop :=
  responseFieldsMatch record observation = true

def FailureFieldsMatchAttemptStageConfiguration (record : AttemptRecord)
    (observation : AdapterObservation) : Prop :=
  failureFieldsMatch record observation = true

def DeadlineFieldsMatch (deadline : Option Deadline) (clock : Option MonotonicClockCapability)
    (observation : AdapterObservation) : Prop :=
  deadlineFieldsMatchBool deadline clock observation = true

private def observationMatchesRecord (record : AttemptRecord) (observation : AdapterObservation) : Bool :=
  match dispositionHandle record.disposition with
  | none => false
  | some handle =>
      attemptOf observation == record.input.attempt &&
      handleOf observation == handle &&
      effectMatchesBool record.input.attempt (effectOfObservation observation) &&
      (responseFieldsMatch record observation ||
       failureFieldsMatch record observation ||
       deadlineFieldsMatchBool record.input.deadline record.input.configuration.monotonicClock observation)

def ObservationRelation (state : NetworkState) (observation : AdapterObservation) : Prop :=
  ValidState state ∧
  match lookupAttempt state (attemptOf observation) with
  | some record => observationMatchesRecord record observation = true
  | none => False

def HostObservationRelation (state : NetworkState) (observation : HostObservation) : Prop :=
  match observation with
  | .Pending key handle =>
      ValidState state ∧
      match lookupAttempt state key with
      | some record => record.disposition = .Started handle
      | none => False
  | .Delivered _ delivered => ObservationRelation state delivered
def StartObservationRelation (state : NetworkState) (prepared : PreparedAttempt)
    (observation : StartObservation) : Prop :=
  CommandIssuedRelation state prepared ∧
  match observation with
  | .Started key _ => key = prepared.input.attempt
  | .StartFailed failure effect =>
      failure.attempt = prepared.input.attempt ∧
      failure.stage = .Start ∧
      failure.configuration = prepared.input.configuration ∧
      EffectMatches prepared.input.attempt effect

private def preparedTokenFailure (state : NetworkState)
    (prepared : PreparedAttempt) : Option NetworkFailure :=
  match lookupAttempt state prepared.input.attempt with
  | none => some (.UnknownAttempt prepared.input.attempt)
  | some record =>
      if record.input.instruction != prepared.input.instruction then
        some (.AttemptTokenMismatch prepared.input.attempt .Instruction)
      else if record.input.deadline != prepared.input.deadline then
        some (.AttemptTokenMismatch prepared.input.attempt .Deadline)
      else if record.input.configuration != prepared.input.configuration then
        some (.AttemptTokenMismatch prepared.input.attempt .Configuration)
      else if record.lineage != prepared.lineage then
        some (.AttemptTokenMismatch prepared.input.attempt .Lineage)
      else none

private def preparedConditionFailure (state : NetworkState) (prepared : PreparedAttempt)
    (expected : AttemptCondition) : Option NetworkFailure :=
  match preparedTokenFailure state prepared with
  | some failure => some failure
  | none =>
      match lookupAttempt state prepared.input.attempt with
      | none => some (.UnknownAttempt prepared.input.attempt)
      | some record =>
          if dispositionCondition record.disposition = expected then none
          else some (.AttemptConditionMismatch prepared.input.attempt expected
            (dispositionCondition record.disposition))

private def startedTokenFailure (state : NetworkState)
    (started : StartedAttempt) : Option NetworkFailure :=
  match preparedTokenFailure state started.prepared with
  | some failure => some failure
  | none =>
      match lookupAttempt state started.prepared.input.attempt with
      | none => some (.UnknownAttempt started.prepared.input.attempt)
      | some record =>
          match record.disposition with
          | .Started handle =>
              if handle = started.handle then none
              else some (.HandleMismatch handle started.handle)
          | disposition =>
              some (.AttemptConditionMismatch started.prepared.input.attempt .IsStarted
                (dispositionCondition disposition))

private theorem attemptInput_ext (left right : AttemptInput)
    (attempt : left.attempt = right.attempt)
    (instruction : left.instruction = right.instruction)
    (deadline : left.deadline = right.deadline)
    (configuration : left.configuration = right.configuration) :
    left = right := by
  cases left
  cases right
  simp_all

theorem preparedTokenFailure_none_iff :
    ∀ (state : NetworkState) (prepared : PreparedAttempt), ValidState state →
      (preparedTokenFailure state prepared = none ↔ PreparedRelation state prepared) := by
  intro state prepared valid
  unfold preparedTokenFailure
  cases found : lookupAttempt state prepared.input.attempt with
  | none => simp [PreparedRelation, found, valid]
  | some record =>
      have keyEq := lookupAttempt_result_key state prepared.input.attempt record found
      constructor
      · intro noFailure
        by_cases instructionEq : record.input.instruction = prepared.input.instruction
        · by_cases deadlineEq : record.input.deadline = prepared.input.deadline
          · by_cases configurationEq :
                record.input.configuration = prepared.input.configuration
            · by_cases lineageEq : record.lineage = prepared.lineage
              · have inputEq : record.input = prepared.input :=
                  attemptInput_ext record.input prepared.input keyEq instructionEq deadlineEq
                    configurationEq
                exact ⟨valid, by simp [found, inputEq, lineageEq]⟩
              · simp [instructionEq, deadlineEq, configurationEq, lineageEq] at noFailure
            · simp [instructionEq, deadlineEq, configurationEq] at noFailure
          · simp [instructionEq, deadlineEq] at noFailure
        · simp [instructionEq] at noFailure
      · intro relation
        rcases relation with ⟨_, relationFields⟩
        have fields :
            record.input = prepared.input ∧ record.lineage = prepared.lineage := by
          simpa [found] using relationFields
        simp [found, fields.1, fields.2]

private theorem dispositionPrepared_iff (disposition : AttemptDisposition) :
    dispositionCondition disposition = .IsPrepared ↔ disposition = .Prepared := by
  cases disposition <;> simp [dispositionCondition]

private theorem dispositionCommandIssued_iff (disposition : AttemptDisposition) :
    dispositionCondition disposition = .IsCommandIssued ↔ disposition = .CommandIssued := by
  cases disposition <;> simp [dispositionCondition]

theorem preparedReadyFailure_none_iff :
    ∀ (state : NetworkState) (prepared : PreparedAttempt), ValidState state →
      (preparedConditionFailure state prepared .IsPrepared = none ↔ PreparedReady state prepared) := by
  intro state prepared valid
  unfold preparedConditionFailure PreparedReady
  rw [← preparedTokenFailure_none_iff state prepared valid]
  cases fields : preparedTokenFailure state prepared with
  | some failure => simp [fields]
  | none =>
      cases found : lookupAttempt state prepared.input.attempt with
      | none =>
          have impossible : False := by
            have relation := (preparedTokenFailure_none_iff state prepared valid).mp fields
            simpa [PreparedRelation, found] using relation
          exact impossible.elim
      | some record =>
          simpa [fields, found] using dispositionPrepared_iff record.disposition

theorem commandIssuedFailure_none_iff :
    ∀ (state : NetworkState) (prepared : PreparedAttempt), ValidState state →
      (preparedConditionFailure state prepared .IsCommandIssued = none ↔
        CommandIssuedRelation state prepared) := by
  intro state prepared valid
  unfold preparedConditionFailure CommandIssuedRelation
  rw [← preparedTokenFailure_none_iff state prepared valid]
  cases fields : preparedTokenFailure state prepared with
  | some failure => simp [fields]
  | none =>
      cases found : lookupAttempt state prepared.input.attempt with
      | none =>
          have impossible : False := by
            have relation := (preparedTokenFailure_none_iff state prepared valid).mp fields
            simpa [PreparedRelation, found] using relation
          exact impossible.elim
      | some record =>
          simpa [fields, found] using dispositionCommandIssued_iff record.disposition

private theorem recordListEvidence_member (records : List AttemptRecord)
    (record : AttemptRecord) :
    recordListEvidence records = true → record ∈ records → recordEvidenceOk record = true := by
  intro evidence membership
  induction records with
  | nil => simp at membership
  | cons candidate rest ih =>
      simp [recordListEvidence] at evidence
      rcases List.mem_cons.mp membership with same | member
      · subst record
        exact evidence.1
      · exact ih evidence.2 member

private theorem validState_lookup_recordEvidence (state : NetworkState)
    (key : AttemptIdentity) (record : AttemptRecord) :
    ValidState state → lookupAttempt state key = some record → recordEvidenceOk record = true := by
  intro valid found
  have facts := valid
  unfold ValidState stateInvariantBool at facts
  simp at facts
  have member : record ∈ state.attempts := by
    unfold lookupAttempt at found
    exact List.mem_of_find?_eq_some found
  exact recordListEvidence_member state.attempts record facts.1.1.1.2 member

private theorem replaceRecord_attempt_keys (state : NetworkState) (key : AttemptIdentity)
    (replacement : AttemptRecord) (replacementKey : replacement.input.attempt = key) :
    (replaceRecord state key replacement).attempts.map (fun record => record.input.attempt) =
      state.attempts.map (fun record => record.input.attempt) := by
  unfold replaceRecord
  simp only [List.map_map]
  apply List.map_eq_map_iff.mpr
  intro candidate membership
  by_cases same : candidate.input.attempt = key
  · simp [same, replacementKey]
  · simp [same]

private theorem recordListEvidence_replace_true (records : List AttemptRecord)
    (key : AttemptIdentity) (replacement : AttemptRecord)
    (evidence : recordListEvidence records = true)
    (replacementEvidence : recordEvidenceOk replacement = true) :
    recordListEvidence
      (records.map (fun record => if record.input.attempt = key then replacement else record)) = true := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      have oldEvidence :
          recordEvidenceOk record = true ∧ recordListEvidence rest = true := by
        simpa [recordListEvidence] using evidence
      by_cases same : record.input.attempt = key
      · simp [recordListEvidence, same, replacementEvidence, ih oldEvidence.2]
      · simp [recordListEvidence, same, oldEvidence.1, ih oldEvidence.2]

private theorem settledKey_replace_mono (records : List AttemptRecord)
    (key : AttemptIdentity) (replacement : AttemptRecord)
    (replacementKey : replacement.input.attempt = key)
    (replacementSettled : isSettled replacement.disposition = true)
    (target : AttemptIdentity) :
    settledKey records target = true →
      settledKey
        (records.map (fun record => if record.input.attempt = key then replacement else record))
        target = true := by
  intro settled
  unfold settledKey at settled ⊢
  rcases List.any_eq_true.mp settled with ⟨record, membership, condition⟩
  apply List.any_eq_true.mpr
  refine
    ⟨if record.input.attempt = key then replacement else record,
      List.mem_map.mpr ⟨record, membership, rfl⟩, ?_⟩
  by_cases same : record.input.attempt = key
  · have conditionFacts :
        (record.input.attempt == target) = true ∧
          isSettled record.disposition = true := by
      simpa only [Bool.and_eq_true] using condition
    have targetEq : record.input.attempt = target := beq_iff_eq.mp conditionFacts.1
    have keyTarget : key = target := same.symm.trans targetEq
    simp [same, replacementKey, keyTarget, replacementSettled]
  · simpa [same] using condition

private theorem replaceRecord_with_settled_preserves_valid (state : NetworkState)
    (key : AttemptIdentity) (replacement existing : AttemptRecord)
    (valid : ValidState state) (found : lookupAttempt state key = some existing)
    (sameInput : replacement.input = existing.input)
    (sameLineage : replacement.lineage = existing.lineage)
    (replacementEvidence : recordEvidenceOk replacement = true)
    (replacementSettled : isSettled replacement.disposition = true) :
    ValidState (replaceRecord state key replacement) := by
  have invariant := valid
  unfold ValidState stateInvariantBool at invariant
  simp only [Bool.and_eq_true] at invariant
  have keysOld := invariant.1.1.1.1
  have recordsOld := invariant.1.1.1.2
  have lineageOld := invariant.1.1.2
  have rootsOld := invariant.1.2
  have authorizationOld := invariant.2
  have existingKey := lookupAttempt_result_key state key existing found
  have replacementKey : replacement.input.attempt = key := by
    exact (congrArg AttemptInput.attempt sameInput).trans existingKey
  have projection :=
    replaceRecord_input_lineage_projection state key replacement existing valid found
      sameInput sameLineage
  have keysNew :
      keysUnique
        ((replaceRecord state key replacement).attempts.map
          (fun record => record.input.attempt)) = true := by
    rw [replaceRecord_attempt_keys state key replacement replacementKey]
    exact keysOld
  have recordsNew :
      recordListEvidence (replaceRecord state key replacement).attempts = true := by
    exact recordListEvidence_replace_true state.attempts key replacement recordsOld
      replacementEvidence
  have rootsNew :
      rootsListEvidence (replaceRecord state key replacement).attempts = true := by
    unfold rootsListEvidence at rootsOld ⊢
    apply List.all_eq_true.mpr
    intro updated updatedMember
    unfold replaceRecord at updatedMember
    rcases List.mem_map.mp updatedMember with ⟨old, oldMember, rfl⟩
    have oldRoot := List.all_eq_true.mp rootsOld old oldMember
    have rootProjection :=
      rootForLogical_projection_congr (replaceRecord state key replacement).attempts
        state.attempts projection old.input.attempt.logical
    have foundList := found
    unfold lookupAttempt at foundList
    have unique := keysOld
    have inputEq :
        (if old.input.attempt = key then replacement else old).input = old.input := by
      by_cases same : old.input.attempt = key
      · have oldEq :=
          keysUnique_lookup_member_eq state.attempts key existing old unique foundList
            oldMember same
        subst old
        simp [same, sameInput]
      · simp [same]
    rw [inputEq, rootProjection]
    exact oldRoot
  have lineageNew :
      lineageListEvidence (replaceRecord state key replacement).attempts = true := by
    unfold lineageListEvidence at lineageOld ⊢
    apply List.all_eq_true.mpr
    intro updated updatedMember
    unfold replaceRecord at updatedMember
    rcases List.mem_map.mp updatedMember with ⟨old, oldMember, rfl⟩
    have oldLineage := List.all_eq_true.mp lineageOld old oldMember
    have rootProjection :=
      rootForLogical_projection_congr (replaceRecord state key replacement).attempts
        state.attempts projection old.input.attempt.logical
    have foundList := found
    unfold lookupAttempt at foundList
    have unique := keysOld
    have fields :
        (if old.input.attempt = key then replacement else old).input = old.input ∧
        (if old.input.attempt = key then replacement else old).lineage = old.lineage := by
      by_cases same : old.input.attempt = key
      · have oldEq :=
          keysUnique_lookup_member_eq state.attempts key existing old unique foundList
            oldMember same
        subst old
        simp [same, sameInput, sameLineage]
      · simp [same]
    cases oldLineageKind : old.lineage with
    | Root =>
        simpa [lineageOk, oldLineageKind, fields.1, fields.2, rootProjection] using
          oldLineage
    | RetryOf authorization =>
        by_cases oldSettled : settledKey state.attempts authorization.«from» = true
        · have newSettledMap :=
            settledKey_replace_mono state.attempts key replacement replacementKey
              replacementSettled authorization.«from» oldSettled
          have newSettled :
              settledKey (replaceRecord state key replacement).attempts
                authorization.«from» = true := by
            simpa [replaceRecord] using newSettledMap
          simpa [lineageOk, oldLineageKind, fields.1, fields.2, rootProjection,
            oldSettled, newSettled] using oldLineage
        · simp [lineageOk, oldLineageKind, oldSettled] at oldLineage
  have authorizationNew :
      authorizationUnique (replaceRecord state key replacement).attempts = true := by
    calc
      authorizationUnique (replaceRecord state key replacement).attempts =
          authorizationUniqueProjection
            ((replaceRecord state key replacement).attempts.map
              (fun record => (record.input, record.lineage))) :=
        authorizationUnique_eq_projection _
      _ = authorizationUniqueProjection
            (state.attempts.map (fun record => (record.input, record.lineage))) :=
        congrArg authorizationUniqueProjection projection
      _ = authorizationUnique state.attempts :=
        (authorizationUnique_eq_projection state.attempts).symm
      _ = true := authorizationOld
  unfold ValidState stateInvariantBool
  simp only [Bool.and_eq_true]
  exact ⟨⟨⟨⟨keysNew, recordsNew⟩, lineageNew⟩, rootsNew⟩, authorizationNew⟩

theorem startedTokenFailure_none_iff :
    ∀ (state : NetworkState) (started : StartedAttempt), ValidState state →
      (startedTokenFailure state started = none ↔ StartedRelation state started) := by
  intro state started valid
  have preparedIff := preparedTokenFailure_none_iff state started.prepared valid
  constructor
  · intro noFailure
    have fields : preparedTokenFailure state started.prepared = none := by
      unfold startedTokenFailure at noFailure
      cases equation : preparedTokenFailure state started.prepared with
      | none => rfl
      | some failure => simp [equation] at noFailure
    have preparedRelation := preparedIff.mp fields
    rcases preparedRelation with ⟨_, relation⟩
    cases found : lookupAttempt state started.prepared.input.attempt with
    | none => simp [found] at relation
    | some record =>
        have inputLineage :
            record.input = started.prepared.input ∧
              record.lineage = started.prepared.lineage := by
          simpa [found] using relation
        have evidence := validState_lookup_recordEvidence state
          started.prepared.input.attempt record valid found
        unfold startedTokenFailure at noFailure
        rw [fields, found] at noFailure
        cases disposition : record.disposition with
        | Prepared => simp [disposition] at noFailure
        | CommandIssued => simp [disposition] at noFailure
        | Settled handle terminal => simp [disposition] at noFailure
        | Started handle =>
            simp only [disposition] at noFailure
            by_cases sameHandle : handle = started.handle
            · have logs : record.firstDelivery = none ∧ record.late = [] := by
                simpa [recordEvidenceOk, disposition] using evidence
              refine ⟨valid, ?_⟩
              rw [found]
              exact ⟨inputLineage.1, inputLineage.2,
                by simpa [sameHandle] using disposition, logs.1, logs.2⟩
            · simp [sameHandle] at noFailure
  · intro relation
    rcases relation with ⟨_, relationFields⟩
    cases found : lookupAttempt state started.prepared.input.attempt with
    | none => simp [found] at relationFields
    | some record =>
        have fields :
            record.input = started.prepared.input ∧
              record.lineage = started.prepared.lineage ∧
              record.disposition = .Started started.handle ∧
              record.firstDelivery = none ∧ record.late = [] := by
          simpa [found] using relationFields
        have preparedRelation : PreparedRelation state started.prepared := by
          exact ⟨valid, by simpa [found] using ⟨fields.1, fields.2.1⟩⟩
        have preparedNone := preparedIff.mpr preparedRelation
        unfold startedTokenFailure
        simp only [preparedNone, found]
        rw [fields.2.2.1]
        simp

def recordedDelivery (record : AttemptRecord) (delivery : DeliveryOrdinal)
    : Option AdapterObservation :=
  match record.firstDelivery with
  | some first =>
      if first.delivery = delivery then some first.observation
      else
        record.late.find? (fun late => late.delivered.delivery == delivery) |>.map (fun late => late.delivered.observation)
  | none => record.late.find? (fun late => late.delivered.delivery == delivery) |>.map (fun late => late.delivered.observation)

private def lastLate : List LateObservation → Option Nat
  | [] => none
  | late :: rest =>
      match lastLate rest with
      | none => some late.delivered.delivery
      | some value => some value

private def expectedDeliveryOf (record : AttemptRecord) : Nat :=
  match record.firstDelivery with
  | none => 0
  | some first =>
      match lastLate record.late with
      | none => first.delivery + 1
      | some value => value + 1

def RecordedDelivery (state : NetworkState) (key : AttemptIdentity)
    (delivery : DeliveryOrdinal) (observation : AdapterObservation) : Prop :=
  match lookupAttempt state key with
  | some record => recordedDelivery record delivery = some observation
  | none => False

def ExpectedNextDelivery (state : NetworkState) (key : AttemptIdentity)
    (delivery : DeliveryOrdinal) : Prop :=
  match lookupAttempt state key with
  | some record => expectedDeliveryOf record = delivery
  | none => False

instance expectedNextDeliveryDecidable (state : NetworkState) (key : AttemptIdentity)
    (delivery : DeliveryOrdinal) : Decidable (ExpectedNextDelivery state key delivery) := by
  unfold ExpectedNextDelivery
  cases lookupAttempt state key <;> infer_instance

def FirstDeliveryAt (state : NetworkState) (key : AttemptIdentity)
    (delivered : DeliveredObservation) : Prop :=
  match lookupAttempt state key with
  | some record => record.firstDelivery = some delivered
  | none => False

instance firstDeliveryAtDecidable (state : NetworkState) (key : AttemptIdentity)
    (delivered : DeliveredObservation) : Decidable (FirstDeliveryAt state key delivered) := by
  unfold FirstDeliveryAt
  cases lookupAttempt state key <;> infer_instance

def RecordSettled (state : NetworkState) (settled : SettledAttempt) : Prop :=
  ValidState state ∧
  match lookupAttempt state settled.prepared.input.attempt with
  | some record =>
      record.input = settled.prepared.input ∧
      record.lineage = settled.prepared.lineage ∧
      record.disposition = .Settled settled.handle settled.terminal
  | none => False

def TerminalOfRecord (state : NetworkState) (key : AttemptIdentity) : Option NetworkTerminal :=
  match lookupAttempt state key with
  | some record => terminalOfDisposition record.disposition
  | none => none

def InstructionOf (state : NetworkState) (key : AttemptIdentity) : Option HttpWireInstruction :=
  (lookupAttempt state key).map (fun record => record.input.instruction)

def LineageOf (state : NetworkState) (key : AttemptIdentity) : Option AttemptLineage :=
  (lookupAttempt state key).map (fun record => record.lineage)

def EffectOf (state : NetworkState) (key : AttemptIdentity) : Option EffectStatus :=
  (lookupAttempt state key).bind (fun record => terminalOfDisposition record.disposition |>.map (fun terminal => terminal.effect))

def CurrentEffect (state : NetworkState) (key : AttemptIdentity) : Option EffectStatus :=
  match EffectOf state key with
  | some status => some status
  | none => some (.Unknown .NoResponse)

def ExactlyOneRecordAdded (state state' : NetworkState) (key : AttemptIdentity) : Prop :=
  ∃ record, state'.attempts = state.attempts ++ [record] ∧ record.input.attempt = key

def LedgerPrefix (state state' : NetworkState) : Prop :=
  ∃ suffix, state'.attempts = state.attempts ++ suffix

def SameExceptEffect (state state' : NetworkState) (key : AttemptIdentity) : Prop :=
  state.attempts.length = state'.attempts.length ∧
  state.attempts.map (fun record => if record.input.attempt = key then { record with disposition :=
      match record.disposition with
      | .Settled handle terminal => .Settled handle { terminal with effect := .Unknown .NoResponse }
      | disposition => disposition } else record) =
    state'.attempts.map (fun record => if record.input.attempt = key then { record with disposition :=
      match record.disposition with
      | .Settled handle terminal => .Settled handle { terminal with effect := .Unknown .NoResponse }
      | disposition => disposition } else record)

instance validStateDecidable (state : NetworkState) : Decidable (ValidState state) := by
  unfold ValidState
  infer_instance

instance validAttemptInputDecidable (input : AttemptInput) : Decidable (ValidAttemptInput input) := by
  unfold ValidAttemptInput
  infer_instance

instance noLogicalRecordDecidable (state : NetworkState) (logical : RequestIdentity) :
    Decidable (NoLogicalRecord state logical) := by
  unfold NoLogicalRecord
  infer_instance

instance noAttemptRecordDecidable (state : NetworkState) (key : AttemptIdentity) :
    Decidable (NoAttemptRecord state key) := by
  unfold NoAttemptRecord
  infer_instance

instance preparedRelationDecidable (state : NetworkState) (prepared : PreparedAttempt) :
    Decidable (PreparedRelation state prepared) := by
  unfold PreparedRelation
  cases hLookup : lookupAttempt state prepared.input.attempt <;> simp [hLookup] <;> infer_instance

instance preparedReadyDecidable (state : NetworkState) (prepared : PreparedAttempt) :
    Decidable (PreparedReady state prepared) := by
  unfold PreparedReady PreparedRelation
  cases hLookup : lookupAttempt state prepared.input.attempt <;> simp [hLookup] <;> infer_instance

instance commandIssuedRelationDecidable (state : NetworkState) (prepared : PreparedAttempt) :
    Decidable (CommandIssuedRelation state prepared) := by
  unfold CommandIssuedRelation PreparedRelation
  cases hLookup : lookupAttempt state prepared.input.attempt <;> simp [hLookup] <;> infer_instance

instance startedRelationDecidable (state : NetworkState) (started : StartedAttempt) :
    Decidable (StartedRelation state started) := by
  unfold StartedRelation
  cases hLookup : lookupAttempt state started.prepared.input.attempt <;>
    simp [hLookup] <;> infer_instance

instance authoritativePreparedAtDecidable (state : NetworkState) (key : AttemptIdentity)
    (prepared : PreparedAttempt) : Decidable (AuthoritativePreparedAt state key prepared) := by
  unfold AuthoritativePreparedAt
  cases hLookup : lookupAttempt state key <;> simp [hLookup] <;> infer_instance

instance sameExceptDispositionDecidable (state state' : NetworkState) (key : AttemptIdentity) :
    Decidable (SameExceptDisposition state state' key) := by
  unfold SameExceptDisposition
  infer_instance

instance effectMatchesDecidable (key : AttemptIdentity) (status : EffectStatus) :
    Decidable (EffectMatches key status) := by
  unfold EffectMatches
  cases status <;> infer_instance

instance startObservationRelationDecidable (state : NetworkState) (prepared : PreparedAttempt)
    (observation : StartObservation) :
    Decidable (StartObservationRelation state prepared observation) := by
  unfold StartObservationRelation
  cases observation <;> infer_instance

instance observationRelationDecidable (state : NetworkState) (observation : AdapterObservation) :
    Decidable (ObservationRelation state observation) := by
  unfold ObservationRelation
  cases hLookup : lookupAttempt state (attemptOf observation) <;>
    simp [hLookup] <;> infer_instance

instance hostObservationRelationDecidable (state : NetworkState) (observation : HostObservation) :
    Decidable (HostObservationRelation state observation) := by
  unfold HostObservationRelation
  cases observation with
  | Pending key handle =>
      cases hLookup : lookupAttempt state key <;> simp [hLookup] <;> infer_instance
  | Delivered delivery delivered =>
      infer_instance



instance deadlineFieldsMatchDecidable (deadline : Option Deadline)
    (clock : Option MonotonicClockCapability) (observation : AdapterObservation) :
    Decidable (DeadlineFieldsMatch deadline clock observation) := by
  unfold DeadlineFieldsMatch
  infer_instance

instance sameExceptEffectDecidable (state state' : NetworkState) (key : AttemptIdentity) :
    Decidable (SameExceptEffect state state' key) := by
  unfold SameExceptEffect
  infer_instance

def EffectStatusCertainty : EffectStatus → Prop
  | .Unknown _ => False
  | .NoEffect _ => True
  | .EffectOccurred _ => True

def Certainty := EffectStatusCertainty

def MatchingIndependentWitness (key : AttemptIdentity) (witness : EffectWitness) : Prop :=
  witness.attempt = key

def TerminalForAttempt (key : AttemptIdentity) (terminal : NetworkTerminal) : Prop :=
  EffectMatches key terminal.effect

def OutcomeNeedsIndependentWitness (_ : NetworkOutcome) : Prop := True

def CancelOrDeadlineOutcome : NetworkOutcome → Prop
  | .Cancelled => True
  | .DeadlineExceeded _ _ => True
  | _ => False

def EqualExceptSourceSequence (left right : AdapterObservation) : Prop :=
  let erase : AdapterObservation → AdapterObservation
    | .ResponseObservation key handle _ raw provenance effect =>
        .ResponseObservation key handle .none raw provenance effect
    | .FailureObservation key handle _ failure effect =>
        .FailureObservation key handle .none failure effect
    | .CancellationObservation key handle _ effect =>
        .CancellationObservation key handle .none effect
    | .DeadlineObservation key handle _ deadline clock effect =>
        .DeadlineObservation key handle .none deadline clock effect
  erase left = erase right

def ResponseKind : AdapterObservation → Prop
  | .ResponseObservation _ _ _ _ _ _ => True
  | _ => False

def CancellationKind : AdapterObservation → Prop
  | .CancellationObservation _ _ _ _ => True
  | _ => False

def ValidDeadlineKind : AdapterObservation → Prop
  | .DeadlineObservation _ _ _ _ _ _ => True
  | _ => False

def FailureKind : AdapterObservation → Prop
  | .FailureObservation _ _ _ _ _ => True
  | _ => False

instance equalExceptSourceSequenceDecidable (left right : AdapterObservation) :
    Decidable (EqualExceptSourceSequence left right) := by
  unfold EqualExceptSourceSequence
  infer_instance

instance responseKindDecidable (observation : AdapterObservation) :
    Decidable (ResponseKind observation) := by
  cases observation <;> unfold ResponseKind <;> infer_instance

instance cancellationKindDecidable (observation : AdapterObservation) :
    Decidable (CancellationKind observation) := by
  cases observation <;> unfold CancellationKind <;> infer_instance

instance validDeadlineKindDecidable (observation : AdapterObservation) :
    Decidable (ValidDeadlineKind observation) := by
  cases observation <;> unfold ValidDeadlineKind <;> infer_instance

instance failureKindDecidable (observation : AdapterObservation) :
    Decidable (FailureKind observation) := by
  cases observation <;> unfold FailureKind <;> infer_instance

def assignDeliveries : Nat → List AdapterObservation → List HostObservation
  | _, [] => []
  | ordinal, observation :: rest => .Delivered ordinal observation :: assignDeliveries (ordinal + 1) rest

def AssignContiguousDelivery (observations : List AdapterObservation) : List HostObservation :=
  assignDeliveries 0 observations

private def assignOrderedLate : Nat → List AdapterObservation → List LateObservation
  | _, [] => []
  | delivery, observation :: rest =>
      { delivered := { delivery := delivery, observation := observation } } ::
        assignOrderedLate (delivery + 1) rest

def OneWinnerAndOrderedLate (observations : List AdapterObservation) (state : NetworkState) : Prop :=
  match observations with
  | [] => False
  | winner :: later =>
      ∃ record : AttemptRecord,
        lookupAttempt state (attemptOf winner) = some record ∧
        record.disposition = .Settled (some (handleOf winner)) (terminalOf winner) ∧
        record.firstDelivery = some { delivery := 0, observation := winner } ∧
        record.late = assignOrderedLate 1 later

def NoRemoteEffectWitness (status : EffectStatus) : Prop :=
  match status with
  | .Unknown _ => True
  | .NoEffect witness => witness.source = .Adapter ∨ witness.source = .Protocol
  | .EffectOccurred witness => witness.source = .Adapter ∨ witness.source = .Protocol

private def appendLate (state : NetworkState) (key : AttemptIdentity) (late : LateObservation) : NetworkState :=
  match lookupAttempt state key with
  | some record => replaceRecord state key { record with late := record.late ++ [late] }
  | none => state

private theorem replaceRecord_attempts_nonempty (state : NetworkState) (key : AttemptIdentity)
    (replacement : AttemptRecord) (nonempty : state.attempts ≠ []) :
    (replaceRecord state key replacement).attempts ≠ [] := by
  simpa [replaceRecord] using nonempty

private theorem appendLate_attempts_nonempty (state : NetworkState) (key : AttemptIdentity)
    (late : LateObservation) (nonempty : state.attempts ≠ []) :
    (appendLate state key late).attempts ≠ [] := by
  unfold appendLate
  split
  · exact replaceRecord_attempts_nonempty state key _ nonempty
  · exact nonempty

private theorem appendLate_attempts_length (state : NetworkState) (key : AttemptIdentity)
    (late : LateObservation) :
    (appendLate state key late).attempts.length = state.attempts.length := by
  unfold appendLate
  split <;> simp [replaceRecord]

private theorem appendLate_preserves_projections (state : NetworkState)
    (modified target : AttemptIdentity) (late : LateObservation) :
    TerminalOfRecord (appendLate state modified late) target = TerminalOfRecord state target ∧
    InstructionOf (appendLate state modified late) target = InstructionOf state target ∧
    LineageOf (appendLate state modified late) target = LineageOf state target ∧
    EffectOf (appendLate state modified late) target = EffectOf state target := by
  cases hLookup : lookupAttempt state modified with
  | none =>
      simp [appendLate, hLookup]
  | some record =>
      let updated : AttemptRecord := { record with late := record.late ++ [late] }
      have updatedKey : updated.input.attempt = modified := by
        exact lookupAttempt_result_key state modified record hLookup
      by_cases same : target = modified
      · subst target
        have hUpdated : lookupAttempt (replaceRecord state modified updated) modified = some updated := by
          apply lookupAttempt_replaceRecord_self state modified updated record hLookup
          rfl
        simp [appendLate, hLookup, TerminalOfRecord, InstructionOf, LineageOf, EffectOf,
          hUpdated, updated]
      · have hUpdated :
            lookupAttempt (replaceRecord state modified updated) target = lookupAttempt state target := by
          exact lookupAttempt_replaceRecord_other state modified target updated updatedKey same
        simp only [appendLate, hLookup]
        unfold TerminalOfRecord InstructionOf LineageOf EffectOf
        rw [hUpdated]
        exact ⟨rfl, rfl, rfl, rfl⟩

private theorem firstDelivery_recordEvidence (record : AttemptRecord)
    (handle : ExecutionHandle) (observation : AdapterObservation)
    (disposition : record.disposition = .Started handle)
    (relation : observationMatchesRecord record observation = true) :
    recordEvidenceOk
      { input := record.input, lineage := record.lineage,
        disposition := .Settled (some handle) (terminalOf observation),
        firstDelivery := some { delivery := 0, observation := observation }, late := [] } = true := by
  cases observation with
  | ResponseObservation key observedHandle source raw provenance effect =>
      simp [observationMatchesRecord, disposition, dispositionHandle, recordEvidenceOk,
        terminalEvidenceOk, terminalOf, outcomeMatchesAttempt, responseFieldsMatch,
        failureFieldsMatch, deadlineFieldsMatchBool, effectMatchesBool, effectOfObservation,
        attemptOf, handleOf, lateEvidenceOk] at relation ⊢
      exact
        ⟨by simpa using relation.1.2,
          by simpa using relation.1.1.1,
          by simpa using relation.1.1.2⟩
  | FailureObservation key observedHandle source failure effect =>
      simp [observationMatchesRecord, disposition, dispositionHandle, recordEvidenceOk,
        terminalEvidenceOk, terminalOf, outcomeMatchesAttempt, responseFieldsMatch,
        failureFieldsMatch, deadlineFieldsMatchBool, effectMatchesBool, effectOfObservation,
        attemptOf, handleOf, lateEvidenceOk] at relation ⊢
      exact
        ⟨⟨by simpa using relation.1.2,
            relation.2.1.1.trans relation.1.1.1⟩,
          by simpa using relation.1.1.1,
          by simpa using relation.1.1.2⟩
  | CancellationObservation key observedHandle source effect =>
      simp [observationMatchesRecord, disposition, dispositionHandle, recordEvidenceOk,
        terminalEvidenceOk, terminalOf, outcomeMatchesAttempt, responseFieldsMatch,
        failureFieldsMatch, deadlineFieldsMatchBool, effectMatchesBool, effectOfObservation,
        attemptOf, handleOf, lateEvidenceOk] at relation ⊢
      exact
        ⟨by simpa using relation.2,
          by simpa using relation.1.1,
          by simpa using relation.1.2⟩
  | DeadlineObservation key observedHandle source deadline clock effect =>
      simp [observationMatchesRecord, disposition, dispositionHandle, recordEvidenceOk,
        terminalEvidenceOk, terminalOf, outcomeMatchesAttempt, responseFieldsMatch,
        failureFieldsMatch, deadlineFieldsMatchBool, effectMatchesBool, effectOfObservation,
        attemptOf, handleOf, lateEvidenceOk] at relation ⊢
      exact
        ⟨by simpa using relation.1.2,
          by simpa using relation.1.1.1,
          by simpa using relation.1.1.2⟩

private def nextLateDelivery (previous : DeliveryOrdinal)
    (late : List LateObservation) : DeliveryOrdinal :=
  match lastLate late with
  | none => previous + 1
  | some delivery => delivery + 1

private theorem nextLateDelivery_cons (previous : DeliveryOrdinal)
    (item : LateObservation) (rest : List LateObservation) :
    nextLateDelivery previous (item :: rest) =
      nextLateDelivery item.delivered.delivery rest := by
  unfold nextLateDelivery
  simp only [lastLate]
  cases lastLate rest <;> rfl

private theorem lateEvidenceOk_append_next (key : AttemptIdentity)
    (handle : ExecutionHandle) (previous : DeliveryOrdinal)
    (late : List LateObservation) (observation : AdapterObservation)
    (oldEvidence : lateEvidenceOk key handle previous late = true)
    (attemptEq : attemptOf observation = key)
    (handleEq : handleOf observation = handle) :
    lateEvidenceOk key handle previous
      (late ++
        [{ delivered :=
            { delivery := nextLateDelivery previous late, observation := observation } }]) = true := by
  induction late generalizing previous with
  | nil =>
      simp [nextLateDelivery, lastLate, lateEvidenceOk, attemptEq, handleEq]
  | cons item rest ih =>
      rw [nextLateDelivery_cons previous item rest]
      simp only [List.cons_append, lateEvidenceOk, Bool.and_eq_true] at oldEvidence ⊢
      exact
        ⟨⟨⟨oldEvidence.1.1.1, oldEvidence.1.1.2⟩, oldEvidence.1.2⟩,
          ih item.delivered.delivery oldEvidence.2⟩

private theorem appendLate_recordEvidence (record : AttemptRecord)
    (handle : ExecutionHandle) (terminal : NetworkTerminal)
    (observation : AdapterObservation)
    (disposition : record.disposition = .Settled (some handle) terminal)
    (oldEvidence : recordEvidenceOk record = true)
    (relation : observationMatchesRecord record observation = true) :
    recordEvidenceOk
      { record with
        late := record.late ++
          [{ delivered :=
              { delivery :=
                  match record.firstDelivery with
                  | none => 0
                  | some first => nextLateDelivery first.delivery record.late,
                observation := observation } }] } = true := by
  have relationFacts := relation
  unfold observationMatchesRecord at relationFacts
  rw [disposition] at relationFacts
  simp only [dispositionHandle, Bool.and_eq_true] at relationFacts
  have attemptEq : attemptOf observation = record.input.attempt :=
    beq_iff_eq.mp relationFacts.1.1.1
  have handleEq : handleOf observation = handle :=
    beq_iff_eq.mp relationFacts.1.1.2
  cases firstEq : record.firstDelivery with
  | none =>
      simp [recordEvidenceOk, disposition, firstEq] at oldEvidence
  | some first =>
      have oldFacts := oldEvidence
      simp only [recordEvidenceOk, disposition, firstEq, Bool.and_eq_true] at oldFacts
      have lateEvidence :=
        lateEvidenceOk_append_next record.input.attempt handle first.delivery record.late
          observation oldFacts.2.2 attemptEq handleEq
      simp only [recordEvidenceOk, disposition, firstEq, Bool.and_eq_true]
      exact ⟨oldFacts.1, ⟨oldFacts.2.1, lateEvidence⟩⟩

private theorem firstDelivery_update_valid (state : NetworkState)
    (started : StartedAttempt) (record : AttemptRecord)
    (observation : AdapterObservation)
    (valid : ValidState state)
    (found : lookupAttempt state started.prepared.input.attempt = some record)
    (recordInput : record.input = started.prepared.input)
    (recordLineage : record.lineage = started.prepared.lineage)
    (disposition : record.disposition = .Started started.handle)
    (relation : ObservationRelation state observation)
    (attemptEq : attemptOf observation = started.prepared.input.attempt)
    (handleEq : handleOf observation = started.handle) :
    ValidState
      (replaceRecord state started.prepared.input.attempt
        { input := record.input, lineage := record.lineage,
          disposition := .Settled (some started.handle) (terminalOf observation),
          firstDelivery := some { delivery := 0, observation := observation }, late := [] }) := by
  have relationFields : observationMatchesRecord record observation = true := by
    rcases relation with ⟨_, relationMatch⟩
    simpa [attemptEq, found] using relationMatch
  let replacement : AttemptRecord :=
    { input := record.input, lineage := record.lineage,
      disposition := .Settled (some started.handle) (terminalOf observation),
      firstDelivery := some { delivery := 0, observation := observation }, late := [] }
  have replacementEvidence : recordEvidenceOk replacement = true := by
    exact firstDelivery_recordEvidence record started.handle observation disposition relationFields
  exact replaceRecord_with_settled_preserves_valid state started.prepared.input.attempt
    replacement record valid found rfl rfl replacementEvidence rfl

private theorem appendLate_expected_valid (state : NetworkState)
    (key : AttemptIdentity) (record : AttemptRecord)
    (handle : ExecutionHandle) (terminal : NetworkTerminal)
    (observation : AdapterObservation)
    (valid : ValidState state) (found : lookupAttempt state key = some record)
    (disposition : record.disposition = .Settled (some handle) terminal)
    (relation : ObservationRelation state observation)
    (attemptEq : attemptOf observation = key)
    (handleEq : handleOf observation = handle) :
    ValidState
      (appendLate state key
        { delivered :=
            { delivery := expectedDeliveryOf record, observation := observation } }) := by
  have oldEvidence := validState_lookup_recordEvidence state key record valid found
  have relationFields : observationMatchesRecord record observation = true := by
    rcases relation with ⟨_, relationMatch⟩
    simpa [attemptEq, found] using relationMatch
  let replacement : AttemptRecord :=
    { record with
      late := record.late ++
        [{ delivered :=
            { delivery := expectedDeliveryOf record, observation := observation } }] }
  have replacementEvidence : recordEvidenceOk replacement = true := by
    have evidence :=
      appendLate_recordEvidence record handle terminal observation disposition oldEvidence relationFields
    simpa [replacement, expectedDeliveryOf, nextLateDelivery] using evidence
  have replacementValid :=
    replaceRecord_with_settled_preserves_valid state key replacement record valid found
      rfl rfl replacementEvidence (by simp [replacement, disposition, isSettled])
  simpa [appendLate, found, replacement] using replacementValid

private theorem observationMatchesRecord_congr (left right : AttemptRecord)
    (observation : AdapterObservation) (sameInput : left.input = right.input)
    (sameHandle : dispositionHandle left.disposition = dispositionHandle right.disposition) :
    observationMatchesRecord left observation = observationMatchesRecord right observation := by
  cases observation <;>
    simp [observationMatchesRecord, responseFieldsMatch, failureFieldsMatch,
      deadlineFieldsMatchBool, sameInput, sameHandle]

private theorem lastLate_append_singleton (late : List LateObservation)
    (item : LateObservation) :
    lastLate (late ++ [item]) = some item.delivered.delivery := by
  induction late with
  | nil => rfl
  | cons head rest ih =>
      simp only [List.cons_append, lastLate]
      rw [ih]

private theorem lateEvidenceOk_lt_next (key : AttemptIdentity)
    (handle : ExecutionHandle) (previous : DeliveryOrdinal)
    (late : List LateObservation)
    (evidence : lateEvidenceOk key handle previous late = true) :
    previous < nextLateDelivery previous late := by
  induction late generalizing previous with
  | nil =>
      simp [nextLateDelivery, lastLate]
  | cons item rest ih =>
      simp only [lateEvidenceOk, Bool.and_eq_true] at evidence
      have headOrder : previous < item.delivered.delivery := by
        simpa using evidence.1.1.1
      rw [nextLateDelivery_cons previous item rest]
      exact Nat.lt_trans headOrder (ih item.delivered.delivery evidence.2)

private theorem lateEvidenceOk_find_next_none (key : AttemptIdentity)
    (handle : ExecutionHandle) (previous : DeliveryOrdinal)
    (late : List LateObservation)
    (evidence : lateEvidenceOk key handle previous late = true) :
    late.find? (fun item =>
      item.delivered.delivery == nextLateDelivery previous late) = none := by
  induction late generalizing previous with
  | nil => rfl
  | cons item rest ih =>
      simp only [lateEvidenceOk, Bool.and_eq_true] at evidence
      rw [nextLateDelivery_cons previous item rest]
      have itemOrder :=
        lateEvidenceOk_lt_next key handle item.delivered.delivery rest evidence.2
      have itemNe :
          ¬ item.delivered.delivery = nextLateDelivery item.delivered.delivery rest :=
        Nat.ne_of_lt itemOrder
      simp [itemNe, ih item.delivered.delivery evidence.2]

private theorem recordedDelivery_expected_none (record : AttemptRecord)
    (handle : ExecutionHandle) (terminal : NetworkTerminal)
    (disposition : record.disposition = .Settled (some handle) terminal)
    (evidence : recordEvidenceOk record = true) :
    recordedDelivery record (expectedDeliveryOf record) = none := by
  cases firstEq : record.firstDelivery with
  | none =>
      simp [recordEvidenceOk, disposition, firstEq] at evidence
  | some first =>
      have facts := evidence
      simp only [recordEvidenceOk, disposition, firstEq, Bool.and_eq_true] at facts
      have firstOrder :=
        lateEvidenceOk_lt_next record.input.attempt handle first.delivery record.late facts.2.2
      have firstNe : ¬ first.delivery = nextLateDelivery first.delivery record.late :=
        Nat.ne_of_lt firstOrder
      have findNone :=
        lateEvidenceOk_find_next_none record.input.attempt handle first.delivery
          record.late facts.2.2
      have expectedEq :
          expectedDeliveryOf record = nextLateDelivery first.delivery record.late := by
        simp [expectedDeliveryOf, firstEq, nextLateDelivery]
      rw [expectedEq]
      unfold recordedDelivery
      rw [firstEq]
      simp [firstNe, findNone]

private def setEffect (state : NetworkState) (key : AttemptIdentity) (status : EffectStatus) : NetworkState :=
  match lookupAttempt state key with
  | some record =>
      match record.disposition with
      | .Settled handle terminal =>
          replaceRecord state key { record with disposition := .Settled handle { terminal with effect := status } }
      | _ => state
  | none => state

def readNetworkState (state : NetworkState) : ReadStateStep :=
  if _ : ValidState state then .Read state
  else .Rejected state (.InvalidNetworkState (stateViolation state))

def prepare (state : NetworkState) (input : AttemptInput) : PrepareStep :=
  if _ : ValidState state then
    if _ : ValidAttemptInput input then
      if hordinal : input.attempt.ordinal = 0 then
        if hlogical : NoLogicalRecord state input.attempt.logical then
          let prepared : PreparedAttempt := { input := input, lineage := .Root }
          let record : AttemptRecord :=
            { input := input, lineage := .Root, disposition := .Prepared,
              firstDelivery := none, late := [] }
          let next := appendRecord state record
          if _ : ValidState next then
            if _ : PreparedRelation next prepared then
              .Prepared next prepared
            else .Rejected state (.InvalidNetworkState (stateViolation next))
          else .Rejected state (.InvalidNetworkState (stateViolation next))
        else .Rejected state (.DuplicateAttempt input.attempt)
      else .Rejected state (.RootAttemptRequired input.attempt)
    else .Rejected state (.InvalidWireInstruction input.instruction.method)
  else .Rejected state (.InvalidNetworkState (stateViolation state))

def sendCommand (state : NetworkState) (prepared : PreparedAttempt) : CommandStep SendCommand :=
  if hissued : commandIssuedMatches state prepared then
    .Rejected state (.CommandAlreadyIssued prepared.input.attempt)
  else if hready : PreparedReady state prepared then
    let next := replaceRecord state prepared.input.attempt
      (match lookupAttempt state prepared.input.attempt with
       | some record => { record with disposition := .CommandIssued }
       | none => { input := prepared.input, lineage := prepared.lineage, disposition := .CommandIssued,
                   firstDelivery := none, late := [] })
    let command : SendCommand := { prepared := prepared }
    if _ : ValidState next then .CommandReady next command
    else .Rejected state (.InvalidNetworkState (stateViolation next))
  else if _ : ValidState state then
    match preparedConditionFailure state prepared .IsPrepared with
    | some mismatch => .Rejected state mismatch
    | none => .Rejected state (.AttemptConditionMismatch prepared.input.attempt .IsPrepared .IsPrepared)
  else .Rejected state (.InvalidNetworkState (stateViolation state))

private theorem find_none_member_predicate_false {α : Type}
    (predicate : α → Bool) (records : List α) (candidate : α)
    (found : records.find? predicate = none) (membership : candidate ∈ records) :
    predicate candidate = false := by
  induction records with
  | nil => simp at membership
  | cons head rest ih =>
      cases equation : predicate head with
      | false =>
          have foundRest : rest.find? predicate = none := by
            simpa [equation] using found
          rcases List.mem_cons.mp membership with same | restMember
          · subst candidate
            exact equation
          · exact ih foundRest restMember
      | true =>
          simp [equation] at found

theorem sendCommand_unknown_attempt_rejected :
    ∀ (state : NetworkState) (prepared : PreparedAttempt),
      ValidState state →
      lookupAttempt state prepared.input.attempt = none →
      sendCommand state prepared =
        .Rejected state (.UnknownAttempt prepared.input.attempt) := by
  intro state prepared valid missing
  have missingList := missing
  unfold lookupAttempt at missingList
  have notIssued : commandIssuedMatches state prepared = false := by
    unfold commandIssuedMatches
    apply List.any_eq_false.mpr
    intro record membership
    have keyFalse :=
      find_none_member_predicate_false
        (fun candidate : AttemptRecord =>
          candidate.input.attempt == prepared.input.attempt)
        state.attempts record missingList membership
    have inputNe : record.input ≠ prepared.input := by
      intro inputEq
      have keyEq := congrArg AttemptInput.attempt inputEq
      have keyTrue :
          (record.input.attempt == prepared.input.attempt) = true :=
        beq_iff_eq.mpr keyEq
      rw [keyFalse] at keyTrue
      contradiction
    simp [inputNe]
  have notReady : ¬ PreparedReady state prepared := by
    simp [PreparedReady, PreparedRelation, missing]
  simp [sendCommand, notIssued, notReady, valid, preparedConditionFailure,
    preparedTokenFailure, missing]

def cancelCommand (state : NetworkState) (started : StartedAttempt) : CommandStep CancelCommand :=
  if hstarted : StartedRelation state started then
    match started.prepared.input.configuration.cancellation with
    | none => .Rejected state (.RequiredCapabilityUnavailable started.prepared.input.attempt .Cancellation)
    | some capability =>
        let command : CancelCommand :=
          { attempt := started.prepared.input.attempt, handle := started.handle, capability := capability }
        .CommandReady state command
  else if _ : ValidState state then
    match startedTokenFailure state started with
    | some mismatch => .Rejected state mismatch
    | none => .Rejected state (.AttemptConditionMismatch started.prepared.input.attempt .IsStarted .IsStarted)
  else .Rejected state (.InvalidNetworkState (stateViolation state))

def observeStart (state : NetworkState) (prepared : PreparedAttempt)
    (observation : StartObservation) : NetworkStep :=
  if hrelation : StartObservationRelation state prepared observation then
    match observation with
    | .Started key handle =>
        let started : StartedAttempt := { prepared := prepared, handle := handle }
        let next := replaceRecord state key
          (match lookupAttempt state key with
           | some record => { record with disposition := .Started handle }
           | none => { input := prepared.input, lineage := prepared.lineage, disposition := .Started handle,
                       firstDelivery := none, late := [] })
        if _ : ValidState next then
          if _ : StartedRelation next started then .Started next started
          else .Rejected state (.InvalidNetworkState (stateViolation next))
        else .Rejected state (.InvalidNetworkState (stateViolation next))
    | .StartFailed failure effect =>
        let terminal : NetworkTerminal := { outcome := .Failed failure, effect := effect }
        let settled : SettledAttempt := { prepared := prepared, handle := none, terminal := terminal }
        let next := replaceRecord state prepared.input.attempt
          (match lookupAttempt state prepared.input.attempt with
           | some record => { record with disposition := .Settled none terminal }
           | none => { input := prepared.input, lineage := prepared.lineage, disposition := .Settled none terminal,
                       firstDelivery := none, late := [] })
        if _ : ValidState next then .Terminal next settled
        else .Rejected state (.InvalidNetworkState (stateViolation next))
  else if valid : ValidState state then
    match preparedConditionFailure state prepared .IsCommandIssued with
    | some failure => .Rejected state failure
    | none =>
        match observation with
        | .Started key _ =>
            .Rejected state (.IdentityMismatch prepared.input.attempt key)
        | .StartFailed failure effect =>
            if failure.attempt != prepared.input.attempt then
              .Rejected state (.IdentityMismatch prepared.input.attempt failure.attempt)
            else if failure.stage != .Start then
              .Rejected state (.ObservationRelationMismatch prepared.input.attempt .FailureStage)
            else if failure.configuration != prepared.input.configuration then
              .Rejected state (.ObservationRelationMismatch prepared.input.attempt .FailureConfiguration)
            else .Rejected state (.ObservationRelationMismatch prepared.input.attempt .EffectWitnessValue)
  else .Rejected state (.InvalidNetworkState (stateViolation state))

def LatePreservation (state state' : NetworkState) (settled settled' : SettledAttempt)
    (delivery : DeliveryOrdinal) (observation : AdapterObservation) (late : LateObservation) : Prop :=
  TerminalOfRecord state' settled.prepared.input.attempt =
      TerminalOfRecord state settled.prepared.input.attempt ∧
  InstructionOf state' settled.prepared.input.attempt =
      InstructionOf state settled.prepared.input.attempt ∧
  LineageOf state' settled.prepared.input.attempt =
      LineageOf state settled.prepared.input.attempt ∧
  EffectOf state' settled.prepared.input.attempt =
      EffectOf state settled.prepared.input.attempt

instance latePreservationDecidable (state state' : NetworkState) (settled settled' : SettledAttempt)
    (delivery : DeliveryOrdinal) (observation : AdapterObservation) (late : LateObservation) :
    Decidable (LatePreservation state state' settled settled' delivery observation late) := by
  unfold LatePreservation
  infer_instance
private inductive HostObservationRejection where
  | unknown : AttemptIdentity → HostObservationRejection
  | condition : AttemptIdentity → AttemptCondition → AttemptCondition → HostObservationRejection
  | handle : ExecutionHandle → ExecutionHandle → HostObservationRejection
  | effect : AttemptIdentity → HostObservationRejection
  | malformed
  | identity : AttemptIdentity → AttemptIdentity → HostObservationRejection
  | observation : AttemptIdentity → ObservationField → HostObservationRejection
  | clockBasis : ClockBasis → ClockBasis → HostObservationRejection
  | deadlineNotReached : Deadline → MonotonicClockObservation → HostObservationRejection

private def HostObservationRejection.failure : HostObservationRejection → NetworkFailure
  | .unknown key => .UnknownAttempt key
  | .condition key expected actual => .AttemptConditionMismatch key expected actual
  | .handle expected actual => .HandleMismatch expected actual
  | .effect key => .EffectWitnessMissing key
  | .malformed => .MalformedAdapterObservation
  | .identity expected actual => .IdentityMismatch expected actual
  | .observation key field => .ObservationRelationMismatch key field
  | .clockBasis expected actual => .ClockBasisMismatch expected actual
  | .deadlineNotReached deadline observedAt => .DeadlineNotReached deadline observedAt

private def adapterObservationRejection (state : NetworkState)
    (observation : AdapterObservation) : HostObservationRejection :=
  let key := attemptOf observation
  match lookupAttempt state key with
  | none => .unknown key
  | some record =>
      match dispositionHandle record.disposition with
      | none => .condition key .IsStarted (dispositionCondition record.disposition)
      | some expectedHandle =>
          if handleOf observation != expectedHandle then
            .handle expectedHandle (handleOf observation)
          else if !effectMatchesBool key (effectOfObservation observation) then
            .effect key
          else
            match observation with
            | .ResponseObservation _ _ _ _ _ _ => .malformed
            | .CancellationObservation _ _ _ _ => .malformed
            | .FailureObservation _ _ _ failure _ =>
                if failure.attempt != key then .identity key failure.attempt
                else
                  match failure.cause with
                  | .Timeout inner _ =>
                      if inner != failure.stage then .observation key .FailureStage
                      else .observation key .FailureConfiguration
                  | _ => .observation key .FailureConfiguration
            | .DeadlineObservation _ _ _ deadline observedAt _ =>
                if record.input.deadline != some deadline then .observation key .DeadlineValue
                else if deadline.clockBasis != observedAt.clockBasis then
                  .clockBasis deadline.clockBasis observedAt.clockBasis
                else .deadlineNotReached deadline observedAt

private def hostObservationRejection (state : NetworkState)
    (observation : HostObservation) : HostObservationRejection :=
  match observation with
  | .Pending key handle =>
      match lookupAttempt state key with
      | none => .unknown key
      | some record =>
          match record.disposition with
          | .Started expected =>
              if handle = expected then .malformed else .handle expected handle
          | disposition => .condition key .IsStarted (dispositionCondition disposition)
  | .Delivered _ delivered => adapterObservationRejection state delivered

private def hostObservationFailure (state : NetworkState)
    (observation : HostObservation) : NetworkFailure :=
  (hostObservationRejection state observation).failure


def observe (state : NetworkState) (observation : HostObservation) : NetworkStep :=
  if hrelation : HostObservationRelation state observation then
    match observation with
    | .Pending key handle =>
        match lookupAttempt state key with
        | some record => .Pending state { prepared := { input := record.input, lineage := record.lineage }, handle := handle }
        | none => .Rejected state (.UnknownAttempt key)
    | .Delivered delivery delivered =>
        if hobservation : ObservationRelation state delivered then
          let key := attemptOf delivered
          match lookupAttempt state key with
          | none => .Rejected state (.UnknownAttempt key)
          | some record =>
              match recordedDelivery record delivery with
              | some old =>
                  if old = delivered then .Duplicate state key delivery
                  else .Rejected state (.ConflictingDelivery key delivery old delivered)
              | none =>
                  let expected := expectedDeliveryOf record
                  if delivery ≠ expected then
                    .Rejected state (.DeliveryOrderViolation key expected delivery)
                  else
                    match record.disposition with
                    | .Started handle =>
                        let terminal := terminalOf delivered
                        let first : DeliveredObservation := { delivery := delivery, observation := delivered }
                        let updated : AttemptRecord :=
                          { input := record.input, lineage := record.lineage,
                            disposition := AttemptDisposition.Settled (some handle) terminal,
                            firstDelivery := some first, late := [] }
                        let next := replaceRecord state key updated
                        let settled : SettledAttempt :=
                          { prepared := { input := record.input, lineage := record.lineage },
                            handle := some handle, terminal := terminal }
                        if _ : ValidState next then
                          if _ : FirstDeliveryAt next key first then .Terminal next settled
                          else .Rejected state (.InvalidNetworkState (stateViolation next))
                        else .Rejected state (.InvalidNetworkState (stateViolation next))
                    | .Settled handle terminal =>
                        let late : LateObservation :=
                          { delivered := { delivery := delivery, observation := delivered } }
                        let next := appendLate state key late
                        let settled : SettledAttempt :=
                          { prepared := { input := record.input, lineage := record.lineage },
                            handle := handle, terminal := terminal }
                        if _ : ValidState next then
                          if _ : (LatePreservation state next settled settled delivery delivered late) then
                            .Late next settled late
                          else .Rejected state (.InvalidNetworkState (stateViolation next))
                        else .Rejected state (.InvalidNetworkState (stateViolation next))
                    | .Prepared => .Rejected state (.AttemptConditionMismatch key .IsStarted .IsPrepared)
                    | .CommandIssued => .Rejected state (.AttemptConditionMismatch key .IsStarted .IsCommandIssued)
        else .Rejected state (.ObservationRelationMismatch (attemptOf delivered) .EffectWitnessValue)
  else if _ : ValidState state then
    .Rejected state (hostObservationFailure state observation)
  else .Rejected state (.InvalidNetworkState (stateViolation state))

theorem observe_unknown_attempt_rejected :
    ∀ (state : NetworkState) (delivery : DeliveryOrdinal)
      (observation : AdapterObservation),
      ValidState state →
      lookupAttempt state (attemptOf observation) = none →
      observe state (.Delivered delivery observation) =
        .Rejected state (.UnknownAttempt (attemptOf observation)) := by
  intro state delivery observation valid missing
  have relationFalse : ¬ ObservationRelation state observation := by
    simp [ObservationRelation, missing]
  have hostRelationFalse :
      ¬ HostObservationRelation state (.Delivered delivery observation) := by
    simpa [HostObservationRelation] using relationFalse
  simp [observe, hostRelationFalse, valid, hostObservationFailure,
    hostObservationRejection, adapterObservationRejection,
    HostObservationRejection.failure, missing]
private theorem observe_started_first (state : NetworkState)
    (started : StartedAttempt) (record : AttemptRecord)
    (observation : AdapterObservation)
    (valid : ValidState state)
    (found : lookupAttempt state started.prepared.input.attempt = some record)
    (recordInput : record.input = started.prepared.input)
    (recordLineage : record.lineage = started.prepared.lineage)
    (disposition : record.disposition = .Started started.handle)
    (firstNone : record.firstDelivery = none) (lateNone : record.late = [])
    (relation : ObservationRelation state observation)
    (attemptEq : attemptOf observation = started.prepared.input.attempt)
    (handleEq : handleOf observation = started.handle) :
    observe state (.Delivered 0 observation) =
      .Terminal
        (replaceRecord state started.prepared.input.attempt
          { input := record.input, lineage := record.lineage,
            disposition := .Settled (some started.handle) (terminalOf observation),
            firstDelivery := some { delivery := 0, observation := observation }, late := [] })
        { prepared := { input := record.input, lineage := record.lineage },
          handle := some started.handle, terminal := terminalOf observation } := by
  let next :=
    replaceRecord state started.prepared.input.attempt
      { input := record.input, lineage := record.lineage,
        disposition := .Settled (some started.handle) (terminalOf observation),
        firstDelivery := some { delivery := 0, observation := observation }, late := [] }
  have nextValid : ValidState next := by
    exact firstDelivery_update_valid state started record observation valid found recordInput
      recordLineage disposition relation attemptEq handleEq
  have firstAt :
      FirstDeliveryAt next started.prepared.input.attempt
        { delivery := 0, observation := observation } := by
    unfold FirstDeliveryAt next
    have foundNext :=
      lookupAttempt_replaceRecord_self state started.prepared.input.attempt
        { input := record.input, lineage := record.lineage,
          disposition := .Settled (some started.handle) (terminalOf observation),
          firstDelivery := some { delivery := 0, observation := observation }, late := [] }
        record found rfl
    rw [foundNext]
  have recordedNone : recordedDelivery record 0 = none := by
    simp [recordedDelivery, firstNone, lateNone]
  have hostRelation : HostObservationRelation state (.Delivered 0 observation) := relation
  simp [observe, hostRelation, relation, attemptEq, found, recordedNone,
    expectedDeliveryOf, firstNone, lateNone, disposition, next, nextValid, firstAt]

private theorem observe_settled_expected (state : NetworkState)
    (key : AttemptIdentity) (record : AttemptRecord)
    (handle : ExecutionHandle) (terminal : NetworkTerminal)
    (observation : AdapterObservation)
    (valid : ValidState state) (found : lookupAttempt state key = some record)
    (disposition : record.disposition = .Settled (some handle) terminal)
    (relation : ObservationRelation state observation)
    (attemptEq : attemptOf observation = key)
    (handleEq : handleOf observation = handle) :
    observe state (.Delivered (expectedDeliveryOf record) observation) =
      .Late
        (appendLate state key
          { delivered :=
              { delivery := expectedDeliveryOf record, observation := observation } })
        { prepared := { input := record.input, lineage := record.lineage },
          handle := some handle, terminal := terminal }
        { delivered :=
            { delivery := expectedDeliveryOf record, observation := observation } } := by
  have recordEvidence := validState_lookup_recordEvidence state key record valid found
  have recordedNone :=
    recordedDelivery_expected_none record handle terminal disposition recordEvidence
  have nextValid :=
    appendLate_expected_valid state key record handle terminal observation valid found
      disposition relation attemptEq handleEq
  have preservation :
      LatePreservation state
        (appendLate state key
          { delivered :=
              { delivery := expectedDeliveryOf record, observation := observation } })
        { prepared := { input := record.input, lineage := record.lineage },
          handle := some handle, terminal := terminal }
        { prepared := { input := record.input, lineage := record.lineage },
          handle := some handle, terminal := terminal }
        (expectedDeliveryOf record) observation
        { delivered :=
            { delivery := expectedDeliveryOf record, observation := observation } } := by
    simpa [LatePreservation] using
      appendLate_preserves_projections state key record.input.attempt
        { delivered :=
            { delivery := expectedDeliveryOf record, observation := observation } }
  have hostRelation :
      HostObservationRelation state (.Delivered (expectedDeliveryOf record) observation) :=
    relation
  simp [observe, hostRelation, relation, attemptEq, found, recordedNone, disposition,
    nextValid, preservation]


private def observeStepState (state : NetworkState) (observation : HostObservation) : NetworkState :=
  match observe state observation with
  | .Started next _ => next
  | .Pending next _ => next
  | .Terminal next _ => next
  | .Late next _ _ => next
  | .Duplicate next _ _ => next
  | .Rejected next _ => next

private theorem observeStepState_attempts_length (state : NetworkState)
    (observation : HostObservation) :
    (observeStepState state observation).attempts.length = state.attempts.length := by
  unfold observeStepState
  cases hResult : observe state observation <;> simp only [hResult]
  all_goals
    unfold observe at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;>
          simp [replaceRecord, appendLate_attempts_length]

private theorem observeStepState_attempts_nonempty (state : NetworkState)
    (observation : HostObservation) (nonempty : state.attempts ≠ []) :
    (observeStepState state observation).attempts ≠ [] := by
  intro empty
  have lengths := observeStepState_attempts_length state observation
  rw [empty] at lengths
  cases hAttempts : state.attempts with
  | nil => exact nonempty hAttempts
  | cons record rest => simp [hAttempts] at lengths

def FoldObserve (state : NetworkState) (observations : List HostObservation) : NetworkState :=
  observations.foldl observeStepState state
private def annotationStatusOk (current : EffectStatus) (requested : EffectStatus) : Bool :=
  match current, requested with
  | .Unknown _, .NoEffect _ => true
  | .Unknown _, .EffectOccurred _ => true
  | .NoEffect old, .NoEffect fresh => old == fresh
  | .EffectOccurred old, .EffectOccurred fresh => old == fresh
  | _, _ => false

private def annotationConflict (current : EffectStatus) (requested : EffectStatus) : Bool :=
  match current, requested with
  | .NoEffect _, .EffectOccurred _ => true
  | .EffectOccurred _, .NoEffect _ => true
  | _, _ => false

def annotateEffect (state : NetworkState) (observation : EffectObservation) : StateStep :=
  if _ : ValidState state then
    match lookupAttempt state observation.attempt with
    | some record =>
        match record.disposition with
        | .Settled _ terminal =>
            if _ : EffectMatches observation.attempt observation.status then
              if _ : annotationStatusOk terminal.effect observation.status then
                let next := setEffect state observation.attempt observation.status
                if _ : ValidState next then
                  if _ : SameExceptEffect state next observation.attempt then .Applied next
                  else .Rejected state (.InvalidNetworkState (stateViolation next))
                else .Rejected state (.InvalidNetworkState (stateViolation next))
              else if _ : annotationConflict terminal.effect observation.status then
                .Rejected state (.EffectKnowledgeConflict observation.attempt)
              else .Rejected state (.EffectWitnessMissing observation.attempt)
            else .Rejected state (.EffectWitnessMissing observation.attempt)
        | _ => .Rejected state (.AttemptConditionMismatch observation.attempt .IsSettled (dispositionCondition record.disposition))
    | none => .Rejected state (.UnknownAttempt observation.attempt)
  else .Rejected state (.InvalidNetworkState (stateViolation state))

private def retryAuthorizationAvailable (state : NetworkState) (authorization : RetryAuthorization) : Bool :=
  !authorizationUsed state.attempts authorization

private def parentIsSettledMaximumBool (state : NetworkState) (key : AttemptIdentity) : Bool :=
  match lookupAttempt state key with
  | none => false
  | some record =>
      isSettled record.disposition &&
      !state.attempts.any (fun candidate =>
        candidate.input.attempt.logical == key.logical && candidate.input.attempt.ordinal > key.ordinal)

def ParentIsSettledMaximum (state : NetworkState) (key : AttemptIdentity) : Prop :=
  parentIsSettledMaximumBool state key = true

instance parentIsSettledMaximumDecidable (state : NetworkState) (key : AttemptIdentity) :
    Decidable (ParentIsSettledMaximum state key) := by
  unfold ParentIsSettledMaximum
  infer_instance

def retryPermissionAcceptable (state : NetworkState) (request : RetryRequest) : Prop :=
  match request.permission with
  | .RetryDenied _ _ _ => False
  | .RetryAllowed authorization =>
      let retryInput : AttemptInput :=
        { attempt := authorization.next, instruction := request.instruction,
          deadline := request.deadline, configuration := request.configuration }
      ValidState state ∧
      ValidAttemptInput retryInput ∧
      authorization.logical = authorization.«from».logical ∧
      authorization.logical = authorization.next.logical ∧
      authorization.next.ordinal = authorization.«from».ordinal + 1 ∧
      ParentIsSettledMaximum state authorization.«from» ∧
      NoAttemptRecord state authorization.next ∧
      retryAuthorizationAvailable state authorization = true

instance retryPermissionAcceptableDecidable (state : NetworkState) (request : RetryRequest) :
    Decidable (retryPermissionAcceptable state request) := by
  unfold retryPermissionAcceptable
  cases request.permission <;> infer_instance


def DeniedOrMalformedRetry (state : NetworkState) (request : RetryRequest) : Prop :=
  ¬ retryPermissionAcceptable state request

instance deniedOrMalformedRetryDecidable (state : NetworkState) (request : RetryRequest) :
    Decidable (DeniedOrMalformedRetry state request) := by
  unfold DeniedOrMalformedRetry
  infer_instance

def AlternateAuthorizationSameNext (request : RetryRequest) (authorization : RetryAuthorization) : RetryRequest :=
  { request with
    permission := .RetryAllowed
      { authorization with
        protocolEvidence := { value := authorization.protocolEvidence.value ++ "-alternate" } } }

private theorem alternateEvidence_ne (value : String) : value ++ "-alternate" ≠ value := by
  intro h
  have hLen : (value ++ "-alternate").length = value.length := congrArg String.length h
  simp [String.length_append] at hLen

theorem alternateAuthorizationSameNext_ne :
    ∀ (request : RetryRequest) (authorization : RetryAuthorization),
      (AlternateAuthorizationSameNext request authorization).permission ≠
        .RetryAllowed authorization := by
  intro request authorization hEq
  unfold AlternateAuthorizationSameNext at hEq
  simp only at hEq
  injection hEq with hAuth
  have hValue := congrArg (fun a : RetryAuthorization => a.protocolEvidence.value) hAuth
  simp only at hValue
  exact alternateEvidence_ne authorization.protocolEvidence.value hValue

def retryFailureKey : RetryPermission → AttemptIdentity
  | .RetryAllowed authorization => authorization.«from»
  | .RetryDenied _ key _ => key

def retry (state : NetworkState) (request : RetryRequest) : PrepareStep :=
  if hacceptable : retryPermissionAcceptable state request then
    match request.permission with
    | .RetryAllowed authorization =>
        let input : AttemptInput :=
          { attempt := authorization.next, instruction := request.instruction,
            deadline := request.deadline, configuration := request.configuration }
        let prepared : PreparedAttempt := { input := input, lineage := .RetryOf authorization }
        let record : AttemptRecord :=
          { input := input, lineage := .RetryOf authorization, disposition := .Prepared,
            firstDelivery := none, late := [] }
        let next := appendRecord state record
        if _ : ValidState next then
          if _ : PreparedRelation next prepared then .Prepared next prepared
          else .Rejected state (.InvalidNetworkState (stateViolation next))
        else .Rejected state (.InvalidNetworkState (stateViolation next))
    | .RetryDenied _ key _ => .Rejected state (.RetryNotPermitted key)
  else .Rejected state (.RetryNotPermitted (retryFailureKey request.permission))

private def prepareStepState : PrepareStep → NetworkState
  | .Prepared state _ => state
  | .Rejected state _ => state

private def commandStepState {α : Type} : CommandStep α → NetworkState
  | .CommandReady state _ => state
  | .Rejected state _ => state

private def networkStepState : NetworkStep → NetworkState
  | .Started state _ => state
  | .Pending state _ => state
  | .Terminal state _ => state
  | .Late state _ _ => state
  | .Duplicate state _ _ => state
  | .Rejected state _ => state

private def stateStepState : StateStep → NetworkState
  | .Applied state => state
  | .Rejected state _ => state

private theorem prepare_preserves_valid (state : NetworkState) (input : AttemptInput)
    (valid : ValidState state) : ValidState (prepareStepState (prepare state input)) := by
  cases hResult : prepare state input <;> simp only [prepareStepState]
  all_goals
    unfold prepare at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption

private theorem sendCommand_preserves_valid (state : NetworkState) (prepared : PreparedAttempt)
    (valid : ValidState state) : ValidState (commandStepState (sendCommand state prepared)) := by
  cases hResult : sendCommand state prepared <;> simp only [commandStepState]
  all_goals
    unfold sendCommand at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption

private theorem cancelCommand_preserves_valid (state : NetworkState) (started : StartedAttempt)
    (valid : ValidState state) : ValidState (commandStepState (cancelCommand state started)) := by
  cases hResult : cancelCommand state started <;> simp only [commandStepState]
  all_goals
    unfold cancelCommand at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption

private theorem observeStart_preserves_valid (state : NetworkState) (prepared : PreparedAttempt)
    (observation : StartObservation) (valid : ValidState state) :
    ValidState (networkStepState (observeStart state prepared observation)) := by
  cases hResult : observeStart state prepared observation <;> simp only [networkStepState]
  all_goals
    unfold observeStart at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption

private theorem observe_preserves_valid (state : NetworkState) (observation : HostObservation)
    (valid : ValidState state) : ValidState (networkStepState (observe state observation)) := by
  cases hResult : observe state observation <;> simp only [networkStepState]
  all_goals
    unfold observe at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption

private theorem annotateEffect_preserves_valid (state : NetworkState)
    (observation : EffectObservation) (valid : ValidState state) :
    ValidState (stateStepState (annotateEffect state observation)) := by
  cases hResult : annotateEffect state observation <;> simp only [stateStepState]
  all_goals
    unfold annotateEffect at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption

private theorem retry_preserves_valid (state : NetworkState) (request : RetryRequest)
    (valid : ValidState state) : ValidState (prepareStepState (retry state request)) := by
  cases hResult : retry state request <;> simp only [prepareStepState]
  all_goals
    unfold retry at hResult
    repeat
      first
      | simp only at hResult
      | split at hResult
      | injection hResult <;> subst_vars <;> assumption


inductive NetworkResultClass where
  | StartedResult
  | PendingResult
  | TerminalResult
  | LateResult
  | DuplicateResult
  | RejectedResult
  deriving DecidableEq, Repr

def ResultClass : NetworkStep → NetworkResultClass
  | .Started _ _ => .StartedResult
  | .Pending _ _ => .PendingResult
  | .Terminal _ _ => .TerminalResult
  | .Late _ _ _ => .LateResult
  | .Duplicate _ _ _ => .DuplicateResult
  | .Rejected _ _ => .RejectedResult

abbrev resultClass := ResultClass

private def eraseObservationSource : AdapterObservation → AdapterObservation
  | .ResponseObservation key handle _ raw provenance effect =>
      .ResponseObservation key handle .none raw provenance effect
  | .FailureObservation key handle _ failure effect =>
      .FailureObservation key handle .none failure effect
  | .CancellationObservation key handle _ effect =>
      .CancellationObservation key handle .none effect
  | .DeadlineObservation key handle _ deadline clock effect =>
      .DeadlineObservation key handle .none deadline clock effect

private def eraseDelivered (delivered : DeliveredObservation) : DeliveredObservation :=
  { delivered with observation := eraseObservationSource delivered.observation }

private def eraseRecordSources (record : AttemptRecord) : AttemptRecord :=
  { record with
    firstDelivery := record.firstDelivery.map eraseDelivered,
    late := record.late.map (fun late => { late with delivered := eraseDelivered late.delivered }) }

private def eraseStateSources (state : NetworkState) : NetworkState :=
  { attempts := state.attempts.map eraseRecordSources }

@[simp] private theorem eraseDelivered_delivery (delivered : DeliveredObservation) :
    (eraseDelivered delivered).delivery = delivered.delivery := rfl

@[simp] private theorem eraseDelivered_observation (delivered : DeliveredObservation) :
    (eraseDelivered delivered).observation = eraseObservationSource delivered.observation := rfl

@[simp] private theorem eraseRecordSources_input (record : AttemptRecord) :
    (eraseRecordSources record).input = record.input := rfl

@[simp] private theorem eraseRecordSources_lineage (record : AttemptRecord) :
    (eraseRecordSources record).lineage = record.lineage := rfl

@[simp] private theorem eraseRecordSources_disposition (record : AttemptRecord) :
    (eraseRecordSources record).disposition = record.disposition := rfl

private theorem attemptOf_eraseObservationSource (observation : AdapterObservation) :
    attemptOf (eraseObservationSource observation) = attemptOf observation := by
  cases observation <;> rfl

private theorem handleOf_eraseObservationSource (observation : AdapterObservation) :
    handleOf (eraseObservationSource observation) = handleOf observation := by
  cases observation <;> rfl

private theorem terminalOf_eraseObservationSource (observation : AdapterObservation) :
    terminalOf (eraseObservationSource observation) = terminalOf observation := by
  cases observation <;> rfl

private theorem lateEvidenceOk_eraseSources (key : AttemptIdentity) (handle : ExecutionHandle)
    (previous : Nat) (late : List LateObservation) :
    lateEvidenceOk key handle previous
        (late.map (fun item => { item with delivered := eraseDelivered item.delivered })) =
      lateEvidenceOk key handle previous late := by
  induction late generalizing previous with
  | nil => rfl
  | cons item rest ih =>
      simp only [List.map_cons, lateEvidenceOk, eraseDelivered_delivery,
        eraseDelivered_observation, attemptOf_eraseObservationSource,
        handleOf_eraseObservationSource]
      rw [ih item.delivered.delivery]
      rfl

private theorem recordEvidenceOk_eraseSources (record : AttemptRecord) :
    recordEvidenceOk (eraseRecordSources record) = recordEvidenceOk record := by
  cases hDisposition : record.disposition with
  | Prepared => simp [recordEvidenceOk, eraseRecordSources, hDisposition]
  | CommandIssued => simp [recordEvidenceOk, eraseRecordSources, hDisposition]
  | Started handle => simp [recordEvidenceOk, eraseRecordSources, hDisposition]
  | Settled handle terminal =>
      cases handle with
      | none => simp [recordEvidenceOk, eraseRecordSources, hDisposition]
      | some executionHandle =>
          cases hFirst : record.firstDelivery with
          | none => simp [recordEvidenceOk, eraseRecordSources, hDisposition, hFirst]
          | some first =>
              have lateEq :
                  lateEvidenceOk record.input.attempt executionHandle first.delivery
                      (record.late.map (fun late =>
                        { delivered :=
                            { delivery := late.delivered.delivery,
                              observation := eraseObservationSource late.delivered.observation } })) =
                    lateEvidenceOk record.input.attempt executionHandle first.delivery record.late := by
                simpa [eraseDelivered] using
                  lateEvidenceOk_eraseSources record.input.attempt executionHandle
                    first.delivery record.late
              simp [recordEvidenceOk, eraseRecordSources, hDisposition, hFirst,
                eraseDelivered, attemptOf_eraseObservationSource,
                handleOf_eraseObservationSource]
              rw [lateEq]

private theorem rootForLogical_eraseSources (records : List AttemptRecord)
    (logical : RequestIdentity) :
    rootForLogical (records.map eraseRecordSources) logical = rootForLogical records logical := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      unfold rootForLogical at ih ⊢
      simp only [List.map_cons, List.any_cons, eraseRecordSources_input,
        eraseRecordSources_lineage]
      rw [ih]

private theorem settledKey_eraseSources (records : List AttemptRecord) (key : AttemptIdentity) :
    settledKey (records.map eraseRecordSources) key = settledKey records key := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      unfold settledKey at ih ⊢
      simp only [List.map_cons, List.any_cons, eraseRecordSources_input,
        eraseRecordSources_disposition]
      rw [ih]

private theorem authorizationUsed_eraseSources (records : List AttemptRecord)
    (authorization : RetryAuthorization) :
    authorizationUsed (records.map eraseRecordSources) authorization =
      authorizationUsed records authorization := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      unfold authorizationUsed at ih ⊢
      simp only [List.map_cons, List.any_cons, eraseRecordSources_lineage]
      rw [ih]

private theorem authorizationUnique_eraseSources (records : List AttemptRecord) :
    authorizationUnique (records.map eraseRecordSources) = authorizationUnique records := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      simp [authorizationUnique, authorizationUsed_eraseSources, eraseRecordSources, ih]

private theorem recordListEvidence_eraseSources (records : List AttemptRecord) :
    recordListEvidence (records.map eraseRecordSources) = recordListEvidence records := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      simp [recordListEvidence, recordEvidenceOk_eraseSources, ih]

private theorem lineageOk_eraseSources (records : List AttemptRecord) (record : AttemptRecord) :
    lineageOk (records.map eraseRecordSources) (eraseRecordSources record) =
      lineageOk records record := by
  simp [lineageOk, rootForLogical_eraseSources, settledKey_eraseSources]

private theorem lineageListEvidence_eraseSources (records : List AttemptRecord) :
    lineageListEvidence (records.map eraseRecordSources) = lineageListEvidence records := by
  unfold lineageListEvidence
  rw [List.all_map]
  congr 1
  funext record
  exact lineageOk_eraseSources records record

private theorem rootsListEvidence_eraseSources (records : List AttemptRecord) :
    rootsListEvidence (records.map eraseRecordSources) = rootsListEvidence records := by
  unfold rootsListEvidence
  rw [List.all_map]
  congr 1
  funext record
  simpa using rootForLogical_eraseSources records record.input.attempt.logical

private theorem stateInvariantBool_eraseSources (state : NetworkState) :
    stateInvariantBool (eraseStateSources state) = stateInvariantBool state := by
  have keysEq :
      (state.attempts.map eraseRecordSources).map (fun record => record.input.attempt) =
        state.attempts.map (fun record => record.input.attempt) := by
    induction state.attempts with
    | nil => rfl
    | cons record rest ih => simp [ih]
  unfold stateInvariantBool eraseStateSources
  rw [keysEq, recordListEvidence_eraseSources, lineageListEvidence_eraseSources,
    rootsListEvidence_eraseSources, authorizationUnique_eraseSources]

private theorem validState_of_erased_equal (left right : NetworkState)
    (erased : eraseStateSources left = eraseStateSources right) :
    ValidState left ↔ ValidState right := by
  unfold ValidState
  rw [← stateInvariantBool_eraseSources left, erased, stateInvariantBool_eraseSources right]

private theorem duplicateAny_eraseSources (records : List AttemptRecord)
    (key : AttemptIdentity) :
    (records.map eraseRecordSources).any (fun record => record.input.attempt == key) =
      records.any (fun record => record.input.attempt == key) := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      simp only [List.map_cons, List.any_cons, eraseRecordSources_input, ih]

private theorem firstDuplicateViolation_eraseSources (records : List AttemptRecord) :
    firstDuplicateViolation (records.map eraseRecordSources) = firstDuplicateViolation records := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      simp only [List.map_cons, firstDuplicateViolation, eraseRecordSources_input,
        duplicateAny_eraseSources]
      split <;> simp [ih]

private theorem recordEvidenceViolation_eraseSources (record : AttemptRecord) :
    recordEvidenceViolation (eraseRecordSources record) = recordEvidenceViolation record := by
  unfold recordEvidenceViolation
  rw [recordEvidenceOk_eraseSources]
  split
  · rfl
  · cases disposition : record.disposition <;>
      simp [eraseRecordSources, disposition, terminalEvidenceOk]

private theorem firstRecordViolation_eraseSources (records : List AttemptRecord) :
    firstRecordViolation (records.map eraseRecordSources) = firstRecordViolation records := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      simp [firstRecordViolation, recordEvidenceViolation_eraseSources, ih]

private theorem lineageViolation_eraseSources (records : List AttemptRecord)
    (record : AttemptRecord) :
    lineageViolation (records.map eraseRecordSources) (eraseRecordSources record) =
      lineageViolation records record := by
  unfold lineageViolation
  rw [lineageOk_eraseSources, rootForLogical_eraseSources]
  cases lineage : record.lineage <;> simp [eraseRecordSources, lineage]

private theorem firstLineageViolation_eraseSources (records remaining : List AttemptRecord) :
    firstLineageViolation (records.map eraseRecordSources) (remaining.map eraseRecordSources) =
      firstLineageViolation records remaining := by
  induction remaining with
  | nil => rfl
  | cons record rest ih =>
      simp [firstLineageViolation, lineageViolation_eraseSources, ih]

private theorem firstRootViolation_eraseSources (records remaining : List AttemptRecord) :
    firstRootViolation (records.map eraseRecordSources) (remaining.map eraseRecordSources) =
      firstRootViolation records remaining := by
  induction remaining with
  | nil => rfl
  | cons record rest ih =>
      simp [firstRootViolation, rootForLogical_eraseSources, ih]

private theorem firstAuthorizationViolation_eraseSources (records : List AttemptRecord) :
    firstAuthorizationViolation (records.map eraseRecordSources) =
      firstAuthorizationViolation records := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      cases lineage : record.lineage <;>
        simp [firstAuthorizationViolation, eraseRecordSources, lineage,
          authorizationUsed_eraseSources, ih]

private theorem stateViolation_eraseSources (state : NetworkState) :
    stateViolation (eraseStateSources state) = stateViolation state := by
  unfold stateViolation eraseStateSources
  rw [firstDuplicateViolation_eraseSources, firstRecordViolation_eraseSources,
    firstLineageViolation_eraseSources, firstRootViolation_eraseSources,
    firstAuthorizationViolation_eraseSources]

private theorem eraseStateSources_firstDelivery_equal (state : NetworkState)
    (key : AttemptIdentity) (record : AttemptRecord) (handle : ExecutionHandle)
    (delivery : DeliveryOrdinal) (left right : AdapterObservation)
    (sourceEqual : eraseObservationSource left = eraseObservationSource right) :
    eraseStateSources
        (replaceRecord state key
          { input := record.input, lineage := record.lineage,
            disposition := .Settled (some handle) (terminalOf left),
            firstDelivery := some { delivery := delivery, observation := left }, late := [] }) =
      eraseStateSources
        (replaceRecord state key
          { input := record.input, lineage := record.lineage,
            disposition := .Settled (some handle) (terminalOf right),
            firstDelivery := some { delivery := delivery, observation := right }, late := [] }) := by
  have terminalEqual : terminalOf left = terminalOf right := by
    calc
      terminalOf left = terminalOf (eraseObservationSource left) :=
        (terminalOf_eraseObservationSource left).symm
      _ = terminalOf (eraseObservationSource right) := congrArg terminalOf sourceEqual
      _ = terminalOf right := terminalOf_eraseObservationSource right
  simp [eraseStateSources, replaceRecord, eraseRecordSources, eraseDelivered,
    terminalEqual, sourceEqual]
  intro candidate _
  by_cases same : candidate.input.attempt = key
  · simp [same, eraseDelivered, sourceEqual]
  · simp [same]

private theorem eraseStateSources_appendLate_equal (state : NetworkState)
    (key : AttemptIdentity) (delivery : DeliveryOrdinal) (left right : AdapterObservation)
    (sourceEqual : eraseObservationSource left = eraseObservationSource right) :
    eraseStateSources
        (appendLate state key { delivered := { delivery := delivery, observation := left } }) =
      eraseStateSources
        (appendLate state key { delivered := { delivery := delivery, observation := right } }) := by
  unfold appendLate
  split
  · simp [eraseStateSources, replaceRecord, eraseRecordSources, eraseDelivered, sourceEqual]
    intro candidate _
    by_cases same : candidate.input.attempt = key
    · simp [same, eraseDelivered, sourceEqual]
    · simp [same]
  · rfl

def EraseSourceSequence : NetworkStep → NetworkStep
  | .Started state started => .Started (eraseStateSources state) started
  | .Pending state started => .Pending (eraseStateSources state) started
  | .Terminal state settled => .Terminal (eraseStateSources state) settled
  | .Late state settled late =>
      .Late (eraseStateSources state) settled { delivered := eraseDelivered late.delivered }
  | .Duplicate state key delivery => .Duplicate (eraseStateSources state) key delivery
  | .Rejected state failure => .Rejected (eraseStateSources state) failure

def SuccessfulNetworkStep : NetworkStep → Prop
  | .Rejected _ _ => False
  | _ => True

def LookupTypedTerminal (state : NetworkState) (key : AttemptIdentity) : Option NetworkTerminal :=
  match lookupAttempt state key with
  | some record => terminalOfDisposition record.disposition
  | none => none
def ApplyNetworkProjection (state : NetworkState) (bridge : ProgressionBridgeInput) :
    ProgressionBridgeOutput :=
  { progression := bridge.progression,
    projection := { terminal := LookupTypedTerminal state bridge.attempt } }


def TerminalCarriedOrReferenced (projection : ProgressionProjection) : Option NetworkTerminal :=
  projection.terminal

def SettleOrRead (state : NetworkState) (key : AttemptIdentity) (terminal : NetworkTerminal) : NetworkState :=
  match lookupAttempt state key with
  | some record =>
      replaceRecord state key
        { record with disposition := .Settled (dispositionHandle record.disposition) terminal }
  | none => state

def FailureCategory : NetworkFailure → NetworkFailureCategory
  | .InvalidWireInstruction _ => .Wire
  | .InvalidDeadline => .Deadline
  | .InvalidNetworkState _ => .State
  | .RootAttemptRequired _ => .Identity
  | .DuplicateAttempt _ => .Identity
  | .UnknownAttempt _ => .Identity
  | .AttemptConditionMismatch _ _ _ => .State
  | .AttemptTokenMismatch _ _ => .Token
  | .ObservationRelationMismatch _ _ => .Observation
  | .RequiredCapabilityUnavailable _ _ => .Capability
  | .CommandAlreadyIssued _ => .State
  | .IdentityMismatch _ _ => .Identity
  | .HandleMismatch _ _ => .Handle
  | .ClockBasisMismatch _ _ => .Deadline
  | .DeadlineNotReached _ _ => .Deadline
  | .DeliveryOrderViolation _ _ _ => .Delivery
  | .ConflictingDelivery _ _ _ _ => .Delivery
  | .MalformedAdapterObservation => .Observation
  | .Host _ => .Host
  | .RetryNotPermitted _ => .Retry
  | .RetryIdentityMismatch _ _ => .Retry
  | .RetryParentMismatch _ _ => .Retry
  | .RetryParentNotSettled _ => .Retry
  | .RetryOrderViolation _ _ => .Retry
  | .RetryAuthorizationAlreadyUsed _ => .Retry
  | .EffectWitnessMissing _ => .Effect
  | .EffectKnowledgeConflict _ => .Effect

private theorem hostObservationFailure_not_delivery (state : NetworkState)
    (observation : HostObservation) :
    FailureCategory (hostObservationFailure state observation) ≠ .Delivery := by
  unfold hostObservationFailure
  cases hostObservationRejection state observation <;>
    simp [HostObservationRejection.failure, FailureCategory]
def SuccessfulTransition (state state' : NetworkState) : Prop :=
  readNetworkState state = .Read state' ∨
  (∃ input prepared, prepare state input = .Prepared state' prepared) ∨
  (∃ prepared command, sendCommand state prepared = .CommandReady state' command) ∨
  (∃ started command, cancelCommand state started = .CommandReady state' command) ∨
  (∃ prepared observation started, observeStart state prepared observation = .Started state' started) ∨
  (∃ prepared observation settled, observeStart state prepared observation = .Terminal state' settled) ∨
  (∃ observation started, observe state observation = .Pending state' started) ∨
  (∃ observation settled, observe state observation = .Terminal state' settled) ∨
  (∃ observation settled late, observe state observation = .Late state' settled late) ∨
  (∃ observation key delivery, observe state observation = .Duplicate state' key delivery) ∨
  (∃ effect, annotateEffect state effect = .Applied state') ∨
  (∃ request prepared, retry state request = .Prepared state' prepared)

def RejectedByOperation (state : NetworkState) (failure : NetworkFailure) : Prop :=
  readNetworkState state = .Rejected state failure ∨
  (∃ input, prepare state input = .Rejected state failure) ∨
  (∃ prepared, sendCommand state prepared = .Rejected state failure) ∨
  (∃ started, cancelCommand state started = .Rejected state failure) ∨
  (∃ prepared observation, observeStart state prepared observation = .Rejected state failure) ∨
  (∃ observation, observe state observation = .Rejected state failure) ∨
  (∃ effect, annotateEffect state effect = .Rejected state failure) ∨
  (∃ request, retry state request = .Rejected state failure)

private def rootFacts (state state' : NetworkState) (input : AttemptInput)
    (prepared : PreparedAttempt) : Prop :=
  ValidAttemptInput input ∧ input.attempt.ordinal = 0 ∧
  NoLogicalRecord state input.attempt.logical ∧
  ExactlyOneRecordAdded state state' input.attempt


private def firstDeliveryFacts (state state' : NetworkState) (started : StartedAttempt)
    (delivery : DeliveryOrdinal) (observation : AdapterObservation) (settled : SettledAttempt) : Prop :=
  settled.terminal = terminalOf observation ∧
  FirstDeliveryAt state' started.prepared.input.attempt
    { delivery := delivery, observation := observation }

private def successfulHostFacts (state : NetworkState) (host : HostObservation) : Prop :=
  HostObservationRelation state host

private def effectSameStateFacts (state state' : NetworkState) (key : AttemptIdentity) : Prop :=
  SameExceptEffect state state' key

private def denialFailure (request : RetryRequest) : NetworkFailure :=
  .RetryNotPermitted (retryFailureKey request.permission)

private def operationRejectedOnMalformed (state : NetworkState) (key : AttemptIdentity) : NetworkStep :=
  .Rejected state (.ObservationRelationMismatch key .EffectWitnessValue)



theorem ledger_invariant_preservation :
    ∀ (state state' : NetworkState), ValidState state → SuccessfulTransition state state' → ValidState state' := by
  intro state state' valid transition
  rcases transition with read | prepared | sent | cancelled | start | startFailure |
    pending | terminal | late | duplicate | effect | retried
  · simp [readNetworkState, valid] at read
    simpa [read] using valid
  · rcases prepared with ⟨input, prepared, equation⟩
    have preserved := prepare_preserves_valid state input valid
    rw [equation] at preserved
    exact preserved
  · rcases sent with ⟨prepared, command, equation⟩
    have preserved := sendCommand_preserves_valid state prepared valid
    rw [equation] at preserved
    exact preserved
  · rcases cancelled with ⟨started, command, equation⟩
    have preserved := cancelCommand_preserves_valid state started valid
    rw [equation] at preserved
    exact preserved
  · rcases start with ⟨prepared, observation, started, equation⟩
    have preserved := observeStart_preserves_valid state prepared observation valid
    rw [equation] at preserved
    exact preserved
  · rcases startFailure with ⟨prepared, observation, settled, equation⟩
    have preserved := observeStart_preserves_valid state prepared observation valid
    rw [equation] at preserved
    exact preserved
  · rcases pending with ⟨observation, started, equation⟩
    have preserved := observe_preserves_valid state observation valid
    rw [equation] at preserved
    exact preserved
  · rcases terminal with ⟨observation, settled, equation⟩
    have preserved := observe_preserves_valid state observation valid
    rw [equation] at preserved
    exact preserved
  · rcases late with ⟨observation, settled, late, equation⟩
    have preserved := observe_preserves_valid state observation valid
    rw [equation] at preserved
    exact preserved
  · rcases duplicate with ⟨observation, key, delivery, equation⟩
    have preserved := observe_preserves_valid state observation valid
    rw [equation] at preserved
    exact preserved
  · rcases effect with ⟨observation, equation⟩
    have preserved := annotateEffect_preserves_valid state observation valid
    rw [equation] at preserved
    exact preserved
  · rcases retried with ⟨request, prepared, equation⟩
    have preserved := retry_preserves_valid state request valid
    rw [equation] at preserved
    exact preserved

theorem root_exclusivity :
    (∀ (state state' : NetworkState) (input : AttemptInput) (prepared : PreparedAttempt),
      ValidState state → prepare state input = .Prepared state' prepared →
        ValidAttemptInput input ∧ input.attempt.ordinal = 0 ∧
          NoLogicalRecord state input.attempt.logical ∧
          ExactlyOneRecordAdded state state' input.attempt) ∧
    (∀ (state : NetworkState) (input : AttemptInput), ValidState state →
      (input.attempt.ordinal ≠ 0 ∨ ¬ NoLogicalRecord state input.attempt.logical) →
      ∃ failure : NetworkFailure, prepare state input = .Rejected state failure) := by
  constructor
  · intro state state' input prepared valid equation
    by_cases hInput : ValidAttemptInput input
    · by_cases hOrdinal : input.attempt.ordinal = 0
      · by_cases hLogical : NoLogicalRecord state input.attempt.logical
        · simp [prepare, valid, hInput, hOrdinal, hLogical] at equation
          by_cases hNext : ValidState
              (appendRecord state
                { input := input, lineage := .Root, disposition := .Prepared,
                  firstDelivery := none, late := [] })
          · simp [hNext] at equation
            by_cases hRel :
                PreparedRelation
                  (appendRecord state
                    { input := input, lineage := .Root, disposition := .Prepared,
                      firstDelivery := none, late := [] })
                  { input := input, lineage := .Root }
            · simp [hRel] at equation
              rcases equation with ⟨hState, hPrepared⟩
              subst state' prepared
              exact ⟨hInput, hOrdinal, hLogical,
                ⟨{ input := input, lineage := .Root, disposition := .Prepared,
                    firstDelivery := none, late := [] },
                  rfl, rfl⟩⟩
            · simp [hRel] at equation
          · simp [hNext] at equation
        · simp [prepare, valid, hInput, hOrdinal, hLogical] at equation
      · simp [prepare, valid, hInput, hOrdinal] at equation
    · simp [prepare, valid, hInput] at equation
  · intro state input valid bad
    rcases bad with hOrdinal | hLogical
    · by_cases hInput : ValidAttemptInput input
      · refine ⟨.RootAttemptRequired input.attempt, ?_⟩
        simp [prepare, valid, hInput, hOrdinal]
      · refine ⟨.InvalidWireInstruction input.instruction.method, ?_⟩
        simp [prepare, valid, hInput]
    · by_cases hInput : ValidAttemptInput input
      · by_cases hOrd : input.attempt.ordinal = 0
        · refine ⟨.DuplicateAttempt input.attempt, ?_⟩
          simp [prepare, valid, hLogical, hInput, hOrd]
        · refine ⟨.RootAttemptRequired input.attempt, ?_⟩
          simp [prepare, valid, hLogical, hInput, hOrd]
      · refine ⟨.InvalidWireInstruction input.instruction.method, ?_⟩
        simp [prepare, valid, hLogical, hInput]

theorem instruction_preservation :
    (∀ (state state' : NetworkState) (input : AttemptInput) (prepared : PreparedAttempt),
      prepare state input = .Prepared state' prepared →
        prepared.input = input ∧ PreparedRelation state' prepared) ∧
    (∀ (state state' : NetworkState) (request : RetryRequest) (prepared : PreparedAttempt)
      (authorization : RetryAuthorization),
      retry state request = .Prepared state' prepared →
        request.permission = .RetryAllowed authorization →
          prepared.input.attempt = authorization.next ∧
          prepared.input.instruction = request.instruction ∧
          prepared.input.deadline = request.deadline ∧
          prepared.input.configuration = request.configuration ∧
          PreparedRelation state' prepared) := by
  constructor
  · intro state state' input prepared equation
    by_cases hState : ValidState state
    · by_cases hInput : ValidAttemptInput input
      · by_cases hOrdinal : input.attempt.ordinal = 0
        · by_cases hLogical : NoLogicalRecord state input.attempt.logical
          · simp [prepare, hState, hInput, hOrdinal, hLogical] at equation
            by_cases hNext : ValidState
                (appendRecord state
                  { input := input, lineage := .Root, disposition := .Prepared,
                    firstDelivery := none, late := [] })
            · simp [hNext] at equation
              by_cases hRel :
                  PreparedRelation
                    (appendRecord state
                      { input := input, lineage := .Root, disposition := .Prepared,
                        firstDelivery := none, late := [] })
                    { input := input, lineage := .Root }
              · simp [hRel] at equation
                rcases equation with ⟨hState', hPrepared⟩
                subst state' prepared
                exact ⟨rfl, hRel⟩
              · simp [hRel] at equation
            · simp [hNext] at equation
          · simp [prepare, hState, hInput, hOrdinal, hLogical] at equation
        · simp [prepare, hState, hInput, hOrdinal] at equation
      · simp [prepare, hState, hInput] at equation
    · simp [prepare, hState] at equation
  · intro state state' request prepared authorization equation permission
    cases hPerm : request.permission with
    | RetryDenied logical parent evidence =>
        simp [hPerm] at permission
    | RetryAllowed actual =>
        have hAuth : actual = authorization := by
          simpa [hPerm] using permission
        subst actual
        unfold retry at equation
        simp [hPerm] at equation
        split at equation
        · split at equation
          · split at equation
            · injection equation with hState hPrepared
              subst state' prepared
              exact ⟨rfl, rfl, rfl, rfl, by assumption⟩
            · contradiction
          · contradiction
        · contradiction

theorem state_read_identity :
    (∀ (state : NetworkState), ValidState state → readNetworkState state = .Read state) ∧
    (∀ (state : NetworkState), ¬ ValidState state →
      ∃ violation : NetworkStateViolation,
        readNetworkState state = .Rejected state (.InvalidNetworkState violation)) := by
  constructor
  · intro state valid
    simp [readNetworkState, valid]
  · intro state invalid
    refine ⟨stateViolation state, ?_⟩
    simp [readNetworkState, invalid]

theorem finite_command_and_one_issue :
    (∀ (state state' : NetworkState) (prepared : PreparedAttempt) (command : SendCommand),
      ValidState state → sendCommand state prepared = .CommandReady state' command →
        PreparedReady state prepared ∧
        AuthoritativePreparedAt state prepared.input.attempt command.prepared ∧
        SameExceptDisposition state state' prepared.input.attempt ∧
        sendCommand state' prepared =
          .Rejected state' (.CommandAlreadyIssued prepared.input.attempt)) ∧
    (∀ (state : NetworkState) (prepared : PreparedAttempt),
      ValidState state → ¬ PreparedReady state prepared →
        ∃ failure : NetworkFailure, sendCommand state prepared = .Rejected state failure) := by
  constructor
  · intro state state' prepared command valid equation
    unfold sendCommand at equation
    split at equation
    · contradiction
    · rename_i notIssued
      split at equation
      · rename_i ready
        rcases ready with ⟨preparedRelation, dispositionReady⟩
        cases found : lookupAttempt state prepared.input.attempt with
        | none => simp [PreparedRelation, found] at preparedRelation
        | some record =>
            have fields :
                record.input = prepared.input ∧ record.lineage = prepared.lineage := by
              simpa [found] using preparedRelation.2
            have keyEq : record.input.attempt = prepared.input.attempt :=
              lookupAttempt_result_key state prepared.input.attempt record found
            simp only [found] at equation
            split at equation
            · injection equation with stateEq commandEq
              subst state' command
              have member : record ∈ state.attempts := by
                unfold lookupAttempt at found
                exact List.mem_of_find?_eq_some found
              have issued :
                  commandIssuedMatches
                      (replaceRecord state prepared.input.attempt
                        { record with disposition := .CommandIssued })
                      prepared = true := by
                unfold commandIssuedMatches replaceRecord
                apply List.any_eq_true.mpr
                refine ⟨{ record with disposition := .CommandIssued }, ?_, ?_⟩
                · exact List.mem_map.mpr ⟨record, member, by simp [keyEq]⟩
                · simp [fields.1, fields.2]
              exact
                ⟨⟨preparedRelation, dispositionReady⟩,
                  ⟨rfl, preparedRelation.2⟩,
                  by simp [SameExceptDisposition, found],
                  by simp [sendCommand, issued]⟩
            · contradiction
      · split at equation
        · cases preparedConditionFailure state prepared .IsPrepared <;> contradiction
        · contradiction
  · intro state prepared valid notReady
    by_cases issued : commandIssuedMatches state prepared
    · exact ⟨.CommandAlreadyIssued prepared.input.attempt, by simp [sendCommand, issued]⟩
    · cases failureEq : preparedConditionFailure state prepared .IsPrepared with
      | none =>
          have ready := (preparedReadyFailure_none_iff state prepared valid).mp failureEq
          exact False.elim (notReady ready)
      | some failure =>
          exact ⟨failure, by simp [sendCommand, issued, notReady, valid, failureEq]⟩

theorem start_success :
    ∀ (state state' : NetworkState) (prepared : PreparedAttempt) (key : AttemptIdentity)
      (handle : ExecutionHandle) (started : StartedAttempt),
      observeStart state prepared (.Started key handle) = .Started state' started →
        CommandIssuedRelation state prepared ∧
        key = prepared.input.attempt ∧
        AuthoritativePreparedAt state key started.prepared ∧
        started.handle = handle ∧
        StartedRelation state' started := by
  intro state state' prepared key handle started equation
  by_cases relation : StartObservationRelation state prepared (.Started key handle)
  · have commandRelation := relation.1
    have keyEq : key = prepared.input.attempt := relation.2
    cases found : lookupAttempt state key with
    | none =>
        rw [keyEq] at found
        simp [CommandIssuedRelation, PreparedRelation, found] at commandRelation
    | some record =>
        unfold observeStart at equation
        rw [dif_pos relation] at equation
        simp [found] at equation
        split at equation
        · split at equation
          · injection equation with stateEq startedEq
            subst state' started
            simp_all [CommandIssuedRelation, PreparedRelation,
              AuthoritativePreparedAt, StartedRelation]
          · contradiction
        · contradiction
  · unfold observeStart at equation
    rw [dif_neg relation] at equation
    split at equation
    · cases token : preparedConditionFailure state prepared .IsCommandIssued <;>
        simp [token] at equation
    · contradiction

theorem pre_handle_failure_provenance :
    ∀ (state state' : NetworkState) (prepared : PreparedAttempt)
      (failure : NetworkHostFailure) (effect : EffectStatus) (settled : SettledAttempt),
      observeStart state prepared (.StartFailed failure effect) = .Terminal state' settled →
        CommandIssuedRelation state prepared ∧
        failure.attempt = prepared.input.attempt ∧
        failure.stage = .Start ∧
        failure.configuration = prepared.input.configuration ∧
        EffectMatches prepared.input.attempt effect ∧
        settled.handle = none ∧
        settled.terminal = { outcome := .Failed failure, effect := effect } := by
  intro state state' prepared failure effect settled equation
  by_cases relation : StartObservationRelation state prepared (.StartFailed failure effect)
  · have commandRelation := relation.1
    have fields := relation.2
    cases found : lookupAttempt state prepared.input.attempt with
    | none =>
        simp [CommandIssuedRelation, PreparedRelation, found] at commandRelation
    | some record =>
        unfold observeStart at equation
        rw [dif_pos relation] at equation
        simp [found] at equation
        split at equation
        · injection equation with stateEq settledEq
          subst state' settled
          exact ⟨commandRelation, fields.1, fields.2.1, fields.2.2.1,
            fields.2.2.2, rfl, rfl⟩
        · contradiction
  · unfold observeStart at equation
    rw [dif_neg relation] at equation
    split at equation
    · cases token : preparedConditionFailure state prepared .IsCommandIssued with
      | some mismatch => simp [token] at equation
      | none =>
          simp [token] at equation
          repeat
            first
            | split at equation
            | cases equation
    · contradiction

private theorem observeStart_rejected_same_state :
    ∀ (state state' : NetworkState) (prepared : PreparedAttempt) (observation : StartObservation)
      (failure : NetworkFailure),
      observeStart state prepared observation = .Rejected state' failure → state' = state := by
  intro state state' prepared observation failure equation
  unfold observeStart at equation
  repeat
    first
    | simp only at equation
    | split at equation
    | injection equation <;> (try subst_vars) <;> (first | rfl | skip)

private theorem observeStart_successful_relation :
    ∀ (state : NetworkState) (prepared : PreparedAttempt) (start : StartObservation)
      (result : NetworkStep),
      observeStart state prepared start = result → SuccessfulNetworkStep result →
        CommandIssuedRelation state prepared ∧ StartObservationRelation state prepared start := by
  intro state prepared start result equation success
  by_cases hRelation : StartObservationRelation state prepared start
  · exact ⟨hRelation.1, hRelation⟩
  · cases start
    all_goals
      unfold observeStart at equation
      rw [dif_neg hRelation] at equation
      repeat
        first
        | split at equation
        | rw [← equation] at success
          simp [SuccessfulNetworkStep] at success

theorem identity_token_handle_capability_clock_preservation :
    (∀ (state state' : NetworkState) (started : StartedAttempt) (command : CancelCommand),
      cancelCommand state started = .CommandReady state' command →
        StartedRelation state started ∧ state' = state ∧
        command.attempt = started.prepared.input.attempt ∧
        command.handle = started.handle ∧
        some command.capability = started.prepared.input.configuration.cancellation) ∧
    (∀ (state : NetworkState) (started : StartedAttempt),
      ¬ StartedRelation state started →
        ∃ failure : NetworkFailure, cancelCommand state started = .Rejected state failure) ∧
    (∀ (state : NetworkState) (prepared : PreparedAttempt) (start : StartObservation)
      (result : NetworkStep),
      observeStart state prepared start = result → SuccessfulNetworkStep result →
        CommandIssuedRelation state prepared ∧ StartObservationRelation state prepared start) ∧
    (∀ (state : NetworkState) (prepared : PreparedAttempt) (start : StartObservation),
      ¬ StartObservationRelation state prepared start →
        ∃ failure : NetworkFailure, observeStart state prepared start = .Rejected state failure) ∧
    (∀ (state : NetworkState) (host : HostObservation) (result : NetworkStep),
      observe state host = result → SuccessfulNetworkStep result →
        HostObservationRelation state host) ∧
    (∀ (state : NetworkState) (host : HostObservation),
      ¬ HostObservationRelation state host →
        ∃ failure : NetworkFailure, observe state host = .Rejected state failure) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro state state' started command equation
    by_cases relation : StartedRelation state started
    · unfold cancelCommand at equation
      rw [dif_pos relation] at equation
      cases cancellation : started.prepared.input.configuration.cancellation with
      | none => simp [cancellation] at equation
      | some capability =>
          simp [cancellation] at equation
          rcases equation with ⟨rfl, rfl⟩
          exact ⟨relation, rfl, rfl, rfl, rfl⟩
    · unfold cancelCommand at equation
      rw [dif_neg relation] at equation
      repeat
        first
        | split at equation
        | cases equation
  · intro state started notRelation
    unfold cancelCommand
    rw [dif_neg notRelation]
    repeat split
    all_goals exact ⟨_, rfl⟩
  · exact observeStart_successful_relation
  · intro state prepared start notRelation
    cases hResult : observeStart state prepared start with
    | Rejected s f =>
        have same := observeStart_rejected_same_state state s prepared start f hResult
        exact ⟨f, by rw [same]⟩
    | Started a b =>
        exact absurd
          (observeStart_successful_relation state prepared start _ hResult
            (by simp [SuccessfulNetworkStep])).2 notRelation
    | Pending a b =>
        exact absurd
          (observeStart_successful_relation state prepared start _ hResult
            (by simp [SuccessfulNetworkStep])).2 notRelation
    | Terminal a b =>
        exact absurd
          (observeStart_successful_relation state prepared start _ hResult
            (by simp [SuccessfulNetworkStep])).2 notRelation
    | Late a b c =>
        exact absurd
          (observeStart_successful_relation state prepared start _ hResult
            (by simp [SuccessfulNetworkStep])).2 notRelation
    | Duplicate a b c =>
        exact absurd
          (observeStart_successful_relation state prepared start _ hResult
            (by simp [SuccessfulNetworkStep])).2 notRelation
  · intro state host result equation success
    by_cases relation : HostObservationRelation state host
    · exact relation
    · unfold observe at equation
      rw [dif_neg relation] at equation
      split at equation <;>
        rw [← equation] at success <;>
        simp [SuccessfulNetworkStep] at success
  · intro state host notRelation
    unfold observe
    rw [dif_neg notRelation]
    repeat split
    all_goals exact ⟨_, rfl⟩

theorem pending_stasis :
    ∀ (state : NetworkState) (started : StartedAttempt), ValidState state → StartedRelation state started →
      observe state (.Pending started.prepared.input.attempt started.handle) = .Pending state started := by
  intro state started valid relation
  rcases relation with ⟨stateValid, recordFacts⟩
  have hostRelation : HostObservationRelation state
      (.Pending started.prepared.input.attempt started.handle) := by
    change ValidState state ∧
      (match lookupAttempt state started.prepared.input.attempt with
       | some record => record.disposition = .Started started.handle
       | none => False)
    refine ⟨stateValid, ?_⟩
    cases hLookup : lookupAttempt state started.prepared.input.attempt with
    | none => simp [hLookup] at recordFacts
    | some record =>
        have fields :
            record.input = started.prepared.input ∧
              record.lineage = started.prepared.lineage ∧
              record.disposition = .Started started.handle ∧
              record.firstDelivery = none ∧ record.late = [] := by
          simpa [hLookup] using recordFacts
        exact fields.2.2.1
  unfold observe
  rw [dif_pos hostRelation]
  cases hLookup : lookupAttempt state started.prepared.input.attempt with
  | none => simp [hLookup] at recordFacts
  | some record =>
      have fields :
          record.input = started.prepared.input ∧
            record.lineage = started.prepared.lineage ∧
            record.disposition = .Started started.handle ∧
            record.firstDelivery = none ∧ record.late = [] := by
        simpa [hLookup] using recordFacts
      rcases fields with ⟨inputEq, lineageEq, _, _, _⟩
      simp [hLookup, inputEq, lineageEq]

theorem first_delivery_wins :
    ∀ (state state' : NetworkState) (started : StartedAttempt) (delivery : DeliveryOrdinal)
      (observation : AdapterObservation) (settled : SettledAttempt),
      StartedRelation state started →
      ExpectedNextDelivery state started.prepared.input.attempt delivery →
      ObservationRelation state observation →
      attemptOf observation = started.prepared.input.attempt →
      handleOf observation = started.handle →
      observe state (.Delivered delivery observation) = .Terminal state' settled →
        settled.terminal = terminalOf observation ∧
        FirstDeliveryAt state' started.prepared.input.attempt
          { delivery := delivery, observation := observation } := by
  intro state state' started delivery observation settled startedRel expected relation keyEq handleEq equation
  rcases startedRel with ⟨_, startedFacts⟩
  have hostRelation : HostObservationRelation state (.Delivered delivery observation) := relation
  cases hLookup : lookupAttempt state started.prepared.input.attempt with
  | none => simp [hLookup] at startedFacts
  | some record =>
      have fields :
          record.input = started.prepared.input ∧
            record.lineage = started.prepared.lineage ∧
            record.disposition = .Started started.handle ∧
            record.firstDelivery = none ∧ record.late = [] := by
        simpa [hLookup] using startedFacts
      rcases fields with ⟨_, _, dispositionEq, firstEq, lateEq⟩
      have expectedEq : expectedDeliveryOf record = delivery := by
        simpa [ExpectedNextDelivery, hLookup] using expected
      have unrecorded : recordedDelivery record delivery = none := by
        simp [recordedDelivery, firstEq, lateEq]
      simp only [observe, dif_pos hostRelation, dif_pos relation] at equation
      simp [keyEq, hLookup, unrecorded, expectedEq, dispositionEq] at equation
      split at equation
      · split at equation
        · rename_i validNext firstDelivery
          injection equation with stateEq settledEq
          subst state' settled
          exact ⟨rfl, by simpa [expectedEq] using firstDelivery⟩
        · contradiction
      · contradiction

theorem late_preservation :
    ∀ (state state' : NetworkState) (settled settled' : SettledAttempt) (delivery : DeliveryOrdinal)
      (observation : AdapterObservation) (late : LateObservation),
      RecordSettled state settled →
      ExpectedNextDelivery state settled.prepared.input.attempt delivery →
      ObservationRelation state observation →
      observe state (.Delivered delivery observation) = .Late state' settled' late →
        TerminalOfRecord state' settled.prepared.input.attempt =
            TerminalOfRecord state settled.prepared.input.attempt ∧
        InstructionOf state' settled.prepared.input.attempt =
            InstructionOf state settled.prepared.input.attempt ∧
        LineageOf state' settled.prepared.input.attempt =
            LineageOf state settled.prepared.input.attempt ∧
        EffectOf state' settled.prepared.input.attempt =
            EffectOf state settled.prepared.input.attempt := by
  intro state state' settled settled' delivery observation late recordRel expected relation equation
  unfold observe at equation
  cases hLookup : lookupAttempt state (attemptOf observation) with
  | none =>
      have impossible : False := by
        simpa [ObservationRelation, hLookup] using relation
      exact impossible.elim
  | some record =>
      simp [hLookup] at equation
      cases hRecorded : recordedDelivery record delivery with
      | some old =>
          simp [hRecorded, relation, HostObservationRelation] at equation
          split at equation <;> contradiction
      | none =>
          simp [hRecorded, relation, HostObservationRelation] at equation
          split at equation
          · cases hDisposition : record.disposition with
            | Prepared => simp [hDisposition] at equation
            | CommandIssued => simp [hDisposition] at equation
            | Started handle =>
                simp [hDisposition] at equation
                split at equation
                · split at equation <;> contradiction
                · contradiction
            | Settled handle terminal =>
                simp [hDisposition] at equation
                split at equation
                · split at equation
                  · injection equation with hState hSettled hLate
                    subst state' settled' late
                    exact appendLate_preserves_projections state (attemptOf observation)
                      settled.prepared.input.attempt
                      { delivered := { delivery := delivery, observation := observation } }
                  · contradiction
                · contradiction
          · contradiction

theorem delivery_source_orthogonality :
    ∀ (state : NetworkState) (delivery : DeliveryOrdinal) (left right : AdapterObservation),
      ValidState state → EqualExceptSourceSequence left right →
      ObservationRelation state left → ObservationRelation state right →
      ExpectedNextDelivery state (attemptOf left) delivery →
      (¬ ∃ recorded : AdapterObservation, RecordedDelivery state (attemptOf left) delivery recorded) →
      ResultClass (observe state (.Delivered delivery left)) =
          ResultClass (observe state (.Delivered delivery right)) ∧
      EraseSourceSequence (observe state (.Delivered delivery left)) =
          EraseSourceSequence (observe state (.Delivered delivery right)) := by
  intro state delivery left right valid sourceEq leftRel rightRel expected fresh
  have erasedObservation :
      eraseObservationSource left = eraseObservationSource right := by
    simpa [EqualExceptSourceSequence, eraseObservationSource] using sourceEq
  have keyEq : attemptOf left = attemptOf right := by
    calc
      attemptOf left = attemptOf (eraseObservationSource left) :=
        (attemptOf_eraseObservationSource left).symm
      _ = attemptOf (eraseObservationSource right) :=
        congrArg attemptOf erasedObservation
      _ = attemptOf right := attemptOf_eraseObservationSource right
  have terminalEq : terminalOf left = terminalOf right := by
    calc
      terminalOf left = terminalOf (eraseObservationSource left) :=
        (terminalOf_eraseObservationSource left).symm
      _ = terminalOf (eraseObservationSource right) :=
        congrArg terminalOf erasedObservation
      _ = terminalOf right := terminalOf_eraseObservationSource right
  have leftHost : HostObservationRelation state (.Delivered delivery left) := leftRel
  have rightHost : HostObservationRelation state (.Delivered delivery right) := rightRel
  cases hLookup : lookupAttempt state (attemptOf left) with
  | none =>
      simp [ExpectedNextDelivery, hLookup] at expected
  | some record =>
      have hLookupRight : lookupAttempt state (attemptOf right) = some record := by
        rw [← keyEq]
        exact hLookup
      have expectedEq : expectedDeliveryOf record = delivery := by
        simpa [ExpectedNextDelivery, hLookup] using expected
      have hRecorded : recordedDelivery record delivery = none := by
        cases equation : recordedDelivery record delivery with
        | none => rfl
        | some old =>
            exfalso
            apply fresh
            exact ⟨old, by simp [RecordedDelivery, hLookup, equation]⟩
      cases hDisposition : record.disposition with
      | Prepared =>
          simp [observe, leftHost, rightHost, leftRel, rightRel, hLookup, hLookupRight,
            hRecorded, expectedEq, hDisposition, keyEq]
      | CommandIssued =>
          simp [observe, leftHost, rightHost, leftRel, rightRel, hLookup, hLookupRight,
            hRecorded, expectedEq, hDisposition, keyEq]
      | Started handle =>
          let leftNext := replaceRecord state (attemptOf left)
            { input := record.input, lineage := record.lineage,
              disposition := .Settled (some handle) (terminalOf left),
              firstDelivery := some { delivery := delivery, observation := left }, late := [] }
          let rightNext := replaceRecord state (attemptOf right)
            { input := record.input, lineage := record.lineage,
              disposition := .Settled (some handle) (terminalOf right),
              firstDelivery := some { delivery := delivery, observation := right }, late := [] }
          have erasedNext : eraseStateSources leftNext = eraseStateSources rightNext := by
            simpa [leftNext, rightNext, keyEq] using
              eraseStateSources_firstDelivery_equal state (attemptOf left) record handle
                delivery left right erasedObservation
          have validIff : ValidState leftNext ↔ ValidState rightNext :=
            validState_of_erased_equal leftNext rightNext erasedNext
          have firstLeft :
              FirstDeliveryAt leftNext (attemptOf left)
                { delivery := delivery, observation := left } := by
            unfold FirstDeliveryAt leftNext
            have found := lookupAttempt_replaceRecord_self state (attemptOf left)
              { input := record.input, lineage := record.lineage,
                disposition := .Settled (some handle) (terminalOf left),
                firstDelivery := some { delivery := delivery, observation := left }, late := [] }
              record hLookup rfl
            rw [found]
          have firstRight :
              FirstDeliveryAt rightNext (attemptOf right)
                { delivery := delivery, observation := right } := by
            unfold FirstDeliveryAt rightNext
            have found := lookupAttempt_replaceRecord_self state (attemptOf right)
              { input := record.input, lineage := record.lineage,
                disposition := .Settled (some handle) (terminalOf right),
                firstDelivery := some { delivery := delivery, observation := right }, late := [] }
              record hLookupRight rfl
            rw [found]
          by_cases leftValid : ValidState leftNext
          · have rightValid := validIff.mp leftValid
            have leftStep :
                observe state (.Delivered delivery left) =
                  .Terminal leftNext
                    { prepared := { input := record.input, lineage := record.lineage },
                      handle := some handle, terminal := terminalOf left } := by
              simp [observe, leftHost, leftRel, hLookup, hRecorded, expectedEq,
                hDisposition, leftNext, leftValid, firstLeft]
            have rightStep :
                observe state (.Delivered delivery right) =
                  .Terminal rightNext
                    { prepared := { input := record.input, lineage := record.lineage },
                      handle := some handle, terminal := terminalOf right } := by
              simp [observe, rightHost, rightRel, hLookupRight, hRecorded, expectedEq,
                hDisposition, rightNext, rightValid, firstRight]
            rw [leftStep, rightStep]
            exact ⟨rfl, by simp [EraseSourceSequence, erasedNext, terminalEq]⟩
          · have rightInvalid : ¬ ValidState rightNext := by
              exact fun rightValid => leftValid (validIff.mpr rightValid)
            have violationEq : stateViolation leftNext = stateViolation rightNext := by
              calc
                stateViolation leftNext = stateViolation (eraseStateSources leftNext) :=
                  (stateViolation_eraseSources leftNext).symm
                _ = stateViolation (eraseStateSources rightNext) :=
                  congrArg stateViolation erasedNext
                _ = stateViolation rightNext := stateViolation_eraseSources rightNext
            have leftStep :
                observe state (.Delivered delivery left) =
                  .Rejected state (.InvalidNetworkState (stateViolation leftNext)) := by
              simp [observe, leftHost, leftRel, hLookup, hRecorded, expectedEq,
                hDisposition, leftNext, leftValid]
            have rightStep :
                observe state (.Delivered delivery right) =
                  .Rejected state (.InvalidNetworkState (stateViolation rightNext)) := by
              simp [observe, rightHost, rightRel, hLookupRight, hRecorded, expectedEq,
                hDisposition, rightNext, rightInvalid]
            rw [leftStep, rightStep]
            exact ⟨rfl, by simp [EraseSourceSequence, violationEq]⟩
      | Settled handle terminal =>
          let leftLate : LateObservation :=
            { delivered := { delivery := delivery, observation := left } }
          let rightLate : LateObservation :=
            { delivered := { delivery := delivery, observation := right } }
          let leftNext := appendLate state (attemptOf left) leftLate
          let rightNext := appendLate state (attemptOf right) rightLate
          let settled : SettledAttempt :=
            { prepared := { input := record.input, lineage := record.lineage },
              handle := handle, terminal := terminal }
          have erasedNext : eraseStateSources leftNext = eraseStateSources rightNext := by
            simpa [leftNext, rightNext, leftLate, rightLate, keyEq] using
              eraseStateSources_appendLate_equal state (attemptOf left) delivery left right
                erasedObservation
          have validIff : ValidState leftNext ↔ ValidState rightNext :=
            validState_of_erased_equal leftNext rightNext erasedNext
          have leftPreservation :
              LatePreservation state leftNext settled settled delivery left leftLate := by
            simpa [LatePreservation, leftNext, settled] using
              appendLate_preserves_projections state (attemptOf left)
                record.input.attempt leftLate
          have rightPreservation :
              LatePreservation state rightNext settled settled delivery right rightLate := by
            simpa [LatePreservation, rightNext, settled] using
              appendLate_preserves_projections state (attemptOf right)
                record.input.attempt rightLate
          have erasedLate :
              eraseDelivered { delivery := delivery, observation := left } =
                eraseDelivered { delivery := delivery, observation := right } := by
            simp [eraseDelivered, erasedObservation]
          by_cases leftValid : ValidState leftNext
          · have rightValid := validIff.mp leftValid
            have leftStep :
                observe state (.Delivered delivery left) =
                  .Late leftNext settled leftLate := by
              simp [observe, leftHost, leftRel, hLookup, hRecorded, expectedEq,
                hDisposition, leftLate, leftNext, settled, leftValid, leftPreservation]
            have rightStep :
                observe state (.Delivered delivery right) =
                  .Late rightNext settled rightLate := by
              simp [observe, rightHost, rightRel, hLookupRight, hRecorded, expectedEq,
                hDisposition, rightLate, rightNext, settled, rightValid, rightPreservation]
            rw [leftStep, rightStep]
            constructor
            · rfl
            · simp [EraseSourceSequence, erasedNext]
              simpa [leftLate, rightLate] using erasedLate
          · have rightInvalid : ¬ ValidState rightNext := by
              exact fun rightValid => leftValid (validIff.mpr rightValid)
            have violationEq : stateViolation leftNext = stateViolation rightNext := by
              calc
                stateViolation leftNext = stateViolation (eraseStateSources leftNext) :=
                  (stateViolation_eraseSources leftNext).symm
                _ = stateViolation (eraseStateSources rightNext) :=
                  congrArg stateViolation erasedNext
                _ = stateViolation rightNext := stateViolation_eraseSources rightNext
            have leftStep :
                observe state (.Delivered delivery left) =
                  .Rejected state (.InvalidNetworkState (stateViolation leftNext)) := by
              simp [observe, leftHost, leftRel, hLookup, hRecorded, expectedEq,
                hDisposition, leftLate, leftNext, settled, leftValid]
            have rightStep :
                observe state (.Delivered delivery right) =
                  .Rejected state (.InvalidNetworkState (stateViolation rightNext)) := by
              simp [observe, rightHost, rightRel, hLookupRight, hRecorded, expectedEq,
                hDisposition, rightLate, rightNext, settled, rightInvalid]
            rw [leftStep, rightStep]
            exact ⟨rfl, by simp [EraseSourceSequence, violationEq]⟩

private theorem foldObserve_ordered_late (state : NetworkState)
    (key : AttemptIdentity) (record : AttemptRecord)
    (handle : ExecutionHandle) (terminal : NetworkTerminal)
    (first : DeliveredObservation) (delivery : DeliveryOrdinal)
    (observations : List AdapterObservation)
    (valid : ValidState state) (found : lookupAttempt state key = some record)
    (disposition : record.disposition = .Settled (some handle) terminal)
    (firstDelivery : record.firstDelivery = some first)
    (expected : expectedDeliveryOf record = delivery)
    (relations : ∀ observation ∈ observations,
      observationMatchesRecord record observation = true)
    (sameAttempt : ∀ observation ∈ observations, attemptOf observation = key)
    (sameHandle : ∀ observation ∈ observations, handleOf observation = handle) :
    ∃ finalRecord : AttemptRecord,
      ValidState (FoldObserve state (assignDeliveries delivery observations)) ∧
      lookupAttempt (FoldObserve state (assignDeliveries delivery observations)) key =
        some finalRecord ∧
      finalRecord.input = record.input ∧
      finalRecord.lineage = record.lineage ∧
      finalRecord.disposition = .Settled (some handle) terminal ∧
      finalRecord.firstDelivery = some first ∧
      finalRecord.late = record.late ++ assignOrderedLate delivery observations := by
  induction observations generalizing state record delivery with
  | nil =>
      refine ⟨record, ?_, ?_, rfl, rfl, disposition, firstDelivery, ?_⟩
      · simpa [FoldObserve, assignDeliveries] using valid
      · simpa [FoldObserve, assignDeliveries] using found
      · simp [assignOrderedLate]
  | cons observation rest ih =>
      have headMatch := relations observation (by simp)
      have headAttempt := sameAttempt observation (by simp)
      have headHandle := sameHandle observation (by simp)
      have headRelation : ObservationRelation state observation := by
        refine ⟨valid, ?_⟩
        rw [headAttempt, found]
        exact headMatch
      let item : LateObservation :=
        { delivered := { delivery := delivery, observation := observation } }
      let nextState := appendLate state key item
      let nextRecord : AttemptRecord :=
        { record with late := record.late ++ [item] }
      have stepExpected :=
        observe_settled_expected state key record handle terminal observation valid found
          disposition headRelation headAttempt headHandle
      have step :
          observe state (.Delivered delivery observation) =
            .Late nextState
              { prepared := { input := record.input, lineage := record.lineage },
                handle := some handle, terminal := terminal }
              item := by
        simpa [item, nextState, expected] using stepExpected
      have nextValid : ValidState nextState := by
        have preserved :=
          appendLate_expected_valid state key record handle terminal observation valid found
            disposition headRelation headAttempt headHandle
        simpa [item, nextState, expected] using preserved
      have nextFound : lookupAttempt nextState key = some nextRecord := by
        have replaced :=
          lookupAttempt_replaceRecord_self state key nextRecord record found (by rfl)
        simpa [nextState, nextRecord, appendLate, found, item] using replaced
      have nextDisposition : nextRecord.disposition = .Settled (some handle) terminal := by
        simpa [nextRecord] using disposition
      have nextFirst : nextRecord.firstDelivery = some first := by
        simpa [nextRecord] using firstDelivery
      have nextExpected : expectedDeliveryOf nextRecord = delivery + 1 := by
        simp [nextRecord, item, expectedDeliveryOf, firstDelivery, lastLate_append_singleton]
      have tailMatches :
          ∀ candidate ∈ rest, observationMatchesRecord nextRecord candidate = true := by
        intro candidate membership
        have oldMatch := relations candidate (by simp [membership])
        have congruence :=
          observationMatchesRecord_congr nextRecord record candidate rfl (by rfl)
        rw [congruence]
        exact oldMatch
      have tailAttempts : ∀ candidate ∈ rest, attemptOf candidate = key := by
        intro candidate membership
        exact sameAttempt candidate (by simp [membership])
      have tailHandles : ∀ candidate ∈ rest, handleOf candidate = handle := by
        intro candidate membership
        exact sameHandle candidate (by simp [membership])
      rcases ih nextState nextRecord (delivery + 1) nextValid nextFound nextDisposition
        nextFirst nextExpected tailMatches tailAttempts tailHandles with
        ⟨finalRecord, finalValid, finalFound, finalInput, finalLineage,
          finalDisposition, finalFirst, finalLate⟩
      refine ⟨finalRecord, ?_, ?_, ?_, ?_, finalDisposition, finalFirst, ?_⟩
      · simpa [FoldObserve, assignDeliveries, observeStepState, step] using finalValid
      · simpa [FoldObserve, assignDeliveries, observeStepState, step] using finalFound
      · simpa [nextRecord] using finalInput
      · simpa [nextRecord] using finalLineage
      · calc
          finalRecord.late =
              nextRecord.late ++ assignOrderedLate (delivery + 1) rest := finalLate
          _ = record.late ++
              ({ delivered := { delivery := delivery, observation := observation } } ::
                assignOrderedLate (delivery + 1) rest) := by
                simp [nextRecord, item, List.append_assoc]
          _ = record.late ++ assignOrderedLate delivery (observation :: rest) := rfl

set_option maxHeartbeats 1000000 in
theorem race_completeness :
    ∀ (state : NetworkState) (started : StartedAttempt)
      (response cancellation deadline failure : AdapterObservation)
      (permutation : List AdapterObservation),
      ValidState state → StartedRelation state started →
      permutation.Perm [response, cancellation, deadline, failure] →
      ResponseKind response → CancellationKind cancellation → ValidDeadlineKind deadline →
      FailureKind failure → ObservationRelation state response → ObservationRelation state cancellation →
      ObservationRelation state deadline → ObservationRelation state failure →
      attemptOf response = started.prepared.input.attempt →
      attemptOf cancellation = started.prepared.input.attempt →
      attemptOf deadline = started.prepared.input.attempt →
      attemptOf failure = started.prepared.input.attempt →
      handleOf response = started.handle → handleOf cancellation = started.handle →
      handleOf deadline = started.handle → handleOf failure = started.handle →
      DeadlineFieldsMatch started.prepared.input.deadline
        started.prepared.input.configuration.monotonicClock deadline →
      OneWinnerAndOrderedLate permutation
        (FoldObserve state (AssignContiguousDelivery permutation)) := by
  intro state started response cancellation deadline failure permutation valid startedRel permutationRel
    responseKind cancellationKind deadlineKind failureKind responseRel cancellationRel deadlineRel failureRel
    responseKey cancellationKey deadlineKey failureKey responseHandle cancellationHandle deadlineHandle failureHandle
    deadlineFields
  have relationFor :
      ∀ observation ∈ permutation, ObservationRelation state observation := by
    intro observation membership
    have canonical := (permutationRel.mem_iff).mp membership
    simp at canonical
    rcases canonical with rfl | rfl | rfl | rfl
    · exact responseRel
    · exact cancellationRel
    · exact deadlineRel
    · exact failureRel
  have attemptFor :
      ∀ observation ∈ permutation,
        attemptOf observation = started.prepared.input.attempt := by
    intro observation membership
    have canonical := (permutationRel.mem_iff).mp membership
    simp at canonical
    rcases canonical with rfl | rfl | rfl | rfl
    · exact responseKey
    · exact cancellationKey
    · exact deadlineKey
    · exact failureKey
  have handleFor :
      ∀ observation ∈ permutation, handleOf observation = started.handle := by
    intro observation membership
    have canonical := (permutationRel.mem_iff).mp membership
    simp at canonical
    rcases canonical with rfl | rfl | rfl | rfl
    · exact responseHandle
    · exact cancellationHandle
    · exact deadlineHandle
    · exact failureHandle
  cases permutation with
  | nil =>
      exfalso
      have length := permutationRel.length_eq
      simp at length
  | cons winner later =>
      rcases startedRel with ⟨startedValid, recordFacts⟩
      cases found : lookupAttempt state started.prepared.input.attempt with
      | none =>
          simp [found] at recordFacts
      | some record =>
          have fields :
              record.input = started.prepared.input ∧
              record.lineage = started.prepared.lineage ∧
              record.disposition = .Started started.handle ∧
              record.firstDelivery = none ∧ record.late = [] := by
            simpa [found] using recordFacts
          rcases fields with
            ⟨recordInput, recordLineage, disposition, firstNone, lateNone⟩
          have winnerRelation := relationFor winner (by simp)
          have winnerAttempt := attemptFor winner (by simp)
          have winnerHandle := handleFor winner (by simp)
          let firstDelivered : DeliveredObservation :=
            { delivery := 0, observation := winner }
          let firstRecord : AttemptRecord :=
            { input := record.input, lineage := record.lineage,
              disposition := .Settled (some started.handle) (terminalOf winner),
              firstDelivery := some firstDelivered, late := [] }
          let firstState : NetworkState :=
            replaceRecord state started.prepared.input.attempt firstRecord
          have firstStep :
              observe state (.Delivered 0 winner) =
                .Terminal firstState
                  { prepared := { input := record.input, lineage := record.lineage },
                    handle := some started.handle, terminal := terminalOf winner } := by
            simpa [firstState, firstRecord, firstDelivered] using
              observe_started_first state started record winner valid found recordInput
                recordLineage disposition firstNone lateNone winnerRelation winnerAttempt
                winnerHandle
          have firstValid : ValidState firstState := by
            simpa [firstState, firstRecord, firstDelivered] using
              firstDelivery_update_valid state started record winner valid found recordInput
                recordLineage disposition winnerRelation winnerAttempt winnerHandle
          have firstFound :
              lookupAttempt firstState started.prepared.input.attempt = some firstRecord := by
            have replaced :=
              lookupAttempt_replaceRecord_self state started.prepared.input.attempt
                firstRecord record found (by simp [firstRecord])
            simpa [firstState] using replaced
          have laterMatches :
              ∀ observation ∈ later,
                observationMatchesRecord firstRecord observation = true := by
            intro observation membership
            have baseRelation := relationFor observation (by simp [membership])
            have observationAttempt := attemptFor observation (by simp [membership])
            have baseMatch : observationMatchesRecord record observation = true := by
              rcases baseRelation with ⟨_, relationMatch⟩
              simpa [observationAttempt, found] using relationMatch
            have congruence :=
              observationMatchesRecord_congr firstRecord record observation rfl
                (by simp [firstRecord, disposition, dispositionHandle])
            rw [congruence]
            exact baseMatch
          have laterAttempts :
              ∀ observation ∈ later,
                attemptOf observation = started.prepared.input.attempt := by
            intro observation membership
            exact attemptFor observation (by simp [membership])
          have laterHandles :
              ∀ observation ∈ later, handleOf observation = started.handle := by
            intro observation membership
            exact handleFor observation (by simp [membership])
          have firstExpected : expectedDeliveryOf firstRecord = 1 := by
            simp [firstRecord, firstDelivered, expectedDeliveryOf, lastLate]
          rcases
              foldObserve_ordered_late firstState started.prepared.input.attempt firstRecord
                started.handle (terminalOf winner) firstDelivered 1 later firstValid
                firstFound (by rfl) (by rfl) firstExpected laterMatches laterAttempts
                laterHandles with
            ⟨finalRecord, finalValid, finalFound, finalInput, finalLineage,
              finalDisposition, finalFirst, finalLate⟩
          have folded :
              FoldObserve state (AssignContiguousDelivery (winner :: later)) =
                FoldObserve firstState (assignDeliveries 1 later) := by
            simp [AssignContiguousDelivery, assignDeliveries, FoldObserve, observeStepState,
              firstStep]
          unfold OneWinnerAndOrderedLate
          refine ⟨finalRecord, ?_, ?_, ?_, ?_⟩
          · rw [folded, winnerAttempt]
            exact finalFound
          · simpa [winnerHandle] using finalDisposition
          · simpa [firstDelivered] using finalFirst
          · simpa [firstRecord] using finalLate

theorem duplicate_discrimination :
    (∀ (state : NetworkState) (key : AttemptIdentity) (delivery : DeliveryOrdinal)
      (observation : AdapterObservation), ValidState state →
      RecordedDelivery state key delivery observation → ObservationRelation state observation →
      attemptOf observation = key →
      observe state (.Delivered delivery observation) = .Duplicate state key delivery) ∧
    (∀ (state : NetworkState) (key : AttemptIdentity) (delivery : DeliveryOrdinal)
      (old fresh : AdapterObservation), ValidState state → RecordedDelivery state key delivery old →
      ObservationRelation state old → ObservationRelation state fresh →
      attemptOf old = key → attemptOf fresh = key → handleOf old = handleOf fresh → old ≠ fresh →
      observe state (.Delivered delivery fresh) =
        .Rejected state (.ConflictingDelivery key delivery old fresh)) ∧
    (∀ (state : NetworkState) (key : AttemptIdentity) (delivery : DeliveryOrdinal)
      (old malformed : AdapterObservation), ValidState state → RecordedDelivery state key delivery old →
      ObservationRelation state old → attemptOf old = key → old ≠ malformed →
      ¬ ObservationRelation state malformed →
      ∃ failure : NetworkFailure,
        observe state (.Delivered delivery malformed) = .Rejected state failure ∧
        failure ≠ .ConflictingDelivery key delivery old malformed ∧
        FailureCategory failure ≠ .Delivery) := by
  constructor
  · intro state key delivery observation valid recorded relation keyEq
    cases hLookup : lookupAttempt state key with
    | none => simp [RecordedDelivery, hLookup] at recorded
    | some record =>
        have recordedHere : recordedDelivery record delivery = some observation := by
          simpa [RecordedDelivery, hLookup] using recorded
        have hostRelation : HostObservationRelation state (.Delivered delivery observation) := by
          change ObservationRelation state observation
          exact relation
        simp [observe, hostRelation, relation, keyEq, hLookup, recordedHere]
  constructor
  · intro state key delivery old fresh valid recorded oldRel freshRel oldKey freshKey handleEq differ
    cases hLookup : lookupAttempt state key with
    | none => simp [RecordedDelivery, hLookup] at recorded
    | some record =>
        have recordedHere : recordedDelivery record delivery = some old := by
          simpa [RecordedDelivery, hLookup] using recorded
        have hostRelation : HostObservationRelation state (.Delivered delivery fresh) := by
          change ObservationRelation state fresh
          exact freshRel
        simp [observe, hostRelation, freshRel, oldKey, freshKey, hLookup, recordedHere, differ]
  · intro state key delivery old malformed valid recorded oldRel oldKey differ malformedRel
    have hostRelationFalse :
        ¬ HostObservationRelation state (.Delivered delivery malformed) := by
      change ¬ ObservationRelation state malformed
      exact malformedRel
    let failure := hostObservationFailure state (.Delivered delivery malformed)
    have category : FailureCategory failure ≠ .Delivery :=
      hostObservationFailure_not_delivery state (.Delivered delivery malformed)
    refine ⟨failure, ?_, ?_, category⟩
    · simp [observe, hostRelationFalse, valid, failure]
    · intro conflict
      apply category
      rw [conflict]
      rfl

private theorem terminalOf_effect_eq_effectOfObservation (observation : AdapterObservation) :
    (terminalOf observation).effect = effectOfObservation observation := by
  cases observation <;> rfl

theorem effect_witness_separation :
    (∀ (state state' : NetworkState) (delivery : DeliveryOrdinal) (observation : AdapterObservation)
        (settled : SettledAttempt),
      observe state (.Delivered delivery observation) = .Terminal state' settled →
      settled.terminal.effect = effectOfObservation observation) ∧
    (∀ (state state' : NetworkState) (prepared : PreparedAttempt) (failure : NetworkHostFailure)
        (effect : EffectStatus) (settled : SettledAttempt),
      observeStart state prepared (.StartFailed failure effect) = .Terminal state' settled →
      settled.terminal.effect = effect) ∧
    (∀ (key : AttemptIdentity) (terminal : NetworkTerminal) (witness : EffectWitness),
      TerminalForAttempt key terminal →
      (terminal.effect = .NoEffect witness ∨ terminal.effect = .EffectOccurred witness) →
      witness.attempt = key ∧ (witness.source = .Adapter ∨ witness.source = .Protocol)) ∧
    (∀ (state state' : NetworkState) (key : AttemptIdentity) (status : EffectStatus)
        (witness : EffectWitness),
      annotateEffect state { attempt := key, status := status } = .Applied state' →
      (status = .NoEffect witness ∨ status = .EffectOccurred witness) →
      witness.attempt = key ∧ (witness.source = .Adapter ∨ witness.source = .Protocol)) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro state state' delivery observation settled equation
    unfold observe at equation
    by_cases hHost : HostObservationRelation state (.Delivered delivery observation)
    · rw [dif_pos hHost] at equation
      simp only at equation
      have hObservation : ObservationRelation state observation := by
        change ObservationRelation state observation at hHost
        exact hHost
      rw [dif_pos hObservation] at equation
      cases hLookup : lookupAttempt state (attemptOf observation) with
      | none => rw [hLookup] at equation; simp only at equation; contradiction
      | some record =>
          rw [hLookup] at equation
          simp only at equation
          cases hRecorded : recordedDelivery record delivery with
          | some old => rw [hRecorded] at equation; simp only at equation; split at equation <;> contradiction
          | none =>
              rw [hRecorded] at equation
              simp only at equation
              split at equation
              · contradiction
              · cases hDisposition : record.disposition with
                | Prepared => rw [hDisposition] at equation; simp only at equation; contradiction
                | CommandIssued => rw [hDisposition] at equation; simp only at equation; contradiction
                | Started actualHandle =>
                    rw [hDisposition] at equation
                    simp only at equation
                    split at equation
                    · split at equation
                      · injection equation with hState hSettled
                        subst state' settled
                        exact terminalOf_effect_eq_effectOfObservation observation
                      · contradiction
                    · contradiction
                | Settled actualHandle actualTerminal =>
                    rw [hDisposition] at equation
                    simp only at equation
                    split at equation
                    · split at equation <;> contradiction
                    · contradiction
    · rw [dif_neg hHost] at equation
      split at equation <;> contradiction
  · intro state state' prepared failure effect settled equation
    have facts := pre_handle_failure_provenance state state' prepared failure effect settled equation
    rw [facts.2.2.2.2.2.2]
  · intro key terminal witness terminalRel effectEq
    have sourceFact : witness.source = .Adapter ∨ witness.source = .Protocol := by
      cases witness.source <;> simp
    rcases effectEq with h | h
    · change EffectMatches key terminal.effect at terminalRel
      rw [h] at terminalRel
      exact ⟨terminalRel, sourceFact⟩
    · change EffectMatches key terminal.effect at terminalRel
      rw [h] at terminalRel
      exact ⟨terminalRel, sourceFact⟩
  · intro state state' key status witness equation statusEq
    have sourceFact : witness.source = .Adapter ∨ witness.source = .Protocol := by
      cases witness.source <;> simp
    by_cases valid : ValidState state
    · unfold annotateEffect at equation
      rw [dif_pos valid] at equation
      cases hLookup : lookupAttempt state key with
      | none => rw [hLookup] at equation; simp only at equation; contradiction
      | some record =>
          rw [hLookup] at equation
          simp only at equation
          cases hDisposition : record.disposition with
          | Prepared => rw [hDisposition] at equation; simp only at equation; contradiction
          | CommandIssued => rw [hDisposition] at equation; simp only at equation; contradiction
          | Started actualHandle => rw [hDisposition] at equation; simp only at equation; contradiction
          | Settled actualHandle actualTerminal =>
              rw [hDisposition] at equation
              simp only at equation
              by_cases hMatches : EffectMatches key status
              · rw [dif_pos hMatches] at equation
                rcases statusEq with h | h
                · rw [h] at hMatches; exact ⟨hMatches, sourceFact⟩
                · rw [h] at hMatches; exact ⟨hMatches, sourceFact⟩
              · rw [dif_neg hMatches] at equation
                contradiction
    · unfold annotateEffect at equation
      rw [dif_neg valid] at equation
      contradiction

private theorem replaceRecord_self_of_valid (state : NetworkState)
    (key : AttemptIdentity) (record : AttemptRecord)
    (valid : ValidState state) (found : lookupAttempt state key = some record) :
    replaceRecord state key record = state := by
  have invariant := valid
  unfold ValidState stateInvariantBool at invariant
  simp only [Bool.and_eq_true] at invariant
  have unique := invariant.1.1.1.1
  have foundList := found
  unfold lookupAttempt at foundList
  unfold replaceRecord
  congr 1
  have mapped :
      state.attempts.map
          (fun candidate => if candidate.input.attempt = key then record else candidate) =
        state.attempts.map id := by
    apply List.map_eq_map_iff.mpr
    intro candidate membership
    by_cases same : candidate.input.attempt = key
    · have candidateEq :=
        keysUnique_lookup_member_eq state.attempts key record candidate unique foundList
          membership same
      subst candidate
      simp [same]
    · simp [same]
  simpa using mapped

private theorem effect_application_facts (state state' : NetworkState)
    (key : AttemptIdentity) (reason : UnknownEffectReason)
    (requested : EffectStatus)
    (current : CurrentEffect state key = some (.Unknown reason))
    (requestedMatch : EffectMatches key requested)
    (unknownAccept : annotationStatusOk (.Unknown reason) requested = true)
    (replayAccept : annotationStatusOk requested requested = true)
    (equation :
      annotateEffect state { attempt := key, status := requested } = .Applied state') :
    SameExceptEffect state state' key ∧
    annotateEffect state' { attempt := key, status := requested } = .Applied state' ∧
    ∀ opposite : EffectStatus,
      EffectMatches key opposite →
      annotationStatusOk requested opposite = false →
      annotationConflict requested opposite = true →
      annotateEffect state' { attempt := key, status := opposite } =
        .Rejected state' (.EffectKnowledgeConflict key) := by
  by_cases stateValid : ValidState state
  · cases found : lookupAttempt state key with
    | none =>
        simp [annotateEffect, stateValid, found] at equation
    | some record =>
        cases disposition : record.disposition with
        | Prepared =>
            simp [annotateEffect, stateValid, found, disposition] at equation
        | CommandIssued =>
            simp [annotateEffect, stateValid, found, disposition] at equation
        | Started handle =>
            simp [annotateEffect, stateValid, found, disposition] at equation
        | Settled handle terminal =>
            have terminalEffect : terminal.effect = .Unknown reason := by
              simpa [CurrentEffect, EffectOf, found, disposition, terminalOfDisposition] using current
            have accepted : annotationStatusOk terminal.effect requested = true := by
              simpa [terminalEffect] using unknownAccept
            unfold annotateEffect at equation
            rw [dif_pos stateValid] at equation
            simp only [found] at equation
            rw [disposition] at equation
            simp only at equation
            rw [dif_pos requestedMatch, dif_pos accepted] at equation
            by_cases nextValid : ValidState (setEffect state key requested)
            · rw [dif_pos nextValid] at equation
              by_cases same : SameExceptEffect state (setEffect state key requested) key
              · rw [dif_pos same] at equation
                injection equation with stateEq
                subst state'
                let updated : AttemptRecord :=
                  { record with
                    disposition := .Settled handle { terminal with effect := requested } }
                have setEquation :
                    setEffect state key requested = replaceRecord state key updated := by
                  simp [setEffect, found, disposition, updated]
                have nextFound :
                    lookupAttempt (setEffect state key requested) key = some updated := by
                  rw [setEquation]
                  exact lookupAttempt_replaceRecord_self state key updated record found rfl
                have replaceIdentity :
                    replaceRecord (setEffect state key requested) key updated =
                      setEffect state key requested :=
                  replaceRecord_self_of_valid (setEffect state key requested) key updated
                    nextValid nextFound
                have setSame :
                    setEffect (setEffect state key requested) key requested =
                      setEffect state key requested := by
                  change
                    (match lookupAttempt (setEffect state key requested) key with
                     | some nextRecord =>
                         match nextRecord.disposition with
                         | .Settled nextHandle nextTerminal =>
                             replaceRecord (setEffect state key requested) key
                               { nextRecord with
                                 disposition := .Settled nextHandle
                                   { nextTerminal with effect := requested } }
                         | _ => setEffect state key requested
                     | none => setEffect state key requested) =
                      setEffect state key requested
                  rw [nextFound]
                  simpa [updated] using replaceIdentity
                have sameReflexive :
                    SameExceptEffect (setEffect state key requested)
                      (setEffect state key requested) key := by
                  simp [SameExceptEffect]
                have replay :
                    annotateEffect (setEffect state key requested)
                        { attempt := key, status := requested } =
                      .Applied (setEffect state key requested) := by
                  simp [annotateEffect, nextValid, nextFound, updated, requestedMatch,
                    replayAccept, setSame, sameReflexive]
                refine ⟨same, replay, ?_⟩
                intro opposite oppositeMatch different conflict
                simp [annotateEffect, nextValid, nextFound, updated, oppositeMatch,
                  different, conflict]
              · rw [dif_neg same] at equation
                contradiction
            · rw [dif_neg nextValid] at equation
              contradiction
  · simp [annotateEffect, stateValid] at equation

theorem effect_monotonicity :
    (∀ (state state' : NetworkState) (key : AttemptIdentity) (witness : EffectWitness)
      (reason : UnknownEffectReason),
      CurrentEffect state key = some (.Unknown reason) →
      EffectMatches key (.NoEffect witness) →
      annotateEffect state { attempt := key, status := .NoEffect witness } = .Applied state' →
      SameExceptEffect state state' key ∧
      annotateEffect state' { attempt := key, status := .NoEffect witness } = .Applied state' ∧
      ∀ conflictingWitness : EffectWitness,
        EffectMatches key (.EffectOccurred conflictingWitness) →
        annotateEffect state'
            { attempt := key, status := .EffectOccurred conflictingWitness } =
          .Rejected state' (.EffectKnowledgeConflict key)) ∧
    (∀ (state state' : NetworkState) (key : AttemptIdentity) (witness : EffectWitness)
      (reason : UnknownEffectReason),
      CurrentEffect state key = some (.Unknown reason) →
      EffectMatches key (.EffectOccurred witness) →
      annotateEffect state { attempt := key, status := .EffectOccurred witness } = .Applied state' →
      SameExceptEffect state state' key ∧
      annotateEffect state' { attempt := key, status := .EffectOccurred witness } = .Applied state' ∧
      ∀ conflictingWitness : EffectWitness,
        EffectMatches key (.NoEffect conflictingWitness) →
        annotateEffect state' { attempt := key, status := .NoEffect conflictingWitness } =
          .Rejected state' (.EffectKnowledgeConflict key)) := by
  constructor
  · intro state state' key witness reason current effectMatch equation
    rcases
        effect_application_facts state state' key reason (.NoEffect witness) current
          effectMatch rfl (by simp [annotationStatusOk]) equation with
      ⟨same, replay, conflicts⟩
    refine ⟨same, replay, ?_⟩
    intro conflictingWitness conflictingMatch
    exact conflicts (.EffectOccurred conflictingWitness) conflictingMatch rfl rfl
  · intro state state' key witness reason current effectMatch equation
    rcases
        effect_application_facts state state' key reason (.EffectOccurred witness) current
          effectMatch rfl (by simp [annotationStatusOk]) equation with
      ⟨same, replay, conflicts⟩
    refine ⟨same, replay, ?_⟩
    intro conflictingWitness conflictingMatch
    exact conflicts (.NoEffect conflictingWitness) conflictingMatch rfl rfl

theorem retry_causal_append :
    ∀ (state state' : NetworkState) (request : RetryRequest) (prepared : PreparedAttempt),
      retry state request = .Prepared state' prepared →
        ∃ authorization : RetryAuthorization,
          request.permission = .RetryAllowed authorization ∧
          ParentIsSettledMaximum state authorization.«from» ∧
          authorization.logical = authorization.«from».logical ∧
          authorization.logical = authorization.next.logical ∧
          authorization.next.ordinal = authorization.«from».ordinal + 1 ∧
          LedgerPrefix state state' ∧
          ExactlyOneRecordAdded state state' authorization.next ∧
          prepared.lineage = .RetryOf authorization := by
  intro state state' request prepared equation
  cases hPermission : request.permission with
  | RetryDenied logical parent evidence =>
      have impossible : False := by
        simpa [retry, retryPermissionAcceptable, hPermission] using equation
      exact impossible.elim
  | RetryAllowed authorization =>
      let retryInput : AttemptInput :=
        { attempt := authorization.next, instruction := request.instruction,
          deadline := request.deadline, configuration := request.configuration }
      let retryPrepared : PreparedAttempt :=
        { input := retryInput, lineage := .RetryOf authorization }
      let retryRecord : AttemptRecord :=
        { input := retryInput, lineage := .RetryOf authorization, disposition := .Prepared,
          firstDelivery := none, late := [] }
      have accepted : retryPermissionAcceptable state request := by
        by_cases hAccept : retryPermissionAcceptable state request
        · exact hAccept
        · simp [retry, hAccept, hPermission] at equation
      have outputFields :
          state' = appendRecord state retryRecord ∧ prepared = retryPrepared := by
        have hEquation := equation
        unfold retry at hEquation
        rw [dif_pos accepted] at hEquation
        simp only [hPermission] at hEquation
        split at hEquation
        · split at hEquation
          · injection hEquation with hState hPrepared
            exact ⟨hState.symm, hPrepared.symm⟩
          · contradiction
        · contradiction
      have acceptedFacts :
          ValidState state ∧ ValidAttemptInput retryInput ∧
            authorization.logical = authorization.«from».logical ∧
            authorization.logical = authorization.next.logical ∧
            authorization.next.ordinal = authorization.«from».ordinal + 1 ∧
            ParentIsSettledMaximum state authorization.«from» ∧
            NoAttemptRecord state authorization.next ∧
            retryAuthorizationAvailable state authorization = true := by
        simpa [retryPermissionAcceptable, hPermission, retryInput] using accepted
      rcases acceptedFacts with ⟨_, _, logicalFrom, logicalNext, ordinalNext, parentMaximum, _, _⟩
      rcases outputFields with ⟨stateEq, preparedEq⟩
      refine ⟨authorization, rfl, parentMaximum, logicalFrom, logicalNext,
        ordinalNext, ?_, ?_, ?_⟩
      · exact ⟨[retryRecord], by simp [appendRecord, stateEq]⟩
      · exact ⟨retryRecord, by simp [appendRecord, stateEq], by simp [retryRecord, retryInput]⟩
      · simpa [retryPrepared] using congrArg PreparedAttempt.lineage preparedEq

theorem retry_one_use :
    ∀ (state state' : NetworkState) (request : RetryRequest) (prepared : PreparedAttempt)
      (authorization : RetryAuthorization),
      retry state request = .Prepared state' prepared →
      request.permission = .RetryAllowed authorization →
      ∃ failure₁ failure₂ : NetworkFailure,
        retry state' request = .Rejected state' failure₁ ∧
        retry state' (AlternateAuthorizationSameNext request authorization) =
          .Rejected state' failure₂ := by
  intro state state' request prepared authorization equation permission
  let retryInput : AttemptInput :=
    { attempt := authorization.next, instruction := request.instruction,
      deadline := request.deadline, configuration := request.configuration }
  let retryRecord : AttemptRecord :=
    { input := retryInput, lineage := .RetryOf authorization, disposition := .Prepared,
      firstDelivery := none, late := [] }
  have accepted : retryPermissionAcceptable state request := by
    by_cases hAccepted : retryPermissionAcceptable state request
    · exact hAccepted
    · simp [retry, hAccepted, permission] at equation
  have appended : state'.attempts = state.attempts ++ [retryRecord] := by
    unfold retry at equation
    rw [dif_pos accepted] at equation
    simp only [permission] at equation
    split at equation
    · split at equation
      · injection equation with stateEq preparedEq
        subst state' prepared
        rfl
      · contradiction
    · contradiction
  have noNext : ¬ NoAttemptRecord state' authorization.next := by
    intro present
    unfold NoAttemptRecord at present
    rw [appended] at present
    simp [retryRecord, retryInput] at present
  have unacceptable : ¬ retryPermissionAcceptable state' request := by
    intro acceptableAgain
    rcases (by simpa [retryPermissionAcceptable, permission] using acceptableAgain) with
      ⟨_, _, _, _, _, _, nextUnused, _⟩
    exact noNext nextUnused
  let alternate := AlternateAuthorizationSameNext request authorization
  have alternateUnacceptable : ¬ retryPermissionAcceptable state' alternate := by
    intro acceptableAgain
    rcases (by simpa [retryPermissionAcceptable, alternate, AlternateAuthorizationSameNext] using
      acceptableAgain) with ⟨_, _, _, _, _, _, nextUnused, _⟩
    exact noNext nextUnused
  refine ⟨.RetryNotPermitted authorization.«from», .RetryNotPermitted authorization.«from», ?_, ?_⟩
  · change retry state' request = .Rejected state' (.RetryNotPermitted authorization.«from»)
    simp [retry, unacceptable, permission, retryFailureKey]
  · by_cases hAlternate : retryPermissionAcceptable state' alternate
    · exact False.elim (alternateUnacceptable hAlternate)
    · unfold retry
      rw [dif_neg hAlternate]
      simp [alternate, AlternateAuthorizationSameNext, retryFailureKey]

theorem retry_denial :
    ∀ (state : NetworkState) (request : RetryRequest), DeniedOrMalformedRetry state request →
      ∃ failure : NetworkFailure, retry state request = .Rejected state failure := by
  intro state request denied
  refine ⟨denialFailure request, ?_⟩
  change ¬ retryPermissionAcceptable state request at denied
  cases hPermission : request.permission with
  | RetryDenied logical parent evidence =>
      simp [retry, hPermission, retryPermissionAcceptable, denialFailure, retryFailureKey]
  | RetryAllowed authorization =>
      simp [retry, hPermission, denied, denialFailure, retryFailureKey]

theorem raw_response_preservation :
    ∀ (state state' : NetworkState) (delivery : DeliveryOrdinal) (observation : AdapterObservation)
      (key : AttemptIdentity) (handle : ExecutionHandle) (source : SourceSequence)
      (raw : RawHttpResponse) (provenance : HeaderProvenance) (effect : EffectStatus)
      (settled : SettledAttempt),
      observation = .ResponseObservation key handle source raw provenance effect →
      observe state (.Delivered delivery observation) = .Terminal state' settled →
      settled.terminal.outcome = .Response raw provenance := by
  intro state state' delivery observation key handle source raw provenance effect settled observationEq equation
  subst observation
  unfold observe at equation
  by_cases hHost :
      HostObservationRelation state
        (.Delivered delivery (.ResponseObservation key handle source raw provenance effect))
  · rw [dif_pos hHost] at equation
    simp only at equation
    have hObservation :
        ObservationRelation state
          (.ResponseObservation key handle source raw provenance effect) := by
      change ObservationRelation state
        (.ResponseObservation key handle source raw provenance effect) at hHost
      exact hHost
    rw [dif_pos hObservation] at equation
    simp only [attemptOf] at equation
    cases hLookup : lookupAttempt state key with
    | none =>
        rw [hLookup] at equation
        simp only at equation
        contradiction
    | some record =>
        rw [hLookup] at equation
        simp only at equation
        cases hRecorded : recordedDelivery record delivery with
        | some old =>
            rw [hRecorded] at equation
            simp only at equation
            split at equation <;> contradiction
        | none =>
            rw [hRecorded] at equation
            simp only at equation
            split at equation
            · contradiction
            · cases hDisposition : record.disposition with
              | Prepared =>
                  rw [hDisposition] at equation
                  simp only at equation
                  contradiction
              | CommandIssued =>
                  rw [hDisposition] at equation
                  simp only at equation
                  contradiction
              | Started actualHandle =>
                  rw [hDisposition] at equation
                  simp only at equation
                  split at equation
                  · split at equation
                    · injection equation with hState hSettled
                      subst state' settled
                      rfl
                    · contradiction
                  · contradiction
              | Settled actualHandle actualTerminal =>
                  rw [hDisposition] at equation
                  simp only at equation
                  split at equation
                  · split at equation <;> contradiction
                  · contradiction
  · rw [dif_neg hHost] at equation
    split at equation <;> contradiction

theorem closed_failure :
    ∀ (state : NetworkState) (failure : NetworkFailure), RejectedByOperation state failure →
      FailureCategory failure = .Wire ∨ FailureCategory failure = .Deadline ∨
      FailureCategory failure = .State ∨ FailureCategory failure = .Token ∨
      FailureCategory failure = .Capability ∨ FailureCategory failure = .Identity ∨
      FailureCategory failure = .Handle ∨ FailureCategory failure = .Observation ∨
      FailureCategory failure = .Delivery ∨ FailureCategory failure = .Host ∨
      FailureCategory failure = .Retry ∨ FailureCategory failure = .Effect := by
  intro state failure rejected
  cases failure <;> simp [FailureCategory]

theorem rejected_operations_preserve_input_state :
    (∀ (state state' : NetworkState) (failure : NetworkFailure),
      readNetworkState state = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (input : AttemptInput) (failure : NetworkFailure),
      prepare state input = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (prepared : PreparedAttempt) (failure : NetworkFailure),
      sendCommand state prepared = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (started : StartedAttempt) (failure : NetworkFailure),
      cancelCommand state started = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (prepared : PreparedAttempt) (observation : StartObservation)
        (failure : NetworkFailure),
      observeStart state prepared observation = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (observation : HostObservation) (failure : NetworkFailure),
      observe state observation = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (effect : EffectObservation) (failure : NetworkFailure),
      annotateEffect state effect = .Rejected state' failure → state' = state) ∧
    (∀ (state state' : NetworkState) (request : RetryRequest) (failure : NetworkFailure),
      retry state request = .Rejected state' failure → state' = state) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro state state' failure equation
    unfold readNetworkState at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' input failure equation
    unfold prepare at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' prepared failure equation
    unfold sendCommand at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' started failure equation
    unfold cancelCommand at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' prepared observation failure equation
    unfold observeStart at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' observation failure equation
    unfold observe at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' effect failure equation
    unfold annotateEffect at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)
  · intro state state' request failure equation
    unfold retry at equation
    repeat
      first
      | simp only at equation
      | split at equation
      | injection equation <;> (try subst_vars) <;> (first | rfl | skip)


theorem progression_separation_and_bridge_provenance :
    ∀ (state state' : NetworkState) (bridge : ProgressionBridgeInput),
      SuccessfulTransition state state' →
      (ApplyNetworkProjection state' bridge).progression = bridge.progression ∧
      LookupTypedTerminal state' bridge.attempt =
        TerminalCarriedOrReferenced (ApplyNetworkProjection state' bridge).projection := by
  intro state state' bridge _transition
  unfold ApplyNetworkProjection TerminalCarriedOrReferenced
  cases hTerminal : LookupTypedTerminal state' bridge.attempt with
  | none => exact ⟨rfl, by simp [hTerminal]⟩
  | some terminal => exact ⟨rfl, by simp [hTerminal]⟩

theorem no_remote_claim :
    ∀ (state state' : NetworkState) (key : AttemptIdentity) (terminal : NetworkTerminal),
      TerminalForAttempt key terminal → CancelOrDeadlineOutcome terminal.outcome →
      SettleOrRead state key terminal = state' →
      (∃ reason : UnknownEffectReason, CurrentEffect state' key = some (.Unknown reason)) ∨
      ∃ witness : EffectWitness, MatchingIndependentWitness key witness ∧
        (CurrentEffect state' key = some (.NoEffect witness) ∨
         CurrentEffect state' key = some (.EffectOccurred witness)) := by
  intro state state' key terminal terminalRel outcomeKind settle
  cases hLookup : lookupAttempt state key with
  | none =>
      simp [SettleOrRead, hLookup] at settle
      cases settle
      exact Or.inl ⟨.NoResponse, by simp [CurrentEffect, EffectOf, hLookup]⟩
  | some record =>
      let updated : AttemptRecord :=
        { record with disposition := .Settled (dispositionHandle record.disposition) terminal }
      simp [SettleOrRead, hLookup, updated] at settle
      cases settle
      have lookupUpdated : lookupAttempt (replaceRecord state key updated) key = some updated := by
        apply lookupAttempt_replaceRecord_self state key updated record hLookup
        rfl
      have currentEffect :
          CurrentEffect (replaceRecord state key updated) key = some terminal.effect := by
        simp [CurrentEffect, EffectOf, lookupUpdated, updated, terminalOfDisposition]
      cases effect : terminal.effect with
      | Unknown reason =>
          exact Or.inl ⟨reason, by simpa [effect] using currentEffect⟩
      | NoEffect witness =>
          change EffectMatches key terminal.effect at terminalRel
          rw [effect] at terminalRel
          have witnessMatches : MatchingIndependentWitness key witness := by
            simpa [EffectMatches, MatchingIndependentWitness] using terminalRel
          exact Or.inr
            ⟨witness, witnessMatches, Or.inl (by simpa [effect] using currentEffect)⟩
      | EffectOccurred witness =>
          change EffectMatches key terminal.effect at terminalRel
          rw [effect] at terminalRel
          have witnessMatches : MatchingIndependentWitness key witness := by
            simpa [EffectMatches, MatchingIndependentWitness] using terminalRel
          exact Or.inr
            ⟨witness, witnessMatches, Or.inr (by simpa [effect] using currentEffect)⟩

end Necoherence
