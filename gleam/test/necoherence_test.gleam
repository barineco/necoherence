// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleeunit
import host_file_adapter
import necoherence/call
import necoherence/core
import necoherence/dynamic_admission as admission
import necoherence/file_effect as files
import necoherence/iteration
import necoherence/reconcile
import necoherence/record
import necoherence/request_progression as rp
import necoherence/store
import necoherence/transition

pub fn main() -> Nil {
  gleeunit.main()
}

fn rid(number: Int) -> core.ResourceId {
  core.resource("core", "r" <> int_to_string(number))
}

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    _ -> "n"
  }
}

fn world_of(entries: List(#(Int, Int))) -> core.World {
  core.world(
    list.map(entries, fn(pair) {
      let #(resource, value) = pair
      #(rid(resource), core.revision(value))
    }),
  )
}

fn cmd(resource: Int, revision: Int, intent: Int) -> core.Command(Int) {
  core.Command(intent, core.Basis(rid(resource), core.revision(revision)))
}

// ### Core

pub fn core_outcome_closure_test() {
  let world = world_of([#(0, 1), #(1, 2)])
  list.each([cmd(0, 1, 7), cmd(99, 0, 1), cmd(0, 0, 2)], fn(command) {
    case core.apply(world, command) {
      core.Applied(_) | core.Rejected(_) | core.Conflicted(_) -> Nil
      core.BoundaryFailed(_) -> panic as "core.apply never boundary-fails"
    }
  })
}

pub fn core_basis_retention_test() {
  let basis = core.Basis(rid(0), core.revision(5))
  let observation = core.Observation(42, basis, 0)
  let command = core.command_of(observation, 99)
  assert command.basis == basis
}

pub fn core_stale_conflict_test() {
  let world = world_of([#(0, 5)])
  assert core.apply(world, cmd(0, 4, 1))
    == core.Conflicted(core.StaleBasis(core.revision(4), core.revision(5)))
}

pub fn core_apply_disjoint_order_invariance_test() {
  let world = world_of([#(0, 1), #(1, 2), #(2, 3)])
  let order_12 = case core.apply(world, cmd(0, 1, 10)) {
    core.Applied(#(_, w1)) ->
      case core.apply(w1, cmd(1, 2, 20)) {
        core.Applied(#(_, w2)) -> Ok(w2)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  let order_21 = case core.apply(world, cmd(1, 2, 20)) {
    core.Applied(#(_, w1)) ->
      case core.apply(w1, cmd(0, 1, 10)) {
        core.Applied(#(_, w2)) -> Ok(w2)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  let assert Ok(left) = order_12
  let assert Ok(right) = order_21
  list.each([0, 1, 2, 99], fn(r) {
    assert core.lookup(left, rid(r)) == core.lookup(right, rid(r))
  })
}

pub fn core_bump_lookup_locality_test() {
  let world = world_of([#(0, 1), #(1, 2)])
  let bumped = core.bump(world, rid(0))
  assert core.lookup(bumped, rid(1)) == core.lookup(world, rid(1))
  assert core.lookup(bumped, rid(0)) == core.Found(core.revision(2))
}

// ### Iteration

fn counter_step() -> call.Immediate(Int, Int) {
  call.immediate_of("counter", [], fn(state) { state + 1 })
}

pub fn iteration_fold_round_count_test() {
  let outcome = iteration.fold(iteration.FoldReq(counter_step(), 0, 3, []))
  assert outcome == iteration.FoldTrace([0, 1, 2, 3])
}

fn decreasing_step() -> call.Immediate(Int, iteration.StepOutcome(Int)) {
  call.immediate_of("decreasing", [], fn(state) {
    case state {
      0 -> iteration.Settled(0)
      _ -> iteration.Advance(state - 1, state - 1)
    }
  })
}

pub fn iteration_recurse_strict_decrease_test() {
  let outcome =
    iteration.recurse(iteration.RecurseReq(decreasing_step(), 3, []))
  assert outcome == iteration.RecurseSettled(0, 3)
}

fn non_decreasing_step() -> call.Immediate(Int, iteration.StepOutcome(Int)) {
  call.immediate_of("non_decreasing", [], fn(state) {
    iteration.Advance(state, state)
  })
}

pub fn iteration_recurse_did_not_decrease_test() {
  let outcome =
    iteration.recurse(iteration.RecurseReq(non_decreasing_step(), 5, []))
  assert outcome == iteration.RecurseDidNotDecrease(1, 5, 5, 5)
}

fn closure_step() -> call.Immediate(iteration.ClosureState(Int), List(Int)) {
  call.immediate_of("closure_step", [], fn(state: iteration.ClosureState(Int)) {
    case list.contains(state.elements, 1) {
      True -> [1, 2]
      False -> [1]
    }
  })
}

pub fn iteration_closure_extensivity_and_termination_test() {
  let outcome =
    iteration.closure(iteration.ClosureReq(closure_step(), [1, 2], [], []))
  assert outcome == iteration.Fixpoint([1, 2], 2)
}

// ### Store

pub fn store_observe_preserves_world_projection_test() {
  let entries = [
    #(rid(0), core.revision(1), "a"),
    #(rid(1), core.revision(2), "b"),
  ]
  let s = store.store_of(entries)
  list.each([0, 1, 99], fn(r) {
    let observed = store.observe(s, rid(r))
    let projected = core.lookup(store.world_of(s), rid(r))
    case observed {
      store.ObserveFound(revision, _) -> {
        assert projected == core.Found(revision)
      }
      store.ObserveUnknown(u) -> {
        assert projected == core.Unknown(u)
      }
    }
  })
}

pub fn store_apply_projects_onto_world_apply_test() {
  let entries = [#(rid(0), core.revision(1), "a")]
  let s = store.store_of(entries)
  let command = core.Command("b", core.Basis(rid(0), core.revision(1)))
  case store.apply(s, command) {
    core.Applied(#(_, s2)) -> {
      assert store.world_of(s2) == core.bump(store.world_of(s), rid(0))
    }
    _ -> panic as "expected applied"
  }
}

// ### Record / Reconcile

pub fn record_has_edge_symmetric_test() {
  let basis = core.Basis(rid(0), core.revision(1))
  let a = record.record_on_basis("a", 1, 1, basis)
  let b = record.record_on_basis("b", 2, 2, basis)
  assert record.has_edge(a, b) == record.has_edge(b, a)
}

pub fn record_has_edge_absent_without_basis_test() {
  let a = record.record_of("a", 1, 1)
  let b = record.record_of("b", 2, 2)
  assert record.has_edge(a, b) == False
}

pub fn reconcile_order_invariance_test() {
  let bases = [
    Some(core.Basis(rid(0), core.revision(1))),
    Some(core.Basis(rid(1), core.revision(2))),
    None,
  ]
  let world = world_of([#(0, 1), #(1, 2)])
  let forward = reconcile.reconcile(bases, world, 0)
  let reversed = reconcile.reconcile(list.reverse(bases), world, 0)
  let forward_present =
    list.all(forward.divergences, fn(d) {
      list.contains(reversed.divergences, d)
    })
  let reversed_present =
    list.all(reversed.divergences, fn(d) {
      list.contains(forward.divergences, d)
    })
  assert forward_present && reversed_present
  assert forward.unbased == reversed.unbased
}

pub fn reconcile_max_revision_and_coherence_test() {
  let bases = [
    Some(core.Basis(rid(0), core.revision(1))),
    Some(core.Basis(rid(0), core.revision(3))),
  ]
  let world = world_of([#(0, 3)])
  let result = reconcile.reconcile(bases, world, 0)
  assert result.divergences == []
  assert reconcile.coherent(result) == True
}

pub fn reconcile_unbased_and_dropped_test() {
  let bases = [None, None]
  let world = world_of([])
  let result = reconcile.reconcile(bases, world, 2)
  assert result.unbased == 2
  assert result.dropped == 2
  assert reconcile.coherent(result) == False
}

// ### Request progression

fn budget(max: Int) -> rp.ResourceBudget {
  rp.ResourceBudget(
    rp.ConfiguredSafetyLimit("pending", max),
    rp.ConfiguredSafetyLimit("in_flight", max),
    rp.ConfiguredSafetyLimit("concurrent", max),
  )
}

fn identity(revision: Int) -> rp.RequestIdentity {
  rp.RequestIdentity("kind", "provenance", revision)
}

fn request_input(revision: Int) -> rp.RequestInput {
  let ident = identity(revision)
  rp.RequestInput(
    ident,
    rp.RequestFootprint([], [], rp.PureEffect),
    rp.ResourceDemand(1, 1, 1),
    rp.Ordered(ident, []),
  )
}

pub fn request_progression_latest_wins_supersedes_test() {
  let snapshot = rp.empty(rp.LatestWins, budget(10))
  let assert rp.SubmitAccepted(s1, _) = rp.submit(snapshot, request_input(1))
  let assert rp.SubmitAccepted(s2, _) = rp.submit(s1, request_input(2))
  let assert Ok(first) =
    list.find(s2.entries, fn(e) { e.identity == identity(1) })
  assert first.phase == rp.Superseded
}

pub fn request_progression_fifo_start_order_test() {
  let snapshot = rp.empty(rp.Fifo, budget(10))
  let assert rp.SubmitAccepted(s1, accepted1) =
    rp.submit(snapshot, request_input(1))
  let assert rp.SubmitAccepted(s2, _accepted2) = rp.submit(s1, request_input(2))
  let selection =
    rp.ExecuteNow(identity(1), rp.EvidenceVersion("e", "d", "p"), 0)
  let assert rp.Execute(s3, starting, _) =
    rp.decide_start(s2, accepted1, selection)
  let observed =
    rp.AppliedSignal(rp.Started(identity(1), rp.ExecutionHandle("h")))
  let assert rp.StartObservationPublishing(_, _) =
    rp.apply_start_observation(s3, starting, observed)
}

pub fn request_progression_all_execute_permits_concurrent_starts_test() {
  let snapshot = rp.empty(rp.AllExecute, budget(10))
  let assert rp.SubmitAccepted(s1, accepted1) =
    rp.submit(snapshot, request_input(1))
  let assert rp.SubmitAccepted(s2, accepted2) = rp.submit(s1, request_input(2))
  let selection1 =
    rp.ExecuteNow(identity(1), rp.EvidenceVersion("e", "d", "p"), 0)
  let assert rp.Execute(s3, starting1, _) =
    rp.decide_start(s2, accepted1, selection1)
  let observed1 =
    rp.AppliedSignal(rp.Started(identity(1), rp.ExecutionHandle("h1")))
  let assert rp.StartObservationPublishing(s4, _) =
    rp.apply_start_observation(s3, starting1, observed1)
  let selection2 =
    rp.ExecuteNow(identity(2), rp.EvidenceVersion("e", "d", "p"), 0)
  let assert rp.Execute(s5, starting2, _) =
    rp.decide_start(s4, accepted2, selection2)
  let observed2 =
    rp.AppliedSignal(rp.Started(identity(2), rp.ExecutionHandle("h2")))
  let assert rp.StartObservationPublishing(_, _) =
    rp.apply_start_observation(s5, starting2, observed2)
}

pub fn request_progression_pending_limit_exceeded_test() {
  let snapshot = rp.empty(rp.AllExecute, budget(0))
  let assert rp.SubmitRejected(_, rp.SubmitPendingLimitExceeded(_, _)) =
    rp.submit(snapshot, request_input(1))
}

pub fn request_progression_cancel_pending_without_adapter_test() {
  let snapshot = rp.empty(rp.AllExecute, budget(10))
  let assert rp.SubmitAccepted(s1, _) = rp.submit(snapshot, request_input(1))
  let assert rp.CancelledDecision(s2, _) = rp.decide_cancel(s1, identity(1))
  let assert Ok(entry) =
    list.find(s2.entries, fn(e) { e.identity == identity(1) })
  assert entry.phase == rp.Cancelled
}

pub fn request_progression_stale_completion_is_superseded_test() {
  let snapshot = rp.empty(rp.LatestWins, budget(10))
  let assert rp.SubmitAccepted(s1, accepted1) =
    rp.submit(snapshot, request_input(1))
  let selection =
    rp.ExecuteNow(identity(1), rp.EvidenceVersion("e", "d", "p"), 0)
  let assert rp.Execute(s2, starting, _) =
    rp.decide_start(s1, accepted1, selection)
  let observed =
    rp.AppliedSignal(rp.Started(identity(1), rp.ExecutionHandle("h")))
  let assert rp.StartObservationPublishing(s3, running) =
    rp.apply_start_observation(s2, starting, observed)
  let assert rp.SubmitAccepted(s4, _) = rp.submit(s3, request_input(2))
  let completion =
    rp.AppliedSignal(rp.Completed(identity(1), rp.ExecutionHandle("h"), 0))
  let assert rp.CompletionSuperseded(_, _) =
    rp.apply_completion_observation(s4, running, completion)
}

pub fn request_progression_derive_occupancy_test() {
  let snapshot = rp.empty(rp.AllExecute, budget(10))
  let assert rp.SubmitAccepted(s1, _) = rp.submit(snapshot, request_input(1))
  let pending = rp.derive_pending(s1)
  assert pending == rp.ResourceDemand(1, 1, 1)
  assert rp.derive_in_flight(s1) == rp.ResourceDemand(0, 0, 0)
  assert rp.derive_concurrent(s1) == rp.ResourceDemand(0, 0, 0)
}

// ### Dynamic admission

fn admission_state(max: Int) -> admission.DynamicAdmissionState {
  admission.DynamicAdmissionState(
    rp.empty(rp.AllExecute, budget(max)),
    budget(max),
    admission.AdmissionProvenance([], []),
  )
}

fn admission_input(
  state: admission.DynamicAdmissionState,
  revision: Int,
  max: Int,
) -> admission.DynamicAdmissionInput {
  admission.DynamicAdmissionInput(
    state,
    request_input(revision),
    admission.EnvironmentSpecification(100),
    admission.CapacityObservation(budget(max), 0),
    0,
    None,
  )
}

pub fn dynamic_admission_rejects_over_budget_test() {
  let state = admission_state(0)
  let result = admission.admit_dynamic_request(admission_input(state, 1, 0))
  case result {
    core.Rejected(admission.ConfiguredSafetyLimitExceeded(_, _, _)) -> Nil
    _ -> panic as "expected configured safety limit exceeded"
  }
}

pub fn dynamic_admission_coalesces_identical_pending_test() {
  let state = admission_state(10)
  let input1 = admission_input(state, 1, 10)
  let assert core.Applied(admission.DynamicAdmissionResult(
    _,
    admission.Submitted(state2, _),
    _,
    _,
    _,
    _,
  )) = admission.admit_dynamic_request(input1)
  let input2 = admission_input(state2, 1, 10)
  let assert core.Applied(admission.DynamicAdmissionResult(
    _,
    admission.Coalesced(_, coalesced_identity),
    _,
    _,
    _,
    admission.CoalescedRequest(_),
  )) = admission.admit_dynamic_request(input2)
  assert coalesced_identity == identity(1)
}

pub fn dynamic_admission_expired_observation_rejects_test() {
  let state = admission_state(10)
  let input =
    admission.DynamicAdmissionInput(
      ..admission_input(state, 1, 10),
      environment_specification: admission.EnvironmentSpecification(0),
      capacity_observation: admission.CapacityObservation(budget(10), 5),
      observed_at: 10,
    )
  case admission.admit_dynamic_request(input) {
    core.Rejected(admission.CapacityObservationUnavailable(_, _)) -> Nil
    _ -> panic as "expected capacity observation unavailable"
  }
}

pub fn dynamic_admission_erasure_requires_terminal_test() {
  let state = admission_state(10)
  case admission.elide_admission_provenance(state, identity(1)) {
    core.Rejected(admission.AdmissionUnknownRequest(_)) -> Nil
    _ -> panic as "expected unknown request"
  }
}

// ### Step transition

pub fn transition_settles_within_limit_test() {
  let assert Ok(limit) = transition.positive_limit_new(3)
  let assert Ok(capacity) = transition.capacity_new(4)
  let settled =
    transition.step(
      0,
      5,
      fn(state, input) { transition.Consumed(state + input, [input]) },
      limit,
      capacity,
    )
  assert settled == transition.Settled(5, [5], 1)
}

pub fn transition_reprocess_limit_exhausted_test() {
  let assert Ok(limit) = transition.positive_limit_new(3)
  let assert Ok(capacity) = transition.capacity_new(4)
  let exhausted =
    transition.step(
      0,
      5,
      fn(state, input) { transition.Reprocess(state + input, []) },
      limit,
      capacity,
    )
  assert exhausted
    == transition.Failed(15, [], transition.ReprocessLimitExhausted(3))
}

pub fn transition_same_input_reprocess_test() {
  let assert Ok(limit) = transition.positive_limit_new(4)
  let assert Ok(capacity) = transition.capacity_new(8)
  let result =
    transition.step(
      [],
      7,
      fn(state, input) {
        let state = [input, ..state]
        case list.length(state) >= 3 {
          True -> transition.Consumed(state, [input])
          False -> transition.Reprocess(state, [])
        }
      },
      limit,
      capacity,
    )
  assert result == transition.Settled([7, 7, 7], [7], 3)
}

pub fn transition_output_order_test() {
  let assert Ok(limit) = transition.positive_limit_new(3)
  let assert Ok(capacity) = transition.capacity_new(6)
  let result =
    transition.step(
      0,
      0,
      fn(state, _input) {
        case state {
          0 -> transition.Reprocess(1, ["a", "b"])
          _ -> transition.Consumed(2, ["c"])
        }
      },
      limit,
      capacity,
    )
  assert result == transition.Settled(2, ["a", "b", "c"], 2)
}

pub fn transition_zero_output_test() {
  let assert Ok(limit) = transition.positive_limit_new(1)
  let assert Ok(capacity) = transition.capacity_new(0)
  let result =
    transition.step(
      "s",
      1,
      fn(state, _input) { transition.Consumed(state, []) },
      limit,
      capacity,
    )
  assert result == transition.Settled("s", [], 1)
}

pub fn transition_bounded_capacity_test() {
  let assert Ok(limit) = transition.positive_limit_new(2)
  let assert Ok(capacity) = transition.capacity_new(1)
  let result =
    transition.step(
      0,
      0,
      fn(_state, _input) { transition.Consumed(1, [10, 20]) },
      limit,
      capacity,
    )
  assert result
    == transition.Failed(1, [10, 20], transition.CapacityExceeded(1, 2))
}

pub fn transition_limit_and_capacity_bounds_test() {
  assert transition.positive_limit_new(0)
    == Error(transition.LimitNotPositive(0))
  assert transition.capacity_new(-1) == Error(transition.CapacityNegative(-1))
  let assert Ok(limit) = transition.positive_limit_new(2)
  assert transition.positive_limit_value(limit) == 2
  let assert Ok(capacity) = transition.capacity_new(0)
  assert transition.capacity_value(capacity) == 0
}

// ### File effect

pub fn file_effect_normalize_path_idempotent_test() {
  let raw = ["a", "..", "b", ".", "c"]
  let once = files.normalize_path(True, raw)
  let twice = files.normalize_path(True, once.segments)
  assert once == twice
  assert once.segments == ["b", "c"]
}

fn file_world() -> core.World {
  core.world([])
}

pub fn file_effect_track_and_read_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let record = files.FileRecord(files.ContentDigest("d1"), [1, 2, 3])
  let state = files.ExternalFileState([#(path, record)], [], [])
  let assert core.Applied(tracked) =
    files.track(files.TrackReq(path, file_world(), 0))
  let assert core.Applied(read_result) =
    files.read(files.ReadReq(path, tracked.world, files.Digests([]), state, 0))
  assert read_result.observation.payload.contents == [1, 2, 3]
}

pub fn file_effect_stale_revision_conflicts_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let record = files.FileRecord(files.ContentDigest("d1"), [1])
  let state = files.ExternalFileState([#(path, record)], [], [])
  let assert core.Applied(read_result) =
    files.read(files.ReadReq(path, file_world(), files.Digests([]), state, 0))
  let stale_basis =
    core.Basis(read_result.observation.basis.resource, core.revision(99))
  let command =
    core.Command(
      files.ReplaceContents([9], files.ContentDigest("d2")),
      stale_basis,
    )
  let replaced =
    files.replace(files.ReplaceReq(
      command,
      path,
      read_result.world,
      read_result.digests,
      state,
      0,
    ))
  case replaced {
    core.Conflicted(files.ConflictStaleBasis(_)) -> Nil
    _ -> panic as "expected stale basis conflict"
  }
}

pub fn file_effect_external_mutation_conflicts_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let record = files.FileRecord(files.ContentDigest("d1"), [1])
  let state = files.ExternalFileState([#(path, record)], [], [])
  let assert core.Applied(read_result) =
    files.read(files.ReadReq(path, file_world(), files.Digests([]), state, 0))
  let mutated_state =
    files.ExternalFileState(
      [#(path, files.FileRecord(files.ContentDigest("d2"), [2]))],
      [],
      [],
    )
  let command =
    core.Command(
      files.ReplaceContents([9], files.ContentDigest("d3")),
      read_result.observation.basis,
    )
  let replaced =
    files.replace(files.ReplaceReq(
      command,
      path,
      read_result.world,
      read_result.digests,
      mutated_state,
      0,
    ))
  case replaced {
    core.Conflicted(files.ConflictExternalMutation(_)) -> Nil
    _ -> panic as "expected external mutation conflict"
  }
}

pub fn file_effect_unobserved_contents_rejects_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let command =
    core.Command(
      files.ReplaceContents([9], files.ContentDigest("d2")),
      core.Basis(core.resource("file", "/a.txt"), core.revision(0)),
    )
  let state = files.ExternalFileState([], [], [])
  let replaced =
    files.replace(files.ReplaceReq(
      command,
      path,
      file_world(),
      files.Digests([]),
      state,
      0,
    ))
  case replaced {
    core.Rejected(files.RejectUnobservedContents(_)) -> Nil
    _ -> panic as "expected unobserved contents rejection"
  }
}

pub fn file_effect_atomic_replace_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let record = files.FileRecord(files.ContentDigest("d1"), [1])
  let state = files.ExternalFileState([#(path, record)], [], [])
  let assert core.Applied(read_result) =
    files.read(files.ReadReq(path, file_world(), files.Digests([]), state, 0))
  let command =
    core.Command(
      files.ReplaceContents([9, 9], files.ContentDigest("d2")),
      read_result.observation.basis,
    )
  let assert core.Applied(replaced) =
    files.replace(files.ReplaceReq(
      command,
      path,
      read_result.world,
      read_result.digests,
      state,
      0,
    ))
  assert replaced.observation.payload.contents == [9, 9]
}

pub fn file_effect_write_failure_is_boundary_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let record = files.FileRecord(files.ContentDigest("d1"), [1])
  let state = files.ExternalFileState([#(path, record)], [], [path])
  let assert core.Applied(read_result) =
    files.read(files.ReadReq(path, file_world(), files.Digests([]), state, 0))
  let command =
    core.Command(
      files.ReplaceContents([9], files.ContentDigest("d2")),
      read_result.observation.basis,
    )
  let replaced =
    files.replace(files.ReplaceReq(
      command,
      path,
      read_result.world,
      read_result.digests,
      state,
      0,
    ))
  case replaced {
    core.BoundaryFailed(files.WriteFailure(_)) -> Nil
    _ -> panic as "expected write boundary failure"
  }
}

pub fn file_effect_read_failure_is_boundary_test() {
  let path = files.normalize_path(True, ["a.txt"])
  let state = files.ExternalFileState([], [path], [])
  let read_result =
    files.read(files.ReadReq(path, file_world(), files.Digests([]), state, 0))
  case read_result {
    core.BoundaryFailed(files.ReadFailure(_)) -> Nil
    _ -> panic as "expected read boundary failure"
  }
}

pub fn file_effect_missing_path_is_unknown_test() {
  let path = files.normalize_path(True, ["missing.txt"])
  let state = files.ExternalFileState([], [], [])
  let read_result =
    files.read(files.ReadReq(path, file_world(), files.Digests([]), state, 0))
  case read_result {
    core.Rejected(core.UnknownResource(_)) -> Nil
    _ -> panic as "expected unknown resource rejection"
  }
}

pub fn file_effect_host_boundary_test() {
  host_file_adapter.host_file_adapter_test()
}
