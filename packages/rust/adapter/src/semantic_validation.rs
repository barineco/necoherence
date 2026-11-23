// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

pub use crate::default_materialization::{
    check_default_applications, decode_with_defaults, materialize_defaults, DefaultApplication,
    DefaultFailure, DefaultedValue,
};
use crate::exact_json_view::JsonValueView;
pub(crate) use crate::semantic_expansion::{decide_slot_in, sealed_fields_failure};
pub use crate::semantic_expansion::{
    BorrowedValueDecision, DiagnosticRecipe, Expansion, MemberCertificate, MemberProof,
    ValidatedSlot, ValidatedValue, ValidationFailure, ValueRequirement,
};
use crate::semantic_numeric::{parse_integer, PreparedInteger};
pub use crate::semantic_prepared_validation::PreparedValidator;
use crate::semantic_prepared_validation::{
    ClassRef, NodeIndex, PreparedLeaf, PreparedProfile, PreparedStringSpec, PreparedUse,
};
use crate::semantic_types::*;
use num_bigint::{BigInt, BigUint};
use num_traits::Zero;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

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
                            && t.last < BigUint::from(128u8)
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
                ..
            } => {
                !first_alphabet.is_empty()
                    && !rest_alphabet.is_empty()
                    && first_alphabet.is_ascii()
                    && rest_alphabet.is_ascii()
                    && max_length.as_ref().is_none_or(|m| min_length <= m)
                    && exact_length.as_ref().is_none_or(|e| {
                        min_length <= e && max_length.as_ref().is_none_or(|m| e <= m)
                    })
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
fn profile_failure(p: &VersionedSemanticProfile) -> Option<ProfileFailure> {
    let fail = |predicate, location: &[&str]| {
        Some(ProfileFailure {
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
        .any(|x| !profile_range_valid(&x.range))
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
                    p.format(f).is_none_or(|b| {
                        !recognize_format(&b.rule, p.grapheme_rules.as_ref(), &x.tag)
                    })
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
                SealedLeaf::String(spec) => {
                    spec.wrapper.as_ref().is_some_and(|name| {
                        !p.wrappers.iter().any(|wrapper| {
                            wrapper.name == *name
                                && matches!(wrapper.payload, WrapperPayload::Text { .. })
                        })
                    }) || spec.format.as_ref().is_some_and(|format| match format {
                        FormatUse::Named(name) => p.format(name).is_none(),
                        FormatUse::Inline(rule) => !format_rule_well_formed(rule),
                    }) || spec
                        .lengths
                        .iter()
                        .any(|bound| !profile_length_valid(bound))
                }
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
    None
}
pub fn check_profile(p: &VersionedSemanticProfile) -> Result<CheckedProfile, ProfileFailure> {
    match profile_failure(p) {
        Some(failure) => Err(failure),
        None => Ok(CheckedProfile { profile: p.clone() }),
    }
}
fn profile_range_valid(range: &IntegerDomain) -> bool {
    !matches!(range, IntegerDomain::Inclusive{minimum,maximum} if minimum>maximum)
}
fn profile_length_valid(bound: &LengthBound) -> bool {
    !matches!((&bound.minimum, &bound.maximum), (Some(a), Some(z)) if a > z)
}

fn measured_length(
    unit: &StringLengthUnit,
    graphemes: Option<&GraphemeSource<'_>>,
    text: &str,
) -> Option<usize> {
    match unit {
        StringLengthUnit::Utf8Bytes => Some(text.len()),
        StringLengthUnit::UnicodeScalars => Some(text.chars().count()),
        StringLengthUnit::Graphemes => graphemes.map(|source| source.table().count(text)),
    }
}
fn length_bounds_failure(
    graphemes: Option<&GraphemeSource<'_>>,
    text: &str,
    bounds: &[LengthBound],
) -> bool {
    let mut measured: [Option<Option<usize>>; 3] = [None; 3];
    bounds.iter().any(|bound| {
        let slot = match bound.unit {
            StringLengthUnit::Utf8Bytes => &mut measured[0],
            StringLengthUnit::UnicodeScalars => &mut measured[1],
            StringLengthUnit::Graphemes => &mut measured[2],
        };
        slot.get_or_insert_with(|| measured_length(&bound.unit, graphemes, text))
            .is_none_or(|measured| {
                !bounded(&BigUint::from(measured), &bound.minimum, &bound.maximum)
            })
    })
}
const MAX_CODEPOINT: u32 = 0x10FFFF;
fn codepoint_range(first: &BigUint, last: &BigUint) -> Option<(u32, u32)> {
    let first = u32::try_from(first)
        .ok()
        .filter(|first| *first <= MAX_CODEPOINT)?;
    let last = u32::try_from(last).map_or(MAX_CODEPOINT, |last| last.min(MAX_CODEPOINT));
    (first <= last).then_some((first, last))
}
fn flatten_ranges<T: Copy>(ranges: impl Iterator<Item = (u32, u32, T)>) -> Vec<(u32, u32, T)> {
    let ranges: Vec<(u32, u32, T)> = ranges.collect();
    if ranges
        .windows(2)
        .all(|pair| matches!(pair, [(_, last, _), (first, _, _)] if last < first))
    {
        return ranges;
    }
    let mut covered: std::collections::BTreeMap<u32, (u32, T)> = std::collections::BTreeMap::new();
    for (first, last, value) in ranges {
        let mut overlapping: Vec<(u32, u32)> = covered
            .range(..=last)
            .rev()
            .take_while(|(_, (end, _))| *end >= first)
            .map(|(start, (end, _))| (*start, *end))
            .collect();
        overlapping.reverse();
        let mut cursor = Some(first);
        for (start, end) in overlapping {
            if let Some(from) = cursor.filter(|from| *from < start) {
                covered.insert(from, (start - 1, value));
            }
            cursor = end.checked_add(1);
        }
        if let Some(from) = cursor.filter(|from| *from <= last) {
            covered.insert(from, (last, value));
        }
    }
    covered
        .into_iter()
        .map(|(first, (last, value))| (first, last, value))
        .collect()
}
fn table_lookup<T: Copy>(table: &[(u32, u32, T)], codepoint: u32) -> Option<T> {
    let index = table.partition_point(|(_, last, _)| *last < codepoint);
    table
        .get(index)
        .filter(|(first, _, _)| *first <= codepoint)
        .map(|(_, _, value)| *value)
}
pub(crate) struct GraphemeTable {
    properties: Vec<(u32, u32, GraphemeProperty)>,
    indic_conjunct: Vec<(u32, u32, IndicProperty)>,
    extended_pictographic: Vec<(u32, u32, ())>,
}
impl GraphemeTable {
    fn new(rules: &GraphemeRules) -> Self {
        Self {
            properties: flatten_ranges(rules.properties.iter().filter_map(|range| {
                codepoint_range(&range.first, &range.last)
                    .map(|(first, last)| (first, last, range.property))
            })),
            indic_conjunct: flatten_ranges(rules.indic_conjunct.iter().filter_map(|range| {
                codepoint_range(&range.first, &range.last)
                    .map(|(first, last)| (first, last, range.property))
            })),
            extended_pictographic: flatten_ranges(
                rules
                    .extended_pictographic
                    .iter()
                    .filter_map(|range| codepoint_range(&range.first, &range.last))
                    .map(|(first, last)| (first, last, ())),
            ),
        }
    }
    fn property(&self, character: char) -> GraphemeProperty {
        table_lookup(&self.properties, u32::from(character)).unwrap_or(GraphemeProperty::Other)
    }
    fn indic(&self, character: char) -> IndicProperty {
        table_lookup(&self.indic_conjunct, u32::from(character)).unwrap_or(IndicProperty::Other)
    }
    fn pictographic(&self, character: char) -> bool {
        table_lookup(&self.extended_pictographic, u32::from(character)).is_some()
    }
    fn count(&self, text: &str) -> usize {
        let mut state = GraphemeState::default();
        let mut count = 0usize;
        for character in text.chars() {
            if grapheme_step(&mut state, self, character) {
                count += 1;
            }
        }
        count
    }
}
#[derive(Clone)]
pub(crate) struct GraphemeSource<'r> {
    rules: std::marker::PhantomData<&'r GraphemeRules>,
    table: Arc<GraphemeTable>,
}
impl<'r> GraphemeSource<'r> {
    pub(crate) fn new(rules: &'r GraphemeRules) -> Self {
        Self {
            rules: std::marker::PhantomData,
            table: Arc::new(GraphemeTable::new(rules)),
        }
    }
    fn table(&self) -> &GraphemeTable {
        &self.table
    }
}
pub fn grapheme_count(rules: &GraphemeRules, text: &str) -> usize {
    GraphemeTable::new(rules).count(text)
}
#[derive(Default)]
struct GraphemeState {
    previous: Option<GraphemeProperty>,
    regional_run: usize,
    pictographic_extends: bool,
    previous_zwj_after_pictographic: bool,
    indic_consonant: bool,
    indic_linker: bool,
}
fn control_property(property: GraphemeProperty) -> bool {
    use GraphemeProperty::*;
    matches!(property, Cr | Lf | Control)
}
fn grapheme_break(
    state: &GraphemeState,
    property: GraphemeProperty,
    indic: IndicProperty,
    pictographic: bool,
) -> bool {
    use GraphemeProperty::*;
    match state.previous {
        None => true,
        Some(Cr) if property == Lf => false,
        Some(previous) if control_property(previous) || control_property(property) => true,
        Some(L) if matches!(property, L | V | Lv | Lvt) => false,
        Some(Lv | V) if matches!(property, V | T) => false,
        Some(Lvt | T) if property == T => false,
        _ if matches!(property, Extend | Zwj | SpacingMark) => false,
        Some(Prepend) => false,
        _ if indic == IndicProperty::Consonant && state.indic_consonant && state.indic_linker => {
            false
        }
        Some(Zwj) if pictographic && state.previous_zwj_after_pictographic => false,
        Some(RegionalIndicator) if property == RegionalIndicator && state.regional_run % 2 == 1 => {
            false
        }
        _ => true,
    }
}
fn grapheme_step(state: &mut GraphemeState, table: &GraphemeTable, character: char) -> bool {
    use GraphemeProperty::*;
    let property = table.property(character);
    let indic = table.indic(character);
    let pictographic = table.pictographic(character);
    let breaks = grapheme_break(state, property, indic, pictographic);
    let zwj_after_pictographic = property == Zwj && state.pictographic_extends;
    state.pictographic_extends = pictographic || (property == Extend && state.pictographic_extends);
    state.previous_zwj_after_pictographic = zwj_after_pictographic;
    match indic {
        IndicProperty::Consonant => {
            state.indic_consonant = true;
            state.indic_linker = false;
        }
        IndicProperty::Linker if state.indic_consonant => state.indic_linker = true,
        IndicProperty::Extend | IndicProperty::Linker => {}
        IndicProperty::Other => {
            state.indic_consonant = false;
            state.indic_linker = false;
        }
    }
    state.regional_run = if property == RegionalIndicator {
        if state.previous == Some(RegionalIndicator) {
            state.regional_run + 1
        } else {
            1
        }
    } else {
        0
    };
    state.previous = Some(property);
    breaks
}
pub(crate) fn bounded<T: Ord>(v: &T, a: &Option<T>, b: &Option<T>) -> bool {
    a.as_ref().is_none_or(|x| x <= v) && b.as_ref().is_none_or(|x| v <= x)
}
fn ascii_alpha(byte: u8) -> bool {
    byte.is_ascii_alphabetic()
}
fn ascii_digit(byte: u8) -> bool {
    byte.is_ascii_digit()
}
fn ascii_alnum(byte: u8) -> bool {
    ascii_alpha(byte) || ascii_digit(byte)
}
fn ascii_hex(byte: u8) -> bool {
    byte.is_ascii_hexdigit()
}
fn uri_unreserved(byte: u8) -> bool {
    ascii_alnum(byte) || b"-._~".contains(&byte)
}
fn uri_subdelim(byte: u8) -> bool {
    b"!$&'()*+,;=".contains(&byte)
}
fn uri_chars(extra: impl Fn(u8) -> bool, text: &[u8]) -> bool {
    let mut rest = text;
    loop {
        match rest {
            [] => return true,
            [b'%', high, low, tail @ ..] => {
                if !(ascii_hex(*high) && ascii_hex(*low)) {
                    return false;
                }
                rest = tail;
            }
            [b'%', ..] => return false,
            [byte, tail @ ..] => {
                if !(uri_unreserved(*byte) || uri_subdelim(*byte) || extra(*byte)) {
                    return false;
                }
                rest = tail;
            }
        }
    }
}
fn split_byte(delimiter: u8, text: &[u8]) -> (&[u8], Option<&[u8]>) {
    match text.iter().position(|byte| *byte == delimiter) {
        Some(index) => {
            let (before, after) = text.split_at(index);
            (before, Some(after.get(1..).unwrap_or_default()))
        }
        None => (text, None),
    }
}
fn nonempty_chars(text: &[u8], test: fn(u8) -> bool) -> bool {
    !text.is_empty() && text.iter().all(|byte| test(*byte))
}
fn ipv4(text: &[u8]) -> bool {
    let mut count = 0usize;
    let valid = text.split(|byte| *byte == b'.').all(|part| {
        count += 1;
        nonempty_chars(part, ascii_digit)
            && part.len() <= 3
            && (part == b"0" || part.first() != Some(&b'0'))
            && part
                .iter()
                .fold(0u32, |value, byte| value * 10 + u32::from(*byte - b'0'))
                <= 255
    });
    valid && count == 4
}
fn ipv6_group_count(text: &[u8]) -> Option<usize> {
    let mut parts = text.split(|byte| *byte == b':').peekable();
    let mut count = 0usize;
    while let Some(part) = parts.next() {
        if parts.peek().is_none() {
            return if part.contains(&b'.') {
                ipv4(part).then_some(count + 2)
            } else if !part.is_empty()
                && part.len() <= 4
                && part.iter().all(|byte| ascii_hex(*byte))
            {
                Some(count + 1)
            } else {
                None
            };
        }
        if part.is_empty() || part.len() > 4 || !part.iter().all(|byte| ascii_hex(*byte)) {
            return None;
        }
        count += 1;
    }
    Some(count)
}
fn split_double_colon(text: &[u8]) -> Option<(&[u8], Option<&[u8]>)> {
    let Some(index) = text.windows(2).position(|pair| pair == b"::") else {
        return Some((text, None));
    };
    let (before, after) = text.split_at(index);
    let after = after.get(2..).unwrap_or_default();
    (!after.windows(2).any(|pair| pair == b"::")).then_some((before, Some(after)))
}
fn ipv6(text: &[u8]) -> bool {
    let Some(parts) = split_double_colon(text) else {
        return false;
    };
    match parts {
        (whole, None) => ipv6_group_count(whole) == Some(8),
        (before, Some(after)) => {
            let left = if before.is_empty() {
                Some(0)
            } else {
                ipv6_group_count(before)
            };
            let right = if after.is_empty() {
                Some(0)
            } else {
                ipv6_group_count(after)
            };
            match (left, right) {
                (Some(left), Some(right)) => left + right < 8 && !before.contains(&b'.'),
                _ => false,
            }
        }
    }
}
fn ip_literal(text: &[u8]) -> bool {
    match text {
        [b'v' | b'V', ..] => match split_byte(b'.', text) {
            (version, Some(address)) => {
                let digits = version.get(1..).unwrap_or_default();
                !digits.is_empty()
                    && digits.iter().all(|byte| ascii_hex(*byte))
                    && !address.is_empty()
                    && address
                        .iter()
                        .all(|byte| uri_unreserved(*byte) || uri_subdelim(*byte) || *byte == b':')
            }
            (_, None) => false,
        },
        _ => ipv6(text),
    }
}
fn uri_host_port(text: &[u8]) -> bool {
    match text {
        [b'[', rest @ ..] => {
            let (host, after) = split_byte(b']', rest);
            ip_literal(host)
                && match after {
                    Some([]) => true,
                    Some([b':', port @ ..]) => port.iter().all(|byte| ascii_digit(*byte)),
                    _ => false,
                }
        }
        _ => {
            let (host, port) = split_byte(b':', text);
            uri_chars(|_| false, host)
                && match port {
                    None => true,
                    Some(digits) => digits.iter().all(|byte| ascii_digit(*byte)),
                }
        }
    }
}
fn uri_authority(text: &[u8]) -> bool {
    let (before, after) = split_byte(b'@', text);
    match after {
        None => uri_host_port(before),
        Some(host) => {
            uri_chars(|byte| byte == b':', before) && !host.contains(&b'@') && uri_host_port(host)
        }
    }
}
fn uri_syntax(text: &str) -> bool {
    if !text.is_ascii() {
        return false;
    }
    let (scheme, tail) = split_byte(b':', text.as_bytes());
    let scheme_ok = match scheme {
        [first, rest @ ..] => {
            ascii_alpha(*first)
                && rest
                    .iter()
                    .all(|byte| ascii_alnum(*byte) || b"+-.".contains(byte))
        }
        [] => false,
    };
    scheme_ok
        && match tail {
            None => false,
            Some(tail) => {
                let (before_fragment, fragment) = split_byte(b'#', tail);
                let (hierarchy, query) = split_byte(b'?', before_fragment);
                let path_ok = match hierarchy {
                    [b'/', b'/', rest @ ..] => {
                        let authority_length = rest
                            .iter()
                            .position(|byte| *byte == b'/')
                            .unwrap_or(rest.len());
                        let (authority, path) = rest.split_at(authority_length);
                        uri_authority(authority)
                            && uri_chars(|byte| matches!(byte, b':' | b'@' | b'/'), path)
                    }
                    rest => uri_chars(|byte| matches!(byte, b':' | b'@' | b'/'), rest),
                };
                path_ok
                    && query.is_none_or(|query| {
                        uri_chars(|byte| matches!(byte, b':' | b'@' | b'/' | b'?'), query)
                    })
                    && fragment.is_none_or(|fragment| {
                        uri_chars(|byte| matches!(byte, b':' | b'@' | b'/' | b'?'), fragment)
                    })
            }
        }
}
fn absolute_uri(text: &str, maximum: Option<&BigUint>) -> bool {
    let within = maximum.is_none_or(|bound| {
        num_traits::ToPrimitive::to_u64(bound)
            .is_none_or(|bound| u64::try_from(text.len()).is_ok_and(|length| length <= bound))
    });
    within && uri_syntax(text)
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
fn leap_year(year: u32) -> bool {
    year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
}
fn month_days(year: u32, month: u32) -> Option<u32> {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => Some(31),
        4 | 6 | 9 | 11 => Some(30),
        2 => Some(if leap_year(year) { 29 } else { 28 }),
        _ => None,
    }
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
    let Some(month_days) = month_days(year, month) else {
        return false;
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
type LanguageParts<'a> = std::iter::Peekable<std::str::Split<'a, char>>;

fn language_subtag(minimum: usize, maximum: usize, text: &str) -> bool {
    (minimum..=maximum).contains(&text.len()) && text.bytes().all(ascii_alnum)
}
fn language_extensions(parts: &mut LanguageParts<'_>) -> bool {
    let mut seen = 0u64;
    loop {
        let Some(&part) = parts.peek() else {
            return true;
        };
        parts.next();
        if part.eq_ignore_ascii_case("x") {
            let mut count = 0;
            return parts.all(|part| {
                count += 1;
                language_subtag(1, 8, part)
            }) && count > 0;
        }
        if part.len() != 1 || !part.bytes().all(ascii_alnum) {
            return false;
        }
        let Some(byte) = part.bytes().next() else {
            return false;
        };
        let code = if byte.is_ascii_digit() {
            byte - b'0'
        } else {
            byte.to_ascii_lowercase() - b'a' + 10
        };
        let mask = 1u64 << code;
        if seen & mask != 0 {
            return false;
        }
        seen |= mask;
        let mut values = 0usize;
        while parts.peek().is_some_and(|part| language_subtag(2, 8, part)) {
            parts.next();
            values += 1;
        }
        if values == 0 {
            return false;
        }
    }
}
fn language_variants(parts: &mut LanguageParts<'_>) -> bool {
    let variant_start = parts.clone();
    let mut variants = 0usize;
    loop {
        let Some(&part) = parts.peek() else {
            return true;
        };
        let variant = language_subtag(5, 8, part)
            || (part.len() == 4
                && part.bytes().all(ascii_alnum)
                && part.bytes().next().is_some_and(ascii_digit));
        if !variant {
            return language_extensions(parts);
        }
        if variant_start
            .clone()
            .take(variants)
            .any(|earlier| earlier.eq_ignore_ascii_case(part))
        {
            return false;
        }
        parts.next();
        variants += 1;
    }
}
pub fn recognize_language_tag<S: AsRef<str>>(text: &str, grandfathered: &[S]) -> bool {
    if !text.is_ascii() {
        return false;
    }
    if grandfathered
        .iter()
        .any(|entry| entry.as_ref().eq_ignore_ascii_case(text))
    {
        return true;
    }
    let mut parts = text.split('-').peekable();
    let Some(primary) = parts.next() else {
        return false;
    };
    if primary.eq_ignore_ascii_case("x") {
        let mut count = 0;
        return parts.all(|part| {
            count += 1;
            language_subtag(1, 8, part)
        }) && count > 0;
    }
    if !primary.bytes().all(ascii_alpha) || !(2..=8).contains(&primary.len()) {
        return false;
    }
    if primary.len() <= 3 {
        for _ in 0..3 {
            if !parts
                .peek()
                .is_some_and(|part| part.len() == 3 && part.bytes().all(ascii_alpha))
            {
                break;
            }
            parts.next();
        }
    }
    if parts
        .peek()
        .is_some_and(|part| part.len() == 4 && part.bytes().all(ascii_alpha))
    {
        parts.next();
    }
    if parts.peek().is_some_and(|part| {
        (part.len() == 2 && part.bytes().all(ascii_alpha))
            || (part.len() == 3 && part.bytes().all(ascii_digit))
    }) {
        parts.next();
    }
    language_variants(&mut parts)
}

struct FormatSpanNode<'a> {
    id: usize,
    min_width: usize,
    max_width: Option<usize>,
    kind: FormatSpanKind<'a>,
}

impl<'a> FormatSpanNode<'a> {
    fn new(id: usize, kind: FormatSpanKind<'a>) -> Self {
        let (min_width, max_width) = span_width(&kind);
        Self {
            id,
            min_width,
            max_width,
            kind,
        }
    }

    fn admits(&self, width: usize) -> bool {
        self.min_width <= width && self.max_width.is_none_or(|maximum| width <= maximum)
    }
}

fn cap_width(width: Option<usize>, bound: Option<&BigUint>) -> Option<usize> {
    match (width, bound.and_then(|bound| usize::try_from(bound).ok())) {
        (Some(width), Some(bound)) => Some(width.min(bound)),
        (width, bound) => width.or(bound),
    }
}

fn rule_width(rule: &FormatRule) -> (usize, Option<usize>) {
    match rule {
        FormatRule::Literal(text) => {
            let width = text.chars().count();
            (width, Some(width))
        }
        FormatRule::Identifier {
            exact_length,
            max_length,
            ..
        } => (
            1,
            cap_width(cap_width(None, exact_length.as_ref()), max_length.as_ref()),
        ),
        _ => (0, None),
    }
}

fn span_width(kind: &FormatSpanKind<'_>) -> (usize, Option<usize>) {
    match kind {
        FormatSpanKind::Epsilon => (0, Some(0)),
        FormatSpanKind::Sequence(left, right) => (
            left.min_width.saturating_add(right.min_width),
            left.max_width
                .zip(right.max_width)
                .and_then(|(left, right)| left.checked_add(right)),
        ),
        FormatSpanKind::Not(_) => (0, None),
        FormatSpanKind::Optional(child) => (0, child.max_width),
        FormatSpanKind::Choice(children) => (
            children
                .iter()
                .map(|child| child.min_width)
                .min()
                .unwrap_or(0),
            children.iter().try_fold(0, |maximum: usize, child| {
                child.max_width.map(|width| maximum.max(width))
            }),
        ),
        FormatSpanKind::Bounded(unit, maximum, child) => match unit {
            StringLengthUnit::Utf8Bytes | StringLengthUnit::UnicodeScalars => {
                (child.min_width, cap_width(child.max_width, Some(maximum)))
            }
            StringLengthUnit::Graphemes => (child.min_width, child.max_width),
        },
        FormatSpanKind::Labels(_, _, _, total, _) => (0, cap_width(None, total.as_ref())),
        FormatSpanKind::Leaf(rule) | FormatSpanKind::Compiled(rule, _) => rule_width(rule),
    }
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
    Compiled(&'a FormatRule, CompiledLeaf),
}

const DFA_TABLE_STATES: usize = 1 << 10;

enum CompiledLeaf {
    Dfa {
        initial: usize,
        accepting: Vec<bool>,
        next: Vec<Option<u16>>,
    },
    Identifier {
        first: [bool; 128],
        rest: [bool; 128],
    },
}

impl CompiledLeaf {
    fn new(rule: &FormatRule) -> Option<Self> {
        match rule {
            FormatRule::AsciiDfa(spec) => Self::dfa(spec),
            FormatRule::Identifier {
                first_alphabet,
                rest_alphabet,
                ..
            } => Some(Self::Identifier {
                first: ascii_set(first_alphabet),
                rest: ascii_set(rest_alphabet),
            }),
            _ => None,
        }
    }

    fn dfa(spec: &DfaSpec) -> Option<Self> {
        let count = usize::try_from(&spec.state_count)
            .ok()
            .filter(|count| *count <= DFA_TABLE_STATES)?;
        let state = |value: &BigUint| usize::try_from(value).ok().filter(|state| *state < count);
        let mut next = vec![None; count * 128];
        for transition in &spec.transitions {
            let from = state(&transition.from_state)?;
            let to = u16::try_from(state(&transition.to_state)?).ok()?;
            let first = u8::try_from(&transition.first).unwrap_or(u8::MAX);
            let last = u8::try_from(&transition.last).unwrap_or(u8::MAX);
            for byte in first..=last.min(127) {
                if let Some(entry) = next.get_mut(from * 128 + usize::from(byte)) {
                    entry.get_or_insert(to);
                }
            }
        }
        Some(Self::Dfa {
            initial: state(&spec.initial_state)?,
            accepting: (0..count)
                .map(|state| spec.accepting_states.contains(&BigUint::from(state)))
                .collect(),
            next,
        })
    }

    fn accepts(&self, rule: &FormatRule, text: &str) -> bool {
        match self {
            Self::Dfa {
                initial,
                accepting,
                next,
            } => {
                if !text.is_ascii() {
                    return false;
                }
                let mut state = *initial;
                for byte in text.bytes() {
                    match next.get(state * 128 + usize::from(byte)).copied().flatten() {
                        Some(to) => state = usize::from(to),
                        None => return false,
                    }
                }
                accepting.get(state).copied().unwrap_or(false)
            }
            Self::Identifier { first, rest } => identifier_accepts(
                rule,
                text,
                |character| ascii_member(first, character),
                |character| ascii_member(rest, character),
            ),
        }
    }
}

fn ascii_set(alphabet: &str) -> [bool; 128] {
    let mut set = [false; 128];
    for byte in alphabet.bytes() {
        if let Some(entry) = set.get_mut(usize::from(byte)) {
            *entry = true;
        }
    }
    set
}

fn ascii_member(set: &[bool; 128], character: char) -> bool {
    usize::try_from(u32::from(character))
        .ok()
        .and_then(|index| set.get(index).copied())
        .unwrap_or(false)
}

fn fresh_format_span_id(next: &mut usize) -> usize {
    let id = *next;
    *next += 1;
    id
}
fn format_span_node<'a>(kind: FormatSpanKind<'a>, next: &mut usize) -> FormatSpanNode<'a> {
    FormatSpanNode::new(fresh_format_span_id(next), kind)
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

fn compile_format_span<'a>(
    rule: &'a FormatRule,
    next: &mut usize,
    compiled: bool,
) -> FormatSpanNode<'a> {
    if let FormatRule::Sequence(parts) = rule {
        let children: Vec<_> = parts
            .iter()
            .map(|part| compile_format_span(part, next, compiled))
            .collect();
        return binary_format_sequence(children, next);
    }
    let id = fresh_format_span_id(next);
    let kind = match rule {
        FormatRule::Not(child) => {
            FormatSpanKind::Not(Box::new(compile_format_span(child, next, compiled)))
        }
        FormatRule::Optional(child) => {
            FormatSpanKind::Optional(Box::new(compile_format_span(child, next, compiled)))
        }
        FormatRule::Choice(parts) => FormatSpanKind::Choice(
            parts
                .iter()
                .map(|part| compile_format_span(part, next, compiled))
                .collect(),
        ),
        FormatRule::Bounded {
            unit,
            maximum,
            rule,
        } => FormatSpanKind::Bounded(
            unit,
            maximum,
            Box::new(compile_format_span(rule, next, compiled)),
        ),
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
            Box::new(compile_format_span(rule, next, compiled)),
        ),
        _ => match compiled.then(|| CompiledLeaf::new(rule)).flatten() {
            Some(leaf) => FormatSpanKind::Compiled(rule, leaf),
            None => FormatSpanKind::Leaf(rule),
        },
    };
    FormatSpanNode::new(id, kind)
}

type FormatMemo = HashMap<(usize, usize, usize), bool>;

trait FormatBoundary {
    fn byte_at(&self, index: usize) -> Option<usize>;
}

struct OffsetVec(Vec<usize>);

impl FormatBoundary for OffsetVec {
    fn byte_at(&self, index: usize) -> Option<usize> {
        self.0.get(index).copied()
    }
}

struct CharScan<'a> {
    source: &'a str,
    count: usize,
    cursor: std::cell::Cell<(usize, usize)>,
}

