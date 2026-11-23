// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/network_effect as effect

fn logical(index: Int) -> effect.RequestIdentity {
  effect.request_identity("kind", "test", index)
}

fn attempt(index: Int, ordinal: Int) -> effect.AttemptIdentity {
  effect.AttemptIdentity(logical(index), ordinal)
}

fn handle() -> effect.ExecutionHandle {
  effect.ExecutionHandle("handle")
}

fn configuration() -> effect.HostConfiguration {
  effect.HostConfiguration(
    64,
    64,
    Some(effect.CancellationCapability(effect.OpaqueEvidence("cancel"))),
    None,
  )
}

fn input(identity: effect.AttemptIdentity) -> effect.AttemptInput {
  effect.AttemptInput(
    identity,
    effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], <<>>),
    None,
    configuration(),
  )
}

fn cancellation(
  identity: effect.AttemptIdentity,
  delivery: Int,
) -> effect.HostObservation {
  effect.Delivered(
    delivery,
    effect.CancellationObservation(
      identity,
      handle(),
      effect.NoSource,
      effect.Unknown(effect.NoResponse),
    ),
  )
}

fn witness(identity: effect.AttemptIdentity) -> effect.EffectWitness {
  effect.EffectWitness(identity, effect.Adapter, effect.OpaqueEvidence("w"))
}

fn next_states(state: effect.NetworkState) -> List(effect.NetworkState) {
  let records = effect.network_attempts(state)
  let fresh = case
    effect.prepare(state, input(attempt(list.length(records), 0)))
  {
    effect.PreparedResult(next, _) -> [next]
    effect.PrepareRejected(_, _) -> []
  }
  list.append(
    fresh,
    list.flat_map(records, fn(record) { record_next(state, record) }),
  )
}

fn record_next(
  state: effect.NetworkState,
  record: effect.AttemptRecord,
) -> List(effect.NetworkState) {
  let identity = record.input.attempt
  let prepared = effect.PreparedAttempt(record.input, record.chain)
  case record.disposition {
    effect.Prepared ->
      case effect.send_command(state, prepared) {
        effect.CommandReady(next, _) -> [next]
        effect.CommandRejected(_, _) -> []
      }
    effect.CommandIssued ->
      list.filter_map(
        [
          effect.observe_start(
            state,
            prepared,
            effect.StartedObservation(identity, handle()),
          ),
          effect.observe_start(
            state,
            prepared,
            effect.StartFailed(
              effect.NetworkHostFailure(
                identity,
                effect.Start,
                record.input.configuration,
                effect.ExecutionStartFailed,
              ),
              effect.Unknown(effect.NoResponse),
            ),
          ),
        ],
        step_state,
      )
    effect.Started(_) ->
      list.filter_map(
        [
          effect.observe(state, cancellation(identity, 0)),
          effect.observe(state, effect.Pending(identity, handle())),
        ],
        step_state,
      )
    effect.Settled(_, _) -> {
      let retried = case record.chain, identity.ordinal {
        effect.Root, 0 ->
          case
            effect.retry(
              state,
              effect.RetryRequest(
                effect.RetryAllowed(effect.RetryAuthorization(
                  identity.logical,
                  identity,
                  effect.AttemptIdentity(identity.logical, 1),
                  effect.OpaqueEvidence("retry"),
                )),
                record.input.instruction,
                None,
                record.input.configuration,
              ),
            )
          {
            effect.PreparedResult(next, _) -> [next]
            effect.PrepareRejected(_, _) -> []
          }
        _, _ -> []
      }
      let annotated = case
        effect.annotate_effect(
          state,
          effect.EffectObservation(
            identity,
            effect.EffectOccurred(witness(identity)),
          ),
        )
      {
        effect.Applied(next) -> [next]
        effect.StateRejected(_, _) -> []
      }
      let late =
        list.filter_map(
          [effect.observe(state, cancellation(identity, 1))],
          step_state,
        )
      list.flatten([retried, annotated, late])
    }
  }
}

fn step_state(step: effect.NetworkStep) -> Result(effect.NetworkState, Nil) {
  case step {
    effect.StartedStep(next, _)
    | effect.TerminalStep(next, _)
    | effect.LateStep(next, _, _)
    | effect.PendingStep(next, _)
    | effect.DuplicateStep(next, _, _) -> Ok(next)
    effect.NetworkRejected(_, _) -> Error(Nil)
  }
}

fn keeps_invariant(state: effect.NetworkState) -> Bool {
  effect.network_state_of(effect.network_attempts(state)) == Ok(state)
}

fn check_sequences(state: effect.NetworkState, depth: Int) -> Bool {
  keeps_invariant(state)
  && case depth {
    0 -> True
    _ ->
      list.all(next_states(state), fn(next) { check_sequences(next, depth - 1) })
  }
}

pub fn generated_operation_sequences_keep_the_state_invariant_test() {
  assert check_sequences(effect.empty_state(), 5)
}

pub fn retry_chain_is_reachable_by_generated_sequences_test() {
  assert list.any(reachable(effect.empty_state(), 5), fn(state) {
    list.length(effect.network_attempts(state)) == 2
    && list.any(effect.network_attempts(state), fn(record) {
      record.chain != effect.Root
    })
  })
}

fn reachable(
  state: effect.NetworkState,
  depth: Int,
) -> List(effect.NetworkState) {
  case depth {
    0 -> [state]
    _ -> [
      state,
      ..list.flat_map(next_states(state), fn(next) {
        reachable(next, depth - 1)
      })
    ]
  }
}
