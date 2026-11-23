// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::utf8_sha256;
use serde_json::Value;

const KEYWORDS: &[&str] = &[
    "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
    "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
    "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
    "with", "yield",
];

const RESERVED: &[&str] = &[
    "extras",
    "decode",
    "encode",
    "examples",
    "__post_init__",
    "__dict__",
    "__class__",
    "__weakref__",
    "_present_members",
    "_dataclass_field",
];

pub(super) fn identifier(text: &str) -> String {
    let mut result: String = text
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect();
    if !result
        .chars()
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic() || character == '_')
    {
        result = format!("value_{result}");
    }
    if KEYWORDS.contains(&result.as_str()) || RESERVED.contains(&result.as_str()) {
        result.push_str("_field");
    }
    result
}

pub(super) fn digest(text: &str, length: usize) -> String {
    utf8_sha256(text).chars().take(length).collect()
}

pub(super) fn qualified(identity: &str) -> String {
    format!("T_{}_{}", identifier(identity), digest(identity, 12))
}

pub(super) fn title(text: &str) -> String {
    let mut previous_cased = false;
    text.chars()
        .map(|character| {
            let output = if previous_cased {
                character.to_ascii_lowercase()
            } else {
                character.to_ascii_uppercase()
            };
            previous_cased = character.is_ascii_alphabetic();
            output
        })
        .collect()
}

pub(super) fn text_literal(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut output = String::from(quote);
    for character in text.chars() {
        match character {
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character == quote => {
                output.push('\\');
                output.push(character);
            }
            character if (character as u32) < 0x20 || character as u32 == 0x7f => {
                output.push_str(&format!("\\x{:02x}", character as u32));
            }
            character => output.push(character),
        }
    }
    output.push(quote);
    output
}

pub(super) fn json_literal(value: &Value) -> String {
    format!("json.loads({})", text_literal(&value.to_string()))
}

pub(super) fn json_tuple_literal(value: &Value) -> String {
    format!("tuple({})", json_literal(value))
}

pub(super) fn tuple_literal(items: &[String]) -> String {
    match items {
        [only] => format!("({only},)"),
        _ => format!("({})", items.join(", ")),
    }
}

pub(super) fn dict_literal(entries: &[(String, String)]) -> String {
    let items: Vec<String> = entries
        .iter()
        .map(|(key, value)| format!("{key}: {value}"))
        .collect();
    format!("{{{}}}", items.join(", "))
}

pub(super) fn optional_text_literal(value: Option<&Value>) -> String {
    match value.and_then(Value::as_str) {
        Some(text) => text_literal(text),
        None => "None".to_owned(),
    }
}

pub(super) fn python_bool(value: bool) -> &'static str {
    if value {
        "True"
    } else {
        "False"
    }
}
