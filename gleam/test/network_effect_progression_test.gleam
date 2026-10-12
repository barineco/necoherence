// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None}
import necoherence/network_effect as effect
import necoherence/request_progression as progression

pub fn network_attempt_keeps_request_identity_test() {
  let logical = progression.RequestIdentity("kind", "test", 1)
  let input =
    effect.AttemptInput(
      effect.AttemptIdentity(logical, 0),
      effect.HttpWireInstruction("GET", "http://127.0.0.1/", [], []),
      None,
      effect.HostConfiguration(0, 0, None, None),
    )
  let assert effect.PreparedResult(state, prepared) =
    effect.prepare(effect.empty_state(), input)
  assert prepared.input.attempt.logical == logical
  assert state.attempts
    == [effect.AttemptRecord(input, effect.Root, effect.Prepared, None, [])]
}
