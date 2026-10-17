// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

pub use crate::default_materialization::{
    check_default_applications, decode_with_defaults, materialize_defaults, DefaultApplication,
    DefaultFailure, DefaultedValue,
};
use crate::semantic_types::*;
use num_bigint::{BigInt, BigUint};
use num_traits::Zero;
use std::collections::{HashMap, HashSet};
use std::net::Ipv6Addr;

fn valid_ref(r: &ProfileRef) -> bool {
    !r.identity.is_empty() && !r.revision.is_empty() && !r.content_digest.is_empty()
}
fn unique<'a>(mut it: impl Iterator<Item = &'a str>) -> bool {
    let mut s = HashSet::new();
    it.all(|v| !v.is_empty() && s.insert(v))
}
pub fn format_rule_well_formed(rule: &FormatRule) -> bool {
    fn go(f: usize, r: &FormatRule) -> bool {
        if f == 0 {
            return false;
        }
        match r {
            FormatRule::AsciiDfa(s) => {
                !s.state_count.is_zero()
                    && s.initial_state < s.state_count
                    && s.accepting_states.iter().all(|v| v < &s.state_count)
                    && s.transitions.iter().all(|t| {
                        t.from_state < s.state_count
                            && t.to_state < s.state_count
                            && t.first <= t.last
                            && t.last < 128
                    })
                    && s.transitions.iter().enumerate().all(|(i, t)| {
                        s.transitions.iter().skip(i + 1).all(|u| {
                            t.from_state != u.from_state || t.last < u.first || u.last < t.first
                        })
                    })
            }
            FormatRule::Timestamp(r) => {
                r.minimum_year <= r.maximum_year && r.maximum_year <= BigUint::from(9999u32)
            }
            FormatRule::Identifier {
                first_alphabet,
                rest_alphabet,
                exact_length,
                min_length,
                max_length,
                forbidden,
            } => {
                !first_alphabet.is_empty()
                    && !rest_alphabet.is_empty()
                    && first_alphabet.is_ascii()
                    && rest_alphabet.is_ascii()
                    && max_length.as_ref().is_none_or(|m| min_length <= m)
                    && exact_length.as_ref().is_none_or(|e| {
                        min_length <= e && max_length.as_ref().is_none_or(|m| e <= m)
                    })
                    && forbidden
                        .iter()
                        .all(|x| !x.chars().any(|c| c == '\u{fffd}'))
            }
            FormatRule::Sequence(v) | FormatRule::Choice(v) => v.iter().all(|x| go(f - 1, x)),
            FormatRule::Optional(x) | FormatRule::Bounded { rule: x, .. } | FormatRule::Not(x) => {
                go(f - 1, x)
            }
            FormatRule::Labels {
                separator, rule, ..
            } => !separator.is_empty() && go(f - 1, rule),
            _ => true,
        }
    }
    go(rule.depth() + 1, rule)
}
pub fn check_profile(p: &VersionedSemanticProfile) -> Result<CheckedProfile, ProfileFailure> {
    let fail = |predicate, location: &[&str]| {
        Err(ProfileFailure {
            reference: p.reference.clone(),
            predicate,
            location: location.iter().map(|x| (*x).into()).collect(),
        })
    };
    if !valid_ref(&p.reference)
        || p.integer_domains.iter().any(|x| !valid_ref(&x.reference))
        || p.format_bindings.iter().any(|x| !valid_ref(&x.reference))
        || p.bytes_policy
            .as_ref()
            .is_some_and(|x| !valid_ref(&x.reference))
        || p.grapheme_rules
            .as_ref()
            .is_some_and(|x| !valid_ref(&x.reference))
    {
        return fail(ProfilePredicate::Pr01, &["profile"]);
    }
    if !unique(p.integer_domains.iter().map(|x| x.name.as_str())) {
        return fail(ProfilePredicate::Pr02, &["integer_domains"]);
    }
    if p.integer_domains
        .iter()
        .any(|x| matches!(&x.range,IntegerDomain::Inclusive{minimum,maximum} if minimum>maximum))
    {
        return fail(ProfilePredicate::Pr03, &["integer_domains"]);
    }
    if p.integer_domains.iter().any(|x| x.forms.is_empty()) {
        return fail(ProfilePredicate::Pr04, &["integer_domains"]);
    }
    if !p
        .integer_domains
        .iter()
        .any(|x| x.name == p.default_integer_domain)
    {
        return fail(ProfilePredicate::Pr05, &["default_integer_domain"]);
    }
    if !unique(p.format_bindings.iter().map(|x| x.name.as_str())) {
        return fail(ProfilePredicate::Pr06, &["format_bindings"]);
    }
    if p.format_bindings
        .iter()
        .any(|x| !format_rule_well_formed(&x.rule))
    {
        return fail(ProfilePredicate::Pr07, &["format_bindings"]);
    }
    if !unique(p.wrappers.iter().map(|x| x.name.as_str()))
        || !unique(p.wrappers.iter().map(|x| x.key.as_str()))
    {
        return fail(ProfilePredicate::Pr08, &["wrappers"]);
    }
    if p.wrappers.iter().any(|x|matches!(&x.payload,WrapperPayload::Text{format:Some(f)} if !p.format_bindings.iter().any(|b|b.name==*f))){return fail(ProfilePredicate::Pr09,&["wrappers"])}
    if p.bytes_policy
        .as_ref()
        .and_then(|x| x.wrapper.as_ref())
        .is_some_and(|n| {
            !p.wrappers
                .iter()
                .any(|x| x.name == *n && x.payload == WrapperPayload::Bytes)
        })
    {
        return fail(ProfilePredicate::Pr10, &["bytes_policy", "wrapper"]);
    }
    if let Some(t) = &p.tag {
        if t.key.is_empty() || p.wrappers.iter().any(|x| x.key == t.key) {
            return fail(ProfilePredicate::Pr11, &["tag", "key"]);
        }
        if t.format
            .as_ref()
            .is_some_and(|f| !p.format_bindings.iter().any(|x| x.name == *f))
        {
            return fail(ProfilePredicate::Pr12, &["tag", "format"]);
        }
        if !unique(t.sealed.iter().map(|x| x.tag.as_str()))
            || t.sealed.iter().any(|x| {
                t.format.as_ref().is_some_and(|f| {
                    p.format(f)
                        .is_none_or(|b| !recognize_format(&b.rule, &x.tag))
                })
            })
        {
            return fail(ProfilePredicate::Pr13, &["tag", "sealed"]);
        }
        if t.sealed.iter().any(|f| {
            !unique(f.fields.iter().map(|x| x.key.as_str()))
                || f.fields
                    .iter()
                    .any(|x| x.key == t.key || p.wrappers.iter().any(|w| w.key == x.key))
        }) {
            return fail(ProfilePredicate::Pr14, &["tag", "sealed", "fields"]);
        }
        if t.sealed.iter().any(|form| {
            form.fields.iter().any(|field| match &field.leaf {
                SealedLeaf::String(spec) => spec.wrapper.as_ref().is_some_and(|name| {
                    !p.wrappers.iter().any(|wrapper| {
                        wrapper.name == *name
                            && matches!(wrapper.payload, WrapperPayload::Text { .. })
                    })
                }) || spec.format.as_ref().is_some_and(|format| {
                    match format {
                        FormatUse::Named(name) => p.format(name).is_none(),
                        FormatUse::Inline(rule) => !format_rule_well_formed(rule),
                    }
                }) || spec.lengths.iter().any(
                    |bound| matches!((&bound.minimum, &bound.maximum), (Some(a), Some(z)) if a > z),
                ),
                SealedLeaf::Integer(spec) => spec
                    .domain
                    .as_ref()
                    .is_some_and(|name| p.integer_domain(Some(name)).is_none()),
            })
        }) {
            return fail(ProfilePredicate::Pr15, &["tag", "sealed", "fields"]);
        }
    }
    if p.grapheme_rules.as_ref().is_some_and(|rules| {
        rules
            .properties
            .iter()
            .any(|range| range.last < range.first)
            || rules
                .extended_pictographic
                .iter()
                .any(|range| range.last < range.first)
            || rules
                .indic_conjunct
                .iter()
                .any(|range| range.last < range.first)
    }) {
        return fail(ProfilePredicate::Pr16, &["grapheme_rules"]);
    }
    Ok(CheckedProfile { profile: p.clone() })
}

