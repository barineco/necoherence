// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::wire::{field, list, text, Result};
use serde_json::Value;

pub(super) fn quote(value: &str) -> String {
    let mut body = String::new();
    for character in value.chars() {
        let code = character as u32;
        match character {
            '\\' => body.push_str("\\\\"),
            '"' => body.push_str("\\\""),
            '\n' => body.push_str("\\n"),
            '\r' => body.push_str("\\r"),
            '\t' => body.push_str("\\t"),
            _ if code < 0x20 || code == 0x7f => body.push_str(&format!("\\u{{{code:X}}}")),
            _ => body.push(character),
        }
    }
    format!("\"{body}\"")
}

pub(super) fn boolean(value: bool) -> &'static str {
    if value {
        "True"
    } else {
        "False"
    }
}

pub(super) fn lower(name: &str) -> String {
    name.to_lowercase()
}

pub(super) fn ref_name(name: &str) -> String {
    format!("ref_{}", lower(name))
}

fn ascii_alphanumeric(code: u32) -> bool {
    matches!(code, 0x30..=0x39 | 0x41..=0x5a | 0x61..=0x7a)
}

fn padded_hex(value: u32, width: usize) -> String {
    format!("{value:0width$x}")
}

fn identifier_tokens(value: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut extras = Vec::new();
    for character in value.chars() {
        let code = character as u32;
        if ascii_alphanumeric(code) {
            current.push(character);
        } else if code > 0x7f {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            tokens.push(format!("u{}", padded_hex(code, 6)));
        } else {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            extras.push(format!("x{}", padded_hex(code, 2)));
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    if tokens.is_empty() {
        extras
    } else {
        tokens
    }
}

fn upper_token(token: &str) -> String {
    let mut characters = token.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

pub(super) fn upper_identifier(identity: &str, role: &str) -> String {
    let rendered: String = identifier_tokens(identity)
        .iter()
        .map(|token| upper_token(token))
        .collect();
    if rendered.starts_with(|character: char| character.is_ascii_digit()) {
        format!("{role}{rendered}")
    } else {
        rendered
    }
}

const GLEAM_KEYWORDS: &[&str] = &[
    "as",
    "assert",
    "auto",
    "case",
    "const",
    "delegate",
    "derive",
    "echo",
    "else",
    "fn",
    "if",
    "implement",
    "import",
    "let",
    "macro",
    "opaque",
    "panic",
    "pub",
    "test",
    "todo",
    "type",
    "use",
];

pub(super) fn lower_identifier(identity: &str, role: &str) -> String {
    let rendered = identifier_tokens(identity)
        .iter()
        .map(|token| lower(token))
        .collect::<Vec<_>>()
        .join("_");
    if rendered.starts_with(|character: char| character.is_ascii_digit())
        || GLEAM_KEYWORDS.contains(&rendered.as_str())
    {
        format!("{role}_{rendered}")
    } else {
        rendered
    }
}

fn type_identity(reference: &Value) -> Result<String> {
    let definition_name = text(reference, "definition_name")?;
    let pointer: Vec<&str> = list(reference, "pointer")?
        .iter()
        .map(|item| item.as_str().unwrap_or_default())
        .collect();
    let relative = match pointer.split_first() {
        Some((first, rest)) if *first == definition_name => rest,
        _ => pointer.as_slice(),
    };
    let mut parts = vec![definition_name];
    parts.extend(relative.iter().copied());
    Ok(parts.join("."))
}

pub(super) fn type_name_of(reference: &Value) -> Result<String> {
    Ok(upper_identifier(&type_identity(reference)?, "Type"))
}

pub(super) fn reference_literal(reference: &Value) -> Result<String> {
    let source = field(reference, "source")?;
    let declared = match field(source, "declared_revision")? {
        Value::Null => "None".to_owned(),
        value => format!("Some({})", super::wire::scalar_text(value)?),
    };
    let pointer: Vec<String> = list(reference, "pointer")?
        .iter()
        .map(|item| quote(item.as_str().unwrap_or_default()))
        .collect();
    Ok(format!(
        "types.TypeRef(types.SourceRef({}, {}, {}, {}, {}, {}), {}, [{}])",
        quote(text(source, "repository")?),
        quote(text(source, "revision")?),
        quote(text(source, "path")?),
        quote(text(source, "content_digest")?),
        quote(text(source, "document_id")?),
        declared,
        quote(text(reference, "definition_name")?),
        pointer.join(", ")
    ))
}

pub(super) struct Names {
    entries: Vec<(Value, String)>,
}

impl Names {
    pub(super) fn new(nodes: &[Value]) -> Result<Self> {
        let entries = nodes
            .iter()
            .map(|node| {
                let reference = field(node, "reference")?;
                Ok((reference.clone(), type_name_of(reference)?))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self { entries })
    }

    pub(super) fn by_id(&self, id: &str) -> Result<&str> {
        let mut matches = self.entries.iter().filter(|(reference, _)| {
            reference.get("definition_name").and_then(Value::as_str) == Some(id)
        });
        let (_, name) = matches
            .next()
            .ok_or_else(|| super::wire::invalid("generated type reference"))?;
        if matches.next().is_some() {
            return Err(super::wire::invalid("generated type identity"));
        }
        Ok(name.as_str())
    }

    pub(super) fn name(&self, reference: &Value) -> Result<&str> {
        self.entries
            .iter()
            .find(|(candidate, _)| candidate == reference)
            .map(|(_, name)| name.as_str())
            .ok_or_else(|| super::wire::invalid("generated type reference"))
    }
}
