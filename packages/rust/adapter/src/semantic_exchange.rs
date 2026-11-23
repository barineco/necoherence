// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::JsonValue as ExchangeJson;
use crate::semantic_types::*;
use crate::semantic_validation::DefaultApplication;
use crate::type_signatures::*;
use num_bigint::{BigInt, BigUint};
use serde::ser::{SerializeSeq, SerializeStruct, SerializeTuple};
use serde::{Serialize, Serializer};
use std::fmt;

pub const COMPOSITION_DIAGNOSTICS_SCHEMA: &str =
    include_str!("signature_composition_diagnostics_schema.json");
use std::sync::Arc;
#[derive(Debug, Clone, PartialEq)]
pub enum GenerationFailure {
    InvalidJson(String),
    Syntax { path: String, message: String },
    UnsupportedSchema { path: String, observed: String },
    UnknownField { path: String, field: String },
    UnknownTag { path: String, tag: String },
    Profile(ProfileFailure),
    Library(LibraryCheckFailure),
    Admission(Box<crate::signature_admission::AdmissionFailure>),
    Composition(crate::semantic_composition::WitnessFailure),
    Encoding(String),
}
impl fmt::Display for GenerationFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for GenerationFailure {}
pub type Decoded<T> = Result<T, GenerationFailure>;

pub trait WireEncode {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error>;
}
impl<T: WireEncode + ?Sized> WireEncode for &T {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        T::serialize_wire(*self, serializer)
    }
}
pub trait WireDecode: WireEncode + Sized {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self>;
}
pub struct Wire<'a, T: ?Sized>(pub &'a T);
impl<T: WireEncode + ?Sized> Serialize for Wire<'_, T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize_wire(serializer)
    }
}

pub fn syntax(path: &str, message: &str) -> GenerationFailure {
    GenerationFailure::Syntax {
        path: path.to_owned(),
        message: message.to_owned(),
    }
}
pub fn field_path(path: &str, field: &str) -> String {
    format!("{path}.{field}")
}
pub fn keys<'a>(
    value: &'a ExchangeJson,
    path: &str,
    names: &[&str],
) -> Decoded<&'a [(String, ExchangeJson)]> {
    let members = match value {
        ExchangeJson::Obj(members) => members,
        _ => return Err(syntax(path, "object expected")),
    };
    let mut actual: Vec<&str> = members.iter().map(|(name, _)| name.as_str()).collect();
    actual.sort_unstable();
    if let Some(name) = actual.into_iter().find(|name| !names.contains(name)) {
        return Err(GenerationFailure::UnknownField {
            path: field_path(path, name),
            field: name.to_owned(),
        });
    }
    if let Some(name) = names
        .iter()
        .copied()
        .find(|name| !members.iter().any(|(key, _)| key.as_str() == *name))
    {
        return Err(syntax(&field_path(path, name), "missing field"));
    }
    Ok(members)
}
pub fn field<'a>(
    members: &'a [(String, ExchangeJson)],
    path: &str,
    name: &str,
) -> Decoded<&'a ExchangeJson> {
    members
        .iter()
        .find(|(key, _)| key.as_str() == name)
        .map(|(_, value)| value)
        .ok_or_else(|| {
            syntax(
                &field_path(path, name),
                &format!("property not found: {name}"),
            )
        })
}
pub fn tag<'a>(value: &'a ExchangeJson, path: &str) -> Decoded<&'a str> {
    let members = match value {
        ExchangeJson::Obj(members) => members,
        _ => return Err(syntax(&field_path(path, "tag"), "object expected")),
    };
    match field(members, path, "tag")? {
        ExchangeJson::Str(tag) => Ok(tag),
        _ => Err(syntax(&field_path(path, "tag"), "String expected")),
    }
}
fn integer_text(text: &str, path: &str) -> Decoded<BigInt> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(syntax(path, "expected canonical integer"));
    }
    let value: BigInt = text
        .parse()
        .map_err(|_| syntax(path, "expected canonical integer"))?;
    if value.to_string() != text {
        return Err(syntax(path, "noncanonical integer"));
    }
    Ok(value)
}
fn exact_decimal(text: &str) -> bool {
    !text.bytes().any(|byte| byte.is_ascii_whitespace())
        && crate::exact_json::text_admission_failure(text).is_none()
        && text.parse::<serde_json::Number>().is_ok()
}