impl<'a> CharScan<'a> {
    fn new(source: &'a str, count: usize) -> Self {
        Self {
            source,
            count,
            cursor: std::cell::Cell::new((0, 0)),
        }
    }
}

impl FormatBoundary for CharScan<'_> {
    fn byte_at(&self, index: usize) -> Option<usize> {
        match index.cmp(&self.count) {
            std::cmp::Ordering::Less => {
                let (chars, bytes) = self.cursor.get();
                let byte = if index >= chars {
                    let tail = &self.source[bytes..];
                    bytes
                        + tail
                            .char_indices()
                            .nth(index - chars)
                            .map_or(tail.len(), |(offset, _)| offset)
                } else {
                    let head = &self.source[..bytes];
                    head.char_indices()
                        .rev()
                        .nth(chars - index - 1)
                        .map_or(0, |(offset, _)| offset)
                };
                self.cursor.set((index, byte));
                Some(byte)
            }
            std::cmp::Ordering::Equal => Some(self.source.len()),
            std::cmp::Ordering::Greater => None,
        }
    }
}

struct AsciiBoundary(usize);

impl FormatBoundary for AsciiBoundary {
    fn byte_at(&self, index: usize) -> Option<usize> {
        (index <= self.0).then_some(index)
    }
}

struct FormatSpan<'a, 'm, B> {
    source: &'a str,
    boundary: B,
    memo: &'m mut FormatMemo,
    limit: Option<usize>,
    graphemes: Option<&'a GraphemeSource<'a>>,
}

