-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.NetworkEffect

namespace Necoherence

private def wLogical : RequestIdentity :=
  { kind := "network", provenance := "W", revision := 1 }

private def wKey0 : AttemptIdentity := { logical := wLogical, ordinal := 0 }
private def wKey1 : AttemptIdentity := { logical := wLogical, ordinal := 1 }
private def wBasis : ClockBasis := { value := "clock-W" }
private def wClockIdentity : OpaqueEvidence := { value := "clock-cap-W" }
private def wClock : MonotonicClockCapability := { identity := wClockIdentity, clockBasis := wBasis }
private def wCancelIdentity : OpaqueEvidence := { value := "cancel-cap-W" }
private def wCancel : CancellationCapability := { identity := wCancelIdentity }
private def wConfiguration : HostConfiguration :=
  { requestBodyLimit := 32, responseBodyLimit := 32,
    cancellation := some wCancel, monotonicClock := some wClock }
private def wDeadline : Deadline := { clockBasis := wBasis, limit := 10, capability := wClock }
private def wInstruction : HttpWireInstruction :=
  { method := "POST", target := "https://example.test/w", headers := [], body := [0, 255] }
private def wInput : AttemptInput :=
  { attempt := wKey0, instruction := wInstruction, deadline := some wDeadline,
    configuration := wConfiguration }
private def wPrepared : PreparedAttempt := { input := wInput, lineage := .Root }
private def wRootRecord : AttemptRecord :=
  { input := wInput, lineage := .Root, disposition := .Prepared,
    firstDelivery := none, late := [] }
private def wEmpty : NetworkState := { attempts := [] }
private def wRoot : NetworkState := { attempts := [wRootRecord] }
private def wHandle : ExecutionHandle := { value := "handle-W" }
private def wCommandState : NetworkState :=
  replaceRecord wRoot wKey0 { wRootRecord with disposition := .CommandIssued }
private def wStartedRecord : AttemptRecord :=
  { wRootRecord with disposition := .Started wHandle }
private def wStartedState : NetworkState :=
  replaceRecord wCommandState wKey0 wStartedRecord
private def wRaw : RawHttpResponse := { status := 200, headers := [], body := [1, 2, 3] }
private def wResponse : AdapterObservation :=
  .ResponseObservation wKey0 wHandle (.some 2) wRaw .WireObserved (.Unknown .NoResponse)
private def wResponseFirst : DeliveredObservation := { delivery := 0, observation := wResponse }
private def wResponseTerminal : NetworkTerminal :=
  { outcome := .Response wRaw .WireObserved, effect := .Unknown .NoResponse }
private def wSettledRecord : AttemptRecord :=
  { input := wInput, lineage := .Root,
    disposition := .Settled (some wHandle) wResponseTerminal,
    firstDelivery := some wResponseFirst, late := [] }
private def wSettled : NetworkState := replaceRecord wStartedState wKey0 wSettledRecord
private def wAuthorization : RetryAuthorization :=
  { logical := wLogical, «from» := wKey0, next := wKey1,
    protocolEvidence := { value := "retry-rule-W" } }
private def wRetryRequest : RetryRequest :=
  { permission := .RetryAllowed wAuthorization, instruction := wInstruction,
    deadline := some wDeadline, configuration := wConfiguration }
private def wRetryInput : AttemptInput :=
  { attempt := wKey1, instruction := wInstruction, deadline := some wDeadline,
    configuration := wConfiguration }
private def wRetryRecord : AttemptRecord :=
  { input := wRetryInput, lineage := .RetryOf wAuthorization, disposition := .Prepared,
    firstDelivery := none, late := [] }
private def wRetried : NetworkState := { attempts := wSettled.attempts ++ [wRetryRecord] }
private def wCancellation : AdapterObservation :=
  .CancellationObservation wKey0 wHandle (.some 1) (.Unknown .Cancellation)
private def wDeadlineObservation : AdapterObservation :=
  .DeadlineObservation wKey0 wHandle (.some 3) wDeadline
    { clockBasis := wBasis, value := 10 } (.Unknown .Deadline)
