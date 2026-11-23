// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

//! The wire text beside the exact input of the default materialization, in the order of `evaluateDecoded`
//! in `verification/lean/DefaultMaterializationCompare.lean`.

use necoherence::exact_json::{bounded_json_parse, decimal_spelling, JsonValue};
use std::collections::{BTreeMap, HashSet};

/// A failure of the wire text beside the exact input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireTextFailure {
    /// The exact input has a duplicate object key, so the wire text is not read.
    DuplicateField,
    /// The wire text is not admitted by the text entry, including a duplicate object key at the parse.
    Syntax,
    /// The wire text spells a value other than the exact input.
    Differs,
    /// The exact input or the wire value cannot be spelled.
    Spelling(String),
}

/// Whether every object of the value has unique member keys at every depth.
pub fn unique_members(value: &JsonValue) -> bool {
    match value {
        JsonValue::Arr(items) => items.iter().all(unique_members),
        JsonValue::Obj(members) => {
            let mut keys = HashSet::new();
            members.iter().all(|(key, _)| keys.insert(key.as_str()))
                && members.iter().all(|(_, member)| unique_members(member))
        }
        _ => true,
    }
}

/// The spelling of a value under `ExactJson.toJson` and `compressJson`, with the object members in key order.
#[derive(Debug, PartialEq, Eq)]
enum Spelled {
    Null,
    Bool(bool),
    Integer(String),
    Decimal(String),
    Str(String),
    Arr(Vec<Spelled>),
    Obj(BTreeMap<String, Spelled>),
}

fn spelled(value: &JsonValue) -> Result<Spelled, WireTextFailure> {
    Ok(match value {
        JsonValue::Null => Spelled::Null,
        JsonValue::Bool(value) => Spelled::Bool(*value),
        JsonValue::Num(value) => Spelled::Integer(value.to_string()),
        JsonValue::Dec(text) => Spelled::Decimal(decimal_spelling(text).ok_or_else(|| {
            WireTextFailure::Spelling(format!("number is not representable: {text}"))
        })?),
        JsonValue::Str(value) => Spelled::Str(value.clone()),
        JsonValue::Arr(items) => {
            Spelled::Arr(items.iter().map(spelled).collect::<Result<Vec<_>, _>>()?)
        }
        JsonValue::Obj(members) => {
            let mut map = BTreeMap::new();
            for (key, member) in members {
                map.insert(key.clone(), spelled(member)?);
            }
            Spelled::Obj(map)
        }
    })
}

/// Checks a wire text against the exact input: the exact input must have unique keys, the wire text must pass the
/// text entry, and the wire value must spell the same as the exact input.
pub fn check_wire_text(before: &JsonValue, text: &str) -> Result<(), WireTextFailure> {
    if !unique_members(before) {
        return Err(WireTextFailure::DuplicateField);
    }
    let wire = bounded_json_parse(text).map_err(|_| WireTextFailure::Syntax)?;
    if spelled(&wire)? != spelled(before)? {
        return Err(WireTextFailure::Differs);
    }
    Ok(())
}