fn length(rule: &StringLengthUnit, s: &str) -> usize {
    match rule {
        StringLengthUnit::Utf8Bytes => s.len(),
        StringLengthUnit::UnicodeScalars => s.chars().count(),
        StringLengthUnit::Graphemes => s.chars().count(),
    }
}
fn range_at<T>(
    ranges: &[T],
    codepoint: u32,
    first: impl Fn(&T) -> u32,
    last: impl Fn(&T) -> u32,
) -> Option<&T> {
    let index = ranges
        .partition_point(|range| first(range) <= codepoint)
        .checked_sub(1)?;
    ranges.get(index).filter(|range| codepoint <= last(range))
}
fn grapheme_property(rules: &GraphemeRules, character: char) -> GraphemeProperty {
    range_at(
        &rules.properties,
        u32::from(character),
        |r| r.first,
        |r| r.last,
    )
    .map_or(GraphemeProperty::Other, |r| r.property)
}
fn indic_property(rules: &GraphemeRules, character: char) -> IndicProperty {
    range_at(
        &rules.indic_conjunct,
        u32::from(character),
        |r| r.first,
        |r| r.last,
    )
    .map_or(IndicProperty::Other, |r| r.property)
}
fn extended_pictographic(rules: &GraphemeRules, character: char) -> bool {
    range_at(
        &rules.extended_pictographic,
        u32::from(character),
        |r| r.first,
        |r| r.last,
    )
    .is_some()
}
pub fn grapheme_count(rules: &GraphemeRules, text: &str) -> usize {
    let mut count = 0usize;
    visit_grapheme_boundaries(rules, text, |_| count += 1);
    count.saturating_sub(1)
}
pub fn grapheme_boundaries(rules: &GraphemeRules, text: &str) -> Vec<usize> {
    let mut boundaries = Vec::new();
    visit_grapheme_boundaries(rules, text, |offset| boundaries.push(offset));
    boundaries
}
fn visit_grapheme_boundaries(rules: &GraphemeRules, text: &str, mut boundary: impl FnMut(usize)) {
    use GraphemeProperty::*;
    let mut previous = None;
    let mut regional_run = 0usize;
    let mut ep_extend = false;
    let mut previous_zwj_after_ep = false;
    let mut indic_consonant = false;
    let mut indic_linker = false;
    let mut length = 0usize;
    for (offset, character) in text.chars().enumerate() {
        length = offset + 1;
        let property = grapheme_property(rules, character);
        let indic = indic_property(rules, character);
        let pictographic = extended_pictographic(rules, character);
        let breaks = match previous {
            None => true,
            Some(Cr) if property == Lf => false,
            Some(Cr | Lf | Control) => true,
            _ if matches!(property, Cr | Lf | Control) => true,
            Some(L) if matches!(property, L | V | Lv | Lvt) => false,
            Some(Lv | V) if matches!(property, V | T) => false,
            Some(Lvt | T) if property == T => false,
            _ if matches!(property, Extend | Zwj | SpacingMark) => false,
            Some(Prepend) => false,
            _ if indic == IndicProperty::Consonant && indic_consonant && indic_linker => false,
            Some(Zwj) if pictographic && previous_zwj_after_ep => false,
            Some(RegionalIndicator) if property == RegionalIndicator && regional_run % 2 == 1 => {
                false
            }
            _ => true,
        };
        if breaks {
            boundary(offset);
        }
        let zwj_after_ep = property == Zwj && ep_extend;
        ep_extend = pictographic || (property == Extend && ep_extend);
        previous_zwj_after_ep = zwj_after_ep;
        match indic {
            IndicProperty::Consonant => {
                indic_consonant = true;
                indic_linker = false;
            }
            IndicProperty::Linker if indic_consonant => indic_linker = true,
            IndicProperty::Extend | IndicProperty::Linker => {}
            IndicProperty::Other => {
                indic_consonant = false;
                indic_linker = false;
            }
        }
        regional_run = if property == RegionalIndicator {
            if previous == Some(RegionalIndicator) {
                regional_run + 1
            } else {
                1
            }
        } else {
            0
        };
        previous = Some(property);
    }
    if length > 0 {
        boundary(length);
    }
}
fn bounded<T: Ord>(v: &T, a: &Option<T>, b: &Option<T>) -> bool {
    a.as_ref().is_none_or(|x| x <= v) && b.as_ref().is_none_or(|x| v <= x)
}
fn unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"-._~".contains(&byte)
}
fn sub_delimiter(byte: u8) -> bool {
    b"!$&'()*+,;=".contains(&byte)
}
fn component(text: &str, ordinary: impl Fn(u8) -> bool) -> bool {
    let mut bytes = text.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            if !bytes.next().is_some_and(|byte| byte.is_ascii_hexdigit())
                || !bytes.next().is_some_and(|byte| byte.is_ascii_hexdigit())
            {
                return false;
            }
        } else if !ordinary(byte) {
            return false;
        }
    }
    true
}
fn uri_authority(text: &str) -> bool {
    let host_port = if let Some((user, host)) = text.rsplit_once('@') {
        if !component(user, |byte| {
            unreserved(byte) || sub_delimiter(byte) || byte == b':'
        }) {
            return false;
        }
        host
    } else {
        text
    };
    if let Some(rest) = host_port.strip_prefix('[') {
        let (address, port) = match rest.split_once(']') {
            Some(parts) => parts,
            None => return false,
        };
        if !port.is_empty()
            && !port
                .strip_prefix(':')
                .is_some_and(|port| port.bytes().all(|byte| byte.is_ascii_digit()))
        {
            return false;
        }
        if address.parse::<Ipv6Addr>().is_ok() {
            return true;
        }
        if let Some(future) = address
            .strip_prefix('v')
            .or_else(|| address.strip_prefix('V'))
        {
            return future.split_once('.').is_some_and(|(version, address)| {
                !version.is_empty()
                    && version.bytes().all(|byte| byte.is_ascii_hexdigit())
                    && !address.is_empty()
                    && address
                        .bytes()
                        .all(|byte| unreserved(byte) || sub_delimiter(byte) || byte == b':')
            });
        }
        false
    } else {
        let host = if let Some((host, port)) = host_port.rsplit_once(':') {
            if !port.bytes().all(|byte| byte.is_ascii_digit()) {
                return false;
            }
            host
        } else {
            host_port
        };
        component(host, |byte| unreserved(byte) || sub_delimiter(byte))
    }
}
fn absolute_uri(text: &str, maximum: &BigUint) -> bool {
    if !text.is_ascii() || BigUint::from(text.len()) > *maximum {
        return false;
    }
    let (scheme, rest) = match text.split_once(':') {
        Some(parts) => parts,
        None => return false,
    };
    if !scheme
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_alphabetic())
        || !scheme
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"+-.".contains(&byte))
    {
        return false;
    }
    let (rest, fragment) = match rest.split_once('#') {
        Some((rest, fragment)) => (rest, Some(fragment)),
        None => (rest, None),
    };
    let pchar = |byte| unreserved(byte) || sub_delimiter(byte) || b":@".contains(&byte);
    if fragment
        .is_some_and(|fragment| !component(fragment, |byte| pchar(byte) || b"/?".contains(&byte)))
    {
        return false;
    }
    let (hierarchy, query) = match rest.split_once('?') {
        Some((hierarchy, query)) => (hierarchy, Some(query)),
        None => (rest, None),
    };
    if query.is_some_and(|query| !component(query, |byte| pchar(byte) || b"/?".contains(&byte))) {
        return false;
    }
    let path = if let Some(authority_path) = hierarchy.strip_prefix("//") {
        let (authority, path) = match authority_path.find('/') {
            Some(index) => (
                authority_path.get(..index).unwrap_or(""),
                authority_path.get(index..).unwrap_or(""),
            ),
            None => (authority_path, ""),
        };
        if !uri_authority(authority) {
            return false;
        }
        path
    } else {
        hierarchy
    };
    component(path, |byte| pchar(byte) || byte == b'/')
}
fn digit_number(bytes: &[u8]) -> Option<u32> {
    bytes.iter().try_fold(0u32, |value, byte| {
        if byte.is_ascii_digit() {
            value.checked_mul(10)?.checked_add(u32::from(*byte - b'0'))
        } else {
            None
        }
    })
}
fn timestamp(text: &str, rule: &CalendarRule) -> bool {
    let bytes = text.as_bytes();
    if !text.is_ascii()
        || bytes.len() < 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return false;
    }
    let parts = (
        bytes.get(0..4).and_then(digit_number),
        bytes.get(5..7).and_then(digit_number),
        bytes.get(8..10).and_then(digit_number),
        bytes.get(11..13).and_then(digit_number),
        bytes.get(14..16).and_then(digit_number),
        bytes.get(17..19).and_then(digit_number),
    );
    let (year, month, day, hour, minute, second) = match parts {
        (Some(a), Some(b), Some(c), Some(d), Some(e), Some(f)) => (a, b, c, d, e, f),
        _ => return false,
    };
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let month_days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    let exact_year = BigUint::from(year);
    if exact_year < rule.minimum_year
        || exact_year > rule.maximum_year
        || day == 0
        || day > month_days
        || hour > 23
        || minute > 59
        || second > if rule.allow_second_60 { 60 } else { 59 }
    {
        return false;
    }
    let mut index = 19usize;
    if bytes.get(index) == Some(&b'.') {
        index += 1;
        let start = index;
        while bytes.get(index).is_some_and(|byte| byte.is_ascii_digit()) {
            index += 1;
        }
        if index == start {
            return false;
        }
    }
    let zone = match text.get(index..) {
        Some(zone) => zone,
        None => return false,
    };
    if zone == "Z" {
        return true;
    }
    let zone_bytes = zone.as_bytes();
    if zone_bytes.len() != 6
        || !matches!(zone_bytes.first(), Some(b'+') | Some(b'-'))
        || zone_bytes.get(3) != Some(&b':')
    {
        return false;
    }
    let (offset_hour, offset_minute) = match (
        zone_bytes.get(1..3).and_then(digit_number),
        zone_bytes.get(4..6).and_then(digit_number),
    ) {
        (Some(hour), Some(minute)) if hour <= 23 && minute <= 59 => (hour, minute),
        _ => return false,
    };
    if zone == "-00:00" {
        return false;
    }
    if !rule.reject_utc_year_outside_range {
        return true;
    }
    let local_minutes = hour * 60 + minute;
    let offset_minutes = offset_hour * 60 + offset_minute;
    let before_minimum = exact_year == rule.minimum_year
        && month == 1
        && day == 1
        && zone.starts_with('+')
        && local_minutes < offset_minutes;
    let after_maximum = exact_year == rule.maximum_year
        && month == 12
        && day == 31
        && zone.starts_with('-')
        && local_minutes + offset_minutes >= 24 * 60;
    !(before_minimum || after_maximum)
}
pub const LANGUAGE_GRANDFATHERED: &[&str] = &[
    "en-GB-oed",
    "i-ami",
    "i-bnn",
    "i-default",
    "i-enochian",
    "i-hak",
    "i-klingon",
    "i-lux",
    "i-mingo",
    "i-navajo",
    "i-pwn",
    "i-tao",
    "i-tay",
    "i-tsu",
    "sgn-BE-FR",
    "sgn-BE-NL",
    "sgn-CH-DE",
    "art-lojban",
    "cel-gaulish",
    "no-bok",
    "no-nyn",
    "zh-guoyu",
    "zh-hakka",
    "zh-min",
    "zh-min-nan",
    "zh-xiang",
];
fn alpha(text: &str) -> bool {
    text.bytes().all(|byte| byte.is_ascii_alphabetic())
}
fn alphanumeric(text: &str) -> bool {
    text.bytes().all(|byte| byte.is_ascii_alphanumeric())
}
fn variant_code(text: &str) -> u64 {
    text.bytes().fold(0u64, |code, byte| {
        (code << 8) | u64::from(byte.to_ascii_lowercase())
    })
}
pub fn recognize_language_tag<S: AsRef<str>>(text: &str, grandfathered: &[S]) -> bool {
    if !text.is_ascii() || text.is_empty() {
        return false;
    }
    if grandfathered
        .iter()
        .any(|entry| text.eq_ignore_ascii_case(entry.as_ref()))
    {
        return true;
    }
    let mut parts = text.split('-').peekable();
    let language = match parts.next() {
        Some(part) => part,
        None => return false,
    };
    if language.eq_ignore_ascii_case("x") {
        let mut count = 0;
        return parts.all(|part| {
            count += 1;
            (1..=8).contains(&part.len()) && alphanumeric(part)
        }) && count > 0;
    }
    if !(2..=8).contains(&language.len()) || !alpha(language) {
        return false;
    }
    if language.len() <= 3 {
        for _ in 0..3 {
            if parts
                .peek()
                .is_some_and(|part| part.len() == 3 && alpha(part))
            {
                parts.next();
            } else {
                break;
            }
        }
    }
    if parts
        .peek()
        .is_some_and(|part| part.len() == 4 && alpha(part))
    {
        parts.next();
    }
    if parts.peek().is_some_and(|part| {
        (part.len() == 2 && alpha(part))
            || (part.len() == 3 && part.bytes().all(|byte| byte.is_ascii_digit()))
    }) {
        parts.next();
    }
    let mut variants = HashSet::new();
    while parts.peek().is_some_and(|part| {
        ((5..=8).contains(&part.len()) && alphanumeric(part))
            || (part.len() == 4
                && part
                    .as_bytes()
                    .first()
                    .is_some_and(|byte| byte.is_ascii_digit())
                && alphanumeric(part))
    }) {
        if let Some(part) = parts.next() {
            if !variants.insert(variant_code(part)) {
                return false;
            }
        }
    }
    let mut extensions = 0u64;
    while parts.peek().is_some_and(|part| {
        part.len() == 1 && alphanumeric(part) && !part.eq_ignore_ascii_case("x")
    }) {
        let singleton = match parts
            .next()
            .and_then(|part| part.as_bytes().first())
            .copied()
        {
            Some(byte) => byte.to_ascii_lowercase(),
            None => return false,
        };
        let code = if singleton.is_ascii_digit() {
            singleton - b'0'
        } else {
            singleton - b'a' + 10
        };
        let mask = 1u64 << code;
        if extensions & mask != 0 {
            return false;
        }
        extensions |= mask;
        let mut count = 0;
        while parts
            .peek()
            .is_some_and(|part| (2..=8).contains(&part.len()) && alphanumeric(part))
        {
            parts.next();
            count += 1;
        }
        if count == 0 {
            return false;
        }
    }
    if parts
        .peek()
        .is_some_and(|part| part.eq_ignore_ascii_case("x"))
    {
        parts.next();
        let mut count = 0;
        return parts.all(|part| {
            count += 1;
            (1..=8).contains(&part.len()) && alphanumeric(part)
        }) && count > 0;
    }
    parts.next().is_none()
}
struct FormatSpanNode<'a> {
    id: usize,
    kind: FormatSpanKind<'a>,
}

