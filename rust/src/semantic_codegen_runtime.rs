// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

pub use crate::exact_json::JsonValue;
use crate::semantic_types::{
    BranchSelector, MemberTest, SemanticGraph, TypeRef, UnionSpec, VersionedSemanticProfile,
    Wrapper,
};
use crate::semantic_validation::{recognize_format, select_union_branch};
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
}
impl fmt::Display for RuntimeFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RuntimeFailure {}
pub fn representation(c: impl Into<String>) -> RuntimeFailure {
    RuntimeFailure::Representation(c.into())
}
pub fn parse_integer(s: &str) -> Result<BigInt, RuntimeFailure> {
    s.parse().map_err(|_| representation("integer"))
}
pub fn decode_json(s: &str) -> Result<JsonValue, RuntimeFailure> {
    serde_json::from_str(s).map_err(|e| RuntimeFailure::Json(e.to_string()))
}
pub fn encode_json(v: &JsonValue) -> Result<String, RuntimeFailure> {
    serde_json::to_string(v).map_err(|e| RuntimeFailure::Json(e.to_string()))
}
pub fn object(v: JsonValue) -> Result<Vec<(String, JsonValue)>, RuntimeFailure> {
    match v {
        JsonValue::Obj(v) => Ok(v),
        _ => Err(representation("object")),
    }
}
pub fn field_slot(v: Option<JsonValue>) -> crate::semantic_types::SlotValue {
    match v {
        None => crate::semantic_types::SlotValue::Absent,
        Some(JsonValue::Null) => crate::semantic_types::SlotValue::Null,
        Some(v) => crate::semantic_types::SlotValue::Present(v),
    }
}
pub fn take_field(m: &mut Vec<(String, JsonValue)>, n: &str) -> crate::semantic_types::SlotValue {
    m.iter()
        .position(|x| x.0 == n)
        .map(|i| field_slot(Some(m.remove(i).1)))
        .unwrap_or(crate::semantic_types::SlotValue::Absent)
}
pub fn put_field(m: &mut Vec<(String, JsonValue)>, n: &str, v: crate::semantic_types::SlotValue) {
    m.retain(|x| x.0 != n);
    match v {
        crate::semantic_types::SlotValue::Absent => {}
        crate::semantic_types::SlotValue::Null => m.push((n.into(), JsonValue::Null)),
        crate::semantic_types::SlotValue::Present(v) => m.push((n.into(), v)),
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
    match value {
        JsonValue::Obj(m) if m.len() == 1 => match m.first() {
            Some((k, JsonValue::Str(v))) if k == &wrapper.key => Ok(v.clone()),
            _ => Err(representation("wrapper payload")),
        },
        _ => Err(representation("wrapper object")),
    }
}
fn base64_encode(bytes: &[u8], url_safe: bool, padded: bool) -> Result<String, RuntimeFailure> {
    let alphabet = if url_safe {
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    } else {
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
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
            let digit = alphabet
                .get(((value >> shift) & 63) as usize)
                .ok_or_else(|| representation("base64 alphabet"))?;
            output.push(char::from(*digit));
        }
    }
    if padded {
        while !output.len().is_multiple_of(4) {
            output.push('=');
        }
    }
    Ok(output)
}
fn base64_value(byte: u8, url_safe: bool) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' if !url_safe => Some(62),
        b'/' if !url_safe => Some(63),
        b'-' if url_safe => Some(62),
        b'_' if url_safe => Some(63),
        _ => None,
    }
}
fn base64_decode(text: &str, url_safe: bool) -> Option<Vec<u8>> {
    let text = text.trim_end_matches('=');
    if text.len() % 4 == 1 {
        return None;
    }
    let values = text
        .bytes()
        .map(|byte| base64_value(byte, url_safe))
        .collect::<Option<Vec<_>>>()?;
    let mut output = Vec::new();
    for chunk in values.chunks(4) {
        let mut value = 0u32;
        for digit in chunk {
            value = (value << 6) | u32::from(*digit);
        }
        value <<= 6 * (4 - chunk.len());
        output.push((value >> 16) as u8);
        if chunk.len() >= 3 {
            output.push((value >> 8) as u8);
        }
        if chunk.len() == 4 {
            output.push(value as u8);
        }
    }
    Some(output)
}
pub fn bytes_encode(
    profile: &VersionedSemanticProfile,
    bytes: &[u8],
) -> Result<JsonValue, RuntimeFailure> {
    let policy = profile
        .bytes_policy
        .as_ref()
        .ok_or_else(|| representation("bytes policy"))?;
    let url_safe = matches!(
        policy.alphabet,
        crate::semantic_types::BytesAlphabet::UrlSafe
    );
    let text = base64_encode(bytes, url_safe, !policy.padding_optional)?;
    match &policy.wrapper {
        Some(wrapper) => wrap_encode(profile, wrapper, text),
        None => Ok(JsonValue::Str(text)),
    }
}
pub fn bytes_decode(
    profile: &VersionedSemanticProfile,
    value: JsonValue,
) -> Result<Vec<u8>, RuntimeFailure> {
    let policy = profile
        .bytes_policy
        .as_ref()
        .ok_or_else(|| representation("bytes policy"))?;
    let text = match &policy.wrapper {
        Some(wrapper) => wrap_decode(profile, wrapper, value)?,
        None => match value {
            JsonValue::Str(text) => text,
            _ => return Err(representation("bytes text")),
        },
    };
    let alphabets: &[bool] = match policy.alphabet {
        crate::semantic_types::BytesAlphabet::Standard => &[false],
        crate::semantic_types::BytesAlphabet::UrlSafe => &[true],
        crate::semantic_types::BytesAlphabet::Either => &[false, true],
    };
    alphabets
        .iter()
        .find_map(|url_safe| base64_decode(&text, *url_safe))
        .ok_or_else(|| representation("base64"))
}
pub fn with_member(key: &str, text: &str, value: JsonValue) -> Result<JsonValue, RuntimeFailure> {
    let JsonValue::Obj(mut m) = value else {
        return Err(representation("object branch"));
    };
    m.retain(|x| x.0 != key);
    m.insert(0, (key.into(), JsonValue::Str(text.into())));
    Ok(JsonValue::Obj(m))
}
pub fn branch_selector_matches(
    profile: &VersionedSemanticProfile,
    selector: &BranchSelector,
    wire_tag: &str,
    value: &JsonValue,
) -> bool {
    match selector {
        BranchSelector::InternalTag => match (&profile.tag, value) {
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
                        if profile.format(format).is_some_and(|binding| {
                            recognize_format(&binding.rule, text)
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
    graph: &SemanticGraph,
    reference: &TypeRef,
    value: &JsonValue,
) -> Result<usize, RuntimeFailure> {
    let Some(node) = graph.find_type(reference) else {
        return Err(RuntimeFailure::UndefinedType(reference.clone()));
    };
    let crate::semantic_types::TypeShape::TaggedUnion(UnionSpec { branches }) = &node.shape else {
        return Err(RuntimeFailure::BranchSelection);
    };
    let declared = UnionSpec {
        branches: branches.clone(),
    };
    let selected = select_union_branch(&graph.profile, &declared, value);
    selected
        .and_then(|b| branches.iter().position(|x| x == b))
        .ok_or(RuntimeFailure::BranchSelection)
}
pub fn select_branch_from(
    selectors: &[BranchSelector],
    value: &JsonValue,
    key: Option<&str>,
    profile: &VersionedSemanticProfile,
) -> Option<usize> {
    selectors.iter().position(|s|match s{BranchSelector::InternalTag=>matches!((key,value),(Some(k),JsonValue::Obj(m))if m.iter().any(|x|x.0==k&&matches!(x.1,JsonValue::Str(_)))),BranchSelector::MemberShape(t)=>matches!(value,JsonValue::Obj(m)if t.iter().all(|(k,x)|match x{MemberTest::Absent=>!m.iter().any(|x|x.0==*k),MemberTest::Format(f)=>m.iter().any(|x|x.0==*k&&matches!(&x.1,JsonValue::Str(v)if profile.format(f).is_some_and(|r|recognize_format(&r.rule,v))))})),BranchSelector::Kind(k)=>crate::semantic_validation::selector_matches(profile,&crate::semantic_types::UnionBranch{target:TypeRef::new(std::sync::Arc::new(crate::semantic_types::SourceRef{repository:String::new(),revision:String::new(),path:String::new(),content_digest:String::new(),document_id:String::new(),declared_revision:None}),"",Vec::<String>::new()),wire_tag:String::new(),selector:BranchSelector::Kind(*k),origin:crate::semantic_types::OccurrenceRef{source:std::sync::Arc::new(crate::semantic_types::SourceRef{repository:String::new(),revision:String::new(),path:String::new(),content_digest:String::new(),document_id:String::new(),declared_revision:None}),pointer:std::sync::Arc::from([])},},value),BranchSelector::Otherwise=>true})
}
