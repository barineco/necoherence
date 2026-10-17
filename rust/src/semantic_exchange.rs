// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
use crate::exact_json::JsonValue as ExchangeJson;
use crate::semantic_types::*;
use crate::semantic_validation::DefaultApplication;
use crate::type_signatures::*;
use num_bigint::{BigInt, BigUint};
use num_traits::ToPrimitive;
use serde::ser::{SerializeSeq, SerializeStruct, SerializeTuple};
use serde::{Serialize, Serializer};
use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::sync::Arc;
#[derive(Debug)]
pub enum GenerationFailure {
    InvalidJson(String),
    Syntax { path: String, expected: String },
    UnsupportedSchema { observed: String },
    UnknownField { path: String, field: String },
    UnknownTag { path: String, tag: String },
    InvalidExchangeShape { path: String, expected: String },
    InvalidInteger { path: String, text: String },
    UnrepresentableNatural { path: String, text: String },
    Profile(ProfileFailure),
    Library(LibraryCheckFailure),
    Encoding(String),
}
impl fmt::Display for GenerationFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for GenerationFailure {}
type Decoded<T> = Result<T, GenerationFailure>;
type SchemaRegistry = BTreeMap<String, serde_json::Value>;

pub(crate) trait WireEncode {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error>;
}
impl<T: WireEncode + ?Sized> WireEncode for &T {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        T::serialize_wire(*self, serializer)
    }
}
trait WireDecode: WireEncode + Sized {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self>;
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value;
}
struct Wire<'a, T: ?Sized>(&'a T);
impl<T: WireEncode + ?Sized> Serialize for Wire<'_, T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize_wire(serializer)
    }
}

