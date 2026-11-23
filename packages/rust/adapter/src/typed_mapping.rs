// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Typed mapping: finite typed places, transitions, colored tokens,
//! input bindings, one-step transitions and result types, mirroring the
//! Lean semantic authority `Necoherence.TypedMapping`.

use crate::core::Nat;
use std::collections::{HashMap, HashSet};

/// What role a token plays at the point it is carried.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TokenKind {
    Input,
    Output,
    Failure,
    Effect,
    Observation,
    Accepted,
}

/// A colored token: the resource it belongs to, its declared position,
/// its revision, and its kind.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ColoredToken {
    pub target: String,
    pub index: Nat,
    pub revision: Nat,
    pub kind: TokenKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TypedPlace {
    pub identity: String,
    pub token_type: String,
    pub revision: Nat,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TypedTransition {
    pub identity: String,
    pub input_places: Vec<String>,
    pub output_places: Vec<String>,
    pub failure_places: Vec<String>,
    pub revision: Nat,
}

/// Whether an input binding retains its matched tokens (`Read`) or
/// removes them (`Consume`) when its transition's branch is applied.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BindingMode {
    Read,
    Consume,
}

/// One declared input binding for one transition: the place it reads
/// from, the type and identity it requires, and the revision every
/// matched token must carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputBinding {
    pub transition_id: String,
    pub name: String,
    pub place: String,
    pub token_type: String,
    pub identity: String,
    pub provenance: String,
    pub multiplicity: Nat,
    pub mode: BindingMode,
    pub required_revision: Nat,
}

/// The dependency graph over declared places and transitions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeclarationGraph {
    pub places: Vec<String>,
    pub transitions: Vec<String>,
    pub edges: Vec<(String, String)>,
    pub revision: Nat,
}

/// The finite domain and search bound: how many binding-carrying
/// transitions and how many search steps the solver may explore.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DomainBound {
    pub target_identity: String,
    pub index: Nat,
    pub revision: Nat,
    pub max_bindings: Nat,
    pub max_search_steps: Nat,
}

/// A marking: for each place, the multiset (as a list) of tokens it
/// carries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Marking {
    pub places: Vec<(String, Vec<ColoredToken>)>,
}

/// The tokens a marking carries at one place; a place absent from the
/// marking carries none.
pub fn tokens_at<'a>(m: &'a Marking, place: &str) -> &'a [ColoredToken] {
    match m.places.iter().find(|(p, _)| p == place) {
        Some((_, ts)) => ts,
        None => &[],
    }
}

/// A finite, decidable predicate over a marking: which place must carry
/// how many tokens, or which exact token, combined by and/or/not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GoalPredicate {
    PlaceHasAtLeast {
        place: String,
        count: Nat,
    },
    PlaceHasToken {
        place: String,
        target: String,
        index: Nat,
        revision: Nat,
    },
    And(Box<GoalPredicate>, Box<GoalPredicate>),
    Or(Box<GoalPredicate>, Box<GoalPredicate>),
    Not(Box<GoalPredicate>),
}

/// Evaluate a goal predicate against a marking.
pub fn eval_goal(m: &Marking, goal: &GoalPredicate) -> bool {
    match goal {
        GoalPredicate::PlaceHasAtLeast { place, count } => {
            *count <= Nat::from(tokens_at(m, place).len())
        }
        GoalPredicate::PlaceHasToken {
            place,
            target,
            index,
            revision,
        } => tokens_at(m, place)
            .iter()
            .any(|t| t.target == *target && t.index == *index && t.revision == *revision),
        GoalPredicate::And(a, b) => eval_goal(m, a) && eval_goal(m, b),
        GoalPredicate::Or(a, b) => eval_goal(m, a) || eval_goal(m, b),
        GoalPredicate::Not(a) => !eval_goal(m, a),
    }
}

/// The complete, closed input to every solver operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SolverInput {
    pub places: Vec<TypedPlace>,
    pub transitions: Vec<TypedTransition>,
    pub bindings: Vec<InputBinding>,
    pub goal: GoalPredicate,
    pub graph: DeclarationGraph,
    pub marking: Marking,
    pub bound: DomainBound,
}

