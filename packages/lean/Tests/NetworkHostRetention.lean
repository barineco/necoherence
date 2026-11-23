-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.NetworkHostRetention

namespace Necoherence

private def hLogical : RequestIdentity :=
  { kind := "network", provenance := "H", revision := 1 }
private def hKey : AttemptIdentity := { logical := hLogical, ordinal := 0 }
private def hOtherKey : AttemptIdentity := { logical := hLogical, ordinal := 1 }
private def hConfiguration : HostConfiguration :=
  { requestBodyLimit := 32, responseBodyLimit := 32, cancellation := none, monotonicClock := none }
private def hInput : AttemptInput :=
  { attempt := hKey,
    instruction := { method := "GET", target := "https://example.test/h", headers := [], body := [] },
    deadline := none, configuration := hConfiguration }
private def hHandle : ExecutionHandle := { value := "handle-H" }
private def hStartedRecord : AttemptRecord :=
  ⟨hInput, .Root, .Started hHandle, none, []⟩
private def hTerminal : NetworkTerminal :=
  { outcome := .Response { status := 200, headers := [], body := [] } .WireObserved,
    effect := .Unknown .NoResponse }
private def hSettledRecord : AttemptRecord :=
  { hStartedRecord with disposition := .Settled (some hHandle) hTerminal }
private def hStarted : NetworkState := { attempts := [hStartedRecord] }
private def hSettled : NetworkState := { attempts := [hSettledRecord] }
private def hEmpty : NetworkState := { attempts := [] }

private def idle : AttemptIdentity → Bool := fun _ => false
private def busy : AttemptIdentity → Bool := fun _ => true

private def isRetain (reasons : List (NecoQuotient.RetentionReason AttemptIdentity Unit HostRecordObservation))
    (expected : List (NecoQuotient.RetentionReason AttemptIdentity Unit HostRecordObservation)) :
    Bool :=
  match reasons, expected with
  | [.futureUse a], [.futureUse b] => a == b
  | [.outstandingEffect a], [.outstandingEffect b] => a == b
  | _, _ => false

private def retainsOnly (state : NetworkState) (running : AttemptIdentity → Bool)
    (expected : List (NecoQuotient.RetentionReason AttemptIdentity Unit HostRecordObservation)) : Bool :=
  match releaseHostRecord state running hKey with
  | .retain reasons => isRetain reasons expected
  | _ => false

private def dematerializes (state : NetworkState) (running : AttemptIdentity → Bool)
    (key : AttemptIdentity) : Bool :=
  match releaseHostRecord state running key with
  | .dematerialize _ => true
  | _ => false

example : retainsOnly hStarted idle [.futureUse hKey] = true := by decide
example : retainsOnly hSettled busy [.outstandingEffect hKey] = true := by decide
example : dematerializes hSettled idle hKey = true := by decide
example : dematerializes hEmpty idle hOtherKey = true := by decide

end Necoherence
