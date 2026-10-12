// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/request_progression as progression

pub type ByteString =
  List(Int)

pub type RawHeaderField {
  RawHeaderField(name: String, value: ByteString)
}

pub type HttpWireInstruction {
  HttpWireInstruction(
    method: String,
    target: String,
    headers: List(RawHeaderField),
    body: ByteString,
  )
}

pub type RawHttpResponse {
  RawHttpResponse(status: Int, headers: List(RawHeaderField), body: ByteString)
}

pub type HeaderProvenance {
  WireObserved
  LibraryObserved
  LibraryNormalized
}

pub type RequestIdentity =
  progression.RequestIdentity

pub type AttemptIdentity {
  AttemptIdentity(logical: RequestIdentity, ordinal: Int)
}

pub type OpaqueEvidence {
  OpaqueEvidence(value: String)
}

pub type ClockBasis {
  ClockBasis(value: String)
}

pub type MonotonicClockObservation {
  MonotonicClockObservation(clock_basis: ClockBasis, value: Int)
}

pub type MonotonicClockCapability {
  MonotonicClockCapability(identity: OpaqueEvidence, clock_basis: ClockBasis)
}

pub type CancellationCapability {
  CancellationCapability(identity: OpaqueEvidence)
}

pub type Deadline {
  Deadline(
    clock_basis: ClockBasis,
    limit: Int,
    capability: MonotonicClockCapability,
  )
}

pub type HostConfiguration {
  HostConfiguration(
    request_body_limit: Int,
    response_body_limit: Int,
    cancellation: Option(CancellationCapability),
    monotonic_clock: Option(MonotonicClockCapability),
  )
}

pub type AttemptInput {
  AttemptInput(
    attempt: AttemptIdentity,
    instruction: HttpWireInstruction,
    deadline: Option(Deadline),
    configuration: HostConfiguration,
  )
}

pub type RetryAuthorization {
  RetryAuthorization(
    logical: RequestIdentity,
    from: AttemptIdentity,
    next: AttemptIdentity,
    protocol_evidence: OpaqueEvidence,
  )
}

pub type AttemptLineage {
  Root
  RetryOf(RetryAuthorization)
}

pub type ExecutionHandle {
  ExecutionHandle(value: String)
}

pub type PreparedAttempt {
  PreparedAttempt(input: AttemptInput, lineage: AttemptLineage)
}

pub type StartedAttempt {
  StartedAttempt(prepared: PreparedAttempt, handle: ExecutionHandle)
}

pub type SendCommand {
  SendCommand(prepared: PreparedAttempt)
}

pub type CancelCommand {
  CancelCommand(
    attempt: AttemptIdentity,
    handle: ExecutionHandle,
    capability: CancellationCapability,
  )
}

pub type EffectWitnessSource {
  Adapter
  Protocol
}

pub type EffectWitness {
  EffectWitness(
    attempt: AttemptIdentity,
    source: EffectWitnessSource,
    evidence: OpaqueEvidence,
  )
}

pub type UnknownEffectReason {
  NoResponse
  CancellationReason
  DeadlineReason
  HostFailure
  ProtocolWitnessMissing
  LateSignal
}

pub type EffectStatus {
  NoEffect(EffectWitness)
  EffectOccurred(EffectWitness)
  Unknown(UnknownEffectReason)
}

pub type EffectObservation {
  EffectObservation(attempt: AttemptIdentity, status: EffectStatus)
}

pub type HostStage {
  Start
  RequestWrite
  ResponseHeaders
  ResponseBody
  Cancel
  DeadlineStage
}

pub type HostTimeoutCause {
  LibraryReported
  SocketReported
  PoolAcquisition
  HostOperation
}

pub type HostFailure {
  UnsupportedUriScheme
  InvalidHostConfiguration
  ExecutionStartFailed
  NameResolutionFailed
  ConnectionFailed
  RequestWriteFailed
  ResponseHeadersFailed
  ResponseBodyFailed
  ResponseBodyLimitExceeded
  MalformedResponse
  HeaderRepresentationUnavailable
  RequestHeaderEncodingUnavailable
  CancellationRejected
  DeadlineControlUnavailable
  Timeout(stage: HostStage, cause: HostTimeoutCause)
  HostRuntimeFailure
  HostClosed
}

pub type NetworkHostFailure {
  NetworkHostFailure(
    attempt: AttemptIdentity,
    stage: HostStage,
    configuration: HostConfiguration,
    cause: HostFailure,
  )
}

pub type NetworkOutcome {
  Response(RawHttpResponse, HeaderProvenance)
  Failed(NetworkHostFailure)
  Cancelled
  DeadlineExceeded(Deadline, MonotonicClockObservation)
}

pub type NetworkTerminal {
  NetworkTerminal(outcome: NetworkOutcome, effect: EffectStatus)
}

pub type AttemptDisposition {
  Prepared
  CommandIssued
  Started(ExecutionHandle)
  Settled(Option(ExecutionHandle), NetworkTerminal)
}

pub type SourceSequence {
  NoSource
  Source(Int)
}

pub type AdapterObservation {
  ResponseObservation(
    attempt: AttemptIdentity,
    handle: ExecutionHandle,
    source: SourceSequence,
    response: RawHttpResponse,
    provenance: HeaderProvenance,
    effect: EffectStatus,
  )
  FailureObservation(
    attempt: AttemptIdentity,
    handle: ExecutionHandle,
    source: SourceSequence,
    failure: NetworkHostFailure,
    effect: EffectStatus,
  )
  CancellationObservation(
    attempt: AttemptIdentity,
    handle: ExecutionHandle,
    source: SourceSequence,
    effect: EffectStatus,
  )
  DeadlineObservation(
    attempt: AttemptIdentity,
    handle: ExecutionHandle,
    source: SourceSequence,
    deadline: Deadline,
    observed: MonotonicClockObservation,
    effect: EffectStatus,
  )
}

pub type DeliveredObservation {
  DeliveredObservation(delivery: Int, observation: AdapterObservation)
}

pub type LateObservation {
  LateObservation(delivered: DeliveredObservation)
}

pub type AttemptRecord {
  AttemptRecord(
    input: AttemptInput,
    lineage: AttemptLineage,
    disposition: AttemptDisposition,
    first_delivery: Option(DeliveredObservation),
    late: List(LateObservation),
  )
}