/// Why a declared typed mapping is invalid.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InvalidReason {
    UnknownPlace(String),
    UnknownInputPlace {
        transition_id: String,
        place: String,
    },
    UnknownTransition(String),
    DuplicateTransitionIdentity(String),
    MissingInputBinding {
        transition_id: String,
        place: String,
    },
    TypeMismatch {
        place: String,
        expected: String,
        actual: String,
    },
    MultiplicityMismatch {
        transition_id: String,
        name: String,
        expected: Nat,
        actual: Nat,
    },
    RevisionMismatch {
        transition_id: String,
        name: String,
        expected: Nat,
        actual: Nat,
    },
    IdentityMismatch {
        transition_id: String,
        name: String,
    },
    DependencyMismatch {
        transition_id: String,
        place: String,
    },
}

/// Why a bounded search could not settle a result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UnknownReason {
    BindingBoundExhausted(Nat),
    SearchStepBoundExhausted(Nat),
}

/// One enabled transition together with the bindings it was enabled by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnabledTransition {
    pub transition_id: String,
    pub bindings: Vec<InputBinding>,
}

/// The finite set of binding-carrying transitions enabled by a marking.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnabledSet {
    pub enabled: Vec<EnabledTransition>,
}

/// The closed result of `derive_enabled`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EnabledResult {
    EnabledSet(EnabledSet),
    Invalid(InvalidReason),
}

/// The firing sequence and marking that satisfied a goal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReachabilityWitness {
    pub path: Vec<String>,
    pub final_marking: Marking,
}

/// The finite closure a bounded search actually explored, proving no
/// marking in it satisfies the goal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClosureWitness {
    pub explored_markings: Vec<Marking>,
    pub steps: Nat,
    pub frontier: Vec<Marking>,
}

/// The closed result of `check_reachability`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReachabilityResult {
    Invalid(InvalidReason),
    Reachable(ReachabilityWitness),
    Unknown(UnknownReason),
    Unreachable(ClosureWitness),
}

/// The marking a deadlock was observed at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeadlockWitness {
    pub marking: Marking,
}

/// The closed result of `check_deadlock`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeadlockResult {
    Deadlocked(DeadlockWitness),
    Invalid(InvalidReason),
    NotDeadlocked(EnabledSet),
    Unknown(UnknownReason),
}

/// Evidence for a detected repeated-marking cycle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CycleWitness {
    pub prefix_path: Vec<String>,
    pub cycle_path: Vec<String>,
    pub cycle_start: Marking,
    pub cycle_end: Marking,
    pub measure_decreasing: bool,
}

/// Evidence for a finite acyclic well-foundedness closure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcyclicWitness {
    pub explored_markings: Vec<Marking>,
    pub steps: Nat,
    pub frontier: Vec<Marking>,
}

/// The closed result of `check_well_foundedness`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WellFoundednessResult {
    Invalid(InvalidReason),
    NotWellFounded(CycleWitness),
    Unknown(UnknownReason),
    WellFounded(AcyclicWitness),
}

/// A violated host contract or an impossible implementation invariant;
/// never a declaration mismatch, which is always the closed `Invalid` result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SolverFailure {
    ContractViolation(String),
    InternalInvariantViolation(String),
}

struct Declaration<'a> {
    place_types: HashMap<&'a str, &'a str>,
    transitions: HashMap<&'a str, &'a TypedTransition>,
    input_places: HashSet<(&'a str, &'a str)>,
}

fn declaration_of(input: &SolverInput) -> Declaration<'_> {
    let mut place_types = HashMap::with_capacity(input.places.len());
    for place in &input.places {
        place_types
            .entry(place.identity.as_str())
            .or_insert(place.token_type.as_str());
    }
    let mut transitions = HashMap::with_capacity(input.transitions.len());
    for transition in &input.transitions {
        transitions
            .entry(transition.identity.as_str())
            .or_insert(transition);
    }
    let input_places = transitions
        .values()
        .flat_map(|transition| {
            transition
                .input_places
                .iter()
                .map(|place| (transition.identity.as_str(), place.as_str()))
        })
        .collect();
    Declaration {
        place_types,
        transitions,
        input_places,
    }
}