impl WireEncode for str {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self)
    }
}
impl WireEncode for String {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.as_str().serialize_wire(serializer)
    }
}
impl WireDecode for String {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Str(text) => Ok(text.clone()),
            _ => Err(syntax(path, "String expected")),
        }
    }
}
impl WireEncode for bool {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_bool(*self)
    }
}
impl WireDecode for bool {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Bool(value) => Ok(*value),
            _ => Err(syntax(path, "Bool expected")),
        }
    }
}
impl WireEncode for BigInt {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}
impl WireDecode for BigInt {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Str(text) => integer_text(text, path),
            _ => Err(syntax(path, "String expected")),
        }
    }
}
impl WireEncode for BigUint {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}
impl WireDecode for BigUint {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Str(text) => integer_text(text, path)?
                .to_biguint()
                .ok_or_else(|| syntax(path, "negative natural")),
            _ => Err(syntax(path, "String expected")),
        }
    }
}

impl<T: WireEncode> WireEncode for [T] {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(self.len()))?;
        for item in self {
            sequence.serialize_element(&Wire(item))?;
        }
        sequence.end()
    }
}
impl<T: WireEncode> WireEncode for Vec<T> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.as_slice().serialize_wire(serializer)
    }
}
impl<T: WireDecode> WireDecode for Vec<T> {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Arr(items) => items
                .iter()
                .enumerate()
                .map(|(index, value)| T::decode_wire(value, &format!("{path}[{index}]")))
                .collect(),
            _ => Err(syntax(path, "array expected")),
        }
    }
}
impl<T: WireEncode> WireEncode for Option<T> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Some(value) => serializer.serialize_some(&Wire(value)),
            None => serializer.serialize_none(),
        }
    }
}
impl<T: WireDecode> WireDecode for Option<T> {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Null => Ok(None),
            value => T::decode_wire(value, path).map(Some),
        }
    }
}
impl<A: WireEncode, B: WireEncode> WireEncode for (A, B) {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut tuple = serializer.serialize_tuple(2)?;
        tuple.serialize_element(&Wire(&self.0))?;
        tuple.serialize_element(&Wire(&self.1))?;
        tuple.end()
    }
}
impl<A: WireDecode, B: WireDecode> WireDecode for (A, B) {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match value {
            ExchangeJson::Arr(items) => match items.as_slice() {
                [first, second] => {
                    Ok((A::decode_wire(first, path)?, B::decode_wire(second, path)?))
                }
                _ => Err(syntax(path, "pair size")),
            },
            _ => Err(syntax(path, "array expected")),
        }
    }
}
macro_rules! pointer_codec {
    ($pointer:ident) => {
        impl<T: WireEncode> WireEncode for $pointer<T> {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                self.as_ref().serialize_wire(serializer)
            }
        }
        impl<T: WireDecode> WireDecode for $pointer<T> {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                T::decode_wire(value, path).map($pointer::new)
            }
        }
    };
}
pointer_codec!(Arc);
pointer_codec!(Box);
impl WireEncode for Arc<str> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.as_ref().serialize_wire(serializer)
    }
}
impl WireDecode for Arc<str> {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        String::decode_wire(value, path).map(Arc::from)
    }
}
impl WireEncode for Arc<[String]> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.as_ref().serialize_wire(serializer)
    }
}
impl WireDecode for Arc<[String]> {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        Vec::<String>::decode_wire(value, path).map(Arc::from)
    }
}

#[macro_export]
macro_rules! wire_key {
    ($name:ident) => {
        stringify!($name)
    };
    ($name:ident, $wire_name:literal) => {
        $wire_name
    };
}