pub type NetworkState {
  NetworkState(attempts: List(AttemptRecord))
}

pub type RetryPermission {
  RetryAllowed(RetryAuthorization)
  RetryDenied(RequestIdentity, AttemptIdentity, OpaqueEvidence)
}

pub type RetryRequest {
  RetryRequest(
    permission: RetryPermission,
    instruction: HttpWireInstruction,
    deadline: Option(Deadline),
    configuration: HostConfiguration,
  )
}

pub type StartObservation {
  StartedObservation(AttemptIdentity, ExecutionHandle)
  StartFailed(NetworkHostFailure, EffectStatus)
}

pub type HostObservation {
  Pending(AttemptIdentity, ExecutionHandle)
  Delivered(Int, AdapterObservation)
}

pub type NetworkStateViolation {
  DuplicateAttemptKey(AttemptIdentity)
  NonRootFirstAttempt(AttemptIdentity)
  OrdinalGap(AttemptIdentity)
  LineageMismatch(AttemptIdentity)
  RetryAuthorizationReuse(RetryAuthorization)
  DispositionEvidenceMismatch(AttemptIdentity)
  DeliveryLogMismatch(AttemptIdentity)
}

pub type AttemptCondition {
  IsPrepared
  IsCommandIssued
  IsStarted
  IsSettled
}

pub type AttemptTokenField {
  Instruction
  DeadlineField
  Configuration
  Lineage
  Handle
}

pub type ObservationField {
  FailureConfiguration
  FailureStage
  DeadlineValue
  ClockBasisValue
  ClockObservationValue
  EffectWitnessValue
}

pub type CapabilityKind {
  CancellationCapabilityKind
  MonotonicClock
}

pub type NetworkFailure {
  InvalidWireInstruction(String)
  InvalidDeadline
  InvalidNetworkState(NetworkStateViolation)
  RootAttemptRequired(AttemptIdentity)
  DuplicateAttempt(AttemptIdentity)
  UnknownAttempt(AttemptIdentity)
  AttemptConditionMismatch(AttemptIdentity, AttemptCondition, AttemptCondition)
  AttemptTokenMismatch(AttemptIdentity, AttemptTokenField)
  ObservationRelationMismatch(AttemptIdentity, ObservationField)
  RequiredCapabilityUnavailable(AttemptIdentity, CapabilityKind)
  CommandAlreadyIssued(AttemptIdentity)
  IdentityMismatch(AttemptIdentity, AttemptIdentity)
  HandleMismatch(ExecutionHandle, ExecutionHandle)
  ClockBasisMismatch(ClockBasis, ClockBasis)
  DeadlineNotReached(Deadline, MonotonicClockObservation)
  DeliveryOrderViolation(AttemptIdentity, Int, Int)
  ConflictingDelivery(
    AttemptIdentity,
    Int,
    AdapterObservation,
    AdapterObservation,
  )
  MalformedAdapterObservation
  Host(NetworkHostFailure)
  RetryNotPermitted(AttemptIdentity)
  RetryIdentityMismatch(RequestIdentity, RequestIdentity)
  RetryParentMismatch(AttemptIdentity, AttemptIdentity)
  RetryParentNotSettled(AttemptIdentity)
  RetryOrderViolation(AttemptIdentity, AttemptIdentity)
  RetryAuthorizationAlreadyUsed(RetryAuthorization)
  EffectWitnessMissing(AttemptIdentity)
  EffectKnowledgeConflict(AttemptIdentity)
}

pub type ReadStateStep {
  Read(NetworkState)
  ReadRejected(NetworkState, NetworkFailure)
}

pub type PrepareStep {
  PreparedResult(NetworkState, PreparedAttempt)
  PrepareRejected(NetworkState, NetworkFailure)
}

pub type CommandStep(a) {
  CommandReady(NetworkState, a)
  CommandRejected(NetworkState, NetworkFailure)
}

pub type StateStep {
  Applied(NetworkState)
  StateRejected(NetworkState, NetworkFailure)
}

pub type SettledAttempt {
  SettledAttempt(
    prepared: PreparedAttempt,
    handle: Option(ExecutionHandle),
    terminal: NetworkTerminal,
  )
}

pub type NetworkStep {
  StartedStep(NetworkState, StartedAttempt)
  PendingStep(NetworkState, StartedAttempt)
  TerminalStep(NetworkState, SettledAttempt)
  LateStep(NetworkState, SettledAttempt, LateObservation)
  DuplicateStep(NetworkState, AttemptIdentity, Int)
  NetworkRejected(NetworkState, NetworkFailure)
}

pub fn empty_state() -> NetworkState {
  NetworkState([])
}

pub fn request_identity(
  kind: String,
  provenance: String,
  revision: Int,
) -> RequestIdentity {
  progression.RequestIdentity(kind, provenance, revision)
}

pub fn lookup(
  state: NetworkState,
  key: AttemptIdentity,
) -> Option(AttemptRecord) {
  case list.find(state.attempts, fn(record) { record.input.attempt == key }) {
    Ok(record) -> Some(record)
    Error(_) -> None
  }
}

pub fn valid_state(state: NetworkState) -> Bool {
  unique_keys(state.attempts)
  && list.all(state.attempts, valid_record)
  && lineage_valid(state.attempts)
  && authorization_unique(state.attempts)
}

fn unique_keys(records: List(AttemptRecord)) -> Bool {
  case records {
    [] -> True
    [first, ..rest] ->
      !list.any(rest, fn(other) { other.input.attempt == first.input.attempt })
      && unique_keys(rest)
  }
}

fn valid_record(record: AttemptRecord) -> Bool {
  let key = record.input.attempt
  case record.disposition {
    Prepared | CommandIssued | Started(_) ->
      record.first_delivery == None && record.late == []
    Settled(handle, terminal) -> {
      let evidence = outcome_matches(key, terminal.outcome)
      let effect = effect_matches(key, terminal.effect)
      case handle, record.first_delivery {
        None, None -> evidence && effect && record.late == []
        Some(expected), Some(first) ->
          evidence
          && effect
          && first.delivery == 0
          && attempt_of(first.observation) == key
          && handle_of(first.observation) == expected
          && late_valid(record.late, expected, key, first.delivery)
        _, _ -> False
      }
    }
  }
}