impl<'a, B: FormatBoundary> FormatSpan<'a, '_, B> {
    fn text(&self, start: usize, end: usize) -> Option<&'a str> {
        let first = self.boundary.byte_at(start)?;
        let last = self.boundary.byte_at(end)?;
        self.source.get(first..last)
    }

    fn accepts(&mut self, node: &FormatSpanNode<'_>, start: usize, end: usize) -> bool {
        if end
            .checked_sub(start)
            .is_some_and(|width| !node.admits(width))
        {
            return false;
        }
        let key = (node.id, start, end);
        if let Some(&accepted) = self.memo.get(&key) {
            return accepted;
        }
        let accepted = match &node.kind {
            FormatSpanKind::Epsilon => start == end,
            FormatSpanKind::Sequence(left, right) => self.sequence_accepts(left, right, start, end),
            FormatSpanKind::Not(child) => !self.accepts(child, start, end),
            FormatSpanKind::Optional(child) => start == end || self.accepts(child, start, end),
            FormatSpanKind::Choice(children) => self.choice_accepts(children, start, end),
            FormatSpanKind::Bounded(unit, maximum, child) => {
                self.bounded_accepts(unit, maximum, child, start, end)
            }
            FormatSpanKind::Labels(separator, minimum, maximum, total, child) => {
                self.labels_accepts((separator, minimum, maximum, total), child, (start, end))
            }
            FormatSpanKind::Leaf(rule) => self.leaf_accepts(rule, start, end),
            FormatSpanKind::Compiled(rule, leaf) => self
                .text(start, end)
                .is_some_and(|text| leaf.accepts(rule, text)),
        };
        if self.limit.is_none_or(|limit| self.memo.len() < limit) {
            self.memo.insert(key, accepted);
        }
        accepted
    }

    fn sequence_accepts(
        &mut self,
        left: &FormatSpanNode<'_>,
        right: &FormatSpanNode<'_>,
        start: usize,
        end: usize,
    ) -> bool {
        let low = right
            .max_width
            .map_or(start, |width| end.saturating_sub(width))
            .max(start.saturating_add(left.min_width));
        let high = left
            .max_width
            .map_or(end, |width| start.saturating_add(width))
            .min(end.saturating_sub(right.min_width));
        (low..=high)
            .any(|split| self.accepts(left, start, split) && self.accepts(right, split, end))
    }

    fn choice_accepts(
        &mut self,
        children: &[FormatSpanNode<'_>],
        start: usize,
        end: usize,
    ) -> bool {
        children.iter().any(|child| self.accepts(child, start, end))
    }

    fn bounded_accepts(
        &mut self,
        unit: &StringLengthUnit,
        maximum: &BigUint,
        child: &FormatSpanNode<'_>,
        start: usize,
        end: usize,
    ) -> bool {
        self.text(start, end).is_some_and(|text| {
            let measured = match unit {
                StringLengthUnit::UnicodeScalars => end.checked_sub(start),
                _ => measured_length(unit, self.graphemes, text),
            };
            measured.is_some_and(|measured| BigUint::from(measured) <= *maximum)
        }) && self.accepts(child, start, end)
    }

    fn labels_accepts(
        &mut self,
        (separator, minimum, maximum, total): (&str, &BigUint, &Option<BigUint>, &Option<BigUint>),
        child: &FormatSpanNode<'_>,
        (start, end): (usize, usize),
    ) -> bool {
        if separator.is_empty() {
            false
        } else if let Some(text) = self.text(start, end) {
            let count = text.split(separator).count();
            let valid = BigUint::from(count) >= *minimum
                && maximum
                    .as_ref()
                    .is_none_or(|bound| BigUint::from(count) <= *bound)
                && total
                    .as_ref()
                    .is_none_or(|bound| BigUint::from(text.chars().count()) <= *bound);
            let mut cursor = start;
            valid
                && text.split(separator).all(|part| {
                    let end = cursor + part.chars().count();
                    let accepted = self.accepts(child, cursor, end);
                    cursor = end + separator.chars().count();
                    accepted
                })
        } else {
            false
        }
    }

    fn leaf_accepts(&self, rule: &FormatRule, start: usize, end: usize) -> bool {
        self.text(start, end)
            .is_some_and(|text| recognize_format_leaf(rule, text))
    }
}

