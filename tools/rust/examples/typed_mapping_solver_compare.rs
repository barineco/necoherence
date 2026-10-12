// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

//! Rust comparison runner for the typed mapping solver: reads the shared
//! fixtures document, executes the four public operations and writes the
//! canonical result document to stdout as JSON; no solving itself.

use std::env;
use std::fs;

use necoherence::typed_mapping::{
    derive_enabled, BindingMode, ColoredToken, DeadlockResult, DeclarationGraph, DomainBound,
    EnabledResult, EnabledSet, GoalPredicate, InputBinding, InvalidReason, Marking,
    ReachabilityResult, SolverInput, TokenKind, TypedPlace, TypedTransition, UnknownReason,
    WellFoundednessResult,
};
use necoherence::Nat;
use necoherence_tools::typed_mapping_solver::{
    check_deadlock, check_reachability, check_well_foundedness,
};

#[derive(Clone, Debug)]
enum J {
    Null,
    Bool(bool),
    Num(u64),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

struct Reader<'a> {
    text: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(text: &'a str) -> Self {
        Reader {
            text: text.as_bytes(),
            pos: 0,
        }
    }

    fn fail<T>(&self, message: &str) -> Result<T, String> {
        Err(format!("{} at offset {}", message, self.pos))
    }

    fn skip_ws(&mut self) {
        while let Some(&b) = self.text.get(self.pos) {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.text.get(self.pos).copied()
    }

    fn expect(&mut self, b: u8) -> Result<(), String> {
        if self.peek() == Some(b) {
            self.pos += 1;
            Ok(())
        } else {
            self.fail(&format!("expected '{}'", b as char))
        }
    }

    fn value(&mut self) -> Result<J, String> {
        self.skip_ws();
        match self.peek() {
            None => self.fail("unexpected end of input"),
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(J::Str(self.string()?)),
            Some(b't') => self.keyword("true", J::Bool(true)),
            Some(b'f') => self.keyword("false", J::Bool(false)),
            Some(b'n') => self.keyword("null", J::Null),
            Some(_) => self.number(),
        }
    }

    fn keyword(&mut self, word: &str, value: J) -> Result<J, String> {
        let end = self.pos.saturating_add(word.len());
        if self.text.get(self.pos..end) == Some(word.as_bytes()) {
            self.pos = end;
            Ok(value)
        } else {
            self.fail(&format!("expected {}", word))
        }
    }

    fn number(&mut self) -> Result<J, String> {
        let start = self.pos;
        while let Some(b) = self.peek() {
            if b.is_ascii_digit() {
                self.pos += 1;
            } else {
                break;
            }
        }
        let digits = self
            .text
            .get(start..self.pos)
            .and_then(|slice| std::str::from_utf8(slice).ok())
            .ok_or_else(|| "bad number slice".to_string())?;
        digits
            .parse::<u64>()
            .map(J::Num)
            .map_err(|e| format!("bad number {}: {}", digits, e))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            match self.peek() {
                None => return self.fail("unterminated string"),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    match self.peek() {
                        Some(b'"') => out.push('"'),
                        Some(b'\\') => out.push('\\'),
                        Some(b'/') => out.push('/'),
                        Some(b'n') => out.push('\n'),
                        Some(b't') => out.push('\t'),
                        Some(b'r') => out.push('\r'),
                        Some(b'b') => out.push('\u{0008}'),
                        Some(b'f') => out.push('\u{000C}'),
                        Some(b'u') => {
                            let hex = self.text.get(self.pos + 1..self.pos + 5);
                            if let Some(hex) = hex {
                                let code = std::str::from_utf8(hex)
                                    .ok()
                                    .and_then(|h| u32::from_str_radix(h, 16).ok());
                                match code.and_then(char::from_u32) {
                                    Some(c) => {
                                        out.push(c);
                                        self.pos += 4;
                                    }
                                    None => return self.fail("bad \\u escape"),
                                }
                            } else {
                                return self.fail("bad \\u escape");
                            }
                        }
                        _ => return self.fail("bad escape"),
                    }
                    self.pos += 1;
                }
                Some(_) => {
                    let rest = self
                        .text
                        .get(self.pos..)
                        .and_then(|slice| std::str::from_utf8(slice).ok())
                        .ok_or_else(|| "bad utf-8 slice".to_string())?;
                    let mut chars = rest.chars();
                    match chars.next() {
                        Some(c) => {
                            out.push(c);
                            self.pos += c.len_utf8();
                        }
                        None => return self.fail("unterminated string"),
                    }
                }
            }
        }
    }

    fn array(&mut self) -> Result<J, String> {
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(J::Arr(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(J::Arr(items));
                }
                _ => return self.fail("expected ',' or ']'"),
            }
        }
    }

    fn object(&mut self) -> Result<J, String> {
        self.expect(b'{')?;
        let mut fields = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(J::Obj(fields));
        }
        loop {
            self.skip_ws();
            let key = self.string()?;
            self.skip_ws();
            self.expect(b':')?;
            let value = self.value()?;
            fields.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(J::Obj(fields));
                }
                _ => return self.fail("expected ',' or '}'"),
            }
        }
    }
}