fn late_valid(
  lates: List(LateObservation),
  handle: ExecutionHandle,
  key: AttemptIdentity,
  previous: Int,
) -> Bool {
  case lates {
    [] -> True
    [late, ..rest] ->
      late.delivered.delivery > previous
      && attempt_of(late.delivered.observation) == key
      && handle_of(late.delivered.observation) == handle
      && late_valid(rest, handle, key, late.delivered.delivery)
  }
}

fn root_for_logical(
  records: List(AttemptRecord),
  logical: RequestIdentity,
) -> Bool {
  list.any(records, fn(record) {
    record.input.attempt.logical == logical
    && record.input.attempt.ordinal == 0
    && record.lineage == Root
  })
}

fn lineage_record_valid(
  records: List(AttemptRecord),
  record: AttemptRecord,
) -> Bool {
  let key = record.input.attempt
  root_for_logical(records, key.logical)
  && case record.lineage {
    Root -> key.ordinal == 0
    RetryOf(auth) ->
      auth.logical == key.logical
      && auth.from.logical == key.logical
      && auth.next == key
      && auth.next.ordinal == auth.from.ordinal + 1
      && list.any(records, fn(parent) {
        parent.input.attempt == auth.from && is_settled(parent.disposition)
      })
  }
}

fn lineage_valid(records: List(AttemptRecord)) -> Bool {
  list.all(records, fn(record) { lineage_record_valid(records, record) })
}

fn authorization_unique(records: List(AttemptRecord)) -> Bool {
  case records {
    [] -> True
    [record, ..rest] -> {
      let unique = case record.lineage {
        Root -> True
        RetryOf(authorization) ->
          !list.any(rest, fn(candidate) {
            candidate.lineage == RetryOf(authorization)
          })
      }
      unique && authorization_unique(rest)
    }
  }
}

fn is_settled(disposition: AttemptDisposition) -> Bool {
  case disposition {
    Settled(_, _) -> True
    _ -> False
  }
}

fn effect_matches(key: AttemptIdentity, status: EffectStatus) -> Bool {
  case status {
    Unknown(_) -> True
    NoEffect(witness) -> witness.attempt == key
    EffectOccurred(witness) -> witness.attempt == key
  }
}

fn outcome_matches(key: AttemptIdentity, outcome: NetworkOutcome) -> Bool {
  case outcome {
    Failed(failure) -> failure.attempt == key
    _ -> True
  }
}

fn instruction_valid(instruction: HttpWireInstruction) -> Bool {
  token_valid(instruction.method)
  && absolute_uri(codepoints(instruction.target))
  && list.all(instruction.headers, fn(header) {
    token_valid(header.name) && bytes_valid(header.value)
  })
  && bytes_valid(instruction.body)
}

fn codepoints(value: String) -> List(Int) {
  value
  |> string.to_utf_codepoints
  |> list.map(string.utf_codepoint_to_int)
}

fn alpha_char(char: Int) -> Bool {
  char >= 65 && char <= 90 || char >= 97 && char <= 122
}

fn digit_char(char: Int) -> Bool {
  char >= 48 && char <= 57
}

fn hex_char(char: Int) -> Bool {
  digit_char(char) || char >= 65 && char <= 70 || char >= 97 && char <= 102
}

fn token_char(char: Int) -> Bool {
  alpha_char(char)
  || digit_char(char)
  || list.contains(
    [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126],
    char,
  )
}

fn token_valid(value: String) -> Bool {
  value != "" && list.all(codepoints(value), token_char)
}

fn bytes_valid(bytes: ByteString) -> Bool {
  list.all(bytes, fn(byte) { byte >= 0 && byte <= 255 })
}

fn uri_unreserved(char: Int) -> Bool {
  alpha_char(char) || digit_char(char) || list.contains([45, 46, 95, 126], char)
}

fn uri_sub_delimiter(char: Int) -> Bool {
  list.contains([33, 36, 38, 39, 40, 41, 42, 43, 44, 59, 61], char)
}

fn uri_path_character(char: Int) -> Bool {
  uri_unreserved(char) || uri_sub_delimiter(char) || char == 58 || char == 64
}

fn uri_component_valid(value: List(Int), allow_question: Bool) -> Bool {
  case value {
    [] -> True
    [37, high, low, ..rest] ->
      hex_char(high)
      && hex_char(low)
      && uri_component_valid(rest, allow_question)
    [37, ..] -> False
    [char, ..rest] ->
      { uri_path_character(char) || char == 47 || allow_question && char == 63 }
      && uri_component_valid(rest, allow_question)
  }
}

fn split_at(
  value: List(Int),
  delimiter: Int,
) -> #(List(Int), Option(List(Int))) {
  case value {
    [] -> #([], None)
    [char, ..rest] if char == delimiter -> #([], Some(rest))
    [char, ..rest] -> {
      let #(before, after) = split_at(rest, delimiter)
      #([char, ..before], after)
    }
  }
}

fn uri_reg_name_valid(value: List(Int)) -> Bool {
  case value {
    [] -> True
    [37, high, low, ..rest] ->
      hex_char(high) && hex_char(low) && uri_reg_name_valid(rest)
    [37, ..] -> False
    [char, ..rest] ->
      { uri_unreserved(char) || uri_sub_delimiter(char) }
      && uri_reg_name_valid(rest)
  }
}

fn uri_user_info_valid(value: List(Int)) -> Bool {
  case value {
    [] -> True
    [37, high, low, ..rest] ->
      hex_char(high) && hex_char(low) && uri_user_info_valid(rest)
    [37, ..] -> False
    [char, ..rest] ->
      { uri_unreserved(char) || uri_sub_delimiter(char) || char == 58 }
      && uri_user_info_valid(rest)
  }
}

fn uri_port_valid(value: List(Int)) -> Bool {
  list.all(value, digit_char)
}

fn uri_ip_literal_valid(value: List(Int)) -> Bool {
  value != []
  && list.any(value, fn(char) { char == 58 || char == 46 })
  && list.all(value, fn(char) {
    hex_char(char)
    || char == 58
    || char == 46
    || char == 118
    || char == 86
    || uri_unreserved(char)
    || uri_sub_delimiter(char)
  })
}