fn format_span_context_of_string(text: &str) -> OffsetVec {
    OffsetVec(
        text.char_indices()
            .map(|(index, _)| index)
            .chain([text.len()])
            .collect(),
    )
}
pub fn recognize_format(rule: &FormatRule, graphemes: Option<&GraphemeRules>, text: &str) -> bool {
    let root = compile_format_span(rule, &mut 0, false);
    let boundary = format_span_context_of_string(text);
    let end = boundary.0.len() - 1;
    let mut memo = FormatMemo::new();
    let graphemes = graphemes.map(GraphemeSource::new);
    FormatSpan {
        source: text,
        boundary,
        memo: &mut memo,
        limit: None,
        graphemes: graphemes.as_ref(),
    }
    .accepts(&root, 0, end)
}

pub struct PreparedFormat<'r> {
    root: FormatSpanNode<'r>,
    graphemes: Option<GraphemeSource<'r>>,
}

pub fn prepare_format<'r>(
    rule: &'r FormatRule,
    graphemes: Option<&'r GraphemeRules>,
) -> PreparedFormat<'r> {
    prepare_format_with(rule, graphemes.map(GraphemeSource::new).as_ref())
}

pub(crate) fn prepare_format_with<'r>(
    rule: &'r FormatRule,
    graphemes: Option<&GraphemeSource<'r>>,
) -> PreparedFormat<'r> {
    PreparedFormat {
        root: compile_format_span(rule, &mut 0, true),
        graphemes: graphemes.cloned(),
    }
}

pub struct FormatWorkspace {
    memo: FormatMemo,
    memo_entries: usize,
}

#[derive(Debug)]
pub struct FormatWorkspaceError {
    pub requested_entries: usize,
    pub cause: std::collections::TryReserveError,
}

impl FormatWorkspace {
    pub fn empty() -> Self {
        Self {
            memo: FormatMemo::new(),
            memo_entries: 0,
        }
    }
    pub fn try_new(memo_entries: usize) -> Result<Self, FormatWorkspaceError> {
        let mut memo = FormatMemo::new();
        match memo.try_reserve(memo_entries) {
            Ok(()) => Ok(Self { memo, memo_entries }),
            Err(cause) => Err(FormatWorkspaceError {
                requested_entries: memo_entries,
                cause,
            }),
        }
    }
}

pub fn recognize_prepared_format(
    prepared: &PreparedFormat<'_>,
    text: &str,
    workspace: &mut FormatWorkspace,
) -> bool {
    workspace.memo.clear();
    let limit = Some(workspace.memo_entries);
    let graphemes = prepared.graphemes.as_ref();
    let memo = &mut workspace.memo;
    if text.is_ascii() {
        return FormatSpan {
            source: text,
            boundary: AsciiBoundary(text.len()),
            memo,
            limit,
            graphemes,
        }
        .accepts(&prepared.root, 0, text.len());
    }
    let count = text.chars().count();
    FormatSpan {
        source: text,
        boundary: CharScan::new(text, count),
        memo,
        limit,
        graphemes,
    }
    .accepts(&prepared.root, 0, count)
}

fn identifier_accepts(
    r: &FormatRule,
    s: &str,
    first_member: impl Fn(char) -> bool,
    rest_member: impl Fn(char) -> bool,
) -> bool {
    let FormatRule::Identifier {
        exact_length,
        min_length,
        max_length,
        forbidden,
        ..
    } = r
    else {
        return false;
    };
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    let length = 1 + chars.clone().count();
    s.is_ascii()
        && first_member(first)
        && chars.all(rest_member)
        && exact_length
            .as_ref()
            .is_none_or(|n| BigUint::from(length) == *n)
        && BigUint::from(length) >= *min_length
        && max_length
            .as_ref()
            .is_none_or(|n| BigUint::from(length) <= *n)
        && !forbidden.iter().any(|x| x == s)
}
fn recognize_format_leaf(r: &FormatRule, s: &str) -> bool {
    match r {
        FormatRule::Literal(x) => x == s,
        FormatRule::Text => true,
        FormatRule::Identifier {
            first_alphabet,
            rest_alphabet,
            ..
        } => identifier_accepts(
            r,
            s,
            |x| first_alphabet.contains(x),
            |x| rest_alphabet.contains(x),
        ),
        FormatRule::AsciiDfa(d) => {
            if !s.is_ascii() {
                return false;
            }
            let mut state = &d.initial_state;
            for b in s.bytes() {
                let byte = BigUint::from(b);
                let Some(t) = d
                    .transitions
                    .iter()
                    .find(|t| t.from_state == *state && t.first <= byte && byte <= t.last)
                else {
                    return false;
                };
                state = &t.to_state;
            }
            d.accepting_states.contains(state)
        }
        FormatRule::Sequence(_)
        | FormatRule::Not(_)
        | FormatRule::Optional(_)
        | FormatRule::Choice(_)
        | FormatRule::Bounded { .. }
        | FormatRule::Labels { .. } => false,
        FormatRule::Timestamp(rule) => timestamp(s, rule),
        FormatRule::AbsoluteUri { max_bytes } => absolute_uri(s, max_bytes.as_ref()),
        FormatRule::LanguageTag { grandfathered } => recognize_language_tag(s, grandfathered),
    }
}
pub fn integer_condition(
    p: &VersionedSemanticProfile,
    s: &IntegerSpec,
    v: &JsonValue,
) -> Option<ValueCondition> {
    PreparedInteger::new(p.integer_domain(s.domain.as_deref()), Some(s))
        .check(JsonValueView::from_json(v))
        .map(ConditionView::into_owned)
}

