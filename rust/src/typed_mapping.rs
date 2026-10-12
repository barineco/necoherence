// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Typed mapping: finite typed places, transitions, colored tokens,
//! input bindings, one-step transitions and result types, mirroring the
//! Lean semantic authority `Necoherence.TypedMapping`.

use crate::core::Nat;

/// What role a token plays at the point it is carried.
#[derive(Clone, Debug, PartialEq, Eq)]
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
#[derive(Clone, Debug, PartialEq, Eq)]
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

fn place_exists(places: &[TypedPlace], id: &str) -> bool {
    places.iter().any(|p| p.identity == id)
}

fn place_type<'a>(places: &'a [TypedPlace], id: &str) -> Option<&'a str> {
    places
        .iter()
        .find(|p| p.identity == id)
        .map(|p| p.token_type.as_str())
}

fn transition_exists(transitions: &[TypedTransition], id: &str) -> bool {
    transitions.iter().any(|t| t.identity == id)
}

fn check_input_place_membership(input: &SolverInput) -> Option<InvalidReason> {
    input.transitions.iter().find_map(|t| {
        t.input_places
            .iter()
            .find(|p| !place_exists(&input.places, p))
            .map(|p| InvalidReason::UnknownInputPlace {
                transition_id: t.identity.clone(),
                place: (*p).clone(),
            })
    })
}

fn check_duplicate_transition_identity(input: &SolverInput) -> Option<InvalidReason> {
    input.transitions.iter().enumerate().find_map(|(index, t)| {
        input
            .transitions
            .iter()
            .skip(index.saturating_add(1))
            .any(|other| other.identity == t.identity)
            .then(|| InvalidReason::DuplicateTransitionIdentity(t.identity.clone()))
    })
}

fn check_binding_coverage(input: &SolverInput) -> Option<InvalidReason> {
    input.transitions.iter().find_map(|t| {
        if t.input_places.is_empty() {
            return None;
        }
        t.input_places
            .iter()
            .find(|place| {
                !input
                    .bindings
                    .iter()
                    .any(|b| b.transition_id == t.identity && b.place.as_str() == place.as_str())
            })
            .map(|place| InvalidReason::MissingInputBinding {
                transition_id: t.identity.clone(),
                place: (*place).clone(),
            })
    })
}

fn find_transition<'a>(
    transitions: &'a [TypedTransition],
    id: &str,
) -> Option<&'a TypedTransition> {
    transitions.iter().find(|t| t.identity == id)
}

fn duplicate_binding_name(input: &SolverInput, b: &InputBinding) -> bool {
    1 < input
        .bindings
        .iter()
        .filter(|b2| b2.transition_id == b.transition_id && b2.name == b.name)
        .count()
}