fn shape(path: &str, expected: &str) -> GenerationFailure {
    GenerationFailure::InvalidExchangeShape {
        path: path.to_owned(),
        expected: expected.to_owned(),
    }
}
fn field_path(path: &str, field: &str) -> String {
    format!("{path}.{field}")
}
fn fields<'a>(
    value: &'a ExchangeJson,
    path: &str,
    names: &[&str],
) -> Decoded<&'a [(String, ExchangeJson)]> {
    let members = match value {
        ExchangeJson::Obj(members) => members,
        _ => return Err(shape(path, "object")),
    };
    let mut seen = HashSet::with_capacity(members.len());
    for (name, _) in members {
        if !seen.insert(name) {
            return Err(shape(&field_path(path, name), "one member with this name"));
        }
        if !names.contains(&name.as_str()) {
            return Err(GenerationFailure::UnknownField {
                path: path.to_owned(),
                field: name.clone(),
            });
        }
    }
    if members.len() != names.len() {
        return Err(shape(path, &format!("exact fields: {}", names.join(","))));
    }
    Ok(members)
}
fn field<'a>(
    members: &'a [(String, ExchangeJson)],
    path: &str,
    name: &str,
) -> Decoded<&'a ExchangeJson> {
    members
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value)
        .ok_or_else(|| shape(&field_path(path, name), "required field"))
}
fn tag<'a>(value: &'a ExchangeJson, path: &str) -> Decoded<&'a str> {
    let members = match value {
        ExchangeJson::Obj(members) => members,
        _ => return Err(shape(path, "tagged object")),
    };
    match field(members, path, "tag")? {
        ExchangeJson::Str(tag) => Ok(tag),
        _ => Err(shape(&field_path(path, "tag"), "string tag")),
    }
}
fn signed_decimal(text: &str) -> bool {
    if text == "0" {
        return true;
    }
    let digits = text.strip_prefix('-').unwrap_or(text);
    matches!(digits.as_bytes().first(), Some(b'1'..=b'9'))
        && digits.bytes().all(|byte| byte.is_ascii_digit())
}
fn natural_decimal(text: &str) -> bool {
    !text.starts_with('-') && signed_decimal(text)
}
fn exact_decimal(text: &str) -> bool {
    !text.bytes().any(|byte| byte.is_ascii_whitespace())
        && text.parse::<serde_json::Number>().is_ok()
}
fn named_schema(
    registry: &mut SchemaRegistry,
    name: &str,
    build: impl FnOnce(&mut SchemaRegistry) -> serde_json::Value,
) -> serde_json::Value {
    let name = name.rsplit("::").next().unwrap_or(name);
    if !registry.contains_key(name) {
        registry.insert(name.to_owned(), serde_json::Value::Null);
        let schema = build(registry);
        registry.insert(name.to_owned(), schema);
    }
    serde_json::json!({"$ref": format!("#/$defs/{name}")})
}
fn object_schema(fields: Vec<(&str, serde_json::Value)>) -> serde_json::Value {
    let required: Vec<_> = fields.iter().map(|(name, _)| (*name).to_owned()).collect();
    let properties: serde_json::Map<_, _> = fields
        .into_iter()
        .map(|(name, value)| (name.to_owned(), value))
        .collect();
    serde_json::json!({"type":"object","properties":properties,"required":required,"additionalProperties":false})
}
fn tag_schema(name: &str) -> serde_json::Value {
    serde_json::json!({"const":name})
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
            _ => Err(shape(path, "string")),
        }
    }
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"string"})
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
            _ => Err(shape(path, "boolean")),
        }
    }
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"boolean"})
    }
}
impl WireEncode for BigInt {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}
impl WireDecode for BigInt {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        let text = match value {
            ExchangeJson::Str(text) => text,
            _ => return Err(shape(path, "canonical signed decimal string")),
        };
        if !signed_decimal(text) {
            return Err(GenerationFailure::InvalidInteger {
                path: path.to_owned(),
                text: text.clone(),
            });
        }
        BigInt::parse_bytes(text.as_bytes(), 10).ok_or_else(|| GenerationFailure::InvalidInteger {
            path: path.to_owned(),
            text: text.clone(),
        })
    }
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"string","pattern":"^(0|-?[1-9][0-9]*)$"})
    }
}
impl WireEncode for BigUint {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}
impl WireDecode for BigUint {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        let text = match value {
            ExchangeJson::Str(text) => text,
            _ => return Err(shape(path, "canonical natural decimal string")),
        };
        if !natural_decimal(text) {
            return Err(GenerationFailure::InvalidInteger {
                path: path.to_owned(),
                text: text.clone(),
            });
        }
        BigUint::parse_bytes(text.as_bytes(), 10).ok_or_else(|| GenerationFailure::InvalidInteger {
            path: path.to_owned(),
            text: text.clone(),
        })
    }
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"string","pattern":"^(0|[1-9][0-9]*)$"})
    }
}
macro_rules! native_natural {
    ($type:ty, $convert:ident) => {
        impl WireEncode for $type {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.collect_str(self)
            }
        }
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                let natural = BigUint::decode_wire(value, path)?;
                natural
                    .$convert()
                    .ok_or_else(|| GenerationFailure::UnrepresentableNatural {
                        path: path.to_owned(),
                        text: natural.to_string(),
                    })
            }
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                BigUint::json_schema(registry)
            }
        }
    };
}
native_natural!(usize, to_usize);
native_natural!(u32, to_u32);
native_natural!(u8, to_u8);

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
            _ => Err(shape(path, "array")),
        }
    }
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"array","items":T::json_schema(registry)})
    }
}
impl<T: WireEncode> WireEncode for Option<T> {
    fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Some(value) => value.serialize_wire(serializer),
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
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"anyOf":[{"type":"null"},T::json_schema(registry)]})
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
                [first, second] => Ok((
                    A::decode_wire(first, &format!("{path}[0]"))?,
                    B::decode_wire(second, &format!("{path}[1]"))?,
                )),
                _ => Err(shape(path, "two-element tuple")),
            },
            _ => Err(shape(path, "two-element tuple")),
        }
    }
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"array","prefixItems":[A::json_schema(registry),B::json_schema(registry)],"items":false,"minItems":2,"maxItems":2})
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
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                T::json_schema(registry)
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
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        String::json_schema(registry)
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
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        Vec::<String>::json_schema(registry)
    }
}