#[macro_export]
macro_rules! wire_record_encode {
    ($type:ty { $($name:ident: $field_type:ty $(=> $wire_name:literal)?),* $(,)? }) => {
        impl WireEncode for $type {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                let mut record = serializer.serialize_struct(stringify!($type), [$($crate::wire_key!($name $(, $wire_name)?)),*].len())?;
                $(record.serialize_field($crate::wire_key!($name $(, $wire_name)?), &Wire(&self.$name))?;)*
                record.end()
            }
        }
    };
}
#[macro_export]
macro_rules! wire_record_decode {
    ($type:ty { $($name:ident: $field_type:ty $(=> $wire_name:literal)?),* $(,)? }) => {
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                let members = keys(value, path, &[$($crate::wire_key!($name $(, $wire_name)?)),*])?;
                Ok(Self { $($name: <$field_type>::decode_wire(field(members, path, $crate::wire_key!($name $(, $wire_name)?))?, &field_path(path, $crate::wire_key!($name $(, $wire_name)?)))?),* })
            }
        }
    };
}
#[macro_export]
macro_rules! wire_record {
    ($($definition:tt)*) => {
        $crate::wire_record_encode!($($definition)*);
        $crate::wire_record_decode!($($definition)*);
    };
}
#[macro_export]
macro_rules! wire_enum_encode {
    ($type:ty; units [$($unit:ident),* $(,)?]; tuples [$($tuple:ident($tuple_type:ty)),* $(,)?]; records [$($variant:ident { $($name:ident: $field_type:ty),* $(,)? }),* $(,)?] $(; binary [$($binary:ident($left_type:ty, $right_type:ty)),* $(,)?])?) => {
        impl WireEncode for $type {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                match self {
                    $(Self::$unit => {
                        let mut record = serializer.serialize_struct(stringify!($type), 1)?;
                        record.serialize_field("tag", stringify!($unit))?; record.end()
                    },)*
                    $(Self::$tuple(value) => {
                        let mut record = serializer.serialize_struct(stringify!($type), 2)?;
                        record.serialize_field("tag", stringify!($tuple))?;
                        record.serialize_field("value", &Wire(value))?; record.end()
                    },)*
                    $(Self::$variant { $($name),* } => {
                        struct Payload<'a> { $($name: &'a $field_type),* }
                        impl Serialize for Payload<'_> {
                            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                                let mut record = serializer.serialize_struct("Fields", [$(stringify!($name)),*].len())?;
                                $(record.serialize_field(stringify!($name), &Wire(self.$name))?;)*
                                record.end()
                            }
                        }
                        let mut record = serializer.serialize_struct(stringify!($type), 2)?;
                        record.serialize_field("tag", stringify!($variant))?;
                        record.serialize_field("fields", &Payload { $($name),* })?; record.end()
                    },)*
                    $($(Self::$binary(left, right) => {
                        let mut record = serializer.serialize_struct(stringify!($type), 2)?;
                        record.serialize_field("tag", stringify!($binary))?;
                        record.serialize_field("value", &Wire(&(left, right)))?; record.end()
                    },)*)?
                }
            }
        }
    };
}
pub fn plain_payload(path: &str, _segment: &str) -> String {
    path.to_owned()
}
pub fn prefixed_payload(path: &str, segment: &str) -> String {
    field_path(path, segment)
}
#[macro_export]
macro_rules! wire_enum_decode_with {
    ($payload:expr; $type:ty; units [$($unit:ident),* $(,)?]; tuples [$($tuple:ident($tuple_type:ty)),* $(,)?]; records [$($variant:ident { $($name:ident: $field_type:ty),* $(,)? }),* $(,)?] $(; binary [$($binary:ident($left_type:ty, $right_type:ty)),* $(,)?])?) => {
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                match tag(value, path)? {
                    $(stringify!($unit) => { keys(value, path, &["tag"])?; Ok(Self::$unit) },)*
                    $(stringify!($tuple) => {
                        let members = keys(value, path, &["tag", "value"])?;
                        let payload_path = $payload(path, "value");
                        Ok(Self::$tuple(<$tuple_type>::decode_wire(field(members, path, "value")?, &payload_path)?))
                    },)*
                    $(stringify!($variant) => {
                        let members = keys(value, path, &["tag", "fields"])?;
                        let payload = field(members, path, "fields")?;
                        let payload_path = $payload(path, "fields");
                        let members = keys(payload, &payload_path, &[$(stringify!($name)),*])?;
                        Ok(Self::$variant { $($name: <$field_type>::decode_wire(field(members, &payload_path, stringify!($name))?, &field_path(&payload_path, stringify!($name)))?),* })
                    },)*
                    $($(stringify!($binary) => {
                        let members = keys(value, path, &["tag", "value"])?;
                        let payload_path = $payload(path, "value");
                        let (left, right) = <($left_type, $right_type)>::decode_wire(field(members, path, "value")?, &payload_path)?;
                        Ok(Self::$binary(left, right))
                    },)*)?
                    other => Err(GenerationFailure::UnknownTag {
                        path: field_path(path, "tag"),
                        tag: other.to_owned(),
                    }),
                }
            }
        }
    };
}
#[macro_export]
macro_rules! wire_enum_decode {
    ($($definition:tt)*) => {
        $crate::wire_enum_decode_with!($crate::semantic_exchange::plain_payload; $($definition)*);
    };
}
#[macro_export]
macro_rules! wire_enum {
    ($($definition:tt)*) => {
        $crate::wire_enum_encode!($($definition)*);
        $crate::wire_enum_decode!($($definition)*);
    };
}
macro_rules! wire_enum_prefixed {
    ($($definition:tt)*) => {
        wire_enum_encode!($($definition)*);
        wire_enum_decode_with!(prefixed_payload; $($definition)*);
    };
}