enum FormatSpanKind<'a> {
    Epsilon,
    Sequence(Box<FormatSpanNode<'a>>, Box<FormatSpanNode<'a>>),
    Not(Box<FormatSpanNode<'a>>),
    Optional(Box<FormatSpanNode<'a>>),
    Choice(Vec<FormatSpanNode<'a>>),
    Bounded(&'a StringLengthUnit, &'a BigUint, Box<FormatSpanNode<'a>>),
    Labels(
        &'a str,
        &'a BigUint,
        &'a Option<BigUint>,
        &'a Option<BigUint>,
        Box<FormatSpanNode<'a>>,
    ),
    Leaf(&'a FormatRule),
}

fn format_span_node<'a>(kind: FormatSpanKind<'a>, next: &mut usize) -> FormatSpanNode<'a> {
    let id = *next;
    *next += 1;
    FormatSpanNode { id, kind }
}

fn binary_format_sequence<'a>(
    mut children: Vec<FormatSpanNode<'a>>,
    next: &mut usize,
) -> FormatSpanNode<'a> {
    if children.len() > 1 {
        let right = children.split_off(children.len() / 2);
        let left = binary_format_sequence(children, next);
        let right = binary_format_sequence(right, next);
        return format_span_node(
            FormatSpanKind::Sequence(Box::new(left), Box::new(right)),
            next,
        );
    }
    match children.pop() {
        Some(child) => child,
        None => format_span_node(FormatSpanKind::Epsilon, next),
    }
}

fn compile_format_span<'a>(rule: &'a FormatRule, next: &mut usize) -> FormatSpanNode<'a> {
    let kind = match rule {
        FormatRule::Sequence(parts) => {
            let children: Vec<_> = parts
                .iter()
                .map(|part| compile_format_span(part, next))
                .collect();
            return binary_format_sequence(children, next);
        }
        FormatRule::Not(child) => FormatSpanKind::Not(Box::new(compile_format_span(child, next))),
        FormatRule::Optional(child) => {
            FormatSpanKind::Optional(Box::new(compile_format_span(child, next)))
        }
        FormatRule::Choice(parts) => FormatSpanKind::Choice(
            parts
                .iter()
                .map(|part| compile_format_span(part, next))
                .collect(),
        ),
        FormatRule::Bounded {
            unit,
            maximum,
            rule,
        } => FormatSpanKind::Bounded(unit, maximum, Box::new(compile_format_span(rule, next))),
        FormatRule::Labels {
            separator,
            min_count,
            max_count,
            total_max,
            rule,
        } => FormatSpanKind::Labels(
            separator,
            min_count,
            max_count,
            total_max,
            Box::new(compile_format_span(rule, next)),
        ),
        _ => FormatSpanKind::Leaf(rule),
    };
    format_span_node(kind, next)
}

struct FormatSpan<'a> {
    source: &'a str,
    offsets: Vec<usize>,
    memo: HashMap<(usize, usize, usize), bool>,
}

impl<'a> FormatSpan<'a> {
    fn text(&self, start: usize, end: usize) -> Option<&'a str> {
        self.offsets
            .get(start)
            .zip(self.offsets.get(end))
            .and_then(|(&first, &last)| self.source.get(first..last))
    }

    fn accepts(&mut self, node: &FormatSpanNode<'_>, start: usize, end: usize) -> bool {
        let key = (node.id, start, end);
        if let Some(&accepted) = self.memo.get(&key) {
            return accepted;
        }
        let accepted = match &node.kind {
            FormatSpanKind::Epsilon => start == end,
            FormatSpanKind::Sequence(left, right) => (start..=end)
                .any(|split| self.accepts(left, start, split) && self.accepts(right, split, end)),
            FormatSpanKind::Not(child) => !self.accepts(child, start, end),
            FormatSpanKind::Optional(child) => start == end || self.accepts(child, start, end),
            FormatSpanKind::Choice(children) => {
                children.iter().any(|child| self.accepts(child, start, end))
            }
            FormatSpanKind::Bounded(unit, maximum, child) => {
                self.text(start, end)
                    .is_some_and(|text| BigUint::from(length(unit, text)) <= **maximum)
                    && self.accepts(child, start, end)
            }
            FormatSpanKind::Labels(separator, minimum, maximum, total, child) => {
                if let Some(text) = self.text(start, end) {
                    let parts: Vec<_> = text.split(*separator).collect();
                    let valid = !separator.is_empty()
                        && BigUint::from(parts.len()) >= **minimum
                        && maximum
                            .as_ref()
                            .is_none_or(|bound| BigUint::from(parts.len()) <= *bound)
                        && total
                            .as_ref()
                            .is_none_or(|bound| BigUint::from(text.len()) <= *bound);
                    let mut cursor = start;
                    valid
                        && parts.iter().all(|part| {
                            let end = cursor + part.chars().count();
                            let accepted = self.accepts(child, cursor, end);
                            cursor = end + separator.chars().count();
                            accepted
                        })
                } else {
                    false
                }
            }
            FormatSpanKind::Leaf(rule) => self
                .text(start, end)
                .is_some_and(|text| recognize_format_leaf(rule, text)),
        };
        self.memo.insert(key, accepted);
        accepted
    }
}

pub fn recognize_format(rule: &FormatRule, text: &str) -> bool {
    let root = compile_format_span(rule, &mut 0);
    let offsets: Vec<_> = text
        .char_indices()
        .map(|(index, _)| index)
        .chain([text.len()])
        .collect();
    let end = offsets.len() - 1;
    FormatSpan {
        source: text,
        offsets,
        memo: HashMap::new(),
    }
    .accepts(&root, 0, end)
}

