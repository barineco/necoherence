// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use num_bigint::{BigInt, BigUint};
use serde::ser::{self, SerializeMap, SerializeSeq};
use serde::{Serialize, Serializer};
use std::collections::HashMap;

use crate::exact_json_view::JsonValueView;

/// A JSON value with exact integers, decimal texts and ordered members.
#[derive(Debug, Eq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Num(BigInt),
    Dec(String),
    Str(String),
    Arr(Vec<JsonValue>),
    Obj(Vec<(String, JsonValue)>),
}

impl PartialEq for JsonValue {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (JsonValue::Null, JsonValue::Null) => true,
            (JsonValue::Bool(left), JsonValue::Bool(right)) => left == right,
            (JsonValue::Num(left), JsonValue::Num(right)) => left == right,
            (JsonValue::Dec(left), JsonValue::Dec(right)) => left == right,
            (JsonValue::Str(left), JsonValue::Str(right)) => left == right,
            (JsonValue::Arr(left), JsonValue::Arr(right)) => left == right,
            (JsonValue::Obj(left), JsonValue::Obj(right)) if left.len() != right.len() => false,
            (JsonValue::Obj(left), JsonValue::Obj(right)) if left.len() <= MEMBER_SCAN_LIMIT => {
                left.iter().all(|(key, value)| {
                    right
                        .iter()
                        .any(|(other_key, other_value)| other_key == key && other_value == value)
                })
            }
            (JsonValue::Obj(left), JsonValue::Obj(right)) => {
                let mut values: HashMap<&str, Vec<&JsonValue>> =
                    HashMap::with_capacity(right.len());
                for (key, value) in right {
                    values.entry(key.as_str()).or_default().push(value);
                }
                left.iter().all(|(key, value)| {
                    values
                        .get(key.as_str())
                        .is_some_and(|candidates| candidates.contains(&value))
                })
            }
            _ => false,
        }
    }
}

const MEMBER_SCAN_LIMIT: usize = 16;

fn first_member<'v>(members: &'v [(String, JsonValue)]) -> impl Fn(&str) -> Option<&'v JsonValue> {
    let index: Option<HashMap<&str, &JsonValue>> = (members.len() > MEMBER_SCAN_LIMIT).then(|| {
        let mut index = HashMap::with_capacity(members.len());
        for (key, value) in members {
            index.entry(key.as_str()).or_insert(value);
        }
        index
    });
    move |key| match &index {
        Some(index) => index.get(key).copied(),
        None => members
            .iter()
            .find(|(other, _)| other == key)
            .map(|(_, value)| value),
    }
}

pub fn same_json(left: &JsonValue, right: &JsonValue) -> bool {
    match (left, right) {
        (JsonValue::Obj(left), JsonValue::Obj(right)) => {
            left.len() == right.len() && {
                let other = first_member(right);
                left.iter()
                    .all(|(key, value)| other(key).is_some_and(|other| same_json(value, other)))
            }
        }
        (JsonValue::Num(left), JsonValue::Num(right)) => left == right,
        (JsonValue::Arr(left), JsonValue::Arr(right)) => {
            left.len() == right.len() && left.iter().zip(right).all(|(a, b)| same_json(a, b))
        }
        _ => match (canonical_number_text(left), canonical_number_text(right)) {
            (Some(left), Some(right)) => left == right,
            _ => left == right,
        },
    }
}

/// The number text that the Lean `canonicalJson` writes, so that an integer and a decimal of the same value compare equal as in Lean `sameJson`.
fn canonical_number_text(value: &JsonValue) -> Option<String> {
    match value {
        JsonValue::Num(integer) => Some(integer.to_string()),
        JsonValue::Dec(text) => LeanNumber::parse(text).map(|number| number.canonical_text()),
        _ => None,
    }
}

pub fn json_size(value: &JsonValue) -> usize {
    JsonValueView::from_json(value).size()
}

impl Serialize for JsonValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        crate::stack_growth::grow(|| self.serialize_value(serializer))
    }
}