struct ExactMember<'a>(&'a str, &'a JsonValue);
impl Serialize for ExactMember<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut record = serializer.serialize_struct("ExactMember", 2)?;
        record.serialize_field("key", self.0)?;
        record.serialize_field("value", &Wire(self.1))?;
        record.end()
    }
}
struct ExactMembers<'a>(&'a [(String, JsonValue)]);
impl Serialize for ExactMembers<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(self.0.len()))?;
        for (key, value) in self.0 {
            sequence.serialize_element(&ExactMember(key, value))?;
        }
        sequence.end()
    }
}
impl WireEncode for JsonValue {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let (tag, count) = match self {
            Self::Null => ("Null", 1),
            Self::Bool(_) => ("Bool", 2),
            Self::Num(_) => ("Integer", 2),
            Self::Dec(_) => ("Decimal", 2),
            Self::Str(_) => ("String", 2),
            Self::Arr(_) => ("Array", 2),
            Self::Obj(_) => ("Object", 2),
        };
        let mut record = serializer.serialize_struct("ExactJson", count)?;
        record.serialize_field("tag", tag)?;
        match self {
            Self::Null => {}
            Self::Bool(value) => record.serialize_field("value", value)?,
            Self::Num(value) => record.serialize_field("value", &Wire(value))?,
            Self::Dec(text) => record.serialize_field("text", text)?,
            Self::Str(value) => record.serialize_field("value", value)?,
            Self::Arr(items) => record.serialize_field("items", &Wire(items))?,
            Self::Obj(members) => record.serialize_field("members", &ExactMembers(members))?,
        }
        record.end()
    }
}
impl WireDecode for JsonValue {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match tag(value, path)? {
            "Null" => {
                keys(value, path, &["tag"])?;
                Ok(Self::Null)
            }
            "Bool" => {
                let members = keys(value, path, &["tag", "value"])?;
                bool::decode_wire(field(members, path, "value")?, path).map(Self::Bool)
            }
            "Integer" => {
                let members = keys(value, path, &["tag", "value"])?;
                BigInt::decode_wire(field(members, path, "value")?, path).map(Self::Num)
            }
            "String" => {
                let members = keys(value, path, &["tag", "value"])?;
                String::decode_wire(field(members, path, "value")?, path).map(Self::Str)
            }
            "Decimal" => {
                let members = keys(value, path, &["tag", "text"])?;
                let text_path = field_path(path, "text");
                let text = String::decode_wire(field(members, path, "text")?, &text_path)?;
                if text.trim_ascii() != text {
                    return Err(syntax(&text_path, "decimal whitespace"));
                }
                if !exact_decimal(&text) {
                    return Err(syntax(&text_path, "invalid exact decimal"));
                }
                Ok(Self::Dec(text))
            }
            "Array" => {
                let members = keys(value, path, &["tag", "items"])?;
                match field(members, path, "items")? {
                    ExchangeJson::Arr(items) => items
                        .iter()
                        .map(|item| crate::stack_growth::grow(|| Self::decode_wire(item, path)))
                        .collect::<Decoded<Vec<_>>>()
                        .map(Self::Arr),
                    _ => Err(syntax(path, "array expected")),
                }
            }
            "Object" => {
                let members = keys(value, path, &["tag", "members"])?;
                let rows = match field(members, path, "members")? {
                    ExchangeJson::Arr(rows) => rows,
                    _ => return Err(syntax(path, "array expected")),
                };
                let mut result = Vec::with_capacity(rows.len());
                for row in rows {
                    let members = keys(row, path, &["key", "value"])?;
                    let key = String::decode_wire(
                        field(members, path, "key")?,
                        &field_path(path, "key"),
                    )?;
                    let child = field(members, path, "value")?;
                    let value = crate::stack_growth::grow(|| Self::decode_wire(child, path))?;
                    result.push((key, value));
                }
                Ok(Self::Obj(result))
            }
            other => Err(GenerationFailure::UnknownTag {
                path: field_path(path, "tag"),
                tag: other.to_owned(),
            }),
        }
    }
}