fn uri_port_suffix_valid(value: List(Int)) -> Bool {
  case value {
    [] -> True
    [58, ..port] -> uri_port_valid(port)
    _ -> False
  }
}

fn uri_host_port_valid(value: List(Int)) -> Bool {
  case value {
    [91, ..rest] -> {
      let #(address, suffix) = list.split_while(rest, fn(char) { char != 93 })
      case suffix {
        [93, ..port] ->
          uri_ip_literal_valid(address) && uri_port_suffix_valid(port)
        _ -> False
      }
    }
    host_port -> {
      let #(host, port) = split_at(host_port, 58)
      uri_reg_name_valid(host)
      && case port {
        None -> True
        Some(digits) -> uri_port_valid(digits)
      }
    }
  }
}

fn authority_valid(authority: List(Int)) -> Bool {
  let #(user_info, host_port) = split_at(authority, 64)
  case host_port {
    None -> uri_host_port_valid(user_info)
    Some(value) ->
      !list.contains(value, 64)
      && uri_user_info_valid(user_info)
      && uri_host_port_valid(value)
  }
}

fn uri_hier_part_valid(value: List(Int)) -> Bool {
  case value {
    [47, 47, ..rest] -> {
      let #(authority, path) = list.split_while(rest, fn(char) { char != 47 })
      authority_valid(authority) && uri_component_valid(path, False)
    }
    path -> uri_component_valid(path, False)
  }
}

fn uri_tail_valid(value: List(Int)) -> Bool {
  let #(before_fragment, fragment) = split_at(value, 35)
  let #(path, query) = split_at(before_fragment, 63)
  uri_hier_part_valid(path)
  && case query {
    None -> True
    Some(value) -> uri_component_valid(value, True)
  }
  && case fragment {
    None -> True
    Some(value) -> uri_component_valid(value, True)
  }
}

fn uri_scheme_char(char: Int) -> Bool {
  alpha_char(char) || digit_char(char) || list.contains([43, 45, 46], char)
}

fn absolute_uri(value: List(Int)) -> Bool {
  case value {
    [] -> False
    [first, ..rest] -> {
      let #(scheme_tail, suffix) =
        list.split_while(rest, fn(char) { char != 58 })
      case suffix {
        [58, ..uri] ->
          alpha_char(first)
          && list.all(scheme_tail, uri_scheme_char)
          && uri_tail_valid(uri)
        _ -> False
      }
    }
  }
}

fn deadline_valid(
  config: HostConfiguration,
  deadline: Option(Deadline),
) -> Bool {
  case deadline {
    None -> True
    Some(value) ->
      value.capability.clock_basis == value.clock_basis
      && config.monotonic_clock == Some(value.capability)
  }
}

fn input_valid(input: AttemptInput) -> Bool {
  instruction_valid(input.instruction)
  && input.instruction.body |> list.length
  <= input.configuration.request_body_limit
  && input.configuration.request_body_limit >= 0
  && input.configuration.response_body_limit >= 0
  && deadline_valid(input.configuration, input.deadline)
}

fn first_duplicate_violation(
  records: List(AttemptRecord),
) -> Option(NetworkStateViolation) {
  case records {
    [] -> None
    [record, ..rest] ->
      case
        list.any(rest, fn(candidate) {
          candidate.input.attempt == record.input.attempt
        })
      {
        True -> Some(DuplicateAttemptKey(record.input.attempt))
        False -> first_duplicate_violation(rest)
      }
  }
}

fn terminal_evidence_valid(
  key: AttemptIdentity,
  terminal: NetworkTerminal,
) -> Bool {
  outcome_matches(key, terminal.outcome) && effect_matches(key, terminal.effect)
}

fn record_evidence_violation(
  record: AttemptRecord,
) -> Option(NetworkStateViolation) {
  case valid_record(record) {
    True -> None
    False ->
      case record.disposition {
        Prepared | CommandIssued | Started(_) ->
          Some(DeliveryLogMismatch(record.input.attempt))
        Settled(None, _) ->
          case record.first_delivery == None && record.late == [] {
            True -> Some(DispositionEvidenceMismatch(record.input.attempt))
            False -> Some(DeliveryLogMismatch(record.input.attempt))
          }
        Settled(Some(_), terminal) ->
          case terminal_evidence_valid(record.input.attempt, terminal) {
            True -> Some(DeliveryLogMismatch(record.input.attempt))
            False -> Some(DispositionEvidenceMismatch(record.input.attempt))
          }
      }
  }
}

fn first_record_violation(
  records: List(AttemptRecord),
) -> Option(NetworkStateViolation) {
  case records {
    [] -> None
    [record, ..rest] ->
      case record_evidence_violation(record) {
        Some(violation) -> Some(violation)
        None -> first_record_violation(rest)
      }
  }
}

fn lineage_violation(
  records: List(AttemptRecord),
  record: AttemptRecord,
) -> Option(NetworkStateViolation) {
  case lineage_record_valid(records, record) {
    True -> None
    False ->
      case root_for_logical(records, record.input.attempt.logical) {
        False -> Some(NonRootFirstAttempt(record.input.attempt))
        True ->
          case record.lineage {
            Root -> Some(NonRootFirstAttempt(record.input.attempt))
            RetryOf(authorization) ->
              case
                authorization.next.ordinal != authorization.from.ordinal + 1
              {
                True -> Some(OrdinalGap(record.input.attempt))
                False -> Some(LineageMismatch(record.input.attempt))
              }
          }
      }
  }
}

fn first_lineage_violation(
  records: List(AttemptRecord),
  remaining: List(AttemptRecord),
) -> Option(NetworkStateViolation) {
  case remaining {
    [] -> None
    [record, ..rest] ->
      case lineage_violation(records, record) {
        Some(violation) -> Some(violation)
        None -> first_lineage_violation(records, rest)
      }
  }
}

fn first_root_violation(
  records: List(AttemptRecord),
  remaining: List(AttemptRecord),
) -> Option(NetworkStateViolation) {
  case remaining {
    [] -> None
    [record, ..rest] ->
      case root_for_logical(records, record.input.attempt.logical) {
        True -> first_root_violation(records, rest)
        False -> Some(NonRootFirstAttempt(record.input.attempt))
      }
  }
}