fn recognize_format_leaf(r: &FormatRule, s: &str) -> bool {
    match r {
        FormatRule::Literal(x) => x == s,
        FormatRule::Text => true,
        FormatRule::Identifier {
            first_alphabet,
            rest_alphabet,
            exact_length,
            min_length,
            max_length,
            forbidden,
        } => {
            let c: Vec<_> = s.chars().collect();
            let Some((first, rest)) = c.split_first() else {
                return false;
            };
            first_alphabet.contains(*first)
                && rest.iter().all(|x| rest_alphabet.contains(*x))
                && exact_length
                    .as_ref()
                    .is_none_or(|n| BigUint::from(c.len()) == *n)
                && BigUint::from(c.len()) >= *min_length
                && max_length
                    .as_ref()
                    .is_none_or(|n| BigUint::from(c.len()) <= *n)
                && !forbidden.iter().any(|x| x == s)
        }
        FormatRule::AsciiDfa(d) => {
            let mut state = d.initial_state.clone();
            for b in s.bytes() {
                let Some(t) = d
                    .transitions
                    .iter()
                    .find(|t| t.from_state == state && t.first <= b && b <= t.last)
                else {
                    return false;
                };
                state = t.to_state.clone()
            }
            d.accepting_states.contains(&state)
        }
        FormatRule::Sequence(_)
        | FormatRule::Not(_)
        | FormatRule::Optional(_)
        | FormatRule::Choice(_)
        | FormatRule::Bounded { .. }
        | FormatRule::Labels { .. } => false,
        FormatRule::Timestamp(rule) => timestamp(s, rule),
        FormatRule::AbsoluteUri { max_bytes } => max_bytes.as_ref().map_or_else(
            || absolute_uri(s, &BigUint::from(u64::MAX)),
            |maximum| absolute_uri(s, maximum),
        ),
        FormatRule::LanguageTag { grandfathered } => recognize_language_tag(s, grandfathered),
    }
}
pub(crate) fn parse_integer(binding: &IntegerDomainBinding, v: &JsonValue) -> Option<BigInt> {
    match v {
        JsonValue::Num(n) if binding.forms.contains(&IntegerForm::Number) => Some(n.clone()),
        JsonValue::Dec(text) if binding.forms.contains(&IntegerForm::IntegralDecimal) => {
            let (mantissa, exponent) = decimal_parts(text)?;
            if exponent >= 0 {
                Some(mantissa * BigInt::from(10u8).pow(u32::try_from(exponent).ok()?))
            } else {
                let divisor = BigInt::from(10u8).pow(u32::try_from(-exponent).ok()?);
                (&mantissa % &divisor).is_zero().then(|| mantissa / divisor)
            }
        }
        JsonValue::Str(s) if binding.forms.contains(&IntegerForm::DecimalString) => s.parse().ok(),
        _ => None,
    }
}
pub fn integer_condition(
    p: &VersionedSemanticProfile,
    s: &IntegerSpec,
    v: &JsonValue,
) -> Option<ValueCondition> {
    let Some(b) = p.integer_domain(s.domain.as_deref()) else {
        return Some(ValueCondition::IntegerDomain);
    };
    let Some(n) = parse_integer(b, v) else {
        return Some(ValueCondition::WrongValueKind("integer".into()));
    };
    if matches!(&b.range,IntegerDomain::Inclusive{minimum,maximum} if n<*minimum||n>*maximum) {
        return Some(ValueCondition::IntegerDomain);
    }
    if s.const_value.as_ref().is_some_and(|x| x != &n) {
        Some(ValueCondition::ConstMismatch)
    } else if s.enum_values.as_ref().is_some_and(|x| !x.contains(&n)) {
        Some(ValueCondition::EnumMismatch)
    } else if s.minimum.as_ref().is_some_and(|x| n < *x) {
        Some(ValueCondition::BelowMinimum)
    } else if s.maximum.as_ref().is_some_and(|x| n > *x) {
        Some(ValueCondition::AboveMaximum)
    } else {
        None
    }
}
pub fn string_condition(
    p: &VersionedSemanticProfile,
    s: &StringSpec,
    v: &str,
) -> Option<ValueCondition> {
    if s.const_value.as_ref().is_some_and(|x| x != v) {
        return Some(ValueCondition::ConstMismatch);
    }
    if s.enum_values
        .as_ref()
        .is_some_and(|x| !x.iter().any(|x| x == v))
    {
        return Some(ValueCondition::EnumMismatch);
    }
    for b in &s.lengths {
        let measured = match b.unit {
            StringLengthUnit::Graphemes => p
                .grapheme_rules
                .as_ref()
                .map(|rules| grapheme_count(rules, v)),
            _ => Some(length(&b.unit, v)),
        };
        if measured
            .is_none_or(|measured| !bounded(&BigUint::from(measured), &b.minimum, &b.maximum))
        {
            return Some(ValueCondition::StringLength);
        }
    }
    match &s.format {
        Some(FormatUse::Named(n)) if p.format(n).is_some_and(|r| !recognize_format(&r.rule, v)) => {
            Some(ValueCondition::Format(n.clone()))
        }
        Some(FormatUse::Inline(r)) if !recognize_format(r, v) => {
            Some(ValueCondition::Format("inline".into()))
        }
        _ => None,
    }
}
fn decimal_parts(text: &str) -> Option<(BigInt, i64)> {
    let (coefficient, exponent) = match text.split_once(['e', 'E']) {
        Some((coefficient, exponent)) => (coefficient, exponent.parse::<i64>().ok()?),
        None => (text, 0),
    };
    let negative = coefficient.starts_with('-');
    let coefficient = coefficient.strip_prefix(['-', '+']).unwrap_or(coefficient);
    let (whole, fraction) = coefficient.split_once('.').unwrap_or((coefficient, ""));
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    let mut mantissa = format!("{whole}{fraction}").parse::<BigInt>().ok()?;
    if negative {
        mantissa = -mantissa;
    }
    Some((mantissa, exponent - i64::try_from(fraction.len()).ok()?))
}
fn compare_decimal(text: &str, bound: &DecimalBound) -> Option<std::cmp::Ordering> {
    let (value, exponent) = decimal_parts(text)?;
    let scale = i64::try_from(bound.scale.clone()).ok()?;
    let power = exponent + scale;
    Some(if power >= 0 {
        (value * BigInt::from(10u8).pow(u32::try_from(power).ok()?)).cmp(&bound.mantissa)
    } else {
        value.cmp(&(bound.mantissa.clone() * BigInt::from(10u8).pow(u32::try_from(-power).ok()?)))
    })
}
fn decimal_condition(spec: &DecimalSpec, text: &str) -> Option<ValueCondition> {
    if decimal_parts(text).is_none() {
        return Some(ValueCondition::InvalidDataModel);
    }
    if let Some(ordering) = spec
        .minimum
        .as_ref()
        .and_then(|bound| compare_decimal(text, bound))
    {
        if ordering.is_lt()
            || (ordering.is_eq() && spec.minimum.as_ref().is_some_and(|bound| bound.exclusive))
        {
            return Some(ValueCondition::BelowMinimum);
        }
    }
    if let Some(ordering) = spec
        .maximum
        .as_ref()
        .and_then(|bound| compare_decimal(text, bound))
    {
        if ordering.is_gt()
            || (ordering.is_eq() && spec.maximum.as_ref().is_some_and(|bound| bound.exclusive))
        {
            return Some(ValueCondition::AboveMaximum);
        }
    }
    None
}
fn member<'a>(m: &'a [(String, JsonValue)], k: &str) -> Option<&'a JsonValue> {
    m.iter().find(|x| x.0 == k).map(|x| &x.1)
}
pub fn class_of(p: &VersionedSemanticProfile, m: &[(String, JsonValue)]) -> ObjectClass {
    if let Some(t) = &p.tag {
        if let Some(JsonValue::Str(v)) = member(m, &t.key) {
            if let Some(f) = t.sealed.iter().find(|x| x.tag == *v) {
                return ObjectClass::Sealed(f.clone());
            }
        }
    }
    if let Some(w) = p.wrappers.iter().find(|w| member(m, &w.key).is_some()) {
        ObjectClass::Wrapper(w.clone())
    } else {
        ObjectClass::Ordinary
    }
}
pub fn selector_matches(p: &VersionedSemanticProfile, b: &UnionBranch, v: &JsonValue) -> bool {
    match &b.selector {
        BranchSelector::InternalTag => {
            matches!((&p.tag,v),(Some(t),JsonValue::Obj(m)) if matches!(member(m,&t.key),Some(JsonValue::Str(x)) if x==&b.wire_tag))
        }
        BranchSelector::MemberShape(t) => {
            matches!(v,JsonValue::Obj(m) if t.iter().all(|(k,x)|match x{MemberTest::Absent=>member(m,k).is_none(),MemberTest::Format(f)=>matches!(member(m,k),Some(JsonValue::Str(s)) if p.format(f).is_some_and(|r|recognize_format(&r.rule,s)))}))
        }
        BranchSelector::Kind(k) => matches!(
            (k, v),
            (ValueKind::Null, JsonValue::Null)
                | (ValueKind::Boolean, JsonValue::Bool(_))
                | (ValueKind::Number, JsonValue::Num(_) | JsonValue::Dec(_))
                | (ValueKind::String, JsonValue::Str(_))
                | (ValueKind::Array, JsonValue::Arr(_))
                | (ValueKind::Object, JsonValue::Obj(_))
        ),
        BranchSelector::Otherwise => true,
    }
}
pub fn select_union_branch<'a>(
    p: &VersionedSemanticProfile,
    s: &'a UnionSpec,
    v: &JsonValue,
) -> Option<&'a UnionBranch> {
    s.branches.iter().find(|b| selector_matches(p, b, v))
}
fn failure(r: &TypeRef, path: ValuePath, v: JsonValue, c: ValueCondition) -> ValueDecision {
    ValueDecision::Rejected(ValueFailure {
        type_ref: r.clone(),
        definition_ref: DefinitionRef {
            source: r.source.clone(),
            name: r.definition_name.clone(),
        },
        origin: r.into(),
        value_path: path,
        condition: c,
        observed: SlotValue::Present(v),
        reference_trace: vec![],
    })
}
fn failure_with_trace(
    r: &TypeRef,
    path: ValuePath,
    v: JsonValue,
    c: ValueCondition,
    trace: &[TypeRef],
) -> ValueDecision {
    let ValueDecision::Rejected(mut failed) = failure(r, path, v, c) else {
        unreachable!()
    };
    failed.reference_trace = trace.to_vec();
    ValueDecision::Rejected(failed)
}
fn duplicate(m: &[(String, JsonValue)]) -> Option<String> {
    let mut s = HashSet::new();
    m.iter().find_map(|x| {
        if s.insert(&x.0) {
            None
        } else {
            Some(x.0.clone())
        }
    })
}
fn base64_digit(c: u8, alphabet: &BytesAlphabet) -> Option<u8> {
    match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(c - b'a' + 26),
        b'0'..=b'9' => Some(c - b'0' + 52),
        b'+' if *alphabet != BytesAlphabet::UrlSafe => Some(62),
        b'/' if *alphabet != BytesAlphabet::UrlSafe => Some(63),
        b'-' if *alphabet != BytesAlphabet::Standard => Some(62),
        b'_' if *alphabet != BytesAlphabet::Standard => Some(63),
        _ => None,
    }
}
fn base64_digits(policy: &BytesPolicy, text: &str) -> Option<Vec<u8>> {
    let body = text.trim_end_matches('=');
    let padding = text.len() - body.len();
    let remainder = body.len() % 4;
    if padding > 2
        || remainder == 1
        || (padding > 0 && (!text.len().is_multiple_of(4) || padding != (4 - remainder) % 4))
        || (padding == 0 && !policy.padding_optional && remainder != 0)
    {
        return None;
    }
    let digits = body
        .bytes()
        .map(|byte| base64_digit(byte, &policy.alphabet))
        .collect::<Option<Vec<_>>>()?;
    if policy.strict_pad_bits && remainder > 1 {
        let last = digits.last()?;
        if remainder == 2 && last % 16 != 0 || remainder == 3 && last % 4 != 0 {
            return None;
        }
    }
    Some(digits)
}
pub fn base64_length(policy: &BytesPolicy, text: &str) -> Option<usize> {
    base64_digits(policy, text)
        .map(|digits| digits.len() / 4 * 3 + (digits.len() % 4).saturating_sub(1))
}
pub(crate) fn base64_decode(policy: &BytesPolicy, text: &str) -> Option<Vec<u8>> {
    let digits = base64_digits(policy, text)?;
    let mut output = Vec::new();
    for chunk in digits.chunks(4) {
        let mut value = 0u32;
        for digit in chunk {
            value = (value << 6) | u32::from(*digit);
        }
        value <<= 6 * (4 - chunk.len());
        output.push((value >> 16) as u8);
        if chunk.len() >= 3 {
            output.push((value >> 8) as u8);
        }
        if chunk.len() == 4 {
            output.push(value as u8);
        }
    }
    Some(output)
}
fn wrapper_text(p: &VersionedSemanticProfile, w: &Wrapper, v: &JsonValue) -> Option<String> {
    let JsonValue::Obj(m) = v else { return None };
    if m.len() != 1 {
        return None;
    }
    let JsonValue::Str(s) = member(m, &w.key)? else {
        return None;
    };
    match &w.payload {
        WrapperPayload::Bytes => p
            .bytes_policy
            .as_ref()
            .and_then(|b| base64_length(b, s))
            .map(|_| s.clone()),
        WrapperPayload::Text { format: None } => Some(s.clone()),
        WrapperPayload::Text { format: Some(f) } => p
            .format(f)
            .filter(|r| recognize_format(&r.rule, s))
            .map(|_| s.clone()),
    }
}
fn wrapper_payload_failure(wrapper: &Wrapper) -> ValueCondition {
    match &wrapper.payload {
        WrapperPayload::Bytes => ValueCondition::InvalidBytes,
        WrapperPayload::Text { format: None } => {
            ValueCondition::WrongValueKind("wrapper text".into())
        }
        WrapperPayload::Text { format: Some(name) } => ValueCondition::Format(name.clone()),
    }
}
fn bytes_len(p: &VersionedSemanticProfile, v: &JsonValue) -> Option<usize> {
    let policy = p.bytes_policy.as_ref()?;
    let text = match &policy.wrapper {
        None => match v {
            JsonValue::Str(text) => text.clone(),
            _ => return None,
        },
        Some(name) => {
            let wrapper = p.wrappers.iter().find(|wrapper| wrapper.name == *name)?;
            wrapper_text(p, wrapper, v)?
        }
    };
    base64_length(policy, &text)
}
fn sealed_leaf_condition(
    profile: &VersionedSemanticProfile,
    leaf: &SealedLeaf,
    value: &JsonValue,
) -> Option<ValueCondition> {
    match (leaf, value) {
        (SealedLeaf::String(spec), JsonValue::Str(text)) => string_condition(profile, spec, text),
        (SealedLeaf::String(spec), JsonValue::Obj(members)) => match class_of(profile, members) {
            ObjectClass::Wrapper(wrapper) => match wrapper_text(profile, &wrapper, value) {
                Some(text) => string_condition(profile, spec, &text),
                None => Some(wrapper_payload_failure(&wrapper)),
            },
            _ => Some(ValueCondition::WrongValueKind("string".into())),
        },
        (SealedLeaf::String(_), _) => Some(ValueCondition::WrongValueKind("string".into())),
        (SealedLeaf::Integer(spec), _) => integer_condition(profile, spec, value),
    }
}
fn tag_member_failure(
    profile: &VersionedSemanticProfile,
    members: &[(String, JsonValue)],
) -> Option<(String, ValueCondition, JsonValue)> {
    let tag = profile.tag.as_ref()?;
    let observed = member(members, &tag.key)?;
    match observed {
        JsonValue::Str(text)
            if tag.format.as_ref().is_none_or(|name| {
                profile
                    .format(name)
                    .is_some_and(|binding| recognize_format(&binding.rule, text))
            }) =>
        {
            None
        }
        _ => Some((
            tag.key.clone(),
            ValueCondition::InvalidTag,
            observed.clone(),
        )),
    }
}
fn sealed_failure(
    profile: &VersionedSemanticProfile,
    tag: &TagModel,
    form: &SealedForm,
    refinements: &[SealedRefinement],
    members: &[(String, JsonValue)],
) -> Option<(String, ValueCondition)> {
    for field in &form.fields {
        match member(members, &field.key) {
            None if field.required => {
                return Some((field.key.clone(), ValueCondition::MissingRequired))
            }
            Some(value) => {
                if let Some(condition) = sealed_leaf_condition(profile, &field.leaf, value) {
                    return Some((field.key.clone(), condition));
                }
            }
            None => {}
        }
    }
    for refinement in refinements {
        if let Some(value) = member(members, &refinement.key) {
            if let Some(condition) = sealed_leaf_condition(profile, &refinement.leaf, value) {
                return Some((refinement.key.clone(), condition));
            }
        }
    }
    if form.extras == SealedExtras::Reject {
        if let Some((key, _)) = members
            .iter()
            .find(|(key, _)| key != &tag.key && !form.fields.iter().any(|field| field.key == *key))
        {
            return Some((key.clone(), ValueCondition::UnexpectedField(key.clone())));
        }
    }
    None
}
fn data_failure(
    profile: &VersionedSemanticProfile,
    path: ValuePath,
    value: &JsonValue,
) -> Option<(ValuePath, ValueCondition, JsonValue)> {
    match value {
        JsonValue::Num(_) => integer_condition(
            profile,
            &IntegerSpec {
                domain: None,
                minimum: None,
                maximum: None,
                const_value: None,
                enum_values: None,
                default_value: None,
            },
            value,
        )
        .map(|condition| (path, condition, value.clone())),
        value @ JsonValue::Dec(_) => {
            let integral = profile
                .integer_domain(None)
                .is_some_and(|binding| parse_integer(binding, value).is_some());
            let condition = if integral {
                integer_condition(
                    profile,
                    &IntegerSpec {
                        domain: None,
                        minimum: None,
                        maximum: None,
                        const_value: None,
                        enum_values: None,
                        default_value: None,
                    },
                    value,
                )
            } else if profile.numbers.decimals {
                None
            } else {
                Some(ValueCondition::InvalidDataModel)
            };
            condition.map(|condition| (path, condition, value.clone()))
        }
        JsonValue::Str(_) | JsonValue::Null | JsonValue::Bool(_) => None,
        JsonValue::Arr(items) => items.iter().enumerate().find_map(|(index, item)| {
            let mut here = path.clone();
            here.push(PathStep::Index(BigUint::from(index)));
            data_failure(profile, here, item)
        }),
        JsonValue::Obj(members) => {
            if let Some(key) = duplicate(members) {
                return Some((path, ValueCondition::DuplicateField(key), value.clone()));
            }
            if let Some((key, condition, observed)) = tag_member_failure(profile, members) {
                let mut here = path;
                here.push(PathStep::Field(key));
                return Some((here, condition, observed));
            }
            match class_of(profile, members) {
                ObjectClass::Wrapper(wrapper) => wrapper_text(profile, &wrapper, value)
                    .is_none()
                    .then(|| (path, wrapper_payload_failure(&wrapper), value.clone())),
                ObjectClass::Sealed(form) => {
                    let tag = profile.tag.as_ref()?;
                    if let Some((key, condition)) =
                        sealed_failure(profile, tag, &form, &[], members)
                    {
                        let mut here = path;
                        here.push(PathStep::Field(key));
                        Some((here, condition, value.clone()))
                    } else {
                        members.iter().find_map(|(key, member_value)| {
                            if key == &tag.key || form.fields.iter().any(|field| field.key == *key)
                            {
                                None
                            } else {
                                let mut here = path.clone();
                                here.push(PathStep::Field(key.clone()));
                                data_failure(profile, here, member_value)
                            }
                        })
                    }
                }
                ObjectClass::Ordinary => members.iter().find_map(|(key, member_value)| {
                    let mut here = path.clone();
                    here.push(PathStep::Field(key.clone()));
                    data_failure(profile, here, member_value)
                }),
            }
        }
    }
}
pub fn accepts_value(g: &SemanticGraph, r: &TypeRef, v: &JsonValue) -> ValueDecision {
    fn element(
        g: &SemanticGraph,
        contract: &ElementContract,
        value: &JsonValue,
        path: ValuePath,
        seen: &mut Vec<(TypeRef, ValuePath)>,
    ) -> ValueDecision {
        if contract.nullable && matches!(value, JsonValue::Null) {
            ValueDecision::Accepted
        } else {
            go(g, &contract.type_ref, value, path, seen)
        }
    }
    fn go(
        g: &SemanticGraph,
        r: &TypeRef,
        v: &JsonValue,
        path: ValuePath,
        seen: &mut Vec<(TypeRef, ValuePath)>,
    ) -> ValueDecision {
        if seen.contains(&(r.clone(), path.clone())) {
            let trace = seen
                .iter()
                .map(|(reference, _)| reference.clone())
                .collect::<Vec<_>>();
            return failure_with_trace(r, path, v.clone(), ValueCondition::ReferenceCycle, &trace);
        }
        let Some(n) = g.find_type(r) else {
            return ValueDecision::Unresolved(vec![SemanticObligation {
                type_ref: r.clone(),
                origin: r.into(),
                value_path: path,
                profile: g.profile.reference.clone(),
                reason: SemanticReason::UnresolvedType,
            }]);
        };
        seen.push((r.clone(), path.clone()));
        let trace = seen
            .iter()
            .take(seen.len() - 1)
            .map(|(reference, _)| reference.clone())
            .collect::<Vec<_>>();
        if let JsonValue::Obj(members) = v {
            if matches!(
                &n.shape,
                TypeShape::Product(_)
                    | TypeShape::TaggedUnion(_)
                    | TypeShape::Sealed { .. }
                    | TypeShape::Unknown(_)
            ) {
                if let Some(key) = duplicate(members) {
                    seen.pop();
                    return failure_with_trace(
                        r,
                        path,
                        v.clone(),
                        ValueCondition::DuplicateField(key),
                        &trace,
                    );
                }
                if let Some((key, condition, observed)) = tag_member_failure(&g.profile, members) {
                    let mut here = path;
                    here.push(PathStep::Field(key));
                    seen.pop();
                    return failure_with_trace(r, here, observed, condition, &trace);
                }
            }
        }
        let reject = |c| failure_with_trace(r, path.clone(), v.clone(), c, trace.as_slice());
        let result = match (&n.shape, v) {
            (TypeShape::Boolean(s), JsonValue::Bool(x)) => {
                if s.const_value.is_some_and(|c| c != *x) {
                    reject(ValueCondition::ConstMismatch)
                } else {
                    ValueDecision::Accepted
                }
            }
            (TypeShape::Integer(s), _) => {
                integer_condition(&g.profile, s, v).map_or(ValueDecision::Accepted, reject)
            }
            (TypeShape::Decimal(spec), JsonValue::Dec(text)) => {
                decimal_condition(spec, text).map_or(ValueDecision::Accepted, reject)
            }
            (TypeShape::String(spec), value) => {
                let text = match (&spec.wrapper, value) {
                    (None, JsonValue::Str(text)) => Ok(text.clone()),
                    (None, _) => Err(ValueCondition::WrongValueKind("string".into())),
                    (Some(name), JsonValue::Obj(members)) => match class_of(&g.profile, members) {
                        ObjectClass::Wrapper(wrapper) if wrapper.name == *name => {
                            wrapper_text(&g.profile, &wrapper, value)
                                .ok_or_else(|| wrapper_payload_failure(&wrapper))
                        }
                        _ => Err(ValueCondition::WrongValueKind("string wrapper".into())),
                    },
                    (Some(_), _) => Err(ValueCondition::WrongValueKind("string wrapper".into())),
                };
                match text {
                    Ok(text) => string_condition(&g.profile, spec, &text)
                        .map_or(ValueDecision::Accepted, reject),
                    Err(condition) => reject(condition),
                }
            }
            (TypeShape::Bytes(s), _) => match bytes_len(&g.profile, v) {
                None => reject(ValueCondition::InvalidBytes),
                Some(length) if bounded(&BigUint::from(length), &s.minimum, &s.maximum) => {
                    ValueDecision::Accepted
                }
                Some(_) => reject(ValueCondition::BytesLength),
            },
            (TypeShape::Array(s), JsonValue::Arr(a)) => {
                if !bounded(&BigUint::from(a.len()), &s.min_length, &s.max_length) {
                    reject(ValueCondition::ArrayLength)
                } else {
                    a.iter()
                        .enumerate()
                        .find_map(|(i, x)| {
                            let mut p = path.clone();
                            p.push(PathStep::Index(BigUint::from(i)));
                            let d = element(g, &s.item, x, p, seen);
                            (!matches!(d, ValueDecision::Accepted)).then_some(d)
                        })
                        .unwrap_or(ValueDecision::Accepted)
                }
            }
            (TypeShape::Product(s), JsonValue::Obj(m)) => {
                if let Some(k) = duplicate(m) {
                    reject(ValueCondition::DuplicateField(k))
                } else if !matches!(class_of(&g.profile, m), ObjectClass::Ordinary) {
                    reject(ValueCondition::WrongValueKind("plain data object".into()))
                } else {
                    for f in &s.fields {
                        match member(m, &f.wire_name) {
                            None if f.slot.required => {
                                return failure_with_trace(
                                    &f.slot.type_ref,
                                    {
                                        let mut p = path.clone();
                                        p.push(PathStep::Field(f.wire_name.clone()));
                                        p
                                    },
                                    JsonValue::Null,
                                    ValueCondition::MissingRequired,
                                    &trace,
                                )
                            }
                            Some(JsonValue::Null) if !f.slot.nullable => {
                                let mut child_path = path.clone();
                                child_path.push(PathStep::Field(f.wire_name.clone()));
                                return failure_with_trace(
                                    &f.slot.type_ref,
                                    child_path,
                                    JsonValue::Null,
                                    ValueCondition::NullNotAllowed,
                                    &trace,
                                );
                            }
                            Some(x) if !matches!(x, JsonValue::Null) => {
                                let mut p = path.clone();
                                p.push(PathStep::Field(f.wire_name.clone()));
                                let d = go(g, &f.slot.type_ref, x, p, seen);
                                if !matches!(d, ValueDecision::Accepted) {
                                    return d;
                                }
                            }
                            _ => {}
                        }
                    }
                    for (k, x) in m {
                        if !s.fields.iter().any(|f| f.wire_name == *k)
                            && g.profile.tag.as_ref().is_none_or(|t| t.key != *k)
                        {
                            let mut here = path.clone();
                            here.push(PathStep::Field(k.clone()));
                            match &s.extras {
                                ExtraMembers::Reject => {
                                    return failure_with_trace(
                                        r,
                                        here,
                                        x.clone(),
                                        ValueCondition::UnexpectedField(k.clone()),
                                        &trace,
                                    );
                                }
                                ExtraMembers::Allow { key_format, value } => {
                                    if key_format.as_ref().is_some_and(|u| match u {
                                        FormatUse::Named(n) => g
                                            .profile
                                            .format(n)
                                            .is_none_or(|r| !recognize_format(&r.rule, k)),
                                        FormatUse::Inline(r) => !recognize_format(r, k),
                                    }) {
                                        return failure_with_trace(
                                            r,
                                            here,
                                            x.clone(),
                                            ValueCondition::KeyFormat(k.clone()),
                                            &trace,
                                        );
                                    }
                                    let d = element(g, value, x, here, seen);
                                    if !matches!(d, ValueDecision::Accepted) {
                                        return d;
                                    }
                                }
                            }
                        }
                    }
                    ValueDecision::Accepted
                }
            }
            (TypeShape::Alias { target, .. }, _) => go(g, target, v, path.clone(), seen),
            (TypeShape::TaggedUnion(s), _) => select_union_branch(&g.profile, s, v).map_or_else(
                || reject(ValueCondition::NoBranchSelected),
                |b| go(g, &b.target, v, path.clone(), seen),
            ),
            (TypeShape::Sealed { tag, refinements }, JsonValue::Obj(members)) => {
                match (&g.profile.tag, class_of(&g.profile, members)) {
                    (Some(model), ObjectClass::Sealed(form)) if form.tag == *tag => {
                        match sealed_failure(&g.profile, model, &form, refinements, members) {
                            Some((key, condition)) => {
                                let mut here = path.clone();
                                here.push(PathStep::Field(key));
                                failure_with_trace(r, here, v.clone(), condition, &trace)
                            }
                            None => ValueDecision::Accepted,
                        }
                    }
                    _ => reject(ValueCondition::WrongValueKind("sealed object".into())),
                }
            }
            (TypeShape::Never, _) => reject(ValueCondition::InvalidDataModel),
            (TypeShape::Unknown(UnknownKind::OrdinaryObject), JsonValue::Obj(members))
                if matches!(class_of(&g.profile, members), ObjectClass::Ordinary) =>
            {
                data_failure(&g.profile, path.clone(), v).map_or(
                    ValueDecision::Accepted,
                    |(here, condition, observed)| {
                        failure_with_trace(r, here, observed, condition, &trace)
                    },
                )
            }
            (TypeShape::Unknown(UnknownKind::Any), _) => data_failure(&g.profile, path.clone(), v)
                .map_or(ValueDecision::Accepted, |(here, condition, observed)| {
                    failure_with_trace(r, here, observed, condition, &trace)
                }),
            (TypeShape::Unit, JsonValue::Null) => ValueDecision::Accepted,
            (TypeShape::RawBody { .. }, _) => {
                if bytes_len(&g.profile, v).is_some() {
                    ValueDecision::Accepted
                } else {
                    reject(ValueCondition::InvalidBytes)
                }
            }
            (TypeShape::Opaque { type_name }, _) => {
                ValueDecision::Unresolved(vec![SemanticObligation {
                    type_ref: r.clone(),
                    origin: r.into(),
                    value_path: path,
                    profile: g.profile.reference.clone(),
                    reason: SemanticReason::OpaqueType(type_name.clone()),
                }])
            }
            (TypeShape::Boolean(_), _) => reject(ValueCondition::WrongValueKind("boolean".into())),
            (TypeShape::Decimal(_), _) => reject(ValueCondition::WrongValueKind("decimal".into())),
            (TypeShape::Array(_), _) => reject(ValueCondition::WrongValueKind("array".into())),
            (TypeShape::Product(_), _) => reject(ValueCondition::WrongValueKind("object".into())),
            (TypeShape::Sealed { .. }, _) => {
                reject(ValueCondition::WrongValueKind("sealed object".into()))
            }
            (TypeShape::Unknown(UnknownKind::OrdinaryObject), _) => {
                reject(ValueCondition::WrongValueKind("ordinary object".into()))
            }
            (TypeShape::Unit, _) => reject(ValueCondition::WrongValueKind("unit".into())),
        };
        seen.pop();
        result
    }
    go(g, r, v, vec![], &mut vec![])
}
pub fn accepts_slot(
    g: &SemanticGraph,
    s: &SlotContract,
    v: SlotValue<&JsonValue>,
) -> ValueDecision {
    match v {
        SlotValue::Absent if s.required => ValueDecision::Rejected(ValueFailure {
            type_ref: s.type_ref.clone(),
            definition_ref: DefinitionRef {
                source: s.type_ref.source.clone(),
                name: s.type_ref.definition_name.clone(),
            },
            origin: (&s.type_ref).into(),
            value_path: vec![],
            condition: ValueCondition::MissingRequired,
            observed: SlotValue::Absent,
            reference_trace: vec![],
        }),
        SlotValue::Null if !s.nullable => failure(
            &s.type_ref,
            vec![],
            JsonValue::Null,
            ValueCondition::NullNotAllowed,
        ),
        SlotValue::Present(v) => accepts_value(g, &s.type_ref, v),
        _ => ValueDecision::Accepted,
    }
}
fn node_meaning_reasons(graph: &SemanticGraph, reference: &TypeRef) -> Vec<SemanticReason> {
    let Some(node) = graph.find_type(reference) else {
        return vec![SemanticReason::UnresolvedType];
    };
    let mut reasons = Vec::new();
    match &node.shape {
        TypeShape::String(spec) => {
            if spec
                .lengths
                .iter()
                .any(|bound| bound.unit == StringLengthUnit::Graphemes)
                && graph.profile.grapheme_rules.is_none()
            {
                reasons.push(SemanticReason::MissingGraphemeRules);
            }
            if let Some(FormatUse::Named(name)) = &spec.format {
                if graph.profile.format(name).is_none() {
                    reasons.push(SemanticReason::UnknownFormat(name.clone()));
                }
            }
            if let Some(name) = &spec.wrapper {
                match graph
                    .profile
                    .wrappers
                    .iter()
                    .find(|wrapper| &wrapper.name == name)
                {
                    None => reasons.push(SemanticReason::UnknownWrapper(name.clone())),
                    Some(wrapper) if matches!(wrapper.payload, WrapperPayload::Bytes) => {
                        reasons.push(SemanticReason::WrapperPayload(name.clone()))
                    }
                    _ => {}
                }
            }
        }
        TypeShape::Integer(spec) => match graph.profile.integer_domain(spec.domain.as_deref()) {
            None => reasons.push(SemanticReason::UnknownIntegerDomain(
                spec.domain
                    .clone()
                    .unwrap_or_else(|| graph.profile.default_integer_domain.clone()),
            )),
            Some(binding) => {
                if let IntegerDomain::Inclusive { minimum, maximum } = &binding.range {
                    if spec.minimum.as_ref().is_some_and(|bound| bound < minimum)
                        || spec.maximum.as_ref().is_some_and(|bound| bound > maximum)
                    {
                        reasons.push(SemanticReason::IntegerBound);
                    }
                }
            }
        },
        TypeShape::Decimal(_) if !graph.profile.numbers.decimals => {
            reasons.push(SemanticReason::DecimalNotAdmitted)
        }
        TypeShape::Bytes(_) | TypeShape::RawBody { .. } if graph.profile.bytes_policy.is_none() => {
            reasons.push(SemanticReason::MissingBytesPolicy)
        }
        TypeShape::Sealed { tag, .. }
            if !graph
                .profile
                .tag
                .as_ref()
                .is_some_and(|model| model.sealed.iter().any(|form| &form.tag == tag)) =>
        {
            reasons.push(SemanticReason::UnknownSealedTag(tag.clone()))
        }
        TypeShape::TaggedUnion(spec)
            if graph.profile.tag.is_none()
                && spec
                    .branches
                    .iter()
                    .any(|branch| branch.selector == BranchSelector::InternalTag) =>
        {
            reasons.push(SemanticReason::MissingTagModel)
        }
        TypeShape::Opaque { type_name } => {
            reasons.push(SemanticReason::OpaqueType(type_name.clone()))
        }
        _ => {}
    }
    reasons
}