impl WireEncode for WrapperPayload {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Bytes => {
                let mut record = serializer.serialize_struct("WrapperPayload", 1)?;
                record.serialize_field("tag", "Bytes")?;
                record.end()
            }
            Self::Text { format } => {
                let mut record = serializer.serialize_struct("WrapperPayload", 2)?;
                record.serialize_field("tag", "Text")?;
                record.serialize_field("value", &Wire(format))?;
                record.end()
            }
        }
    }
}
impl WireDecode for WrapperPayload {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match tag(value, path)? {
            "Bytes" => {
                keys(value, path, &["tag"])?;
                Ok(Self::Bytes)
            }
            "Text" => {
                let members = keys(value, path, &["tag", "value"])?;
                Ok(Self::Text {
                    format: Option::<String>::decode_wire(field(members, path, "value")?, path)?,
                })
            }
            other => Err(GenerationFailure::UnknownTag {
                path: field_path(path, "tag"),
                tag: other.to_owned(),
            }),
        }
    }
}
struct MemberCheck<'a>(&'a (String, MemberTest));
impl WireEncode for MemberCheck<'_> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut record = serializer.serialize_struct("MemberCheck", 2)?;
        record.serialize_field("key", &Wire(&self.0 .0))?;
        record.serialize_field("test", &Wire(&self.0 .1))?;
        record.end()
    }
}
struct MemberChecks<'a>(&'a [(String, MemberTest)]);
impl WireEncode for MemberChecks<'_> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(self.0.len()))?;
        for check in self.0 {
            sequence.serialize_element(&Wire(&MemberCheck(check)))?;
        }
        sequence.end()
    }
}
fn serialize_unit_tag<S: Serializer>(serializer: S, tag: &str) -> Result<S::Ok, S::Error> {
    let mut record = serializer.serialize_struct("BranchSelector", 1)?;
    record.serialize_field("tag", tag)?;
    record.end()
}
fn serialize_tagged<S: Serializer, T: WireEncode + ?Sized>(
    serializer: S,
    tag: &str,
    value: &T,
) -> Result<S::Ok, S::Error> {
    let mut record = serializer.serialize_struct("BranchSelector", 2)?;
    record.serialize_field("tag", tag)?;
    record.serialize_field("value", &Wire(value))?;
    record.end()
}
impl WireEncode for BranchSelector {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::InternalTag => serialize_unit_tag(serializer, "InternalTag"),
            Self::Otherwise => serialize_unit_tag(serializer, "Otherwise"),
            Self::MemberShape(tests) => {
                serialize_tagged(serializer, "MemberShape", &MemberChecks(tests))
            }
            Self::Kind(kind) => serialize_tagged(serializer, "Kind", kind),
        }
    }
}
fn decode_member_check(value: &ExchangeJson, path: &str) -> Decoded<(String, MemberTest)> {
    let members = keys(value, path, &["key", "test"])?;
    Ok((
        String::decode_wire(field(members, path, "key")?, &field_path(path, "key"))?,
        MemberTest::decode_wire(field(members, path, "test")?, &field_path(path, "test"))?,
    ))
}
fn decode_member_checks(value: &ExchangeJson, path: &str) -> Decoded<Vec<(String, MemberTest)>> {
    match value {
        ExchangeJson::Arr(items) => items
            .iter()
            .map(|item| decode_member_check(item, path))
            .collect(),
        _ => Err(syntax(path, "array expected")),
    }
}
impl WireDecode for BranchSelector {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        match tag(value, path)? {
            "InternalTag" => {
                keys(value, path, &["tag"])?;
                Ok(Self::InternalTag)
            }
            "Otherwise" => {
                keys(value, path, &["tag"])?;
                Ok(Self::Otherwise)
            }
            "MemberShape" => {
                let members = keys(value, path, &["tag", "value"])?;
                Ok(Self::MemberShape(decode_member_checks(
                    field(members, path, "value")?,
                    path,
                )?))
            }
            "Kind" => {
                let members = keys(value, path, &["tag", "value"])?;
                Ok(Self::Kind(ValueKind::decode_wire(
                    field(members, path, "value")?,
                    path,
                )?))
            }
            other => Err(GenerationFailure::UnknownTag {
                path: field_path(path, "tag"),
                tag: other.to_owned(),
            }),
        }
    }
}
impl WireEncode for crate::goal_observations::GoalObservations {
    fn serialize_wire<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.value().serialize(s)
    }
}
impl WireDecode for crate::goal_observations::GoalObservations {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        keys(value, path, &crate::goal_observations::KEYS)?;
        let value = serde_json::Value::decode_wire(value, path)?;
        crate::goal_observations::GoalObservations::from_wire(value)
            .ok_or_else(|| syntax(path, "goal observations"))
    }
}
impl WireEncode for serde_json::Value {
    fn serialize_wire<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.serialize(s)
    }
}
impl WireDecode for serde_json::Value {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        serde_json::to_value(value).map_err(|_| syntax(path, "JSON value"))
    }
}
pub fn encode<T: WireEncode + ?Sized>(v: &T) -> Decoded<String> {
    serde_json::to_string(&Wire(v)).map_err(|e| GenerationFailure::Encoding(e.to_string()))
}
pub fn encode_diagnostic(value: &ValueFailure) -> Decoded<String> {
    encode(value)
}
pub(crate) fn wire_value<T: WireEncode + ?Sized>(value: &T) -> Decoded<serde_json::Value> {
    serde_json::to_value(Wire(value))
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))
}
pub fn parse_exchange_text(text: &str) -> Decoded<ExchangeJson> {
    if let Some(message) = crate::exact_json::text_admission_failure(text) {
        return Err(syntax("$", message));
    }
    crate::exact_json::parse_json_text(text)
        .map_err(|e| GenerationFailure::InvalidJson(e.to_string()))
}
fn decode<T: WireDecode>(s: &str) -> Decoded<T> {
    let value = parse_exchange_text(s)?;
    T::decode_wire(&value, "$")
}
pub fn decode_wire_text_at<T: WireDecode>(text: &str, path: &str) -> Decoded<T> {
    let value = parse_exchange_text(text).map_err(|failure| match failure {
        GenerationFailure::Syntax { message, .. } | GenerationFailure::InvalidJson(message) => {
            syntax(path, &message)
        }
        other => other,
    })?;
    T::decode_wire(&value, path)
}
pub fn encode_signature_generation(v: &SignatureGenerationInput) -> Decoded<String> {
    encode(v)
}
pub fn decode_signature_generation(s: &str) -> Decoded<SignatureGenerationInput> {
    let value = parse_exchange_text(s).map_err(|failure| match failure {
        GenerationFailure::Syntax { message, .. } => GenerationFailure::InvalidJson(message),
        other => other,
    })?;
    let members = keys(
        &value,
        "$",
        &[
            "schema",
            "basis",
            "signatures",
            "composition",
            "entrypoints",
        ],
    )?;
    let schema = String::decode_wire(field(members, "$", "schema")?, "$.schema")?;
    if schema != "ncoh-checked-generation@5" {
        return Err(GenerationFailure::UnsupportedSchema {
            path: "$.schema".into(),
            observed: schema,
        });
    }
    SignatureGenerationInput::decode_wire(&value, "$")
}
pub fn encode_type_signatures(v: &TypeSignatureLibrary) -> Decoded<String> {
    encode(v)
}
pub fn decode_type_signatures(s: &str) -> Decoded<TypeSignatureLibrary> {
    let value: TypeSignatureLibrary = decode(s)?;
    crate::type_signatures::check_library(&value).map_err(GenerationFailure::Library)?;
    Ok(value)
}
pub fn encode_value_profile(v: &ValueSemanticProfile) -> Decoded<String> {
    encode(v)
}
pub fn decode_value_profile(s: &str) -> Decoded<ValueSemanticProfile> {
    let v: ValueSemanticProfile = decode(s)?;
    crate::semantic_validation::check_profile(&v.semantic_profile())
        .map_err(GenerationFailure::Profile)?;
    Ok(v)
}