fn first_authorization_violation(
  records: List(AttemptRecord),
) -> Option(NetworkStateViolation) {
  case records {
    [] -> None
    [record, ..rest] ->
      case record.lineage {
        Root -> first_authorization_violation(rest)
        RetryOf(authorization) ->
          case
            list.any(rest, fn(candidate) {
              candidate.lineage == RetryOf(authorization)
            })
          {
            True -> Some(RetryAuthorizationReuse(authorization))
            False -> first_authorization_violation(rest)
          }
      }
  }
}

fn state_violation(state: NetworkState) -> NetworkStateViolation {
  case first_duplicate_violation(state.attempts) {
    Some(violation) -> violation
    None ->
      case first_record_violation(state.attempts) {
        Some(violation) -> violation
        None ->
          case first_lineage_violation(state.attempts, state.attempts) {
            Some(violation) -> violation
            None ->
              case first_root_violation(state.attempts, state.attempts) {
                Some(violation) -> violation
                None ->
                  case first_authorization_violation(state.attempts) {
                    Some(violation) -> violation
                    None ->
                      DuplicateAttemptKey(AttemptIdentity(
                        progression.RequestIdentity("", "", 0),
                        0,
                      ))
                  }
              }
          }
      }
  }
}

fn failure_for_invalid_state(state: NetworkState) -> NetworkFailure {
  InvalidNetworkState(state_violation(state))
}

pub fn read_network_state(state: NetworkState) -> ReadStateStep {
  case valid_state(state) {
    True -> Read(state)
    False -> ReadRejected(state, failure_for_invalid_state(state))
  }
}

fn append_record(state: NetworkState, record: AttemptRecord) -> NetworkState {
  NetworkState(list.append(state.attempts, [record]))
}

fn replace_record(
  state: NetworkState,
  key: AttemptIdentity,
  replacement: AttemptRecord,
) -> NetworkState {
  NetworkState(
    list.map(state.attempts, fn(record) {
      case record.input.attempt == key {
        True -> replacement
        False -> record
      }
    }),
  )
}

fn record_for(
  state: NetworkState,
  key: AttemptIdentity,
) -> Option(AttemptRecord) {
  lookup(state, key)
}

fn prepared_relation(state: NetworkState, prepared: PreparedAttempt) -> Bool {
  case record_for(state, prepared.input.attempt) {
    Some(record) ->
      valid_state(state)
      && record.input == prepared.input
      && record.lineage == prepared.lineage
    None -> False
  }
}

fn prepared_ready(state: NetworkState, prepared: PreparedAttempt) -> Bool {
  case record_for(state, prepared.input.attempt) {
    Some(record) ->
      prepared_relation(state, prepared) && record.disposition == Prepared
    None -> False
  }
}

fn command_issued_relation(
  state: NetworkState,
  prepared: PreparedAttempt,
) -> Bool {
  case record_for(state, prepared.input.attempt) {
    Some(record) ->
      prepared_relation(state, prepared) && record.disposition == CommandIssued
    None -> False
  }
}

fn prepared_token_failure(
  state: NetworkState,
  prepared: PreparedAttempt,
) -> Option(NetworkFailure) {
  case record_for(state, prepared.input.attempt) {
    None -> Some(UnknownAttempt(prepared.input.attempt))
    Some(record) ->
      case
        record.input.instruction != prepared.input.instruction,
        record.input.deadline != prepared.input.deadline,
        record.input.configuration != prepared.input.configuration,
        record.lineage != prepared.lineage
      {
        True, _, _, _ ->
          Some(AttemptTokenMismatch(prepared.input.attempt, Instruction))
        False, True, _, _ ->
          Some(AttemptTokenMismatch(prepared.input.attempt, DeadlineField))
        False, False, True, _ ->
          Some(AttemptTokenMismatch(prepared.input.attempt, Configuration))
        False, False, False, True ->
          Some(AttemptTokenMismatch(prepared.input.attempt, Lineage))
        False, False, False, False -> None
      }
  }
}

fn prepared_condition_failure(
  state: NetworkState,
  prepared: PreparedAttempt,
  expected: AttemptCondition,
) -> Option(NetworkFailure) {
  case prepared_token_failure(state, prepared) {
    Some(failure) -> Some(failure)
    None ->
      case record_for(state, prepared.input.attempt) {
        None -> Some(UnknownAttempt(prepared.input.attempt))
        Some(record) -> {
          let actual = disposition_condition(record.disposition)
          case actual == expected {
            True -> None
            False ->
              Some(AttemptConditionMismatch(
                prepared.input.attempt,
                expected,
                actual,
              ))
          }
        }
      }
  }
}

fn started_token_failure(
  state: NetworkState,
  started: StartedAttempt,
) -> Option(NetworkFailure) {
  case prepared_token_failure(state, started.prepared) {
    Some(failure) -> Some(failure)
    None ->
      case record_for(state, started.prepared.input.attempt) {
        None -> Some(UnknownAttempt(started.prepared.input.attempt))
        Some(record) ->
          case record.disposition {
            Started(handle) ->
              case handle == started.handle {
                True -> None
                False -> Some(HandleMismatch(handle, started.handle))
              }
            disposition ->
              Some(AttemptConditionMismatch(
                started.prepared.input.attempt,
                IsStarted,
                disposition_condition(disposition),
              ))
          }
      }
  }
}

pub fn prepare(state: NetworkState, input: AttemptInput) -> PrepareStep {
  case valid_state(state), input_valid(input) {
    False, _ -> PrepareRejected(state, failure_for_invalid_state(state))
    _, False ->
      PrepareRejected(state, InvalidWireInstruction(input.instruction.method))
    True, True ->
      case
        input.attempt.ordinal,
        list.any(state.attempts, fn(record) {
          record.input.attempt.logical == input.attempt.logical
        })
      {
        ordinal, _ if ordinal != 0 ->
          PrepareRejected(state, RootAttemptRequired(input.attempt))
        _, True -> PrepareRejected(state, DuplicateAttempt(input.attempt))
        _, False -> {
          let prepared = PreparedAttempt(input, Root)
          let next =
            append_record(state, AttemptRecord(input, Root, Prepared, None, []))
          PreparedResult(next, prepared)
        }
      }
  }
}

