// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/request_progression as rp

fn identity(revision: Int) -> rp.RequestIdentity {
  rp.RequestIdentity("kind", "test", revision)
}

fn budget() -> rp.ResourceBudget {
  rp.ResourceBudget(
    rp.ConfiguredSafetyLimit("pending", 100),
    rp.ConfiguredSafetyLimit("in-flight", 100),
    rp.ConfiguredSafetyLimit("concurrent", 100),
  )
}

fn footprint(effect_class: rp.RequestEffectClass) -> rp.RequestFootprint {
  rp.RequestFootprint([], [], effect_class)
}

fn request(revision: Int, ordered: Bool) -> rp.RequestInput {
  let permission = case ordered {
    True -> rp.Ordered(identity(revision), [])
    False -> rp.Permitted(identity(revision), [])
  }
  rp.RequestInput(
    identity(revision),
    footprint(case ordered {
      True -> rp.OrderedEffect
      False -> rp.PureEffect
    }),
    rp.ResourceDemand(revision + 1, 1, 2),
    permission,
  )
}

fn evidence() -> rp.EvidenceVersion {
  rp.EvidenceVersion("evidence", "digest", "path")
}

fn handle(revision: Int) -> rp.ExecutionHandle {
  rp.ExecutionHandle("handle-" <> rp_int(revision))
}

fn rp_int(value: Int) -> String {
  case value {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    _ -> "n"
  }
}

fn next_snapshots(
  snapshot: rp.RequestProgressionSnapshot,
) -> List(rp.RequestProgressionSnapshot) {
  let next_revision = list.length(rp.progression_entries(snapshot))
  let submissions =
    list.filter_map([False, True], fn(ordered) {
      case rp.submit(snapshot, request(next_revision, ordered)) {
        rp.SubmitAccepted(next, _) -> Ok(next)
        rp.SubmitRejected(_, _) -> Error(Nil)
      }
    })
  let per_entry =
    list.flat_map(rp.progression_entries(snapshot), fn(entry) {
      entries_next(snapshot, entry)
    })
  list.append(submissions, per_entry)
}

fn entries_next(
  snapshot: rp.RequestProgressionSnapshot,
  entry: rp.RequestEntry,
) -> List(rp.RequestProgressionSnapshot) {
  let id = entry.identity
  let revision = id.revision
  case entry.phase {
    rp.Pending ->
      list.filter_map(
        [
          rp.decide_start(
            snapshot,
            rp.Accepted(id),
            rp.ExecuteNow(id, evidence(), 1),
          ),
          rp.decide_start(
            snapshot,
            rp.Accepted(id),
            rp.RemainPending(id, evidence(), 1),
          ),
        ],
        fn(result) {
          case result {
            rp.Execute(next, _, _) | rp.Deferred(next, _) -> Ok(next)
            rp.StartDecisionRejected(_, _) -> Error(Nil)
          }
        },
      )
      |> list.append(case rp.decide_cancel(snapshot, id) {
        rp.CancelledDecision(next, _) -> [next]
        _ -> []
      })
    rp.Preparing ->
      list.filter_map(
        [
          rp.apply_start_observation(
            snapshot,
            rp.Starting(id, rp.StartCommand(id, entry.footprint)),
            rp.AppliedSignal(rp.Started(id, handle(revision))),
          ),
          rp.apply_start_observation(
            snapshot,
            rp.Starting(id, rp.StartCommand(id, entry.footprint)),
            rp.AdapterFailed(rp.StartAdapterFailure(id, "failed")),
          ),
        ],
        fn(result) {
          case result {
            rp.StartObservationPublishing(next, _) -> Ok(next)
            rp.StartObservationFailed(next, _) -> Ok(next)
          }
        },
      )
    rp.Publishing -> {
      let running = rp.Running(id, handle(revision))
      list.map(
        [
          rp.AppliedSignal(rp.Completed(id, handle(revision), Nil)),
          rp.AppliedSignal(rp.CancelledAtAdapter(id, handle(revision))),
          rp.AdapterFailed(rp.CompletionAdapterFailure(
            id,
            handle(revision),
            "failed",
          )),
        ],
        fn(observed) {
          case rp.apply_completion_observation(snapshot, running, observed) {
            rp.CompletionApplied(next, _, _)
            | rp.CompletionSuperseded(next, _)
            | rp.CompletionCancelled(next, _)
            | rp.CompletionObservationFailed(next, _) -> next
          }
        },
      )
    }
    _ -> []
  }
}

