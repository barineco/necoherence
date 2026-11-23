// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import necoherence/core
import necoherence/dynamic_admission as admission
import necoherence/exact_json as json
import necoherence/file_effect as files
import necoherence/network_effect as effect
import necoherence/reconcile
import necoherence/semantic_generation_runtime as runtime
import necoherence/request_progression as rp
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/store
import necoherence/typed_mapping as tm

@external(erlang, "gleam_cost_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "gleam_cost_ffi", "count_on")
fn count_on(modules: List(String)) -> Nil

@external(erlang, "gleam_cost_ffi", "count_read")
fn count_read(modules: List(String)) -> Int

pub fn main() {
  case arguments() {
    [operation, count_text, ..] ->
      case int.parse(count_text) {
        Ok(count) -> {
          let #(calls, steps) = counted(operation, count)
          io.println(
            "{\"operation\":\""
            <> operation
            <> "\",\"n\":"
            <> int.to_string(count)
            <> ",\"calls\":"
            <> int.to_string(calls)
            <> ",\"steps\":"
            <> int.to_string(steps)
            <> "}",
          )
        }
        Error(Nil) -> io.println("invalid count")
      }
    _ -> io.println("usage: gleam_cost <operation> <count> <module>...")
  }
}

fn traced() -> List(String) {
  list.drop(arguments(), 2)
}

fn measure(setup: fn() -> state, step: fn(state, Int) -> state, k: Int) -> #(Int, Int) {
  let initial = setup()
  let modules = traced()
  count_on(modules)
  let before = count_read(modules)
  loop(initial, step, 0, k)
  #(count_read(modules) - before, k)
}

fn loop(state: state, step: fn(state, Int) -> state, index: Int, k: Int) -> Nil {
  case index >= k {
    True -> Nil
    False -> loop(step(state, index), step, index + 1, k)
  }
}