fn command_issued(state: NetworkState, prepared: PreparedAttempt) -> Bool {
  list.any(state.attempts, fn(record) {
    record.input == prepared.input
    && record.lineage == prepared.lineage
    && record.disposition == CommandIssued
  })
}

pub fn send_command(
  state: NetworkState,
  prepared: PreparedAttempt,
) -> CommandStep(SendCommand) {
  case command_issued(state, prepared) {
    True -> CommandRejected(state, CommandAlreadyIssued(prepared.input.attempt))
    False ->
      case prepared_ready(state, prepared) {
        True -> {
          let next =
            replace_record(
              state,
              prepared.input.attempt,
              AttemptRecord(
                prepared.input,
                prepared.lineage,
                CommandIssued,
                None,
                [],
              ),
            )
          CommandReady(next, SendCommand(prepared))
        }
        False ->
          case valid_state(state) {
            False -> CommandRejected(state, failure_for_invalid_state(state))
            True ->
              case prepared_condition_failure(state, prepared, IsPrepared) {
                Some(failure) -> CommandRejected(state, failure)
                None ->
                  CommandRejected(
                    state,
                    AttemptConditionMismatch(
                      prepared.input.attempt,
                      IsPrepared,
                      IsPrepared,
                    ),
                  )
              }
          }
      }
  }
}

fn started_relation(state: NetworkState, started: StartedAttempt) -> Bool {
  case record_for(state, started.prepared.input.attempt) {
    Some(record) ->
      valid_state(state)
      && record.input == started.prepared.input
      && record.lineage == started.prepared.lineage
      && record.disposition == Started(started.handle)
      && record.first_delivery == None
      && record.late == []
    None -> False
  }
}

pub fn cancel_command(
  state: NetworkState,
  started: StartedAttempt,
) -> CommandStep(CancelCommand) {
  case started_relation(state, started) {
    True ->
      case started.prepared.input.configuration.cancellation {
        None ->
          CommandRejected(
            state,
            RequiredCapabilityUnavailable(
              started.prepared.input.attempt,
              CancellationCapabilityKind,
            ),
          )
        Some(capability) ->
          CommandReady(
            state,
            CancelCommand(
              started.prepared.input.attempt,
              started.handle,
              capability,
            ),
          )
      }
    False ->
      case valid_state(state) {
        False -> CommandRejected(state, failure_for_invalid_state(state))
        True ->
          case started_token_failure(state, started) {
            Some(failure) -> CommandRejected(state, failure)
            None ->
              CommandRejected(
                state,
                AttemptConditionMismatch(
                  started.prepared.input.attempt,
                  IsStarted,
                  IsStarted,
                ),
              )
          }
      }
  }
}

pub fn observe_start(
  state: NetworkState,
  prepared: PreparedAttempt,
  observation: StartObservation,
) -> NetworkStep {
  let relation =
    command_issued_relation(state, prepared)
    && case observation {
      StartedObservation(key, _) -> key == prepared.input.attempt
      StartFailed(failure, status) ->
        failure.attempt == prepared.input.attempt
        && failure.stage == Start
        && failure.configuration == prepared.input.configuration
        && effect_matches(prepared.input.attempt, status)
    }
  case relation, observation {
    True, StartedObservation(key, handle) -> {
      let next =
        replace_record(
          state,
          key,
          AttemptRecord(
            prepared.input,
            prepared.lineage,
            Started(handle),
            None,
            [],
          ),
        )
      StartedStep(next, StartedAttempt(prepared, handle))
    }
    True, StartFailed(failure, status) -> {
      let terminal = NetworkTerminal(Failed(failure), status)
      let next =
        replace_record(
          state,
          prepared.input.attempt,
          AttemptRecord(
            prepared.input,
            prepared.lineage,
            Settled(None, terminal),
            None,
            [],
          ),
        )
      TerminalStep(next, SettledAttempt(prepared, None, terminal))
    }
    False, _ ->
      case valid_state(state) {
        False -> NetworkRejected(state, failure_for_invalid_state(state))
        True ->
          case prepared_condition_failure(state, prepared, IsCommandIssued) {
            Some(failure) -> NetworkRejected(state, failure)
            None ->
              case observation {
                StartedObservation(key, _) ->
                  NetworkRejected(
                    state,
                    IdentityMismatch(prepared.input.attempt, key),
                  )
                StartFailed(failure, _) ->
                  case
                    failure.attempt != prepared.input.attempt,
                    failure.stage != Start,
                    failure.configuration != prepared.input.configuration
                  {
                    True, _, _ ->
                      NetworkRejected(
                        state,
                        IdentityMismatch(
                          prepared.input.attempt,
                          failure.attempt,
                        ),
                      )
                    False, True, _ ->
                      NetworkRejected(
                        state,
                        ObservationRelationMismatch(
                          prepared.input.attempt,
                          FailureStage,
                        ),
                      )
                    False, False, True ->
                      NetworkRejected(
                        state,
                        ObservationRelationMismatch(
                          prepared.input.attempt,
                          FailureConfiguration,
                        ),
                      )
                    False, False, False ->
                      NetworkRejected(
                        state,
                        ObservationRelationMismatch(
                          prepared.input.attempt,
                          EffectWitnessValue,
                        ),
                      )
                  }
              }
          }
      }
  }
}