pub fn decode_type_reference(text: &str) -> Decoded<TypeRef> {
    decode(text)
}
pub fn encode_exact_value(value: &JsonValue) -> Decoded<String> {
    encode(value)
}
pub fn decode_exact_value(text: &str) -> Decoded<JsonValue> {
    decode(text)
}
pub fn encode_default_applications(applications: &[DefaultApplication]) -> Decoded<String> {
    encode(applications)
}
pub fn encode_semantic_obligations(obligations: &[SemanticObligation]) -> Decoded<String> {
    encode(obligations)
}
pub fn decode_semantic_obligations(text: &str) -> Decoded<Vec<SemanticObligation>> {
    decode(text)
}
pub fn decode_evaluation_provenance(text: &str) -> Decoded<EvaluationProvenance> {
    decode(text)
}
pub fn encode_evaluation_provenance(provenance: &EvaluationProvenance) -> Decoded<String> {
    encode(provenance)
}
pub fn decode_composition_provenance(
    text: &str,
) -> Decoded<crate::semantic_composition::CompositionProvenance> {
    decode(text)
}
pub fn encode_composition_provenance(
    provenance: &crate::semantic_composition::CompositionProvenance,
) -> Decoded<String> {
    encode(provenance)
}
pub fn decode_unresolved_obligations(
    text: &str,
) -> Decoded<Vec<crate::semantic_composition::UnresolvedObligation>> {
    decode(text)
}
pub fn encode_unresolved_obligations(
    obligations: &[crate::semantic_composition::UnresolvedObligation],
) -> Decoded<String> {
    encode(obligations)
}
pub fn encode_signature_basis(v: &SignatureGenerationBasis) -> Decoded<String> {
    encode(v)
}
pub fn encode_expected_signature_basis(
    v: &crate::type_signatures::ExpectedSignatureBasis,
) -> Decoded<String> {
    encode(v)
}
pub fn decode_signature_basis(s: &str) -> Decoded<SignatureGenerationBasis> {
    decode(s)
}
pub fn decode_expected_signature_basis(
    s: &str,
) -> Decoded<crate::type_signatures::ExpectedSignatureBasis> {
    decode(s)
}
pub fn utf8_sha256(s: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(s.as_bytes()))
}