pub fn string_condition(
    p: &VersionedSemanticProfile,
    s: &StringSpec,
    v: &str,
) -> Option<ValueCondition> {
    let profile = PreparedProfile::new(p);
    let format = s
        .format
        .as_ref()
        .map(|usage| PreparedUse::new(profile.graphemes(), usage));
    string_condition_view(
        &profile,
        &mut FormatWorkspace::empty(),
        s,
        format.as_ref(),
        v,
        StringContext::Typed,
    )
    .map(ConditionView::into_owned)
}
#[derive(Clone, Copy)]
pub(crate) enum StringContext {
    Typed,
    Sealed,
}
pub(crate) fn string_condition_view<'g: 'a, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    s: &'g StringSpec,
    format: Option<&PreparedUse<'g>>,
    v: &'a str,
    context: StringContext,
) -> Option<ConditionView<'a>> {
    if s.const_value.as_ref().is_some_and(|x| x != v) {
        return Some(ConditionView::Direct(ValueCondition::ConstMismatch));
    }
    if s.enum_values
        .as_ref()
        .is_some_and(|x| !x.iter().any(|x| x == v))
    {
        return Some(ConditionView::Direct(ValueCondition::EnumMismatch));
    }
    if length_bounds_failure(p.graphemes(), v, &s.lengths) {
        return Some(ConditionView::Direct(ValueCondition::StringLength));
    }
    match format {
        None => None,
        Some(PreparedUse::Named(n)) => match p.named(n) {
            Some(prepared) if !recognize_prepared_format(prepared, v, w) => {
                Some(view_text(ValueCondition::Format, n))
            }
            Some(_) => None,
            None => match context {
                StringContext::Typed => None,
                StringContext::Sealed => Some(view_text(ValueCondition::Format, n)),
            },
        },
        Some(PreparedUse::Inline(prepared)) if !recognize_prepared_format(prepared, v, w) => {
            Some(view_text(ValueCondition::Format, "inline"))
        }
        Some(PreparedUse::Inline(_)) => None,
    }
}
pub fn selector_matches(p: &VersionedSemanticProfile, b: &UnionBranch, v: &JsonValue) -> bool {
    selector_matches_view(
        &PreparedProfile::new(p),
        &mut FormatWorkspace::empty(),
        b,
        JsonValueView::from_json(v),
    )
}
fn selector_matches_view<'g>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    b: &UnionBranch,
    v: JsonValueView<'_>,
) -> bool {
    match &b.selector {
        BranchSelector::InternalTag => tag_matches(p, v, &b.wire_tag),
        BranchSelector::MemberShape(tests) => {
            v.members().is_some() && tests.iter().all(|test| member_test_matches(p, w, v, test))
        }
        BranchSelector::Kind(k) => *k == v.kind(),
        BranchSelector::Otherwise => true,
    }
}
fn tag_value<'a>(p: &PreparedProfile<'_>, v: JsonValueView<'a>) -> Option<&'a str> {
    p.profile()
        .tag
        .as_ref()
        .and_then(|t| v.member(&t.key).and_then(JsonValueView::as_str))
}
fn tag_matches(p: &PreparedProfile<'_>, v: JsonValueView<'_>, tag: &str) -> bool {
    tag_value(p, v) == Some(tag)
}
fn member_test_matches(
    p: &PreparedProfile<'_>,
    w: &mut FormatWorkspace,
    v: JsonValueView<'_>,
    (key, test): &(String, MemberTest),
) -> bool {
    match test {
        MemberTest::Absent => v.member(key).is_none(),
        MemberTest::Format(f) => {
            match (v.member(key).and_then(JsonValueView::as_str), p.named(f)) {
                (Some(s), Some(prepared)) => recognize_prepared_format(prepared, s, w),
                _ => false,
            }
        }
    }
}
pub fn select_union_branch<'a>(
    p: &VersionedSemanticProfile,
    s: &'a UnionSpec,
    v: &JsonValue,
) -> Option<&'a UnionBranch> {
    select_union_branch_view(
        &PreparedProfile::new(p),
        &mut FormatWorkspace::empty(),
        s,
        JsonValueView::from_json(v),
    )
}
pub(crate) fn select_union_branch_view<'g, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    s: &'a UnionSpec,
    v: JsonValueView<'_>,
) -> Option<&'a UnionBranch> {
    select_union_branch_index(p, w, s, v).and_then(|index| s.branches.get(index))
}
pub(crate) fn select_union_branch_index(
    p: &PreparedProfile<'_>,
    w: &mut FormatWorkspace,
    s: &UnionSpec,
    v: JsonValueView<'_>,
) -> Option<usize> {
    let mut tag = None;
    s.branches.iter().position(|b| match b.selector {
        BranchSelector::InternalTag => {
            *tag.get_or_insert_with(|| tag_value(p, v)) == Some(b.wire_tag.as_str())
        }
        _ => selector_matches_view(p, w, b, v),
    })
}
const DUPLICATE_SCAN_MEMBERS: usize = 16;

pub(crate) fn duplicate(v: JsonValueView<'_>) -> Option<&str> {
    let members = v.members()?;
    if members.clone().nth(DUPLICATE_SCAN_MEMBERS).is_none() {
        return members
            .clone()
            .enumerate()
            .find(|(index, (key, _))| {
                members
                    .clone()
                    .take(*index)
                    .any(|(earlier, _)| earlier == *key)
            })
            .map(|(_, (key, _))| key);
    }
    let mut seen = HashSet::new();
    members.map(|(key, _)| key).find(|key| !seen.insert(*key))
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
fn base64_body<'t>(policy: &BytesPolicy, text: &'t str) -> Option<&'t str> {
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
    if !body
        .bytes()
        .all(|byte| base64_digit(byte, &policy.alphabet).is_some())
    {
        return None;
    }
    if policy.strict_pad_bits && remainder > 1 {
        let last = base64_digit(*body.as_bytes().last()?, &policy.alphabet)?;
        if remainder == 2 && last % 16 != 0 || remainder == 3 && last % 4 != 0 {
            return None;
        }
    }
    Some(body)
}
pub fn base64_length(policy: &BytesPolicy, text: &str) -> Option<usize> {
    base64_body(policy, text).map(|body| body.len() / 4 * 3 + (body.len() % 4).saturating_sub(1))
}
pub(crate) fn base64_decode(policy: &BytesPolicy, text: &str) -> Option<Vec<u8>> {
    let body = base64_body(policy, text)?;
    let mut output = Vec::new();
    for chunk in body.as_bytes().chunks(4) {
        let mut value = 0u32;
        for byte in chunk {
            value = (value << 6) | u32::from(base64_digit(*byte, &policy.alphabet)?);
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

fn named_format_accepts(
    p: &PreparedProfile<'_>,
    w: &mut FormatWorkspace,
    name: &str,
    text: &str,
) -> bool {
    p.named(name)
        .is_some_and(|prepared| recognize_prepared_format(prepared, text, w))
}
pub(crate) fn format_use_accepts(
    p: &PreparedProfile<'_>,
    w: &mut FormatWorkspace,
    u: &PreparedUse<'_>,
    text: &str,
) -> bool {
    match u {
        PreparedUse::Named(name) => named_format_accepts(p, w, name, text),
        PreparedUse::Inline(prepared) => recognize_prepared_format(prepared, text, w),
    }
}

pub(crate) fn wrapper_text<'g, 'v>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    wrapper: &Wrapper,
    v: JsonValueView<'v>,
) -> Option<&'v str> {
    let mut members = v.members()?;
    let (key, value) = members.next()?;
    if members.next().is_some() || key != wrapper.key.as_str() {
        return None;
    }
    let s = value.as_str()?;
    match &wrapper.payload {
        WrapperPayload::Bytes => p
            .profile()
            .bytes_policy
            .as_ref()
            .and_then(|b| base64_length(b, s))
            .map(|_| s),
        WrapperPayload::Text { format: None } => Some(s),
        WrapperPayload::Text { format: Some(f) } => p
            .named(f)
            .filter(|prepared| recognize_prepared_format(prepared, s, w))
            .map(|_| s),
    }
}

pub(crate) fn wrapper_payload_failure<'a>(wrapper: &'a Wrapper) -> ConditionView<'a> {
    match &wrapper.payload {
        WrapperPayload::Bytes => ConditionView::Direct(ValueCondition::InvalidBytes),
        WrapperPayload::Text { format: None } => wrong_kind("wrapper text"),
        WrapperPayload::Text { format: Some(name) } => {
            view_text(ValueCondition::Format, name.as_str())
        }
    }
}
pub(crate) fn bytes_len<'g>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    v: JsonValueView<'_>,
) -> Option<usize> {
    let policy = p.profile().bytes_policy.as_ref()?;
    let text = match &policy.wrapper {
        None => v.as_str()?,
        Some(name) => {
            let wrapper = p
                .profile()
                .wrappers
                .iter()
                .find(|wrapper| wrapper.name == *name)?;
            wrapper_text(p, w, wrapper, v)?
        }
    };
    base64_length(policy, text)
}
pub(crate) fn sealed_leaf_condition<'g: 'a, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    leaf: &PreparedLeaf<'g>,
    value: JsonValueView<'a>,
) -> Option<ConditionView<'a>> {
    match leaf {
        PreparedLeaf::String(spec) => sealed_string_leaf(p, w, spec, value),
        PreparedLeaf::Integer(numeric) => sealed_integer_condition(numeric, value),
    }
}

