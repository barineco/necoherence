// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use crate::renderer::RenderFailure;
use serde_json::Value;

pub(super) type Result<T> = std::result::Result<T, RenderFailure>;

pub(super) fn invalid(message: &str) -> RenderFailure {
    RenderFailure::InvalidCheckedPlan(message.into())
}

pub(super) fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value> {
    value
        .get(key)
        .ok_or_else(|| invalid(&format!("generated field {key}")))
}

pub(super) fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    field(value, key)?
        .as_str()
        .ok_or_else(|| invalid("generated text"))
}

pub(super) fn list<'a>(value: &'a Value, key: &str) -> Result<&'a [Value]> {
    field(value, key)?
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| invalid("generated list"))
}

pub(super) fn flag(value: &Value, key: &str) -> Result<bool> {
    field(value, key)?
        .as_bool()
        .ok_or_else(|| invalid("generated flag"))
}

pub(super) fn tag(value: &Value) -> Result<&str> {
    text(value, "tag")
}

pub(super) fn scalar_text(value: &Value) -> Result<String> {
    match value {
        Value::String(text) => Ok(text.clone()),
        Value::Number(number) => Ok(number.to_string()),
        _ => Err(invalid("generated scalar")),
    }
}