macro_rules! wire_key {
    ($name:ident) => {
        stringify!($name)
    };
    ($name:ident, $wire_name:literal) => {
        $wire_name
    };
}

macro_rules! wire_record {
    ($type:ty { $($name:ident: $field_type:ty $(=> $wire_name:literal)?),* $(,)? }) => {
        impl WireEncode for $type {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                let mut record = serializer.serialize_struct(stringify!($type), [$(wire_key!($name $(, $wire_name)?)),*].len())?;
                $(record.serialize_field(wire_key!($name $(, $wire_name)?), &Wire(&self.$name))?;)*
                record.end()
            }
        }
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                let members = fields(value, path, &[$(wire_key!($name $(, $wire_name)?)),*])?;
                Ok(Self { $($name: <$field_type>::decode_wire(field(members, path, wire_key!($name $(, $wire_name)?))?, &field_path(path, wire_key!($name $(, $wire_name)?)))?),* })
            }
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                named_schema(registry, stringify!($type), |registry| object_schema(vec![$((wire_key!($name $(, $wire_name)?), <$field_type>::json_schema(registry))),*]))
            }
        }
    };
}
macro_rules! wire_enum {
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
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                match tag(value, path)? {
                    $(stringify!($unit) => { fields(value, path, &["tag"])?; Ok(Self::$unit) },)*
                    $(stringify!($tuple) => {
                        let members = fields(value, path, &["tag", "value"])?;
                        Ok(Self::$tuple(<$tuple_type>::decode_wire(field(members, path, "value")?, &field_path(path, "value"))?))
                    },)*
                    $(stringify!($variant) => {
                        let members = fields(value, path, &["tag", "fields"])?;
                        let payload = field(members, path, "fields")?;
                        let path = field_path(path, "fields");
                        let members = fields(payload, &path, &[$(stringify!($name)),*])?;
                        Ok(Self::$variant { $($name: <$field_type>::decode_wire(field(members, &path, stringify!($name))?, &field_path(&path, stringify!($name)))?),* })
                    },)*
                    $($(stringify!($binary) => {
                        let members = fields(value, path, &["tag", "value"])?;
                        let (left, right) = <($left_type, $right_type)>::decode_wire(field(members, path, "value")?, &field_path(path, "value"))?;
                        Ok(Self::$binary(left, right))
                    },)*)?
                    other => Err(GenerationFailure::UnknownTag {
                        path: field_path(path, "tag"),
                        tag: other.to_owned(),
                    }),
                }
            }
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                named_schema(registry, stringify!($type), |_registry| serde_json::json!({"oneOf":[
                    $(object_schema(vec![("tag", tag_schema(stringify!($unit)))]),)*
                    $(object_schema(vec![("tag", tag_schema(stringify!($tuple))), ("value", <$tuple_type>::json_schema(_registry))]),)*
                    $(object_schema(vec![("tag", tag_schema(stringify!($variant))), ("fields", object_schema(vec![$((stringify!($name), <$field_type>::json_schema(_registry))),*]))]),)*
                    $($(object_schema(vec![("tag", tag_schema(stringify!($binary))), ("value", <($left_type, $right_type)>::json_schema(_registry))]),)*)?
                ]}))
            }
        }
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
        let (key, tag_name) = match tag(value, path)? {
            "Null" => {
                fields(value, path, &["tag"])?;
                return Ok(Self::Null);
            }
            "Bool" | "Integer" | "String" => ("value", tag(value, path)?),
            "Decimal" => ("text", "Decimal"),
            "Array" => ("items", "Array"),
            "Object" => ("members", "Object"),
            _ => return Err(shape(&field_path(path, "tag"), "ExactJson variant")),
        };
        let members = fields(value, path, &["tag", key])?;
        let value = field(members, path, key)?;
        let path = field_path(path, key);
        match tag_name {
            "Bool" => bool::decode_wire(value, &path).map(Self::Bool),
            "Integer" => BigInt::decode_wire(value, &path).map(Self::Num),
            "String" => String::decode_wire(value, &path).map(Self::Str),
            "Decimal" => {
                let text = String::decode_wire(value, &path)?;
                if !exact_decimal(&text) {
                    return Err(shape(&path, "exact JSON number spelling"));
                }
                Ok(Self::Dec(text))
            }
            "Array" => Vec::<JsonValue>::decode_wire(value, &path).map(Self::Arr),
            "Object" => {
                let rows = match value {
                    ExchangeJson::Arr(rows) => rows,
                    _ => return Err(shape(&path, "ordered member array")),
                };
                let mut result = Vec::with_capacity(rows.len());
                for (index, row) in rows.iter().enumerate() {
                    let path = format!("{path}[{index}]");
                    let members = fields(row, &path, &["key", "value"])?;
                    result.push((
                        String::decode_wire(
                            field(members, &path, "key")?,
                            &field_path(&path, "key"),
                        )?,
                        Self::decode_wire(
                            field(members, &path, "value")?,
                            &field_path(&path, "value"),
                        )?,
                    ));
                }
                Ok(Self::Obj(result))
            }
            _ => Err(shape(&path, "ExactJson variant")),
        }
    }
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        named_schema(registry, "ExactJson", |registry| {
            let nested = Self::json_schema(registry);
            serde_json::json!({"oneOf":[
                object_schema(vec![("tag",tag_schema("Null"))]),
                object_schema(vec![("tag",tag_schema("Bool")),("value",bool::json_schema(registry))]),
                object_schema(vec![("tag",tag_schema("Integer")),("value",BigInt::json_schema(registry))]),
                object_schema(vec![("tag",tag_schema("Decimal")),("text",serde_json::json!({"type":"string","pattern":"^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"}))]),
                object_schema(vec![("tag",tag_schema("String")),("value",String::json_schema(registry))]),
                object_schema(vec![("tag",tag_schema("Array")),("items",serde_json::json!({"type":"array","items":nested.clone()}))]),
                object_schema(vec![("tag",tag_schema("Object")),("members",serde_json::json!({"type":"array","items":object_schema(vec![("key",String::json_schema(registry)),("value",nested)])}))]),
            ]})
        })
    }
}