private def wFailure : AdapterObservation :=
  .FailureObservation wKey0 wHandle (.some 4)
    { attempt := wKey0, stage := .ResponseBody, configuration := wConfiguration,
      cause := .Timeout .ResponseBody .LibraryReported }
    (.Unknown .HostFailure)
private def wMalformed : AdapterObservation :=
  .ResponseObservation wKey1 wHandle (.some 7) wRaw .WireObserved (.Unknown .NoResponse)
private def wCancelTerminal : NetworkTerminal :=
  { outcome := .Cancelled, effect := .Unknown .Cancellation }
private def wCancelLate : LateObservation :=
  { delivered := { delivery := 1, observation := wCancellation } }
private def wCancelSettled : NetworkState :=
  replaceRecord wStartedState wKey0
    { input := wInput, lineage := .Root,
      disposition := .Settled (some wHandle) wResponseTerminal,
      firstDelivery := some wResponseFirst, late := [wCancelLate] }
private def wStartFailure : NetworkHostFailure :=
  { attempt := wKey0, stage := .Start, configuration := wConfiguration,
    cause := .ExecutionStartFailed }
private def wPreHandleTerminal : NetworkTerminal :=
  { outcome := .Failed wStartFailure, effect := .Unknown .HostFailure }
private def wPreHandleState : NetworkState :=
  replaceRecord wCommandState wKey0
    { wRootRecord with disposition := .Settled none wPreHandleTerminal }

private def wStarted : StartedAttempt := { prepared := wPrepared, handle := wHandle }
private def wRetryPrepared : PreparedAttempt :=
  { input := wRetryInput, lineage := .RetryOf wAuthorization }
private def wResponseAlternateSource : AdapterObservation :=
  .ResponseObservation wKey0 wHandle (.some 200) wRaw .WireObserved (.Unknown .NoResponse)
private def wForgedHandle : ExecutionHandle := { value := "forged-handle" }
private def wWrongHandleResponse : AdapterObservation :=
  .ResponseObservation wKey0 wForgedHandle (.some 2) wRaw .WireObserved (.Unknown .NoResponse)
private def wForeignEffectWitness : EffectWitness :=
  { attempt := wKey1, source := .Adapter, evidence := { value := "foreign-effect-W" } }
private def wWrongEffectResponse : AdapterObservation :=
  .ResponseObservation wKey0 wHandle (.some 2) wRaw .WireObserved
    (.NoEffect wForeignEffectWitness)
private def wOtherBasis : ClockBasis := { value := "other-clock-W" }
private def wClockMismatchObservation : AdapterObservation :=
  .DeadlineObservation wKey0 wHandle (.some 5) wDeadline
    { clockBasis := wOtherBasis, value := 10 } (.Unknown .Deadline)
private def wEarlyDeadlineObservation : AdapterObservation :=
  .DeadlineObservation wKey0 wHandle (.some 6) wDeadline
    { clockBasis := wBasis, value := 9 } (.Unknown .Deadline)
private def wTimeoutFailure : NetworkHostFailure :=
  { attempt := wKey0, stage := .Deadline, configuration := wConfiguration,
    cause := .Timeout .Deadline .LibraryReported }
private def wTimeoutObservation : AdapterObservation :=
  .FailureObservation wKey0 wHandle (.some 4) wTimeoutFailure (.Unknown .HostFailure)
private def wTimeoutTerminal : NetworkTerminal :=
  { outcome := .Failed wTimeoutFailure, effect := .Unknown .HostFailure }
private def wTimeoutState : NetworkState :=
  replaceRecord wStartedState wKey0
    { input := wInput, lineage := .Root,
      disposition := .Settled (some wHandle) wTimeoutTerminal,
      firstDelivery := some { delivery := 0, observation := wTimeoutObservation },
      late := [] }
private def wDeadlineTerminal : NetworkTerminal :=
  { outcome := .DeadlineExceeded wDeadline { clockBasis := wBasis, value := 10 },
    effect := .Unknown .Deadline }