pub fn meaning_obligations(graph: &SemanticGraph, roots: &[TypeRef]) -> Vec<SemanticObligation> {
    let edges: usize = graph
        .nodes
        .iter()
        .map(|node| type_children(&node.shape).len())
        .sum();
    let mut pending: std::collections::VecDeque<TypeRef> = roots.iter().cloned().collect();
    let mut seen = HashSet::new();
    let mut reachable = Vec::new();
    for _ in 0..roots.len() + graph.nodes.len() + edges + 1 {
        let Some(reference) = pending.pop_front() else {
            break;
        };
        if !seen.insert(reference.clone()) {
            continue;
        }
        if let Some(node) = graph.find_type(&reference) {
            for child in type_children(&node.shape).into_iter().rev() {
                pending.push_front(child.clone());
            }
        }
        reachable.push(reference);
    }
    reachable
        .into_iter()
        .rev()
        .flat_map(|reference| {
            node_meaning_reasons(graph, &reference)
                .into_iter()
                .map(move |reason| SemanticObligation {
                    type_ref: reference.clone(),
                    origin: OccurrenceRef::from(&reference),
                    value_path: vec![],
                    profile: graph.profile.reference.clone(),
                    reason,
                })
        })
        .collect()
}

pub fn check_meaning_defined(g: &SemanticGraph, roots: &[TypeRef]) -> Result<(), MeaningFailure> {
    for obligation in meaning_obligations(g, roots) {
        let predicate = match obligation.reason {
            SemanticReason::UnknownFormat(_) => Some(MeaningObligation::Mo01),
            SemanticReason::MissingGraphemeRules => Some(MeaningObligation::Mo02),
            SemanticReason::MissingBytesPolicy => Some(MeaningObligation::Mo03),
            SemanticReason::UnknownIntegerDomain(_) => Some(MeaningObligation::Mo04),
            SemanticReason::UnknownWrapper(_) => Some(MeaningObligation::Mo05),
            SemanticReason::WrapperPayload(_) => Some(MeaningObligation::Mo06),
            SemanticReason::UnknownSealedTag(_) => Some(MeaningObligation::Mo07),
            SemanticReason::DecimalNotAdmitted => Some(MeaningObligation::Mo08),
            SemanticReason::IntegerBound => Some(MeaningObligation::Mo09),
            SemanticReason::OpaqueType(_) => Some(MeaningObligation::Mo10),
            SemanticReason::MissingTagModel => Some(MeaningObligation::Mo11),
            _ => None,
        };
        if let Some(predicate) = predicate {
            return Err(MeaningFailure {
                type_ref: obligation.type_ref,
                predicate,
                location: vec![],
            });
        }
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::panic)]
mod tests {
    use super::{accepts_value, recognize_format, recognize_language_tag};
    use crate::semantic_types::*;
    use num_bigint::BigUint;
    use std::sync::Arc;