fn sealed_string_leaf<'g: 'a, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    spec: &PreparedStringSpec<'g>,
    value: JsonValueView<'a>,
) -> Option<ConditionView<'a>> {
    if let Some(text) = value.as_str() {
        sealed_string_condition(p, w, spec, text)
    } else if value.members().is_some() {
        match p.classify(value) {
            ClassRef::Wrapper(wrapper) => match wrapper_text(p, w, wrapper, value) {
                Some(text) => sealed_string_condition(p, w, spec, text),
                None => Some(wrapper_payload_failure(wrapper)),
            },
            _ => Some(wrong_kind("string")),
        }
    } else {
        Some(wrong_kind("string"))
    }
}

fn sealed_string_condition<'g: 'a, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    spec: &PreparedStringSpec<'g>,
    text: &'a str,
) -> Option<ConditionView<'a>> {
    string_condition_view(
        p,
        w,
        spec.spec(),
        spec.format(),
        text,
        StringContext::Sealed,
    )
}

fn sealed_integer_condition<'g: 'a, 'a>(
    numeric: &PreparedInteger<'g>,
    value: JsonValueView<'a>,
) -> Option<ConditionView<'a>> {
    match value.as_integer() {
        Some(_) => numeric.check(value),
        None => Some(wrong_kind("integer")),
    }
}
pub(crate) fn tag_member_failure<'g: 'a, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    value: JsonValueView<'a>,
) -> Option<(&'g str, ConditionView<'a>, JsonValueView<'a>)> {
    let tag = p.profile().tag.as_ref()?;
    let observed = value.member(&tag.key)?;
    match observed.as_str() {
        Some(text)
            if tag.format.as_ref().is_none_or(|name| {
                p.named(name)
                    .is_some_and(|prepared| recognize_prepared_format(prepared, text, w))
            }) =>
        {
            None
        }
        _ => Some((
            tag.key.as_str(),
            ConditionView::Direct(ValueCondition::InvalidTag),
            observed,
        )),
    }
}
pub fn integer_value_for_domain(
    profile: &VersionedSemanticProfile,
    domain: Option<&str>,
    value: &JsonValue,
) -> Option<BigInt> {
    let binding = profile.integer_domain(domain)?;
    parse_integer(binding, value)
}

pub fn tag_value_accepts(
    profile: &VersionedSemanticProfile,
    members: &[(String, JsonValue)],
) -> bool {
    let prepared = PreparedProfile::new(profile);
    let object = JsonValue::Obj(members.to_vec());
    tag_member_failure(
        &prepared,
        &mut FormatWorkspace::empty(),
        JsonValueView::from_json(&object),
    )
    .is_none()
}

fn text_wrapper(profile: &VersionedSemanticProfile) -> Option<&Wrapper> {
    profile
        .wrappers
        .iter()
        .find(|wrapper| matches!(wrapper.payload, WrapperPayload::Text { .. }))
}

pub fn wrapper_text_accepts(profile: &VersionedSemanticProfile, value: &JsonValue) -> bool {
    let Some(wrapper) = text_wrapper(profile) else {
        return false;
    };
    let prepared = PreparedProfile::new(profile);
    wrapper_text(
        &prepared,
        &mut FormatWorkspace::empty(),
        wrapper,
        JsonValueView::from_json(value),
    )
    .is_some()
}

pub fn data_value_accepts<'a>(profile: &'a VersionedSemanticProfile, value: &'a JsonValue) -> bool {
    let prepared = PreparedProfile::new(profile);
    data_value_view_accepts(
        &prepared,
        &mut FormatWorkspace::empty(),
        JsonValueView::from_json(value),
    )
}

fn data_value_view_accepts<'g: 'a, 'a>(
    p: &PreparedProfile<'g>,
    w: &mut FormatWorkspace,
    value: JsonValueView<'a>,
) -> bool {
    if let Some(integer) = value.as_integer() {
        return p.data_numeric().check_number(integer).is_none();
    }
    if let Some(text) = value.as_decimal_text() {
        return p.data_numeric().check_decimal(text).is_none();
    }
    if let Some(items) = value.as_array() {
        return items
            .iter()
            .all(|item| data_value_view_accepts(p, w, JsonValueView::from_json(item)));
    }
    let Some(mut members) = value.members() else {
        return true;
    };
    if duplicate(value).is_some() || tag_member_failure(p, w, value).is_some() {
        return false;
    }
    match p.classify(value) {
        ClassRef::Wrapper(wrapper) => wrapper_text(p, w, wrapper, value).is_some(),
        ClassRef::Sealed { form } => {
            if sealed_fields_failure(p, w, form, value).is_some() {
                return false;
            }
            let Some(tag) = p.profile().tag.as_ref() else {
                return false;
            };
            members.all(|(key, member)| {
                if key == tag.key || form.fields().iter().any(|field| field.key() == key) {
                    true
                } else if form.form().extras == SealedExtras::Reject {
                    false
                } else {
                    data_value_view_accepts(p, w, member)
                }
            })
        }
        ClassRef::Ordinary => members.all(|(_, member)| data_value_view_accepts(p, w, member)),
    }
}

pub(crate) enum ConditionView<'a> {
    Direct(ValueCondition),
    Text {
        constructor: fn(String) -> ValueCondition,
        text: &'a str,
    },
}

impl ConditionView<'_> {
    pub(crate) fn into_owned(self) -> ValueCondition {
        match self {
            ConditionView::Direct(condition) => condition,
            ConditionView::Text { constructor, text } => constructor(text.to_owned()),
        }
    }
}

impl<'a> From<ValueCondition> for ConditionView<'a> {
    fn from(condition: ValueCondition) -> Self {
        ConditionView::Direct(condition)
    }
}

pub(crate) fn view_text<'a>(
    constructor: fn(String) -> ValueCondition,
    text: &'a str,
) -> ConditionView<'a> {
    ConditionView::Text { constructor, text }
}

pub(crate) fn wrong_kind(text: &str) -> ConditionView<'_> {
    view_text(ValueCondition::WrongValueKind, text)
}

pub fn semantic_node_structure_is_valid(
    profile: &VersionedSemanticProfile,
    node: &TypeNode,
) -> bool {
    fn ordered_bounds<T: Ord>(minimum: &Option<T>, maximum: &Option<T>) -> bool {
        match (minimum, maximum) {
            (Some(minimum), Some(maximum)) => minimum <= maximum,
            _ => true,
        }
    }

    fn unique_nonempty<'a>(mut values: impl Iterator<Item = &'a str>) -> bool {
        let mut seen = HashSet::new();
        values.all(|value| !value.is_empty() && seen.insert(value))
    }

    fn format_use_is_structurally_valid(format: &Option<FormatUse>) -> bool {
        match format {
            Some(FormatUse::Inline(rule)) => format_rule_well_formed(rule),
            _ => true,
        }
    }

    match &node.shape {
        TypeShape::Integer(spec) => ordered_bounds(&spec.minimum, &spec.maximum),
        TypeShape::Decimal(spec) => match (&spec.minimum, &spec.maximum) {
            (Some(minimum), Some(maximum)) => {
                minimum.scale == maximum.scale && minimum.mantissa <= maximum.mantissa
            }
            _ => true,
        },
        TypeShape::String(spec) => {
            format_use_is_structurally_valid(&spec.format)
                && spec
                    .lengths
                    .iter()
                    .all(|bound| ordered_bounds(&bound.minimum, &bound.maximum))
        }
        TypeShape::Product(spec) => {
            unique_nonempty(spec.fields.iter().map(|field| field.wire_name.as_str()))
        }
        TypeShape::Array(spec) => ordered_bounds(&spec.min_length, &spec.max_length),
        TypeShape::Bytes(spec) => ordered_bounds(&spec.minimum, &spec.maximum),
        TypeShape::TaggedUnion(spec) => {
            unique_nonempty(spec.branches.iter().map(|branch| branch.wire_tag.as_str()))
                && spec.branches.iter().enumerate().all(|(index, branch)| {
                    (!matches!(branch.selector, BranchSelector::Otherwise)
                        || index + 1 == spec.branches.len())
                        && match &branch.selector {
                            BranchSelector::MemberShape(tests) => {
                                unique_nonempty(tests.iter().map(|(name, _)| name.as_str()))
                            }
                            _ => true,
                        }
                        && spec.branches.iter().take(index).all(|previous| {
                            match (&branch.selector, &previous.selector) {
                                (BranchSelector::InternalTag, BranchSelector::InternalTag) => {
                                    branch.wire_tag != previous.wire_tag
                                }
                                _ => branch.selector != previous.selector,
                            }
                        })
                })
        }
        TypeShape::Sealed { tag, refinements } => {
            unique_nonempty(refinements.iter().map(|refinement| refinement.key.as_str()))
                && profile
                    .tag
                    .as_ref()
                    .and_then(|model| model.sealed.iter().find(|form| form.tag == *tag))
                    .is_none_or(|form| {
                        refinements.iter().all(|refinement| {
                            form.fields.iter().any(|field| {
                                field.key == refinement.key
                                    && matches!(
                                        (&field.leaf, &refinement.leaf),
                                        (SealedLeaf::String(_), SealedLeaf::String(_))
                                            | (SealedLeaf::Integer(_), SealedLeaf::Integer(_))
                                    )
                            })
                        })
                    })
        }
        _ => true,
    }
}