fn totals_from_entries(
  snapshot: rp.RequestProgressionSnapshot,
  keep: fn(rp.RequestPhase) -> Bool,
) -> rp.ResourceDemand {
  list.fold(
    list.filter(rp.progression_entries(snapshot), fn(entry) {
      keep(entry.phase)
    }),
    rp.ResourceDemand(0, 0, 0),
    fn(total, entry) {
      rp.ResourceDemand(
        total.pending + entry.demand.pending,
        total.in_flight + entry.demand.in_flight,
        total.concurrent + entry.demand.concurrent,
      )
    },
  )
}

fn keeps_invariant(snapshot: rp.RequestProgressionSnapshot) -> Bool {
  rp.snapshot_of(
    rp.progression_policy(snapshot),
    rp.progression_budget(snapshot),
    rp.progression_current_identity(snapshot),
    rp.progression_entries(snapshot),
    rp.progression_revision(snapshot),
  )
  == Ok(snapshot)
  && rp.derive_pending(snapshot)
  == totals_from_entries(snapshot, fn(phase) { phase == rp.Pending })
  && rp.derive_in_flight(snapshot)
  == totals_from_entries(snapshot, fn(phase) {
    phase == rp.Preparing || phase == rp.Publishing
  })
  && rp.derive_concurrent(snapshot)
  == totals_from_entries(snapshot, fn(phase) { phase == rp.Publishing })
}

fn check_sequences(
  snapshot: rp.RequestProgressionSnapshot,
  depth: Int,
) -> Bool {
  keeps_invariant(snapshot)
  && case depth {
    0 -> True
    _ ->
      list.all(next_snapshots(snapshot), fn(next) {
        check_sequences(next, depth - 1)
      })
  }
}

pub fn construction_rejects_duplicate_identities_test() {
  let entry =
    rp.RequestEntry(
      identity(1),
      footprint(rp.PureEffect),
      rp.ResourceDemand(1, 0, 0),
      rp.Pending,
      rp.Permitted(identity(1), []),
      None,
      None,
    )
  assert rp.snapshot_of(rp.Fifo, budget(), None, [entry, entry], 0)
    == Error(rp.DuplicateIdentity(identity(1)))
}

pub fn generated_operation_sequences_keep_the_snapshot_invariant_test() {
  [rp.LatestWins, rp.Fifo, rp.AllExecute]
  |> list.each(fn(policy) {
    assert check_sequences(rp.empty(policy, budget()), 4)
  })
}

pub fn fifo_start_is_blocked_exactly_after_the_first_pending_entry_test() {
  let assert rp.SubmitAccepted(one, _) =
    rp.submit(rp.empty(rp.Fifo, budget()), request(1, False))
  let assert rp.SubmitAccepted(two, _) = rp.submit(one, request(2, False))
  let selection = fn(revision) {
    rp.ExecuteNow(identity(revision), evidence(), 1)
  }
  assert case rp.decide_start(two, rp.Accepted(identity(2)), selection(2)) {
    rp.StartDecisionRejected(_, rp.StartPolicyOrderBlocked(_)) -> True
    _ -> False
  }
  assert case rp.decide_start(two, rp.Accepted(identity(1)), selection(1)) {
    rp.Execute(_, _, _) -> True
    _ -> False
  }
  assert rp.find_request(two, identity(2)) != None
  assert Some(identity(2)) == rp.progression_current_identity(two)
}