fn first_places(m: &Marking) -> HashMap<&str, &[ColoredToken]> {
    let mut places = HashMap::with_capacity(m.places.len());
    for (place, tokens) in &m.places {
        places.entry(place.as_str()).or_insert(tokens.as_slice());
    }
    places
}

fn check_input_place_membership(
    input: &SolverInput,
    declaration: &Declaration<'_>,
) -> Option<InvalidReason> {
    input.transitions.iter().find_map(|t| {
        t.input_places
            .iter()
            .find(|p| !declaration.place_types.contains_key(p.as_str()))
            .map(|p| InvalidReason::UnknownInputPlace {
                transition_id: t.identity.clone(),
                place: p.clone(),
            })
    })
}

fn check_duplicate_transition_identity(input: &SolverInput) -> Option<InvalidReason> {
    let mut counts: HashMap<&str, usize> = HashMap::with_capacity(input.transitions.len());
    for t in &input.transitions {
        *counts.entry(t.identity.as_str()).or_default() += 1;
    }
    input
        .transitions
        .iter()
        .find(|t| {
            counts
                .get(t.identity.as_str())
                .is_some_and(|count| 1 < *count)
        })
        .map(|t| InvalidReason::DuplicateTransitionIdentity(t.identity.clone()))
}

fn check_binding_coverage(input: &SolverInput) -> Option<InvalidReason> {
    let covered: HashSet<(&str, &str)> = input
        .bindings
        .iter()
        .map(|b| (b.transition_id.as_str(), b.place.as_str()))
        .collect();
    input.transitions.iter().find_map(|t| {
        t.input_places
            .iter()
            .find(|place| !covered.contains(&(t.identity.as_str(), place.as_str())))
            .map(|place| InvalidReason::MissingInputBinding {
                transition_id: t.identity.clone(),
                place: place.clone(),
            })
    })
}

fn find_transition<'a>(
    transitions: &'a [TypedTransition],
    id: &str,
) -> Option<&'a TypedTransition> {
    transitions.iter().find(|t| t.identity == id)
}

fn check_binding_structure(
    declaration: &Declaration<'_>,
    names: &HashMap<(&str, &str), usize>,
    b: &InputBinding,
) -> Option<InvalidReason> {
    if !declaration
        .transitions
        .contains_key(b.transition_id.as_str())
    {
        return Some(InvalidReason::UnknownTransition(b.transition_id.clone()));
    }
    let Some(ty) = declaration.place_types.get(b.place.as_str()) else {
        return Some(InvalidReason::UnknownPlace(b.place.clone()));
    };
    if !declaration
        .input_places
        .contains(&(b.transition_id.as_str(), b.place.as_str()))
    {
        return Some(InvalidReason::DependencyMismatch {
            transition_id: b.transition_id.clone(),
            place: b.place.clone(),
        });
    }
    if *ty != b.token_type {
        return Some(InvalidReason::TypeMismatch {
            place: b.place.clone(),
            expected: b.token_type.clone(),
            actual: (*ty).to_string(),
        });
    }
    if b.multiplicity == Nat::from(0u8) {
        return Some(InvalidReason::MultiplicityMismatch {
            transition_id: b.transition_id.clone(),
            name: b.name.clone(),
            expected: Nat::from(1u8),
            actual: Nat::from(0u8),
        });
    }
    if names
        .get(&(b.transition_id.as_str(), b.name.as_str()))
        .is_some_and(|count| 1 < *count)
    {
        return Some(InvalidReason::IdentityMismatch {
            transition_id: b.transition_id.clone(),
            name: b.name.clone(),
        });
    }
    None
}

struct TargetRevisions<'a> {
    first: &'a Nat,
    other: Option<&'a Nat>,
}

fn target_revisions(m: &Marking) -> HashMap<(&str, &str), TargetRevisions<'_>> {
    let mut revisions: HashMap<(&str, &str), TargetRevisions<'_>> = HashMap::new();
    for (place, tokens) in first_places(m) {
        for token in tokens {
            revisions
                .entry((place, token.target.as_str()))
                .and_modify(|seen| {
                    if seen.other.is_none() && seen.first != &token.revision {
                        seen.other = Some(&token.revision);
                    }
                })
                .or_insert(TargetRevisions {
                    first: &token.revision,
                    other: None,
                });
        }
    }
    revisions
}

