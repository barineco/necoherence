// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

//! 交換形式の JSON Schema の生成。

use necoherence::semantic_composition::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::DefaultApplication;
use necoherence::type_signatures::*;
use necoherence::typed_mapping as resource;
use num_bigint::{BigInt, BigUint};
use std::collections::BTreeMap;
use std::sync::Arc;

type SchemaRegistry = BTreeMap<String, serde_json::Value>;

pub trait WireSchema {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value;
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
        impl WireSchema for $type {
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                named_schema(registry, stringify!($type), |registry| object_schema(vec![$((wire_key!($name $(, $wire_name)?), <$field_type>::json_schema(registry))),*]))
            }
        }
    };
}

macro_rules! wire_enum {
    ($type:ty; units [$($unit:ident),* $(,)?]; tuples [$($tuple:ident($tuple_type:ty)),* $(,)?]; records [$($variant:ident { $($name:ident: $field_type:ty),* $(,)? }),* $(,)?] $(; binary [$($binary:ident($left_type:ty, $right_type:ty)),* $(,)?])?) => {
        impl WireSchema for $type {
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

macro_rules! wire_enum_prefixed {
    ($($definition:tt)*) => {
        wire_enum!($($definition)*);
    };
}

macro_rules! pointer_schema {
    ($pointer:ident) => {
        impl<T: WireSchema> WireSchema for $pointer<T> {
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                T::json_schema(registry)
            }
        }
    };
}
pointer_schema!(Arc);
pointer_schema!(Box);

macro_rules! wire_identifier {
    ($($type:ty),* $(,)?) => { $(
        impl WireSchema for $type {
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                String::json_schema(registry)
            }
        }
    )* };
}

include!("../../../packages/rust/adapter/src/wire_declarations.rs");

impl WireSchema for String {
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"string"})
    }
}

impl WireSchema for bool {
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"boolean"})
    }
}

impl WireSchema for BigInt {
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"string","pattern":"^(0|-?[1-9][0-9]*)$"})
    }
}

impl WireSchema for BigUint {
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"string","pattern":"^(0|[1-9][0-9]*)$"})
    }
}

impl<T: WireSchema> WireSchema for Vec<T> {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"array","items":T::json_schema(registry)})
    }
}

impl<T: WireSchema> WireSchema for Option<T> {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"anyOf":[{"type":"null"},T::json_schema(registry)]})
    }
}

impl<A: WireSchema, B: WireSchema> WireSchema for (A, B) {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({"type":"array","prefixItems":[A::json_schema(registry),B::json_schema(registry)],"items":false,"minItems":2,"maxItems":2})
    }
}

impl WireSchema for Arc<str> {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        String::json_schema(registry)
    }
}

impl WireSchema for Arc<[String]> {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        Vec::<String>::json_schema(registry)
    }
}

impl WireSchema for JsonValue {
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

impl WireSchema for WrapperPayload {
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

impl WireSchema for BranchSelector {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        named_schema(registry, "BranchSelector", |registry| {
            let member_check = object_schema(vec![
                ("key", String::json_schema(registry)),
                ("test", MemberTest::json_schema(registry)),
            ]);
            serde_json::json!({"oneOf":[
                object_schema(vec![("tag", tag_schema("InternalTag"))]),
                object_schema(vec![("tag", tag_schema("Otherwise"))]),
                object_schema(vec![("tag", tag_schema("MemberShape")), ("value", serde_json::json!({"type":"array","items":member_check}))]),
                object_schema(vec![("tag", tag_schema("Kind")), ("value", ValueKind::json_schema(registry))]),
            ]})
        })
    }
}

impl WireSchema for serde_json::Value {
    fn json_schema(_: &mut SchemaRegistry) -> serde_json::Value {
        serde_json::json!({})
    }
}

impl WireSchema for GoalObservations {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        named_schema(registry, "GoalObservations", |_| {
            object_schema(
                [
                    "outputs",
                    "failures",
                    "final_resources",
                    "effects",
                    "residuals",
                    "execution_failures",
                    "provenance",
                ]
                .into_iter()
                .map(|name| (name, serde_json::json!({})))
                .collect(),
            )
        })
    }
}

impl WireSchema for TypeObligation {
    fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
        named_schema(registry, "TypeObligation", |registry| {
            object_schema(vec![
                ("source", TypeRef::json_schema(registry)),
                ("destination", TypeRef::json_schema(registry)),
                ("reason", TypeObligationReason::json_schema(registry)),
            ])
        })
    }
}

pub fn signature_generation_schema() -> serde_json::Value {
    let mut registry = SchemaRegistry::new();
    let root = SignatureGenerationInput::json_schema(&mut registry);
    serde_json::json!({"$schema":"https://json-schema.org/draft/2020-12/schema","root":root,"$defs":registry})
}
