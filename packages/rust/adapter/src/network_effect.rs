// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::core::Nat;
use crate::request_progression::{ExecutionHandle, RequestIdentity};
use neco_quotient_retention::{
    judge_erasure_by, ErasureDecision, ErasureRequest, LiveFns, Recoverability,
};
use num_traits::{ToPrimitive, Zero};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::borrow::Borrow;
use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::str::FromStr;
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Natural(pub Nat);

impl Natural {
    fn successor(&self) -> Self {
        Self(&self.0 + 1u8)
    }

    pub fn to_u64(&self) -> Option<u64> {
        self.0.to_u64()
    }

    fn is_zero(&self) -> bool {
        self.0.is_zero()
    }
}

impl From<u8> for Natural {
    fn from(value: u8) -> Self {
        Self(value.into())
    }
}

impl From<u16> for Natural {
    fn from(value: u16) -> Self {
        Self(value.into())
    }
}

impl From<u64> for Natural {
    fn from(value: u64) -> Self {
        Self(value.into())
    }
}
impl From<u128> for Natural {
    fn from(value: u128) -> Self {
        Self(value.into())
    }
}

impl From<usize> for Natural {
    fn from(value: usize) -> Self {
        Self(value.into())
    }
}

impl Serialize for Natural {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serde_json::Number::from_str(&self.0.to_string())
            .map_err(serde::ser::Error::custom)?
            .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Natural {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let number = serde_json::Number::deserialize(deserializer)?;
        let encoded = number.to_string();
        Nat::parse_bytes(encoded.as_bytes(), 10)
            .map(Self)
            .ok_or_else(|| serde::de::Error::custom("natural number required"))
    }
}

