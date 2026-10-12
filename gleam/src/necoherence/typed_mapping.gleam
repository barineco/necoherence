// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/result

/// What role a token plays at the point it is carried.
pub type TokenKind {
  TokenInput
  TokenOutput
  TokenFailure
  TokenEffect
  TokenObservation
  TokenAccepted
}

/// A colored token: the resource it belongs to, its declared position,
/// its revision, and its kind.
pub type ColoredToken {
  ColoredToken(target: String, index: Int, revision: Int, kind: TokenKind)
}

/// A declared typed place: its identity, the token type it carries, and its
/// revision.
pub type TypedPlace {
  TypedPlace(identity: String, token_type: String, revision: Int)
}

/// A declared typed transition: its identity, declared input, output and
/// failure places, and its revision.
pub type TypedTransition {
  TypedTransition(
    identity: String,
    input_places: List(String),
    output_places: List(String),
    failure_places: List(String),
    revision: Int,
  )
}

/// Whether an input binding retains its matched tokens (`Read`) or removes
/// them (`Consume`) when its transition's branch is applied.
pub type BindingMode {
  Read
  Consume
}

/// One declared input binding for one transition: the place it reads from,
/// the type and identity it requires, and the revision every matched token
/// must carry.
pub type InputBinding {
  InputBinding(
    transition_id: String,
    name: String,
    place: String,
    token_type: String,
    identity: String,
    provenance: String,
    multiplicity: Int,
    mode: BindingMode,
    required_revision: Int,
  )
}

