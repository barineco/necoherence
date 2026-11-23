-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.NetworkEffect
import NecoQuotient.Retention

namespace Necoherence

/-- The two observations a host adapter's per-attempt record holds. -/
inductive HostRecordObservation where
  | undelivered
  | deliveryOrdinal
  deriving DecidableEq, Repr

/-- True when the core state still lets the attempt's host observation be requested: a record exists and is not settled. -/
def hostAwaits (state : NetworkState) (key : AttemptIdentity) : Bool :=
  match lookupAttempt state key with
  | some record =>
      match record.disposition with
      | .Settled _ _ => false
      | _ => true
  | none => false

/-- True when the attempt has a record and the core no longer awaits it, so a later `prepare` cannot reopen it. -/
def hostSettled (state : NetworkState) (key : AttemptIdentity) : Bool :=
  match lookupAttempt state key with
  | some record =>
      match record.disposition with
      | .Settled _ _ => true
      | _ => false
  | none => false

/-- The erasure request for one attempt's host record: both observations are removed, none is preserved. -/
def hostRecordRequest (key : AttemptIdentity) :
    NecoQuotient.ErasureRequest AttemptIdentity Unit HostRecordObservation :=
  { target := key,
    targetBasis := none,
    removedObservations := [.undelivered, .deliveryOrdinal],
    preservedObservations := [] }

/-- Live membership: a future use is a non-settled record, an outstanding effect is a running worker. -/
def hostRecordMembership (state : NetworkState) (running : AttemptIdentity → Bool) :
    NecoQuotient.LiveMembership AttemptIdentity Unit :=
  { activeBasis := fun _ => false,
    branchRoot := fun _ => false,
    futureUse := fun key => hostAwaits state key,
    outstandingEffect := running,
    outstandingSignal := fun _ => false }

/-- A discarded host record cannot be restored. -/
def hostRecordRecoverability : Option (NecoQuotient.Recoverability Unit Unit) := some .irrecoverable

/-- Judge whether one attempt's host record may be discarded. -/
def releaseHostRecord (state : NetworkState) (running : AttemptIdentity → Bool) (key : AttemptIdentity) :=
  NecoQuotient.judgeErasureBy (hostRecordRequest key) (hostRecordMembership state running)
    hostRecordRecoverability

theorem releaseHostRecord_dematerialize_iff (state : NetworkState)
    (running : AttemptIdentity → Bool) (key : AttemptIdentity) :
    (∃ witness, releaseHostRecord state running key = .dematerialize witness) ↔
      (hostAwaits state key = false ∧ running key = false) := by
  unfold releaseHostRecord
  rw [NecoQuotient.judgeErasureBy_dematerialize_iff]
  simp [NecoQuotient.InputsComplete, hostRecordRequest, hostRecordMembership,
    hostRecordRecoverability]

theorem releaseHostRecord_retention_reasons (state : NetworkState)
    (running : AttemptIdentity → Bool) (key : AttemptIdentity)
    (reasons : List (NecoQuotient.RetentionReason AttemptIdentity Unit HostRecordObservation))
    (h : releaseHostRecord state running key = .retain reasons) :
    (∀ reason, reason ∈ reasons →
        reason = .futureUse key ∨ reason = .outstandingEffect key) ∧
      (hostAwaits state key = true → .futureUse key ∈ reasons) ∧
      (running key = true → .outstandingEffect key ∈ reasons) := by
  have hdef : releaseHostRecord state running key =
      NecoQuotient.decideWithBy (hostRecordRequest key) (hostRecordMembership state running)
        (K := Unit) (W := Unit) .irrecoverable := by
    simp [releaseHostRecord, NecoQuotient.judgeErasureBy, hostRecordRecoverability,
      hostRecordRequest]
  rw [hdef] at h
  unfold NecoQuotient.decideWithBy at h
  have hrs : NecoQuotient.retentionReasonsBy (hostRecordRequest key)
      (hostRecordMembership state running) (NecoQuotient.Recoverability.irrecoverable (K := Unit) (W := Unit)) =
      (if hostAwaits state key then [NecoQuotient.RetentionReason.futureUse key] else []) ++
      (if running key then [NecoQuotient.RetentionReason.outstandingEffect key] else []) := by
    simp [NecoQuotient.retentionReasonsBy, hostRecordRequest, hostRecordMembership]
  rw [hrs] at h
  cases ha : hostAwaits state key <;> cases hr : running key <;> simp [ha, hr] at h <;>
    (subst h; simp)