fn get<'a>(j: &'a J, key: &str) -> Result<&'a J, String> {
    match j {
        J::Obj(fields) => fields
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v)
            .ok_or_else(|| format!("missing field {}", key)),
        _ => Err(format!("expected object for field {}", key)),
    }
}

fn jstr<'a>(j: &'a J, key: &str) -> Result<&'a str, String> {
    match get(j, key)? {
        J::Str(s) => Ok(s),
        _ => Err(format!("field {} is not a string", key)),
    }
}

fn jnat(j: &J, key: &str) -> Result<Nat, String> {
    match get(j, key)? {
        J::Num(n) => Ok(Nat::from(*n)),
        _ => Err(format!("field {} is not a number", key)),
    }
}

fn jarr<'a>(j: &'a J, key: &str) -> Result<&'a [J], String> {
    match get(j, key)? {
        J::Arr(items) => Ok(items),
        _ => Err(format!("field {} is not an array", key)),
    }
}

fn jstrs(j: &J, key: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for item in jarr(j, key)? {
        match item {
            J::Str(s) => out.push(s.clone()),
            _ => return Err(format!("field {} has a non-string item", key)),
        }
    }
    Ok(out)
}

fn dec_token(j: &J) -> Result<ColoredToken, String> {
    let kind = match jstr(j, "kind")? {
        "input" => TokenKind::Input,
        "output" => TokenKind::Output,
        "failure" => TokenKind::Failure,
        "effect" => TokenKind::Effect,
        "observation" => TokenKind::Observation,
        "accepted" => TokenKind::Accepted,
        other => return Err(format!("unknown token kind {}", other)),
    };
    Ok(ColoredToken {
        target: jstr(j, "target")?.to_string(),
        index: jnat(j, "index")?,
        revision: jnat(j, "revision")?,
        kind,
    })
}

fn dec_place(j: &J) -> Result<TypedPlace, String> {
    Ok(TypedPlace {
        identity: jstr(j, "identity")?.to_string(),
        token_type: jstr(j, "token_type")?.to_string(),
        revision: jnat(j, "revision")?,
    })
}

fn dec_transition(j: &J) -> Result<TypedTransition, String> {
    Ok(TypedTransition {
        identity: jstr(j, "identity")?.to_string(),
        input_places: jstrs(j, "input_places")?,
        output_places: jstrs(j, "output_places")?,
        failure_places: jstrs(j, "failure_places")?,
        revision: jnat(j, "revision")?,
    })
}

fn dec_binding(j: &J) -> Result<InputBinding, String> {
    let mode = match jstr(j, "mode")? {
        "read" => BindingMode::Read,
        "consume" => BindingMode::Consume,
        other => return Err(format!("unknown binding mode {}", other)),
    };
    Ok(InputBinding {
        transition_id: jstr(j, "transition_id")?.to_string(),
        name: jstr(j, "name")?.to_string(),
        place: jstr(j, "place")?.to_string(),
        token_type: jstr(j, "token_type")?.to_string(),
        identity: jstr(j, "identity")?.to_string(),
        provenance: jstr(j, "provenance")?.to_string(),
        multiplicity: jnat(j, "multiplicity")?,
        mode,
        required_revision: jnat(j, "required_revision")?,
    })
}

