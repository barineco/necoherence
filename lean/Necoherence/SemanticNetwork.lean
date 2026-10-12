-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticExecution
import Necoherence.NetworkEffect

namespace Necoherence.SemanticNetwork

open Necoherence.SemanticExecution

structure NetworkBinding (α β : Type) where
  state : IO.Ref NetworkState
  encode : α → Except ExecutionFailure AttemptInput
  decode : RawHttpResponse → Except ExecutionFailure β
  start : SendCommand → IO StartObservation
  observe : StartedAttempt → IO HostObservation

def call (binding : NetworkBinding α β) (value : α) : IO (Except ExecutionFailure β) :=
  (do
    let input ← ExceptT.mk (pure (binding.encode value))
    let state ← liftM (binding.state.get : IO NetworkState)
    let (state, token) ← match Necoherence.prepare state input with
      | .Prepared state token => pure (state, token)
      | .Rejected _ failure => throw (.network failure)
    liftM (binding.state.set state : IO Unit)
    let (state, command) ← match sendCommand state token with
      | .CommandReady state command => pure (state, command)
      | .Rejected _ failure => throw (.network failure)
    liftM (binding.state.set state : IO Unit)
    let start ← liftM (binding.start command)
    let (state, started) ← match observeStart state token start with
      | .Started state started => pure (state, started)
      | .Terminal state settled => do
        liftM (binding.state.set state : IO Unit)
        throw (.networkTerminal settled.terminal)
      | .Rejected _ failure => throw (.network failure)
      | _ => throw (.invalidPlan "network start result")
    liftM (binding.state.set state : IO Unit)
    let observation ← liftM (binding.observe started)
    match Necoherence.observe state observation with
    | .Terminal state settled => do
      liftM (binding.state.set state : IO Unit)
      match settled.terminal.outcome with
      | .Response response _ =>
        ExceptT.mk (pure (binding.decode response))
      | _ => throw (.networkTerminal settled.terminal)
    | .Pending state started => do
      liftM (binding.state.set state : IO Unit)
      throw (.networkPending started)
    | .Rejected _ failure => throw (.network failure)
    | _ => throw (.invalidPlan "network observation result")
    : ExceptT ExecutionFailure IO β).run

end Necoherence.SemanticNetwork