pub type ByteString = Vec<u8>;
pub type DeliveryOrdinal = Natural;
pub type SourceSequence = Option<Natural>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawHeaderField {
    pub name: String,
    pub value: ByteString,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HttpWireInstruction {
    pub method: String,
    pub target: String,
    pub headers: Vec<RawHeaderField>,
    pub body: ByteString,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawHttpResponse {
    pub status: Natural,
    pub headers: Vec<RawHeaderField>,
    pub body: ByteString,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum HeaderProvenance {
    WireObserved,
    LibraryObserved,
    LibraryNormalized,
}

#[derive(Serialize, Deserialize)]
struct RequestIdentityCodec {
    kind: String,
    provenance: String,
    revision: Natural,
}

impl Serialize for RequestIdentity {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        RequestIdentityCodec {
            kind: self.kind.clone(),
            provenance: self.provenance.clone(),
            revision: Natural(self.revision.clone()),
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for RequestIdentity {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = RequestIdentityCodec::deserialize(deserializer)?;
        Ok(Self {
            kind: value.kind,
            provenance: value.provenance,
            revision: value.revision.0,
        })
    }
}

impl Serialize for ExecutionHandle {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Codec<'a> {
            value: &'a str,
        }
        Codec { value: &self.value }.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for ExecutionHandle {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Codec {
            value: String,
        }
        Ok(Self {
            value: Codec::deserialize(deserializer)?.value.into(),
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AttemptIdentity {
    pub logical: RequestIdentity,
    pub ordinal: Natural,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OpaqueEvidence {
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClockBasis {
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MonotonicClockObservation {
    pub clock_basis: ClockBasis,
    pub value: Natural,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MonotonicClockCapability {
    pub identity: OpaqueEvidence,
    pub clock_basis: ClockBasis,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancellationCapability {
    pub identity: OpaqueEvidence,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Deadline {
    pub clock_basis: ClockBasis,
    pub limit: Natural,
    pub capability: MonotonicClockCapability,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostConfiguration {
    pub request_body_limit: Natural,
    pub response_body_limit: Natural,
    pub cancellation: Option<CancellationCapability>,
    pub monotonic_clock: Option<MonotonicClockCapability>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptInput {
    pub attempt: AttemptIdentity,
    pub instruction: HttpWireInstruction,
    pub deadline: Option<Deadline>,
    pub configuration: HostConfiguration,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryAuthorization {
    pub logical: RequestIdentity,
    pub from: AttemptIdentity,
    pub next: AttemptIdentity,
    pub protocol_evidence: OpaqueEvidence,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum AttemptChain {
    Root,
    RetryOf { authorization: RetryAuthorization },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreparedAttempt {
    pub input: Arc<AttemptInput>,
    pub chain: AttemptChain,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartedAttempt {
    pub prepared: PreparedAttempt,
    pub handle: ExecutionHandle,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SendCommand {
    pub prepared: PreparedAttempt,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancelCommand {
    pub attempt: AttemptIdentity,
    pub handle: ExecutionHandle,
    pub capability: CancellationCapability,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum EffectWitnessSource {
    Adapter,
    Protocol,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectWitness {
    pub attempt: AttemptIdentity,
    pub source: EffectWitnessSource,
    pub evidence: OpaqueEvidence,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum UnknownEffectReason {
    NoResponse,
    Cancellation,
    Deadline,
    HostFailure,
    ProtocolWitnessMissing,
    LateSignal,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum EffectStatus {
    NoEffect { witness: EffectWitness },
    EffectOccurred { witness: EffectWitness },
    Unknown { reason: UnknownEffectReason },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectObservation {
    pub attempt: AttemptIdentity,
    pub status: EffectStatus,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum HostStage {
    Start,
    RequestWrite,
    ResponseHeaders,
    ResponseBody,
    Cancel,
    Deadline,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum HostTimeoutCause {
    LibraryReported,
    SocketReported,
    PoolAcquisition,
    HostOperation,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum HostFailure {
    UnsupportedUriScheme,
    InvalidHostConfiguration,
    ExecutionStartFailed,
    NameResolutionFailed,
    ConnectionFailed,
    RequestWriteFailed,
    ResponseHeadersFailed,
    ResponseBodyFailed,
    ResponseBodyLimitExceeded,
    MalformedResponse,
    HeaderRepresentationUnavailable,
    RequestHeaderEncodingUnavailable,
    CancellationRejected,
    DeadlineControlUnavailable,
    Timeout {
        stage: HostStage,
        cause: HostTimeoutCause,
    },
    HostRuntimeFailure,
    HostClosed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkHostFailure {
    pub attempt: AttemptIdentity,
    pub stage: HostStage,
    pub configuration: HostConfiguration,
    pub cause: HostFailure,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum NetworkOutcome {
    Response {
        response: RawHttpResponse,
        provenance: HeaderProvenance,
    },
    Failed {
        failure: NetworkHostFailure,
    },
    Cancelled,
    DeadlineExceeded {
        deadline: Deadline,
        #[serde(rename = "observedAt")]
        observed_at: MonotonicClockObservation,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkTerminal {
    pub outcome: NetworkOutcome,
    pub effect: EffectStatus,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum AttemptDisposition {
    Prepared,
    CommandIssued,
    Started {
        handle: ExecutionHandle,
    },
    Settled {
        handle: Option<ExecutionHandle>,
        terminal: NetworkTerminal,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeliveredObservation {
    pub delivery: DeliveryOrdinal,
    pub observation: AdapterObservation,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LateObservation {
    pub delivered: DeliveredObservation,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttemptRecord {
    pub input: Arc<AttemptInput>,
    pub chain: AttemptChain,
    pub disposition: AttemptDisposition,
    pub first_delivery: Option<DeliveredObservation>,
    pub late: Vec<LateObservation>,
}

/// Network effect state. Records keep their order and satisfy the state
/// invariant; [`network_state_of`] checks it on construction.
#[derive(Clone, Debug, Default)]
pub struct NetworkState {
    attempts: Vec<AttemptRecord>,
    positions: HashMap<AttemptKey, usize>,
    highest_ordinals: HashMap<RequestKey, usize>,
}

#[derive(Clone, Debug)]
struct AttemptKey(Arc<AttemptInput>);

impl PartialEq for AttemptKey {
    fn eq(&self, other: &Self) -> bool {
        self.0.attempt == other.0.attempt
    }
}

impl Eq for AttemptKey {}

impl Hash for AttemptKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.attempt.hash(state);
    }
}

impl Borrow<AttemptIdentity> for AttemptKey {
    fn borrow(&self) -> &AttemptIdentity {
        &self.0.attempt
    }
}

#[derive(Clone, Debug)]
struct RequestKey(Arc<AttemptInput>);

impl PartialEq for RequestKey {
    fn eq(&self, other: &Self) -> bool {
        self.0.attempt.logical == other.0.attempt.logical
    }
}

impl Eq for RequestKey {}

impl Hash for RequestKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.attempt.logical.hash(state);
    }
}

impl Borrow<RequestIdentity> for RequestKey {
    fn borrow(&self) -> &RequestIdentity {
        &self.0.attempt.logical
    }
}

impl PartialEq for NetworkState {
    fn eq(&self, other: &Self) -> bool {
        self.attempts == other.attempts
    }
}

impl Eq for NetworkState {}

#[derive(Serialize)]
struct NetworkStateView<'a> {
    attempts: &'a [AttemptRecord],
}

#[derive(Deserialize)]
struct NetworkStateRecords {
    attempts: Vec<AttemptRecord>,
}

impl Serialize for NetworkState {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        NetworkStateView {
            attempts: &self.attempts,
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for NetworkState {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let records = NetworkStateRecords::deserialize(deserializer)?;
        network_state_of(records.attempts)
            .map_err(|violation| serde::de::Error::custom(format!("{violation:?}")))
    }
}

impl NetworkState {
    /// An empty state with room for `attempts` records.
    pub fn with_capacity(attempts: usize) -> Self {
        Self {
            attempts: Vec::with_capacity(attempts),
            positions: HashMap::with_capacity(attempts),
            highest_ordinals: HashMap::with_capacity(attempts),
        }
    }

    fn position(&self, attempt: &AttemptIdentity) -> Option<usize> {
        self.positions.get(attempt).copied()
    }

    fn record_mut(&mut self, attempt: &AttemptIdentity) -> Option<&mut AttemptRecord> {
        let position = self.position(attempt)?;
        self.attempts.get_mut(position)
    }

    fn push_record(&mut self, record: AttemptRecord) {
        let position = self.attempts.len();
        self.positions
            .insert(AttemptKey(Arc::clone(&record.input)), position);
        match self
            .highest_ordinals
            .entry(RequestKey(Arc::clone(&record.input)))
        {
            Entry::Vacant(vacant) => {
                vacant.insert(position);
            }
            Entry::Occupied(mut occupied) => {
                let raised = self
                    .attempts
                    .get(*occupied.get())
                    .is_none_or(|held| held.input.attempt.ordinal < record.input.attempt.ordinal);
                if raised {
                    occupied.insert(position);
                }
            }
        }
        self.attempts.push(record);
    }

    fn later_attempt_exists(&self, attempt: &AttemptIdentity) -> bool {
        self.highest_ordinals
            .get(&attempt.logical)
            .and_then(|position| self.attempts.get(*position))
            .is_some_and(|held| held.input.attempt.ordinal > attempt.ordinal)
    }

    fn authorization_used(&self, authorization: &RetryAuthorization) -> bool {
        lookup_attempt(self, &authorization.next).is_some_and(|record| {
            matches!(
                &record.chain,
                AttemptChain::RetryOf { authorization: held } if held == authorization
            )
        })
    }
}

/// Build a network state from its records, or return the first violated
/// condition of the state invariant.
pub fn network_state_of(
    attempts: Vec<AttemptRecord>,
) -> Result<NetworkState, NetworkStateViolation> {
    if !valid_records(&attempts) {
        return Err(records_violation(&attempts));
    }
    let mut state = NetworkState::default();
    for record in attempts {
        state.push_record(record);
    }
    Ok(state)
}

/// Borrow the records in their order.
pub fn network_attempts(state: &NetworkState) -> &[AttemptRecord] {
    &state.attempts
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum AdapterObservation {
    ResponseObservation {
        attempt: AttemptIdentity,
        handle: ExecutionHandle,
        #[serde(rename = "sourceSequence")]
        source_sequence: SourceSequence,
        response: RawHttpResponse,
        provenance: HeaderProvenance,
        effect: EffectStatus,
    },
    FailureObservation {
        attempt: AttemptIdentity,
        handle: ExecutionHandle,
        #[serde(rename = "sourceSequence")]
        source_sequence: SourceSequence,
        failure: NetworkHostFailure,
        effect: EffectStatus,
    },
    CancellationObservation {
        attempt: AttemptIdentity,
        handle: ExecutionHandle,
        #[serde(rename = "sourceSequence")]
        source_sequence: SourceSequence,
        effect: EffectStatus,
    },
    DeadlineObservation {
        attempt: AttemptIdentity,
        handle: ExecutionHandle,
        #[serde(rename = "sourceSequence")]
        source_sequence: SourceSequence,
        deadline: Deadline,
        #[serde(rename = "observedAt")]
        observed_at: MonotonicClockObservation,
        effect: EffectStatus,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum RetryPermission {
    RetryAllowed {
        authorization: RetryAuthorization,
    },
    RetryDenied {
        logical: RequestIdentity,
        parent: AttemptIdentity,
        evidence: OpaqueEvidence,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RetryRequest {
    pub permission: RetryPermission,
    pub instruction: HttpWireInstruction,
    pub deadline: Option<Deadline>,
    pub configuration: HostConfiguration,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum StartObservation {
    Started {
        attempt: AttemptIdentity,
        handle: ExecutionHandle,
    },
    StartFailed {
        failure: NetworkHostFailure,
        effect: EffectStatus,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum HostObservation {
    Pending {
        attempt: AttemptIdentity,
        handle: ExecutionHandle,
    },
    Delivered {
        delivery: DeliveryOrdinal,
        observation: AdapterObservation,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum NetworkStateViolation {
    DuplicateAttemptKey { attempt: AttemptIdentity },
    NonRootFirstAttempt { attempt: AttemptIdentity },
    OrdinalGap { attempt: AttemptIdentity },
    ChainMismatch { attempt: AttemptIdentity },
    RetryAuthorizationReuse { authorization: RetryAuthorization },
    DispositionEvidenceMismatch { attempt: AttemptIdentity },
    DeliveryLogMismatch { attempt: AttemptIdentity },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AttemptCondition {
    IsPrepared,
    IsCommandIssued,
    IsStarted,
    IsSettled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AttemptTokenField {
    Instruction,
    Deadline,
    Configuration,
    Chain,
    Handle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ObservationField {
    FailureConfiguration,
    FailureStage,
    DeadlineValue,
    ClockBasisValue,
    ClockObservationValue,
    EffectWitnessValue,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CapabilityKind {
    Cancellation,
    MonotonicClock,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum NetworkFailure {
    InvalidWireInstruction {
        method: String,
    },
    InvalidDeadline,
    InvalidNetworkState {
        violation: NetworkStateViolation,
    },
    RootAttemptRequired {
        attempt: AttemptIdentity,
    },
    DuplicateAttempt {
        attempt: AttemptIdentity,
    },
    UnknownAttempt {
        attempt: AttemptIdentity,
    },
    AttemptConditionMismatch {
        attempt: AttemptIdentity,
        expected: AttemptCondition,
        actual: AttemptCondition,
    },
    AttemptTokenMismatch {
        attempt: AttemptIdentity,
        field: AttemptTokenField,
    },
    ObservationRelationMismatch {
        attempt: AttemptIdentity,
        field: ObservationField,
    },
    RequiredCapabilityUnavailable {
        attempt: AttemptIdentity,
        capability: CapabilityKind,
    },
    CommandAlreadyIssued {
        attempt: AttemptIdentity,
    },
    IdentityMismatch {
        expected: AttemptIdentity,
        actual: AttemptIdentity,
    },
    HandleMismatch {
        expected: ExecutionHandle,
        actual: ExecutionHandle,
    },
    ClockBasisMismatch {
        expected: ClockBasis,
        actual: ClockBasis,
    },
    DeadlineNotReached {
        deadline: Deadline,
        #[serde(rename = "observedAt")]
        observed_at: MonotonicClockObservation,
    },
    DeliveryOrderViolation {
        attempt: AttemptIdentity,
        expected: DeliveryOrdinal,
        actual: DeliveryOrdinal,
    },
    ConflictingDelivery {
        attempt: AttemptIdentity,
        delivery: DeliveryOrdinal,
        old: AdapterObservation,
        fresh: AdapterObservation,
    },
    MalformedAdapterObservation,
    Host {
        failure: NetworkHostFailure,
    },
    RetryNotPermitted {
        attempt: AttemptIdentity,
    },
    RetryIdentityMismatch {
        expected: RequestIdentity,
        actual: RequestIdentity,
    },
    RetryParentMismatch {
        expected: AttemptIdentity,
        actual: AttemptIdentity,
    },
    RetryParentNotSettled {
        attempt: AttemptIdentity,
    },
    RetryOrderViolation {
        expected: AttemptIdentity,
        actual: AttemptIdentity,
    },
    RetryAuthorizationAlreadyUsed {
        authorization: RetryAuthorization,
    },
    EffectWitnessMissing {
        attempt: AttemptIdentity,
    },
    EffectKnowledgeConflict {
        attempt: AttemptIdentity,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadStateStep {
    Read(NetworkState),
    Rejected(NetworkState, NetworkFailure),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrepareStep {
    Prepared(NetworkState, PreparedAttempt),
    Rejected(NetworkState, NetworkFailure),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandStep<T> {
    CommandReady(NetworkState, T),
    Rejected(NetworkState, NetworkFailure),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StateStep {
    Applied(NetworkState),
    Rejected(NetworkState, NetworkFailure),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettledAttempt {
    pub prepared: PreparedAttempt,
    pub handle: Option<ExecutionHandle>,
    pub terminal: NetworkTerminal,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NetworkStep {
    Started(NetworkState, StartedAttempt),
    Pending(NetworkState, StartedAttempt),
    Terminal(NetworkState, SettledAttempt),
    Late(NetworkState, SettledAttempt, LateObservation),
    Duplicate(NetworkState, AttemptIdentity, DeliveryOrdinal),
    Rejected(NetworkState, NetworkFailure),
}

fn token_char_ok(value: char) -> bool {
    value.is_ascii_alphanumeric()
        || matches!(
            value,
            '!' | '#'
                | '$'
                | '%'
                | '&'
                | '\''
                | '*'
                | '+'
                | '-'
                | '.'
                | '^'
                | '_'
                | '`'
                | '|'
                | '~'
        )
}

fn token_ok(value: &str) -> bool {
    !value.is_empty() && value.chars().all(token_char_ok)
}

fn alpha_byte_ok(value: u8) -> bool {
    value.is_ascii_alphabetic()
}

fn digit_byte_ok(value: u8) -> bool {
    value.is_ascii_digit()
}

fn hex_byte_ok(value: u8) -> bool {
    value.is_ascii_hexdigit()
}

fn uri_unreserved_ok(value: u8) -> bool {
    alpha_byte_ok(value) || digit_byte_ok(value) || matches!(value, b'-' | b'.' | b'_' | b'~')
}

fn uri_sub_delim_ok(value: u8) -> bool {
    matches!(
        value,
        b'!' | b'$' | b'&' | b'\'' | b'(' | b')' | b'*' | b'+' | b',' | b';' | b'='
    )
}

fn uri_pchar_ok(value: u8) -> bool {
    uri_unreserved_ok(value) || uri_sub_delim_ok(value) || matches!(value, b':' | b'@')
}

fn percent_encoded_ok(value: &[u8], index: usize) -> bool {
    match (value.get(index + 1), value.get(index + 2)) {
        (Some(high), Some(low)) => hex_byte_ok(*high) && hex_byte_ok(*low),
        _ => false,
    }
}

fn uri_component_ok(allow_question: bool, value: &[u8]) -> bool {
    let mut index = 0;
    while let Some(character) = value.get(index).copied() {
        if character == b'%' {
            if !percent_encoded_ok(value, index) {
                return false;
            }
            index += 3;
            continue;
        }
        if !(uri_pchar_ok(character) || character == b'/' || (allow_question && character == b'?'))
        {
            return false;
        }
        index += 1;
    }
    true
}

fn split_at_byte(value: &[u8], delimiter: u8) -> (&[u8], Option<&[u8]>) {
    match value.iter().position(|candidate| *candidate == delimiter) {
        Some(index) => {
            let (head, tail) = value.split_at(index);
            (head, Some(tail.get(1..).unwrap_or_default()))
        }
        None => (value, None),
    }
}

fn uri_reg_name_ok(value: &[u8]) -> bool {
    let mut index = 0;
    while let Some(character) = value.get(index).copied() {
        if character == b'%' {
            if !percent_encoded_ok(value, index) {
                return false;
            }
            index += 3;
        } else if uri_unreserved_ok(character) || uri_sub_delim_ok(character) {
            index += 1;
        } else {
            return false;
        }
    }
    true
}

fn uri_user_info_ok(value: &[u8]) -> bool {
    let mut index = 0;
    while let Some(character) = value.get(index).copied() {
        if character == b'%' {
            if !percent_encoded_ok(value, index) {
                return false;
            }
            index += 3;
        } else if uri_unreserved_ok(character) || uri_sub_delim_ok(character) || character == b':' {
            index += 1;
        } else {
            return false;
        }
    }
    true
}

fn uri_port_ok(value: &[u8]) -> bool {
    value.iter().all(|character| digit_byte_ok(*character))
}

fn uri_ip_literal_ok(value: &[u8]) -> bool {
    !value.is_empty()
        && value
            .iter()
            .any(|character| matches!(character, b':' | b'.'))
        && value.iter().all(|character| {
            hex_byte_ok(*character)
                || matches!(character, b':' | b'.' | b'v' | b'V')
                || uri_unreserved_ok(*character)
                || uri_sub_delim_ok(*character)
        })
}

fn uri_port_suffix_ok(value: &[u8]) -> bool {
    match value.split_first() {
        None => true,
        Some((b':', port)) => uri_port_ok(port),
        Some(_) => false,
    }
}

fn uri_host_port_ok(value: &[u8]) -> bool {
    if let Some((b'[', rest)) = value.split_first() {
        let Some(end) = rest.iter().position(|character| *character == b']') else {
            return false;
        };
        let (literal, after) = rest.split_at(end);
        let Some(port_suffix) = after.get(1..) else {
            return false;
        };
        return uri_ip_literal_ok(literal) && uri_port_suffix_ok(port_suffix);
    }
    let (host, port) = split_at_byte(value, b':');
    uri_reg_name_ok(host) && port.is_none_or(uri_port_ok)
}

fn authority_ok(value: &[u8]) -> bool {
    let (userinfo, host_port) = split_at_byte(value, b'@');
    match host_port {
        None => uri_host_port_ok(userinfo),
        Some(host_port) => {
            !host_port.contains(&b'@') && uri_user_info_ok(userinfo) && uri_host_port_ok(host_port)
        }
    }
}

fn uri_hier_part_ok(value: &[u8]) -> bool {
    if let Some(rest) = value.strip_prefix(b"//") {
        let authority_length = rest
            .iter()
            .position(|character| *character == b'/')
            .unwrap_or(rest.len());
        let (authority, path) = rest.split_at(authority_length);
        authority_ok(authority) && uri_component_ok(false, path)
    } else {
        uri_component_ok(false, value)
    }
}

fn uri_tail_ok(value: &[u8]) -> bool {
    let (before_fragment, fragment) = split_at_byte(value, b'#');
    let (path, query) = split_at_byte(before_fragment, b'?');
    uri_hier_part_ok(path)
        && query.is_none_or(|part| uri_component_ok(true, part))
        && fragment.is_none_or(|part| uri_component_ok(true, part))
}

fn target_ok(target: &str) -> bool {
    if !target.is_ascii() {
        return false;
    }
    let characters = target.as_bytes();
    let Some((first, rest)) = characters.split_first() else {
        return false;
    };
    let first = *first;
    let scheme_length = rest
        .iter()
        .position(|character| *character == b':')
        .unwrap_or(rest.len());
    if scheme_length == rest.len() {
        return false;
    }
    let (scheme, after) = rest.split_at(scheme_length);
    let Some(tail) = after.get(1..) else {
        return false;
    };
    alpha_byte_ok(first)
        && scheme.iter().all(|character| {
            alpha_byte_ok(*character)
                || digit_byte_ok(*character)
                || matches!(character, b'+' | b'-' | b'.')
        })
        && uri_tail_ok(tail)
}

fn headers_ok(headers: &[RawHeaderField]) -> bool {
    headers.iter().all(|header| token_ok(&header.name))
}

fn instruction_ok(instruction: &HttpWireInstruction) -> bool {
    token_ok(&instruction.method)
        && target_ok(&instruction.target)
        && headers_ok(&instruction.headers)
}

fn response_ok(response: &RawHttpResponse) -> bool {
    response.status.0 >= Nat::from(100u16)
        && response.status.0 <= Nat::from(999u16)
        && headers_ok(&response.headers)
}

pub fn valid_attempt_input(input: &AttemptInput) -> bool {
    attempt_input_ok(
        &input.instruction,
        input.deadline.as_ref(),
        &input.configuration,
    )
}

fn attempt_input_ok(
    instruction: &HttpWireInstruction,
    deadline: Option<&Deadline>,
    configuration: &HostConfiguration,
) -> bool {
    instruction_ok(instruction)
        && Natural::from(instruction.body.len()) <= configuration.request_body_limit
        && deadline.is_none_or(|deadline| {
            deadline.capability.clock_basis == deadline.clock_basis
                && configuration.monotonic_clock.as_ref() == Some(&deadline.capability)
        })
}

pub fn clock_reaches(deadline: &Deadline, observation: &MonotonicClockObservation) -> bool {
    deadline.capability.clock_basis == deadline.clock_basis
        && observation.clock_basis == deadline.clock_basis
        && deadline.limit <= observation.value
}

fn effect_matches(attempt: &AttemptIdentity, status: &EffectStatus) -> bool {
    match status {
        EffectStatus::Unknown { .. } => true,
        EffectStatus::NoEffect { witness } | EffectStatus::EffectOccurred { witness } => {
            &witness.attempt == attempt
        }
    }
}

pub fn attempt_of(observation: &AdapterObservation) -> &AttemptIdentity {
    match observation {
        AdapterObservation::ResponseObservation { attempt, .. }
        | AdapterObservation::FailureObservation { attempt, .. }
        | AdapterObservation::CancellationObservation { attempt, .. }
        | AdapterObservation::DeadlineObservation { attempt, .. } => attempt,
    }
}

pub fn handle_of(observation: &AdapterObservation) -> &ExecutionHandle {
    match observation {
        AdapterObservation::ResponseObservation { handle, .. }
        | AdapterObservation::FailureObservation { handle, .. }
        | AdapterObservation::CancellationObservation { handle, .. }
        | AdapterObservation::DeadlineObservation { handle, .. } => handle,
    }
}

pub fn source_of(observation: &AdapterObservation) -> SourceSequence {
    match observation {
        AdapterObservation::ResponseObservation {
            source_sequence, ..
        }
        | AdapterObservation::FailureObservation {
            source_sequence, ..
        }
        | AdapterObservation::CancellationObservation {
            source_sequence, ..
        }
        | AdapterObservation::DeadlineObservation {
            source_sequence, ..
        } => source_sequence.clone(),
    }
}

fn effect_of_observation(observation: &AdapterObservation) -> &EffectStatus {
    match observation {
        AdapterObservation::ResponseObservation { effect, .. }
        | AdapterObservation::FailureObservation { effect, .. }
        | AdapterObservation::CancellationObservation { effect, .. }
        | AdapterObservation::DeadlineObservation { effect, .. } => effect,
    }
}

pub fn terminal_of_observation(observation: &AdapterObservation) -> NetworkTerminal {
    match observation {
        AdapterObservation::ResponseObservation {
            response,
            provenance,
            effect,
            ..
        } => NetworkTerminal {
            outcome: NetworkOutcome::Response {
                response: response.clone(),
                provenance: *provenance,
            },
            effect: effect.clone(),
        },
        AdapterObservation::FailureObservation {
            failure, effect, ..
        } => NetworkTerminal {
            outcome: NetworkOutcome::Failed {
                failure: failure.clone(),
            },
            effect: effect.clone(),
        },
        AdapterObservation::CancellationObservation { effect, .. } => NetworkTerminal {
            outcome: NetworkOutcome::Cancelled,
            effect: effect.clone(),
        },
        AdapterObservation::DeadlineObservation {
            deadline,
            observed_at,
            effect,
            ..
        } => NetworkTerminal {
            outcome: NetworkOutcome::DeadlineExceeded {
                deadline: deadline.clone(),
                observed_at: observed_at.clone(),
            },
            effect: effect.clone(),
        },
    }
}

fn disposition_handle(disposition: &AttemptDisposition) -> Option<&ExecutionHandle> {
    match disposition {
        AttemptDisposition::Started { handle }
        | AttemptDisposition::Settled {
            handle: Some(handle),
            ..
        } => Some(handle),
        _ => None,
    }
}

fn disposition_condition(disposition: &AttemptDisposition) -> AttemptCondition {
    match disposition {
        AttemptDisposition::Prepared => AttemptCondition::IsPrepared,
        AttemptDisposition::CommandIssued => AttemptCondition::IsCommandIssued,
        AttemptDisposition::Started { .. } => AttemptCondition::IsStarted,
        AttemptDisposition::Settled { .. } => AttemptCondition::IsSettled,
    }
}

fn terminal_evidence_ok(attempt: &AttemptIdentity, terminal: &NetworkTerminal) -> bool {
    effect_matches(attempt, &terminal.effect)
        && match &terminal.outcome {
            NetworkOutcome::Failed { failure } => &failure.attempt == attempt,
            _ => true,
        }
}

fn late_evidence_ok(
    late: &[LateObservation],
    attempt: &AttemptIdentity,
    handle: &ExecutionHandle,
    mut previous: DeliveryOrdinal,
) -> bool {
    for value in late {
        if previous >= value.delivered.delivery
            || attempt_of(&value.delivered.observation) != attempt
            || handle_of(&value.delivered.observation) != handle
        {
            return false;
        }
        previous = value.delivered.delivery.clone();
    }
    true
}

fn record_evidence_ok(record: &AttemptRecord) -> bool {
    match &record.disposition {
        AttemptDisposition::Prepared
        | AttemptDisposition::CommandIssued
        | AttemptDisposition::Started { .. } => {
            record.first_delivery.is_none() && record.late.is_empty()
        }
        AttemptDisposition::Settled {
            handle: None,
            terminal,
        } => {
            record.first_delivery.is_none()
                && record.late.is_empty()
                && terminal_evidence_ok(&record.input.attempt, terminal)
        }
        AttemptDisposition::Settled {
            handle: Some(handle),
            terminal,
        } => {
            terminal_evidence_ok(&record.input.attempt, terminal)
                && record.first_delivery.as_ref().is_some_and(|first| {
                    first.delivery.is_zero()
                        && attempt_of(&first.observation) == &record.input.attempt
                        && handle_of(&first.observation) == handle
                        && late_evidence_ok(
                            &record.late,
                            &record.input.attempt,
                            handle,
                            first.delivery.clone(),
                        )
                })
        }
    }
}

fn root_for_logical(records: &[AttemptRecord], logical: &RequestIdentity) -> bool {
    records.iter().any(|record| {
        &record.input.attempt.logical == logical
            && record.input.attempt.ordinal.is_zero()
            && record.chain == AttemptChain::Root
    })
}

fn settled_key(records: &[AttemptRecord], attempt: &AttemptIdentity) -> bool {
    records.iter().any(|record| {
        &record.input.attempt == attempt
            && matches!(record.disposition, AttemptDisposition::Settled { .. })
    })
}

fn chain_ok(records: &[AttemptRecord], record: &AttemptRecord) -> bool {
    root_for_logical(records, &record.input.attempt.logical)
        && match &record.chain {
            AttemptChain::Root => record.input.attempt.ordinal.is_zero(),
            AttemptChain::RetryOf { authorization } => {
                authorization.logical == record.input.attempt.logical
                    && authorization.from.logical == record.input.attempt.logical
                    && authorization.next == record.input.attempt
                    && authorization.from.ordinal.successor() == authorization.next.ordinal
                    && settled_key(records, &authorization.from)
            }
        }
}

fn authorization_unique(records: &[AttemptRecord]) -> bool {
    records.iter().enumerate().all(|(index, record)| match &record.chain {
        AttemptChain::Root => true,
        AttemptChain::RetryOf { authorization } => records.iter().skip(index + 1).all(|candidate| {
            !matches!(&candidate.chain, AttemptChain::RetryOf { authorization: other } if other == authorization)
        }),
    })
}

fn valid_records(records: &[AttemptRecord]) -> bool {
    records.iter().enumerate().all(|(index, record)| {
        !records
            .iter()
            .skip(index + 1)
            .any(|candidate| candidate.input.attempt == record.input.attempt)
            && record_evidence_ok(record)
            && chain_ok(records, record)
    }) && authorization_unique(records)
}

fn first_duplicate_violation(records: &[AttemptRecord]) -> Option<NetworkStateViolation> {
    records.iter().enumerate().find_map(|(index, record)| {
        records
            .iter()
            .skip(index + 1)
            .any(|candidate| candidate.input.attempt == record.input.attempt)
            .then(|| NetworkStateViolation::DuplicateAttemptKey {
                attempt: record.input.attempt.clone(),
            })
    })
}

fn record_evidence_violation(record: &AttemptRecord) -> Option<NetworkStateViolation> {
    if record_evidence_ok(record) {
        return None;
    }
    let attempt = record.input.attempt.clone();
    match &record.disposition {
        AttemptDisposition::Prepared
        | AttemptDisposition::CommandIssued
        | AttemptDisposition::Started { .. } => {
            Some(NetworkStateViolation::DeliveryLogMismatch { attempt })
        }
        AttemptDisposition::Settled { handle: None, .. } => {
            if record.first_delivery.is_none() && record.late.is_empty() {
                Some(NetworkStateViolation::DispositionEvidenceMismatch { attempt })
            } else {
                Some(NetworkStateViolation::DeliveryLogMismatch { attempt })
            }
        }
        AttemptDisposition::Settled {
            handle: Some(_),
            terminal,
        } => {
            if terminal_evidence_ok(&record.input.attempt, terminal) {
                Some(NetworkStateViolation::DeliveryLogMismatch { attempt })
            } else {
                Some(NetworkStateViolation::DispositionEvidenceMismatch { attempt })
            }
        }
    }
}

fn first_record_violation(records: &[AttemptRecord]) -> Option<NetworkStateViolation> {
    records.iter().find_map(record_evidence_violation)
}

fn chain_violation(
    records: &[AttemptRecord],
    record: &AttemptRecord,
) -> Option<NetworkStateViolation> {
    if chain_ok(records, record) {
        return None;
    }
    if !root_for_logical(records, &record.input.attempt.logical) {
        return Some(NetworkStateViolation::NonRootFirstAttempt {
            attempt: record.input.attempt.clone(),
        });
    }
    match &record.chain {
        AttemptChain::Root => Some(NetworkStateViolation::NonRootFirstAttempt {
            attempt: record.input.attempt.clone(),
        }),
        AttemptChain::RetryOf { authorization } => {
            if authorization.next.ordinal != authorization.from.ordinal.successor() {
                Some(NetworkStateViolation::OrdinalGap {
                    attempt: record.input.attempt.clone(),
                })
            } else {
                Some(NetworkStateViolation::ChainMismatch {
                    attempt: record.input.attempt.clone(),
                })
            }
        }
    }
}

fn first_chain_violation(records: &[AttemptRecord]) -> Option<NetworkStateViolation> {
    records
        .iter()
        .find_map(|record| chain_violation(records, record))
}

fn first_root_violation(records: &[AttemptRecord]) -> Option<NetworkStateViolation> {
    records.iter().find_map(|record| {
        (!root_for_logical(records, &record.input.attempt.logical)).then(|| {
            NetworkStateViolation::NonRootFirstAttempt {
                attempt: record.input.attempt.clone(),
            }
        })
    })
}

fn first_authorization_violation(records: &[AttemptRecord]) -> Option<NetworkStateViolation> {
    records.iter().enumerate().find_map(|(index, record)| {
        let AttemptChain::RetryOf { authorization } = &record.chain else {
            return None;
        };
        records
            .iter()
            .skip(index + 1)
            .any(|candidate| {
                matches!(
                    &candidate.chain,
                    AttemptChain::RetryOf {
                        authorization: other
                    } if other == authorization
                )
            })
            .then(|| NetworkStateViolation::RetryAuthorizationReuse {
                authorization: authorization.clone(),
            })
    })
}

fn records_violation(records: &[AttemptRecord]) -> NetworkStateViolation {
    first_duplicate_violation(records)
        .or_else(|| first_record_violation(records))
        .or_else(|| first_chain_violation(records))
        .or_else(|| first_root_violation(records))
        .or_else(|| first_authorization_violation(records))
        .unwrap_or_else(|| NetworkStateViolation::DuplicateAttemptKey {
            attempt: empty_attempt_identity(),
        })
}

fn empty_attempt_identity() -> AttemptIdentity {
    AttemptIdentity {
        logical: RequestIdentity {
            kind: String::new(),
            provenance: String::new(),
            revision: 0u8.into(),
        },
        ordinal: 0u8.into(),
    }
}

pub fn lookup_attempt<'a>(
    state: &'a NetworkState,
    attempt: &AttemptIdentity,
) -> Option<&'a AttemptRecord> {
    state
        .position(attempt)
        .and_then(|position| state.attempts.get(position))
}
fn prepared_token_failure(
    state: &NetworkState,
    prepared: &PreparedAttempt,
) -> Option<NetworkFailure> {
    let Some(record) = lookup_attempt(state, &prepared.input.attempt) else {
        return Some(NetworkFailure::UnknownAttempt {
            attempt: prepared.input.attempt.clone(),
        });
    };
    if record.input.instruction != prepared.input.instruction {
        Some(NetworkFailure::AttemptTokenMismatch {
            attempt: prepared.input.attempt.clone(),
            field: AttemptTokenField::Instruction,
        })
    } else if record.input.deadline != prepared.input.deadline {
        Some(NetworkFailure::AttemptTokenMismatch {
            attempt: prepared.input.attempt.clone(),
            field: AttemptTokenField::Deadline,
        })
    } else if record.input.configuration != prepared.input.configuration {
        Some(NetworkFailure::AttemptTokenMismatch {
            attempt: prepared.input.attempt.clone(),
            field: AttemptTokenField::Configuration,
        })
    } else if record.chain != prepared.chain {
        Some(NetworkFailure::AttemptTokenMismatch {
            attempt: prepared.input.attempt.clone(),
            field: AttemptTokenField::Chain,
        })
    } else {
        None
    }
}

fn prepared_condition_failure(
    state: &NetworkState,
    prepared: &PreparedAttempt,
    expected: AttemptCondition,
) -> Option<NetworkFailure> {
    if let Some(failure) = prepared_token_failure(state, prepared) {
        return Some(failure);
    }
    let Some(record) = lookup_attempt(state, &prepared.input.attempt) else {
        return Some(NetworkFailure::UnknownAttempt {
            attempt: prepared.input.attempt.clone(),
        });
    };
    let actual = disposition_condition(&record.disposition);
    (actual != expected).then(|| NetworkFailure::AttemptConditionMismatch {
        attempt: prepared.input.attempt.clone(),
        expected,
        actual,
    })
}

fn started_token_failure(state: &NetworkState, started: &StartedAttempt) -> Option<NetworkFailure> {
    if let Some(failure) = prepared_token_failure(state, &started.prepared) {
        return Some(failure);
    }
    let Some(record) = lookup_attempt(state, &started.prepared.input.attempt) else {
        return Some(NetworkFailure::UnknownAttempt {
            attempt: started.prepared.input.attempt.clone(),
        });
    };
    match &record.disposition {
        AttemptDisposition::Started { handle } if handle == &started.handle => None,
        AttemptDisposition::Started { handle } => Some(NetworkFailure::HandleMismatch {
            expected: handle.clone(),
            actual: started.handle.clone(),
        }),
        disposition => Some(NetworkFailure::AttemptConditionMismatch {
            attempt: started.prepared.input.attempt.clone(),
            expected: AttemptCondition::IsStarted,
            actual: disposition_condition(disposition),
        }),
    }
}

fn prepared_relation(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    lookup_attempt(state, &prepared.input.attempt)
        .is_some_and(|record| record.input == prepared.input && record.chain == prepared.chain)
}

fn prepared_ready(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    prepared_relation(state, prepared)
        && lookup_attempt(state, &prepared.input.attempt)
            .is_some_and(|record| record.disposition == AttemptDisposition::Prepared)
}

fn command_issued_matches(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    lookup_attempt(state, &prepared.input.attempt).is_some_and(|record| {
        record.input == prepared.input
            && record.chain == prepared.chain
            && record.disposition == AttemptDisposition::CommandIssued
    })
}

fn command_issued_relation(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    prepared_relation(state, prepared)
        && lookup_attempt(state, &prepared.input.attempt)
            .is_some_and(|record| record.disposition == AttemptDisposition::CommandIssued)
}

fn started_relation(state: &NetworkState, started: &StartedAttempt) -> bool {
    lookup_attempt(state, &started.prepared.input.attempt).is_some_and(|record| {
        record.input == started.prepared.input
            && record.chain == started.prepared.chain
            && matches!(
                &record.disposition,
                AttemptDisposition::Started { handle } if handle == &started.handle
            )
            && record.first_delivery.is_none()
            && record.late.is_empty()
    })
}

fn response_fields_match(record: &AttemptRecord, observation: &AdapterObservation) -> bool {
    match observation {
        AdapterObservation::ResponseObservation { response, .. } => {
            response_ok(response)
                && Natural::from(response.body.len())
                    <= record.input.configuration.response_body_limit
        }
        AdapterObservation::CancellationObservation { .. } => true,
        _ => false,
    }
}

fn failure_fields_match(record: &AttemptRecord, observation: &AdapterObservation) -> bool {
    match observation {
        AdapterObservation::FailureObservation {
            attempt, failure, ..
        } => {
            failure.attempt == *attempt
                && failure.configuration == record.input.configuration
                && match failure.cause {
                    HostFailure::Timeout { stage, .. } => stage == failure.stage,
                    _ => true,
                }
        }
        _ => false,
    }
}

fn deadline_fields_match(record: &AttemptRecord, observation: &AdapterObservation) -> bool {
    match (
        &record.input.deadline,
        &record.input.configuration.monotonic_clock,
        observation,
    ) {
        (
            Some(expected),
            Some(capability),
            AdapterObservation::DeadlineObservation {
                deadline,
                observed_at,
                ..
            },
        ) => {
            expected == deadline
                && capability == &expected.capability
                && clock_reaches(expected, observed_at)
        }
        _ => false,
    }
}

fn observation_relation(state: &NetworkState, observation: &AdapterObservation) -> bool {
    lookup_attempt(state, attempt_of(observation)).is_some_and(|record| {
        disposition_handle(&record.disposition).is_some_and(|handle| {
            attempt_of(observation) == &record.input.attempt
                && handle_of(observation) == handle
                && effect_matches(&record.input.attempt, effect_of_observation(observation))
                && (response_fields_match(record, observation)
                    || failure_fields_match(record, observation)
                    || deadline_fields_match(record, observation))
        })
    })
}

fn host_observation_relation(state: &NetworkState, observation: &HostObservation) -> bool {
    match observation {
        HostObservation::Pending { attempt, handle } => {
            lookup_attempt(state, attempt).is_some_and(|record| {
                record.disposition
                    == AttemptDisposition::Started {
                        handle: handle.clone(),
                    }
            })
        }
        HostObservation::Delivered { observation, .. } => observation_relation(state, observation),
    }
}

fn start_observation_relation(
    state: &NetworkState,
    prepared: &PreparedAttempt,
    observation: &StartObservation,
) -> bool {
    command_issued_relation(state, prepared)
        && match observation {
            StartObservation::Started { attempt, .. } => attempt == &prepared.input.attempt,
            StartObservation::StartFailed { failure, effect } => {
                failure.attempt == prepared.input.attempt
                    && failure.stage == HostStage::Start
                    && failure.configuration == prepared.input.configuration
                    && effect_matches(&prepared.input.attempt, effect)
            }
        }
}
fn adapter_observation_failure(
    state: &NetworkState,
    observation: &AdapterObservation,
) -> NetworkFailure {
    let attempt = attempt_of(observation);
    let Some(record) = lookup_attempt(state, attempt) else {
        return NetworkFailure::UnknownAttempt {
            attempt: attempt.clone(),
        };
    };
    let Some(expected_handle) = disposition_handle(&record.disposition) else {
        return NetworkFailure::AttemptConditionMismatch {
            attempt: attempt.clone(),
            expected: AttemptCondition::IsStarted,
            actual: disposition_condition(&record.disposition),
        };
    };
    if handle_of(observation) != expected_handle {
        return NetworkFailure::HandleMismatch {
            expected: expected_handle.clone(),
            actual: handle_of(observation).clone(),
        };
    }
    if !effect_matches(attempt, effect_of_observation(observation)) {
        return NetworkFailure::EffectWitnessMissing {
            attempt: attempt.clone(),
        };
    }
    match observation {
        AdapterObservation::ResponseObservation { .. }
        | AdapterObservation::CancellationObservation { .. } => {
            NetworkFailure::MalformedAdapterObservation
        }
        AdapterObservation::FailureObservation { failure, .. } => {
            if failure.attempt != *attempt {
                NetworkFailure::IdentityMismatch {
                    expected: attempt.clone(),
                    actual: failure.attempt.clone(),
                }
            } else if matches!(
                failure.cause,
                HostFailure::Timeout { stage, .. } if stage != failure.stage
            ) {
                NetworkFailure::ObservationRelationMismatch {
                    attempt: attempt.clone(),
                    field: ObservationField::FailureStage,
                }
            } else {
                NetworkFailure::ObservationRelationMismatch {
                    attempt: attempt.clone(),
                    field: ObservationField::FailureConfiguration,
                }
            }
        }
        AdapterObservation::DeadlineObservation {
            deadline,
            observed_at,
            ..
        } => {
            if record.input.deadline.as_ref() != Some(deadline) {
                NetworkFailure::ObservationRelationMismatch {
                    attempt: attempt.clone(),
                    field: ObservationField::DeadlineValue,
                }
            } else if deadline.clock_basis != observed_at.clock_basis {
                NetworkFailure::ClockBasisMismatch {
                    expected: deadline.clock_basis.clone(),
                    actual: observed_at.clock_basis.clone(),
                }
            } else {
                NetworkFailure::DeadlineNotReached {
                    deadline: deadline.clone(),
                    observed_at: observed_at.clone(),
                }
            }
        }
    }
}

fn host_observation_failure(state: &NetworkState, observation: &HostObservation) -> NetworkFailure {
    match observation {
        HostObservation::Pending { attempt, handle } => {
            let Some(record) = lookup_attempt(state, attempt) else {
                return NetworkFailure::UnknownAttempt {
                    attempt: attempt.clone(),
                };
            };
            match &record.disposition {
                AttemptDisposition::Started { handle: expected } if expected != handle => {
                    NetworkFailure::HandleMismatch {
                        expected: expected.clone(),
                        actual: handle.clone(),
                    }
                }
                AttemptDisposition::Started { .. } => NetworkFailure::MalformedAdapterObservation,
                disposition => NetworkFailure::AttemptConditionMismatch {
                    attempt: attempt.clone(),
                    expected: AttemptCondition::IsStarted,
                    actual: disposition_condition(disposition),
                },
            }
        }
        HostObservation::Delivered { observation, .. } => {
            adapter_observation_failure(state, observation)
        }
    }
}

fn recorded_delivery<'a>(
    record: &'a AttemptRecord,
    delivery: &DeliveryOrdinal,
) -> Option<&'a AdapterObservation> {
    if let Some(first) = &record.first_delivery {
        if &first.delivery == delivery {
            return Some(&first.observation);
        }
    }
    record
        .late
        .iter()
        .find(|late| &late.delivered.delivery == delivery)
        .map(|late| &late.delivered.observation)
}

fn expected_delivery(record: &AttemptRecord) -> DeliveryOrdinal {
    match &record.first_delivery {
        None => 0u8.into(),
        Some(first) => record.late.last().map_or_else(
            || first.delivery.successor(),
            |late| late.delivered.delivery.successor(),
        ),
    }
}

/// Read a network state. States are valid by construction.
pub fn read_network_state(state: NetworkState) -> ReadStateStep {
    ReadStateStep::Read(state)
}

pub fn prepare(mut state: NetworkState, input: Arc<AttemptInput>) -> PrepareStep {
    if !valid_attempt_input(&input) {
        let failure = NetworkFailure::InvalidWireInstruction {
            method: input.instruction.method.clone(),
        };
        return PrepareStep::Rejected(state, failure);
    }
    if !input.attempt.ordinal.is_zero() {
        let failure = NetworkFailure::RootAttemptRequired {
            attempt: input.attempt.clone(),
        };
        return PrepareStep::Rejected(state, failure);
    }
    if state.highest_ordinals.contains_key(&input.attempt.logical) {
        let failure = NetworkFailure::DuplicateAttempt {
            attempt: input.attempt.clone(),
        };
        return PrepareStep::Rejected(state, failure);
    }
    let prepared = PreparedAttempt {
        input: Arc::clone(&input),
        chain: AttemptChain::Root,
    };
    state.push_record(AttemptRecord {
        input,
        chain: AttemptChain::Root,
        disposition: AttemptDisposition::Prepared,
        first_delivery: None,
        late: Vec::new(),
    });
    PrepareStep::Prepared(state, prepared)
}

pub fn send_command(
    mut state: NetworkState,
    prepared: PreparedAttempt,
) -> CommandStep<SendCommand> {
    if command_issued_matches(&state, &prepared) {
        let failure = NetworkFailure::CommandAlreadyIssued {
            attempt: prepared.input.attempt.clone(),
        };
        return CommandStep::Rejected(state, failure);
    }
    if !prepared_ready(&state, &prepared) {
        let failure = prepared_condition_failure(&state, &prepared, AttemptCondition::IsPrepared)
            .unwrap_or_else(|| NetworkFailure::AttemptConditionMismatch {
                attempt: prepared.input.attempt.clone(),
                expected: AttemptCondition::IsPrepared,
                actual: AttemptCondition::IsPrepared,
            });
        return CommandStep::Rejected(state, failure);
    }
    if let Some(record) = state.record_mut(&prepared.input.attempt) {
        record.disposition = AttemptDisposition::CommandIssued;
    }
    CommandStep::CommandReady(state, SendCommand { prepared })
}

pub fn cancel_command(state: NetworkState, started: StartedAttempt) -> CommandStep<CancelCommand> {
    if !started_relation(&state, &started) {
        let failure = started_token_failure(&state, &started).unwrap_or_else(|| {
            NetworkFailure::AttemptConditionMismatch {
                attempt: started.prepared.input.attempt.clone(),
                expected: AttemptCondition::IsStarted,
                actual: AttemptCondition::IsStarted,
            }
        });
        return CommandStep::Rejected(state, failure);
    }
    let Some(capability) = started.prepared.input.configuration.cancellation.clone() else {
        let failure = NetworkFailure::RequiredCapabilityUnavailable {
            attempt: started.prepared.input.attempt.clone(),
            capability: CapabilityKind::Cancellation,
        };
        return CommandStep::Rejected(state, failure);
    };
    CommandStep::CommandReady(
        state,
        CancelCommand {
            attempt: started.prepared.input.attempt.clone(),
            handle: started.handle,
            capability,
        },
    )
}

fn start_observation_failure(
    state: &NetworkState,
    prepared: &PreparedAttempt,
    observation: &StartObservation,
) -> NetworkFailure {
    if let Some(failure) =
        prepared_condition_failure(state, prepared, AttemptCondition::IsCommandIssued)
    {
        return failure;
    }
    match observation {
        StartObservation::Started { attempt, .. } => NetworkFailure::IdentityMismatch {
            expected: prepared.input.attempt.clone(),
            actual: attempt.clone(),
        },
        StartObservation::StartFailed { failure, effect: _ } => {
            if failure.attempt != prepared.input.attempt {
                NetworkFailure::IdentityMismatch {
                    expected: prepared.input.attempt.clone(),
                    actual: failure.attempt.clone(),
                }
            } else if failure.stage != HostStage::Start {
                NetworkFailure::ObservationRelationMismatch {
                    attempt: prepared.input.attempt.clone(),
                    field: ObservationField::FailureStage,
                }
            } else if failure.configuration != prepared.input.configuration {
                NetworkFailure::ObservationRelationMismatch {
                    attempt: prepared.input.attempt.clone(),
                    field: ObservationField::FailureConfiguration,
                }
            } else {
                NetworkFailure::ObservationRelationMismatch {
                    attempt: prepared.input.attempt.clone(),
                    field: ObservationField::EffectWitnessValue,
                }
            }
        }
    }
}

pub fn observe_start(
    mut state: NetworkState,
    prepared: PreparedAttempt,
    observation: StartObservation,
) -> NetworkStep {
    if !start_observation_relation(&state, &prepared, &observation) {
        let failure = start_observation_failure(&state, &prepared, &observation);
        return NetworkStep::Rejected(state, failure);
    }
    match observation {
        StartObservation::Started { attempt, handle } => {
            if let Some(record) = state.record_mut(&attempt) {
                record.disposition = AttemptDisposition::Started {
                    handle: handle.clone(),
                };
            }
            NetworkStep::Started(state, StartedAttempt { prepared, handle })
        }
        StartObservation::StartFailed { failure, effect } => {
            let terminal = NetworkTerminal {
                outcome: NetworkOutcome::Failed { failure },
                effect,
            };
            if let Some(record) = state.record_mut(&prepared.input.attempt) {
                record.disposition = AttemptDisposition::Settled {
                    handle: None,
                    terminal: terminal.clone(),
                };
            }
            let settled = SettledAttempt {
                prepared,
                handle: None,
                terminal,
            };
            NetworkStep::Terminal(state, settled)
        }
    }
}

fn prepared_of(record: &AttemptRecord) -> PreparedAttempt {
    PreparedAttempt {
        input: Arc::clone(&record.input),
        chain: record.chain.clone(),
    }
}

fn delivered_failure(
    record: &AttemptRecord,
    delivery: &DeliveryOrdinal,
    observation: &AdapterObservation,
) -> Option<NetworkFailure> {
    let expected = expected_delivery(record);
    if delivery != &expected {
        return Some(NetworkFailure::DeliveryOrderViolation {
            attempt: attempt_of(observation).clone(),
            expected,
            actual: delivery.clone(),
        });
    }
    let actual = match &record.disposition {
        AttemptDisposition::Prepared => AttemptCondition::IsPrepared,
        AttemptDisposition::CommandIssued => AttemptCondition::IsCommandIssued,
        _ => return None,
    };
    Some(NetworkFailure::AttemptConditionMismatch {
        attempt: attempt_of(observation).clone(),
        expected: AttemptCondition::IsStarted,
        actual,
    })
}

fn observe_delivery(
    mut state: NetworkState,
    delivery: DeliveryOrdinal,
    observation: AdapterObservation,
) -> NetworkStep {
    let found = state
        .position(attempt_of(&observation))
        .and_then(|position| {
            state
                .attempts
                .get(position)
                .map(|record| (position, record))
        });
    let Some((position, record)) = found else {
        let attempt = attempt_of(&observation).clone();
        return NetworkStep::Rejected(state, NetworkFailure::UnknownAttempt { attempt });
    };
    if let Some(old) = recorded_delivery(record, &delivery) {
        let attempt = attempt_of(&observation).clone();
        if old == &observation {
            return NetworkStep::Duplicate(state, attempt, delivery);
        }
        let failure = NetworkFailure::ConflictingDelivery {
            attempt,
            delivery,
            old: old.clone(),
            fresh: observation,
        };
        return NetworkStep::Rejected(state, failure);
    }
    if let Some(failure) = delivered_failure(record, &delivery, &observation) {
        return NetworkStep::Rejected(state, failure);
    }
    let prepared = prepared_of(record);
    let Some(record) = state.attempts.get_mut(position) else {
        let attempt = attempt_of(&observation).clone();
        return NetworkStep::Rejected(state, NetworkFailure::UnknownAttempt { attempt });
    };
    match &record.disposition {
        AttemptDisposition::Started { handle } => {
            let handle = handle.clone();
            let terminal = terminal_of_observation(&observation);
            record.disposition = AttemptDisposition::Settled {
                handle: Some(handle.clone()),
                terminal: terminal.clone(),
            };
            record.first_delivery = Some(DeliveredObservation {
                delivery,
                observation,
            });
            record.late.clear();
            let settled = SettledAttempt {
                prepared,
                handle: Some(handle),
                terminal,
            };
            NetworkStep::Terminal(state, settled)
        }
        AttemptDisposition::Settled { handle, terminal } => {
            let settled = SettledAttempt {
                prepared,
                handle: handle.clone(),
                terminal: terminal.clone(),
            };
            let late = LateObservation {
                delivered: DeliveredObservation {
                    delivery,
                    observation,
                },
            };
            record.late.push(late.clone());
            NetworkStep::Late(state, settled, late)
        }
        AttemptDisposition::Prepared | AttemptDisposition::CommandIssued => {
            let attempt = attempt_of(&observation).clone();
            NetworkStep::Rejected(state, NetworkFailure::UnknownAttempt { attempt })
        }
    }
}

pub fn observe(state: NetworkState, observation: HostObservation) -> NetworkStep {
    if !host_observation_relation(&state, &observation) {
        let failure = host_observation_failure(&state, &observation);
        return NetworkStep::Rejected(state, failure);
    }
    match observation {
        HostObservation::Pending { attempt, handle } => {
            let Some(record) = lookup_attempt(&state, &attempt) else {
                return NetworkStep::Rejected(state, NetworkFailure::UnknownAttempt { attempt });
            };
            let prepared = prepared_of(record);
            NetworkStep::Pending(state, StartedAttempt { prepared, handle })
        }
        HostObservation::Delivered {
            delivery,
            observation,
        } => observe_delivery(state, delivery, observation),
    }
}

fn annotation_status_ok(current: &EffectStatus, requested: &EffectStatus) -> bool {
    match (current, requested) {
        (EffectStatus::Unknown { .. }, EffectStatus::NoEffect { .. })
        | (EffectStatus::Unknown { .. }, EffectStatus::EffectOccurred { .. }) => true,
        (EffectStatus::NoEffect { witness: old }, EffectStatus::NoEffect { witness: fresh })
        | (
            EffectStatus::EffectOccurred { witness: old },
            EffectStatus::EffectOccurred { witness: fresh },
        ) => old == fresh,
        _ => false,
    }
}

fn annotation_conflict(current: &EffectStatus, requested: &EffectStatus) -> bool {
    matches!(
        (current, requested),
        (
            EffectStatus::NoEffect { .. },
            EffectStatus::EffectOccurred { .. }
        ) | (
            EffectStatus::EffectOccurred { .. },
            EffectStatus::NoEffect { .. }
        )
    )
}

fn annotation_failure(
    state: &NetworkState,
    observation: &EffectObservation,
) -> Option<NetworkFailure> {
    let attempt = &observation.attempt;
    let Some(record) = lookup_attempt(state, attempt) else {
        return Some(NetworkFailure::UnknownAttempt {
            attempt: attempt.clone(),
        });
    };
    let AttemptDisposition::Settled { terminal, .. } = &record.disposition else {
        return Some(NetworkFailure::AttemptConditionMismatch {
            attempt: attempt.clone(),
            expected: AttemptCondition::IsSettled,
            actual: disposition_condition(&record.disposition),
        });
    };
    if !effect_matches(attempt, &observation.status) {
        return Some(NetworkFailure::EffectWitnessMissing {
            attempt: attempt.clone(),
        });
    }
    if annotation_status_ok(&terminal.effect, &observation.status) {
        None
    } else if annotation_conflict(&terminal.effect, &observation.status) {
        Some(NetworkFailure::EffectKnowledgeConflict {
            attempt: attempt.clone(),
        })
    } else {
        Some(NetworkFailure::EffectWitnessMissing {
            attempt: attempt.clone(),
        })
    }
}

pub fn annotate_effect(mut state: NetworkState, observation: EffectObservation) -> StateStep {
    if let Some(failure) = annotation_failure(&state, &observation) {
        return StateStep::Rejected(state, failure);
    }
    if let Some(record) = state.record_mut(&observation.attempt) {
        if let AttemptDisposition::Settled { terminal, .. } = &mut record.disposition {
            terminal.effect = observation.status;
        }
    }
    StateStep::Applied(state)
}

fn retry_failure_key(permission: &RetryPermission) -> AttemptIdentity {
    match permission {
        RetryPermission::RetryAllowed { authorization } => authorization.from.clone(),
        RetryPermission::RetryDenied { parent, .. } => parent.clone(),
    }
}

fn retry_acceptable(
    state: &NetworkState,
    request: &RetryRequest,
    authorization: &RetryAuthorization,
) -> bool {
    attempt_input_ok(
        &request.instruction,
        request.deadline.as_ref(),
        &request.configuration,
    ) && authorization.logical == authorization.from.logical
        && authorization.logical == authorization.next.logical
        && authorization.from.ordinal.successor() == authorization.next.ordinal
        && lookup_attempt(state, &authorization.from).is_some_and(|parent| {
            matches!(parent.disposition, AttemptDisposition::Settled { .. })
                && !state.later_attempt_exists(&authorization.from)
        })
        && lookup_attempt(state, &authorization.next).is_none()
        && !state.authorization_used(authorization)
}

pub fn retry(mut state: NetworkState, request: RetryRequest) -> PrepareStep {
    let authorization = match &request.permission {
        RetryPermission::RetryAllowed { authorization }
            if retry_acceptable(&state, &request, authorization) =>
        {
            authorization.clone()
        }
        permission => {
            let failure = NetworkFailure::RetryNotPermitted {
                attempt: retry_failure_key(permission),
            };
            return PrepareStep::Rejected(state, failure);
        }
    };
    let input = Arc::new(AttemptInput {
        attempt: authorization.next.clone(),
        instruction: request.instruction,
        deadline: request.deadline,
        configuration: request.configuration,
    });
    let chain = AttemptChain::RetryOf { authorization };
    let prepared = PreparedAttempt {
        input: Arc::clone(&input),
        chain: chain.clone(),
    };
    state.push_record(AttemptRecord {
        input,
        chain,
        disposition: AttemptDisposition::Prepared,
        first_delivery: None,
        late: Vec::new(),
    });
    PrepareStep::Prepared(state, prepared)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostRecordObservation {
    Undelivered,
    DeliveryOrdinal,
}

pub fn host_awaits(state: &NetworkState, key: &AttemptIdentity) -> bool {
    match lookup_attempt(state, key) {
        Some(record) => !matches!(record.disposition, AttemptDisposition::Settled { .. }),
        None => false,
    }
}

pub fn host_settled(state: &NetworkState, key: &AttemptIdentity) -> bool {
    match lookup_attempt(state, key) {
        Some(record) => matches!(record.disposition, AttemptDisposition::Settled { .. }),
        None => false,
    }
}

pub fn release_host_record<F: Fn(&AttemptIdentity) -> bool>(
    state: &NetworkState,
    running: F,
    key: &AttemptIdentity,
) -> ErasureDecision<AttemptIdentity, (), (), (), HostRecordObservation> {
    let request = ErasureRequest {
        target: key.clone(),
        target_basis: None,
        removed_observations: vec![
            HostRecordObservation::Undelivered,
            HostRecordObservation::DeliveryOrdinal,
        ],
        preserved_observations: Vec::new(),
    };
    let membership = LiveFns {
        active_basis: |_: &()| false,
        branch_root: |_: &AttemptIdentity| false,
        future_use: |target: &AttemptIdentity| host_awaits(state, target),
        outstanding_effect: |target: &AttemptIdentity| running(target),
        outstanding_signal: |_: &AttemptIdentity| false,
    };
    judge_erasure_by(
        request,
        &membership,
        Some(Recoverability::<(), ()>::Irrecoverable),
    )
}