fn dec_goal(j: &J) -> Result<GoalPredicate, String> {
    match jstr(j, "kind")? {
        "place_has_at_least" => Ok(GoalPredicate::PlaceHasAtLeast {
            place: jstr(j, "place")?.to_string(),
            count: jnat(j, "count")?,
        }),
        "place_has_token" => Ok(GoalPredicate::PlaceHasToken {
            place: jstr(j, "place")?.to_string(),
            target: jstr(j, "target")?.to_string(),
            index: jnat(j, "index")?,
            revision: jnat(j, "revision")?,
        }),
        "and" => Ok(GoalPredicate::And(
            Box::new(dec_goal(get(j, "a")?)?),
            Box::new(dec_goal(get(j, "b")?)?),
        )),
        "or" => Ok(GoalPredicate::Or(
            Box::new(dec_goal(get(j, "a")?)?),
            Box::new(dec_goal(get(j, "b")?)?),
        )),
        "not" => Ok(GoalPredicate::Not(Box::new(dec_goal(get(j, "a")?)?))),
        other => Err(format!("unknown goal kind {}", other)),
    }
}

fn dec_marking(j: &J) -> Result<Marking, String> {
    let mut places = Vec::new();
    for entry in jarr(j, "places")? {
        let place = jstr(entry, "place")?.to_string();
        let mut tokens = Vec::new();
        for token in jarr(entry, "tokens")? {
            tokens.push(dec_token(token)?);
        }
        places.push((place, tokens));
    }
    Ok(Marking { places })
}

fn dec_input(j: &J) -> Result<SolverInput, String> {
    let mut places = Vec::new();
    for item in jarr(j, "places")? {
        places.push(dec_place(item)?);
    }
    let mut transitions = Vec::new();
    for item in jarr(j, "transitions")? {
        transitions.push(dec_transition(item)?);
    }
    let mut bindings = Vec::new();
    for item in jarr(j, "bindings")? {
        bindings.push(dec_binding(item)?);
    }
    let graph_j = get(j, "graph")?;
    let mut edges = Vec::new();
    for edge in jarr(graph_j, "edges")? {
        match edge {
            J::Arr(pair) if pair.len() == 2 => {
                let from = match pair.first() {
                    Some(J::Str(s)) => s.clone(),
                    _ => return Err("edge endpoints must be strings".to_string()),
                };
                let to = match pair.get(1) {
                    Some(J::Str(s)) => s.clone(),
                    _ => return Err("edge endpoints must be strings".to_string()),
                };
                edges.push((from, to));
            }
            _ => return Err("edge must be a two-element array".to_string()),
        }
    }
    let bound_j = get(j, "bound")?;
    Ok(SolverInput {
        places,
        transitions,
        bindings,
        goal: dec_goal(get(j, "goal")?)?,
        graph: DeclarationGraph {
            places: jstrs(graph_j, "places")?,
            transitions: jstrs(graph_j, "transitions")?,
            edges,
            revision: jnat(graph_j, "revision")?,
        },
        marking: dec_marking(get(j, "marking")?)?,
        bound: DomainBound {
            target_identity: jstr(bound_j, "target_identity")?.to_string(),
            index: jnat(bound_j, "index")?,
            revision: jnat(bound_j, "revision")?,
            max_bindings: jnat(bound_j, "max_bindings")?,
            max_search_steps: jnat(bound_j, "max_search_steps")?,
        },
    })
}

fn esc(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn emit(j: &J, out: &mut String) {
    match j {
        J::Null => out.push_str("null"),
        J::Bool(true) => out.push_str("true"),
        J::Bool(false) => out.push_str("false"),
        J::Num(n) => out.push_str(&n.to_string()),
        J::Str(s) => out.push_str(&esc(s)),
        J::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                emit(item, out);
            }
            out.push(']');
        }
        J::Obj(fields) => {
            out.push('{');
            for (i, (k, v)) in fields.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&esc(k));
                out.push(':');
                emit(v, out);
            }
            out.push('}');
        }
    }
}

fn s(text: &str) -> J {
    J::Str(text.to_string())
}