fn counted(operation: String, n: Int) -> #(Int, Int) {
  case operation {
    "vc_validate_value" ->
      measure(fn() { value_graph(n) }, vc_validate_value(accepted_value()), n)
    "vc_validate_value_rejected" ->
      measure(fn() { value_graph(n) }, vc_validate_value(rejected_value()), n)
    "vc_select_branch" ->
      measure(
        fn() { declaration_graph(n) },
        vc_select_branch(accepted_selection()),
        n,
      )
    "vc_select_branch_rejected" ->
      measure(
        fn() { declaration_graph(n) },
        vc_select_branch(rejected_selection()),
        n,
      )
    "vc_named_wrapper" ->
      measure(fn() { declaration_graph(n) }, vc_named_wrapper, n)
    "vc_accepts_slot" -> measure(fn() { value_graph(n) }, vc_accepts_slot, n)
    "vc_validate_slot" -> measure(fn() { value_graph(n) }, vc_validate_slot, n)
    "core_lookup" -> measure(fn() { world(n) }, core_lookup(n), n)
    "core_bump" -> measure(fn() { world(n) }, core_bump(n), n)
    "core_apply" -> measure(fn() { world(n) }, core_apply(n), n)
    "core_apply_conflicted" ->
      measure(fn() { world(n) }, core_apply_conflicted(n), n)
    "core_apply_unknown" -> measure(fn() { world(n) }, core_apply_unknown, n)
    "rp_submit_fifo" ->
      measure(fn() { pending_snapshot(rp.Fifo, n) }, rp_submit(n), n)
    "rp_submit_latest_wins" ->
      measure(fn() { pending_snapshot(rp.LatestWins, n) }, rp_submit(n), n)
    "rp_decide_start" ->
      measure(
        fn() { pending_snapshot(rp.AllExecute, 2 * n) },
        shifted(n, rp_decide_start),
        n,
      )
    "rp_decide_start_blocked" ->
      measure(
        fn() { pending_snapshot(rp.Fifo, n) },
        rp_decide_start_blocked(n),
        n,
      )
    "rp_apply_start_observation" ->
      measure(
        fn() { phase_snapshot(rp.Preparing, 2 * n) },
        shifted(n, rp_apply_start_observation),
        n,
      )
    "rp_apply_completion_observation" ->
      measure(
        fn() { phase_snapshot(rp.Publishing, 2 * n) },
        shifted(n, rp_apply_completion_observation),
        n,
      )
    "rp_decide_cancel" ->
      measure(
        fn() { pending_snapshot(rp.AllExecute, 2 * n) },
        shifted(n, rp_decide_cancel),
        n,
      )
    "rp_derive_pending" ->
      measure(fn() { pending_snapshot(rp.AllExecute, n) }, rp_derive(0), n)
    "rp_derive_in_flight" ->
      measure(fn() { phase_snapshot(rp.Preparing, n) }, rp_derive(1), n)
    "rp_derive_concurrent" ->
      measure(fn() { phase_snapshot(rp.Publishing, n) }, rp_derive(2), n)
    "da_admit_submitted" ->
      measure(
        fn() { admission_state(rp.Fifo, rp.Pending, n) },
        da_admit(n, False),
        n,
      )
    "da_admit_executed" ->
      measure(
        fn() { admission_state(rp.AllExecute, rp.Pending, n) },
        da_admit(n, True),
        n,
      )
    "da_elide_admission_provenance" ->
      measure(
        fn() { admission_state(rp.AllExecute, rp.Published, 2 * n) },
        shifted(n, da_elide),
        n,
      )
    "ne_prepare" ->
      measure(fn() { network_state(Prepared, n) }, ne_prepare(n), n)
    "ne_send_command" ->
      measure(
        fn() { network_state(Prepared, 2 * n) },
        shifted(n, ne_send_command),
        n,
      )
    "ne_observe_start" ->
      measure(
        fn() { network_state(Issued, 2 * n) },
        shifted(n, ne_observe_start),
        n,
      )
    "ne_cancel_command" ->
      measure(
        fn() { network_state(Started, 2 * n) },
        shifted(n, ne_cancel_command),
        n,
      )
    "ne_observe_pending" ->
      measure(
        fn() { network_state(Started, 2 * n) },
        shifted(n, ne_observe_pending),
        n,
      )
    "ne_observe_delivered" ->
      measure(
        fn() { network_state(Started, 2 * n) },
        shifted(n, ne_observe_delivered),
        n,
      )
    "ne_observe_late" ->
      measure(
        fn() { network_state(Settled, 2 * n) },
        shifted(n, ne_observe_late),
        n,
      )
    "ne_annotate_effect" ->
      measure(
        fn() { network_state(Settled, 2 * n) },
        shifted(n, ne_annotate_effect),
        n,
      )
    "ne_retry" ->
      measure(fn() { network_state(Settled, 2 * n) }, shifted(n, ne_retry), n)
    "ne_read_network_state" ->
      measure(fn() { network_state(Settled, n) }, ne_read, n)
    "store_observe" -> measure(fn() { store_state(n) }, store_observe(n), n)
    "store_apply" -> measure(fn() { store_state(n) }, store_apply(n), n)
    "file_effect_read" -> measure(fn() { file_held(n) }, file_effect_read(n), n)
    "file_effect_replace" ->
      measure(fn() { file_held(n) }, file_effect_replace(n), n)
    "file_effect_track" ->
      measure(fn() { file_world(n) }, file_effect_track(n), n)
    "reconcile" -> measure(fn() { world(n) }, reconcile_all(n), 3)
    "tm_validate" ->
      per_element(n, fn(input) {
        case tm.validate(input) {
          Ok(Nil) -> 0
          Error(_) -> 1
        }
      })
    "tm_derive_enabled" ->
      per_element(n, fn(input) {
        case tm.derive_enabled_set(input) {
          tm.Enabled(tm.EnabledSet(enabled)) -> list.length(enabled)
          tm.EnabledInvalid(_) -> -1
        }
      })
    "tm_binding_bound" ->
      per_element(n, fn(input) {
        case tm.binding_bound_exceeded(input) {
          True -> 1
          False -> 0
        }
      })
    _ -> #(-1, 1)
  }
}

fn value_source() -> types.SourceRef {
  types.SourceRef("cost", "1", "types.json", "0", "cost", None)
}