fn format_rules_use_graphemes(rules: &[FormatRule]) -> bool {
    rules.iter().any(format_rule_uses_graphemes)
}
fn format_use_uses_graphemes(profile: &VersionedSemanticProfile, usage: &FormatUse) -> bool {
    match usage {
        FormatUse::Inline(rule) => format_rule_uses_graphemes(rule),
        FormatUse::Named(name) => profile
            .format(name)
            .is_some_and(|binding| format_rule_uses_graphemes(&binding.rule)),
    }
}
fn format_rule_uses_graphemes(rule: &FormatRule) -> bool {
    match rule {
        FormatRule::Bounded { unit, rule, .. } => {
            *unit == StringLengthUnit::Graphemes || format_rule_uses_graphemes(rule)
        }
        FormatRule::Sequence(parts) | FormatRule::Choice(parts) => {
            format_rules_use_graphemes(parts)
        }
        FormatRule::Optional(rule) | FormatRule::Not(rule) => format_rule_uses_graphemes(rule),
        FormatRule::Labels { rule, .. } => format_rule_uses_graphemes(rule),
        FormatRule::Literal(_)
        | FormatRule::AsciiDfa(_)
        | FormatRule::Identifier { .. }
        | FormatRule::Timestamp(_)
        | FormatRule::AbsoluteUri { .. }
        | FormatRule::LanguageTag { .. }
        | FormatRule::Text => false,
    }
}