include!("signature_composition_wire.rs");
include!("wire_declarations.rs");
#[cfg(test)]
mod tests {
    use super::*;

    fn member_shape_value(entries: ExchangeJson) -> ExchangeJson {
        ExchangeJson::Obj(vec![
            ("tag".into(), ExchangeJson::Str("MemberShape".into())),
            ("value".into(), entries),
        ])
    }

    #[test]
    fn member_shape_entries_encode_as_key_and_test_objects() {
        let selector = BranchSelector::MemberShape(vec![("m".into(), MemberTest::Absent)]);
        assert_eq!(
            serde_json::to_value(Wire(&selector)).ok(),
            Some(
                serde_json::json!({"tag":"MemberShape","value":[{"key":"m","test":{"tag":"Absent"}}]})
            )
        );
    }

    #[test]
    fn member_shape_entries_decode_from_key_and_test_objects() {
        let entry = ExchangeJson::Obj(vec![
            ("key".into(), ExchangeJson::Str("m".into())),
            (
                "test".into(),
                ExchangeJson::Obj(vec![("tag".into(), ExchangeJson::Str("Absent".into()))]),
            ),
        ]);
        assert_eq!(
            <BranchSelector as WireDecode>::decode_wire(
                &member_shape_value(ExchangeJson::Arr(vec![entry])),
                "$"
            ),
            Ok(BranchSelector::MemberShape(vec![(
                "m".into(),
                MemberTest::Absent
            )]))
        );
    }

    #[test]
    fn negative_natural_is_a_syntax_failure() {
        assert_eq!(
            <BigUint as WireDecode>::decode_wire(&ExchangeJson::Str("-5".into()), "$"),
            Err(GenerationFailure::Syntax {
                path: "$".into(),
                message: "negative natural".into(),
            })
        );
    }

    #[test]
    fn member_shape_entries_reject_pair_arrays() {
        let pair = ExchangeJson::Arr(vec![
            ExchangeJson::Str("m".into()),
            ExchangeJson::Obj(vec![("tag".into(), ExchangeJson::Str("Absent".into()))]),
        ]);
        assert_eq!(
            <BranchSelector as WireDecode>::decode_wire(
                &member_shape_value(ExchangeJson::Arr(vec![pair])),
                "$"
            ),
            Err(GenerationFailure::Syntax {
                path: "$".into(),
                message: "object expected".into(),
            })
        );
    }
}
