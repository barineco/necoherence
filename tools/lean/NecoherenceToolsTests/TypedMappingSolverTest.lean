-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceTools.TypedMappingSolver



namespace NecoherenceTools
open Necoherence

private def placeReady : TypedPlace := { identity := "P-READY", tokenType := "T-JOB", revision := 1 }
private def placeDone : TypedPlace := { identity := "P-DONE", tokenType := "T-JOB", revision := 1 }

private def tRun : TypedTransition :=
  { identity := "T-RUN", inputPlaces := ["P-READY"], outputPlaces := ["P-DONE"], failurePlaces := [], revision := 1 }

private def bindingRun : InputBinding :=
  { transitionId := "T-RUN", name := "job", place := "P-READY", tokenType := "T-JOB", identity := "job-1",
    provenance := "test", multiplicity := 1, mode := .consume, requiredRevision := 1 }

private def tokJob : ColoredToken := { target := "job-1", index := 0, revision := 1, kind := .input }

private def markingReady : Marking := { places := [("P-READY", [tokJob]), ("P-DONE", [])] }

private def boundSmall : DomainBound :=
  { targetIdentity := "unit:typed-mapping-solver", index := 0, revision := 1, maxBindings := 10, maxSearchSteps := 10 }

private def graphSimple : DeclarationGraph :=
  { places := ["P-READY", "P-DONE"], transitions := ["T-RUN"], edges := [("P-READY", "P-DONE")], revision := 1 }

private def inputReady : SolverInput :=
  { places := [placeReady, placeDone], transitions := [tRun], bindings := [bindingRun],
    goal := .placeHasAtLeast "P-DONE" 1, graph := graphSimple, marking := markingReady, bound := boundSmall }


example : deriveEnabled inputReady = .enabledSet { enabled := [{ transitionId := "T-RUN", bindings := [bindingRun] }] } := by
  decide


example :
    checkReachability inputReady =
      .reachable
        { path := ["T-RUN"],
          finalMarking := { places := [("P-READY", []), ("P-DONE", [{ target := "T-RUN", index := 0, revision := 1, kind := .output }])] } } := by
  decide


example :
    checkDeadlock
        { inputReady with marking := { places := [("P-READY", []), ("P-DONE", [])] } } =
      .deadlocked { marking := { places := [("P-READY", []), ("P-DONE", [])] } } := by
  decide


example (w : AcyclicWitness)
    (h : checkWellFoundedness inputReady = .wellFounded w) :
    w.frontier = [] ∧ w.steps ≤ boundSmall.maxSearchSteps := by
  have hs := acyclicWitnessSound inputReady w h
  exact ⟨hs.2.2.1, hs.2.2.2.1⟩



private def placeOf (id : String) : TypedPlace := { identity := id, tokenType := "T-JOB", revision := 1 }

private def inTok (target : String) : ColoredToken := { target, index := 0, revision := 1, kind := .input }

private def outTok (target : String) : ColoredToken := { target, index := 0, revision := 1, kind := .output }

private def bind (tid name place ident : String) (mode : BindingMode) : InputBinding :=
  { transitionId := tid, name, place, tokenType := "T-JOB", identity := ident,
    provenance := "test", multiplicity := 1, mode, requiredRevision := 1 }


private def convTransitions : List TypedTransition :=
  [ { identity := "T-A", inputPlaces := ["P-SRC", "P-X", "P-S"], outputPlaces := ["P-A"], failurePlaces := [], revision := 1 },
    { identity := "T-B", inputPlaces := ["P-SRC", "P-X", "P-S"], outputPlaces := ["P-B"], failurePlaces := [], revision := 1 },
    { identity := "T-AX", inputPlaces := ["P-SRC", "P-X", "P-A"], outputPlaces := [], failurePlaces := [], revision := 1 },
    { identity := "T-BC", inputPlaces := ["P-SRC", "P-X", "P-B"], outputPlaces := ["P-C"], failurePlaces := [], revision := 1 },
    { identity := "T-CX", inputPlaces := ["P-SRC", "P-X", "P-C"], outputPlaces := [], failurePlaces := [], revision := 1 } ]