private def wDeadlineState : NetworkState :=
  replaceRecord wStartedState wKey0
    { input := wInput, lineage := .Root,
      disposition := .Settled (some wHandle) wDeadlineTerminal,
      firstDelivery := some { delivery := 0, observation := wDeadlineObservation },
      late := [] }

theorem W1 :
    ∃ state prepared,
      prepare wEmpty wInput = .Prepared state prepared ∧
      ValidState state ∧ PreparedReady state prepared := by
  exact ⟨wRoot, wPrepared, by decide, by decide, by decide⟩

theorem W2 :
    sendCommand wRoot wPrepared =
        .CommandReady wCommandState { prepared := wPrepared } ∧
    observeStart wCommandState wPrepared (.Started wKey0 wHandle) =
        .Started wStartedState wStarted ∧
    ∃ state started, StartedRelation state started := by
  exact
    ⟨by decide, by decide,
      ⟨wStartedState, wStarted, by decide⟩⟩

theorem W3 :
    observe wStartedState (.Delivered 0 wResponse) =
        .Terminal wSettled
          { prepared := wPrepared, handle := some wHandle,
            terminal := wResponseTerminal } ∧
    ValidState wSettled ∧
    wResponseTerminal.outcome = .Response wRaw .WireObserved ∧
    EqualExceptSourceSequence wResponse wResponseAlternateSource ∧
    ExpectedNextDelivery wStartedState wKey0 0 ∧
    (¬ ∃ recorded : AdapterObservation,
      RecordedDelivery wStartedState wKey0 0 recorded) ∧
    ObservationRelation wStartedState wResponse ∧
    ObservationRelation wStartedState wResponseAlternateSource ∧
    ResultClass (observe wStartedState (.Delivered 0 wResponse)) =
      ResultClass (observe wStartedState (.Delivered 0 wResponseAlternateSource)) ∧
    EraseSourceSequence (observe wStartedState (.Delivered 0 wResponse)) =
      EraseSourceSequence
        (observe wStartedState (.Delivered 0 wResponseAlternateSource)) := by
  have fresh :
      ¬ ∃ recorded : AdapterObservation,
        RecordedDelivery wStartedState wKey0 0 recorded := by
    intro recorded
    rcases recorded with ⟨recorded, evidence⟩
    have found : lookupAttempt wStartedState wKey0 = some wStartedRecord := by
      decide
    have noneRecorded : recordedDelivery wStartedRecord 0 = none := by
      decide
    unfold RecordedDelivery at evidence
    rw [found] at evidence
    simp only at evidence
    rw [noneRecorded] at evidence
    contradiction
  exact
    ⟨by decide, by decide, by decide, by decide,
      by decide, fresh, by decide, by decide,
      by decide, by decide⟩

theorem W4 :
    retry wSettled wRetryRequest = .Prepared wRetried wRetryPrepared ∧
    PreparedRelation wRetried wRetryPrepared ∧
    LedgerPrefix wSettled wRetried ∧
    ExactlyOneRecordAdded wSettled wRetried wKey1 ∧
    lookupAttempt wRetried wKey1 = some wRetryRecord ∧
    ¬ CommandIssuedRelation wRetried wRetryPrepared := by
  exact
    ⟨by decide, by decide, ⟨[wRetryRecord], rfl⟩,
      ⟨wRetryRecord, rfl, rfl⟩, by decide, by decide⟩

theorem W5 :
    StartedRelation wStartedState wStarted ∧
    observe wStartedState (.Pending wKey0 wHandle) =
      .Pending wStartedState wStarted := by
  exact ⟨by decide, by decide⟩