theorem releaseHostRecord_never_rejected (state : NetworkState)
    (running : AttemptIdentity → Bool) (key : AttemptIdentity) (missing : NecoQuotient.MissingInput) :
    releaseHostRecord state running key ≠ .rejected missing := by
  simp [releaseHostRecord, NecoQuotient.judgeErasureBy, hostRecordRecoverability,
    hostRecordRequest, NecoQuotient.decideWithBy]
  split <;> simp

theorem settled_idle_record_is_released (state : NetworkState)
    (running : AttemptIdentity → Bool) (key : AttemptIdentity)
    (record : AttemptRecord) (handle : Option ExecutionHandle) (terminal : NetworkTerminal)
    (found : lookupAttempt state key = some record)
    (settled : record.disposition = .Settled handle terminal)
    (idle : running key = false) :
    ∃ witness, releaseHostRecord state running key = .dematerialize witness := by
  rw [releaseHostRecord_dematerialize_iff]
  refine ⟨?_, idle⟩
  simp [hostAwaits, found, settled]

theorem settled_host_pending_unrelated(state : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (handle : Option ExecutionHandle) (terminal : NetworkTerminal)
    (found : lookupAttempt state key = some record)
    (settled : record.disposition = .Settled handle terminal)
    (executionHandle : ExecutionHandle) :
    ¬ HostObservationRelation state (.Pending key executionHandle) := by
  intro relation
  simp [HostObservationRelation, found, settled] at relation

theorem settled_cancel_rejected (state : NetworkState) (started : StartedAttempt)
    (record : AttemptRecord) (handle : Option ExecutionHandle) (terminal : NetworkTerminal)
    (found : lookupAttempt state started.prepared.input.attempt = some record)
    (settled : record.disposition = .Settled handle terminal) :
    ∃ failure, cancelCommand state started = .Rejected state failure := by
  unfold cancelCommand
  by_cases hs : StartedRelation state started
  · have h := hs.2
    simp only [found] at h
    rw [settled] at h
    cases h.2.2.1
  · rw [dif_neg hs]
    split
    · split <;> exact ⟨_, rfl⟩
    · exact ⟨_, rfl⟩

/-- Once the core no longer awaits an existing attempt, `observe` never makes it await again. -/
theorem host_awaits_false_is_stable_under_observe (state : NetworkState)
    (observation : HostObservation) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    hostAwaits (observeStepState state observation) key = false := by
  have settled : ∃ handle terminal, record.disposition = .Settled handle terminal := by
    unfold hostAwaits at closed
    rw [found] at closed
    cases hd : record.disposition with
    | Settled handle terminal => exact ⟨handle, terminal, rfl⟩
    | Prepared => simp [hd] at closed
    | CommandIssued => simp [hd] at closed
    | Started handle => simp [hd] at closed
  obtain ⟨handle, terminal, hs⟩ := settled
  obtain ⟨next, handle', terminal', hnext, hnextSettled⟩ :=
    observe_keeps_settled_record state observation key record handle terminal found hs
  unfold hostAwaits
  rw [hnext]
  simp [hnextSettled]

#print axioms host_awaits_false_is_stable_under_observe

private theorem host_closed_settled (state : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    ∃ handle terminal, record.disposition = .Settled handle terminal := by
  unfold hostAwaits at closed
  rw [found] at closed
  cases hd : record.disposition with
  | Settled handle terminal => exact ⟨handle, terminal, rfl⟩
  | Prepared => simp [hd] at closed
  | CommandIssued => simp [hd] at closed
  | Started handle => simp [hd] at closed

private theorem host_awaits_false_of_settled (state : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (handle : Option ExecutionHandle) (terminal : NetworkTerminal)
    (found : lookupAttempt state key = some record)
    (settled : record.disposition = .Settled handle terminal) :
    hostAwaits state key = false := by
  unfold hostAwaits
  rw [found]
  simp [settled]

private theorem host_awaits_false_of_lookup_eq (state state' : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false)
    (same : lookupAttempt state' key = some record) :
    hostAwaits state' key = false := by
  obtain ⟨handle, terminal, hs⟩ := host_closed_settled state key record found closed
  exact host_awaits_false_of_settled state' key record handle terminal same hs

private theorem host_lookup_key (state : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (found : lookupAttempt state key = some record) :
    record.input.attempt = key := by
  unfold lookupAttempt at found
  exact beq_iff_eq.mp (List.find?_eq_some_iff_getElem.mp found).1

private theorem host_lookup_append (state : NetworkState) (extra : List AttemptRecord)
    (state' : NetworkState) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (ext : state'.attempts = state.attempts ++ extra) :
    lookupAttempt state' key = some record := by
  unfold lookupAttempt at *
  rw [ext, List.find?_append, found]
  rfl

private theorem host_map_find_other (records : List AttemptRecord)
    (key target : AttemptIdentity) (replacement : AttemptRecord)
    (replacementKey : replacement.input.attempt = key) (different : target ≠ key) :
    (records.map (fun record => if record.input.attempt = key then replacement else record)).find?
        (fun record => record.input.attempt == target) =
      records.find? (fun record => record.input.attempt == target) := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
      by_cases recordKey : record.input.attempt = key
      · have recordNotTarget : ¬(record.input.attempt == target) = true := by
          intro equal
          exact different ((beq_iff_eq.mp equal).symm.trans recordKey)
        have replacementNotTarget : ¬(replacement.input.attempt == target) = true := by
          intro equal
          exact different ((beq_iff_eq.mp equal).symm.trans replacementKey)
        simp only [List.map_cons, if_pos recordKey]
        rw [List.find?_cons_of_neg (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
              (a := replacement) replacementNotTarget,
            List.find?_cons_of_neg (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
              (a := record) recordNotTarget, ih]
      · simp only [List.map_cons, if_neg recordKey]
        by_cases recordTarget : (record.input.attempt == target) = true
        · rw [List.find?_cons_of_pos (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget,
              List.find?_cons_of_pos (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget]
        · rw [List.find?_cons_of_neg (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget,
              List.find?_cons_of_neg (p := fun candidate : AttemptRecord => candidate.input.attempt == target)
                (a := record) recordTarget, ih]

private theorem host_map_find_self (records : List AttemptRecord) (key : AttemptIdentity)
    (replacement : AttemptRecord) (replacementKey : replacement.input.attempt = key)
    (old : AttemptRecord)
    (found : records.find? (fun record => record.input.attempt == key) = some old) :
    (records.map (fun record => if record.input.attempt = key then replacement else record)).find?
        (fun record => record.input.attempt == key) = some replacement := by
  induction records with
  | nil => simp at found
  | cons record rest ih =>
      by_cases same : record.input.attempt = key
      · simp [same, replacementKey]
      · have foundRest : rest.find? (fun item => item.input.attempt == key) = some old := by
          simpa [same] using found
        simpa [same] using ih foundRest

/-- Replacing the record at `k` keeps a closed attempt closed, unless the replacement lands on the closed attempt itself and is not settled. -/
private theorem host_awaits_false_replace (state : NetworkState) (k key : AttemptIdentity)
    (replacement record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false)
    (replacementKey : replacement.input.attempt = k)
    (onSelf : k = key → ∃ handle terminal, replacement.disposition = .Settled handle terminal) :
    hostAwaits (replaceRecord state k replacement) key = false := by
  by_cases hk : key = k
  · subst hk
    obtain ⟨handle, terminal, hs⟩ := onSelf rfl
    have : lookupAttempt (replaceRecord state key replacement) key = some replacement := by
      unfold lookupAttempt replaceRecord at *
      exact host_map_find_self state.attempts key replacement replacementKey record found
    exact host_awaits_false_of_settled _ key replacement handle terminal this hs
  · have : lookupAttempt (replaceRecord state k replacement) key = some record := by
      unfold lookupAttempt replaceRecord at *
      rw [host_map_find_other state.attempts k key replacement replacementKey hk]
      exact found
    exact host_awaits_false_of_lookup_eq state _ key record found closed this

/-- Once the core no longer awaits an existing attempt, `prepare` never makes it await again. -/
theorem host_awaits_false_is_stable_under_prepare (state : NetworkState) (input : AttemptInput)
    (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    (∀ next prepared, prepare state input = .Prepared next prepared →
      hostAwaits next key = false) ∧
    (∀ same failure, prepare state input = .Rejected same failure →
      hostAwaits same key = false) := by
  constructor
  · intro next prepared h
    unfold prepare at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact host_awaits_false_of_lookup_eq state _ key record found closed (host_lookup_append state _ _ key record found rfl))
      | cases h
  · intro same failure h
    unfold prepare at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact closed)
      | cases h

#print axioms host_awaits_false_is_stable_under_prepare

private theorem host_prepared_ready_not_settled (state : NetworkState) (prepared : PreparedAttempt)
    (key : AttemptIdentity) (record : AttemptRecord) (handle : Option ExecutionHandle)
    (terminal : NetworkTerminal) (found : lookupAttempt state key = some record)
    (settled : record.disposition = .Settled handle terminal)
    (ready : PreparedReady state prepared) (hk : prepared.input.attempt = key) : False := by
  obtain ⟨_, h⟩ := ready
  rw [hk, found] at h
  simp only at h
  rw [settled] at h
  cases h

/-- Once the core no longer awaits an existing attempt, `sendCommand` never makes it await again. -/
theorem host_awaits_false_is_stable_under_send_command (state : NetworkState)
    (prepared : PreparedAttempt) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    (∀ next command, sendCommand state prepared = .CommandReady next command →
      hostAwaits next key = false) ∧
    (∀ same failure, sendCommand state prepared = .Rejected same failure →
      hostAwaits same key = false) := by
  have settled := host_closed_settled state key record found closed
  constructor
  · intro next command h
    unfold sendCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (exact host_awaits_false_replace state prepared.input.attempt key _ record found closed (by first | rfl | (have hk := host_lookup_key state prepared.input.attempt _ ‹lookupAttempt state prepared.input.attempt = some _›; exact hk)) (by intro hk; exfalso; obtain ⟨handle, terminal, hs⟩ := settled; exact host_prepared_ready_not_settled state prepared key record handle terminal found hs ‹PreparedReady state prepared› hk))
      | (injection h with h1 h2; subst h1; exact host_awaits_false_replace state prepared.input.attempt key _ record found closed (by first | rfl | (have hk := host_lookup_key state prepared.input.attempt _ ‹lookupAttempt state prepared.input.attempt = some _›; exact hk)) (by intro hk; exfalso; obtain ⟨handle, terminal, hs⟩ := settled; exact host_prepared_ready_not_settled state prepared key record handle terminal found hs ‹PreparedReady state prepared› hk))
  · intro same failure h
    unfold sendCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact closed)
      | (split at h <;> first | (injection h with h1 h2; subst h1; exact closed) | cases h)
      | cases h

#print axioms host_awaits_false_is_stable_under_send_command

/-- Once the core no longer awaits an existing attempt, `cancelCommand` never makes it await again. -/
theorem host_awaits_false_is_stable_under_cancel_command (state : NetworkState)
    (started : StartedAttempt) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    (∀ same command, cancelCommand state started = .CommandReady same command →
      hostAwaits same key = false) ∧
    (∀ same failure, cancelCommand state started = .Rejected same failure →
      hostAwaits same key = false) := by
  constructor
  · intro same command h
    unfold cancelCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact closed)
      | (cases h; done)
  · intro same failure h
    unfold cancelCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact closed)
      | (cases h; done)

#print axioms host_awaits_false_is_stable_under_cancel_command

private theorem host_start_not_settled (state : NetworkState) (prepared : PreparedAttempt)
    (k key : AttemptIdentity) (handle' : ExecutionHandle) (record : AttemptRecord)
    (handle : Option ExecutionHandle) (terminal : NetworkTerminal)
    (found : lookupAttempt state key = some record)
    (settled : record.disposition = .Settled handle terminal)
    (relation : StartObservationRelation state prepared (.Started k handle'))
    (hk : k = key) : False := by
  obtain ⟨⟨_, issued⟩, same⟩ := relation
  have same' : prepared.input.attempt = key := same.symm.trans hk
  rw [same', found] at issued
  simp only at issued
  rw [settled] at issued
  cases issued

/-- Once the core no longer awaits an existing attempt, `observeStart` never makes it await again. -/
theorem host_awaits_false_is_stable_under_observe_start (state : NetworkState)
    (prepared : PreparedAttempt) (observation : StartObservation)
    (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    (∀ next started, observeStart state prepared observation = .Started next started →
      hostAwaits next key = false) ∧
    (∀ next started, observeStart state prepared observation = .Pending next started →
      hostAwaits next key = false) ∧
    (∀ next settled, observeStart state prepared observation = .Terminal next settled →
      hostAwaits next key = false) ∧
    (∀ next settled late, observeStart state prepared observation = .Late next settled late →
      hostAwaits next key = false) ∧
    (∀ next attempt delivery, observeStart state prepared observation = .Duplicate next attempt delivery →
      hostAwaits next key = false) ∧
    (∀ same failure, observeStart state prepared observation = .Rejected same failure →
      hostAwaits same key = false) := by
  have settled := host_closed_settled state key record found closed
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> (intros; rename_i h; cases observation <;> unfold observeStart at h <;> dsimp only at h <;> repeat' split at h) <;>
    first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact closed)
      | (injection h with h1; subst h1; exact closed)
      | ((try (injection h with h1; subst h1)); refine host_awaits_false_replace state _ key _ record found closed ?_ ?_
         · first | rfl | (have hk := host_lookup_key state _ _ ‹lookupAttempt state _ = some _›; exact hk) | exact (‹StartObservationRelation state prepared (.Started _ _)›.2).symm
         · first
             | (intro _; exact ⟨_, _, rfl⟩)
             | (intro hk; exfalso; obtain ⟨handle, terminal, hs⟩ := settled; exact host_start_not_settled state prepared _ key _ record handle terminal found hs (by assumption) hk))

#print axioms host_awaits_false_is_stable_under_observe_start

private theorem host_awaits_false_set_effect (state : NetworkState) (k : AttemptIdentity)
    (status : EffectStatus) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    hostAwaits
      (match lookupAttempt state k with
       | some record =>
           match record.disposition with
           | .Settled handle terminal =>
               replaceRecord state k
                 { record with disposition := .Settled handle { terminal with effect := status } }
           | _ => state
       | none => state) key = false := by
  split
  · rename_i target hk
    split
    · exact host_awaits_false_replace state k key _ record found closed
        (host_lookup_key state k target hk) (fun _ => ⟨_, _, rfl⟩)
    · exact closed
  · exact closed

/-- Once the core no longer awaits an existing attempt, `annotateEffect` never makes it await again. -/
theorem host_awaits_false_is_stable_under_annotate_effect (state : NetworkState)
    (observation : EffectObservation) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    (∀ next, annotateEffect state observation = .Applied next →
      hostAwaits next key = false) ∧
    (∀ same failure, annotateEffect state observation = .Rejected same failure →
      hostAwaits same key = false) := by
  constructor
  · intro next h
    unfold annotateEffect at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1; subst h1; exact closed)
      | (injection h with h1; subst h1; exact host_awaits_false_set_effect state _ _ key record found closed)
  · intro same failure h
    unfold annotateEffect at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact closed)

#print axioms host_awaits_false_is_stable_under_annotate_effect

/-- Once the core no longer awaits an existing attempt, `retry` never makes it await again. -/
theorem host_awaits_false_is_stable_under_retry (state : NetworkState) (request : RetryRequest)
    (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (closed : hostAwaits state key = false) :
    (∀ next prepared, retry state request = .Prepared next prepared →
      hostAwaits next key = false) ∧
    (∀ same failure, retry state request = .Rejected same failure →
      hostAwaits same key = false) := by
  constructor
  · intro next prepared h
    unfold retry at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact host_awaits_false_of_lookup_eq state _ key record found closed (host_lookup_append state _ _ key record found rfl))
  · intro same failure h
    unfold retry at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact closed)

#print axioms host_awaits_false_is_stable_under_retry

theorem host_settled_iff (state : NetworkState) (key : AttemptIdentity) :
    hostSettled state key = true ↔
      ((∃ record, lookupAttempt state key = some record) ∧ hostAwaits state key = false) := by
  unfold hostSettled hostAwaits
  cases h : lookupAttempt state key with
  | none => simp
  | some record =>
      simp only [h, exists_apply_eq_apply, true_and]
      generalize record.disposition = d
      cases d <;> simp

#print axioms host_settled_iff

theorem host_settled_not_awaited (state : NetworkState) (key : AttemptIdentity) :
    hostSettled state key = true → hostAwaits state key = false := by
  intro h
  exact ((host_settled_iff state key).mp h).2

#print axioms host_settled_not_awaited

private theorem host_settled_of_settled_record (state : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (handle : Option ExecutionHandle) (terminal : NetworkTerminal)
    (found : lookupAttempt state key = some record)
    (hs : record.disposition = .Settled handle terminal) :
    hostSettled state key = true := by
  unfold hostSettled
  rw [found]
  simp [hs]

private theorem host_settled_split (state : NetworkState) (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    ∃ record, lookupAttempt state key = some record ∧
      ∃ handle terminal, record.disposition = .Settled handle terminal := by
  obtain ⟨⟨record, found⟩, closed⟩ := (host_settled_iff state key).mp settled
  exact ⟨record, found, host_closed_settled state key record found closed⟩

private theorem host_settled_of_lookup_eq (state state' : NetworkState) (key : AttemptIdentity)
    (record : AttemptRecord) (found : lookupAttempt state key = some record)
    (settled : hostSettled state key = true)
    (same : lookupAttempt state' key = some record) :
    hostSettled state' key = true := by
  unfold hostSettled at *
  rw [found] at settled
  rw [same]
  exact settled

private theorem host_settled_replace (state : NetworkState) (k key : AttemptIdentity)
    (replacement record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (settled : hostSettled state key = true)
    (replacementKey : replacement.input.attempt = k)
    (onSelf : k = key → ∃ handle terminal, replacement.disposition = .Settled handle terminal) :
    hostSettled (replaceRecord state k replacement) key = true := by
  by_cases hk : key = k
  · subst hk
    obtain ⟨handle, terminal, hs⟩ := onSelf rfl
    have : lookupAttempt (replaceRecord state key replacement) key = some replacement := by
      unfold lookupAttempt replaceRecord at *
      exact host_map_find_self state.attempts key replacement replacementKey record found
    exact host_settled_of_settled_record _ key replacement handle terminal this hs
  · have : lookupAttempt (replaceRecord state k replacement) key = some record := by
      unfold lookupAttempt replaceRecord at *
      rw [host_map_find_other state.attempts k key replacement replacementKey hk]
      exact found
    exact host_settled_of_lookup_eq state _ key record found settled this

/-- A settled attempt record stays settled under `observe`. -/
theorem host_settled_is_stable_under_observe (state : NetworkState)
    (observation : HostObservation) (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    hostSettled (observeStepState state observation) key = true := by
  obtain ⟨record, found, handle, terminal, hs⟩ := host_settled_split state key settled
  obtain ⟨record', handle', terminal', hnext, hnextSettled⟩ :=
    observe_keeps_settled_record state observation key record handle terminal found hs
  exact host_settled_of_settled_record _ key record' handle' terminal' hnext hnextSettled

#print axioms host_settled_is_stable_under_observe

/-- A settled attempt record stays settled under `prepare`. -/
theorem host_settled_is_stable_under_prepare (state : NetworkState) (input : AttemptInput)
    (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    (∀ next prepared, prepare state input = .Prepared next prepared →
      hostSettled next key = true) ∧
    (∀ same failure, prepare state input = .Rejected same failure →
      hostSettled same key = true) := by
  obtain ⟨record, found, _⟩ := host_settled_split state key settled
  constructor
  · intro next prepared h
    unfold prepare at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact host_settled_of_lookup_eq state _ key record found settled (host_lookup_append state _ _ key record found rfl))
      | cases h
  · intro same failure h
    unfold prepare at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact settled)
      | cases h

#print axioms host_settled_is_stable_under_prepare

/-- A settled attempt record stays settled under `sendCommand`. -/
theorem host_settled_is_stable_under_send_command (state : NetworkState)
    (prepared : PreparedAttempt) (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    (∀ next command, sendCommand state prepared = .CommandReady next command →
      hostSettled next key = true) ∧
    (∀ same failure, sendCommand state prepared = .Rejected same failure →
      hostSettled same key = true) := by
  obtain ⟨record, found, hdisp⟩ := host_settled_split state key settled
  constructor
  · intro next command h
    unfold sendCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (exact host_settled_replace state prepared.input.attempt key _ record found settled (by first | rfl | (have hk := host_lookup_key state prepared.input.attempt _ ‹lookupAttempt state prepared.input.attempt = some _›; exact hk)) (by intro hk; exfalso; obtain ⟨handle, terminal, hs⟩ := hdisp; exact host_prepared_ready_not_settled state prepared key record handle terminal found hs ‹PreparedReady state prepared› hk))
      | (injection h with h1 h2; subst h1; exact host_settled_replace state prepared.input.attempt key _ record found settled (by first | rfl | (have hk := host_lookup_key state prepared.input.attempt _ ‹lookupAttempt state prepared.input.attempt = some _›; exact hk)) (by intro hk; exfalso; obtain ⟨handle, terminal, hs⟩ := hdisp; exact host_prepared_ready_not_settled state prepared key record handle terminal found hs ‹PreparedReady state prepared› hk))
  · intro same failure h
    unfold sendCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact settled)
      | (split at h <;> first | (injection h with h1 h2; subst h1; exact settled) | cases h)
      | cases h

#print axioms host_settled_is_stable_under_send_command

/-- A settled attempt record stays settled under `cancelCommand`. -/
theorem host_settled_is_stable_under_cancel_command (state : NetworkState)
    (started : StartedAttempt) (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    (∀ same command, cancelCommand state started = .CommandReady same command →
      hostSettled same key = true) ∧
    (∀ same failure, cancelCommand state started = .Rejected same failure →
      hostSettled same key = true) := by
  constructor
  · intro same command h
    unfold cancelCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact settled)
      | (cases h; done)
  · intro same failure h
    unfold cancelCommand at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (injection h with h1 h2; subst h1; exact settled)
      | (cases h; done)

#print axioms host_settled_is_stable_under_cancel_command

/-- A settled attempt record stays settled under `observeStart`. -/
theorem host_settled_is_stable_under_observe_start (state : NetworkState)
    (prepared : PreparedAttempt) (observation : StartObservation)
    (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    (∀ next started, observeStart state prepared observation = .Started next started →
      hostSettled next key = true) ∧
    (∀ next started, observeStart state prepared observation = .Pending next started →
      hostSettled next key = true) ∧
    (∀ next settled, observeStart state prepared observation = .Terminal next settled →
      hostSettled next key = true) ∧
    (∀ next settled late, observeStart state prepared observation = .Late next settled late →
      hostSettled next key = true) ∧
    (∀ next attempt delivery, observeStart state prepared observation = .Duplicate next attempt delivery →
      hostSettled next key = true) ∧
    (∀ same failure, observeStart state prepared observation = .Rejected same failure →
      hostSettled same key = true) := by
  obtain ⟨record, found, hdisp⟩ := host_settled_split state key settled
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> (intros; rename_i h; cases observation <;> unfold observeStart at h <;> dsimp only at h <;> repeat' split at h) <;>
    first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact settled)
      | (injection h with h1; subst h1; exact settled)
      | ((try (injection h with h1; subst h1)); refine host_settled_replace state _ key _ record found settled ?_ ?_
         · first | rfl | (have hk := host_lookup_key state _ _ ‹lookupAttempt state _ = some _›; exact hk) | exact (‹StartObservationRelation state prepared (.Started _ _)›.2).symm
         · first
             | (intro _; exact ⟨_, _, rfl⟩)
             | (intro hk; exfalso; obtain ⟨handle, terminal, hs⟩ := hdisp; exact host_start_not_settled state prepared _ key _ record handle terminal found hs (by assumption) hk))

#print axioms host_settled_is_stable_under_observe_start

private theorem host_settled_set_effect (state : NetworkState) (k : AttemptIdentity)
    (status : EffectStatus) (key : AttemptIdentity) (record : AttemptRecord)
    (found : lookupAttempt state key = some record)
    (settled : hostSettled state key = true) :
    hostSettled
      (match lookupAttempt state k with
       | some record =>
           match record.disposition with
           | .Settled handle terminal =>
               replaceRecord state k
                 { record with disposition := .Settled handle { terminal with effect := status } }
           | _ => state
       | none => state) key = true := by
  split
  · rename_i target hk
    split
    · exact host_settled_replace state k key _ record found settled
        (host_lookup_key state k target hk) (fun _ => ⟨_, _, rfl⟩)
    · exact settled
  · exact settled

/-- A settled attempt record stays settled under `annotateEffect`. -/
theorem host_settled_is_stable_under_annotate_effect (state : NetworkState)
    (observation : EffectObservation) (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    (∀ next, annotateEffect state observation = .Applied next →
      hostSettled next key = true) ∧
    (∀ same failure, annotateEffect state observation = .Rejected same failure →
      hostSettled same key = true) := by
  obtain ⟨record, found, _⟩ := host_settled_split state key settled
  constructor
  · intro next h
    unfold annotateEffect at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1; subst h1; exact settled)
      | (injection h with h1; subst h1; exact host_settled_set_effect state _ _ key record found settled)
  · intro same failure h
    unfold annotateEffect at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact settled)

#print axioms host_settled_is_stable_under_annotate_effect

/-- A settled attempt record stays settled under `retry`. -/
theorem host_settled_is_stable_under_retry (state : NetworkState) (request : RetryRequest)
    (key : AttemptIdentity)
    (settled : hostSettled state key = true) :
    (∀ next prepared, retry state request = .Prepared next prepared →
      hostSettled next key = true) ∧
    (∀ same failure, retry state request = .Rejected same failure →
      hostSettled same key = true) := by
  obtain ⟨record, found, _⟩ := host_settled_split state key settled
  constructor
  · intro next prepared h
    unfold retry at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact host_settled_of_lookup_eq state _ key record found settled (host_lookup_append state _ _ key record found rfl))
  · intro same failure h
    unfold retry at h
    dsimp only at h
    repeat' split at h
    all_goals first
      | (cases h; done)
      | (injection h with h1 h2; subst h1; exact settled)

#print axioms host_settled_is_stable_under_retry

theorem release_settled_running_retains_outstanding_effect (state : NetworkState)
    (running : AttemptIdentity → Bool) (key : AttemptIdentity) :
    hostSettled state key = true → running key = true →
      releaseHostRecord state running key = .retain [.outstandingEffect key] := by
  intro settled hr
  have ha := host_settled_not_awaited state key settled
  have hdef : releaseHostRecord state running key =
      NecoQuotient.decideWithBy (hostRecordRequest key) (hostRecordMembership state running)
        (K := Unit) (W := Unit) .irrecoverable := by
    simp [releaseHostRecord, NecoQuotient.judgeErasureBy, hostRecordRecoverability,
      hostRecordRequest]
  rw [hdef]
  unfold NecoQuotient.decideWithBy
  have hrs : NecoQuotient.retentionReasonsBy (hostRecordRequest key)
      (hostRecordMembership state running) (NecoQuotient.Recoverability.irrecoverable (K := Unit) (W := Unit)) =
      (if hostAwaits state key then [NecoQuotient.RetentionReason.futureUse key] else []) ++
      (if running key then [NecoQuotient.RetentionReason.outstandingEffect key] else []) := by
    simp [NecoQuotient.retentionReasonsBy, hostRecordRequest, hostRecordMembership]
  rw [hrs]
  simp [ha, hr]

#print axioms release_settled_running_retains_outstanding_effect

end Necoherence