fn enc_token(t: &ColoredToken) -> J {
    let kind = match t.kind {
        TokenKind::Input => "input",
        TokenKind::Output => "output",
        TokenKind::Failure => "failure",
        TokenKind::Effect => "effect",
        TokenKind::Observation => "observation",
        TokenKind::Accepted => "accepted",
    };
    J::Obj(vec![
        ("target".to_string(), s(&t.target)),
        ("index".to_string(), nat_j(&t.index)),
        ("revision".to_string(), nat_j(&t.revision)),
        ("kind".to_string(), s(kind)),
    ])
}

fn nat_j(n: &Nat) -> J {
    let digits = n.to_string();
    match digits.parse::<u64>() {
        Ok(v) => J::Num(v),
        Err(_) => J::Str(digits),
    }
}

fn enc_marking(m: &Marking) -> J {
    let mut places = Vec::new();
    for (place, tokens) in &m.places {
        places.push(J::Obj(vec![
            ("place".to_string(), s(place)),
            (
                "tokens".to_string(),
                J::Arr(tokens.iter().map(enc_token).collect()),
            ),
        ]));
    }
    J::Obj(vec![("places".to_string(), J::Arr(places))])
}

fn enc_binding(b: &InputBinding) -> J {
    J::Obj(vec![
        ("transition_id".to_string(), s(&b.transition_id)),
        ("name".to_string(), s(&b.name)),
        ("place".to_string(), s(&b.place)),
        ("token_type".to_string(), s(&b.token_type)),
        ("identity".to_string(), s(&b.identity)),
        ("provenance".to_string(), s(&b.provenance)),
        ("multiplicity".to_string(), nat_j(&b.multiplicity)),
        (
            "mode".to_string(),
            s(match b.mode {
                BindingMode::Read => "read",
                BindingMode::Consume => "consume",
            }),
        ),
        ("required_revision".to_string(), nat_j(&b.required_revision)),
    ])
}

fn enc_invalid(r: &InvalidReason) -> J {
    match r {
        InvalidReason::UnknownPlace(p) => J::Obj(vec![
            ("kind".to_string(), s("unknown_place")),
            ("place".to_string(), s(p)),
        ]),
        InvalidReason::UnknownInputPlace {
            transition_id,
            place,
        } => J::Obj(vec![
            ("kind".to_string(), s("unknown_input_place")),
            ("transition_id".to_string(), s(transition_id)),
            ("place".to_string(), s(place)),
        ]),
        InvalidReason::UnknownTransition(t) => J::Obj(vec![
            ("kind".to_string(), s("unknown_transition")),
            ("transition_id".to_string(), s(t)),
        ]),
        InvalidReason::DuplicateTransitionIdentity(identity) => J::Obj(vec![
            ("kind".to_string(), s("duplicate_transition_identity")),
            ("identity".to_string(), s(identity)),
        ]),
        InvalidReason::MissingInputBinding {
            transition_id,
            place,
        } => J::Obj(vec![
            ("kind".to_string(), s("missing_input_binding")),
            ("transition_id".to_string(), s(transition_id)),
            ("place".to_string(), s(place)),
        ]),
        InvalidReason::TypeMismatch {
            place,
            expected,
            actual,
        } => J::Obj(vec![
            ("kind".to_string(), s("type_mismatch")),
            ("place".to_string(), s(place)),
            ("expected".to_string(), s(expected)),
            ("actual".to_string(), s(actual)),
        ]),
        InvalidReason::MultiplicityMismatch {
            transition_id,
            name,
            expected,
            actual,
        } => J::Obj(vec![
            ("kind".to_string(), s("multiplicity_mismatch")),
            ("transition_id".to_string(), s(transition_id)),
            ("name".to_string(), s(name)),
            ("expected".to_string(), nat_j(expected)),
            ("actual".to_string(), nat_j(actual)),
        ]),
        InvalidReason::RevisionMismatch {
            transition_id,
            name,
            expected,
            actual,
        } => J::Obj(vec![
            ("kind".to_string(), s("revision_mismatch")),
            ("transition_id".to_string(), s(transition_id)),
            ("name".to_string(), s(name)),
            ("expected".to_string(), nat_j(expected)),
            ("actual".to_string(), nat_j(actual)),
        ]),
        InvalidReason::IdentityMismatch {
            transition_id,
            name,
        } => J::Obj(vec![
            ("kind".to_string(), s("identity_mismatch")),
            ("transition_id".to_string(), s(transition_id)),
            ("name".to_string(), s(name)),
        ]),
        InvalidReason::DependencyMismatch {
            transition_id,
            place,
        } => J::Obj(vec![
            ("kind".to_string(), s("dependency_mismatch")),
            ("transition_id".to_string(), s(transition_id)),
            ("place".to_string(), s(place)),
        ]),
    }
}