fn node_meaning_reasons(graph: &SemanticGraph, declared: Option<&TypeNode>) -> Vec<SemanticReason> {
    let Some(node) = declared else {
        return vec![SemanticReason::UnresolvedType];
    };
    let mut reasons = Vec::new();
    match &node.shape {
        TypeShape::String(spec) => {
            let format_uses_graphemes = spec
                .format
                .as_ref()
                .is_some_and(|usage| format_use_uses_graphemes(&graph.profile, usage));
            if (format_uses_graphemes
                || spec
                    .lengths
                    .iter()
                    .any(|bound| bound.unit == StringLengthUnit::Graphemes))
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

fn reachable_types<'r>(
    graph: &'r SemanticGraph,
    index: &NodeIndex<'_>,
    roots: &'r [TypeRef],
) -> Vec<(&'r TypeRef, Option<&'r TypeNode>)> {
    let mut pending: std::collections::VecDeque<&TypeRef> = roots.iter().collect();
    let mut seen_nodes: HashSet<usize> = HashSet::new();
    let mut seen_unresolved = HashSet::new();
    let mut reachable = Vec::new();
    while let Some(reference) = pending.pop_front() {
        let position = index.get(reference);
        let node = position.and_then(|position| graph.nodes.get(position));
        let fresh = match position.filter(|position| *position < graph.nodes.len()) {
            Some(position) => seen_nodes.insert(position),
            None => seen_unresolved.insert(reference),
        };
        if !fresh {
            continue;
        }
        if let Some(node) = node {
            for child in type_children(&node.shape).into_iter().rev() {
                pending.push_front(child);
            }
        }
        reachable.push((reference, node));
    }
    reachable.reverse();
    reachable
}
pub(crate) fn meaning_blocked_table(graph: &SemanticGraph, index: &NodeIndex<'_>) -> Vec<bool> {
    let canonical: Vec<Option<usize>> = graph
        .nodes
        .iter()
        .map(|node| index.get(&node.reference))
        .collect();
    let mut blocked = vec![false; graph.nodes.len()];
    let mut parents: Vec<Vec<usize>> = vec![Vec::new(); graph.nodes.len()];
    let mut pending = Vec::new();
    for (position, node) in graph.nodes.iter().enumerate() {
        if canonical.get(position).copied().flatten() != Some(position) {
            continue;
        }
        let mut seed = !node_meaning_reasons(graph, Some(node)).is_empty();
        for child in type_children(&node.shape) {
            match index.get(child).and_then(|target| parents.get_mut(target)) {
                Some(row) => row.push(position),
                None => seed = true,
            }
        }
        if seed {
            if let Some(flag) = blocked.get_mut(position) {
                *flag = true;
            }
            pending.push(position);
        }
    }
    while let Some(position) = pending.pop() {
        for parent in parents.get(position).into_iter().flatten() {
            if let Some(flag) = blocked.get_mut(*parent).filter(|flag| !**flag) {
                *flag = true;
                pending.push(*parent);
            }
        }
    }
    canonical
        .iter()
        .map(|target| {
            target
                .and_then(|target| blocked.get(target).copied())
                .unwrap_or(true)
        })
        .collect()
}
pub fn meaning_obligations(graph: &SemanticGraph, roots: &[TypeRef]) -> Vec<SemanticObligation> {
    meaning_obligations_in(graph, &NodeIndex::new(graph), roots)
}
#[cfg(test)]
thread_local! {
    pub(crate) static MEANING_OBLIGATION_CALLS: std::cell::Cell<usize> =
        const { std::cell::Cell::new(0) };
}
pub(crate) fn meaning_obligations_in(
    graph: &SemanticGraph,
    index: &NodeIndex<'_>,
    roots: &[TypeRef],
) -> Vec<SemanticObligation> {
    #[cfg(test)]
    MEANING_OBLIGATION_CALLS.with(|calls| calls.set(calls.get() + 1));
    reachable_types(graph, index, roots)
        .into_iter()
        .flat_map(|(reference, node)| {
            node_meaning_reasons(graph, node)
                .into_iter()
                .map(move |reason| SemanticObligation {
                    type_ref: reference.clone(),
                    origin: OccurrenceRef::from(reference),
                    value_path: vec![],
                    profile: graph.profile.reference.clone(),
                    reason,
                })
        })
        .collect()
}
fn meaning_predicate(reason: &SemanticReason) -> Option<MeaningObligation> {
    match reason {
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
        SemanticReason::UnresolvedType => Some(MeaningObligation::Mo12),
        _ => None,
    }
}
pub fn check_meaning_defined(g: &SemanticGraph, roots: &[TypeRef]) -> Result<(), MeaningFailure> {
    for obligation in meaning_obligations(g, roots) {
        if let Some(predicate) = meaning_predicate(&obligation.reason) {
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
    use super::FormatWorkspaceError;
    use super::{recognize_format, recognize_language_tag, FormatWorkspace, PreparedValidator};
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
            ("en-1abc-1ABC", false),
            ("en-1abc-2abc", true),
            ("en-1abc-1abc-2abc", false),
            ("en-2abc-1abc", true),
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
            ("", vec![""], true),
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
                    let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
                        .accepts_value(&wrapper_failure_reference(reference), &value);
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
                            .rev()
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
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&wrapper_failure_reference("root"), &value),
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
            let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&reference, &value);
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
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&reference, &value),
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
            ("YWJjZ", false),
            ("", true),
        ] {
            let value = JsonValue::Obj(vec![
                ("kind".into(), JsonValue::Str("sealed".into())),
                (
                    "label".into(),
                    JsonValue::Obj(vec![("bytes".into(), JsonValue::Str(text.into()))]),
                ),
            ]);
            let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&reference, &value);
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
            let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&reference, &value);
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
            "../../../../verification/declaration/wrapper_base64_vectors.json"
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
                let input: JsonValue = crate::exact_json::parse_json_text(
                    &case.get("input").ok_or("missing input")?.to_string(),
                )?;
                let expected = case.get("expected").ok_or("missing expected outcome")?;
                let actual = match PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(root, &input)
                {
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
        use crate::semantic_codegen_runtime::{bytes_decode, bytes_encode, Bytes};

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
                    let encoded = bytes_encode(&profile, &Bytes::from(bytes.to_vec()))?;
                    assert_eq!(bytes_decode(&profile, encoded)?.data, bytes);
                }
            }
        }
        for text in ["+/8=", "-_8=", "+_8=", "-/8="] {
            let value = JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str(text.into()))]);
            assert_eq!(bytes_decode(&profile, value)?.data, vec![251, 255]);
        }
        Ok(())
    }

    fn raw_and_prepared(rule: &FormatRule, text: &str) -> Result<bool, FormatWorkspaceError> {
        use super::{prepare_format, recognize_prepared_format, FormatWorkspace};
        let observed = recognize_format(rule, None, text);
        let prepared = prepare_format(rule, None);
        for budget in [0usize, 4, 256, 4096] {
            let mut workspace = FormatWorkspace::try_new(budget)?;
            assert_eq!(
                recognize_prepared_format(&prepared, text, &mut workspace),
                observed,
                "prepared budget {budget} {text:?}"
            );
        }
        Ok(observed)
    }

    #[test]
    fn sequence_grouping_preserves_concatenation_and_empty_parts(
    ) -> Result<(), FormatWorkspaceError> {
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
                    raw_and_prepared(rule, text)?,
                    ["!", "a!", "😀!", "a😀!"].contains(&text)
                );
            }
        }
        assert!(raw_and_prepared(&sequence(vec![]), "")?);
        assert!(!raw_and_prepared(&sequence(vec![]), "a")?);
        let negated = sequence(vec![
            literal("["),
            FormatRule::Not(Box::new(sequence(vec![literal("a"), literal("😀")]))),
            literal("]"),
        ]);
        assert!(raw_and_prepared(&negated, "[]")?);
        assert!(raw_and_prepared(&negated, "[😀]")?);
        assert!(!raw_and_prepared(&negated, "[a😀]")?);
        Ok(())
    }

    #[test]
    fn sequence_labels_preserve_scalar_offsets_and_byte_bounds() -> Result<(), FormatWorkspaceError>
    {
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
            ("[a😀🔹a😀]", true),
        ] {
            assert_eq!(raw_and_prepared(&rule, text)?, expected);
        }
        let bounded = |maximum: u8| FormatRule::Bounded {
            unit: StringLengthUnit::Utf8Bytes,
            maximum: maximum.into(),
            rule: Box::new(rule.clone()),
        };
        assert!(raw_and_prepared(&bounded(15), "[😀🔹a😀]")?);
        assert!(!raw_and_prepared(&bounded(14), "[😀🔹a😀]")?);
        Ok(())
    }

    #[test]
    fn flat_sequence_with_600_parts_preserves_acceptance_and_rejection(
    ) -> Result<(), FormatWorkspaceError> {
        let mut parts = vec![FormatRule::Literal(String::new()); 600];
        let rule = FormatRule::Sequence(parts.clone());
        assert!(raw_and_prepared(&rule, "")?);
        assert!(!raw_and_prepared(&rule, "x")?);
        parts.push(FormatRule::Literal("x".into()));
        let suffix = FormatRule::Sequence(parts);
        assert!(raw_and_prepared(&suffix, "x")?);
        assert!(!raw_and_prepared(&suffix, "")?);
        Ok(())
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod format_workspace_tests {
    use super::*;

    fn reject_rule() -> FormatRule {
        FormatRule::Sequence(vec![
            FormatRule::Literal("a".into()),
            FormatRule::Choice(vec![
                FormatRule::Literal("b".into()),
                FormatRule::Optional(Box::new(FormatRule::Literal("c".into()))),
            ]),
            FormatRule::Literal("d".into()),
        ])
    }

    #[test]
    fn memo_entries_never_exceed_the_budget() {
        let rule = reject_rule();
        let prepared = prepare_format(&rule, None);
        for budget in [0usize, 1, 4] {
            let mut workspace = FormatWorkspace::try_new(budget).expect("small reservation");
            for text in ["xyz", "ab", "acx", "abcx", "ad", "abd"] {
                let observed = recognize_prepared_format(&prepared, text, &mut workspace);
                assert_eq!(
                    observed,
                    recognize_format(&rule, None, text),
                    "budget {budget} {text:?}"
                );
                assert!(workspace.memo.len() <= budget);
            }
        }
    }

    #[test]
    fn try_new_reports_the_std_failure() {
        let error = FormatWorkspace::try_new(usize::MAX)
            .err()
            .expect("maximum reservation fails");
        let std_error = FormatMemo::new()
            .try_reserve(usize::MAX)
            .expect_err("std reservation fails");
        assert_eq!(error.requested_entries, usize::MAX);
        assert_eq!(error.cause, std_error);
    }
}

#[cfg(test)]
mod range_lookup_tests {
    use super::{flatten_ranges, table_lookup};

    fn lookup(values: &[(u32, u32)], codepoint: u32) -> Option<usize> {
        let table = flatten_ranges(
            values
                .iter()
                .enumerate()
                .map(|(index, (first, last))| (*first, *last, index)),
        );
        table_lookup(&table, codepoint)
    }

    fn listed(values: &[(u32, u32)], codepoint: u32) -> Option<usize> {
        values
            .iter()
            .position(|(first, last)| *first <= codepoint && codepoint <= *last)
    }

    #[test]
    fn first_listed_range_wins_over_later_overlap() {
        assert_eq!(lookup(&[(10, 20), (0, 30)], 15), Some(0));
    }

    #[test]
    fn range_lookup_finds_members_of_sorted_ranges() {
        let ranges = [(0, 5), (10, 20)];
        assert_eq!(lookup(&ranges, 12), Some(1));
        assert_eq!(lookup(&ranges, 7), None);
    }

    #[test]
    fn flattened_lookup_matches_listed_order() {
        let ranges = [
            (10, 20),
            (0, 30),
            (15, 40),
            (5, 5),
            (25, 26),
            (41, 50),
            (0, 60),
        ];
        for codepoint in 0..70 {
            assert_eq!(lookup(&ranges, codepoint), listed(&ranges, codepoint));
        }
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod lean_representative_tests {
    use super::*;

    fn recognized(rule: &FormatRule, text: &str) -> bool {
        let raw = recognize_format(rule, None, text);
        let prepared = prepare_format(rule, None);
        let mut workspace = FormatWorkspace::try_new(1 << 12).expect("memo budget");
        let fast = recognize_prepared_format(&prepared, text, &mut workspace);
        assert_eq!(
            raw, fast,
            "raw and prepared recognition differ for {text:?}"
        );
        raw
    }

    fn labels(separator: &str, minimum: u32, total_max: u32) -> FormatRule {
        FormatRule::Labels {
            separator: separator.into(),
            min_count: BigUint::from(minimum),
            max_count: None,
            total_max: Some(BigUint::from(total_max)),
            rule: Box::new(FormatRule::Text),
        }
    }

    #[test]
    fn labels_total_bound_counts_scalar_values_as_lean_does() {
        assert!(recognized(&labels("é", 2, 6), "@--é-x"));
        assert!(!recognized(&labels("é", 2, 6), "@--é-xy"));
        assert!(recognized(&labels("😀", 2, 4), "a😀b"));
        assert!(recognized(&labels("😀", 2, 3), "a😀b"));
        assert!(!recognized(&labels(".", 1, 4), "ab.cd"));
    }

    #[test]
    fn identifier_and_ascii_dfa_reject_non_ascii_text_as_lean_does() {
        let identifier = |first: &str, rest: &str| FormatRule::Identifier {
            first_alphabet: first.into(),
            rest_alphabet: rest.into(),
            exact_length: None,
            min_length: BigUint::from(0u8),
            max_length: None,
            forbidden: vec![],
        };
        assert!(!recognized(&identifier("é", "ab"), "é"));
        assert!(!recognized(&identifier("ab", "ab"), "aé"));
        let dfa = |first: u8, last: u8| {
            let (first, last) = (BigUint::from(first), BigUint::from(last));
            FormatRule::AsciiDfa(DfaSpec {
                state_count: BigUint::from(1u8),
                initial_state: BigUint::from(0u8),
                accepting_states: vec![BigUint::from(0u8)],
                transitions: vec![DfaTransition {
                    from_state: BigUint::from(0u8),
                    first,
                    last,
                    to_state: BigUint::from(0u8),
                }],
            })
        };
        assert!(!recognized(&dfa(223, 255), "é"));
        assert!(recognized(&dfa(97, 97), "aa"));
    }

    #[test]
    fn forbidden_word_with_replacement_character_is_well_formed_as_lean_does() {
        let rule = FormatRule::Identifier {
            first_alphabet: "ab".into(),
            rest_alphabet: "ab".into(),
            exact_length: None,
            min_length: BigUint::from(1u8),
            max_length: None,
            forbidden: vec!["\u{fffd}".into()],
        };
        assert!(format_rule_well_formed(&rule));
    }

    #[test]
    fn uri_language_and_timestamp_representatives_match_lean() {
        let uri = |maximum: Option<u32>| FormatRule::AbsoluteUri {
            max_bytes: maximum.map(BigUint::from),
        };
        assert!(recognized(&uri(None), "https://[v1.fe]/a?b#c"));
        assert!(!recognized(&uri(None), "urn:x:%zz"));
        assert!(recognized(&uri(None), "http://[::ffff:1.2.3.4]:8080/"));
        assert!(!recognized(&uri(None), "http://[1:2:3:4:5:6:7:8:9]/"));
        assert!(recognized(&uri(None), "http://01.2.3.4/"));
        assert!(!recognized(&uri(None), "https://example.com/é"));
        assert!(!recognized(&uri(Some(19)), "https://example.com/"));
        assert!(recognized(&uri(Some(20)), "https://example.com/"));

        let language = |grandfathered: &[&str]| FormatRule::LanguageTag {
            grandfathered: grandfathered.iter().map(|tag| (*tag).to_owned()).collect(),
        };
        for text in [
            "zh-min-nan",
            "en-a-bbb-x-ccc",
            "en-US-u-ca",
            "sl-rozaj-biske",
        ] {
            assert!(recognized(&language(&[]), text), "{text}");
        }
        assert!(!recognized(&language(&[]), "de-1901-1901"));
        assert!(recognized(&language(&["I-KLINGON"]), "i-klingon"));

        let calendar = |minimum: u32, maximum: u32, second_60: bool, utc: bool| {
            FormatRule::Timestamp(CalendarRule {
                allow_second_60: second_60,
                minimum_year: BigUint::from(minimum),
                maximum_year: BigUint::from(maximum),
                reject_utc_year_outside_range: utc,
            })
        };
        assert!(!recognized(
            &calendar(2020, 2020, false, false),
            "2020-12-31T23:59:59-00:00"
        ));
        assert!(!recognized(
            &calendar(2020, 2020, false, true),
            "2020-01-01T00:30:00+01:00"
        ));
        assert!(recognized(
            &calendar(2020, 2020, false, false),
            "2020-01-01T00:30:00+01:00"
        ));
        assert!(!recognized(
            &calendar(0, 9999, false, true),
            "9999-12-31T23:30:00-00:30"
        ));
        assert!(!recognized(
            &calendar(0, 9999, false, true),
            "9999-12-31T23:30:00-01:00"
        ));
        assert!(recognized(
            &calendar(2000, 2000, true, false),
            "2000-02-29T12:00:60.25Z"
        ));
        assert!(!recognized(
            &calendar(0, 9999, false, false),
            "2001-02-29T12:00:00Z"
        ));
    }

    #[test]
    fn base64_representatives_match_lean() {
        let reference = ProfileRef {
            identity: "p".into(),
            revision: "1".into(),
            content_digest: "a".into(),
        };
        let policy =
            |alphabet: BytesAlphabet, padding_optional: bool, strict_pad_bits: bool| BytesPolicy {
                reference: reference.clone(),
                padding_optional,
                alphabet,
                strict_pad_bits,
                wrapper: None,
            };
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Standard, true, true), "YWJ="),
            None
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Standard, true, false), "YWJ="),
            Some(2)
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::UrlSafe, true, true), "_w"),
            Some(1)
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Standard, true, true), "_w"),
            None
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Either, false, true), "-_+/"),
            Some(3)
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Standard, false, true), "YQ"),
            None
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Standard, false, true), "YQ=="),
            Some(1)
        );
        assert_eq!(
            base64_length(&policy(BytesAlphabet::Standard, true, true), "Y==="),
            None
        );
    }
}

pub fn evaluate_value(
    validator: &mut PreparedValidator<'_>,
    r: &TypeRef,
    v: &JsonValue,
) -> SemanticEvaluation {
    classify_value_decision(
        EvaluationProvenance {
            operation: "validate".into(),
            type_ref: r.clone(),
            value_path: vec![],
        },
        validator.accepts_value(r, v),
    )
}
