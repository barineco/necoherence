// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

pub use crate::exact_json::JsonValue;
use crate::exact_json_view::JsonValueView;
use crate::semantic_prepared_validation::PreparedMetadata;
use crate::semantic_types::{
    BranchSelector, BytesAlphabet, BytesPolicy, MemberTest, TypeRef, VersionedSemanticProfile,
    Wrapper,
};
use crate::semantic_validation::{
    base64_decode, base64_length, recognize_prepared_format, select_union_branch_index,
    FormatWorkspace,
};
pub use num_bigint::{BigInt, BigUint};
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Nullable<T> {
    Null,
    Value(T),
}
#[derive(Debug)]
pub enum RuntimeFailure {
    Json(String),
    Representation(String),
    BranchSelection,
    UndefinedType(TypeRef),
    Validation(crate::semantic_validation::ValidationFailure),
    Defaults(crate::semantic_validation::DefaultFailure),
}
impl fmt::Display for RuntimeFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RuntimeFailure {}

pub enum RuntimeFailureView<'a> {
    Json(std::borrow::Cow<'a, str>),
    Representation(std::borrow::Cow<'a, str>),
    BranchSelection,
    UndefinedType(std::borrow::Cow<'a, crate::semantic_types::TypeRef>),
    Validation(std::borrow::Cow<'a, crate::semantic_validation::ValidationFailure>),
    Defaults(std::borrow::Cow<'a, crate::semantic_validation::DefaultFailure>),
}
impl<'a> From<RuntimeFailure> for RuntimeFailureView<'a> {
    fn from(cause: RuntimeFailure) -> Self {
        match cause {
            RuntimeFailure::Json(text) => RuntimeFailureView::Json(std::borrow::Cow::Owned(text)),
            RuntimeFailure::Representation(text) => {
                RuntimeFailureView::Representation(std::borrow::Cow::Owned(text))
            }
            RuntimeFailure::BranchSelection => RuntimeFailureView::BranchSelection,
            RuntimeFailure::UndefinedType(reference) => {
                RuntimeFailureView::UndefinedType(std::borrow::Cow::Owned(reference))
            }
            RuntimeFailure::Validation(failure) => {
                RuntimeFailureView::Validation(std::borrow::Cow::Owned(failure))
            }
            RuntimeFailure::Defaults(failure) => {
                RuntimeFailureView::Defaults(std::borrow::Cow::Owned(failure))
            }
        }
    }
}
impl<'a> From<&'a RuntimeFailure> for RuntimeFailureView<'a> {
    fn from(cause: &'a RuntimeFailure) -> Self {
        match cause {
            RuntimeFailure::Json(text) => {
                RuntimeFailureView::Json(std::borrow::Cow::Borrowed(text))
            }
            RuntimeFailure::Representation(text) => {
                RuntimeFailureView::Representation(std::borrow::Cow::Borrowed(text))
            }
            RuntimeFailure::BranchSelection => RuntimeFailureView::BranchSelection,
            RuntimeFailure::UndefinedType(reference) => {
                RuntimeFailureView::UndefinedType(std::borrow::Cow::Borrowed(reference))
            }
            RuntimeFailure::Validation(failure) => {
                RuntimeFailureView::Validation(std::borrow::Cow::Borrowed(failure))
            }
            RuntimeFailure::Defaults(failure) => {
                RuntimeFailureView::Defaults(std::borrow::Cow::Borrowed(failure))
            }
        }
    }
}
impl RuntimeFailureView<'_> {
    pub fn into_owned(self) -> RuntimeFailure {
        match self {
            RuntimeFailureView::Json(text) => RuntimeFailure::Json(text.into_owned()),
            RuntimeFailureView::Representation(text) => {
                RuntimeFailure::Representation(text.into_owned())
            }
            RuntimeFailureView::BranchSelection => RuntimeFailure::BranchSelection,
            RuntimeFailureView::UndefinedType(reference) => {
                RuntimeFailure::UndefinedType(reference.into_owned())
            }
            RuntimeFailureView::Validation(failure) => {
                RuntimeFailure::Validation(failure.into_owned())
            }
            RuntimeFailureView::Defaults(failure) => RuntimeFailure::Defaults(failure.into_owned()),
        }
    }
}
pub fn representation(c: impl Into<String>) -> RuntimeFailure {
    RuntimeFailure::Representation(c.into())
}
pub fn integer_decode(
    profile: &VersionedSemanticProfile,
    domain: Option<&str>,
    value: JsonValue,
) -> Result<BigInt, RuntimeFailure> {
    let binding = profile
        .integer_domain(domain)
        .ok_or_else(|| representation("integer domain"))?;
    crate::semantic_numeric::parse_integer(binding, &value).ok_or_else(|| representation("integer"))
}
pub fn integer_encode(
    profile: &VersionedSemanticProfile,
    domain: Option<&str>,
    value: &BigInt,
) -> Result<JsonValue, RuntimeFailure> {
    use crate::semantic_types::IntegerForm;
    let binding = profile
        .integer_domain(domain)
        .ok_or_else(|| representation("integer domain"))?;
    if binding.forms.contains(&IntegerForm::Number) {
        Ok(JsonValue::Num(value.clone()))
    } else if binding.forms.contains(&IntegerForm::IntegralDecimal) {
        Ok(JsonValue::Dec(format!("{value}.0")))
    } else if binding.forms.contains(&IntegerForm::DecimalString) {
        Ok(JsonValue::Str(value.to_string()))
    } else {
        Err(representation("integer form"))
    }
}
pub fn decode_json(s: &str) -> Result<JsonValue, RuntimeFailure> {
    crate::exact_json::parse_json_text(s).map_err(|e| RuntimeFailure::Json(e.to_string()))
}
pub fn encode_json(v: &JsonValue) -> Result<String, RuntimeFailure> {
    serde_json::to_string(v).map_err(|e| RuntimeFailure::Json(e.to_string()))
}
pub fn object(mut v: JsonValue) -> Result<Vec<(String, JsonValue)>, RuntimeFailure> {
    match &mut v {
        JsonValue::Obj(members) => Ok(std::mem::take(members)),
        _ => Err(representation("object")),
    }
}
fn wrapper<'a>(
    profile: &'a VersionedSemanticProfile,
    name: &str,
) -> Result<&'a Wrapper, RuntimeFailure> {
    profile
        .wrappers
        .iter()
        .find(|wrapper| wrapper.name == name)
        .ok_or_else(|| representation(format!("unknown wrapper {name}")))
}
pub fn wrap_encode(
    profile: &VersionedSemanticProfile,
    wrapper_name: &str,
    payload: String,
) -> Result<JsonValue, RuntimeFailure> {
    let wrapper = wrapper(profile, wrapper_name)?;
    Ok(JsonValue::Obj(vec![(
        wrapper.key.clone(),
        JsonValue::Str(payload),
    )]))
}
pub fn wrap_decode(
    profile: &VersionedSemanticProfile,
    wrapper_name: &str,
    value: JsonValue,
) -> Result<String, RuntimeFailure> {
    let wrapper = wrapper(profile, wrapper_name)?;
    match &value {
        JsonValue::Obj(m) if m.len() == 1 => match m.first() {
            Some((k, JsonValue::Str(v))) if k == &wrapper.key => Ok(v.clone()),
            _ => Err(representation("wrapper payload")),
        },
        _ => Err(representation("wrapper object")),
    }
}
const STANDARD_DIGITS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_SAFE_DIGITS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bytes {
    pub data: Vec<u8>,
    pub wire: Option<String>,
}
impl From<Vec<u8>> for Bytes {
    fn from(data: Vec<u8>) -> Self {
        Self { data, wire: None }
    }
}
fn base64_encode(bytes: &[u8], alphabet: &BytesAlphabet) -> Result<String, RuntimeFailure> {
    let digits = match alphabet {
        BytesAlphabet::UrlSafe => URL_SAFE_DIGITS,
        BytesAlphabet::Standard | BytesAlphabet::Either => STANDARD_DIGITS,
    };
    let mut output = String::new();
    for chunk in bytes.chunks(3) {
        let first = chunk
            .first()
            .ok_or_else(|| representation("base64 input chunk"))?;
        let value = (u32::from(*first) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for shift in [18, 12, 6, 0].into_iter().take(chunk.len() + 1) {
            let digit = digits
                .get(((value >> shift) & 63) as usize)
                .ok_or_else(|| representation("base64 alphabet"))?;
            output.push(char::from(*digit));
        }
        for _ in chunk.len() + 1..4 {
            output.push('=');
        }
    }
    Ok(output)
}
pub fn bytes_encode(
    profile: &VersionedSemanticProfile,
    value: &Bytes,
) -> Result<JsonValue, RuntimeFailure> {
    let default = BytesPolicy {
        reference: profile.reference.clone(),
        padding_optional: false,
        alphabet: BytesAlphabet::Standard,
        strict_pad_bits: true,
        wrapper: None,
    };
    let policy = profile.bytes_policy.as_ref().unwrap_or(&default);
    let text = match value.wire.as_deref() {
        Some(wire)
            if base64_length(policy, wire).is_some()
                && base64_decode(policy, wire).as_deref() == Some(value.data.as_slice()) =>
        {
            wire.to_owned()
        }
        _ => base64_encode(&value.data, &policy.alphabet)?,
    };
    match policy.wrapper.as_ref().and_then(|name| {
        profile
            .wrappers
            .iter()
            .find(|wrapper| &wrapper.name == name)
    }) {
        Some(wrapper) => Ok(JsonValue::Obj(vec![(
            wrapper.key.clone(),
            JsonValue::Str(text),
        )])),
        None => Ok(JsonValue::Str(text)),
    }
}
pub fn bytes_decode(
    profile: &VersionedSemanticProfile,
    value: JsonValue,
) -> Result<Bytes, RuntimeFailure> {
    let policy = profile
        .bytes_policy
        .as_ref()
        .ok_or_else(|| representation("validated bytes policy"))?;
    let wire = match &policy.wrapper {
        Some(name) => wrap_decode(profile, name, value)?,
        None => match &value {
            JsonValue::Str(wire) => wire.clone(),
            _ => return Err(representation("validated bytes shape")),
        },
    };
    let data =
        base64_decode(policy, &wire).ok_or_else(|| representation("validated bytes encoding"))?;
    Ok(Bytes {
        data,
        wire: Some(wire),
    })
}
pub fn with_member(
    key: &str,
    text: &str,
    mut value: JsonValue,
) -> Result<JsonValue, RuntimeFailure> {
    let JsonValue::Obj(m) = &mut value else {
        return Err(representation("object branch"));
    };
    m.retain(|x| x.0 != key);
    m.insert(0, (key.into(), JsonValue::Str(text.into())));
    Ok(value)
}
pub fn branch_selector_matches(
    metadata: &PreparedMetadata<'_>,
    selector: &BranchSelector,
    wire_tag: &str,
    value: &JsonValue,
) -> bool {
    let prepared = metadata.profile();
    let mut workspace = FormatWorkspace::empty();
    match selector {
        BranchSelector::InternalTag => match (&prepared.profile().tag, value) {
            (Some(tag), JsonValue::Obj(members)) => members.iter().any(|(key, value)| {
                key == &tag.key && matches!(value, JsonValue::Str(text) if text == wire_tag)
            }),
            _ => false,
        },
        BranchSelector::MemberShape(tests) => match value {
            JsonValue::Obj(members) => tests.iter().all(|(key, test)| match test {
                MemberTest::Absent => !members.iter().any(|(name, _)| name == key),
                MemberTest::Format(format) => members.iter().any(|(name, value)| {
                    name == key
                        && matches!(value, JsonValue::Str(text)
                        if prepared.named(format).is_some_and(|format| {
                            recognize_prepared_format(format, text, &mut workspace)
                        }))
                }),
            }),
            _ => false,
        },
        BranchSelector::Kind(kind) => matches!(
            (kind, value),
            (crate::semantic_types::ValueKind::Null, JsonValue::Null)
                | (
                    crate::semantic_types::ValueKind::Boolean,
                    JsonValue::Bool(_)
                )
                | (
                    crate::semantic_types::ValueKind::Number,
                    JsonValue::Num(_) | JsonValue::Dec(_)
                )
                | (crate::semantic_types::ValueKind::String, JsonValue::Str(_))
                | (crate::semantic_types::ValueKind::Array, JsonValue::Arr(_))
                | (crate::semantic_types::ValueKind::Object, JsonValue::Obj(_))
        ),
        BranchSelector::Otherwise => true,
    }
}
pub fn select_branch(
    metadata: &PreparedMetadata<'_>,
    reference: &TypeRef,
    value: &JsonValue,
) -> Result<usize, RuntimeFailure> {
    let Some(node) = metadata
        .index()
        .get(reference)
        .and_then(|position| metadata.graph().nodes.get(position))
    else {
        return Err(RuntimeFailure::UndefinedType(reference.clone()));
    };
    let crate::semantic_types::TypeShape::TaggedUnion(spec) = &node.shape else {
        return Err(RuntimeFailure::BranchSelection);
    };
    select_union_branch_index(
        metadata.profile(),
        &mut FormatWorkspace::empty(),
        spec,
        JsonValueView::from_json(value),
    )
    .ok_or(RuntimeFailure::BranchSelection)
}