private def convBindings : List InputBinding :=
  [ bind "T-A" "ba-src" "P-SRC" "job-1" .read,
    bind "T-A" "ba-x" "P-X" "job-2" .read,
    bind "T-A" "ba-s" "P-S" "job-3" .consume,
    bind "T-B" "bb-src" "P-SRC" "job-1" .read,
    bind "T-B" "bb-x" "P-X" "job-2" .read,
    bind "T-B" "bb-s" "P-S" "job-3" .consume,
    bind "T-AX" "bax-src" "P-SRC" "job-1" .read,
    bind "T-AX" "bax-x" "P-X" "job-2" .read,
    bind "T-AX" "bax-a" "P-A" "T-A" .consume,
    bind "T-BC" "bbc-src" "P-SRC" "job-1" .read,
    bind "T-BC" "bbc-x" "P-X" "job-2" .read,
    bind "T-BC" "bbc-b" "P-B" "T-B" .consume,
    bind "T-CX" "bcx-src" "P-SRC" "job-1" .read,
    bind "T-CX" "bcx-x" "P-X" "job-2" .read,
    bind "T-CX" "bcx-c" "P-C" "T-BC" .consume ]

private def mConv0 : Marking :=
  { places := [("P-SRC", [inTok "job-1"]), ("P-X", [inTok "job-2"]), ("P-S", [inTok "job-3"]),
    ("P-A", []), ("P-B", []), ("P-C", [])] }

private def mConvA : Marking :=
  { places := [("P-SRC", [inTok "job-1"]), ("P-X", [inTok "job-2"]), ("P-S", []),
    ("P-A", [outTok "T-A"]), ("P-B", []), ("P-C", [])] }

private def mConvB : Marking :=
  { places := [("P-SRC", [inTok "job-1"]), ("P-X", [inTok "job-2"]), ("P-S", []),
    ("P-A", []), ("P-B", [outTok "T-B"]), ("P-C", [])] }

private def mConvX : Marking :=
  { places := [("P-SRC", [inTok "job-1"]), ("P-X", [inTok "job-2"]), ("P-S", []),
    ("P-A", []), ("P-B", []), ("P-C", [])] }

private def mConvC : Marking :=
  { places := [("P-SRC", [inTok "job-1"]), ("P-X", [inTok "job-2"]), ("P-S", []),
    ("P-A", []), ("P-B", []), ("P-C", [outTok "T-BC"])] }

private def convBound : DomainBound :=
  { targetIdentity := "unit:typed-mapping-solver", index := 0, revision := 1, maxBindings := 20, maxSearchSteps := 20 }

private def inputConv : SolverInput :=
  { places := (["P-SRC", "P-X", "P-S", "P-A", "P-B", "P-C", "P-Z"].map placeOf),
    transitions := convTransitions, bindings := convBindings,
    goal := .placeHasAtLeast "P-Z" 1,
    graph := { places := ["P-SRC", "P-X", "P-S", "P-A", "P-B", "P-C", "P-Z"],
               transitions := ["T-A", "T-B", "T-AX", "T-BC", "T-CX"], edges := [], revision := 1 },
    marking := mConv0, bound := convBound }


example (w : AcyclicWitness)
    (h : checkWellFoundedness inputConv = .wellFounded w) :
    w.frontier = [] ∧ w.steps ≤ inputConv.bound.maxSearchSteps := by
  have hs := acyclicWitnessSound inputConv w h
  exact ⟨hs.2.2.1, hs.2.2.2.1⟩


example (w : ClosureWitness)
    (h : checkReachability inputConv = .unreachable w) :
    w.frontier = [] ∧ w.steps ≤ inputConv.bound.maxSearchSteps := by
  have hs := closureWitnessSound inputConv w h
  exact ⟨hs.2.2.1, hs.2.2.2.2.2.2.1⟩
private def ghostTransition : TypedTransition :=
  { identity := "T-GHOST", inputPlaces := ["P-GHOST"], outputPlaces := [],
    failurePlaces := [], revision := 1 }

private def graphGhost : DeclarationGraph :=
  { places := ["P-READY", "P-DONE"], transitions := ["T-GHOST"],
    edges := [], revision := 1 }

private def inputGhost : SolverInput :=
  { places := inputReady.places, transitions := [ghostTransition], bindings := [],
    goal := inputReady.goal, graph := graphGhost, marking := inputReady.marking,
    bound := inputReady.bound }


example : checkReachability inputGhost =
    .invalid (.unknownInputPlace "T-GHOST" "P-GHOST") := by
  decide


example :
    deriveEnabled { inputReady with bindings := [] } =
      .invalid (.missingInputBinding "T-RUN" "P-READY") := by
  decide


example :
    checkDeadlock { inputReady with transitions := [tRun, tRun] } =
      .invalid (.duplicateTransitionIdentity "T-RUN") := by
  decide

private def sourceTransition : TypedTransition :=
  { identity := "T-SOURCE", inputPlaces := [], outputPlaces := ["P-DONE"],
    failurePlaces := [], revision := 1 }