impl JsonValue {
    fn serialize_value<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            JsonValue::Null => serializer.serialize_unit(),
            JsonValue::Bool(value) => serializer.serialize_bool(*value),
            JsonValue::Num(value) => serialize_number(&value.to_string(), serializer),
            JsonValue::Dec(text) => serialize_decimal(text, serializer),
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

fn serialize_decimal<S: Serializer>(text: &str, serializer: S) -> Result<S::Ok, S::Error> {
    if text_admission_failure(text) == Some(EXPONENT_TOO_LARGE) {
        return Err(ser::Error::custom(EXPONENT_TOO_LARGE));
    }
    let spelling =
        decimal_spelling(text).ok_or_else(|| ser::Error::custom("number is not representable"))?;
    serialize_number(&spelling, serializer)
}

pub(crate) struct LeanNumber {
    mantissa: BigInt,
    exponent: BigUint,
}

impl LeanNumber {
    pub(crate) fn parse(text: &str) -> Option<Self> {
        let (negative, unsigned) = match text.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, text),
        };
        let (significand, exponent_text) = match unsigned.split_once(['e', 'E']) {
            Some((significand, exponent_text)) => (significand, Some(exponent_text)),
            None => (unsigned, None),
        };
        let (whole, fraction) = match significand.split_once('.') {
            Some((whole, fraction)) => (whole, Some(fraction)),
            None => (significand, None),
        };
        let digits = format!("{whole}{}", fraction.unwrap_or_default());
        let magnitude = BigUint::parse_bytes(digits.as_bytes(), 10)?;
        let mantissa = if negative {
            -BigInt::from(magnitude)
        } else {
            BigInt::from(magnitude)
        };
        let places = fraction.map_or(0, str::len);
        let mut number = Self {
            mantissa,
            exponent: BigUint::from(places),
        };
        if let Some(exponent_text) = exponent_text {
            if exponent_digits_reach_limit(
                exponent_text
                    .strip_prefix(['-', '+'])
                    .unwrap_or(exponent_text)
                    .chars()
                    .map_while(|c| c.to_digit(10)),
            ) {
                return None;
            }
            match exponent_text.strip_prefix('-') {
                Some(shift) => {
                    number.exponent += BigUint::parse_bytes(shift.as_bytes(), 10)?;
                }
                None => {
                    let shift = BigUint::parse_bytes(
                        exponent_text
                            .strip_prefix('+')
                            .unwrap_or(exponent_text)
                            .as_bytes(),
                        10,
                    )?;
                    if shift >= number.exponent {
                        let padding = u32::try_from(&shift - &number.exponent).ok()?;
                        number.mantissa *= BigInt::from(10u8).pow(padding);
                        number.exponent = BigUint::default();
                    } else {
                        number.exponent -= shift;
                    }
                }
            }
        }
        Some(number)
    }

    pub(crate) fn has_places(&self) -> bool {
        self.exponent != BigUint::default()
    }

    pub(crate) fn into_integer(self) -> BigInt {
        self.mantissa
    }

    pub(crate) fn is_zero(&self) -> bool {
        self.mantissa == BigInt::default()
    }

    pub(crate) fn text(&self) -> String {
        if !self.has_places() {
            return self.mantissa.to_string();
        }
        let sign = if self.mantissa < BigInt::default() {
            "-"
        } else {
            ""
        };
        let magnitude = self.mantissa.magnitude();
        let bound = 9 + magnitude.to_string().len();
        let (places, compression) = match usize::try_from(&self.exponent) {
            Ok(places) if places <= bound => (places, None),
            _ => (
                bound,
                Some(BigInt::from(bound) - BigInt::from(self.exponent.clone())),
            ),
        };
        let unit = BigUint::from(10u8).pow(places as u32);
        let left = magnitude / &unit;
        let remainder = magnitude % &unit;
        if remainder == BigUint::default() && compression.is_none() {
            return format!("{sign}{left}");
        }
        let right = (&unit + remainder).to_string();
        let right = right[1..].trim_end_matches('0');
        let exponent =
            compression.map_or_else(String::new, |compression| format!("e{compression}"));
        format!("{sign}{left}.{right}{exponent}")
    }

    pub(crate) fn canonical_text(&self) -> String {
        if self.is_zero() {
            "0".to_owned()
        } else {
            self.text()
        }
    }

    fn spelling(&self) -> Option<String> {
        let scale = BigInt::from(10u8).pow(u32::try_from(&self.exponent).ok()?);
        let quotient = &self.mantissa / &scale;
        if &quotient * &scale == self.mantissa {
            Some(format!("{quotient}.0"))
        } else {
            Some(self.text())
        }
    }
}