/// The dependency graph over declared places and transitions.
pub type DeclarationGraph {
  DeclarationGraph(
    places: List(String),
    transitions: List(String),
    edges: List(#(String, String)),
    revision: Int,
  )
}

/// The finite domain and search bound: how many binding-carrying
/// transitions and how many search steps the solver may explore.
pub type DomainBound {
  DomainBound(
    target_identity: String,
    index: Int,
    revision: Int,
    max_bindings: Int,
    max_search_steps: Int,
  )
}

/// A marking: for each place, the multiset (as a list) of tokens it
/// carries.
pub type Marking {
  Marking(places: List(#(String, List(ColoredToken))))
}

/// A finite, decidable predicate over a marking: which place must carry how
/// many tokens, or which exact token, combined by `GoalAnd`/`GoalOr`/
/// `GoalNot`.
pub type GoalPredicate {
  PlaceHasAtLeast(place: String, count: Int)
  PlaceHasToken(place: String, target: String, index: Int, revision: Int)
  GoalAnd(a: GoalPredicate, b: GoalPredicate)
  GoalOr(a: GoalPredicate, b: GoalPredicate)
  GoalNot(a: GoalPredicate)
}

/// The complete, closed input to every solver operation.
pub type SolverInput {
  SolverInput(
    places: List(TypedPlace),
    transitions: List(TypedTransition),
    bindings: List(InputBinding),
    goal: GoalPredicate,
    graph: DeclarationGraph,
    marking: Marking,
    bound: DomainBound,
  )
}

/// Why a declared typed mapping is invalid.
pub type InvalidReason {
  UnknownPlace(place: String)
  UnknownTransition(transition_id: String)
  UnknownInputPlace(transition_id: String, place: String)
  MissingInputBinding(transition_id: String, place: String)
  DuplicateTransitionIdentity(identity: String)
  TypeMismatch(place: String, expected: String, actual: String)
  MultiplicityMismatch(
    transition_id: String,
    name: String,
    expected: Int,
    actual: Int,
  )
  RevisionMismatch(
    transition_id: String,
    name: String,
    expected: Int,
    actual: Int,
  )
  IdentityMismatch(transition_id: String, name: String)
  DependencyMismatch(transition_id: String, place: String)
}

/// Why a bounded search could not settle a result.
pub type UnknownReason {
  BindingBoundExhausted(limit: Int)
  SearchStepBoundExhausted(limit: Int)
}

/// One enabled transition together with the bindings it was enabled by.
pub type EnabledTransition {
  EnabledTransition(transition_id: String, bindings: List(InputBinding))
}

/// The finite set of binding-carrying transitions enabled by a marking.
pub type EnabledSet {
  EnabledSet(enabled: List(EnabledTransition))
}

/// The closed result of `derive_enabled_set` and `derive_enabled`.
pub type EnabledResult {
  Enabled(EnabledSet)
  EnabledInvalid(InvalidReason)
}

/// The firing sequence and marking that satisfied a goal.
pub type ReachabilityWitness {
  ReachabilityWitness(path: List(String), final_marking: Marking)
}

/// The finite closure a bounded search actually explored, proving no
/// marking in it satisfies the goal.
pub type ClosureWitness {
  ClosureWitness(
    explored_markings: List(Marking),
    steps: Int,
    frontier: List(Marking),
  )
}

/// The closed result of deciding whether a marking satisfying the goal is
/// reachable: `Reachable` carries the firing sequence that reaches one,
/// `Unreachable` carries the explored closure containing none, and
/// `ReachabilityUnknown` and `ReachabilityInvalid` carry why the bounded
/// search could not settle it or why the declared mapping is invalid.
pub type ReachabilityResult {
  Reachable(ReachabilityWitness)
  Unreachable(ClosureWitness)
  ReachabilityUnknown(UnknownReason)
  ReachabilityInvalid(InvalidReason)
}

/// The marking a deadlock was observed at.
pub type DeadlockWitness {
  DeadlockWitness(marking: Marking)
}

/// The closed result of deciding whether a marking is a deadlock:
/// `Deadlocked` carries the marking observed with nothing enabled,
/// `NotDeadlocked` carries the set of enabled transitions, and
/// `DeadlockUnknown` and `DeadlockInvalid` carry why the bounded search could
/// not settle it or why the declared mapping is invalid.
pub type DeadlockResult {
  Deadlocked(DeadlockWitness)
  NotDeadlocked(EnabledSet)
  DeadlockUnknown(UnknownReason)
  DeadlockInvalid(InvalidReason)
}

pub type CycleWitness {
  CycleWitness(
    prefix_path: List(String),
    cycle_path: List(String),
    cycle_start: Marking,
    cycle_end: Marking,
    measure_decreasing: Bool,
  )
}

pub type AcyclicWitness {
  AcyclicWitness(
    explored_markings: List(Marking),
    steps: Int,
    frontier: List(Marking),
  )
}

/// The closed result of deciding whether the firing relation is well-founded:
/// `WellFounded` carries the acyclic closure explored, `NotWellFounded`
/// carries a witnessing cycle, and `WellFoundednessUnknown` and
/// `WellFoundednessInvalid` carry why the bounded search could not settle it
/// or why the declared mapping is invalid.
pub type WellFoundednessResult {
  WellFounded(AcyclicWitness)
  NotWellFounded(CycleWitness)
  WellFoundednessUnknown(UnknownReason)
  WellFoundednessInvalid(InvalidReason)
}

/// A violated host contract or an impossible implementation invariant;
/// never a declaration mismatch, which is always the closed invalid
/// result.
pub type SolverFailure {
  ContractViolation(message: String)
  InternalInvariantViolation(message: String)
}

/// The tokens a marking carries at one place; a place absent from the
/// marking carries none.
pub fn tokens_at(marking: Marking, place: String) -> List(ColoredToken) {
  case list.find(marking.places, fn(p) { p.0 == place }) {
    Ok(#(_, tokens)) -> tokens
    Error(_) -> []
  }
}

/// Evaluate a goal predicate against a marking.
pub fn eval_goal(marking: Marking, goal: GoalPredicate) -> Bool {
  case goal {
    PlaceHasAtLeast(place, count) ->
      count <= list.length(tokens_at(marking, place))
    PlaceHasToken(place, target, index, revision) ->
      list.any(tokens_at(marking, place), fn(t) {
        t.target == target && t.index == index && t.revision == revision
      })
    GoalAnd(a, b) -> eval_goal(marking, a) && eval_goal(marking, b)
    GoalOr(a, b) -> eval_goal(marking, a) || eval_goal(marking, b)
    GoalNot(a) -> !eval_goal(marking, a)
  }
}

fn place_exists(places: List(TypedPlace), id: String) -> Bool {
  list.any(places, fn(p) { p.identity == id })
}

fn place_type(places: List(TypedPlace), id: String) -> Result(String, Nil) {
  case list.find(places, fn(p) { p.identity == id }) {
    Ok(p) -> Ok(p.token_type)
    Error(_) -> Error(Nil)
  }
}

fn transition_exists(transitions: List(TypedTransition), id: String) -> Bool {
  list.any(transitions, fn(t) { t.identity == id })
}

fn transition_identity_count(
  transitions: List(TypedTransition),
  identity: String,
) -> Int {
  transitions
  |> list.filter(fn(t) { t.identity == identity })
  |> list.length
}

fn check_transition_input_places(
  input: SolverInput,
  t: TypedTransition,
) -> Result(Nil, InvalidReason) {
  first_error(t.input_places, fn(place) {
    case place_exists(input.places, place) {
      True -> Ok(Nil)
      False -> Error(UnknownInputPlace(t.identity, place))
    }
  })
}

fn check_transition_identity(
  input: SolverInput,
  t: TypedTransition,
) -> Result(Nil, InvalidReason) {
  case transition_identity_count(input.transitions, t.identity) > 1 {
    True -> Error(DuplicateTransitionIdentity(t.identity))
    False -> Ok(Nil)
  }
}

fn has_binding_for(
  input: SolverInput,
  transition_id: String,
  place: String,
) -> Bool {
  list.any(input.bindings, fn(b) {
    b.transition_id == transition_id && b.place == place
  })
}

fn check_transition_input_bindings(
  input: SolverInput,
  t: TypedTransition,
) -> Result(Nil, InvalidReason) {
  first_error(t.input_places, fn(place) {
    case has_binding_for(input, t.identity, place) {
      True -> Ok(Nil)
      False -> Error(MissingInputBinding(t.identity, place))
    }
  })
}

fn find_transition(
  transitions: List(TypedTransition),
  id: String,
) -> Result(TypedTransition, Nil) {
  list.find(transitions, fn(t) { t.identity == id })
}

fn duplicate_binding_name(input: SolverInput, b: InputBinding) -> Bool {
  let count =
    input.bindings
    |> list.filter(fn(b2) {
      b2.transition_id == b.transition_id && b2.name == b.name
    })
    |> list.length
  1 < count
}

/// Structural validity of one binding: declared transition and place,
/// input-place membership, declared type, positive multiplicity and no
/// duplicate name within the transition.
fn check_binding_structure(
  input: SolverInput,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case transition_exists(input.transitions, b.transition_id) {
    False -> Error(UnknownTransition(b.transition_id))
    True ->
      case place_exists(input.places, b.place) {
        False -> Error(UnknownPlace(b.place))
        True -> check_binding_dependency(input, b)
      }
  }
}

fn check_binding_dependency(
  input: SolverInput,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case find_transition(input.transitions, b.transition_id) {
    Error(_) -> Error(UnknownTransition(b.transition_id))
    Ok(t) ->
      case list.contains(t.input_places, b.place) {
        False -> Error(DependencyMismatch(b.transition_id, b.place))
        True -> check_binding_type(input, b)
      }
  }
}

fn check_binding_type(
  input: SolverInput,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case place_type(input.places, b.place) {
    Error(_) -> Error(UnknownPlace(b.place))
    Ok(ty) ->
      case ty != b.token_type {
        True -> Error(TypeMismatch(b.place, b.token_type, ty))
        False ->
          case b.multiplicity == 0 {
            True -> Error(MultiplicityMismatch(b.transition_id, b.name, 1, 0))
            False ->
              case duplicate_binding_name(input, b) {
                True -> Error(IdentityMismatch(b.transition_id, b.name))
                False -> Ok(Nil)
              }
          }
      }
  }
}

/// A token present at a binding's place, sharing the binding's target
/// identity, whose revision differs from the binding's declared required
/// revision is a colored-token mismatch.
fn check_binding_revision(
  input: SolverInput,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case
    list.find(tokens_at(input.marking, b.place), fn(t) {
      t.target == b.identity && t.revision != b.required_revision
    })
  {
    Ok(t) ->
      Error(RevisionMismatch(
        b.transition_id,
        b.name,
        b.required_revision,
        t.revision,
      ))
    Error(_) -> Ok(Nil)
  }
}

fn check_graph_places(input: SolverInput) -> Result(Nil, InvalidReason) {
  case list.find(input.graph.places, fn(p) { !place_exists(input.places, p) }) {
    Ok(p) -> Error(UnknownPlace(p))
    Error(_) -> Ok(Nil)
  }
}

fn check_graph_transitions(input: SolverInput) -> Result(Nil, InvalidReason) {
  case
    list.find(input.graph.transitions, fn(t) {
      !transition_exists(input.transitions, t)
    })
  {
    Ok(t) -> Error(UnknownTransition(t))
    Error(_) -> Ok(Nil)
  }
}

/// An edge endpoint is valid when it names a declared place or a declared
/// transition of the dependency graph.
fn is_graph_node(input: SolverInput, id: String) -> Bool {
  list.contains(input.graph.places, id)
  || list.contains(input.graph.transitions, id)
}

fn check_graph_edges(input: SolverInput) -> Result(Nil, InvalidReason) {
  case
    list.find(input.graph.edges, fn(e) {
      !is_graph_node(input, e.0) || !is_graph_node(input, e.1)
    })
  {
    Ok(e) -> Error(DependencyMismatch(e.0, e.1))
    Error(_) -> Ok(Nil)
  }
}

/// The first Error produced by check over items; `Ok(Nil)` when every
/// item passes.
fn first_error(
  items: List(a),
  check: fn(a) -> Result(Nil, InvalidReason),
) -> Result(Nil, InvalidReason) {
  case items {
    [] -> Ok(Nil)
    [x, ..rest] ->
      case check(x) {
        Error(reason) -> Error(reason)
        Ok(_) -> first_error(rest, check)
      }
  }
}

/// Every output place and failure place a transition declares must belong
/// to the declared place set; a branch place outside it would let
/// `apply_branch_at` mint markings outside the declared finite domain.
fn check_branch_places(input: SolverInput) -> Result(Nil, InvalidReason) {
  first_error(input.transitions, fn(t) {
    first_error(list.append(t.output_places, t.failure_places), fn(p) {
      case place_exists(input.places, p) {
        True -> Ok(Nil)
        False -> Error(DependencyMismatch(t.identity, p))
      }
    })
  })
}

pub fn validate(input: SolverInput) -> Result(Nil, InvalidReason) {
  use _ <- result.try(
    first_error(input.transitions, fn(t) {
      check_transition_input_places(input, t)
    }),
  )
  use _ <- result.try(
    first_error(input.transitions, fn(t) { check_transition_identity(input, t) }),
  )
  use _ <- result.try(
    first_error(input.transitions, fn(t) {
      check_transition_input_bindings(input, t)
    }),
  )
  use _ <- result.try(
    first_error(input.bindings, fn(b) { check_binding_structure(input, b) }),
  )
  use _ <- result.try(
    first_error(input.bindings, fn(b) { check_binding_revision(input, b) }),
  )
  use _ <- result.try(check_graph_places(input))
  use _ <- result.try(check_graph_transitions(input))
  use _ <- result.try(check_graph_edges(input))
  check_branch_places(input)
}

/// The declared input bindings of one transition.
pub fn bindings_for(
  input: SolverInput,
  transition_id: String,
) -> List(InputBinding) {
  list.filter(input.bindings, fn(b) { b.transition_id == transition_id })
}

/// Whether a marking carries enough matching, correctly-revisioned tokens
/// to satisfy one binding.
fn binding_satisfied_at(marking: Marking, b: InputBinding) -> Bool {
  let matching =
    tokens_at(marking, b.place)
    |> list.filter(fn(t) {
      t.target == b.identity && t.revision == b.required_revision
    })
  b.multiplicity <= list.length(matching)
}

/// Whether every one of a transition's declared bindings is satisfied at a
/// marking.
pub fn transition_enabled_at(
  bindings: List(InputBinding),
  marking: Marking,
) -> Bool {
  list.all(bindings, binding_satisfied_at(marking, _))
}

/// The candidate input bindings enumerated while scanning the declared
/// transitions for enabledness at a marking: every declared binding of
/// every declared transition is a candidate the solver must consider.
fn candidate_binding_count(input: SolverInput) -> Int {
  list.fold(input.transitions, 0, fn(acc, t) {
    acc + list.length(bindings_for(input, t.identity))
  })
}

/// Whether binding enumeration exceeds the declared bound
/// `max_bindings`; operations then report
/// `Unknown(BindingBoundExhausted(_))`.
pub fn binding_bound_exceeded(input: SolverInput) -> Bool {
  input.bound.max_bindings < candidate_binding_count(input)
}

/// Derive the finite set of binding-carrying transitions enabled by
/// `input.marking`, after validating the declaration.
pub fn derive_enabled_set(input: SolverInput) -> EnabledResult {
  case validate(input) {
    Error(reason) -> EnabledInvalid(reason)
    Ok(_) -> {
      let enabled =
        list.filter_map(input.transitions, fn(t) {
          let bs = bindings_for(input, t.identity)
          case transition_enabled_at(bs, input.marking) {
            True ->
              Ok(EnabledTransition(transition_id: t.identity, bindings: bs))
            False -> Error(Nil)
          }
        })
      Enabled(EnabledSet(enabled))
    }
  }
}

fn select_matching(
  tokens: List(ColoredToken),
  b: InputBinding,
) -> List(ColoredToken) {
  tokens
  |> list.filter(fn(t) {
    t.target == b.identity && t.revision == b.required_revision
  })
  |> list.take(b.multiplicity)
}

/// The tokens one transition's `Consume` bindings actually remove from one
/// place, given a marking.
fn consumed_at(
  bindings: List(InputBinding),
  marking: Marking,
  place: String,
) -> List(ColoredToken) {
  bindings
  |> list.filter(fn(b) { b.place == place && b.mode == Consume })
  |> list.fold([], fn(acc, b) {
    list.append(acc, select_matching(tokens_at(marking, place), b))
  })
}

/// Remove the first occurrence of `t` from `tokens`; the list itself when
/// `t` does not occur.
fn erase_first(
  tokens: List(ColoredToken),
  t: ColoredToken,
) -> List(ColoredToken) {
  case tokens {
    [] -> []
    [x, ..rest] ->
      case x == t {
        True -> rest
        False -> [x, ..erase_first(rest, t)]
      }
  }
}

/// Remove exactly the occurrences in `to_remove` from `tokens`:
/// multiset subtraction preserving duplicates beyond the selected count.
fn remove_all_tokens(
  tokens: List(ColoredToken),
  to_remove: List(ColoredToken),
) -> List(ColoredToken) {
  list.fold(to_remove, tokens, fn(acc, t) { erase_first(acc, t) })
}

/// Apply the consume side of one declared branch: every place keeps its
/// tokens except the occurrences its transition's `Consume` bindings
/// selected.
fn apply_consumption(
  marking: Marking,
  bindings: List(InputBinding),
) -> Marking {
  Marking(
    places: list.map(marking.places, fn(p) {
      #(p.0, remove_all_tokens(p.1, consumed_at(bindings, marking, p.0)))
    }),
  )
}

fn add_token(marking: Marking, place: String, tok: ColoredToken) -> Marking {
  case list.find(marking.places, fn(p) { p.0 == place }) {
    Ok(_) ->
      Marking(
        places: list.map(marking.places, fn(p) {
          case p.0 == place {
            True -> #(p.0, [tok, ..p.1])
            False -> p
          }
        }),
      )
    Error(_) -> Marking(places: list.append(marking.places, [#(place, [tok])]))
  }
}

fn add_tokens(
  marking: Marking,
  places: List(String),
  tok: ColoredToken,
) -> Marking {
  list.fold(places, marking, fn(acc, place) { add_token(acc, place, tok) })
}

/// The token produced at each of a transition's declared output places:
/// its own identity, index zero, its own revision, kind `TokenOutput`.
fn produced_token(t: TypedTransition) -> ColoredToken {
  ColoredToken(
    target: t.identity,
    index: 0,
    revision: t.revision,
    kind: TokenOutput,
  )
}

/// Atomically apply one declared result branch: consume bindings
/// remove their tokens, read bindings retain theirs and every declared
/// output place gains the produced token. Nothing is promoted to an observation.
pub fn apply_branch_at(
  marking: Marking,
  t: TypedTransition,
  bindings: List(InputBinding),
) -> Marking {
  add_tokens(
    apply_consumption(marking, bindings),
    t.output_places,
    produced_token(t),
  )
}

/// Every token surviving consumption at a place was already present there;
/// consumption never invents or mutates a token's color.
pub fn check_token_color_preserved(
  before: List(ColoredToken),
  after: List(ColoredToken),
) -> Bool {
  list.all(after, fn(t) { list.contains(before, t) })
}

/// The occurrences of `t` in `tokens`: the multiset count of one token
/// identity.
fn count_of(tokens: List(ColoredToken), t: ColoredToken) -> Int {
  list.length(list.filter(tokens, fn(u) { u == t }))
}

/// Multiset atomicity of consumption: retained count equals prior
/// count minus consumed count per token identity. Unselected
/// structurally equal duplicates remain.
pub fn check_read_consume_atomicity(
  before: List(ColoredToken),
  consumed: List(ColoredToken),
  retained: List(ColoredToken),
) -> Bool {
  let universe = list.append(before, list.append(consumed, retained))
  list.all(universe, fn(t) {
    let diff = count_of(before, t) - count_of(consumed, t)
    count_of(retained, t)
    == case diff < 0 {
      True -> 0
      False -> diff
    }
  })
}

/// Deadlock and goal satisfaction never hold at the same marking.
pub fn check_deadlock_goal_separation(
  goal_holds: Bool,
  deadlocked: Bool,
) -> Bool {
  case goal_holds && deadlocked {
    True -> False
    False -> True
  }
}

/// `Unreachable` may only be reported together with a fully-explored
/// (non-bound-exhausted) closure.
pub fn check_closure_required_for_unreachable(
  closure_complete: Bool,
  reported_unreachable: Bool,
) -> Bool {
  !reported_unreachable || closure_complete
}

/// Derive the finite set of binding-carrying transitions enabled by
/// `input.marking`, after validating the declaration. The function
/// is pure and total, with no effects; host
/// failures report on the `Result` error channel.
pub fn derive_enabled(
  input: SolverInput,
) -> Result(EnabledResult, SolverFailure) {
  Ok(derive_enabled_set(input))
}
