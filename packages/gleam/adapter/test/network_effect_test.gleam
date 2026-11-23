// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import neco_quotient_retention as retention
import necoherence/network_effect as effect
import necoherence/request_progression as progression

fn identity() -> effect.RequestIdentity {
  progression.RequestIdentity("runner", "test", 0)
}

fn input() -> effect.AttemptInput {
  effect.AttemptInput(
    effect.AttemptIdentity(identity(), 0),
    effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<>>),
    None,
    effect.HostConfiguration(0, 1024, None, None),
  )
}

pub fn construction_rejects_duplicate_attempt_keys_test() {
  let record =
    effect.AttemptRecord(input(), effect.Root, effect.Prepared, None, [])
  assert effect.network_state_of([record, record])
    == Error(effect.DuplicateAttemptKey(effect.AttemptIdentity(identity(), 0)))
}

pub fn construction_reports_the_first_failed_state_check_test() {
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
  assert effect.network_state_of([record])
    == Error(effect.DeliveryLogMismatch(key))
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
  assert effect.network_attempts(issued_state) |> list_length == 1
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
  chain: effect.AttemptChain,
) -> effect.AttemptRecord {
  effect.AttemptRecord(
    effect.AttemptInput(
      attempt,
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<>>),
      None,
      effect.HostConfiguration(0, 1024, None, None),
    ),
    chain,
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
  chain: effect.AttemptChain,
) -> effect.AttemptRecord {
  effect.AttemptRecord(
    effect.AttemptInput(
      attempt,
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<>>),
      None,
      effect.HostConfiguration(0, 1024, None, None),
    ),
    chain,
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
  assert effect.network_state_of([record_l0, record_m0, record_m1, record_l2])
    == Error(effect.ChainMismatch(l2))
}

pub fn prepare_rejects_a_body_that_is_not_a_byte_sequence_test() {
  let unaligned =
    effect.AttemptInput(
      effect.AttemptIdentity(identity(), 0),
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<1:size(4)>>),
      None,
      effect.HostConfiguration(8, 8, None, None),
    )
  assert effect.prepare(effect.empty_state(), unaligned)
    == effect.PrepareRejected(
      effect.empty_state(),
      effect.InvalidWireInstruction("GET"),
    )
}

pub fn prepare_rejects_a_header_value_that_is_not_a_byte_sequence_test() {
  let unaligned =
    effect.AttemptInput(
      effect.AttemptIdentity(identity(), 0),
      effect.HttpWireInstruction(
        "GET",
        "http://127.0.0.1/",
        [effect.RawHeaderField("x-a", <<1:size(3)>>)],
        <<>>,
      ),
      None,
      effect.HostConfiguration(8, 8, None, None),
    )
  assert effect.prepare(effect.empty_state(), unaligned)
    == effect.PrepareRejected(
      effect.empty_state(),
      effect.InvalidWireInstruction("GET"),
    )
}

fn started_state() -> #(
  effect.NetworkState,
  effect.AttemptIdentity,
  effect.ExecutionHandle,
) {
  let assert effect.PreparedResult(prepared_state, prepared) =
    effect.prepare(effect.empty_state(), input())
  let assert effect.CommandReady(issued_state, _) =
    effect.send_command(prepared_state, prepared)
  let key = prepared.input.attempt
  let handle = effect.ExecutionHandle("test-handle")
  let assert effect.StartedStep(state, _) =
    effect.observe_start(
      issued_state,
      prepared,
      effect.StartedObservation(key, handle),
    )
  #(state, key, handle)
}

fn settled_state() -> #(effect.NetworkState, effect.AttemptIdentity) {
  let #(state, key, handle) = started_state()
  let response =
    effect.ResponseObservation(
      key,
      handle,
      effect.NoSource,
      effect.RawHttpResponse(200, [], <<2, 3>>),
      effect.LibraryNormalized,
      effect.Unknown(effect.NoResponse),
    )
  let assert effect.TerminalStep(settled, _) =
    effect.observe(state, effect.Delivered(0, response))
  #(settled, key)
}

pub fn started_record_is_retained_only_for_future_use_test() {
  let #(state, key, _) = started_state()
  assert effect.host_awaits(state, key)
  assert !effect.host_settled(state, key)
  assert effect.release_host_record(state, fn(_) { False }, key)
    == retention.Retain([retention.FutureUse(key)])
}

pub fn settled_record_with_a_running_worker_is_retained_only_for_the_outstanding_effect_test() {
  let #(state, key) = settled_state()
  assert !effect.host_awaits(state, key)
  assert effect.host_settled(state, key)
  assert effect.release_host_record(state, fn(_) { True }, key)
    == retention.Retain([retention.OutstandingEffect(key)])
}

pub fn settled_record_without_a_running_worker_may_be_discarded_test() {
  let #(state, key) = settled_state()
  assert effect.release_host_record(state, fn(_) { False }, key)
    == retention.Dematerialize(
      retention.DematerializeWitness(key, retention.Irrecoverable, [
        effect.Undelivered,
        effect.DeliveryOrdinal,
      ]),
    )
}

pub fn missing_record_without_a_running_worker_may_be_discarded_test() {
  let key = effect.AttemptIdentity(identity(), 0)
  let state = effect.empty_state()
  assert !effect.host_awaits(state, key)
  assert !effect.host_settled(state, key)
  assert effect.release_host_record(state, fn(_) { False }, key)
    == retention.Dematerialize(
      retention.DematerializeWitness(key, retention.Irrecoverable, [
        effect.Undelivered,
        effect.DeliveryOrdinal,
      ]),
    )
}