fn check_binding_revision(
    revisions: &HashMap<(&str, &str), TargetRevisions<'_>>,
    b: &InputBinding,
) -> Option<InvalidReason> {
    let seen = revisions.get(&(b.place.as_str(), b.identity.as_str()))?;
    let actual = if seen.first != &b.required_revision {
        seen.first
    } else {
        seen.other?
    };
    Some(InvalidReason::RevisionMismatch {
        transition_id: b.transition_id.clone(),
        name: b.name.clone(),
        expected: b.required_revision.clone(),
        actual: actual.clone(),
    })
}

fn check_graph(input: &SolverInput, declaration: &Declaration<'_>) -> Option<InvalidReason> {
    if let Some(place) = input
        .graph
        .places
        .iter()
        .find(|p| !declaration.place_types.contains_key(p.as_str()))
    {
        return Some(InvalidReason::UnknownPlace(place.clone()));
    }
    if let Some(transition) = input
        .graph
        .transitions
        .iter()
        .find(|t| !declaration.transitions.contains_key(t.as_str()))
    {
        return Some(InvalidReason::UnknownTransition(transition.clone()));
    }
    let nodes: HashSet<&str> = input
        .graph
        .places
        .iter()
        .chain(input.graph.transitions.iter())
        .map(String::as_str)
        .collect();
    input
        .graph
        .edges
        .iter()
        .find(|e| !nodes.contains(e.0.as_str()) || !nodes.contains(e.1.as_str()))
        .map(|e| InvalidReason::DependencyMismatch {
            transition_id: e.0.clone(),
            place: e.1.clone(),
        })
}

fn check_branch_places(
    input: &SolverInput,
    declaration: &Declaration<'_>,
) -> Option<InvalidReason> {
    input
        .transitions
        .iter()
        .flat_map(|t| {
            t.output_places
                .iter()
                .chain(t.failure_places.iter())
                .map(move |p| (t, p))
        })
        .find(|(_, p)| !declaration.place_types.contains_key(p.as_str()))
        .map(|(t, p)| InvalidReason::DependencyMismatch {
            transition_id: t.identity.clone(),
            place: p.clone(),
        })
}

/// Validate a declared typed mapping in the contract's precedence order.
pub fn validate(input: &SolverInput) -> Option<InvalidReason> {
    let declaration = declaration_of(input);
    if let Some(reason) = check_input_place_membership(input, &declaration) {
        return Some(reason);
    }
    if let Some(reason) = check_duplicate_transition_identity(input) {
        return Some(reason);
    }
    if let Some(reason) = check_binding_coverage(input) {
        return Some(reason);
    }
    let mut names: HashMap<(&str, &str), usize> = HashMap::with_capacity(input.bindings.len());
    for b in &input.bindings {
        *names
            .entry((b.transition_id.as_str(), b.name.as_str()))
            .or_default() += 1;
    }
    if let Some(reason) = input
        .bindings
        .iter()
        .find_map(|b| check_binding_structure(&declaration, &names, b))
    {
        return Some(reason);
    }
    let revisions = target_revisions(&input.marking);
    if let Some(reason) = input
        .bindings
        .iter()
        .find_map(|b| check_binding_revision(&revisions, b))
    {
        return Some(reason);
    }
    if let Some(reason) = check_graph(input, &declaration) {
        return Some(reason);
    }
    check_branch_places(input, &declaration)
}

/// The declared input bindings of one transition.
pub fn bindings_for(input: &SolverInput, transition_id: &str) -> Vec<InputBinding> {
    input
        .bindings
        .iter()
        .filter(|b| b.transition_id == transition_id)
        .cloned()
        .collect()
}

fn bindings_by_transition(input: &SolverInput) -> HashMap<&str, Vec<&InputBinding>> {
    let mut grouped: HashMap<&str, Vec<&InputBinding>> = HashMap::new();
    for b in &input.bindings {
        grouped.entry(b.transition_id.as_str()).or_default().push(b);
    }
    grouped
}

fn matching(token: &ColoredToken, b: &InputBinding) -> bool {
    token.target == b.identity && token.revision == b.required_revision
}