fn value_reference(name: String) -> types.TypeRef {
  types.TypeRef(value_source(), name, [name])
}

fn value_node(name: String, shape: types.TypeShape) -> types.TypeNode {
  types.TypeNode(value_reference(name), shape, None, [], [])
}

fn value_graph(n: Int) -> validation.PreparedGraph {
  let profile_reference = types.ProfileRef("cost", "1", "0")
  let occurrence = types.OccurrenceRef(value_source(), [])
  let profile =
    types.SemanticProfile(
      profile_reference,
      [],
      [],
      "",
      types.NumberModel(False),
      None,
      [
        types.FormatBinding(
          "word",
          profile_reference,
          types.Sequence([types.Literal("w"), types.Text]),
        ),
      ],
      None,
      [],
      None,
    )
  let fillers =
    list.map(indices(n), fn(index) {
      value_node(
        "Filler" <> int.to_string(index),
        types.BooleanShape(types.BooleanSpec(None, None)),
      )
    })
  let nodes = [
    value_node("Bool", types.BooleanShape(types.BooleanSpec(None, None))),
    value_node(
      "Word",
      types.StringShape(types.StringSpec(
        Some(types.NamedFormat("word")),
        [],
        None,
        None,
        None,
        [],
        None,
      )),
    ),
    value_node(
      "Pair",
      types.ProductShape(types.ProductSpec(
        [
          types.FieldSpec(
            "a",
            types.SlotContract(value_reference("Bool"), True, False),
            occurrence,
          ),
          types.FieldSpec(
            "s",
            types.SlotContract(value_reference("Word"), True, False),
            occurrence,
          ),
        ],
        types.RejectExtras,
      )),
    ),
    ..fillers
  ]
  validation.prepare(types.SemanticGraph(profile, nodes, [value_source()]))
}

fn declaration_graph(n: Int) -> validation.PreparedGraph {
  let profile_reference = types.ProfileRef("cost", "1", "0")
  let filler_formats =
    list.map(indices(n), fn(index) {
      types.FormatBinding(
        "filler" <> int.to_string(index),
        profile_reference,
        types.Literal("f" <> int.to_string(index)),
      )
    })
  let filler_wrappers =
    list.map(indices(n), fn(index) {
      types.Wrapper(
        "filler" <> int.to_string(index),
        "k" <> int.to_string(index),
        types.WrapperBytes,
      )
    })
  let profile =
    types.SemanticProfile(
      profile_reference,
      [],
      [],
      "",
      types.NumberModel(False),
      None,
      list.append(filler_formats, [
        types.FormatBinding(
          "word",
          profile_reference,
          types.Sequence([types.Literal("w"), types.Text]),
        ),
      ]),
      None,
      list.append(filler_wrappers, [
        types.Wrapper("target", "wrapped", types.WrapperBytes),
      ]),
      None,
    )
  let fillers =
    list.map(indices(n), fn(index) {
      value_node(
        "Filler" <> int.to_string(index),
        types.BooleanShape(types.BooleanSpec(None, None)),
      )
    })
  validation.prepare(types.SemanticGraph(profile, fillers, [value_source()]))
}