private def graphSource : DeclarationGraph :=
  { places := ["P-READY", "P-DONE"], transitions := ["T-SOURCE"],
    edges := [], revision := 1 }

private def inputSource : SolverInput :=
  { places := inputReady.places, transitions := [sourceTransition], bindings := [],
    goal := inputReady.goal, graph := graphSource, marking := inputReady.marking,
    bound := inputReady.bound }

private def sourceFinal : Marking :=
  { places := [("P-READY", [tokJob]), ("P-DONE", [outTok "T-SOURCE"])] }


example : checkReachability inputSource =
    .reachable { path := ["T-SOURCE"], finalMarking := sourceFinal } := by
  decide

private def boundInitial : DomainBound :=
  { targetIdentity := "unit:typed-mapping-solver", index := 0,
    revision := 1, maxBindings := 10, maxSearchSteps := 0 }

private def inputInitialGoal : SolverInput :=
  { places := inputReady.places, transitions := inputReady.transitions,
    bindings := inputReady.bindings, goal := .placeHasAtLeast "P-READY" 1,
    graph := inputReady.graph, marking := inputReady.marking,
    bound := boundInitial }


example : checkReachability inputInitialGoal =
    .reachable { path := [], finalMarking := markingReady } := by
  decide

private def cyclePlace : TypedPlace :=
  { identity := "P-LOOP", tokenType := "T-JOB", revision := 1 }

private def cycleGrow : TypedTransition :=
  { identity := "T-GROW", inputPlaces := ["P-LOOP"], outputPlaces := ["P-LOOP"],
    failurePlaces := [], revision := 1 }

private def cycleClose : TypedTransition :=
  { identity := "T-CLOSE", inputPlaces := ["P-LOOP"], outputPlaces := [],
    failurePlaces := [], revision := 1 }

private def cycleInputBinding : InputBinding :=
  bind "T-GROW" "grow" "P-LOOP" "job-1" .read

private def cycleCloseBinding : InputBinding :=
  bind "T-CLOSE" "close" "P-LOOP" "T-GROW" .consume

private def cycleMarking : Marking :=
  { places := [("P-LOOP", [inTok "job-1"])] }

private def graphCycle : DeclarationGraph :=
  { places := ["P-LOOP"], transitions := ["T-GROW", "T-CLOSE"],
    edges := [], revision := 1 }

private def cycleInput : SolverInput :=
  { places := [cyclePlace], transitions := [cycleGrow, cycleClose],
    bindings := [cycleInputBinding, cycleCloseBinding],
    goal := .placeHasAtLeast "P-GHOST" 1,
    graph := graphCycle,
    marking := cycleMarking,
    bound := { convBound with maxSearchSteps := 10 } }


example :
    checkWellFoundedness cycleInput =
      .notWellFounded
        { prefixPath := [],
          cyclePath := ["T-GROW", "T-CLOSE"],
          cycleStart := cycleMarking,
          cycleEnd := cycleMarking,
          measureDecreasing := true } := by
  native_decide

private def finalMarkingRun : Marking :=
  { places := [("P-READY", []), ("P-DONE", [outTok "T-RUN"])] }


example : pathReplay inputReady markingReady ["T-RUN"] =
    some finalMarkingRun := by
  native_decide


example :
    tokensAt
        (applyConsumption { places := [("P-DUP", [inTok "job-d", inTok "job-d"])] }
          [bind "T-D" "bd" "P-DUP" "job-d" .consume])
        "P-DUP" = [inTok "job-d"] := by
  decide


example : checkReachability { inputReady with bound := { boundSmall with maxBindings := 0 } } =
    .unknown (.bindingBoundExhausted 0) := by
  decide


example : checkReachability
    { inputReady with
      transitions := [{ identity := "T-BAD-OUT", inputPlaces := [], outputPlaces := ["P-GHOST"], failurePlaces := [], revision := 1 }],
      bindings := [],
      graph := { places := ["P-READY", "P-DONE"], transitions := ["T-BAD-OUT"], edges := [], revision := 1 } } =
    .invalid (.dependencyMismatch "T-BAD-OUT" "P-GHOST") := by
  decide


example : checkReachability
    { inputReady with
      transitions := [{ identity := "T-BAD-FAIL", inputPlaces := [], outputPlaces := [], failurePlaces := ["P-GHOST-F"], revision := 1 }],
      bindings := [],
      graph := { places := ["P-READY", "P-DONE"], transitions := ["T-BAD-FAIL"], edges := [], revision := 1 } } =
    .invalid (.dependencyMismatch "T-BAD-FAIL" "P-GHOST-F") := by
  decide

end NecoherenceTools