    #[test]
    fn language_tag_recognition_matches_subtag_structure() {
        let grandfathered = ["en-GB-oed", "i-klingon", "sgn-BE-FR"];
        for (text, expected) in [
            ("x-private", true),
            ("X-1-AbC", true),
            ("en", true),
            ("en-US", true),
            ("zh-Hant-TW", true),
            ("en-1901", true),
            ("en-GB-oed", true),
            ("I-KLINGON", true),
            ("sgn-be-fr", true),
            ("zh-cmn-Hans-CN", true),
            ("abc-def-ghi-jkl-Latn-419-1901-abcde-a-abc-b-def-x-1", true),
            ("abcd-Latn-US", true),
            ("abcdefgh", true),
            ("en-419", true),
            ("sl-rozaj-biske-1994", true),
            ("en-a-abc-b-def", true),
            ("en-0-ab-9-cd", true),
            ("en-x-a-12345678", true),
            ("en-a-12345678-x-a", true),
            ("en-a", false),
            ("en-a-abc-a-def", false),
            ("en-a-abc-A-def", false),
            ("en-1901-1901", false),
            ("sl-rozaj-ROZAJ", false),
            ("", false),
            ("é", false),
            ("en-１２３", false),
            ("x", false),
            ("x-", false),
            ("x-123456789", false),
            ("x-a-!", false),
            ("e", false),
            ("abcdefghi", false),
            ("12", false),
            ("en-", false),
            ("en--US", false),
            ("-en", false),
            ("en_US", false),
            ("en US", false),
            ("en-US\n", false),
            ("abc-def-ghi-jkl-mno", false),
            ("abcd-efg", false),
            ("en-US-Latn", false),
            ("en-abcd", true),
            ("en-1abc", true),
            ("en-123456789", false),
            ("en-a-b-cd", false),
            ("en-a-abc-x", false),
            ("en-x", false),
            ("en-x-a-", false),
            ("en-x-123456789", false),
        ] {
            assert_eq!(
                recognize_language_tag(text, &grandfathered),
                expected,
                "{text:?}"
            );
        }
    }

