// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}

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

/// The closed result of the enabled-transition derivation.
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

type Index {
  Index(
    place_types: Dict(String, String),
    transitions: Dict(String, TypedTransition),
    transition_inputs: Dict(String, Set(String)),
    binding_pairs: Set(#(String, String)),
    binding_names: Dict(#(String, String), Int),
    graph_places: Set(String),
    graph_transitions: Set(String),
    tokens_by_target: Dict(#(String, String), List(ColoredToken)),
  )
}

fn insert_first(entries: Dict(key, value), key: key, value: value) {
  case dict.has_key(entries, key) {
    True -> entries
    False -> dict.insert(entries, key, value)
  }
}

fn index_of(input: SolverInput) -> Index {
  let transitions =
    list.fold(input.transitions, dict.new(), fn(entries, t) {
      insert_first(entries, t.identity, t)
    })
  Index(
    place_types: list.fold(input.places, dict.new(), fn(entries, p) {
      insert_first(entries, p.identity, p.token_type)
    }),
    transitions: transitions,
    transition_inputs: dict.map_values(transitions, fn(_, t) {
      set.from_list(t.input_places)
    }),
    binding_pairs: list.fold(input.bindings, set.new(), fn(pairs, b) {
      set.insert(pairs, #(b.transition_id, b.place))
    }),
    binding_names: list.fold(input.bindings, dict.new(), fn(counts, b) {
      dict.upsert(counts, #(b.transition_id, b.name), fn(existing) {
        option.unwrap(existing, 0) + 1
      })
    }),
    graph_places: set.from_list(input.graph.places),
    graph_transitions: set.from_list(input.graph.transitions),
    tokens_by_target: tokens_by_target(input.marking),
  )
}

fn tokens_by_target(
  marking: Marking,
) -> Dict(#(String, String), List(ColoredToken)) {
  let #(_, reversed) =
    list.fold(marking.places, #(set.new(), dict.new()), fn(state, entry) {
      let #(seen, collected) = state
      case set.contains(seen, entry.0) {
        True -> state
        False -> #(
          set.insert(seen, entry.0),
          list.fold(entry.1, collected, fn(collected, token) {
            dict.upsert(collected, #(entry.0, token.target), fn(existing) {
              [token, ..option.unwrap(existing, [])]
            })
          }),
        )
      }
    })
  dict.map_values(reversed, fn(_, tokens) { list.reverse(tokens) })
}

fn place_exists(index: Index, id: String) -> Bool {
  dict.has_key(index.place_types, id)
}

fn transition_exists(index: Index, id: String) -> Bool {
  dict.has_key(index.transitions, id)
}

fn check_transition_input_places(
  index: Index,
  t: TypedTransition,
) -> Result(Nil, InvalidReason) {
  first_error(t.input_places, fn(place) {
    case place_exists(index, place) {
      True -> Ok(Nil)
      False -> Error(UnknownInputPlace(t.identity, place))
    }
  })
}

fn duplicate_transition_identity(
  transitions: List(TypedTransition),
) -> Option(String) {
  list.fold(list.reverse(transitions), #(set.new(), None), fn(found, t) {
    let #(later, duplicate) = found
    #(set.insert(later, t.identity), case set.contains(later, t.identity) {
      True -> Some(t.identity)
      False -> duplicate
    })
  }).1
}

fn check_duplicate_transition_identity(
  input: SolverInput,
) -> Result(Nil, InvalidReason) {
  case duplicate_transition_identity(input.transitions) {
    Some(identity) -> Error(DuplicateTransitionIdentity(identity))
    None -> Ok(Nil)
  }
}

fn check_transition_input_bindings(
  index: Index,
  t: TypedTransition,
) -> Result(Nil, InvalidReason) {
  first_error(t.input_places, fn(place) {
    case set.contains(index.binding_pairs, #(t.identity, place)) {
      True -> Ok(Nil)
      False -> Error(MissingInputBinding(t.identity, place))
    }
  })
}

fn check_binding_structure(
  index: Index,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case transition_exists(index, b.transition_id) {
    False -> Error(UnknownTransition(b.transition_id))
    True ->
      case place_exists(index, b.place) {
        False -> Error(UnknownPlace(b.place))
        True -> check_binding_dependency(index, b)
      }
  }
}

fn check_binding_dependency(
  index: Index,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case dict.get(index.transition_inputs, b.transition_id) {
    Error(_) -> Error(UnknownTransition(b.transition_id))
    Ok(input_places) ->
      case set.contains(input_places, b.place) {
        False -> Error(DependencyMismatch(b.transition_id, b.place))
        True -> check_binding_type(index, b)
      }
  }
}