fn enc_unknown(r: &UnknownReason) -> J {
    match r {
        UnknownReason::BindingBoundExhausted(n) => J::Obj(vec![
            ("kind".to_string(), s("binding_bound_exhausted")),
            ("limit".to_string(), nat_j(n)),
        ]),
        UnknownReason::SearchStepBoundExhausted(n) => J::Obj(vec![
            ("kind".to_string(), s("search_step_bound_exhausted")),
            ("limit".to_string(), nat_j(n)),
        ]),
    }
}

fn enc_enabled_set(set: &EnabledSet) -> J {
    J::Arr(
        set.enabled
            .iter()
            .map(|e| {
                J::Obj(vec![
                    ("transition_id".to_string(), s(&e.transition_id)),
                    (
                        "bindings".to_string(),
                        J::Arr(e.bindings.iter().map(enc_binding).collect()),
                    ),
                ])
            })
            .collect(),
    )
}

fn enc_operations(input: &SolverInput) -> Result<J, String> {
    let enabled = match derive_enabled(input) {
        Ok(EnabledResult::EnabledSet(set)) => J::Obj(vec![
            ("status".to_string(), s("enabled_set")),
            ("enabled".to_string(), enc_enabled_set(&set)),
        ]),
        Ok(EnabledResult::Invalid(r)) => J::Obj(vec![
            ("status".to_string(), s("invalid")),
            ("reason".to_string(), enc_invalid(&r)),
        ]),
        Err(failure) => return Err(format!("derive_enabled failed: {:?}", failure)),
    };
    let reachability = match check_reachability(input) {
        Ok(ReachabilityResult::Invalid(r)) => J::Obj(vec![
            ("status".to_string(), s("invalid")),
            ("reason".to_string(), enc_invalid(&r)),
        ]),
        Ok(ReachabilityResult::Reachable(w)) => J::Obj(vec![
            ("status".to_string(), s("reachable")),
            (
                "path".to_string(),
                J::Arr(w.path.iter().map(|p| s(p)).collect()),
            ),
            ("final_marking".to_string(), enc_marking(&w.final_marking)),
        ]),
        Ok(ReachabilityResult::Unknown(r)) => J::Obj(vec![
            ("status".to_string(), s("unknown")),
            ("reason".to_string(), enc_unknown(&r)),
        ]),
        Ok(ReachabilityResult::Unreachable(w)) => J::Obj(vec![
            ("status".to_string(), s("unreachable")),
            (
                "closure_witness".to_string(),
                J::Obj(vec![
                    (
                        "explored_markings".to_string(),
                        J::Arr(w.explored_markings.iter().map(enc_marking).collect()),
                    ),
                    ("steps".to_string(), nat_j(&w.steps)),
                    (
                        "frontier".to_string(),
                        J::Arr(w.frontier.iter().map(enc_marking).collect()),
                    ),
                ]),
            ),
        ]),
        Err(failure) => return Err(format!("check_reachability failed: {:?}", failure)),
    };
    let deadlock = match check_deadlock(input) {
        Ok(DeadlockResult::Deadlocked(w)) => J::Obj(vec![
            ("status".to_string(), s("deadlocked")),
            ("marking".to_string(), enc_marking(&w.marking)),
        ]),
        Ok(DeadlockResult::Invalid(r)) => J::Obj(vec![
            ("status".to_string(), s("invalid")),
            ("reason".to_string(), enc_invalid(&r)),
        ]),
        Ok(DeadlockResult::NotDeadlocked(set)) => J::Obj(vec![
            ("status".to_string(), s("not_deadlocked")),
            ("enabled".to_string(), enc_enabled_set(&set)),
        ]),
        Ok(DeadlockResult::Unknown(r)) => J::Obj(vec![
            ("status".to_string(), s("unknown")),
            ("reason".to_string(), enc_unknown(&r)),
        ]),
        Err(failure) => return Err(format!("check_deadlock failed: {:?}", failure)),
    };
    let well_foundedness = match check_well_foundedness(input) {
        Ok(WellFoundednessResult::Invalid(r)) => J::Obj(vec![
            ("status".to_string(), s("invalid")),
            ("reason".to_string(), enc_invalid(&r)),
        ]),
        Ok(WellFoundednessResult::NotWellFounded(w)) => J::Obj(vec![
            ("status".to_string(), s("not_well_founded")),
            ("witness".to_string(), enc_cycle_witness(&w)),
        ]),
        Ok(WellFoundednessResult::Unknown(r)) => J::Obj(vec![
            ("status".to_string(), s("unknown")),
            ("reason".to_string(), enc_unknown(&r)),
        ]),
        Ok(WellFoundednessResult::WellFounded(w)) => J::Obj(vec![
            ("status".to_string(), s("well_founded")),
            ("witness".to_string(), enc_acyclic_witness(&w)),
        ]),
        Err(failure) => return Err(format!("check_well_foundedness failed: {:?}", failure)),
    };
    Ok(J::Obj(vec![
        ("derive_enabled".to_string(), enabled),
        ("check_reachability".to_string(), reachability),
        ("check_deadlock".to_string(), deadlock),
        ("check_well_foundedness".to_string(), well_foundedness),
    ]))
}

