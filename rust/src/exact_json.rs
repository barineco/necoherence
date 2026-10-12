// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use std::fmt;

use num_bigint::BigInt;
use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::ser::{self, SerializeMap, SerializeSeq};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

const NUMBER_TOKEN: &str = "$serde_json::private::Number";

/// A JSON value with exact integers, decimal texts and ordered members.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Num(BigInt),
    Dec(String),
    Str(String),
    Arr(Vec<JsonValue>),
    Obj(Vec<(String, JsonValue)>),
}

impl Serialize for JsonValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            JsonValue::Null => serializer.serialize_unit(),
            JsonValue::Bool(value) => serializer.serialize_bool(*value),
            JsonValue::Num(value) => serialize_number(&value.to_string(), serializer),
            JsonValue::Dec(text) => serialize_number(text, serializer),
            JsonValue::Str(value) => serializer.serialize_str(value),
            JsonValue::Arr(items) => {
                let mut sequence = serializer.serialize_seq(Some(items.len()))?;
                for item in items {
                    sequence.serialize_element(item)?;
                }
                sequence.end()
            }
            JsonValue::Obj(members) => {
                let mut map = serializer.serialize_map(Some(members.len()))?;
                for (key, value) in members {
                    map.serialize_entry(key, value)?;
                }
                map.end()
            }
        }
    }
}

fn serialize_number<S: Serializer>(text: &str, serializer: S) -> Result<S::Ok, S::Error> {
    let number: serde_json::Number = text.parse().map_err(ser::Error::custom)?;
    number.serialize(serializer)
}

fn number_from_text<E: de::Error>(text: &str) -> Result<JsonValue, E> {
    if text.contains(['.', 'e', 'E']) {
        Ok(JsonValue::Dec(text.to_string()))
    } else {
        text.parse::<BigInt>()
            .map(JsonValue::Num)
            .map_err(de::Error::custom)
    }
}

struct JsonValueVisitor;

impl<'de> Visitor<'de> for JsonValueVisitor {
    type Value = JsonValue;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a JSON value")
    }

    fn visit_unit<E: de::Error>(self) -> Result<JsonValue, E> {
        Ok(JsonValue::Null)
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<JsonValue, E> {
        Ok(JsonValue::Bool(value))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<JsonValue, E> {
        Ok(JsonValue::Num(BigInt::from(value)))
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<JsonValue, E> {
        Ok(JsonValue::Num(BigInt::from(value)))
    }

    fn visit_i128<E: de::Error>(self, value: i128) -> Result<JsonValue, E> {
        Ok(JsonValue::Num(BigInt::from(value)))
    }

    fn visit_u128<E: de::Error>(self, value: u128) -> Result<JsonValue, E> {
        Ok(JsonValue::Num(BigInt::from(value)))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<JsonValue, E> {
        Ok(JsonValue::Str(value.to_string()))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<JsonValue, E> {
        Ok(JsonValue::Str(value))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<JsonValue, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = sequence.next_element::<JsonValue>()? {
            items.push(item);
        }
        Ok(JsonValue::Arr(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<JsonValue, A::Error> {
        let mut members: Vec<(String, JsonValue)> = Vec::new();
        while let Some(key) = map.next_key::<String>()? {
            if members.is_empty() && key == NUMBER_TOKEN {
                let text: String = map.next_value()?;
                return number_from_text(&text);
            }
            let value = map.next_value::<JsonValue>()?;
            members.push((key, value));
        }
        Ok(JsonValue::Obj(members))
    }
}

impl<'de> Deserialize<'de> for JsonValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<JsonValue, D::Error> {
        deserializer.deserialize_any(JsonValueVisitor)
    }
}
