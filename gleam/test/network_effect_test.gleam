// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/network_effect as effect
import necoherence/request_progression as progression

fn identity() -> effect.RequestIdentity {
  progression.RequestIdentity("runner", "test", 0)
}

fn input() -> effect.AttemptInput {
  effect.AttemptInput(
    effect.AttemptIdentity(identity(), 0),
    effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], []),
    None,
    effect.HostConfiguration(0, 1024, None, None),
  )
}

pub fn read_invalid_state_returns_original_state_test() {
  let record =
    effect.AttemptRecord(input(), effect.Root, effect.Prepared, None, [])
  let state = effect.NetworkState([record, record])
  assert effect.read_network_state(state)
    == effect.ReadRejected(
      state,
      effect.InvalidNetworkState(
        effect.DuplicateAttemptKey(effect.AttemptIdentity(identity(), 0)),
      ),
    )
}

pub fn read_reports_the_first_failed_state_check_test() {
  let key = effect.AttemptIdentity(identity(), 0)
  let observation =
    effect.CancellationObservation(
      key,
      effect.ExecutionHandle("unexpected"),
      effect.NoSource,
      effect.Unknown(effect.NoResponse),
    )
  let record =
    effect.AttemptRecord(
      input(),
      effect.Root,
      effect.Prepared,
      Some(effect.DeliveredObservation(0, observation)),
      [],
    )
  let state = effect.NetworkState([record])
  assert effect.read_network_state(state)
    == effect.ReadRejected(
      state,
      effect.InvalidNetworkState(effect.DeliveryLogMismatch(key)),
    )
}

pub fn send_classifies_missing_and_already_issued_test() {
  let prepared = effect.PreparedAttempt(input(), effect.Root)
  let empty = effect.empty_state()
  assert effect.send_command(empty, prepared)
    == effect.CommandRejected(
      empty,
      effect.UnknownAttempt(prepared.input.attempt),
    )

  let assert effect.PreparedResult(prepared_state, authoritative) =
    effect.prepare(empty, input())
  let assert effect.CommandReady(issued_state, _) =
    effect.send_command(prepared_state, authoritative)
  assert effect.send_command(issued_state, authoritative)
    == effect.CommandRejected(
      issued_state,
      effect.CommandAlreadyIssued(authoritative.input.attempt),
    )
}

pub fn cancel_classifies_handle_mismatch_test() {
  let assert effect.PreparedResult(prepared_state, prepared) =
    effect.prepare(effect.empty_state(), input())
  let assert effect.CommandReady(issued_state, _) =
    effect.send_command(prepared_state, prepared)
  let expected = effect.ExecutionHandle("expected")
  let assert effect.StartedStep(started_state, started) =
    effect.observe_start(
      issued_state,
      prepared,
      effect.StartedObservation(prepared.input.attempt, expected),
    )
  let supplied =
    effect.StartedAttempt(started.prepared, effect.ExecutionHandle("supplied"))
  assert effect.cancel_command(started_state, supplied)
    == effect.CommandRejected(
      started_state,
      effect.HandleMismatch(expected, supplied.handle),
    )
}

pub fn delivered_observation_classifies_unknown_attempt_test() {
  let key = effect.AttemptIdentity(identity(), 0)
  let observation =
    effect.Delivered(
      0,
      effect.CancellationObservation(
        key,
        effect.ExecutionHandle("missing"),
        effect.NoSource,
        effect.Unknown(effect.NoResponse),
      ),
    )
  assert effect.observe(effect.empty_state(), observation)
    == effect.NetworkRejected(effect.empty_state(), effect.UnknownAttempt(key))
}

pub fn prepare_send_start_and_pending_are_typed_test() {
  let state = effect.empty_state()
  let assert effect.PreparedResult(prepared_state, prepared) =
    effect.prepare(state, input())
  let assert effect.CommandReady(issued_state, command) =
    effect.send_command(prepared_state, prepared)
  assert issued_state.attempts |> list_length == 1
  assert command.prepared == prepared
}

fn list_length(values: List(a)) -> Int {
  case values {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn logical(provenance: String) -> effect.RequestIdentity {
  progression.RequestIdentity("runner", provenance, 0)
}

fn settled_record(
  attempt: effect.AttemptIdentity,
  lineage: effect.AttemptLineage,
) -> effect.AttemptRecord {
  effect.AttemptRecord(
    effect.AttemptInput(
      attempt,
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], []),
      None,
      effect.HostConfiguration(0, 1024, None, None),
    ),
    lineage,
    effect.Settled(
      None,
      effect.NetworkTerminal(
        effect.Cancelled,
        effect.Unknown(effect.NoResponse),
      ),
    ),
    None,
    [],
  )
}

fn prepared_record(
  attempt: effect.AttemptIdentity,
  lineage: effect.AttemptLineage,
) -> effect.AttemptRecord {
  effect.AttemptRecord(
    effect.AttemptInput(
      attempt,
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], []),
      None,
      effect.HostConfiguration(0, 1024, None, None),
    ),
    lineage,
    effect.Prepared,
    None,
    [],
  )
}

pub fn read_rejects_retry_authorization_crossing_logicals_test() {
  let l = logical("L")
  let m = logical("M")
  let l0 = effect.AttemptIdentity(l, 0)
  let m0 = effect.AttemptIdentity(m, 0)
  let m1 = effect.AttemptIdentity(m, 1)
  let l2 = effect.AttemptIdentity(l, 2)
  let record_l0 = settled_record(l0, effect.Root)
  let record_m0 = settled_record(m0, effect.Root)
  let record_m1 =
    settled_record(
      m1,
      effect.RetryOf(effect.RetryAuthorization(
        m,
        m0,
        m1,
        effect.OpaqueEvidence("e1"),
      )),
    )
  let record_l2 =
    prepared_record(
      l2,
      effect.RetryOf(effect.RetryAuthorization(
        l,
        m1,
        l2,
        effect.OpaqueEvidence("e2"),
      )),
    )
  let state = effect.NetworkState([record_l0, record_m0, record_m1, record_l2])
  assert effect.read_network_state(state)
    == effect.ReadRejected(
      state,
      effect.InvalidNetworkState(effect.LineageMismatch(l2)),
    )
}