/// Whether a marking carries enough matching, correctly-revisioned
/// tokens to satisfy one binding.
pub fn binding_satisfied_at(m: &Marking, b: &InputBinding) -> bool {
    let matched = tokens_at(m, &b.place)
        .iter()
        .filter(|t| matching(t, b))
        .count();
    b.multiplicity <= Nat::from(matched)
}

/// Whether every one of a transition's declared bindings is satisfied
/// at a marking.
pub fn transition_enabled_at(bindings: &[InputBinding], m: &Marking) -> bool {
    bindings.iter().all(|b| binding_satisfied_at(m, b))
}

fn enabled_at(bindings: &[&InputBinding], m: &Marking) -> bool {
    bindings.iter().all(|b| binding_satisfied_at(m, b))
}

/// The candidate input bindings enumerated while scanning the declared
/// transitions for enabledness at a marking: every declared binding of
/// every declared transition is a candidate the solver must consider.
pub fn candidate_binding_count(input: &SolverInput) -> Nat {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for b in &input.bindings {
        *counts.entry(b.transition_id.as_str()).or_default() += 1;
    }
    let total: usize = input
        .transitions
        .iter()
        .map(|t| counts.get(t.identity.as_str()).copied().unwrap_or(0))
        .sum();
    Nat::from(total)
}

/// Whether binding enumeration exceeds the declared bound
/// `max_bindings`; operations then report
/// `Unknown(BindingBoundExhausted(_))`.
pub fn binding_bound_exceeded(input: &SolverInput) -> bool {
    input.bound.max_bindings < candidate_binding_count(input)
}

fn select_matching(tokens: &[ColoredToken], b: &InputBinding) -> Vec<ColoredToken> {
    let mut selected = Vec::new();
    for t in tokens.iter().filter(|t| matching(t, b)) {
        if Nat::from(selected.len()) >= b.multiplicity {
            break;
        }
        selected.push(t.clone());
    }
    selected
}

/// The tokens one transition's `Consume` bindings actually remove from
/// one place, given a marking.
pub fn consumed_at(bindings: &[InputBinding], m: &Marking, place: &str) -> Vec<ColoredToken> {
    let mut acc = Vec::new();
    for b in bindings
        .iter()
        .filter(|b| b.place == place && b.mode == BindingMode::Consume)
    {
        acc.extend(select_matching(tokens_at(m, place), b));
    }
    acc
}

fn remove_counted(tokens: &mut Vec<ColoredToken>, mut counts: HashMap<ColoredToken, usize>) {
    tokens.retain(|token| match counts.get_mut(token) {
        Some(count) if 0 < *count => {
            *count -= 1;
            false
        }
        _ => true,
    });
}

fn removal_counts(to_remove: &[ColoredToken]) -> HashMap<ColoredToken, usize> {
    let mut counts = HashMap::with_capacity(to_remove.len());
    for token in to_remove {
        *counts.entry(token.clone()).or_default() += 1;
    }
    counts
}

/// Remove exactly the occurrences in `to_remove` from `tokens`:
/// multiset subtraction preserving duplicates beyond the selected count.
pub fn remove_all_tokens(
    mut tokens: Vec<ColoredToken>,
    to_remove: &[ColoredToken],
) -> Vec<ColoredToken> {
    remove_counted(&mut tokens, removal_counts(to_remove));
    tokens
}

fn consume_in_place(m: &mut Marking, bindings: &[&InputBinding]) {
    let mut removals: HashMap<&str, HashMap<ColoredToken, usize>> = HashMap::new();
    for b in bindings.iter().filter(|b| b.mode == BindingMode::Consume) {
        let counts = removals.entry(b.place.as_str()).or_default();
        for token in select_matching(tokens_at(m, &b.place), b) {
            *counts.entry(token).or_default() += 1;
        }
    }
    for (place, counts) in removals {
        for (_, tokens) in m.places.iter_mut().filter(|(p, _)| p == place) {
            remove_counted(tokens, counts.clone());
        }
    }
}

/// Apply the consume side of one declared branch: every place keeps its
/// tokens except the occurrences its transition's `Consume` bindings
/// selected.
pub fn apply_consumption(mut m: Marking, bindings: &[InputBinding]) -> Marking {
    let bindings: Vec<&InputBinding> = bindings.iter().collect();
    consume_in_place(&mut m, &bindings);
    m
}