fn adapter_observation_failure(
  state: NetworkState,
  observation: AdapterObservation,
) -> NetworkFailure {
  let key = attempt_of(observation)
  case record_for(state, key) {
    None -> UnknownAttempt(key)
    Some(record) -> {
      let expected_handle = case record.disposition {
        Started(handle) | Settled(Some(handle), _) -> Some(handle)
        _ -> None
      }
      case expected_handle {
        None ->
          AttemptConditionMismatch(
            key,
            IsStarted,
            disposition_condition(record.disposition),
          )
        Some(expected) ->
          case
            handle_of(observation) != expected,
            !effect_matches(key, effect_of(observation))
          {
            True, _ -> HandleMismatch(expected, handle_of(observation))
            False, True -> EffectWitnessMissing(key)
            False, False ->
              case observation {
                ResponseObservation(_, _, _, _, _, _)
                | CancellationObservation(_, _, _, _) ->
                  MalformedAdapterObservation
                FailureObservation(_, _, _, failure, _) ->
                  case failure.attempt != key {
                    True -> IdentityMismatch(key, failure.attempt)
                    False ->
                      case failure.cause {
                        Timeout(stage, _) if stage != failure.stage ->
                          ObservationRelationMismatch(key, FailureStage)
                        _ ->
                          ObservationRelationMismatch(key, FailureConfiguration)
                      }
                  }
                DeadlineObservation(_, _, _, deadline, observed, _) ->
                  case
                    record.input.deadline != Some(deadline),
                    deadline.clock_basis != observed.clock_basis
                  {
                    True, _ -> ObservationRelationMismatch(key, DeadlineValue)
                    False, True ->
                      ClockBasisMismatch(
                        deadline.clock_basis,
                        observed.clock_basis,
                      )
                    False, False -> DeadlineNotReached(deadline, observed)
                  }
              }
          }
      }
    }
  }
}

fn pending_observation_failure(
  state: NetworkState,
  key: AttemptIdentity,
  handle: ExecutionHandle,
) -> NetworkFailure {
  case record_for(state, key) {
    None -> UnknownAttempt(key)
    Some(record) ->
      case record.disposition {
        Started(expected) ->
          case handle == expected {
            True -> MalformedAdapterObservation
            False -> HandleMismatch(expected, handle)
          }
        disposition ->
          AttemptConditionMismatch(
            key,
            IsStarted,
            disposition_condition(disposition),
          )
      }
  }
}

pub fn observe(
  state: NetworkState,
  observation: HostObservation,
) -> NetworkStep {
  case valid_state(state) {
    False -> NetworkRejected(state, failure_for_invalid_state(state))
    True ->
      case observation {
        Pending(key, handle) ->
          case record_for(state, key) {
            Some(record) if record.disposition == Started(handle) ->
              PendingStep(
                state,
                StartedAttempt(
                  PreparedAttempt(record.input, record.lineage),
                  handle,
                ),
              )
            _ ->
              NetworkRejected(
                state,
                pending_observation_failure(state, key, handle),
              )
          }
        Delivered(delivery, delivered) ->
          observe_delivery(state, delivery, delivered)
      }
  }
}

fn observe_delivery(
  state: NetworkState,
  delivery: Int,
  delivered: AdapterObservation,
) -> NetworkStep {
  let key = attempt_of(delivered)
  case valid_state(state), record_for(state, key) {
    False, _ -> NetworkRejected(state, failure_for_invalid_state(state))
    True, None ->
      NetworkRejected(state, adapter_observation_failure(state, delivered))
    True, Some(record) ->
      case observation_valid(record, delivered) {
        False ->
          NetworkRejected(state, adapter_observation_failure(state, delivered))
        True ->
          case recorded_delivery(record, delivery) {
            Some(old) if old == delivered -> DuplicateStep(state, key, delivery)
            Some(old) ->
              NetworkRejected(
                state,
                ConflictingDelivery(key, delivery, old, delivered),
              )
            None -> {
              let expected = expected_delivery(record)
              case delivery == expected, record.disposition {
                False, _ ->
                  NetworkRejected(
                    state,
                    DeliveryOrderViolation(key, expected, delivery),
                  )
                True, Started(handle) -> {
                  let terminal = terminal_of(delivered)
                  let first = DeliveredObservation(delivery, delivered)
                  let next =
                    replace_record(
                      state,
                      key,
                      AttemptRecord(
                        record.input,
                        record.lineage,
                        Settled(Some(handle), terminal),
                        Some(first),
                        [],
                      ),
                    )
                  TerminalStep(
                    next,
                    SettledAttempt(
                      PreparedAttempt(record.input, record.lineage),
                      Some(handle),
                      terminal,
                    ),
                  )
                }
                True, Settled(handle, terminal) -> {
                  let late =
                    LateObservation(DeliveredObservation(delivery, delivered))
                  let next =
                    replace_record(
                      state,
                      key,
                      AttemptRecord(
                        record.input,
                        record.lineage,
                        Settled(handle, terminal),
                        record.first_delivery,
                        list.append(record.late, [late]),
                      ),
                    )
                  LateStep(
                    next,
                    SettledAttempt(
                      PreparedAttempt(record.input, record.lineage),
                      handle,
                      terminal,
                    ),
                    late,
                  )
                }
                True, Prepared ->
                  NetworkRejected(
                    state,
                    AttemptConditionMismatch(key, IsStarted, IsPrepared),
                  )
                True, CommandIssued ->
                  NetworkRejected(
                    state,
                    AttemptConditionMismatch(key, IsStarted, IsCommandIssued),
                  )
              }
            }
          }
      }
  }
}

fn observation_valid(
  record: AttemptRecord,
  observation: AdapterObservation,
) -> Bool {
  let handle_matches = case record.disposition {
    Started(handle) -> handle_of(observation) == handle
    Settled(Some(handle), _) -> handle_of(observation) == handle
    _ -> False
  }
  attempt_of(observation) == record.input.attempt
  && handle_matches
  && effect_matches(record.input.attempt, effect_of(observation))
  && case observation {
    ResponseObservation(_, _, _, response, _, _) ->
      response_valid(response)
      && list.length(response.body)
      <= record.input.configuration.response_body_limit
    FailureObservation(_, _, _, failure, _) ->
      failure.attempt == record.input.attempt
      && failure.configuration == record.input.configuration
      && case failure.cause {
        Timeout(stage, _) -> stage == failure.stage
        _ -> True
      }
    CancellationObservation(_, _, _, _) -> True
    DeadlineObservation(_, _, _, deadline, clock, _) ->
      record.input.deadline == Some(deadline)
      && record.input.configuration.monotonic_clock == Some(deadline.capability)
      && deadline.capability.clock_basis == deadline.clock_basis
      && clock.clock_basis == deadline.clock_basis
      && clock.value >= deadline.limit
  }
}

fn response_valid(response: RawHttpResponse) -> Bool {
  response.status >= 100
  && response.status <= 999
  && bytes_valid(response.body)
  && list.all(response.headers, fn(header) {
    header.name != "" && token_valid(header.name) && bytes_valid(header.value)
  })
}