    #[test]
    fn language_tag_recognition_uses_ascii_grandfathered_entries() {
        for (text, grandfathered, expected) in [
            ("I-CUSTOM", vec!["i-custom"], true),
            ("i-custom", vec![], false),
            ("", vec![""], false),
            ("é", vec!["é"], false),
            ("k", vec!["K"], false),
        ] {
            assert_eq!(
                recognize_language_tag(text, &grandfathered),
                expected,
                "{text:?}"
            );
        }
    }

    fn wrapper_failure_reference(name: &str) -> TypeRef {
        TypeRef::new(
            Arc::new(SourceRef {
                repository: "repo".into(),
                revision: "rev".into(),
                path: "types.json".into(),
                content_digest: "a".repeat(64),
                document_id: "wrappers".into(),
                declared_revision: None,
            }),
            name,
            vec![name.into()],
        )
    }

    fn wrapper_failure_graph(bytes_payload: bool) -> SemanticGraph {
        let field = if bytes_payload { "blob" } else { "cid" };
        let wrapper = if bytes_payload { "bytes" } else { "cid" };
        let key = if bytes_payload { "$bytes" } else { "$link" };
        let profile_ref = ProfileRef {
            identity: "profile".into(),
            revision: "1".into(),
            content_digest: "a".repeat(64),
        };
        let product = |field: &str, target: &str| {
            TypeShape::Product(ProductSpec {
                fields: vec![FieldSpec {
                    wire_name: field.into(),
                    slot: SlotContract {
                        type_ref: wrapper_failure_reference(target),
                        required: true,
                        nullable: false,
                    },
                    origin: OccurrenceRef::from(&wrapper_failure_reference(target)),
                }],
                extras: ExtraMembers::Reject,
            })
        };
        let leaf = if bytes_payload {
            TypeShape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            })
        } else {
            TypeShape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: Some(wrapper.into()),
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            })
        };
        SemanticGraph {
            profile: VersionedSemanticProfile {
                reference: profile_ref.clone(),
                source_refs: vec![],
                integer_domains: vec![],
                default_integer_domain: "integer".into(),
                numbers: NumberModel { decimals: true },
                grapheme_rules: None,
                format_bindings: vec![],
                bytes_policy: Some(BytesPolicy {
                    reference: profile_ref,
                    padding_optional: true,
                    alphabet: BytesAlphabet::Either,
                    strict_pad_bits: true,
                    wrapper: Some("bytes".into()),
                }),
                wrappers: vec![Wrapper {
                    name: wrapper.into(),
                    key: key.into(),
                    payload: if bytes_payload {
                        WrapperPayload::Bytes
                    } else {
                        WrapperPayload::Text { format: None }
                    },
                }],
                tag: None,
            },
            nodes: [
                ("leaf", leaf),
                ("operation", product(field, "leaf")),
                (
                    "operations",
                    TypeShape::Array(ArraySpec {
                        item: ElementContract {
                            type_ref: wrapper_failure_reference("operation"),
                            nullable: false,
                        },
                        min_length: None,
                        max_length: None,
                    }),
                ),
                ("root", product("ops", "operations")),
            ]
            .into_iter()
            .map(|(name, shape)| TypeNode {
                reference: wrapper_failure_reference(name),
                shape,
                description: None,
                attributes: vec![],
                extensions: vec![],
            })
            .collect(),
            source_refs: vec![],
        }
    }

    #[test]
    fn wrapper_decode_failure_keeps_value_location() {
        for bytes_payload in [false, true] {
            let graph = wrapper_failure_graph(bytes_payload);
            let field = if bytes_payload { "blob" } else { "cid" };
            let key = if bytes_payload { "$bytes" } else { "$link" };
            for invalid in [
                JsonValue::Str("invalid".into()),
                JsonValue::Obj(vec![]),
                JsonValue::Obj(vec![("wrong".into(), JsonValue::Str("x".into()))]),
                JsonValue::Obj(vec![(key.into(), JsonValue::Bool(false))]),
                JsonValue::Obj(vec![
                    (key.into(), JsonValue::Str("YQ==".into())),
                    ("extra".into(), JsonValue::Bool(true)),
                ]),
                JsonValue::Arr(vec![]),
            ] {
                let valid = JsonValue::Obj(vec![(key.into(), JsonValue::Str("YQ==".into()))]);
                let operation = JsonValue::Obj(vec![(field.into(), invalid.clone())]);
                let operations = JsonValue::Arr(vec![
                    JsonValue::Obj(vec![(field.into(), valid)]),
                    operation.clone(),
                ]);
                let root = JsonValue::Obj(vec![("ops".into(), operations.clone())]);
                for (reference, value, path, trace) in [
                    ("leaf", invalid.clone(), vec![], vec![]),
                    (
                        "operation",
                        operation,
                        vec![PathStep::Field(field.into())],
                        vec!["operation"],
                    ),
                    (
                        "operations",
                        operations,
                        vec![
                            PathStep::Index(BigUint::from(1u8)),
                            PathStep::Field(field.into()),
                        ],
                        vec!["operations", "operation"],
                    ),
                    (
                        "root",
                        root,
                        vec![
                            PathStep::Field("ops".into()),
                            PathStep::Index(BigUint::from(1u8)),
                            PathStep::Field(field.into()),
                        ],
                        vec!["root", "operations", "operation"],
                    ),
                ] {
                    let decision =
                        accepts_value(&graph, &wrapper_failure_reference(reference), &value);
                    let ValueDecision::Rejected(failure) = decision else {
                        panic!("expected wrapper failure: {decision:?}");
                    };
                    assert_eq!(failure.value_path, path);
                    assert_eq!(
                        failure.condition,
                        if bytes_payload {
                            ValueCondition::InvalidBytes
                        } else if matches!(&invalid, JsonValue::Obj(members)
                            if members.iter().any(|(name, _)| name == key))
                        {
                            ValueCondition::WrongValueKind("wrapper text".into())
                        } else {
                            ValueCondition::WrongValueKind("string wrapper".into())
                        }
                    );
                    assert_eq!(failure.type_ref, wrapper_failure_reference("leaf"));
                    assert_eq!(failure.observed, SlotValue::Present(invalid.clone()));
                    assert_eq!(
                        failure.reference_trace,
                        trace
                            .into_iter()
                            .map(wrapper_failure_reference)
                            .collect::<Vec<_>>()
                    );
                }
            }
        }
    }

    #[test]
    fn wrapper_decode_accepts_valid_nested_values() {
        for bytes_payload in [false, true] {
            let graph = wrapper_failure_graph(bytes_payload);
            let field = if bytes_payload { "blob" } else { "cid" };
            let key = if bytes_payload { "$bytes" } else { "$link" };
            let value = JsonValue::Obj(vec![(
                "ops".into(),
                JsonValue::Arr(vec![JsonValue::Obj(vec![(
                    field.into(),
                    JsonValue::Obj(vec![(key.into(), JsonValue::Str("YQ==".into()))]),
                )])]),
            )]);
            assert_eq!(
                accepts_value(&graph, &wrapper_failure_reference("root"), &value),
                ValueDecision::Accepted
            );
        }
    }

    fn sealed_wrapper_graph(leaf_wrapper: Option<String>) -> SemanticGraph {
        let mut graph = wrapper_failure_graph(false);
        graph.profile.wrappers = vec![Wrapper {
            name: "text".into(),
            key: "text".into(),
            payload: WrapperPayload::Text { format: None },
        }];
        graph.profile.bytes_policy = None;
        graph.profile.tag = Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![SealedField {
                    key: "label".into(),
                    required: true,
                    leaf: SealedLeaf::String(StringSpec {
                        format: None,
                        lengths: vec![],
                        wrapper: leaf_wrapper,
                        const_value: None,
                        enum_values: None,
                        examples: vec![],
                        default_value: None,
                    }),
                }],
                extras: SealedExtras::Reject,
            }],
        });
        let reference = wrapper_failure_reference("sealed");
        graph.nodes = vec![TypeNode {
            reference: reference.clone(),
            shape: TypeShape::Sealed {
                tag: "sealed".into(),
                refinements: vec![],
            },
            description: None,
            attributes: vec![],
            extensions: vec![],
        }];
        graph
    }

    #[test]
    fn sealed_leaf_wrapper_failure_keeps_field_path_and_wrapper_condition() {
        let graph = sealed_wrapper_graph(Some("text".into()));
        let reference = wrapper_failure_reference("sealed");
        for (label, condition) in [
            (
                JsonValue::Obj(vec![("text".into(), JsonValue::Bool(false))]),
                ValueCondition::WrongValueKind("wrapper text".into()),
            ),
            (
                JsonValue::Obj(vec![
                    ("text".into(), JsonValue::Str("hello".into())),
                    ("extra".into(), JsonValue::Bool(true)),
                ]),
                ValueCondition::WrongValueKind("wrapper text".into()),
            ),
            (
                JsonValue::Obj(vec![("wrong".into(), JsonValue::Str("hello".into()))]),
                ValueCondition::WrongValueKind("string".into()),
            ),
            (
                JsonValue::Bool(false),
                ValueCondition::WrongValueKind("string".into()),
            ),
        ] {
            let value = JsonValue::Obj(vec![
                ("kind".into(), JsonValue::Str("sealed".into())),
                ("label".into(), label),
            ]);
            let decision = accepts_value(&graph, &reference, &value);
            let ValueDecision::Rejected(failure) = decision else {
                panic!("expected sealed leaf failure: {decision:?}");
            };
            assert_eq!(failure.value_path, vec![PathStep::Field("label".into())]);
            assert_eq!(failure.condition, condition);
            assert_eq!(failure.type_ref, reference);
        }
        for label in [
            JsonValue::Str("hello".into()),
            JsonValue::Obj(vec![("text".into(), JsonValue::Str("hello".into()))]),
        ] {
            let value = JsonValue::Obj(vec![
                ("kind".into(), JsonValue::Str("sealed".into())),
                ("label".into(), label),
            ]);
            assert_eq!(
                accepts_value(&graph, &reference, &value),
                ValueDecision::Accepted
            );
        }
    }

    #[test]
    fn sealed_leaf_bytes_wrapper_validates_base64_payload() {
        let mut graph = sealed_wrapper_graph(None);
        graph.profile.wrappers.push(Wrapper {
            name: "bytes".into(),
            key: "bytes".into(),
            payload: WrapperPayload::Bytes,
        });
        graph.profile.bytes_policy = Some(BytesPolicy {
            reference: graph.profile.reference.clone(),
            padding_optional: true,
            alphabet: BytesAlphabet::Either,
            strict_pad_bits: true,
            wrapper: Some("bytes".into()),
        });
        let reference = wrapper_failure_reference("sealed");
        for (text, accepted) in [
            ("!", false),
            ("a", false),
            ("YQ===", false),
            ("YR==", false),
            ("YWJ=", false),
            ("YW+_", true),
            ("YQ==", true),
            ("YQ", true),
            ("YWJj", true),
            ("", true),
        ] {
            let value = JsonValue::Obj(vec![
                ("kind".into(), JsonValue::Str("sealed".into())),
                (
                    "label".into(),
                    JsonValue::Obj(vec![("bytes".into(), JsonValue::Str(text.into()))]),
                ),
            ]);
            let decision = accepts_value(&graph, &reference, &value);
            if accepted {
                assert_eq!(decision, ValueDecision::Accepted);
            } else {
                let ValueDecision::Rejected(failure) = decision else {
                    panic!("expected bytes wrapper failure: {decision:?}");
                };
                assert_eq!(failure.value_path, vec![PathStep::Field("label".into())]);
                assert_eq!(failure.condition, ValueCondition::InvalidBytes);
            }
        }
    }

    #[test]
    fn sealed_leaf_text_wrapper_validates_profile_format() {
        let mut graph = sealed_wrapper_graph(None);
        graph.profile.wrappers = vec![Wrapper {
            name: "text".into(),
            key: "text".into(),
            payload: WrapperPayload::Text {
                format: Some("wrapper-format".into()),
            },
        }];
        graph.profile.format_bindings.push(FormatBinding {
            name: "wrapper-format".into(),
            reference: graph.profile.reference.clone(),
            rule: FormatRule::Literal("hello".into()),
        });
        let reference = wrapper_failure_reference("sealed");
        for (text, accepted) in [("hello", true), ("wrong", false)] {
            let value = JsonValue::Obj(vec![
                ("kind".into(), JsonValue::Str("sealed".into())),
                (
                    "label".into(),
                    JsonValue::Obj(vec![("text".into(), JsonValue::Str(text.into()))]),
                ),
            ]);
            let decision = accepts_value(&graph, &reference, &value);
            if accepted {
                assert_eq!(decision, ValueDecision::Accepted);
            } else {
                let ValueDecision::Rejected(failure) = decision else {
                    panic!("expected text wrapper failure: {decision:?}");
                };
                assert_eq!(failure.value_path, vec![PathStep::Field("label".into())]);
                assert_eq!(
                    failure.condition,
                    ValueCondition::Format("wrapper-format".into())
                );
            }
        }
    }
    #[test]
    fn wrapper_base64_vectors_match_lean() -> Result<(), Box<dyn std::error::Error>> {
        use crate::semantic_exchange::{decode_type_signatures, wire_value};
        use crate::signature_admission::check_type_signatures;
        use serde_json::{json, Value};
        use std::collections::HashSet;

        let vectors: Value = serde_json::from_str(include_str!(
            "../../comparison/declaration/wrapper_base64_vectors.json"
        ))?;
        assert_eq!(
            vectors.get("schema"),
            Some(&json!("wrapper-base64-vectors@1"))
        );
        let profiles = vectors.get("profiles").ok_or("missing profiles")?;
        let type_graphs = vectors.get("type_graphs").ok_or("missing type graphs")?;
        let branches = vectors
            .get("branches")
            .and_then(Value::as_array)
            .ok_or("missing branches")?;
        assert_eq!(branches.len(), 25);
        let mut branch_ids = HashSet::new();
        let mut case_ids = HashSet::new();
        for branch in branches {
            let branch_id = branch
                .get("id")
                .and_then(Value::as_str)
                .ok_or("branch id")?;
            assert!(branch_ids.insert(branch_id), "{branch_id}");
            let profile_id = branch
                .get("profile")
                .and_then(Value::as_str)
                .ok_or("profile id")?;
            let graph_id = branch
                .get("type_graph")
                .and_then(Value::as_str)
                .ok_or("graph id")?;
            let type_graph = type_graphs.get(graph_id).ok_or("unknown type graph")?;
            let root_id = type_graph
                .get("root")
                .and_then(Value::as_str)
                .ok_or("root id")?;
            let library = decode_type_signatures(
                &json!({
                    "schema": "ncoh-type-signatures@1",
                    "identity": "wrapper-base64",
                    "revision": "1",
                    "profile": profiles.get(profile_id).ok_or("unknown profile")?,
                    "sources": [],
                    "provenance": [],
                    "groups": [],
                    "annotations": [],
                    "nodes": type_graph.get("nodes").ok_or("missing nodes")?,
                    "definitions": []
                })
                .to_string(),
            )?;
            let graph = check_type_signatures(&library)?;
            let root = &graph
                .nodes
                .iter()
                .find(|node| node.reference.definition_name.as_ref() == root_id)
                .ok_or("unknown root")?
                .reference;
            let cases = branch
                .get("cases")
                .and_then(Value::as_array)
                .ok_or("missing cases")?;
            assert!(!cases.is_empty(), "{branch_id}");
            for case in cases {
                let case_id = case.get("id").and_then(Value::as_str).ok_or("case id")?;
                assert!(case_ids.insert(case_id), "{case_id}");
                let input: JsonValue =
                    serde_json::from_value(case.get("input").ok_or("missing input")?.clone())?;
                let expected = case.get("expected").ok_or("missing expected outcome")?;
                let actual = match accepts_value(&graph, root, &input) {
                    ValueDecision::Accepted => {
                        json!({"accepted": true, "condition": null, "path": []})
                    }
                    ValueDecision::Rejected(failure) => json!({
                        "accepted": false,
                        "condition": wire_value(&failure.condition)?,
                        "path": wire_value(&failure.value_path)?
                    }),
                    decision => return Err(format!("{case_id}: {decision:?}").into()),
                };
                assert_eq!(&actual, expected, "{case_id}");
                if graph_id == "bytes" || graph_id == "bounded-bytes" {
                    let decoded =
                        crate::semantic_codegen_runtime::bytes_decode(&graph.profile, input);
                    let decodable = expected.get("accepted") == Some(&json!(true))
                        || expected.get("condition") == Some(&json!({"tag": "BytesLength"}));
                    assert_eq!(decoded.is_ok(), decodable, "{case_id}: {decoded:?}");
                }
            }
        }
        assert_eq!(case_ids.len(), 55);
        Ok(())
    }

    #[test]
    fn bytes_decode_preserves_payload_under_profile_policy(
    ) -> Result<(), Box<dyn std::error::Error>> {
        use crate::semantic_codegen_runtime::{bytes_decode, bytes_encode};

        let mut profile = wrapper_failure_graph(true).profile;
        for alphabet in [
            BytesAlphabet::Standard,
            BytesAlphabet::UrlSafe,
            BytesAlphabet::Either,
        ] {
            for padding_optional in [false, true] {
                let policy = profile
                    .bytes_policy
                    .as_mut()
                    .ok_or("missing bytes policy")?;
                policy.alphabet = alphabet;
                policy.padding_optional = padding_optional;
                for bytes in [&[][..], &[0][..], &[251, 255][..], &[255, 255, 255][..]] {
                    let encoded = bytes_encode(&profile, bytes)?;
                    assert_eq!(bytes_decode(&profile, encoded)?, bytes);
                }
            }
        }
        for text in ["+/8=", "-_8=", "+_8=", "-/8="] {
            let value = JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str(text.into()))]);
            assert_eq!(bytes_decode(&profile, value)?, vec![251, 255]);
        }
        Ok(())
    }

    #[test]
    fn sequence_grouping_preserves_concatenation_and_empty_parts() {
        let literal = |text: &str| FormatRule::Literal(text.into());
        let sequence = FormatRule::Sequence;
        let first = FormatRule::Choice(vec![literal(""), literal("a")]);
        let second = FormatRule::Optional(Box::new(literal("😀")));
        let third = literal("!");
        let rules = [
            sequence(vec![first.clone(), second.clone(), third.clone()]),
            sequence(vec![
                sequence(vec![first.clone(), second.clone()]),
                third.clone(),
            ]),
            sequence(vec![
                first.clone(),
                sequence(vec![second.clone(), third.clone()]),
            ]),
            sequence(vec![
                sequence(vec![]),
                first,
                second,
                sequence(vec![third]),
                sequence(vec![]),
            ]),
        ];
        for text in ["", "!", "a!", "😀!", "a😀!", "aa!", "😀a!", "a😀", "x!"] {
            for rule in &rules {
                assert_eq!(
                    recognize_format(rule, text),
                    ["!", "a!", "😀!", "a😀!"].contains(&text)
                );
            }
        }
        assert!(recognize_format(&sequence(vec![]), ""));
        assert!(!recognize_format(&sequence(vec![]), "a"));
        let negated = sequence(vec![
            literal("["),
            FormatRule::Not(Box::new(sequence(vec![literal("a"), literal("😀")]))),
            literal("]"),
        ]);
        assert!(recognize_format(&negated, "[]"));
        assert!(recognize_format(&negated, "[😀]"));
        assert!(!recognize_format(&negated, "[a😀]"));
    }

    #[test]
    fn sequence_labels_preserve_scalar_offsets_and_byte_bounds() {
        let literal = |text: &str| FormatRule::Literal(text.into());
        let child = FormatRule::Sequence(vec![
            FormatRule::Optional(Box::new(literal("a"))),
            literal("😀"),
        ]);
        let inner = FormatRule::Labels {
            separator: "🔹".into(),
            min_count: 2u8.into(),
            max_count: Some(2u8.into()),
            total_max: Some(13u8.into()),
            rule: Box::new(child),
        };
        let rule = FormatRule::Sequence(vec![literal("["), inner, literal("]")]);
        for (text, expected) in [
            ("[😀🔹a😀]", true),
            ("[a😀🔹😀]", true),
            ("[😀🔹b😀]", false),
            ("[😀🔹😀🔹😀]", false),
            ("[a😀🔹a😀]", false),
        ] {
            assert_eq!(recognize_format(&rule, text), expected);
        }
        let bounded = |maximum: u8| FormatRule::Bounded {
            unit: StringLengthUnit::Utf8Bytes,
            maximum: maximum.into(),
            rule: Box::new(rule.clone()),
        };
        assert!(recognize_format(&bounded(15), "[😀🔹a😀]"));
        assert!(!recognize_format(&bounded(14), "[😀🔹a😀]"));
    }

    #[test]
    fn flat_sequence_with_600_parts_preserves_acceptance_and_rejection() {
        let mut parts = vec![FormatRule::Literal(String::new()); 600];
        let rule = FormatRule::Sequence(parts.clone());
        assert!(recognize_format(&rule, ""));
        assert!(!recognize_format(&rule, "x"));
        parts.push(FormatRule::Literal("x".into()));
        let suffix = FormatRule::Sequence(parts);
        assert!(recognize_format(&suffix, "x"));
        assert!(!recognize_format(&suffix, ""));
    }
}