fn add_token_in_place(m: &mut Marking, place: &str, tok: &ColoredToken) {
    let mut found = false;
    for (_, tokens) in m.places.iter_mut().filter(|(p, _)| p == place) {
        tokens.insert(0, tok.clone());
        found = true;
    }
    if !found {
        m.places.push((place.to_string(), vec![tok.clone()]));
    }
}

/// The token produced at each of a transition's declared output places:
/// its own identity, index zero, its own revision, kind `Output`.
pub fn produced_token(t: &TypedTransition) -> ColoredToken {
    ColoredToken {
        target: t.identity.clone(),
        index: Nat::from(0u8),
        revision: t.revision.clone(),
        kind: TokenKind::Output,
    }
}

fn branch_in_place(m: &mut Marking, t: &TypedTransition, bindings: &[&InputBinding]) {
    consume_in_place(m, bindings);
    let token = produced_token(t);
    for place in &t.output_places {
        add_token_in_place(m, place, &token);
    }
}

/// Atomically apply one declared result branch: consume bindings
/// remove their tokens, read bindings retain theirs and every declared
/// output place gains the produced token. Nothing is promoted to an observation.
pub fn apply_branch_at(mut m: Marking, t: &TypedTransition, bindings: &[InputBinding]) -> Marking {
    let bindings: Vec<&InputBinding> = bindings.iter().collect();
    branch_in_place(&mut m, t, &bindings);
    m
}

pub fn step_at(input: &SolverInput, m: &Marking, transition_id: &str) -> Option<Marking> {
    let t = find_transition(&input.transitions, transition_id)?;
    let bindings: Vec<&InputBinding> = input
        .bindings
        .iter()
        .filter(|b| b.transition_id == transition_id)
        .collect();
    if !enabled_at(&bindings, m) {
        return None;
    }
    let mut next = m.clone();
    branch_in_place(&mut next, t, &bindings);
    Some(next)
}

pub fn path_replay(input: &SolverInput, start: &Marking, path: &[String]) -> Option<Marking> {
    let mut transitions: HashMap<&str, &TypedTransition> = HashMap::new();
    for t in &input.transitions {
        transitions.entry(t.identity.as_str()).or_insert(t);
    }
    let grouped = bindings_by_transition(input);
    let mut current = start.clone();
    for transition_id in path {
        let t = transitions.get(transition_id.as_str())?;
        let bindings = grouped
            .get(transition_id.as_str())
            .map_or(&[][..], Vec::as_slice);
        if !enabled_at(bindings, &current) {
            return None;
        }
        branch_in_place(&mut current, t, bindings);
    }
    Some(current)
}

/// Derive the finite set of binding-carrying transitions enabled by
/// `input.marking`, after validating the declaration.
pub fn derive_enabled(input: &SolverInput) -> Result<EnabledResult, SolverFailure> {
    if let Some(reason) = validate(input) {
        return Ok(EnabledResult::Invalid(reason));
    }
    let grouped = bindings_by_transition(input);
    let mut available: HashMap<(&str, &str, &Nat), usize> = HashMap::new();
    for (place, tokens) in first_places(&input.marking) {
        for token in tokens {
            *available
                .entry((place, token.target.as_str(), &token.revision))
                .or_default() += 1;
        }
    }
    let satisfied = |b: &InputBinding| {
        let count = available
            .get(&(b.place.as_str(), b.identity.as_str(), &b.required_revision))
            .copied()
            .unwrap_or(0);
        b.multiplicity <= Nat::from(count)
    };
    let enabled = input
        .transitions
        .iter()
        .filter_map(|t| {
            let bindings = grouped
                .get(t.identity.as_str())
                .map_or(&[][..], Vec::as_slice);
            bindings
                .iter()
                .all(|b| satisfied(b))
                .then(|| EnabledTransition {
                    transition_id: t.identity.clone(),
                    bindings: bindings.iter().map(|b| (*b).clone()).collect(),
                })
        })
        .collect();
    Ok(EnabledResult::EnabledSet(EnabledSet { enabled }))
}

/// Deadlock and goal satisfaction never hold at the same marking.
pub fn check_deadlock_goal_separation(goal_holds: bool, deadlocked: bool) -> bool {
    !(goal_holds && deadlocked)
}
