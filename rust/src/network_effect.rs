// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::core::Nat;
use crate::request_progression::{ExecutionHandle, RequestIdentity};
use num_traits::{ToPrimitive, Zero};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::str::FromStr;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Natural(pub Nat);

impl Natural {
    fn successor(&self) -> Self {
        Self(&self.0 + 1u8)
    }

    pub fn to_u64(&self) -> Option<u64> {
        self.0.to_u64()
    }

    pub fn to_u8(&self) -> Option<u8> {
        self.0.to_u8()
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

pub type ByteString = Vec<Natural>;
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
            value: Codec::deserialize(deserializer)?.value,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptIdentity {
    pub logical: RequestIdentity,
    pub ordinal: Natural,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryAuthorization {
    pub logical: RequestIdentity,
    pub from: AttemptIdentity,
    pub next: AttemptIdentity,
    pub protocol_evidence: OpaqueEvidence,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag")]
pub enum AttemptLineage {
    Root,
    RetryOf { authorization: RetryAuthorization },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreparedAttempt {
    pub input: AttemptInput,
    pub lineage: AttemptLineage,
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
    pub input: AttemptInput,
    pub lineage: AttemptLineage,
    pub disposition: AttemptDisposition,
    pub first_delivery: Option<DeliveredObservation>,
    pub late: Vec<LateObservation>,
}

#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct NetworkState {
    pub attempts: Vec<AttemptRecord>,
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
    LineageMismatch { attempt: AttemptIdentity },
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
    Lineage,
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

fn byte_ok(value: &Natural) -> bool {
    value.0 <= Nat::from(255u16)
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

fn alpha_char_ok(value: char) -> bool {
    value.is_ascii_alphabetic()
}

fn digit_char_ok(value: char) -> bool {
    value.is_ascii_digit()
}

fn hex_char_ok(value: char) -> bool {
    value.is_ascii_hexdigit()
}

fn uri_unreserved_ok(value: char) -> bool {
    alpha_char_ok(value) || digit_char_ok(value) || matches!(value, '-' | '.' | '_' | '~')
}

fn uri_sub_delim_ok(value: char) -> bool {
    matches!(
        value,
        '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '='
    )
}

fn uri_pchar_ok(value: char) -> bool {
    uri_unreserved_ok(value) || uri_sub_delim_ok(value) || matches!(value, ':' | '@')
}

fn percent_encoded_ok(value: &[char], index: usize) -> bool {
    match (value.get(index + 1), value.get(index + 2)) {
        (Some(high), Some(low)) => hex_char_ok(*high) && hex_char_ok(*low),
        _ => false,
    }
}

fn uri_component_ok(allow_question: bool, value: &[char]) -> bool {
    let mut index = 0;
    while let Some(character) = value.get(index).copied() {
        if character == '%' {
            if !percent_encoded_ok(value, index) {
                return false;
            }
            index += 3;
            continue;
        }
        if !(uri_pchar_ok(character) || character == '/' || (allow_question && character == '?')) {
            return false;
        }
        index += 1;
    }
    true
}

fn split_at_char(value: &[char], delimiter: char) -> (&[char], Option<&[char]>) {
    match value.iter().position(|candidate| *candidate == delimiter) {
        Some(index) => {
            let (head, tail) = value.split_at(index);
            (head, Some(tail.get(1..).unwrap_or_default()))
        }
        None => (value, None),
    }
}

fn uri_reg_name_ok(value: &[char]) -> bool {
    let mut index = 0;
    while let Some(character) = value.get(index).copied() {
        if character == '%' {
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

fn uri_user_info_ok(value: &[char]) -> bool {
    let mut index = 0;
    while let Some(character) = value.get(index).copied() {
        if character == '%' {
            if !percent_encoded_ok(value, index) {
                return false;
            }
            index += 3;
        } else if uri_unreserved_ok(character) || uri_sub_delim_ok(character) || character == ':' {
            index += 1;
        } else {
            return false;
        }
    }
    true
}

fn uri_port_ok(value: &[char]) -> bool {
    value.iter().all(|character| digit_char_ok(*character))
}

fn uri_ip_literal_ok(value: &[char]) -> bool {
    !value.is_empty()
        && value.iter().any(|character| matches!(character, ':' | '.'))
        && value.iter().all(|character| {
            hex_char_ok(*character)
                || matches!(character, ':' | '.' | 'v' | 'V')
                || uri_unreserved_ok(*character)
                || uri_sub_delim_ok(*character)
        })
}

fn uri_port_suffix_ok(value: &[char]) -> bool {
    match value.split_first() {
        None => true,
        Some((':', port)) => uri_port_ok(port),
        Some(_) => false,
    }
}

fn uri_host_port_ok(value: &[char]) -> bool {
    if let Some(('[', rest)) = value.split_first() {
        let Some(end) = rest.iter().position(|character| *character == ']') else {
            return false;
        };
        let (literal, after) = rest.split_at(end);
        let Some(port_suffix) = after.get(1..) else {
            return false;
        };
        return uri_ip_literal_ok(literal) && uri_port_suffix_ok(port_suffix);
    }
    let (host, port) = split_at_char(value, ':');
    uri_reg_name_ok(host) && port.is_none_or(uri_port_ok)
}

fn authority_ok(value: &[char]) -> bool {
    let (userinfo, host_port) = split_at_char(value, '@');
    match host_port {
        None => uri_host_port_ok(userinfo),
        Some(host_port) => {
            !host_port.contains(&'@') && uri_user_info_ok(userinfo) && uri_host_port_ok(host_port)
        }
    }
}

fn uri_hier_part_ok(value: &[char]) -> bool {
    if let Some(rest) = value.strip_prefix(&['/', '/']) {
        let authority_length = rest
            .iter()
            .position(|character| *character == '/')
            .unwrap_or(rest.len());
        let (authority, path) = rest.split_at(authority_length);
        authority_ok(authority) && uri_component_ok(false, path)
    } else {
        uri_component_ok(false, value)
    }
}

fn uri_tail_ok(value: &[char]) -> bool {
    let (before_fragment, fragment) = split_at_char(value, '#');
    let (path, query) = split_at_char(before_fragment, '?');
    uri_hier_part_ok(path)
        && query.is_none_or(|part| uri_component_ok(true, part))
        && fragment.is_none_or(|part| uri_component_ok(true, part))
}

fn target_ok(target: &str) -> bool {
    let characters: Vec<char> = target.chars().collect();
    let Some((first, rest)) = characters.split_first() else {
        return false;
    };
    let first = *first;
    let scheme_length = rest
        .iter()
        .position(|character| *character == ':')
        .unwrap_or(rest.len());
    if scheme_length == rest.len() {
        return false;
    }
    let (scheme, after) = rest.split_at(scheme_length);
    let Some(tail) = after.get(1..) else {
        return false;
    };
    alpha_char_ok(first)
        && scheme.iter().all(|character| {
            alpha_char_ok(*character)
                || digit_char_ok(*character)
                || matches!(character, '+' | '-' | '.')
        })
        && uri_tail_ok(tail)
}

fn headers_ok(headers: &[RawHeaderField]) -> bool {
    headers
        .iter()
        .all(|header| token_ok(&header.name) && header.value.iter().all(byte_ok))
}

fn instruction_ok(instruction: &HttpWireInstruction) -> bool {
    token_ok(&instruction.method)
        && target_ok(&instruction.target)
        && headers_ok(&instruction.headers)
        && instruction.body.iter().all(byte_ok)
}

fn response_ok(response: &RawHttpResponse) -> bool {
    response.status.0 >= Nat::from(100u16)
        && response.status.0 <= Nat::from(999u16)
        && headers_ok(&response.headers)
        && response.body.iter().all(byte_ok)
}

pub fn valid_attempt_input(input: &AttemptInput) -> bool {
    instruction_ok(&input.instruction)
        && Natural::from(input.instruction.body.len()) <= input.configuration.request_body_limit
        && input.deadline.as_ref().is_none_or(|deadline| {
            deadline.capability.clock_basis == deadline.clock_basis
                && input.configuration.monotonic_clock.as_ref() == Some(&deadline.capability)
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
            && record.lineage == AttemptLineage::Root
    })
}

fn settled_key(records: &[AttemptRecord], attempt: &AttemptIdentity) -> bool {
    records.iter().any(|record| {
        &record.input.attempt == attempt
            && matches!(record.disposition, AttemptDisposition::Settled { .. })
    })
}

fn lineage_ok(records: &[AttemptRecord], record: &AttemptRecord) -> bool {
    root_for_logical(records, &record.input.attempt.logical)
        && match &record.lineage {
            AttemptLineage::Root => record.input.attempt.ordinal.is_zero(),
            AttemptLineage::RetryOf { authorization } => {
                authorization.logical == record.input.attempt.logical
                    && authorization.from.logical == record.input.attempt.logical
                    && authorization.next == record.input.attempt
                    && authorization.from.ordinal.successor() == authorization.next.ordinal
                    && settled_key(records, &authorization.from)
            }
        }
}

fn authorization_unique(records: &[AttemptRecord]) -> bool {
    records.iter().enumerate().all(|(index, record)| match &record.lineage {
        AttemptLineage::Root => true,
        AttemptLineage::RetryOf { authorization } => records.iter().skip(index + 1).all(|candidate| {
            !matches!(&candidate.lineage, AttemptLineage::RetryOf { authorization: other } if other == authorization)
        }),
    })
}

pub fn valid_state(state: &NetworkState) -> bool {
    state.attempts.iter().enumerate().all(|(index, record)| {
        !state
            .attempts
            .iter()
            .skip(index + 1)
            .any(|candidate| candidate.input.attempt == record.input.attempt)
            && record_evidence_ok(record)
            && lineage_ok(&state.attempts, record)
    }) && authorization_unique(&state.attempts)
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

fn lineage_violation(
    records: &[AttemptRecord],
    record: &AttemptRecord,
) -> Option<NetworkStateViolation> {
    if lineage_ok(records, record) {
        return None;
    }
    if !root_for_logical(records, &record.input.attempt.logical) {
        return Some(NetworkStateViolation::NonRootFirstAttempt {
            attempt: record.input.attempt.clone(),
        });
    }
    match &record.lineage {
        AttemptLineage::Root => Some(NetworkStateViolation::NonRootFirstAttempt {
            attempt: record.input.attempt.clone(),
        }),
        AttemptLineage::RetryOf { authorization } => {
            if authorization.next.ordinal != authorization.from.ordinal.successor() {
                Some(NetworkStateViolation::OrdinalGap {
                    attempt: record.input.attempt.clone(),
                })
            } else {
                Some(NetworkStateViolation::LineageMismatch {
                    attempt: record.input.attempt.clone(),
                })
            }
        }
    }
}

fn first_lineage_violation(records: &[AttemptRecord]) -> Option<NetworkStateViolation> {
    records
        .iter()
        .find_map(|record| lineage_violation(records, record))
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
        let AttemptLineage::RetryOf { authorization } = &record.lineage else {
            return None;
        };
        records
            .iter()
            .skip(index + 1)
            .any(|candidate| {
                matches!(
                    &candidate.lineage,
                    AttemptLineage::RetryOf {
                        authorization: other
                    } if other == authorization
                )
            })
            .then(|| NetworkStateViolation::RetryAuthorizationReuse {
                authorization: authorization.clone(),
            })
    })
}

fn state_violation(state: &NetworkState) -> NetworkStateViolation {
    first_duplicate_violation(&state.attempts)
        .or_else(|| first_record_violation(&state.attempts))
        .or_else(|| first_lineage_violation(&state.attempts))
        .or_else(|| first_root_violation(&state.attempts))
        .or_else(|| first_authorization_violation(&state.attempts))
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
        .attempts
        .iter()
        .find(|record| &record.input.attempt == attempt)
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
    } else if record.lineage != prepared.lineage {
        Some(NetworkFailure::AttemptTokenMismatch {
            attempt: prepared.input.attempt.clone(),
            field: AttemptTokenField::Lineage,
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
    valid_state(state)
        && lookup_attempt(state, &prepared.input.attempt).is_some_and(|record| {
            record.input == prepared.input && record.lineage == prepared.lineage
        })
}

fn prepared_ready(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    prepared_relation(state, prepared)
        && lookup_attempt(state, &prepared.input.attempt)
            .is_some_and(|record| record.disposition == AttemptDisposition::Prepared)
}

fn command_issued_matches(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    state.attempts.iter().any(|record| {
        record.input == prepared.input
            && record.lineage == prepared.lineage
            && record.disposition == AttemptDisposition::CommandIssued
    })
}

fn command_issued_relation(state: &NetworkState, prepared: &PreparedAttempt) -> bool {
    prepared_relation(state, prepared)
        && lookup_attempt(state, &prepared.input.attempt)
            .is_some_and(|record| record.disposition == AttemptDisposition::CommandIssued)
}

fn started_relation(state: &NetworkState, started: &StartedAttempt) -> bool {
    valid_state(state)
        && lookup_attempt(state, &started.prepared.input.attempt).is_some_and(|record| {
            record.input == started.prepared.input
                && record.lineage == started.prepared.lineage
                && record.disposition
                    == AttemptDisposition::Started {
                        handle: started.handle.clone(),
                    }
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
    valid_state(state)
        && lookup_attempt(state, attempt_of(observation)).is_some_and(|record| {
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
            valid_state(state)
                && lookup_attempt(state, attempt).is_some_and(|record| {
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

trait FromReject {
    fn rejected(state: NetworkState, failure: NetworkFailure) -> Self;
}

impl FromReject for ReadStateStep {
    fn rejected(state: NetworkState, failure: NetworkFailure) -> Self {
        Self::Rejected(state, failure)
    }
}
impl FromReject for PrepareStep {
    fn rejected(state: NetworkState, failure: NetworkFailure) -> Self {
        Self::Rejected(state, failure)
    }
}
impl<T> FromReject for CommandStep<T> {
    fn rejected(state: NetworkState, failure: NetworkFailure) -> Self {
        Self::Rejected(state, failure)
    }
}
impl FromReject for StateStep {
    fn rejected(state: NetworkState, failure: NetworkFailure) -> Self {
        Self::Rejected(state, failure)
    }
}
impl FromReject for NetworkStep {
    fn rejected(state: NetworkState, failure: NetworkFailure) -> Self {
        Self::Rejected(state, failure)
    }
}

fn reject<T: FromReject>(state: &NetworkState, failure: NetworkFailure) -> T {
    T::rejected(state.clone(), failure)
}

pub fn read_network_state(state: NetworkState) -> ReadStateStep {
    if valid_state(&state) {
        ReadStateStep::Read(state)
    } else {
        let violation = state_violation(&state);
        ReadStateStep::Rejected(state, NetworkFailure::InvalidNetworkState { violation })
    }
}

pub fn prepare(state: NetworkState, input: AttemptInput) -> PrepareStep {
    if !valid_state(&state) {
        return reject(
            &state,
            NetworkFailure::InvalidNetworkState {
                violation: state_violation(&state),
            },
        );
    }
    if !valid_attempt_input(&input) {
        return reject(
            &state,
            NetworkFailure::InvalidWireInstruction {
                method: input.instruction.method,
            },
        );
    }
    if !input.attempt.ordinal.is_zero() {
        return reject(
            &state,
            NetworkFailure::RootAttemptRequired {
                attempt: input.attempt,
            },
        );
    }
    if state
        .attempts
        .iter()
        .any(|record| record.input.attempt.logical == input.attempt.logical)
    {
        return reject(
            &state,
            NetworkFailure::DuplicateAttempt {
                attempt: input.attempt,
            },
        );
    }
    let prepared = PreparedAttempt {
        input: input.clone(),
        lineage: AttemptLineage::Root,
    };
    let mut next = state.clone();
    next.attempts.push(AttemptRecord {
        input,
        lineage: AttemptLineage::Root,
        disposition: AttemptDisposition::Prepared,
        first_delivery: None,
        late: Vec::new(),
    });
    if valid_state(&next) && prepared_relation(&next, &prepared) {
        PrepareStep::Prepared(next, prepared)
    } else {
        reject(
            &state,
            NetworkFailure::InvalidNetworkState {
                violation: state_violation(&next),
            },
        )
    }
}

pub fn send_command(state: NetworkState, prepared: PreparedAttempt) -> CommandStep<SendCommand> {
    if command_issued_matches(&state, &prepared) {
        return reject(
            &state,
            NetworkFailure::CommandAlreadyIssued {
                attempt: prepared.input.attempt.clone(),
            },
        );
    }
    if !prepared_ready(&state, &prepared) {
        if !valid_state(&state) {
            return reject(
                &state,
                NetworkFailure::InvalidNetworkState {
                    violation: state_violation(&state),
                },
            );
        }
        let failure = prepared_condition_failure(&state, &prepared, AttemptCondition::IsPrepared)
            .unwrap_or_else(|| NetworkFailure::AttemptConditionMismatch {
                attempt: prepared.input.attempt.clone(),
                expected: AttemptCondition::IsPrepared,
                actual: AttemptCondition::IsPrepared,
            });
        return reject(&state, failure);
    }
    let mut next = state.clone();
    if let Some(record) = next
        .attempts
        .iter_mut()
        .find(|record| record.input.attempt == prepared.input.attempt)
    {
        record.disposition = AttemptDisposition::CommandIssued;
    }
    if !valid_state(&next) {
        return reject(
            &state,
            NetworkFailure::InvalidNetworkState {
                violation: state_violation(&next),
            },
        );
    }
    CommandStep::CommandReady(next, SendCommand { prepared })
}

pub fn cancel_command(state: NetworkState, started: StartedAttempt) -> CommandStep<CancelCommand> {
    if !started_relation(&state, &started) {
        if !valid_state(&state) {
            return reject(
                &state,
                NetworkFailure::InvalidNetworkState {
                    violation: state_violation(&state),
                },
            );
        }
        let failure = started_token_failure(&state, &started).unwrap_or_else(|| {
            NetworkFailure::AttemptConditionMismatch {
                attempt: started.prepared.input.attempt.clone(),
                expected: AttemptCondition::IsStarted,
                actual: AttemptCondition::IsStarted,
            }
        });
        return reject(&state, failure);
    }
    let Some(capability) = started.prepared.input.configuration.cancellation.clone() else {
        return reject(
            &state,
            NetworkFailure::RequiredCapabilityUnavailable {
                attempt: started.prepared.input.attempt,
                capability: CapabilityKind::Cancellation,
            },
        );
    };
    CommandStep::CommandReady(
        state,
        CancelCommand {
            attempt: started.prepared.input.attempt,
            handle: started.handle,
            capability,
        },
    )
}

pub fn observe_start(
    state: NetworkState,
    prepared: PreparedAttempt,
    observation: StartObservation,
) -> NetworkStep {
    if !start_observation_relation(&state, &prepared, &observation) {
        if !valid_state(&state) {
            return reject(
                &state,
                NetworkFailure::InvalidNetworkState {
                    violation: state_violation(&state),
                },
            );
        }
        if let Some(failure) =
            prepared_condition_failure(&state, &prepared, AttemptCondition::IsCommandIssued)
        {
            return reject(&state, failure);
        }
        let failure = match &observation {
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
        };
        return reject(&state, failure);
    }
    match observation {
        StartObservation::Started { attempt, handle } => {
            let started = StartedAttempt {
                prepared: prepared.clone(),
                handle: handle.clone(),
            };
            let mut next = state.clone();
            if let Some(record) = next
                .attempts
                .iter_mut()
                .find(|record| record.input.attempt == attempt)
            {
                record.disposition = AttemptDisposition::Started { handle };
            }
            if valid_state(&next) && started_relation(&next, &started) {
                NetworkStep::Started(next, started)
            } else {
                reject(
                    &state,
                    NetworkFailure::InvalidNetworkState {
                        violation: state_violation(&next),
                    },
                )
            }
        }
        StartObservation::StartFailed { failure, effect } => {
            let terminal = NetworkTerminal {
                outcome: NetworkOutcome::Failed { failure },
                effect,
            };
            let settled = SettledAttempt {
                prepared: prepared.clone(),
                handle: None,
                terminal: terminal.clone(),
            };
            let mut next = state.clone();
            if let Some(record) = next
                .attempts
                .iter_mut()
                .find(|record| record.input.attempt == prepared.input.attempt)
            {
                record.disposition = AttemptDisposition::Settled {
                    handle: None,
                    terminal,
                };
            }
            if valid_state(&next) {
                NetworkStep::Terminal(next, settled)
            } else {
                reject(
                    &state,
                    NetworkFailure::InvalidNetworkState {
                        violation: state_violation(&next),
                    },
                )
            }
        }
    }
}

pub fn observe(state: NetworkState, observation: HostObservation) -> NetworkStep {
    if !host_observation_relation(&state, &observation) {
        if !valid_state(&state) {
            return reject(
                &state,
                NetworkFailure::InvalidNetworkState {
                    violation: state_violation(&state),
                },
            );
        }
        let failure = host_observation_failure(&state, &observation);
        return reject(&state, failure);
    }
    match observation {
        HostObservation::Pending { attempt, handle } => {
            let Some(record) = lookup_attempt(&state, &attempt) else {
                return reject(&state, NetworkFailure::UnknownAttempt { attempt });
            };
            NetworkStep::Pending(
                state.clone(),
                StartedAttempt {
                    prepared: PreparedAttempt {
                        input: record.input.clone(),
                        lineage: record.lineage.clone(),
                    },
                    handle,
                },
            )
        }
        HostObservation::Delivered {
            delivery,
            observation,
        } => {
            let attempt = attempt_of(&observation).clone();
            let Some(record) = lookup_attempt(&state, &attempt).cloned() else {
                return reject(&state, NetworkFailure::UnknownAttempt { attempt });
            };
            if let Some(old) = recorded_delivery(&record, &delivery) {
                return if old == &observation {
                    NetworkStep::Duplicate(state, attempt, delivery)
                } else {
                    reject(
                        &state,
                        NetworkFailure::ConflictingDelivery {
                            attempt,
                            delivery,
                            old: old.clone(),
                            fresh: observation,
                        },
                    )
                };
            }
            let expected = expected_delivery(&record);
            if delivery != expected {
                return reject(
                    &state,
                    NetworkFailure::DeliveryOrderViolation {
                        attempt,
                        expected,
                        actual: delivery,
                    },
                );
            }
            match &record.disposition {
                AttemptDisposition::Started { handle } => {
                    let terminal = terminal_of_observation(&observation);
                    let first = DeliveredObservation {
                        delivery,
                        observation,
                    };
                    let settled = SettledAttempt {
                        prepared: PreparedAttempt {
                            input: record.input.clone(),
                            lineage: record.lineage.clone(),
                        },
                        handle: Some(handle.clone()),
                        terminal: terminal.clone(),
                    };
                    let mut next = state.clone();
                    if let Some(updated) = next
                        .attempts
                        .iter_mut()
                        .find(|candidate| candidate.input.attempt == attempt)
                    {
                        updated.disposition = AttemptDisposition::Settled {
                            handle: Some(handle.clone()),
                            terminal,
                        };
                        updated.first_delivery = Some(first);
                        updated.late.clear();
                    }
                    if valid_state(&next) {
                        NetworkStep::Terminal(next, settled)
                    } else {
                        reject(
                            &state,
                            NetworkFailure::InvalidNetworkState {
                                violation: state_violation(&next),
                            },
                        )
                    }
                }
                AttemptDisposition::Settled { handle, terminal } => {
                    let late = LateObservation {
                        delivered: DeliveredObservation {
                            delivery,
                            observation,
                        },
                    };
                    let settled = SettledAttempt {
                        prepared: PreparedAttempt {
                            input: record.input.clone(),
                            lineage: record.lineage.clone(),
                        },
                        handle: handle.clone(),
                        terminal: terminal.clone(),
                    };
                    let mut next = state.clone();
                    if let Some(updated) = next
                        .attempts
                        .iter_mut()
                        .find(|candidate| candidate.input.attempt == attempt)
                    {
                        updated.late.push(late.clone());
                    }
                    if valid_state(&next) {
                        NetworkStep::Late(next, settled, late)
                    } else {
                        reject(
                            &state,
                            NetworkFailure::InvalidNetworkState {
                                violation: state_violation(&next),
                            },
                        )
                    }
                }
                AttemptDisposition::Prepared => reject(
                    &state,
                    NetworkFailure::AttemptConditionMismatch {
                        attempt,
                        expected: AttemptCondition::IsStarted,
                        actual: AttemptCondition::IsPrepared,
                    },
                ),
                AttemptDisposition::CommandIssued => reject(
                    &state,
                    NetworkFailure::AttemptConditionMismatch {
                        attempt,
                        expected: AttemptCondition::IsStarted,
                        actual: AttemptCondition::IsCommandIssued,
                    },
                ),
            }
        }
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

pub fn annotate_effect(state: NetworkState, observation: EffectObservation) -> StateStep {
    if !valid_state(&state) {
        return reject(
            &state,
            NetworkFailure::InvalidNetworkState {
                violation: state_violation(&state),
            },
        );
    }
    let Some(record) = lookup_attempt(&state, &observation.attempt).cloned() else {
        return reject(
            &state,
            NetworkFailure::UnknownAttempt {
                attempt: observation.attempt,
            },
        );
    };
    let AttemptDisposition::Settled { handle, terminal } = record.disposition else {
        return reject(
            &state,
            NetworkFailure::AttemptConditionMismatch {
                attempt: observation.attempt,
                expected: AttemptCondition::IsSettled,
                actual: disposition_condition(&record.disposition),
            },
        );
    };
    if !effect_matches(&observation.attempt, &observation.status) {
        return reject(
            &state,
            NetworkFailure::EffectWitnessMissing {
                attempt: observation.attempt,
            },
        );
    }
    if !annotation_status_ok(&terminal.effect, &observation.status) {
        return if annotation_conflict(&terminal.effect, &observation.status) {
            reject(
                &state,
                NetworkFailure::EffectKnowledgeConflict {
                    attempt: observation.attempt,
                },
            )
        } else {
            reject(
                &state,
                NetworkFailure::EffectWitnessMissing {
                    attempt: observation.attempt,
                },
            )
        };
    }
    let mut next = state.clone();
    if let Some(record) = next
        .attempts
        .iter_mut()
        .find(|record| record.input.attempt == observation.attempt)
    {
        record.disposition = AttemptDisposition::Settled {
            handle,
            terminal: NetworkTerminal {
                outcome: terminal.outcome,
                effect: observation.status,
            },
        };
    }
    if valid_state(&next) {
        StateStep::Applied(next)
    } else {
        reject(
            &state,
            NetworkFailure::InvalidNetworkState {
                violation: state_violation(&next),
            },
        )
    }
}

fn retry_failure_key(permission: &RetryPermission) -> AttemptIdentity {
    match permission {
        RetryPermission::RetryAllowed { authorization } => authorization.from.clone(),
        RetryPermission::RetryDenied { parent, .. } => parent.clone(),
    }
}

fn retry_acceptable(state: &NetworkState, request: &RetryRequest) -> bool {
    let RetryPermission::RetryAllowed { authorization } = &request.permission else {
        return false;
    };
    let input = AttemptInput {
        attempt: authorization.next.clone(),
        instruction: request.instruction.clone(),
        deadline: request.deadline.clone(),
        configuration: request.configuration.clone(),
    };
    valid_state(state)
        && valid_attempt_input(&input)
        && authorization.logical == authorization.from.logical
        && authorization.logical == authorization.next.logical
        && authorization.from.ordinal.successor() == authorization.next.ordinal
        && lookup_attempt(state, &authorization.from).is_some_and(|parent| {
            matches!(parent.disposition, AttemptDisposition::Settled { .. })
                && !state.attempts.iter().any(|candidate| {
                    candidate.input.attempt.logical == authorization.from.logical
                        && candidate.input.attempt.ordinal > authorization.from.ordinal
                })
        })
        && lookup_attempt(state, &authorization.next).is_none()
        && state.attempts.iter().all(|record| {
            !matches!(&record.lineage, AttemptLineage::RetryOf { authorization: used } if used == authorization)
        })
}

pub fn retry(state: NetworkState, request: RetryRequest) -> PrepareStep {
    if !retry_acceptable(&state, &request) {
        return reject(
            &state,
            NetworkFailure::RetryNotPermitted {
                attempt: retry_failure_key(&request.permission),
            },
        );
    }
    let authorization = match request.permission {
        RetryPermission::RetryAllowed { authorization } => authorization,
        RetryPermission::RetryDenied { parent, .. } => {
            return reject(
                &state,
                NetworkFailure::RetryNotPermitted { attempt: parent },
            );
        }
    };
    let input = AttemptInput {
        attempt: authorization.next.clone(),
        instruction: request.instruction,
        deadline: request.deadline,
        configuration: request.configuration,
    };
    let lineage = AttemptLineage::RetryOf {
        authorization: authorization.clone(),
    };
    let prepared = PreparedAttempt {
        input: input.clone(),
        lineage: lineage.clone(),
    };
    let mut next = state.clone();
    next.attempts.push(AttemptRecord {
        input,
        lineage,
        disposition: AttemptDisposition::Prepared,
        first_delivery: None,
        late: Vec::new(),
    });
    if valid_state(&next) && prepared_relation(&next, &prepared) {
        PrepareStep::Prepared(next, prepared)
    } else {
        reject(
            &state,
            NetworkFailure::InvalidNetworkState {
                violation: state_violation(&next),
            },
        )
    }
}