fn attempt_of(observation: AdapterObservation) -> AttemptIdentity {
  case observation {
    ResponseObservation(key, _, _, _, _, _)
    | FailureObservation(key, _, _, _, _)
    | CancellationObservation(key, _, _, _)
    | DeadlineObservation(key, _, _, _, _, _) -> key
  }
}

fn handle_of(observation: AdapterObservation) -> ExecutionHandle {
  case observation {
    ResponseObservation(_, handle, _, _, _, _)
    | FailureObservation(_, handle, _, _, _)
    | CancellationObservation(_, handle, _, _)
    | DeadlineObservation(_, handle, _, _, _, _) -> handle
  }
}

fn effect_of(observation: AdapterObservation) -> EffectStatus {
  case observation {
    ResponseObservation(_, _, _, _, _, effect)
    | FailureObservation(_, _, _, _, effect)
    | CancellationObservation(_, _, _, effect)
    | DeadlineObservation(_, _, _, _, _, effect) -> effect
  }
}

fn terminal_of(observation: AdapterObservation) -> NetworkTerminal {
  case observation {
    ResponseObservation(_, _, _, response, provenance, effect) ->
      NetworkTerminal(Response(response, provenance), effect)
    FailureObservation(_, _, _, failure, effect) ->
      NetworkTerminal(Failed(failure), effect)
    CancellationObservation(_, _, _, effect) ->
      NetworkTerminal(Cancelled, effect)
    DeadlineObservation(_, _, _, deadline, clock, effect) ->
      NetworkTerminal(DeadlineExceeded(deadline, clock), effect)
  }
}

fn recorded_delivery(
  record: AttemptRecord,
  delivery: Int,
) -> Option(AdapterObservation) {
  case record.first_delivery {
    Some(first) if first.delivery == delivery -> Some(first.observation)
    _ -> {
      case
        list.find(record.late, fn(late) { late.delivered.delivery == delivery })
      {
        Ok(late) -> Some(late.delivered.observation)
        Error(_) -> None
      }
    }
  }
}

fn expected_delivery(record: AttemptRecord) -> Int {
  case list.last(record.late) {
    Ok(late) -> late.delivered.delivery + 1
    Error(_) ->
      case record.first_delivery {
        Some(first) -> first.delivery + 1
        None -> 0
      }
  }
}

pub fn annotate_effect(
  state: NetworkState,
  observation: EffectObservation,
) -> StateStep {
  case valid_state(state), record_for(state, observation.attempt) {
    False, _ -> StateRejected(state, failure_for_invalid_state(state))
    True, None -> StateRejected(state, UnknownAttempt(observation.attempt))
    True, Some(record) ->
      case record.disposition {
        Settled(handle, terminal) ->
          case effect_matches(observation.attempt, observation.status) {
            False ->
              StateRejected(state, EffectWitnessMissing(observation.attempt))
            True ->
              case terminal.effect, observation.status {
                Unknown(_), NoEffect(_) | Unknown(_), EffectOccurred(_) ->
                  Applied(replace_record(
                    state,
                    observation.attempt,
                    AttemptRecord(
                      record.input,
                      record.lineage,
                      Settled(
                        handle,
                        NetworkTerminal(terminal.outcome, observation.status),
                      ),
                      record.first_delivery,
                      record.late,
                    ),
                  ))
                NoEffect(old), NoEffect(new) if old == new -> Applied(state)
                EffectOccurred(old), EffectOccurred(new) if old == new ->
                  Applied(state)
                NoEffect(_), EffectOccurred(_)
                | EffectOccurred(_), NoEffect(_)
                ->
                  StateRejected(
                    state,
                    EffectKnowledgeConflict(observation.attempt),
                  )
                _, _ ->
                  StateRejected(
                    state,
                    EffectWitnessMissing(observation.attempt),
                  )
              }
          }
        _ ->
          StateRejected(
            state,
            AttemptConditionMismatch(
              observation.attempt,
              IsSettled,
              disposition_condition(record.disposition),
            ),
          )
      }
  }
}

fn disposition_condition(disposition: AttemptDisposition) -> AttemptCondition {
  case disposition {
    Prepared -> IsPrepared
    CommandIssued -> IsCommandIssued
    Started(_) -> IsStarted
    Settled(_, _) -> IsSettled
  }
}

fn authorization_used(
  state: NetworkState,
  authorization: RetryAuthorization,
) -> Bool {
  list.any(state.attempts, fn(record) {
    case record.lineage {
      Root -> False
      RetryOf(candidate) -> candidate == authorization
    }
  })
}

pub fn retry(state: NetworkState, request: RetryRequest) -> PrepareStep {
  case request.permission {
    RetryDenied(_, key, _) -> PrepareRejected(state, RetryNotPermitted(key))
    RetryAllowed(authorization) -> {
      let input =
        AttemptInput(
          authorization.next,
          request.instruction,
          request.deadline,
          request.configuration,
        )
      let parent_is_settled_maximum =
        list.any(state.attempts, fn(record) {
          record.input.attempt == authorization.from
          && is_settled(record.disposition)
        })
        && !list.any(state.attempts, fn(record) {
          record.input.attempt.logical == authorization.from.logical
          && record.input.attempt.ordinal > authorization.from.ordinal
        })
      let acceptable =
        valid_state(state)
        && input_valid(input)
        && authorization.logical == authorization.from.logical
        && authorization.logical == authorization.next.logical
        && authorization.next.ordinal == authorization.from.ordinal + 1
        && parent_is_settled_maximum
        && !list.any(state.attempts, fn(record) {
          record.input.attempt == authorization.next
        })
        && !authorization_used(state, authorization)
      case acceptable {
        False -> PrepareRejected(state, RetryNotPermitted(authorization.from))
        True -> {
          let prepared = PreparedAttempt(input, RetryOf(authorization))
          let next =
            append_record(
              state,
              AttemptRecord(input, RetryOf(authorization), Prepared, None, []),
            )
          case valid_state(next), prepared_relation(next, prepared) {
            True, True -> PreparedResult(next, prepared)
            _, _ -> PrepareRejected(state, failure_for_invalid_state(next))
          }
        }
      }
    }
  }
}
