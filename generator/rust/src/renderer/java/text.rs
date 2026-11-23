// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use crate::renderer::RenderFailure;
use serde_json::Value;

pub(super) type Result<T> = std::result::Result<T, RenderFailure>;

const KEYWORDS: &[&str] = &[
    "abstract",
    "assert",
    "boolean",
    "break",
    "byte",
    "case",
    "catch",
    "char",
    "class",
    "const",
    "continue",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extends",
    "final",
    "finally",
    "float",
    "for",
    "goto",
    "if",
    "implements",
    "import",
    "instanceof",
    "int",
    "interface",
    "long",
    "native",
    "new",
    "package",
    "private",
    "protected",
    "public",
    "return",
    "short",
    "static",
    "strictfp",
    "super",
    "switch",
    "synchronized",
    "this",
    "throw",
    "throws",
    "transient",
    "try",
    "void",
    "volatile",
    "while",
    "true",
    "false",
    "null",
    "record",
    "sealed",
    "permits",
    "yield",
    "var",
    "_",
];

pub(super) fn emission(message: impl Into<String>) -> RenderFailure {
    RenderFailure::JavaEmission(message.into())
}

pub(super) fn valid_target(package_name: &str, class_name: &str) -> bool {
    if !valid_identifier(class_name) {
        return false;
    }
    package_name.is_empty() || package_name.split('.').all(valid_identifier)
}

fn valid_identifier(name: &str) -> bool {
    !KEYWORDS.contains(&name) && is_java_identifier(name)
}

fn is_java_identifier(name: &str) -> bool {
    let mut characters = name.chars();
    match characters.next() {
        Some(first) if identifier_start(first) => characters.all(identifier_part),
        _ => false,
    }
}

fn identifier_start(character: char) -> bool {
    character.is_alphabetic() || character == '_' || character == '$'
}

fn identifier_part(character: char) -> bool {
    identifier_start(character) || character.is_numeric()
}

pub(super) fn identifier(text: &str) -> String {
    let mut out = String::new();
    for unit in text.encode_utf16() {
        let plain = matches!(unit, 0x41..=0x5a | 0x61..=0x7a | 0x24 | 0x5f)
            || (matches!(unit, 0x30..=0x39) && !out.is_empty());
        if plain {
            out.push(char::from(unit as u8));
        } else {
            out.push_str(&format!("_{unit:x}_"));
        }
    }
    if out.is_empty() {
        out.push_str("value");
    }
    if KEYWORDS.contains(&out.as_str()) {
        out.insert_str(0, "field_");
    }
    out
}

pub(super) fn prefix(text: &str) -> String {
    let mut out = String::new();
    let mut first = true;
    for character in text.chars() {
        if !character.is_ascii_alphanumeric() {
            first = true;
            continue;
        }
        if out.is_empty() && character.is_ascii_digit() {
            out.push('N');
        }
        out.push(if first {
            character.to_ascii_uppercase()
        } else {
            character
        });
        first = false;
    }
    if out.is_empty() {
        "Value".to_owned()
    } else {
        out
    }
}

pub(super) fn field_identifier(text: &str) -> String {
    let name = identifier(text);
    if matches!(
        name.as_str(),
        "extra"
            | "wire"
            | "encode"
            | "decode"
            | "decodeWithDefaults"
            | "fromWire"
            | "rawWire"
            | "of"
            | "validate"
            | "outcomeId"
            | "embeddingId"
            | "_memberOrder"
    ) {
        format!("field_{name}")
    } else {
        name
    }
}

pub(super) fn quote(text: &str) -> String {
    let mut out = String::from("\"");
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            control if (control as u32) < 32 => {
                out.push_str(&format!("\\u00{:02x}", control as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

pub(super) fn chunks(text: &str, limit: usize) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut units = 0;
    for character in text.chars() {
        let width = character.len_utf16();
        if units + width > limit {
            result.push(std::mem::take(&mut current));
            units = 0;
        }
        current.push(character);
        units += width;
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

pub(super) fn utf16_length(text: &str) -> usize {
    text.encode_utf16().count()
}

pub(super) fn line(buffer: &mut String, text: &str) {
    buffer.push_str(text);
    buffer.push('\n');
}

pub(super) fn collection(
    buffer: &mut String,
    counter: &mut usize,
    kind: &str,
    mutable: &str,
    freeze: &str,
    statements: &[String],
) -> String {
    let method = format!("_initialize{}", *counter);
    *counter += 1;
    let mut calls: Vec<String> = Vec::new();
    for group in statements.chunks(64) {
        let part = format!("{method}Part{}", calls.len());
        line(
            buffer,
            &format!("  private static void {part}({kind} value) {{"),
        );
        for statement in group {
            line(buffer, &format!("    {statement}"));
        }
        line(buffer, "  }");
        calls.push(format!("{part}(value);"));
    }
    let mut level = 0;
    while calls.len() > 64 {
        let mut parents = Vec::new();
        for group in calls.chunks(64) {
            let part = format!("{method}Level{level}Part{}", parents.len());
            line(
                buffer,
                &format!("  private static void {part}({kind} value) {{"),
            );
            for call in group {
                line(buffer, &format!("    {call}"));
            }
            line(buffer, "  }");
            parents.push(format!("{part}(value);"));
        }
        calls = parents;
        level += 1;
    }
    line(
        buffer,
        &format!("  private static {kind} {method}() {{ {kind} value={mutable};"),
    );
    for call in &calls {
        line(buffer, &format!("    {call}"));
    }
    line(buffer, &format!("    return {freeze}; }}"));
    format!("{method}()")
}

pub(super) fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value> {
    value
        .get(key)
        .ok_or_else(|| emission(format!("generated field {key}")))
}

pub(super) fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    field(value, key)?
        .as_str()
        .ok_or_else(|| emission(format!("generated text {key}")))
}

pub(super) fn list<'a>(value: &'a Value, key: &str) -> Result<&'a [Value]> {
    field(value, key)?
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| emission(format!("generated list {key}")))
}

pub(super) fn flag(value: &Value, key: &str) -> Result<bool> {
    field(value, key)?
        .as_bool()
        .ok_or_else(|| emission(format!("generated flag {key}")))
}

pub(super) fn tag(value: &Value) -> Result<&str> {
    text(value, "tag")
}

pub(super) fn wire_text(value: &Value) -> String {
    value.to_string()
}