theorem W6 :
    ValidState wStartedState ∧
    StartedRelation wStartedState wStarted ∧
    ObservationRelation wStartedState wResponse ∧
    ObservationRelation wStartedState wCancellation ∧
    ObservationRelation wStartedState wDeadlineObservation ∧
    ObservationRelation wStartedState wFailure ∧
    attemptOf wResponse = wKey0 ∧
    attemptOf wCancellation = wKey0 ∧
    attemptOf wDeadlineObservation = wKey0 ∧
    attemptOf wFailure = wKey0 ∧
    handleOf wResponse = wHandle ∧
    handleOf wCancellation = wHandle ∧
    handleOf wDeadlineObservation = wHandle ∧
    handleOf wFailure = wHandle ∧
    DeadlineFieldsMatch (some wDeadline) (some wClock) wDeadlineObservation ∧
    OneWinnerAndOrderedLate
      [wResponse, wCancellation, wDeadlineObservation, wFailure]
      (FoldObserve wStartedState
        (AssignContiguousDelivery
          [wResponse, wCancellation, wDeadlineObservation, wFailure])) ∧
    OneWinnerAndOrderedLate
      [wCancellation, wResponse, wDeadlineObservation, wFailure]
      (FoldObserve wStartedState
        (AssignContiguousDelivery
          [wCancellation, wResponse, wDeadlineObservation, wFailure])) ∧
    OneWinnerAndOrderedLate
      [wDeadlineObservation, wResponse, wCancellation, wFailure]
      (FoldObserve wStartedState
        (AssignContiguousDelivery
          [wDeadlineObservation, wResponse, wCancellation, wFailure])) ∧
    OneWinnerAndOrderedLate
      [wFailure, wResponse, wCancellation, wDeadlineObservation]
      (FoldObserve wStartedState
        (AssignContiguousDelivery
          [wFailure, wResponse, wCancellation, wDeadlineObservation])) := by
  have responseFirst :
      OneWinnerAndOrderedLate
        [wResponse, wCancellation, wDeadlineObservation, wFailure]
        (FoldObserve wStartedState
          (AssignContiguousDelivery
            [wResponse, wCancellation, wDeadlineObservation, wFailure])) := by
    apply race_completeness wStartedState wStarted wResponse wCancellation
      wDeadlineObservation wFailure
    all_goals decide
  have cancellationFirst :
      OneWinnerAndOrderedLate
        [wCancellation, wResponse, wDeadlineObservation, wFailure]
        (FoldObserve wStartedState
          (AssignContiguousDelivery
            [wCancellation, wResponse, wDeadlineObservation, wFailure])) := by
    apply race_completeness wStartedState wStarted wResponse wCancellation
      wDeadlineObservation wFailure
    all_goals decide
  have deadlineFirst :
      OneWinnerAndOrderedLate
        [wDeadlineObservation, wResponse, wCancellation, wFailure]
        (FoldObserve wStartedState
          (AssignContiguousDelivery
            [wDeadlineObservation, wResponse, wCancellation, wFailure])) := by
    apply race_completeness wStartedState wStarted wResponse wCancellation
      wDeadlineObservation wFailure
    all_goals decide
  have failureFirst :
      OneWinnerAndOrderedLate
        [wFailure, wResponse, wCancellation, wDeadlineObservation]
        (FoldObserve wStartedState
          (AssignContiguousDelivery
            [wFailure, wResponse, wCancellation, wDeadlineObservation])) := by
    apply race_completeness wStartedState wStarted wResponse wCancellation
      wDeadlineObservation wFailure
    all_goals decide
  exact
    ⟨by decide, by decide, by decide, by decide,
      by decide, by decide, by decide, by decide,
      by decide, by decide, by decide, by decide,
      by decide, by decide, by decide, responseFirst,
      cancellationFirst, deadlineFirst, failureFirst⟩