wire_record!(SourceIdentity {
    repository: String,
    revision: String,
    path: String,
    content_digest: String
});
wire_record!(Origin { source:SourceIdentity, locator:Vec<String> });
wire_record!(SourceRef { repository:String, revision:String, path:String, content_digest:String, document_id:String, declared_revision:Option<BigInt> });
wire_record!(ProfileRef {
    identity: String,
    revision: String,
    content_digest: String
});
wire_record!(TypeRef { source:Arc<SourceRef>, definition_name:Arc<str>, pointer:Arc<[String]> });
wire_record!(DefinitionRef { source:Arc<SourceRef>, name:Arc<str> });
wire_record!(OccurrenceRef { source:Arc<SourceRef>, pointer:Arc<[String]> });
wire_enum!(IntegerDomain; units [Unbounded]; tuples []; records [Inclusive { minimum:BigInt, maximum:BigInt }]);
wire_enum!(IntegerForm; units [Number,IntegralDecimal,DecimalString]; tuples []; records []);
wire_record!(IntegerDomainBinding { name:String, reference:ProfileRef, range:IntegerDomain, forms:Vec<IntegerForm> });
wire_record!(NumberModel { decimals: bool });
wire_enum!(BytesAlphabet; units [Standard,UrlSafe,Either]; tuples []; records []);
wire_enum!(StringLengthUnit; units [Utf8Bytes,UnicodeScalars,Graphemes]; tuples []; records []);
wire_record!(LengthBound { unit:StringLengthUnit, minimum:Option<BigUint>, maximum:Option<BigUint> });
wire_enum!(FormatUse; units []; tuples [Named(String),Inline(FormatRule)]; records []);
wire_enum!(GraphemeProperty; units [Other,Cr,Lf,Control,Extend,Zwj,RegionalIndicator,Prepend,SpacingMark,L,V,T,Lv,Lvt]; tuples []; records []);
wire_enum!(IndicProperty; units [Other,Consonant,Extend,Linker]; tuples []; records []);
wire_record!(CodepointRange {
    first: u32,
    last: u32
});
wire_record!(GraphemeRange {
    first: u32,
    last: u32,
    property: GraphemeProperty
});
wire_record!(IndicRange {
    first: u32,
    last: u32,
    property: IndicProperty
});
wire_record!(GraphemeComponent {
    unicode_version: String,
    uax29_revision: String,
    cluster_profile: String
});
wire_record!(GraphemeSource {
    role: String,
    origin: Origin
});
wire_record!(GraphemeRules { reference:ProfileRef,properties:Vec<GraphemeRange>,extended_pictographic:Vec<CodepointRange>,indic_conjunct:Vec<IndicRange>,component:GraphemeComponent,table_sha256:String,sources:Vec<GraphemeSource> });
wire_record!(BytesPolicy { reference:ProfileRef,padding_optional:bool,alphabet:BytesAlphabet,strict_pad_bits:bool,wrapper:Option<String> });
wire_record!(CalendarRule {
    allow_second_60: bool,
    minimum_year: BigUint,
    maximum_year: BigUint,
    reject_utc_year_outside_range: bool => "rejectUtcYearOutsideRange"
});
wire_record!(DfaTransition {
    from_state: BigUint,
    first: u8,
    last: u8,
    to_state: BigUint
});
wire_record!(DfaSpec { state_count:BigUint,initial_state:BigUint,accepting_states:Vec<BigUint>,transitions:Vec<DfaTransition> });
wire_enum!(FormatRule; units [Text]; tuples [Literal(String),Sequence(Vec<FormatRule>),Optional(Box<FormatRule>),AsciiDfa(DfaSpec),Timestamp(CalendarRule),Choice(Vec<FormatRule>),Not(Box<FormatRule>)]; records [Labels { separator:String,min_count:BigUint,max_count:Option<BigUint>,total_max:Option<BigUint>,rule:Box<FormatRule> },Bounded { unit:StringLengthUnit,maximum:BigUint,rule:Box<FormatRule> },Identifier { first_alphabet:String,rest_alphabet:String,exact_length:Option<BigUint>,min_length:BigUint,max_length:Option<BigUint>,forbidden:Vec<String> },AbsoluteUri { max_bytes:Option<BigUint> },LanguageTag { grandfathered:Vec<String> }]);
wire_record!(FormatBinding {
    name: String,
    reference: ProfileRef,
    rule: FormatRule
});
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
                fields(value, path, &["tag"])?;
                Ok(Self::Bytes)
            }
            "Text" => {
                let members = fields(value, path, &["tag", "value"])?;
                Ok(Self::Text {
                    format: Option::<String>::decode_wire(
                        field(members, path, "value")?,
                        &field_path(path, "value"),
                    )?,
                })
            }
            other => Err(GenerationFailure::UnknownTag {
                path: field_path(path, "tag"),
                tag: other.to_owned(),
            }),
        }
    }
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        named_schema(registry, "WrapperPayload", |registry| {
            serde_json::json!({"oneOf":[
                object_schema(vec![("tag",tag_schema("Bytes"))]),
                object_schema(vec![
                    ("tag",tag_schema("Text")),
                    ("value",Option::<String>::json_schema(registry))
                ])
            ]})
        })
    }
}
wire_record!(Wrapper {
    name: String,
    key: String,
    payload: WrapperPayload
});
wire_record!(BooleanSpec { const_value:Option<bool>,default_value:Option<bool> });
wire_record!(IntegerSpec { domain:Option<String>,minimum:Option<BigInt>,maximum:Option<BigInt>,const_value:Option<BigInt>,enum_values:Option<Vec<BigInt>>,default_value:Option<BigInt> });
wire_record!(DecimalBound {
    mantissa: BigInt,
    scale: BigUint,
    exclusive: bool
});
wire_record!(DecimalSpec { minimum:Option<DecimalBound>,maximum:Option<DecimalBound> });
wire_record!(StringSpec { format:Option<FormatUse>,lengths:Vec<LengthBound>,wrapper:Option<String>,const_value:Option<String>,enum_values:Option<Vec<String>>,examples:Vec<String>,default_value:Option<String> });
wire_enum!(SealedLeaf; units []; tuples [String(StringSpec),Integer(IntegerSpec)]; records []);
wire_record!(SealedField {
    key: String,
    required: bool,
    leaf: SealedLeaf
});
wire_enum!(SealedExtras; units [Reject,Any]; tuples []; records []);
wire_record!(SealedForm { tag:String,fields:Vec<SealedField>,extras:SealedExtras });
wire_record!(TagModel { key:String,format:Option<String>,sealed:Vec<SealedForm> });
wire_record!(SealedRefinement {
    key: String,
    leaf: SealedLeaf
});
wire_record!(VersionedSemanticProfile { reference:ProfileRef,source_refs:Vec<SourceIdentity>,integer_domains:Vec<IntegerDomainBinding>,default_integer_domain:String,numbers:NumberModel,grapheme_rules:Option<GraphemeRules>,format_bindings:Vec<FormatBinding>,bytes_policy:Option<BytesPolicy>,wrappers:Vec<Wrapper>,tag:Option<TagModel> });
wire_record!(SemanticGraph { profile:VersionedSemanticProfile,nodes:Vec<TypeNode>,source_refs:Vec<SourceRef> });
wire_record!(DefaultApplication {
    value_path: ValuePath,
    type_ref: TypeRef,
    origin: OccurrenceRef,
    value: JsonValue
});
wire_record!(LengthSpec { minimum:Option<BigUint>,maximum:Option<BigUint> });
wire_enum!(UnknownKind; units [Any,OrdinaryObject]; tuples []; records []);
wire_enum!(ValueKind; units [Null,Boolean,Number,String,Array,Object]; tuples []; records []);
wire_enum!(MemberTest; units [Absent]; tuples [Format(String)]; records []);
wire_enum!(BranchSelector; units [InternalTag,Otherwise]; tuples [MemberShape(Vec<(String,MemberTest)>),Kind(ValueKind)]; records []);
wire_record!(ValueSemanticProfile { reference:ProfileRef,source_refs:Vec<SourceIdentity>,integer_domains:Vec<IntegerDomainBinding>,default_integer_domain:String,numbers:NumberModel,grapheme_rules:Option<GraphemeRules>,format_bindings:Vec<FormatBinding>,wrappers:Vec<Wrapper>,tag:Option<TagModel>,bytes_policy:Option<BytesPolicy> });
wire_enum!(AnnotationTarget; units [Library]; tuples [Group(String),Definition(String),Type(String)]; records [Outcome { definition:String,outcome:String }]);
wire_record!(ProvenanceBinding { target:AnnotationTarget,origins:Vec<Origin> });
wire_record!(DefinitionGroup { id:String,members:Vec<String> });
wire_record!(Annotation {
    target: AnnotationTarget,
    key: String,
    value: JsonValue
});
wire_record!(SignatureSlot {
    type_id: String,
    required: bool,
    nullable: bool
});
wire_record!(SignatureField {
    wire_name: String,
    slot: SignatureSlot
});
wire_record!(SignatureElementContract {
    type_id: String,
    nullable: bool
});
wire_enum!(SignatureExtraMembers; units [Reject]; tuples []; records [Allow { key_format:Option<FormatUse>,value:SignatureElementContract }]);
wire_record!(SignatureProduct { fields:Vec<SignatureField>,extras:SignatureExtraMembers });
wire_record!(SignatureArray { item:SignatureElementContract,minimum:Option<BigUint> => "min_length",maximum:Option<BigUint> => "max_length" });
wire_record!(SignatureUnionBranch {
    target: String,
    wire_tag: String,
    selector: BranchSelector
});
wire_record!(SignatureUnion { branches:Vec<SignatureUnionBranch> });
wire_enum!(Shape; units [Unit,Never]; tuples [Unknown(UnknownKind),Boolean(BooleanSpec),Integer(IntegerSpec),Decimal(DecimalSpec),String(StringSpec),Bytes(LengthSpec),Product(SignatureProduct),Array(SignatureArray),TaggedUnion(SignatureUnion)]; records [Sealed { tag:String,refinements:Vec<SealedRefinement> },Alias { target:String },RawBody { encoding:String },Opaque { type_name:String }]);
wire_record!(TypeNodeInput {
    id: String,
    shape: Shape
});
wire_enum!(EffectPoint; units [HttpRequestResponse,DataOnly]; tuples []; records []);
wire_enum!(crate::type_signatures::OutcomeForm; units [Success,DeclaredFailure]; tuples []; records []);
wire_enum!(OutcomeCause; units []; tuples []; records [ValueContract { origin:Origin },ExternalCondition { specification:Origin }]);
wire_record!(SignaturePort {
    id: String,
    contract: SignatureSlot
});
wire_record!(SignatureResourceProduction {
    id: String,
    token_type: String,
    revision: BigUint,
    quantity: BigUint,
    provenance: String
});
wire_record!(SignatureOutcome { id:String,form:crate::type_signatures::OutcomeForm,cause:OutcomeCause,value_ports:Vec<SignaturePort>,produced_resources:Vec<SignatureResourceProduction> });
wire_record!(OperationContract { effect:EffectPoint,inputs:Vec<SignaturePort>,outcomes:Vec<SignatureOutcome> });
wire_enum!(SignatureDefinitionShape; units []; tuples [Value(String),Symbol(String),Operation(OperationContract),Message(String)]; records []);
wire_record!(DefinitionInput {
    id: String,
    wire_identity: String,
    shape: SignatureDefinitionShape
});
wire_record!(TypeSignatureLibrary { schema:String,identity:String,revision:String,profile:ValueSemanticProfile,sources:Vec<SourceIdentity>,provenance:Vec<ProvenanceBinding>,groups:Vec<DefinitionGroup>,annotations:Vec<Annotation>,nodes:Vec<TypeNodeInput>,definitions:Vec<DefinitionInput> });
wire_record!(SignatureGenerationBasis { signature_schema:String,library_identity:String,library_revision:String,profile:ProfileRef,graph_sha256:String,provenance_sha256:String,metadata_sha256:String,problem_sha256:Option<String>,entrypoints_sha256:String });
wire_record!(SignatureEntrypoint {
    identity: String,
    definition: String
});
wire_enum!(PathStep; units []; tuples [Field(String),Index(BigUint),Variant(String)]; records []);
wire_enum!(SlotValue; units [Absent,Null]; tuples [Present(JsonValue)]; records []);
wire_enum!(ValueCondition; units [MissingRequired,NullNotAllowed,ConstMismatch,EnumMismatch,BelowMinimum,AboveMaximum,IntegerDomain,StringLength,ArrayLength,BytesLength,InvalidBytes,InvalidTag,ReservedForm,NoBranchSelected,Uninhabited,InvalidDataModel,ReferenceCycle]; tuples [WrongValueKind(String),Format(String),InvalidWrapper(String),KeyFormat(String),DuplicateField(String),UnexpectedField(String)]; records []);
wire_record!(ValueFailure { type_ref:TypeRef,definition_ref:DefinitionRef,origin:OccurrenceRef,value_path:ValuePath,condition:ValueCondition,observed:SlotValue,reference_trace:Vec<TypeRef> });
wire_enum!(ProfilePredicate; units [Pr01,Pr02,Pr03,Pr04,Pr05,Pr06,Pr07,Pr08,Pr09,Pr10,Pr11,Pr12,Pr13,Pr14,Pr15,Pr16]; tuples []; records []);
wire_record!(ProfileFailure { reference:ProfileRef,predicate:ProfilePredicate,location:Vec<String> });
impl WireEncode for serde_json::Value {
    fn serialize_wire<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.serialize(s)
    }
}
impl WireDecode for serde_json::Value {
    fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
        serde_json::to_value(value).map_err(|_| shape(path, "json"))
    }
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({})
    }
}
wire_record!(SignatureComposition {
    problem: serde_json::Value,
    derivation: serde_json::Value
});
wire_record!(SignatureGenerationInput { schema:String,basis:SignatureGenerationBasis,signatures:Arc<TypeSignatureLibrary>,composition:Option<SignatureComposition>,entrypoints:Vec<SignatureEntrypoint> });
fn encode<T: WireEncode + ?Sized>(v: &T) -> Decoded<String> {
    serde_json::to_string(&Wire(v)).map_err(|e| GenerationFailure::Encoding(e.to_string()))
}
pub(crate) fn wire_value<T: WireEncode + ?Sized>(value: &T) -> Decoded<serde_json::Value> {
    serde_json::to_value(Wire(value))
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))
}
fn decode<T: WireDecode>(s: &str) -> Decoded<T> {
    let value: ExchangeJson =
        serde_json::from_str(s).map_err(|e| GenerationFailure::InvalidJson(e.to_string()))?;
    T::decode_wire(&value, "$")
}
pub fn encode_signature_generation(v: &SignatureGenerationInput) -> Decoded<String> {
    encode(v)
}
pub fn encode_checked_generation(v: &SignatureGenerationInput) -> Decoded<String> {
    encode(v)
}
fn require_schema(text: &str, expected: &str) -> Decoded<()> {
    let value: serde_json::Value = serde_json::from_str(text)
        .map_err(|failure| GenerationFailure::InvalidJson(failure.to_string()))?;
    let observed = value
        .get("schema")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    if observed == expected {
        Ok(())
    } else {
        Err(GenerationFailure::UnsupportedSchema {
            observed: observed.to_owned(),
        })
    }
}
pub fn decode_signature_generation(s: &str) -> Decoded<SignatureGenerationInput> {
    require_schema(s, "ncoh-checked-generation@4")?;
    let value: SignatureGenerationInput = decode(s)?;
    crate::type_signatures::check_library(&value.signatures).map_err(GenerationFailure::Library)?;
    Ok(value)
}
pub fn encode_type_signatures(v: &TypeSignatureLibrary) -> Decoded<String> {
    encode(v)
}
pub fn decode_type_signatures(s: &str) -> Decoded<TypeSignatureLibrary> {
    require_schema(s, "ncoh-type-signatures@1")?;
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

pub fn decode_semantic_graph(text: &str) -> Decoded<SemanticGraph> {
    let graph: SemanticGraph = decode(text)?;
    crate::semantic_validation::check_profile(&graph.profile)
        .map_err(GenerationFailure::Profile)?;
    Ok(graph)
}
pub fn encode_semantic_graph(graph: &SemanticGraph) -> Decoded<String> {
    encode(graph)
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
pub fn signature_generation_schema() -> serde_json::Value {
    let mut registry = SchemaRegistry::new();
    let root = SignatureGenerationInput::json_schema(&mut registry);
    serde_json::json!({"$schema":"https://json-schema.org/draft/2020-12/schema","root":root,"$defs":registry})
}
pub fn encode_diagnostic(value: &ValueFailure) -> Decoded<String> {
    encode(value)
}
pub fn decode_diagnostic(text: &str) -> Decoded<ValueFailure> {
    decode(text)
}
pub fn encode_signature_basis(v: &SignatureGenerationBasis) -> Decoded<String> {
    encode(v)
}
pub fn decode_signature_basis(s: &str) -> Decoded<SignatureGenerationBasis> {
    decode(s)
}
pub fn utf8_sha256(s: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(s.as_bytes()))
}

include!("signature_composition_wire.rs");