/// Structural validity of one binding: declared transition and place,
/// input-place membership, declared type, positive multiplicity and no
/// duplicate name within the transition.
fn check_binding_structure(input: &SolverInput, b: &InputBinding) -> Option<InvalidReason> {
    if !transition_exists(&input.transitions, &b.transition_id) {
        return Some(InvalidReason::UnknownTransition(b.transition_id.clone()));
    }
    if !place_exists(&input.places, &b.place) {
        return Some(InvalidReason::UnknownPlace(b.place.clone()));
    }
    let t = match find_transition(&input.transitions, &b.transition_id) {
        None => return Some(InvalidReason::UnknownTransition(b.transition_id.clone())),
        Some(t) => t,
    };
    if !t.input_places.contains(&b.place) {
        return Some(InvalidReason::DependencyMismatch {
            transition_id: b.transition_id.clone(),
            place: b.place.clone(),
        });
    }
    let ty = match place_type(&input.places, &b.place) {
        None => return Some(InvalidReason::UnknownPlace(b.place.clone())),
        Some(ty) => ty,
    };
    if ty != b.token_type {
        return Some(InvalidReason::TypeMismatch {
            place: b.place.clone(),
            expected: b.token_type.clone(),
            actual: ty.to_string(),
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
    if duplicate_binding_name(input, b) {
        return Some(InvalidReason::IdentityMismatch {
            transition_id: b.transition_id.clone(),
            name: b.name.clone(),
        });
    }
    None
}

/// A token present at a binding's place, sharing the binding's target
/// identity, whose revision differs from the binding's declared required
/// revision is a colored-token mismatch.
fn check_binding_revision(input: &SolverInput, b: &InputBinding) -> Option<InvalidReason> {
    tokens_at(&input.marking, &b.place)
        .iter()
        .find(|t| t.target == b.identity && t.revision != b.required_revision)
        .map(|t| InvalidReason::RevisionMismatch {
            transition_id: b.transition_id.clone(),
            name: b.name.clone(),
            expected: b.required_revision.clone(),
            actual: t.revision.clone(),
        })
}

fn check_graph_places(input: &SolverInput) -> Option<InvalidReason> {
    input
        .graph
        .places
        .iter()
        .find(|p| !place_exists(&input.places, p))
        .map(|p| InvalidReason::UnknownPlace(p.clone()))
}

fn check_graph_transitions(input: &SolverInput) -> Option<InvalidReason> {
    input
        .graph
        .transitions
        .iter()
        .find(|t| !transition_exists(&input.transitions, t))
        .map(|t| InvalidReason::UnknownTransition(t.clone()))
}

/// An edge endpoint is valid when it names a declared place or a
/// declared transition of the dependency graph.
fn is_graph_node(input: &SolverInput, id: &str) -> bool {
    input.graph.places.iter().any(|p| p == id) || input.graph.transitions.iter().any(|t| t == id)
}

fn check_graph_edges(input: &SolverInput) -> Option<InvalidReason> {
    input
        .graph
        .edges
        .iter()
        .find(|e| !is_graph_node(input, &e.0) || !is_graph_node(input, &e.1))
        .map(|e| InvalidReason::DependencyMismatch {
            transition_id: e.0.clone(),
            place: e.1.clone(),
        })
}

/// Every output place and failure place a transition declares must belong
/// to the declared place set; a branch place outside it would let
/// `apply_branch_at` mint markings outside the declared finite domain.
fn check_branch_places(input: &SolverInput) -> Option<InvalidReason> {
    input
        .transitions
        .iter()
        .flat_map(|t| {
            t.output_places
                .iter()
                .chain(t.failure_places.iter())
                .map(move |p| (t, p))
        })
        .find(|(_, p)| !place_exists(&input.places, p))
        .map(|(t, p)| InvalidReason::DependencyMismatch {
            transition_id: t.identity.clone(),
            place: p.clone(),
        })
}

/// Validate a declared typed mapping in the contract's precedence order.
pub fn validate(input: &SolverInput) -> Option<InvalidReason> {
    if let Some(reason) = check_input_place_membership(input) {
        return Some(reason);
    }
    if let Some(reason) = check_duplicate_transition_identity(input) {
        return Some(reason);
    }
    if let Some(reason) = check_binding_coverage(input) {
        return Some(reason);
    }
    if let Some(reason) = input
        .bindings
        .iter()
        .find_map(|b| check_binding_structure(input, b))
    {
        return Some(reason);
    }
    if let Some(reason) = input
        .bindings
        .iter()
        .find_map(|b| check_binding_revision(input, b))
    {
        return Some(reason);
    }
    if let Some(reason) = check_graph_places(input) {
        return Some(reason);
    }
    if let Some(reason) = check_graph_transitions(input) {
        return Some(reason);
    }
    if let Some(reason) = check_graph_edges(input) {
        return Some(reason);
    }
    check_branch_places(input)
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

/// Whether a marking carries enough matching, correctly-revisioned
/// tokens to satisfy one binding.
pub fn binding_satisfied_at(m: &Marking, b: &InputBinding) -> bool {
    let matching = tokens_at(m, &b.place)
        .iter()
        .filter(|t| t.target == b.identity && t.revision == b.required_revision)
        .count();
    b.multiplicity <= Nat::from(matching)
}

/// Whether every one of a transition's declared bindings is satisfied
/// at a marking.
pub fn transition_enabled_at(bindings: &[InputBinding], m: &Marking) -> bool {
    bindings.iter().all(|b| binding_satisfied_at(m, b))
}

/// The candidate input bindings enumerated while scanning the declared
/// transitions for enabledness at a marking: every declared binding of
/// every declared transition is a candidate the solver must consider.
pub fn candidate_binding_count(input: &SolverInput) -> Nat {
    input.transitions.iter().fold(Nat::from(0u8), |acc, t| {
        acc + Nat::from(bindings_for(input, &t.identity).len())
    })
}

/// Whether binding enumeration exceeds the declared bound
/// `max_bindings`; operations then report
/// `Unknown(BindingBoundExhausted(_))`.
pub fn binding_bound_exceeded(input: &SolverInput) -> bool {
    input.bound.max_bindings < candidate_binding_count(input)
}

/// Derive the finite set of binding-carrying transitions enabled by
/// `input.marking`, after validating the declaration.
pub fn derive_enabled(input: &SolverInput) -> Result<EnabledResult, SolverFailure> {
    if let Some(reason) = validate(input) {
        return Ok(EnabledResult::Invalid(reason));
    }
    let enabled = input
        .transitions
        .iter()
        .filter_map(|t| {
            let bs = bindings_for(input, &t.identity);
            if transition_enabled_at(&bs, &input.marking) {
                Some(EnabledTransition {
                    transition_id: t.identity.clone(),
                    bindings: bs,
                })
            } else {
                None
            }
        })
        .collect();
    Ok(EnabledResult::EnabledSet(EnabledSet { enabled }))
}

fn select_matching(tokens: &[ColoredToken], b: &InputBinding) -> Vec<ColoredToken> {
    let mut selected = Vec::new();
    for t in tokens
        .iter()
        .filter(|t| t.target == b.identity && t.revision == b.required_revision)
    {
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

/// Remove exactly the occurrences in `to_remove` from `tokens`:
/// multiset subtraction preserving duplicates beyond the selected count.
pub fn remove_all_tokens(tokens: &[ColoredToken], to_remove: &[ColoredToken]) -> Vec<ColoredToken> {
    let mut acc = tokens.to_vec();
    for t in to_remove {
        if let Some(pos) = acc.iter().position(|u| u == t) {
            acc.remove(pos);
        }
    }
    acc
}

/// Apply the consume side of one declared branch: every place keeps its
/// tokens except the occurrences its transition's `Consume` bindings
/// selected.
pub fn apply_consumption(m: &Marking, bindings: &[InputBinding]) -> Marking {
    Marking {
        places: m
            .places
            .iter()
            .map(|(place, ts)| {
                (
                    place.clone(),
                    remove_all_tokens(ts, &consumed_at(bindings, m, place)),
                )
            })
            .collect(),
    }
}

fn add_token(m: &Marking, place: &str, tok: &ColoredToken) -> Marking {
    if m.places.iter().any(|(p, _)| p == place) {
        Marking {
            places: m
                .places
                .iter()
                .map(|(p, ts)| {
                    if p == place {
                        let mut ts2 = Vec::with_capacity(ts.len() + 1);
                        ts2.push(tok.clone());
                        ts2.extend(ts.iter().cloned());
                        (p.clone(), ts2)
                    } else {
                        (p.clone(), ts.clone())
                    }
                })
                .collect(),
        }
    } else {
        let mut places = m.places.clone();
        places.push((place.to_string(), vec![tok.clone()]));
        Marking { places }
    }
}

fn add_tokens(m: &Marking, places: &[String], tok: &ColoredToken) -> Marking {
    let mut acc = m.clone();
    for place in places {
        acc = add_token(&acc, place, tok);
    }
    acc
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

/// Atomically apply one declared result branch: consume bindings
/// remove their tokens, read bindings retain theirs and every declared
/// output place gains the produced token. Nothing is promoted to an observation.
pub fn apply_branch_at(m: &Marking, t: &TypedTransition, bindings: &[InputBinding]) -> Marking {
    add_tokens(
        &apply_consumption(m, bindings),
        &t.output_places,
        &produced_token(t),
    )
}

/// Every token surviving consumption at a place was already present
/// there; consumption never invents or mutates a token's color.
pub fn check_token_color_preserved(before: &[ColoredToken], after: &[ColoredToken]) -> bool {
    after.iter().all(|t| before.contains(t))
}

/// Multiset atomicity of consumption: retained count equals prior
/// count minus consumed count per token identity. Unselected
/// structurally equal duplicates remain.
pub fn check_read_consume_atomicity(
    before: &[ColoredToken],
    consumed: &[ColoredToken],
    retained: &[ColoredToken],
) -> bool {
    let count =
        |ts: &[ColoredToken], t: &ColoredToken| Nat::from(ts.iter().filter(|u| *u == t).count());
    before
        .iter()
        .chain(consumed.iter())
        .chain(retained.iter())
        .all(|t| {
            let diff = if count(consumed, t) <= count(before, t) {
                count(before, t) - count(consumed, t)
            } else {
                Nat::from(0u8)
            };
            count(retained, t) == diff
        })
}

/// Deadlock and goal satisfaction never hold at the same marking.
pub fn check_deadlock_goal_separation(goal_holds: bool, deadlocked: bool) -> bool {
    !(goal_holds && deadlocked)
}

/// `Unreachable` may only be reported together with a fully-explored
/// (non-bound-exhausted) closure.
pub fn check_closure_required_for_unreachable(
    closure_complete: bool,
    reported_unreachable: bool,
) -> bool {
    !reported_unreachable || closure_complete
}

/// The solver never produces an acceptance or observation value: no
/// closed result constructor carries one, witnessed structurally.
pub fn solver_produces_no_acceptance() -> bool {
    true
}