fn check_binding_type(
  index: Index,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  case dict.get(index.place_types, b.place) {
    Error(_) -> Error(UnknownPlace(b.place))
    Ok(ty) ->
      case ty != b.token_type {
        True -> Error(TypeMismatch(b.place, b.token_type, ty))
        False ->
          case b.multiplicity == 0 {
            True -> Error(MultiplicityMismatch(b.transition_id, b.name, 1, 0))
            False ->
              case dict.get(index.binding_names, #(b.transition_id, b.name)) {
                Ok(count) if count > 1 ->
                  Error(IdentityMismatch(b.transition_id, b.name))
                _ -> Ok(Nil)
              }
          }
      }
  }
}

fn check_binding_revision(
  index: Index,
  b: InputBinding,
) -> Result(Nil, InvalidReason) {
  let tokens =
    dict.get(index.tokens_by_target, #(b.place, b.identity))
    |> result.unwrap([])
  case list.find(tokens, fn(t) { t.revision != b.required_revision }) {
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

fn check_graph_places(
  input: SolverInput,
  index: Index,
) -> Result(Nil, InvalidReason) {
  case list.find(input.graph.places, fn(p) { !place_exists(index, p) }) {
    Ok(p) -> Error(UnknownPlace(p))
    Error(_) -> Ok(Nil)
  }
}

fn check_graph_transitions(
  input: SolverInput,
  index: Index,
) -> Result(Nil, InvalidReason) {
  case
    list.find(input.graph.transitions, fn(t) { !transition_exists(index, t) })
  {
    Ok(t) -> Error(UnknownTransition(t))
    Error(_) -> Ok(Nil)
  }
}

fn is_graph_node(index: Index, id: String) -> Bool {
  set.contains(index.graph_places, id)
  || set.contains(index.graph_transitions, id)
}

fn check_graph_edges(
  input: SolverInput,
  index: Index,
) -> Result(Nil, InvalidReason) {
  case
    list.find(input.graph.edges, fn(e) {
      !is_graph_node(index, e.0) || !is_graph_node(index, e.1)
    })
  {
    Ok(e) -> Error(DependencyMismatch(e.0, e.1))
    Error(_) -> Ok(Nil)
  }
}

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

fn check_branch_places(
  input: SolverInput,
  index: Index,
) -> Result(Nil, InvalidReason) {
  first_error(input.transitions, fn(t) {
    first_error(list.append(t.output_places, t.failure_places), fn(p) {
      case place_exists(index, p) {
        True -> Ok(Nil)
        False -> Error(DependencyMismatch(t.identity, p))
      }
    })
  })
}

pub fn validate(input: SolverInput) -> Result(Nil, InvalidReason) {
  validate_with(input, index_of(input))
}

fn validate_with(
  input: SolverInput,
  index: Index,
) -> Result(Nil, InvalidReason) {
  use _ <- result.try(
    first_error(input.transitions, fn(t) {
      check_transition_input_places(index, t)
    }),
  )
  use _ <- result.try(check_duplicate_transition_identity(input))
  use _ <- result.try(
    first_error(input.transitions, fn(t) {
      check_transition_input_bindings(index, t)
    }),
  )
  use _ <- result.try(
    first_error(input.bindings, fn(b) { check_binding_structure(index, b) }),
  )
  use _ <- result.try(
    first_error(input.bindings, fn(b) { check_binding_revision(index, b) }),
  )
  use _ <- result.try(check_graph_places(input, index))
  use _ <- result.try(check_graph_transitions(input, index))
  use _ <- result.try(check_graph_edges(input, index))
  check_branch_places(input, index)
}

/// The declared input bindings of one transition.
pub fn bindings_for(
  input: SolverInput,
  transition_id: String,
) -> List(InputBinding) {
  list.filter(input.bindings, fn(b) { b.transition_id == transition_id })
}

fn token_counts(marking: Marking) -> Dict(#(String, String, Int), Int) {
  let #(_, counts) =
    list.fold(marking.places, #(set.new(), dict.new()), fn(state, entry) {
      let #(seen, counts) = state
      case set.contains(seen, entry.0) {
        True -> state
        False -> #(
          set.insert(seen, entry.0),
          list.fold(entry.1, counts, fn(counts, token) {
            dict.upsert(
              counts,
              #(entry.0, token.target, token.revision),
              fn(existing) { option.unwrap(existing, 0) + 1 },
            )
          }),
        )
      }
    })
  counts
}

fn binding_counted(
  counts: Dict(#(String, String, Int), Int),
  b: InputBinding,
) -> Bool {
  b.multiplicity
  <= result.unwrap(
    dict.get(counts, #(b.place, b.identity, b.required_revision)),
    0,
  )
}

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

fn bindings_by_transition(
  bindings: List(InputBinding),
) -> Dict(String, List(InputBinding)) {
  list.fold(list.reverse(bindings), dict.new(), fn(grouped, b) {
    dict.upsert(grouped, b.transition_id, fn(existing) {
      [b, ..option.unwrap(existing, [])]
    })
  })
}

fn bindings_of(
  grouped: Dict(String, List(InputBinding)),
  transition_id: String,
) -> List(InputBinding) {
  result.unwrap(dict.get(grouped, transition_id), [])
}

fn candidate_binding_count(input: SolverInput) -> Int {
  let grouped = bindings_by_transition(input.bindings)
  list.fold(input.transitions, 0, fn(acc, t) {
    acc + list.length(bindings_of(grouped, t.identity))
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
      let grouped = bindings_by_transition(input.bindings)
      let counts = token_counts(input.marking)
      let enabled =
        list.filter_map(input.transitions, fn(t) {
          let bs = bindings_of(grouped, t.identity)
          case list.all(bs, binding_counted(counts, _)) {
            True ->
              Ok(EnabledTransition(transition_id: t.identity, bindings: bs))
            False -> Error(Nil)
          }
        })
      Enabled(EnabledSet(enabled))
    }
  }
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

fn subtract_tokens(
  tokens: List(ColoredToken),
  to_remove: List(ColoredToken),
) -> List(ColoredToken) {
  let pending =
    list.fold(to_remove, dict.new(), fn(counts, token) {
      dict.upsert(counts, token, fn(existing) { option.unwrap(existing, 0) + 1 })
    })
  list.fold(tokens, #(pending, []), fn(state, token) {
    let #(pending, kept) = state
    case dict.get(pending, token) {
      Ok(count) if count > 0 -> #(dict.insert(pending, token, count - 1), kept)
      _ -> #(pending, [token, ..kept])
    }
  }).1
  |> list.reverse
}

fn apply_consumption(
  marking: Marking,
  bindings: List(InputBinding),
) -> Marking {
  let consuming =
    list.fold(list.reverse(bindings), dict.new(), fn(grouped, b) {
      case b.mode {
        Consume ->
          dict.upsert(grouped, b.place, fn(existing) {
            [b, ..option.unwrap(existing, [])]
          })
        Read -> grouped
      }
    })
  let first_tokens =
    list.fold(marking.places, dict.new(), fn(entries, p) {
      insert_first(entries, p.0, p.1)
    })
  Marking(
    places: list.map(marking.places, fn(p) {
      case dict.get(consuming, p.0) {
        Error(_) -> p
        Ok(place_bindings) -> {
          let tokens = result.unwrap(dict.get(first_tokens, p.0), [])
          let consumed =
            list.fold(place_bindings, [], fn(acc, b) {
              list.append(acc, select_matching(tokens, b))
            })
          #(p.0, subtract_tokens(p.1, consumed))
        }
      }
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

pub fn step_at(
  input: SolverInput,
  marking: Marking,
  transition_id: String,
) -> Option(Marking) {
  step_with(
    transitions_by_identity(input.transitions),
    bindings_by_transition(input.bindings),
    marking,
    transition_id,
  )
}

fn transitions_by_identity(
  transitions: List(TypedTransition),
) -> Dict(String, TypedTransition) {
  list.fold(transitions, dict.new(), fn(entries, t) {
    insert_first(entries, t.identity, t)
  })
}

fn step_with(
  transitions: Dict(String, TypedTransition),
  grouped: Dict(String, List(InputBinding)),
  marking: Marking,
  transition_id: String,
) -> Option(Marking) {
  case dict.get(transitions, transition_id) {
    Error(_) -> None
    Ok(t) -> {
      let bs = bindings_of(grouped, transition_id)
      case transition_enabled_at(bs, marking) {
        True -> Some(apply_branch_at(marking, t, bs))
        False -> None
      }
    }
  }
}

pub fn path_replay(
  input: SolverInput,
  start: Marking,
  path: List(String),
) -> Option(Marking) {
  replay(
    transitions_by_identity(input.transitions),
    bindings_by_transition(input.bindings),
    start,
    path,
  )
}

fn replay(
  transitions: Dict(String, TypedTransition),
  grouped: Dict(String, List(InputBinding)),
  marking: Marking,
  path: List(String),
) -> Option(Marking) {
  case path {
    [] -> Some(marking)
    [transition_id, ..rest] ->
      case step_with(transitions, grouped, marking, transition_id) {
        None -> None
        Some(next) -> replay(transitions, grouped, next, rest)
      }
  }
}