theorem W7 :
    observe wSettled (.Delivered 0 wResponse) = .Duplicate wSettled wKey0 0 ∧
    observe wSettled (.Delivered 0 wCancellation) =
      .Rejected wSettled (.ConflictingDelivery wKey0 0 wResponse wCancellation) ∧
    observe wSettled (.Delivered 0 wMalformed) =
      .Rejected wSettled (.UnknownAttempt wKey1) ∧
    observe wSettled (.Delivered 0 wWrongHandleResponse) =
      .Rejected wSettled (.HandleMismatch wHandle wForgedHandle) ∧
    observe wSettled (.Delivered 0 wWrongEffectResponse) =
      .Rejected wSettled (.EffectWitnessMissing wKey0) ∧
    prepare wEmpty
        { wInput with instruction := { wInstruction with method := "GET BAD" } } =
      .Rejected wEmpty (.InvalidWireInstruction "GET BAD") ∧
    prepare wEmpty
        { wInput with instruction := { wInstruction with target := "/foo" } } =
      .Rejected wEmpty (.InvalidWireInstruction "POST") ∧
    observe wStartedState (.Delivered 0 wClockMismatchObservation) =
      .Rejected wStartedState (.ClockBasisMismatch wBasis wOtherBasis) ∧
    observe wStartedState (.Delivered 0 wEarlyDeadlineObservation) =
      .Rejected wStartedState
        (.DeadlineNotReached wDeadline { clockBasis := wBasis, value := 9 }) ∧
    sendCommand wRoot
        { wPrepared with input :=
          { wInput with instruction := { wInstruction with method := "PUT" } } } =
      .Rejected wRoot (.AttemptTokenMismatch wKey0 .Instruction) ∧
    sendCommand wRoot
        { wPrepared with input := { wInput with deadline := none } } =
      .Rejected wRoot (.AttemptTokenMismatch wKey0 .Deadline) ∧
    sendCommand wRoot
        { wPrepared with input :=
          { wInput with configuration :=
            { wConfiguration with responseBodyLimit := 31 } } } =
      .Rejected wRoot (.AttemptTokenMismatch wKey0 .Configuration) ∧
    sendCommand wRoot { wPrepared with lineage := .RetryOf wAuthorization } =
      .Rejected wRoot (.AttemptTokenMismatch wKey0 .Lineage) ∧
    sendCommand wRoot
        { wPrepared with input := { wInput with attempt := wKey1 } } =
      .Rejected wRoot (.UnknownAttempt wKey1) ∧
    sendCommand wCommandState wPrepared =
      .Rejected wCommandState (.CommandAlreadyIssued wKey0) ∧
    cancelCommand wStartedState
        { prepared := wPrepared, handle := wForgedHandle } =
      .Rejected wStartedState (.HandleMismatch wHandle wForgedHandle) := by
  have unknownObservation :
      observe wSettled (.Delivered 0 wMalformed) =
        .Rejected wSettled (.UnknownAttempt wKey1) := by
    apply observe_unknown_attempt_rejected
    · decide
    · decide
  have unknownPrepared :
      sendCommand wRoot
          { wPrepared with input := { wInput with attempt := wKey1 } } =
        .Rejected wRoot (.UnknownAttempt wKey1) := by
    apply sendCommand_unknown_attempt_rejected
    · decide
    · decide
  exact
    ⟨by decide, by decide, unknownObservation, by decide,
      by decide, by decide, by decide, by decide,
      by decide, by decide, by decide, by decide,
      by decide, unknownPrepared, by decide, by decide⟩

theorem W8 :
    wTimeoutFailure.attempt = wKey0 ∧
    wTimeoutFailure.stage = .Deadline ∧
    wTimeoutFailure.configuration = wConfiguration ∧
    DeadlineFieldsMatch (some wDeadline) (some wClock) wDeadlineObservation ∧
    observe wStartedState (.Delivered 0 wTimeoutObservation) =
      .Terminal wTimeoutState
        { prepared := wPrepared, handle := some wHandle, terminal := wTimeoutTerminal } ∧
    observe wStartedState (.Delivered 0 wDeadlineObservation) =
      .Terminal wDeadlineState
        { prepared := wPrepared, handle := some wHandle, terminal := wDeadlineTerminal } ∧
    wTimeoutTerminal.outcome = .Failed wTimeoutFailure ∧
    wDeadlineTerminal.outcome =
      .DeadlineExceeded wDeadline { clockBasis := wBasis, value := 10 } ∧
    wTimeoutTerminal ≠ wDeadlineTerminal := by
  decide

end Necoherence