fn selection_branches() -> List(#(String, types.BranchSelector)) {
  [#("shape", types.MemberShape([#("s", types.FormatMember("word"))]))]
}

fn accepted_selection() -> json.JsonValue {
  json.JsonValueObj([#("s", json.JsonValueStr("wx"))])
}

fn rejected_selection() -> json.JsonValue {
  json.JsonValueObj([#("s", json.JsonValueStr("zz"))])
}

fn vc_select_branch(
  value: json.JsonValue,
) -> fn(validation.PreparedGraph, Int) -> validation.PreparedGraph {
  fn(prepared, _) {
    let _ = runtime.select_branch(prepared, selection_branches(), value)
    prepared
  }
}

fn vc_named_wrapper(
  prepared: validation.PreparedGraph,
  _: Int,
) -> validation.PreparedGraph {
  let _ = runtime.named_wrapper(prepared, "target")
  prepared
}

fn accepted_value() -> json.JsonValue {
  json.JsonValueObj([
    #("a", json.JsonValueBool(True)),
    #("s", json.JsonValueStr("wx")),
  ])
}

fn rejected_value() -> json.JsonValue {
  json.JsonValueObj([
    #("a", json.JsonValueNum(1)),
    #("s", json.JsonValueStr("wx")),
  ])
}

fn pair_slot() -> types.SlotContract {
  types.SlotContract(value_reference("Pair"), True, False)
}

fn vc_validate_value(
  value: json.JsonValue,
) -> fn(validation.PreparedGraph, Int) -> validation.PreparedGraph {
  fn(prepared, _) {
    let _ =
      validation.validate_value(prepared, value_reference("Pair"), value, None)
    prepared
  }
}

fn vc_accepts_slot(
  prepared: validation.PreparedGraph,
  _: Int,
) -> validation.PreparedGraph {
  let _ =
    validation.accepts_slot(
      prepared,
      pair_slot(),
      types.Present(accepted_value()),
    )
  prepared
}

fn vc_validate_slot(
  prepared: validation.PreparedGraph,
  _: Int,
) -> validation.PreparedGraph {
  let _ =
    validation.validate_slot(
      prepared,
      pair_slot(),
      types.Present(accepted_value()),
    )
  prepared
}

fn typed_input(n: Int) -> tm.SolverInput {
  let names = indices(n)
  tm.SolverInput(
    list.map(names, fn(index) {
      tm.TypedPlace("p" <> int.to_string(index), "a", 1)
    }),
    list.map(names, fn(index) {
      tm.TypedTransition(
        "t" <> int.to_string(index),
        ["p" <> int.to_string(index)],
        ["p" <> int.to_string(index)],
        [],
        1,
      )
    }),
    list.map(names, fn(index) {
      tm.InputBinding(
        "t" <> int.to_string(index),
        "b",
        "p" <> int.to_string(index),
        "a",
        "x",
        "prov",
        1,
        tm.Consume,
        1,
      )
    }),
    tm.PlaceHasAtLeast("p0", 1),
    tm.DeclarationGraph(
      list.map(names, fn(index) { "p" <> int.to_string(index) }),
      list.map(names, fn(index) { "t" <> int.to_string(index) }),
      list.map(names, fn(index) {
        #("p" <> int.to_string(index), "t" <> int.to_string(index))
      }),
      1,
    ),
    tm.Marking(
      list.map(names, fn(index) {
        #("p" <> int.to_string(index), [
          tm.ColoredToken("x", 0, 1, tm.TokenInput),
        ])
      }),
    ),
    tm.DomainBound("x", 0, 1, n * 2, 8),
  )
}

fn per_element(n: Int, run: fn(tm.SolverInput) -> Int) -> #(Int, Int) {
  let input = typed_input(n)
  let modules = traced()
  count_on(modules)
  let before = count_read(modules)
  let _ = run(input)
  let spent = count_read(modules) - before
  #(spent * 1000, n)
}

fn shifted(
  offset: Int,
  step: fn(state, Int) -> state,
) -> fn(state, Int) -> state {
  fn(state, index) { step(state, offset + index) }
}

fn indices(n: Int) -> List(Int) {
  int.range(0, n, [], fn(accumulated, index) { [index, ..accumulated] })
  |> list.reverse
}

fn resource(index: Int) -> core.ResourceId {
  core.resource("k", "r" <> int.to_string(index))
}

fn world(n: Int) -> core.World {
  core.world(
    list.map(indices(n), fn(index) {
      #(resource(index), core.revision(index + 1))
    }),
  )
}

fn core_lookup(n: Int) -> fn(core.World, Int) -> core.World {
  fn(world, _) {
    case core.lookup(world, resource(n - 1)) {
      core.Found(_) -> world
      core.Unknown(_) -> world
    }
  }
}

fn core_bump(n: Int) -> fn(core.World, Int) -> core.World {
  fn(world, _) { core.bump(world, resource(n - 1)) }
}

fn core_apply(n: Int) -> fn(core.World, Int) -> core.World {
  fn(world, index) {
    let command =
      core.Command(index, core.Basis(resource(n - 1), core.revision(n + index)))
    case core.apply(world, command) {
      core.Applied(#(_, next)) -> next
      _ -> world
    }
  }
}

fn core_apply_conflicted(n: Int) -> fn(core.World, Int) -> core.World {
  fn(world, index) {
    let command =
      core.Command(index, core.Basis(resource(n - 1), core.revision(0)))
    case core.apply(world, command) {
      core.Conflicted(_) -> world
      _ -> world
    }
  }
}

fn core_apply_unknown(world: core.World, index: Int) -> core.World {
  let command =
    core.Command(
      index,
      core.Basis(core.resource("missing", "r"), core.revision(1)),
    )
  case core.apply(world, command) {
    core.Rejected(_) -> world
    _ -> world
  }
}

fn identity(index: Int) -> rp.RequestIdentity {
  rp.RequestIdentity("k", "p", index)
}

fn footprint() -> rp.RequestFootprint {
  rp.RequestFootprint([], [], rp.PureEffect)
}

fn demand() -> rp.ResourceDemand {
  rp.ResourceDemand(1, 1, 1)
}

fn budget(n: Int) -> rp.ResourceBudget {
  rp.ResourceBudget(
    rp.ConfiguredSafetyLimit("p", n * 4),
    rp.ConfiguredSafetyLimit("i", n * 4),
    rp.ConfiguredSafetyLimit("c", n * 4),
  )
}

fn entry(index: Int, phase: rp.RequestPhase) -> rp.RequestEntry {
  rp.RequestEntry(
    identity(index),
    footprint(),
    demand(),
    phase,
    rp.Permitted(identity(index), []),
    None,
    case phase {
      rp.Publishing -> Some(rp.ExecutionHandle("h"))
      _ -> None
    },
  )
}

fn snapshot(
  policy: rp.RequestPolicy,
  phase: rp.RequestPhase,
  n: Int,
) -> rp.RequestProgressionSnapshot {
  let assert Ok(built) =
    rp.snapshot_of(
      policy,
      budget(n),
      Some(identity(0)),
      list.map(indices(n), fn(index) { entry(index, phase) }),
      0,
    )
  built
}

fn pending_snapshot(
  policy: rp.RequestPolicy,
  n: Int,
) -> rp.RequestProgressionSnapshot {
  snapshot(policy, rp.Pending, n)
}

fn phase_snapshot(
  phase: rp.RequestPhase,
  n: Int,
) -> rp.RequestProgressionSnapshot {
  snapshot(rp.AllExecute, phase, n)
}

fn request_input(index: Int) -> rp.RequestInput {
  rp.RequestInput(
    identity(index),
    footprint(),
    demand(),
    rp.Permitted(identity(index), []),
  )
}

fn evidence() -> rp.EvidenceVersion {
  rp.EvidenceVersion("e", "d", "p")
}

fn rp_submit(
  n: Int,
) -> fn(rp.RequestProgressionSnapshot, Int) -> rp.RequestProgressionSnapshot {
  fn(snapshot, index) {
    case rp.submit(snapshot, request_input(n + index)) {
      rp.SubmitAccepted(next, _) -> next
      rp.SubmitRejected(_, _) -> snapshot
    }
  }
}

fn rp_decide_start(
  snapshot: rp.RequestProgressionSnapshot,
  index: Int,
) -> rp.RequestProgressionSnapshot {
  let selection = rp.ExecuteNow(identity(index), evidence(), 1)
  case rp.decide_start(snapshot, rp.Accepted(identity(index)), selection) {
    rp.Execute(next, _, _) -> next
    _ -> snapshot
  }
}

fn rp_decide_start_blocked(
  n: Int,
) -> fn(rp.RequestProgressionSnapshot, Int) -> rp.RequestProgressionSnapshot {
  fn(snapshot, _) {
    let selection = rp.ExecuteNow(identity(n - 1), evidence(), 1)
    case rp.decide_start(snapshot, rp.Accepted(identity(n - 1)), selection) {
      rp.StartDecisionRejected(_, _) -> snapshot
      _ -> snapshot
    }
  }
}

fn rp_apply_start_observation(
  snapshot: rp.RequestProgressionSnapshot,
  index: Int,
) -> rp.RequestProgressionSnapshot {
  let starting =
    rp.Starting(identity(index), rp.StartCommand(identity(index), footprint()))
  let observed =
    rp.AppliedSignal(rp.Started(identity(index), rp.ExecutionHandle("h")))
  case rp.apply_start_observation(snapshot, starting, observed) {
    rp.StartObservationPublishing(next, _) -> next
    rp.StartObservationFailed(_, _) -> snapshot
  }
}

fn rp_apply_completion_observation(
  snapshot: rp.RequestProgressionSnapshot,
  index: Int,
) -> rp.RequestProgressionSnapshot {
  let handle = rp.ExecutionHandle("h")
  let observed = rp.AppliedSignal(rp.Completed(identity(index), handle, Nil))
  case
    rp.apply_completion_observation(
      snapshot,
      rp.Running(identity(index), handle),
      observed,
    )
  {
    rp.CompletionApplied(next, _, _) -> next
    _ -> snapshot
  }
}

fn rp_decide_cancel(
  snapshot: rp.RequestProgressionSnapshot,
  index: Int,
) -> rp.RequestProgressionSnapshot {
  case rp.decide_cancel(snapshot, identity(index)) {
    rp.CancelledDecision(next, _) -> next
    _ -> snapshot
  }
}

fn rp_derive(
  which: Int,
) -> fn(rp.RequestProgressionSnapshot, Int) -> rp.RequestProgressionSnapshot {
  fn(snapshot, _) {
    let total = case which {
      0 -> rp.derive_pending(snapshot)
      1 -> rp.derive_in_flight(snapshot)
      _ -> rp.derive_concurrent(snapshot)
    }
    case total {
      rp.ResourceDemand(_, _, _) -> snapshot
    }
  }
}

fn admission_state(
  policy: rp.RequestPolicy,
  phase: rp.RequestPhase,
  n: Int,
) -> admission.DynamicAdmissionState {
  admission.admission_state_of(
    snapshot(policy, phase, n),
    budget(n),
    admission.AdmissionProvenance(
      list.map(indices(n), fn(index) { identity(n * 4 + index) }),
      [],
    ),
  )
}

fn da_input(
  state: admission.DynamicAdmissionState,
  n: Int,
  index: Int,
  executed: Bool,
) -> admission.DynamicAdmissionInput {
  admission.DynamicAdmissionInput(
    state,
    request_input(n * 2 + index),
    admission.EnvironmentSpecification(10),
    admission.CapacityObservation(budget(n), 0),
    0,
    case executed {
      True -> Some(rp.ExecuteNow(identity(n * 2 + index), evidence(), 1))
      False -> None
    },
  )
}

fn da_admit(
  n: Int,
  executed: Bool,
) -> fn(admission.DynamicAdmissionState, Int) -> admission.DynamicAdmissionState {
  fn(state, index) {
    case admission.admit_dynamic_request(da_input(state, n, index, executed)) {
      core.Applied(result) ->
        case result.admission_decision {
          admission.Submitted(next, _) -> next
          admission.Started(next, _) -> next
          admission.Coalesced(next, _) -> next
        }
      _ -> state
    }
  }
}

fn da_elide(
  state: admission.DynamicAdmissionState,
  index: Int,
) -> admission.DynamicAdmissionState {
  case admission.elide_admission_provenance(state, identity(index)) {
    core.Applied(#(next, _)) -> next
    _ -> state
  }
}

type Disposition {
  Prepared
  Issued
  Started
  Settled
}

fn attempt(index: Int, ordinal: Int) -> effect.AttemptIdentity {
  effect.AttemptIdentity(effect.request_identity("k", "p", index), ordinal)
}

fn handle() -> effect.ExecutionHandle {
  effect.ExecutionHandle("h")
}

fn configuration() -> effect.HostConfiguration {
  effect.HostConfiguration(
    1024,
    1024,
    Some(effect.CancellationCapability(effect.OpaqueEvidence("c"))),
    None,
  )
}

fn instruction() -> effect.HttpWireInstruction {
  effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<>>)
}

fn attempt_input(identity: effect.AttemptIdentity) -> effect.AttemptInput {
  effect.AttemptInput(identity, instruction(), None, configuration())
}

fn terminal_effect() -> effect.EffectStatus {
  effect.Unknown(effect.NoResponse)
}

fn cancellation_observation(
  identity: effect.AttemptIdentity,
) -> effect.AdapterObservation {
  effect.CancellationObservation(
    identity,
    handle(),
    effect.NoSource,
    terminal_effect(),
  )
}

fn record_of(index: Int, disposition: Disposition) -> effect.AttemptRecord {
  let identity = attempt(index, 0)
  let input = attempt_input(identity)
  case disposition {
    Prepared ->
      effect.AttemptRecord(input, effect.Root, effect.Prepared, None, [])
    Issued ->
      effect.AttemptRecord(input, effect.Root, effect.CommandIssued, None, [])
    Started ->
      effect.AttemptRecord(
        input,
        effect.Root,
        effect.Started(handle()),
        None,
        [],
      )
    Settled ->
      effect.AttemptRecord(
        input,
        effect.Root,
        effect.Settled(
          Some(handle()),
          effect.NetworkTerminal(effect.Cancelled, terminal_effect()),
        ),
        Some(effect.DeliveredObservation(0, cancellation_observation(identity))),
        [],
      )
  }
}

fn network_state(disposition: Disposition, n: Int) -> effect.NetworkState {
  let assert Ok(state) =
    effect.network_state_of(
      list.map(indices(n), fn(index) { record_of(index, disposition) }),
    )
  state
}

fn prepared_of(index: Int) -> effect.PreparedAttempt {
  effect.PreparedAttempt(attempt_input(attempt(index, 0)), effect.Root)
}

fn ne_prepare(n: Int) -> fn(effect.NetworkState, Int) -> effect.NetworkState {
  fn(state, index) {
    case effect.prepare(state, attempt_input(attempt(n + index, 0))) {
      effect.PreparedResult(next, _) -> next
      effect.PrepareRejected(_, _) -> state
    }
  }
}

fn ne_send_command(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  case effect.send_command(state, prepared_of(index)) {
    effect.CommandReady(next, _) -> next
    effect.CommandRejected(_, _) -> state
  }
}

fn ne_observe_start(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  let observation = effect.StartedObservation(attempt(index, 0), handle())
  case effect.observe_start(state, prepared_of(index), observation) {
    effect.StartedStep(next, _) -> next
    _ -> state
  }
}

fn ne_cancel_command(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  let started = effect.StartedAttempt(prepared_of(index), handle())
  case effect.cancel_command(state, started) {
    effect.CommandReady(_, _) -> state
    effect.CommandRejected(_, _) -> state
  }
}

fn ne_observe_pending(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  case effect.observe(state, effect.Pending(attempt(index, 0), handle())) {
    effect.PendingStep(_, _) -> state
    _ -> state
  }
}

fn ne_observe_delivered(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  let observation = cancellation_observation(attempt(index, 0))
  case effect.observe(state, effect.Delivered(0, observation)) {
    effect.TerminalStep(next, _) -> next
    _ -> state
  }
}

fn ne_observe_late(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  let observation = cancellation_observation(attempt(index, 0))
  case effect.observe(state, effect.Delivered(1, observation)) {
    effect.LateStep(next, _, _) -> next
    _ -> state
  }
}

fn ne_annotate_effect(
  state: effect.NetworkState,
  index: Int,
) -> effect.NetworkState {
  let identity = attempt(index, 0)
  let status =
    effect.EffectOccurred(effect.EffectWitness(
      identity,
      effect.Adapter,
      effect.OpaqueEvidence("w"),
    ))
  case
    effect.annotate_effect(state, effect.EffectObservation(identity, status))
  {
    effect.Applied(next) -> next
    effect.StateRejected(_, _) -> state
  }
}

fn ne_retry(state: effect.NetworkState, index: Int) -> effect.NetworkState {
  let authorization =
    effect.RetryAuthorization(
      effect.request_identity("k", "p", index),
      attempt(index, 0),
      attempt(index, 1),
      effect.OpaqueEvidence("a"),
    )
  let request =
    effect.RetryRequest(
      effect.RetryAllowed(authorization),
      instruction(),
      None,
      configuration(),
    )
  case effect.retry(state, request) {
    effect.PreparedResult(next, _) -> next
    effect.PrepareRejected(_, _) -> state
  }
}

fn ne_read(state: effect.NetworkState, _index: Int) -> effect.NetworkState {
  case effect.read_network_state(state) {
    effect.Read(next) -> next
    effect.ReadRejected(_, _) -> state
  }
}

fn store_state(n: Int) -> store.Store(Int) {
  store.store_of(
    list.map(indices(n), fn(index) {
      #(resource(index), core.revision(index + 1), index)
    }),
  )
}

fn store_observe(n: Int) -> fn(store.Store(Int), Int) -> store.Store(Int) {
  fn(state, _) {
    case store.observe(state, resource(n - 1)) {
      store.ObserveFound(_, _) -> state
      store.ObserveUnknown(_) -> state
    }
  }
}

fn store_apply(n: Int) -> fn(store.Store(Int), Int) -> store.Store(Int) {
  fn(state, index) {
    let command =
      core.Command(index, core.Basis(resource(n - 1), core.revision(n + index)))
    case store.apply(state, command) {
      core.Applied(#(_, next)) -> next
      _ -> state
    }
  }
}

fn file_path(index: Int) -> files.NormalizedPath {
  files.normalize_path(True, ["f" <> int.to_string(index)])
}

fn file_resource(index: Int) -> core.ResourceId {
  core.resource("file", "/f" <> int.to_string(index))
}

fn file_digest(index: Int) -> files.ContentDigest {
  files.ContentDigest("d" <> int.to_string(index))
}

fn file_world(n: Int) -> core.World {
  core.world(
    list.map(indices(n), fn(index) { #(file_resource(index), core.revision(0)) }),
  )
}

type FileHeld =
  #(core.World, files.Digests, files.ExternalFileState)

fn file_held(n: Int) -> FileHeld {
  #(
    file_world(n),
    files.digests_of(
      list.map(indices(n), fn(index) { #(file_resource(index), file_digest(0)) }),
    ),
    files.external_file_state_of(
      list.map(indices(n), fn(index) {
        #(file_path(index), files.FileRecord(file_digest(0), [0, 0, 0, 0]))
      }),
      [],
      [],
    ),
  )
}

fn file_effect_read(n: Int) -> fn(FileHeld, Int) -> FileHeld {
  fn(held, index) {
    let #(world, digests, external) = held
    case
      files.read(files.ReadReq(
        file_path(n - 1),
        world,
        digests,
        external,
        index,
      ))
    {
      core.Applied(read) -> #(read.world, read.digests, external)
      _ -> held
    }
  }
}

fn file_effect_replace(n: Int) -> fn(FileHeld, Int) -> FileHeld {
  fn(held, index) {
    let #(world, digests, external) = held
    let command =
      core.Command(
        files.ReplaceContents([1, 1, 1, 1], file_digest(index + 1)),
        core.Basis(file_resource(n - 1), core.revision(index)),
      )
    case
      files.replace(files.ReplaceReq(
        command,
        file_path(n - 1),
        world,
        digests,
        external,
        index,
      ))
    {
      core.Applied(replaced) -> #(
        replaced.world,
        replaced.digests,
        replaced.state,
      )
      _ -> held
    }
  }
}

fn file_effect_track(n: Int) -> fn(core.World, Int) -> core.World {
  fn(world, index) {
    case files.track(files.TrackReq(file_path(n + index), world, index)) {
      core.Applied(tracked) -> tracked.world
      _ -> world
    }
  }
}

fn reconcile_all(n: Int) -> fn(core.World, Int) -> core.World {
  let bases =
    list.map(indices(n), fn(index) {
      Some(core.Basis(resource(index), core.revision(index + 1)))
    })
  fn(world, _) {
    case reconcile.reconcile(bases, world, 0) {
      reconcile.Reconciliation(_, _, _) -> world
    }
  }
}