fn number_from_text(text: &str) -> Result<JsonValue, String> {
    let number = LeanNumber::parse(text).ok_or_else(|| "number is not representable".to_owned())?;
    Ok(if number.has_places() {
        JsonValue::Dec(number.canonical_text())
    } else {
        JsonValue::Num(number.into_integer())
    })
}

/// The spelling of a decimal text as the exact JSON encoder writes it.
pub fn decimal_spelling(text: &str) -> Option<String> {
    LeanNumber::parse(text)?.spelling()
}

/// Parses a text at the text entry: an admission failure first, then a strict parse that rejects duplicate keys.
pub fn bounded_json_parse(text: &str) -> Result<JsonValue, String> {
    if let Some(message) = text_admission_failure(text) {
        return Err(message.to_owned());
    }
    parse_json_text(text)
}

pub fn parse_json_text(text: &str) -> Result<JsonValue, String> {
    let mut reader = LexicalReader { text, position: 0 };
    reader.skip_whitespace();
    let value = reader.value()?;
    reader.skip_whitespace();
    if reader.position == text.len() {
        Ok(value)
    } else {
        Err(reader.failure("end of input expected"))
    }
}

struct LexicalReader<'a> {
    text: &'a str,
    position: usize,
}

impl LexicalReader<'_> {
    fn failure(&self, message: &str) -> String {
        format!("{message} at byte {}", self.position)
    }

    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.position).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.position += 1;
        }
    }

    fn value(&mut self) -> Result<JsonValue, String> {
        match self.peek() {
            Some(b'{') => crate::stack_growth::grow(|| self.object()),
            Some(b'[') => crate::stack_growth::grow(|| self.array()),
            Some(b'"') => self.string().map(JsonValue::Str),
            Some(b't') => self.literal("true", JsonValue::Bool(true)),
            Some(b'f') => self.literal("false", JsonValue::Bool(false)),
            Some(b'n') => self.literal("null", JsonValue::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err(self.failure("expected a JSON value")),
        }
    }

    fn object(&mut self) -> Result<JsonValue, String> {
        self.position += 1;
        self.skip_whitespace();
        let mut members: Vec<(String, JsonValue)> = Vec::new();
        let mut keys: std::collections::HashSet<String> = std::collections::HashSet::new();
        if self.peek() == Some(b'}') {
            self.position += 1;
            return Ok(JsonValue::Obj(members));
        }
        loop {
            if self.peek() != Some(b'"') {
                return Err(self.failure("expected an object key"));
            }
            let key = self.string()?;
            if !keys.insert(key.clone()) {
                return Err(format!("duplicate object key: {key}"));
            }
            self.skip_whitespace();
            if self.peek() != Some(b':') {
                return Err(self.failure("expected a colon"));
            }
            self.position += 1;
            self.skip_whitespace();
            let value = self.value()?;
            members.push((key, value));
            self.skip_whitespace();
            match self.peek() {
                Some(b',') => {
                    self.position += 1;
                    self.skip_whitespace();
                }
                Some(b'}') => {
                    self.position += 1;
                    break;
                }
                _ => return Err(self.failure("object separator")),
            }
        }
        members.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(JsonValue::Obj(members))
    }

    fn array(&mut self) -> Result<JsonValue, String> {
        self.position += 1;
        self.skip_whitespace();
        let mut items = Vec::new();
        if self.peek() == Some(b']') {
            self.position += 1;
            return Ok(JsonValue::Arr(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_whitespace();
            match self.peek() {
                Some(b',') => {
                    self.position += 1;
                    self.skip_whitespace();
                }
                Some(b']') => {
                    self.position += 1;
                    break;
                }
                _ => return Err(self.failure("array separator")),
            }
        }
        Ok(JsonValue::Arr(items))
    }

    fn string(&mut self) -> Result<String, String> {
        let text = self.text;
        self.position += 1;
        let mut out = String::new();
        loop {
            let Some(character) = text
                .get(self.position..)
                .and_then(|rest| rest.chars().next())
            else {
                return Err(self.failure("unterminated string"));
            };
            self.position += character.len_utf8();
            match character {
                '"' => return Ok(out),
                '\\' => out.push(self.escape()?),
                control if u32::from(control) < 0x20 => {
                    return Err(self.failure("control character in string"));
                }
                _ => out.push(character),
            }
        }
    }

    fn escape(&mut self) -> Result<char, String> {
        let Some(byte) = self.peek() else {
            return Err(self.failure("unterminated escape"));
        };
        self.position += 1;
        Ok(match byte {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{8}',
            b'f' => '\u{c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => return self.unicode_escape(),
            _ => return Err(self.failure("invalid escape")),
        })
    }

    fn unicode_escape(&mut self) -> Result<char, String> {
        let text = self.text;
        let high = self.hex4()?;
        if (0xDC00..0xE000).contains(&high) {
            return Err(self.failure("unpaired Unicode surrogate"));
        }
        if !(0xD800..0xDC00).contains(&high) {
            return char::from_u32(high).ok_or_else(|| self.failure("invalid Unicode escape"));
        }
        if text.get(self.position..self.position + 2) != Some("\\u") {
            return Err(self.failure("unpaired Unicode surrogate"));
        }
        self.position += 2;
        let low = self.hex4()?;
        if !(0xDC00..0xE000).contains(&low) {
            return Err(self.failure("unpaired Unicode surrogate"));
        }
        let code = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
        char::from_u32(code).ok_or_else(|| self.failure("invalid Unicode escape"))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let text = self.text;
        let digits = text
            .get(self.position..self.position + 4)
            .ok_or_else(|| self.failure("invalid Unicode escape"))?;
        let code = digits
            .chars()
            .try_fold(0u32, |code, digit| {
                digit.to_digit(16).map(|value| code * 16 + value)
            })
            .ok_or_else(|| self.failure("invalid Unicode escape"))?;
        self.position += 4;
        Ok(code)
    }

    fn number(&mut self) -> Result<JsonValue, String> {
        let text = self.text;
        let bytes = text.as_bytes();
        let start = self.position;
        let mut end = start;
        let byte = |index: usize| bytes.get(index).copied();
        let digit = |index: usize| matches!(byte(index), Some(b'0'..=b'9'));
        if byte(end) == Some(b'-') {
            end += 1;
        }
        match byte(end) {
            Some(b'0') => end += 1,
            Some(b'1'..=b'9') => {
                while digit(end) {
                    end += 1;
                }
            }
            _ => return Err(self.failure("expected a digit")),
        }
        if byte(end) == Some(b'.') {
            end += 1;
            if !digit(end) {
                return Err(self.failure("expected a fraction digit"));
            }
            while digit(end) {
                end += 1;
            }
        }
        if matches!(byte(end), Some(b'e' | b'E')) {
            end += 1;
            if matches!(byte(end), Some(b'+' | b'-')) {
                end += 1;
            }
            if !digit(end) {
                return Err(self.failure("expected an exponent digit"));
            }
            while digit(end) {
                end += 1;
            }
        }
        self.position = end;
        let token = text
            .get(start..end)
            .ok_or_else(|| self.failure("invalid number"))?;
        number_from_text(token)
    }

    fn literal(&mut self, word: &str, value: JsonValue) -> Result<JsonValue, String> {
        if self
            .text
            .get(self.position..)
            .is_some_and(|rest| rest.starts_with(word))
        {
            self.position += word.len();
            Ok(value)
        } else {
            Err(self.failure("expected a literal"))
        }
    }
}

pub(crate) const EXPONENT_LIMIT: u64 = 10_000;
pub const UNPAIRED_SURROGATE: &str = "unpaired Unicode surrogate";
pub const EXPONENT_TOO_LARGE: &str = "exponent too large";

fn hex_code(bytes: &[u8]) -> Option<u32> {
    if bytes.len() != 4 {
        return None;
    }
    bytes.iter().try_fold(0u32, |code, digit| {
        char::from(*digit)
            .to_digit(16)
            .map(|value| code * 16 + value)
    })
}

fn is_high_surrogate(code: u32) -> bool {
    (0xD800..=0xDBFF).contains(&code)
}

fn is_low_surrogate(code: u32) -> bool {
    (0xDC00..=0xDFFF).contains(&code)
}

fn exponent_magnitude_at_limit(rest: &[u8]) -> bool {
    let digits = match rest.split_first() {
        Some((&(b'-' | b'+'), tail)) => tail,
        _ => rest,
    };
    exponent_digits_reach_limit(
        digits
            .iter()
            .map_while(|byte| byte.is_ascii_digit().then(|| u32::from(byte - b'0'))),
    )
}

pub(crate) fn exponent_digits_reach_limit(digits: impl IntoIterator<Item = u32>) -> bool {
    let mut value = 0u64;
    let mut count = 0usize;
    for digit in digits {
        value = (value * 10 + u64::from(digit)).min(EXPONENT_LIMIT);
        count += 1;
    }
    count > 0 && value >= EXPONENT_LIMIT
}

pub fn text_admission_failure(text: &str) -> Option<&'static str> {
    let mut rest = text.as_bytes();
    let mut in_string = false;
    while let Some((&character, tail)) = rest.split_first() {
        rest = tail;
        if !in_string {
            match character {
                b'"' => in_string = true,
                b'e' | b'E' if exponent_magnitude_at_limit(rest) => {
                    return Some(EXPONENT_TOO_LARGE)
                }
                _ => {}
            }
        } else if character == b'"' {
            in_string = false;
        } else if character == b'\\' {
            if let Some((&b'u', after_u)) = rest.split_first() {
                rest = after_u;
                match after_u.get(..4).and_then(hex_code) {
                    Some(code) if is_low_surrogate(code) => return Some(UNPAIRED_SURROGATE),
                    Some(code) if is_high_surrogate(code) => {
                        let low = after_u
                            .get(4..)
                            .and_then(|after_escape| after_escape.strip_prefix(b"\\u"))
                            .and_then(|tail| {
                                tail.get(..4).and_then(hex_code).map(|low| (low, tail))
                            });
                        match low {
                            Some((low, tail)) if is_low_surrogate(low) => {
                                rest = tail.get(4..).unwrap_or(&[]);
                            }
                            _ => return Some(UNPAIRED_SURROGATE),
                        }
                    }
                    Some(_) => rest = after_u.get(4..).unwrap_or(&[]),
                    None => {}
                }
            } else if let Some((_, after_escape)) = rest.split_first() {
                rest = after_escape;
            }
        }
    }
    None
}

impl Clone for JsonValue {
    fn clone(&self) -> Self {
        crate::stack_growth::grow(|| match self {
            JsonValue::Null => JsonValue::Null,
            JsonValue::Bool(value) => JsonValue::Bool(*value),
            JsonValue::Num(value) => JsonValue::Num(value.clone()),
            JsonValue::Dec(text) => JsonValue::Dec(text.clone()),
            JsonValue::Str(text) => JsonValue::Str(text.clone()),
            JsonValue::Arr(items) => JsonValue::Arr(items.clone()),
            JsonValue::Obj(members) => JsonValue::Obj(members.clone()),
        })
    }
}

impl Drop for JsonValue {
    fn drop(&mut self) {
        let mut pending = Vec::new();
        take_children(self, &mut pending);
        while let Some(mut value) = pending.pop() {
            take_children(&mut value, &mut pending);
        }
    }
}

fn take_children(value: &mut JsonValue, pending: &mut Vec<JsonValue>) {
    match value {
        JsonValue::Arr(items) => pending.append(items),
        JsonValue::Obj(members) => pending.extend(members.drain(..).map(|(_, member)| member)),
        JsonValue::Null
        | JsonValue::Bool(_)
        | JsonValue::Num(_)
        | JsonValue::Dec(_)
        | JsonValue::Str(_) => {}
    }
}

#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used)]
mod lean_number_tests {
    use super::{bounded_json_parse, same_json, JsonValue, LeanNumber};

    const LEAN_VECTORS: &[(&str, &str, bool)] = &[
        ("0", "0", false),
        ("-0", "0", false),
        ("0.0", "0", true),
        ("-0.0", "0", true),
        ("0e5", "0", false),
        ("0e-100", "0.e-90", true),
        ("0.00e3", "0", false),
        ("1", "1", false),
        ("-1", "-1", false),
        ("1.50", "1.5", true),
        ("1e2", "100", false),
        ("1E+2", "100", false),
        ("1.0", "1", true),
        ("10e-1", "1", true),
        ("0.10", "0.1", true),
        ("1e-2", "0.01", true),
        ("1e-20", "0.0000000001e-10", true),
        ("1.5e-20", "0.00000000015e-10", true),
        ("123e-30", "0.000000000123e-18", true),
        ("0.000000001", "0.000000001", true),
        ("0.0000000001", "0.0000000001", true),
        ("0.00000000001", "0.0000000001e-1", true),
        ("-2.5e-15", "-0.00000000025e-5", true),
        ("12345.6789e2", "1234567.89", true),
        ("12345.6789e-2", "123.456789", true),
        ("1e0", "1", false),
        ("1e-0", "1", false),
        ("100e-2", "1", true),
        ("99.99e-9", "0.00000009999", true),
        ("1e-9", "0.000000001", true),
        ("1e-10", "0.0000000001", true),
        ("1e-11", "0.0000000001e-1", true),
        ("5e-324", "0.0000000005e-314", true),
        ("0e0", "0", false),
        ("0.5e1", "5", false),
        (
            "123456789012345678901234567890.5",
            "123456789012345678901234567890.5",
            true,
        ),
    ];

    #[test]
    fn number_text_matches_lean_json_parse_and_compress() {
        for (literal, compressed, has_places) in LEAN_VECTORS {
            let number = LeanNumber::parse(literal).unwrap();
            assert_eq!(number.has_places(), *has_places, "{literal}");
            assert_eq!(number.text(), *compressed, "{literal}");
        }
    }

    #[test]
    fn decoded_number_matches_lean_from_json() {
        for (literal, compressed, has_places) in LEAN_VECTORS {
            let value: JsonValue = bounded_json_parse(literal).unwrap();
            if LeanNumber::parse(literal).is_some_and(|number| number.is_zero()) {
                let expected = if *has_places {
                    JsonValue::Dec("0".into())
                } else {
                    JsonValue::Num(0.into())
                };
                assert_eq!(value, expected, "{literal}");
                continue;
            }
            match &value {
                JsonValue::Dec(text) => {
                    assert!(*has_places && text.as_str() == *compressed, "{literal}")
                }
                JsonValue::Num(integer) => {
                    assert!(
                        !*has_places && integer.to_string() == *compressed,
                        "{literal}"
                    );
                }
                _ => panic!("{literal}"),
            }
        }
    }

    #[test]
    fn canonical_zero_is_plain_zero() {
        for literal in ["0", "-0", "0.0", "0e5", "0e-100"] {
            assert_eq!(LeanNumber::parse(literal).unwrap().canonical_text(), "0");
        }
    }

    #[test]
    fn same_json_compares_numbers_by_the_lean_canonical_text() {
        let cases = [
            ("10", "10.0", true),
            ("10", "1e1", true),
            ("10.0", "1e1", true),
            ("1", "1.0e0", true),
            ("0", "0.0", true),
            ("0", "-0.0", true),
            ("100e-2", "1", true),
            ("1.5", "1.50", true),
            ("10", "10.5", false),
            ("1", "true", false),
        ];
        for (left, right, expected) in cases {
            let left: JsonValue = bounded_json_parse(left).unwrap();
            let right: JsonValue = bounded_json_parse(right).unwrap();
            assert_eq!(same_json(&left, &right), expected, "{left:?} {right:?}");
        }
    }
}