fn enc_cycle_witness(w: &necoherence::typed_mapping::CycleWitness) -> J {
    J::Obj(vec![
        (
            "prefix_path".to_string(),
            J::Arr(w.prefix_path.iter().map(|p| s(p)).collect()),
        ),
        (
            "cycle_path".to_string(),
            J::Arr(w.cycle_path.iter().map(|p| s(p)).collect()),
        ),
        ("cycle_start".to_string(), enc_marking(&w.cycle_start)),
        ("cycle_end".to_string(), enc_marking(&w.cycle_end)),
        (
            "measure_decreasing".to_string(),
            J::Bool(w.measure_decreasing),
        ),
    ])
}

fn enc_acyclic_witness(w: &necoherence::typed_mapping::AcyclicWitness) -> J {
    J::Obj(vec![
        (
            "explored_markings".to_string(),
            J::Arr(w.explored_markings.iter().map(enc_marking).collect()),
        ),
        ("steps".to_string(), nat_j(&w.steps)),
        (
            "frontier".to_string(),
            J::Arr(w.frontier.iter().map(enc_marking).collect()),
        ),
    ])
}

fn run() -> Result<String, String> {
    let path = env::args()
        .nth(1)
        .ok_or_else(|| "usage: typed_mapping_solver_compare <fixtures.json>".to_string())?;
    let text = fs::read_to_string(&path).map_err(|e| format!("cannot read {}: {}", path, e))?;
    let mut reader = Reader::new(&text);
    let document = reader.value()?;
    let cases = jarr(&document, "cases")?;
    let mut results = Vec::new();
    for case in cases {
        let name = jstr(case, "name")?;
        let input = dec_input(get(case, "input")?)?;
        results.push(J::Obj(vec![
            ("case".to_string(), s(name)),
            ("operations".to_string(), enc_operations(&input)?),
        ]));
    }
    let out = J::Obj(vec![
        ("producer".to_string(), s("rust")),
        (
            "solver_module".to_string(),
            s("necoherence_tools::typed_mapping_solver"),
        ),
        ("producer_kind".to_string(), s("public-api")),
        ("results".to_string(), J::Arr(results)),
    ]);
    let mut text = String::new();
    emit(&out, &mut text);
    Ok(text)
}

fn main() -> Result<(), String> {
    use std::io::Write;
    let text = run().map_err(|message| format!("typed_mapping_solver_compare: {}", message))?;
    let mut stdout = std::io::stdout().lock();
    stdout
        .write_all(text.as_bytes())
        .map_err(|e| e.to_string())?;
    stdout.write_all(b"\n").map_err(|e| e.to_string())
}
