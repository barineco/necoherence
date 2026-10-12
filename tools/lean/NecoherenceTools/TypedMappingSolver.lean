-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.TypedMapping

/-
Bounded search over typed mappings: reachability, deadlock and
well-foundedness checks and their soundness theorems.
-/

namespace NecoherenceTools
open Necoherence

/-! Bounded reachability exploration -/

private def neighborsFrom (input : SolverInput)
    (transitions : List TypedTransition) (path : List String) (m : Marking) :
    List (List String × Marking) :=
  transitions.foldr (fun t acc =>
    match stepAt input m t.identity with
    | some next => (path ++ [t.identity], next) :: acc
    | none => acc) []


private def neighborsOf (input : SolverInput) (path : List String) (m : Marking) :
    List (List String × Marking) :=
  neighborsFrom input input.transitions path m

private def freshNeighbors (neighbors : List (List String × Marking)) (blocked : List Marking) :
    List (List String × Marking) :=
  neighbors.foldr (fun pr acc =>
    if blocked.contains pr.2 || acc.any (fun q => q.2 == pr.2) then acc
    else pr :: acc) []

private theorem freshNeighbors_mem {neighbors : List (List String × Marking)}
    {blocked : List Marking} {entry : List String × Marking}
    (h : entry ∈ freshNeighbors neighbors blocked) : entry ∈ neighbors := by
  induction neighbors with
  | nil => simp [freshNeighbors] at h
  | cons head rest ih =>
    simp only [freshNeighbors, List.foldr] at h
    split at h
    · exact List.mem_cons_of_mem head (ih h)
    · have hcases := List.mem_cons.mp h
      cases hcases with
      | inl heq =>
          subst entry
          exact List.mem_cons_self
      | inr htail => exact List.mem_cons_of_mem head (ih htail)
private theorem freshNeighbors_covers
    {neighbors : List (List String × Marking)} {blocked : List Marking}
    {entry : List String × Marking}
    (h : entry ∈ neighbors) :
    entry.2 ∈ blocked ∨
      entry.2 ∈ (freshNeighbors neighbors blocked).map Prod.snd := by
  let step : (List String × Marking) →
      List (List String × Marking) → List (List String × Marking) :=
    fun pr acc =>
      if blocked.contains pr.2 || acc.any (fun q => q.2 == pr.2)
      then acc else pr :: acc
  have keep (head : List String × Marking)
      (acc : List (List String × Marking)) (marking : Marking)
      (hm : marking ∈ acc.map Prod.snd) :
      marking ∈ (step head acc).map Prod.snd := by
    dsimp [step]
    split
    · exact hm
    · exact List.mem_cons_of_mem _ hm
  have cover : ∀ (xs : List (List String × Marking))
      (acc : List (List String × Marking)) (candidate : List String × Marking),
      candidate ∈ xs →
      candidate.2 ∈ blocked ∨
        candidate.2 ∈ (xs.foldr step acc).map Prod.snd := by
    intro xs
    induction xs with
    | nil =>
        intro acc candidate hc
        cases hc
    | cons head rest ih =>
        intro acc candidate hc
        let nextAcc := rest.foldr step acc
        cases List.mem_cons.mp hc with
        | inl hhead =>
            subst candidate
            cases hb : blocked.contains head.2 with
            | true => exact Or.inl (List.contains_iff_mem.mp hb)
            | false =>
                cases ha : nextAcc.any (fun q => q.2 == head.2) with
                | true =>
                    rcases List.any_eq_true.mp ha with ⟨q, hq, hqm⟩
                    have hqm' : q.2 = head.2 := beq_iff_eq.mp hqm
                    exact Or.inr (keep head nextAcc head.2
                      (List.mem_map.mpr ⟨q, hq, hqm'⟩))
                | false =>
                    have hnot : head.2 ∉ blocked := by
                      intro hm
                      have hc' : blocked.contains head.2 = true :=
                        List.contains_iff_mem.mpr hm
                      rw [hb] at hc'
                      cases hc'
                    exact Or.inr (by
                      change head.2 ∈ (step head nextAcc).map Prod.snd
                      simp [step, hb, ha, hnot])
        | inr hrest =>
            cases ih acc candidate hrest with
            | inl hblocked => exact Or.inl hblocked
            | inr hfresh => exact Or.inr (keep head nextAcc candidate.2 hfresh)
  change entry.2 ∈ blocked ∨ entry.2 ∈ (neighbors.foldr step []).map Prod.snd
  exact cover neighbors [] entry h

private theorem neighbors_replay_from
    (input : SolverInput) (transitions : List TypedTransition)
    (start : Marking) (path : List String) (m : Marking)
    (hpath : pathReplay input start path = some m)
    {nextPath : List String} {next : Marking}
    (hnext : (nextPath, next) ∈ neighborsFrom input transitions path m) :
    pathReplay input start nextPath = some next := by
  induction transitions with
  | nil => cases hnext
  | cons t rest ih =>
    change (nextPath, next) ∈
      (match stepAt input m t.identity with
       | some after => (path ++ [t.identity], after) :: neighborsFrom input rest path m
       | none => neighborsFrom input rest path m) at hnext
    cases hs : stepAt input m t.identity with
    | none =>
      simp [hs] at hnext
      exact ih hnext
    | some _ =>
      have hnext' := hnext
      simp [hs] at hnext'
      cases hnext' with
      | inl heq =>
        cases heq
        subst_vars
        rw [pathReplay_append]
        simp [hpath, pathReplay, hs]
      | inr htail =>
        exact ih htail

private theorem neighbors_replay
    (input : SolverInput) (start : Marking) (path : List String) (m : Marking)
    (hpath : pathReplay input start path = some m)
    {nextPath : List String} {next : Marking}
    (hnext : (nextPath, next) ∈ neighborsOf input path m) :
    pathReplay input start nextPath = some next := by
  exact neighbors_replay_from input input.transitions start path m hpath hnext
private theorem neighborsFrom_complete
    (input : SolverInput) (transitions : List TypedTransition)
    (path : List String) (m : Marking) (t : TypedTransition)
    (ht : t ∈ transitions) {next : Marking}
    (hs : stepAt input m t.identity = some next) :
    (path ++ [t.identity], next) ∈ neighborsFrom input transitions path m := by
  induction transitions with
  | nil => cases ht
  | cons head rest ih =>
      have hcases : t = head ∨ t ∈ rest := List.mem_cons.mp ht
      cases hcases with
      | inl hheadEq =>
          subst t
          change (path ++ [head.identity], next) ∈
            (match stepAt input m head.identity with
            | some after => (path ++ [head.identity], after) :: neighborsFrom input rest path m
            | none => neighborsFrom input rest path m)
          cases hhead : stepAt input m head.identity with
          | none => simp [hhead] at hs
          | some after =>
              have heq : after = next := Option.some.inj (hhead.symm.trans hs)
              simp [hhead, heq]
      | inr htail =>
          change (path ++ [t.identity], next) ∈
            (match stepAt input m head.identity with
            | some after => (path ++ [head.identity], after) :: neighborsFrom input rest path m
            | none => neighborsFrom input rest path m)
          cases hhead : stepAt input m head.identity with
          | none =>
              simp [hhead]
              exact ih htail
          | some after =>
              simp [hhead]
              exact Or.inr (ih htail)

private def QueueReplay (input : SolverInput) (queue : List (List String × Marking)) : Prop :=
  ∀ path m, (path, m) ∈ queue → pathReplay input input.marking path = some m
private def ClosureCovered (input : SolverInput)
    (queue : List (List String × Marking)) (visited : List Marking) : Prop :=
  ∀ m, m ∈ visited →
    ∀ t, t ∈ input.transitions →
      ∀ n, stepAt input m t.identity = some n →
        n ∈ visited ∨ n ∈ queue.map Prod.snd

private theorem closureCovered_expand
    (input : SolverInput) (path : List String) (m : Marking)
    (rest : List (List String × Marking)) (visited : List Marking)
    (hcovered : ClosureCovered input ((path, m) :: rest) visited) :
    ClosureCovered input
      (rest ++ freshNeighbors (neighborsOf input path m)
        (m :: visited ++ rest.map Prod.snd))
      (m :: visited) := by
  intro x hx t ht n hs
  change x ∈ m :: visited at hx
  cases List.mem_cons.mp hx with
  | inl hxm =>
      subst x
      have hneigh := neighborsFrom_complete input input.transitions path m t ht hs
      cases freshNeighbors_covers hneigh with
      | inl hblocked =>
          change n ∈ m :: visited ++ rest.map Prod.snd at hblocked
          rcases List.mem_append.mp hblocked with hv | hrest
          · exact Or.inl hv
          · exact Or.inr (by
              simp only [List.map_append]
              exact List.mem_append.mpr (Or.inl hrest))
      | inr hfresh =>
          exact Or.inr (by
            simp only [List.map_append]
            exact List.mem_append.mpr (Or.inr hfresh))
  | inr hxv =>
      rcases hcovered x (by exact hxv) t ht n hs with hv | hq
      · exact Or.inl (by simp [hv])
      · simp only [List.map_cons] at hq
        rcases List.mem_cons.mp hq with hhead | hrest
        · exact Or.inl (List.mem_cons.mpr (Or.inl hhead))
        · exact Or.inr (by
            simp only [List.map_append]
            exact List.mem_append.mpr (Or.inl hrest))



private theorem queueReplay_append (input : SolverInput)
    {left right : List (List String × Marking)}
    (hl : QueueReplay input left) (hr : QueueReplay input right) :
    QueueReplay input (left ++ right) := by
  intro path m h
  cases List.mem_append.mp h with
  | inl hleft => exact hl path m hleft
  | inr hright => exact hr path m hright

inductive ExploreOutcome where
  | found (path : List String) (marking : Marking)
  | closed (visited : List Marking)
  | boundHit (visited : List Marking)

private def explore (input : SolverInput) : Nat → List (List String × Marking) → List Marking → ExploreOutcome
  | _, [], visited => .closed visited
  | 0, (path, m) :: _, visited =>
      if evalGoal m input.goal then .found path m else .boundHit (m :: visited)
  | fuel + 1, (path, m) :: rest, visited =>
      if evalGoal m input.goal then .found path m
      else
        let visited' := m :: visited
        let blocked := visited' ++ rest.map (fun pr => pr.2)
        let neighbors := freshNeighbors (neighborsOf input path m) blocked
        explore input fuel (rest ++ neighbors) visited'

def checkReachability (input : SolverInput) : ReachabilityResult :=
  match validate input with
  | some reason => .invalid reason
  | none =>
    if bindingBoundExceeded input then
      .unknown (.bindingBoundExhausted input.bound.maxBindings)
    else
      match explore input input.bound.maxSearchSteps [([], input.marking)] [] with
      | .found path m => .reachable { path := path, finalMarking := m }
      | .closed visited => .unreachable { exploredMarkings := visited, steps := visited.length, frontier := [] }
      | .boundHit _ => .unknown (.searchStepBoundExhausted input.bound.maxSearchSteps)

private theorem explore_found_sound (input : SolverInput) :
    ∀ fuel queue visited path m,
      QueueReplay input queue →
      explore input fuel queue visited = .found path m →
      pathReplay input input.marking path = some m ∧ evalGoal m input.goal = true := by
  intro fuel
  induction fuel with
  | zero =>
    intro queue visited path m hqueue hresult
    cases queue with
    | nil => simp [explore] at hresult
    | cons entry rest =>
      cases entry with
      | mk entryPath entryMarking =>
        simp only [explore] at hresult
        split at hresult
        · injection hresult with hpath hmark
          subst hpath
          subst hmark
          exact ⟨hqueue entryPath entryMarking (by simp), by assumption⟩
        · simp at hresult
  | succ fuel ih =>
    intro queue visited path m hqueue hresult
    cases queue with
    | nil => simp [explore] at hresult
    | cons entry rest =>
      cases entry with
      | mk entryPath entryMarking =>
        simp only [explore] at hresult
        split at hresult
        · injection hresult with hpath hmark
          subst hpath
          subst hmark
          exact ⟨hqueue entryPath entryMarking (by simp), by assumption⟩
        · have hentry : pathReplay input input.marking entryPath = some entryMarking :=
            hqueue entryPath entryMarking (by simp)
          let visited' := entryMarking :: visited
          let blocked := visited' ++ rest.map (fun pr => pr.2)
          let neighbors := freshNeighbors (neighborsOf input entryPath entryMarking) blocked
          have hrest : QueueReplay input rest := by
            intro p n hp
            exact hqueue p n (by simp [hp])
          have hfresh : QueueReplay input neighbors := by
            intro p n hp
            have hmem : (p, n) ∈ neighborsOf input entryPath entryMarking :=
              freshNeighbors_mem hp
            exact neighbors_replay input input.marking entryPath entryMarking hentry hmem
          have hqueue' : QueueReplay input (rest ++ neighbors) :=
            queueReplay_append input hrest hfresh
          exact ih (rest ++ neighbors) visited' path m hqueue' hresult

private theorem explore_closed_no_goal (input : SolverInput) :
    ∀ fuel queue visited explored,
      QueueReplay input queue →
      (∀ m, m ∈ visited → evalGoal m input.goal = false) →
      explore input fuel queue visited = .closed explored →
      (∀ m, m ∈ explored → evalGoal m input.goal = false) ∧
        explored.length ≤ visited.length + fuel := by
  intro fuel
  induction fuel with
  | zero =>
    intro queue visited explored hqueue hvisited hresult
    cases queue with
    | nil => simp [explore] at hresult; cases hresult; exact ⟨hvisited, by omega⟩
    | cons entry rest =>
      cases entry with
      | mk path m =>
        cases hgoal : evalGoal m input.goal <;> simp [explore, hgoal] at hresult
  | succ fuel ih =>
    intro queue visited explored hqueue hvisited hresult
    cases queue with
    | nil => simp [explore] at hresult; cases hresult; exact ⟨hvisited, by omega⟩
    | cons entry rest =>
      cases entry with
      | mk path m =>
        simp only [explore] at hresult
        split at hresult
        · simp at hresult
        · let visited' := m :: visited
          let blocked := visited' ++ rest.map (fun pr => pr.2)
          let neighbors := freshNeighbors (neighborsOf input path m) blocked
          have hrest : QueueReplay input rest := by
            intro p n hp
            exact hqueue p n (by simp [hp])
          have hentry : pathReplay input input.marking path = some m :=
            hqueue path m (by simp)
          have hfresh : QueueReplay input neighbors := by
            intro p n hp
            exact neighbors_replay input input.marking path m hentry (freshNeighbors_mem hp)
          have hqueue' : QueueReplay input (rest ++ neighbors) :=
            queueReplay_append input hrest hfresh
          have hcurrent : evalGoal m input.goal = false := by
            cases hgoal : evalGoal m input.goal with
            | false => rfl
            | true =>
                have hnot : ¬ evalGoal m input.goal = true := by assumption
                exact False.elim (hnot hgoal)
          have hvisited' : ∀ n, n ∈ visited' → evalGoal n input.goal = false := by
            intro n hn
            change n ∈ m :: visited at hn
            have hn' : n = m ∨ n ∈ visited := List.mem_cons.mp hn
            cases hn' with
            | inl hnm => subst n; exact hcurrent
            | inr hrest => exact hvisited n hrest
          have hsub := ih (rest ++ neighbors) visited' explored hqueue' hvisited' hresult
          refine ⟨?_, ?_⟩
          · intro n hn
            exact hsub.1 n (by simpa [visited'] using hn)
          · have hlen := hsub.2
            simp [visited'] at hlen
            omega
private theorem explore_closed_complete (input : SolverInput) :
    ∀ fuel queue visited final,
      (input.marking ∈ visited ∨ input.marking ∈ queue.map Prod.snd) →
      ClosureCovered input queue visited →
      explore input fuel queue visited = .closed final →
      input.marking ∈ final ∧
        (∀ m, m ∈ final → ∀ t, t ∈ input.transitions → ∀ n,
          stepAt input m t.identity = some n → n ∈ final) := by
  intro fuel
  induction fuel with
  | zero =>
      intro queue visited final hroot hcovered hresult
      cases queue with
      | nil =>
          simp [explore] at hresult
          cases hresult
          refine ⟨hroot.resolve_right (by simp), ?_⟩
          intro m hm t ht n hs
          exact (hcovered m hm t ht n hs).resolve_right (by simp)
      | cons entry rest =>
          cases entry with
          | mk path m =>
              cases hgoal : evalGoal m input.goal <;> simp [explore, hgoal] at hresult
  | succ fuel ih =>
      intro queue visited final hroot hcovered hresult
      cases queue with
      | nil =>
          simp [explore] at hresult
          cases hresult
          exact ⟨hroot.resolve_right (by simp), by
            intro m hm t ht n hs
            exact (hcovered m hm t ht n hs).resolve_right (by simp)⟩
      | cons entry rest =>
          rcases entry with ⟨path, current⟩
          simp only [explore] at hresult
          split at hresult
          · simp at hresult
          · let visited' := current :: visited
            let blocked := visited' ++ rest.map Prod.snd
            let neighbors := freshNeighbors (neighborsOf input path current) blocked
            let queue' := rest ++ neighbors
            have hroot' : input.marking ∈ visited' ∨
                input.marking ∈ queue'.map Prod.snd := by
              rcases hroot with hv | hq
              · exact Or.inl (List.mem_cons_of_mem current hv)
              · simp only [List.map_cons] at hq
                rcases List.mem_cons.mp hq with hhead | hrest
                · exact Or.inl (List.mem_cons.mpr (Or.inl hhead))
                · exact Or.inr (by
                    dsimp [queue']
                    rw [List.map_append]
                    exact List.mem_append.mpr (Or.inl hrest))
            have hcovered' := closureCovered_expand input path current rest visited hcovered
            have hresult' : explore input fuel queue' visited' = .closed final := by
              simpa [queue', visited', blocked, neighbors] using hresult
            exact ih queue' visited' final hroot' hcovered' hresult'


theorem reachableWitnessSound (input : SolverInput) (w : ReachabilityWitness)
    (h : checkReachability input = .reachable w) :
    validate input = none ∧
      bindingBoundExceeded input = false ∧
      pathReplay input input.marking w.path = some w.finalMarking ∧
      pathEnabled input input.marking w.path = true ∧
      evalGoal w.finalMarking input.goal = true := by
  unfold checkReachability at h
  cases hv : validate input with
  | some reason => simp [hv] at h
  | none =>
    rw [hv] at h
    cases hb : bindingBoundExceeded input with
    | true => simp [hb] at h
    | false =>
      rw [hb] at h
      cases he : explore input input.bound.maxSearchSteps [([], input.marking)] [] with
      | found p m =>
        rw [he] at h
        cases h
        have hqueue : QueueReplay input [([], input.marking)] := by
          intro path marking hmemb
          have hmemb' : path = [] ∧ marking = input.marking := by simpa using hmemb
          rcases hmemb' with ⟨rfl, rfl⟩
          rfl
        have hs := explore_found_sound input input.bound.maxSearchSteps [([], input.marking)] [] p m hqueue he
        refine ⟨rfl, rfl, hs.1, ?_, hs.2⟩
        exact pathReplayEnabled input input.marking p hs.1
      | closed explored => simp [he] at h
      | boundHit explored => simp [he] at h

theorem reachableWitnessPathExec (input : SolverInput) (w : ReachabilityWitness)
    (h : checkReachability input = .reachable w) :
    PathExec input input.marking w.path w.finalMarking := by
  rcases reachableWitnessSound input w h with ⟨hvalid, _, hpath, _, _⟩
  exact pathReplay_implies_pathExec input hvalid hpath

theorem closureWitnessSound (input : SolverInput) (w : ClosureWitness)
    (h : checkReachability input = .unreachable w) :
    validate input = none ∧
      bindingBoundExceeded input = false ∧
      w.frontier = [] ∧
      w.exploredMarkings.length > 0 ∧
      input.marking ∈ w.exploredMarkings ∧
      (∀ m, m ∈ w.exploredMarkings →
        ∀ t, t ∈ input.transitions →
          ∀ n, stepAt input m t.identity = some n → n ∈ w.exploredMarkings) ∧
      w.steps ≤ input.bound.maxSearchSteps ∧
      (∀ m, m ∈ w.exploredMarkings → evalGoal m input.goal = false) := by
  unfold checkReachability at h
  cases hv : validate input with
  | some reason => simp [hv] at h
  | none =>
    rw [hv] at h
    cases hb : bindingBoundExceeded input with
    | true => simp [hb] at h
    | false =>
      rw [hb] at h
      cases he : explore input input.bound.maxSearchSteps [([], input.marking)] [] with
      | found p m => simp [he] at h
      | boundHit visited => simp [he] at h
      | closed visited =>
        rw [he] at h
        cases h
        have hqueue : QueueReplay input [([], input.marking)] := by
          intro path marking hmemb
          have hmemb' : path = [] ∧ marking = input.marking := by simpa using hmemb
          rcases hmemb' with ⟨rfl, rfl⟩
          rfl
        have hcovered : ClosureCovered input [([], input.marking)] [] := by
          intro m hm t ht n hs
          simp at hm
        have hcomplete := explore_closed_complete input input.bound.maxSearchSteps
          [([], input.marking)] [] visited (by simp) hcovered he
        have hs := explore_closed_no_goal input input.bound.maxSearchSteps [([], input.marking)] [] visited hqueue
          (by simp) he
        have hrootmem := hcomplete.1
        have hnonempty : visited.length > 0 := by
          cases visited with
          | nil => simp at hrootmem
          | cons head tail => simp
        exact ⟨rfl, rfl, rfl, hnonempty, hcomplete.1, hcomplete.2,
          by simpa using hs.2, hs.1⟩

theorem boundSoundness (input : SolverInput) (visited : List Marking)
    (hvalid : validate input = none) (hbound : bindingBoundExceeded input = false)
    (h : explore input input.bound.maxSearchSteps [([], input.marking)] [] = .closed visited) :
    checkReachability input = .unreachable
      { exploredMarkings := visited, steps := visited.length, frontier := [] } ∧
      visited.length > 0 ∧
      input.marking ∈ visited ∧
      (∀ m, m ∈ visited →
        ∀ t, t ∈ input.transitions →
          ∀ n, stepAt input m t.identity = some n → n ∈ visited) ∧
      (∀ m, m ∈ visited → evalGoal m input.goal = false) ∧
      visited.length ≤ input.bound.maxSearchSteps := by
  have hres : checkReachability input = .unreachable
      { exploredMarkings := visited, steps := visited.length, frontier := [] } := by
    simp [checkReachability, hvalid, hbound, h]
  have hqueue : QueueReplay input [([], input.marking)] := by
    intro path marking hmemb
    have heq : (path, marking) = ([], input.marking) := by simpa using hmemb
    cases heq
    rfl
  have hcovered : ClosureCovered input [([], input.marking)] [] := by
    intro m hm t ht n hs
    simp at hm
  have hcomplete := explore_closed_complete input input.bound.maxSearchSteps
    [([], input.marking)] [] visited (by simp) hcovered h
  have hs := explore_closed_no_goal input input.bound.maxSearchSteps [([], input.marking)] [] visited hqueue
    (by simp) h
  have hrootmem := hcomplete.1
  have hne : visited ≠ [] := by
    intro hnil
    subst visited
    simp at hrootmem
  have hnonempty : visited.length > 0 := by
    cases visited with
    | nil => exact False.elim (hne rfl)
    | cons head tail => simp
  exact ⟨hres, hnonempty, hcomplete.1, hcomplete.2, hs.1,
    by simpa using hs.2⟩

theorem boundExhaustionIsUnknown (input : SolverInput) (visited : List Marking)
    (hvalid : validate input = none) (hbound : bindingBoundExceeded input = false)
    (h : explore input input.bound.maxSearchSteps [([], input.marking)] [] = .boundHit visited) :
    checkReachability input = .unknown (.searchStepBoundExhausted input.bound.maxSearchSteps) := by
  simp [checkReachability, hvalid, hbound, h]

theorem bindingBoundExhaustionIsUnknown (input : SolverInput)
    (hvalid : validate input = none) (hbound : bindingBoundExceeded input = true) :
    checkReachability input = .unknown (.bindingBoundExhausted input.bound.maxBindings) := by
  simp [checkReachability, hvalid, hbound]

/-! Deadlock -/

def checkDeadlock (input : SolverInput) : DeadlockResult :=
  match validate input with
  | some reason => .invalid reason
  | none =>
    if bindingBoundExceeded input then
      .unknown (.bindingBoundExhausted input.bound.maxBindings)
    else
      match deriveEnabled input with
      | .invalid reason => .invalid reason
      | .enabledSet s =>
        if evalGoal input.marking input.goal then
          .notDeadlocked s
        else if s.enabled.isEmpty then
          .deadlocked { marking := input.marking }
        else
          .notDeadlocked s

theorem deadlockGoalSeparation (input : SolverInput) (w : DeadlockWitness)
    (h : checkDeadlock input = .deadlocked w) :
    evalGoal input.marking input.goal = false ∧
      checkDeadlockGoalSeparation (evalGoal input.marking input.goal) true = true := by
  unfold checkDeadlock at h
  cases hv : validate input with
  | some reason => rw [hv] at h; cases h
  | none =>
    rw [hv] at h
    cases hb : bindingBoundExceeded input with
    | true => rw [hb] at h; simp at h
    | false =>
      rw [hb] at h
      cases hd : deriveEnabled input with
      | invalid reason => rw [hd] at h; cases h
      | enabledSet s =>
        rw [hd] at h
        by_cases hg : evalGoal input.marking input.goal = true
        · rw [hg] at h; simp at h
        · have hg' : evalGoal input.marking input.goal = false := by
            cases hbool : evalGoal input.marking input.goal
            · rfl
            · exact absurd hbool hg
          refine ⟨hg', ?_⟩
          simp [checkDeadlockGoalSeparation, hg']

/-! Well-foundedness -/

def totalTokens (m : Marking) : Nat :=
  m.places.foldl (fun acc p => acc + p.2.length) 0

private def suffixAfterPrefix : List String → List String → Option (List String)
  | [], rest => some rest
  | _ :: _, [] => none
  | prefixHead :: prefixRest, restHead :: restRest =>
    if prefixHead == restHead then suffixAfterPrefix prefixRest restRest else none

private theorem suffixAfterPrefix_exists {prePath full : List String}
    (hprefix : ∃ tail, full = prePath ++ tail) :
    ∃ suffix, suffixAfterPrefix prePath full = some suffix := by
  induction prePath generalizing full with
  | nil =>
      exact ⟨full, by simp [suffixAfterPrefix]⟩
  | cons ph pt ih =>
      cases full with
      | nil =>
          rcases hprefix with ⟨tail, h⟩
          simp at h
      | cons fh ft =>
          rcases hprefix with ⟨tail, h⟩
          cases h
          have hrest : ∃ suffix, suffixAfterPrefix pt (pt ++ tail) = some suffix :=
            ih ⟨tail, rfl⟩
          rcases hrest with ⟨suffix, hsuffix⟩
          exact ⟨suffix, by simp [suffixAfterPrefix, hsuffix]⟩

private theorem suffixAfterPrefix_spec {prePath full suffix : List String}
    (hprefix : ∃ tail, full = prePath ++ tail)
    (hsuffix : suffixAfterPrefix prePath full = some suffix) :
    full = prePath ++ suffix := by
  induction prePath generalizing full suffix with
  | nil => simp [suffixAfterPrefix] at hsuffix; subst hsuffix; rfl
  | cons ph pt ih =>
    cases full with
    | nil => simp [suffixAfterPrefix] at hsuffix
    | cons fh ft =>
      simp only [suffixAfterPrefix] at hsuffix
      split at hsuffix
      · next heq =>
        have htail : ∃ tail, ft = pt ++ tail := by
          rcases hprefix with ⟨tail, h⟩
          cases h
          simp at *
        have hspec := ih htail hsuffix
        have heq' : ph = fh := eq_of_beq heq
        cases heq'
        simp [hspec, List.cons_append]
      · simp at hsuffix

private def activePathPrefix (path : List String)
    (active : List (List String × Marking)) : Prop :=
  ∀ ancestorPath ancestor, (ancestorPath, ancestor) ∈ active →
    ∃ tail, path = ancestorPath ++ tail

private def activeReplay (input : SolverInput)
    (active : List (List String × Marking)) : Prop :=
  ∀ path marking, (path, marking) ∈ active →
    pathReplay input input.marking path = some marking

private def findActive (marking : Marking) : List (List String × Marking) →
    Option (List String × Marking)
  | [] => none
  | entry :: rest =>
    if entry.2 == marking then some entry else findActive marking rest

private def cycleCandidate (active : List (List String × Marking))
    (current : Marking) (neighbors : List (List String × Marking)) :
    Option (List String × List String × Marking × Marking × Marking) :=
  match neighbors with
  | [] => none
  | (nextPath, next) :: rest =>
    match findActive next active with
    | some (prefixPath, cycleStart) =>
      some (prefixPath,
        (suffixAfterPrefix prefixPath nextPath).getD nextPath,
        cycleStart, cycleStart, current)
    | none => cycleCandidate active current rest

inductive CycleOutcome where
  | cycleFound (prefixPath cyclePath : List String)
      (cycleStart cycleEnd closingSource : Marking)
  | closedNoCycle (visited : List Marking)
  | boundHit (visited : List Marking)

private abbrev WFEntry := List String × List (List String × Marking) × Marking

private def exploreWF (input : SolverInput) :
    Nat → List WFEntry → List Marking → CycleOutcome
  | _, [], explored => .closedNoCycle explored
  | 0, _ :: _, explored => .boundHit explored
  | fuel + 1, (path, active, m) :: rest, explored =>
    if explored.contains m then
      exploreWF input fuel rest explored
    else
      let neighbors := neighborsOf input path m
      match cycleCandidate active m neighbors with
      | some (prefixPath, cyclePath, cycleStart, cycleEnd, closingSource) =>
        .cycleFound prefixPath cyclePath cycleStart cycleEnd closingSource
      | none =>
        let explored' := m :: explored
        let blocked := active.map (fun entry => entry.2) ++ explored'
        let fresh := freshNeighbors neighbors blocked
        let entries := fresh.map (fun pr =>
          (pr.1, (pr.1, pr.2) :: active, pr.2))
        exploreWF input fuel (entries ++ rest) explored'

private def findFiniteCycle (input : SolverInput) :
    Nat → List String → List (List String × Marking) → Marking →
      Option (List String × List String × Marking × Marking × Marking)
  | 0, _, _, _ => none
  | fuel + 1, path, active, m =>
      let neighbors := neighborsOf input path m
      match cycleCandidate active m neighbors with
      | some candidate => some candidate
      | none =>
          firstSome (freshNeighbors neighbors (active.map Prod.snd)) (fun pr =>
            findFiniteCycle input fuel pr.1 ((pr.1, pr.2) :: active) pr.2)

private def cycleResult (prefixPath cyclePath : List String)
    (cycleStart cycleEnd closingSource : Marking) : WellFoundednessResult :=
  .notWellFounded
    { prefixPath := prefixPath,
      cyclePath := cyclePath,
      cycleStart := cycleStart,
      cycleEnd := cycleEnd,
      measureDecreasing := totalTokens cycleEnd < totalTokens closingSource }

def checkWellFoundedness (input : SolverInput) : WellFoundednessResult :=
  match validate input with
  | some reason => .invalid reason
  | none =>
    if bindingBoundExceeded input then
      .unknown (.bindingBoundExhausted input.bound.maxBindings)
    else
      match exploreWF input input.bound.maxSearchSteps
          [([], [([], input.marking)], input.marking)] [] with
      | .cycleFound prefixPath cyclePath cycleStart cycleEnd closingSource =>
          cycleResult prefixPath cyclePath cycleStart cycleEnd closingSource
      | .closedNoCycle explored =>
          match findFiniteCycle input explored.length []
              [([], input.marking)] input.marking with
          | some (prefixPath, cyclePath, cycleStart, cycleEnd, closingSource) =>
              cycleResult prefixPath cyclePath cycleStart cycleEnd closingSource
          | none =>
              .wellFounded
                { exploredMarkings := explored,
                  steps := explored.length,
                  frontier := [] }
      | .boundHit _ => .unknown (.searchStepBoundExhausted input.bound.maxSearchSteps)

private def WFQueueReplay (input : SolverInput) (queue : List WFEntry) : Prop :=
  ∀ path active marking, (path, active, marking) ∈ queue →
    pathReplay input input.marking path = some marking ∧
    activeReplay input active ∧ activePathPrefix path active

private theorem activeReplay_mem
    (input : SolverInput) (active : List (List String × Marking))
    (hactive : activeReplay input active)
    {path : List String} {marking : Marking}
    (hmem : (path, marking) ∈ active) :
    pathReplay input input.marking path = some marking := by
  exact hactive path marking hmem

private theorem activePrefix_mem
    (path : List String) (active : List (List String × Marking))
    (hactive : activePathPrefix path active)
    {ancestorPath : List String} {ancestor : Marking}
    (hmem : (ancestorPath, ancestor) ∈ active) :
    ∃ tail, path = ancestorPath ++ tail := by
  exact hactive ancestorPath ancestor hmem

private theorem findActive_sound (marking : Marking)
    (active : List (List String × Marking))
    {path : List String} {ancestor : Marking}
    (h : findActive marking active = some (path, ancestor)) :
    (path, ancestor) ∈ active ∧ ancestor = marking := by
  induction active with
  | nil => simp [findActive] at h
  | cons entry rest ih =>
    cases entry with
    | mk entryPath entryMarking =>
      simp only [findActive] at h
      split at h
      · next heq =>
        have heq' : entryMarking = marking := eq_of_beq heq
        cases h
        exact ⟨by simp, heq'⟩
      · have hrest := ih h
        exact ⟨List.mem_cons_of_mem (entryPath, entryMarking) hrest.1, hrest.2⟩

private theorem neighbors_path_shape_from
    (input : SolverInput) (transitions : List TypedTransition)
    (path : List String) (m : Marking)
    {nextPath : List String} {next : Marking}
    (h : (nextPath, next) ∈ neighborsFrom input transitions path m) :
    ∃ transitionId, nextPath = path ++ [transitionId] := by
  induction transitions with
  | nil => simp [neighborsFrom] at h
  | cons t rest ih =>
    change (nextPath, next) ∈
      (match stepAt input m t.identity with
       | some after => (path ++ [t.identity], after) :: neighborsFrom input rest path m
       | none => neighborsFrom input rest path m) at h
    cases hs : stepAt input m t.identity with
    | none =>
      simp [hs] at h
      exact ih h
    | some _ =>
      have h' := h
      simp [hs] at h'
      cases h' with
      | inl heq => exact ⟨t.identity, heq.1⟩
      | inr htail => exact ih htail

private theorem neighbors_path_shape
    (input : SolverInput) (path : List String) (m : Marking)
    {nextPath : List String} {next : Marking}
    (h : (nextPath, next) ∈ neighborsOf input path m) :
    ∃ transitionId, nextPath = path ++ [transitionId] := by
  exact neighbors_path_shape_from input input.transitions path m h

private theorem cycleCandidate_sound_list
    (input : SolverInput) (path : List String)
    (active : List (List String × Marking)) (current : Marking)
    (hpath : pathReplay input input.marking path = some current)
    (hactiveReplay : activeReplay input active)
    (hactivePrefix : activePathPrefix path active) :
    ∀ neighbors {prefixPath cyclePath : List String}
      {cycleStart cycleEnd closingSource : Marking},
      (∀ {nextPath : List String} {next : Marking},
        (nextPath, next) ∈ neighbors →
        pathReplay input input.marking nextPath = some next) →
      (∀ {nextPath : List String} {next : Marking},
        (nextPath, next) ∈ neighbors →
        ∃ transitionId, nextPath = path ++ [transitionId]) →
      cycleCandidate active current neighbors =
        some (prefixPath, cyclePath, cycleStart, cycleEnd, closingSource) →
      pathReplay input input.marking prefixPath = some cycleStart ∧
        pathReplay input cycleStart cyclePath = some cycleEnd ∧
        cyclePath ≠ [] ∧ cycleStart = cycleEnd := by
  intro neighbors
  induction neighbors with
  | nil =>
      intro prefixPath cyclePath cycleStart cycleEnd closingSource hneighbors hshape hcandidate
      simp [cycleCandidate] at hcandidate
  | cons head rest ih =>
      intro prefixPath cyclePath cycleStart cycleEnd closingSource hneighbors hshape hcandidate
      cases head with
      | mk nextPath next =>
        simp only [cycleCandidate] at hcandidate
        cases hfind : findActive next active with
        | none =>
            simp only [hfind] at hcandidate
            exact ih
              (fun hmem => hneighbors (List.mem_cons_of_mem (nextPath, next) hmem))
              (fun hmem => hshape (List.mem_cons_of_mem (nextPath, next) hmem))
              hcandidate
        | some ancestor =>
            cases ancestor with
            | mk ancestorPath ancestorMarking =>
              simp only [hfind] at hcandidate
              injection hcandidate with htuple
              injection htuple with hprefix hrest
              subst hprefix
              injection hrest with hcycle hrest
              injection hrest with hstart hrest
              subst hstart
              injection hrest with hend hsource
              subst hend
              subst hsource
              have hfind' := findActive_sound next active hfind
              have hancestorReplay :=
                hactiveReplay ancestorPath ancestorMarking hfind'.1
              have hnextReplay := hneighbors (List.mem_cons_self : (nextPath, next) ∈ (nextPath, next) :: rest)
              have hshapeNext := hshape (List.mem_cons_self : (nextPath, next) ∈ (nextPath, next) :: rest)
              rcases hshapeNext with ⟨transitionId, hnextShape⟩
              have hshapeCurrent : ∃ tail, path = ancestorPath ++ tail :=
                hactivePrefix ancestorPath ancestorMarking hfind'.1
              have hnextPrefix : ∃ tail, nextPath = ancestorPath ++ tail := by
                rcases hshapeCurrent with ⟨tail, htail⟩
                refine ⟨tail ++ [transitionId], ?_⟩
                simp [hnextShape, htail, List.append_assoc]
              rcases suffixAfterPrefix_exists hnextPrefix with ⟨suffix, hsuffix⟩
              have hspecSuffix : nextPath = ancestorPath ++ suffix :=
                suffixAfterPrefix_spec hnextPrefix hsuffix
              have hget :
                  (suffixAfterPrefix ancestorPath nextPath).getD nextPath = suffix := by
                simp [hsuffix]
              have hspec : nextPath = ancestorPath ++ cyclePath := by
                calc
                  nextPath = ancestorPath ++ suffix := hspecSuffix
                  _ = ancestorPath ++ (suffixAfterPrefix ancestorPath nextPath).getD nextPath := by
                    rw [hget]
                  _ = ancestorPath ++ cyclePath := by rw [hcycle]
              have hnonempty : cyclePath ≠ [] := by
                intro hempty
                subst hempty
                have hlen : nextPath.length = ancestorPath.length := by
                  simpa [hspec]
                rcases hshapeCurrent with ⟨tail, htail⟩
                simp [hnextShape, htail] at hlen
              have hconcat : pathReplay input input.marking
                  (ancestorPath ++ cyclePath) = some next := by
                rw [← hspec]
                exact hnextReplay
              rw [pathReplay_append, hancestorReplay] at hconcat
              rw [← hfind'.2] at hconcat
              exact ⟨hancestorReplay, hconcat, hnonempty, rfl⟩

private theorem cycleCandidate_sound
    (input : SolverInput) (path : List String)
    (active : List (List String × Marking)) (current : Marking)
    (hpath : pathReplay input input.marking path = some current)
    (hactiveReplay : activeReplay input active)
    (hactivePrefix : activePathPrefix path active)
    {prefixPath cyclePath : List String}
    {cycleStart cycleEnd closingSource : Marking}
    (hcandidate : cycleCandidate active current (neighborsOf input path current) =
      some (prefixPath, cyclePath, cycleStart, cycleEnd, closingSource)) :
    pathReplay input input.marking prefixPath = some cycleStart ∧
      pathReplay input cycleStart cyclePath = some cycleEnd ∧
      cyclePath ≠ [] ∧ cycleStart = cycleEnd := by
  exact cycleCandidate_sound_list input path active current hpath hactiveReplay hactivePrefix
    (neighborsOf input path current)
    (fun hmem => neighbors_replay input input.marking path current hpath hmem)
    (fun hmem => neighbors_path_shape input path current hmem)
    hcandidate
private theorem wfQueueReplay_append (input : SolverInput)
    {left right : List WFEntry}
    (hl : WFQueueReplay input left) (hr : WFQueueReplay input right) :
    WFQueueReplay input (left ++ right) := by
  intro path active marking h
  cases List.mem_append.mp h with
  | inl hleft => exact hl path active marking hleft
  | inr hright => exact hr path active marking hright

private theorem exploreWF_cycle_sound (input : SolverInput) :
    ∀ fuel queue explored prePath cycle start finish source,
      WFQueueReplay input queue →
      exploreWF input fuel queue explored =
        .cycleFound prePath cycle start finish source →
      pathReplay input input.marking prePath = some start ∧
        pathReplay input start cycle = some finish ∧
        cycle ≠ [] ∧ start = finish := by
  intro fuel
  induction fuel with
  | zero =>
      intro queue explored prePath cycle start finish source hqueue hresult
      cases queue with
      | nil => simp [exploreWF] at hresult
      | cons entry rest => simp [exploreWF] at hresult
  | succ fuel ih =>
      intro queue explored prePath cycle start finish source hqueue hresult
      cases queue with
      | nil => simp [exploreWF] at hresult
      | cons entry rest =>
          rcases entry with ⟨path, active, current⟩
          simp only [exploreWF] at hresult
          split at hresult
          · have hrest : WFQueueReplay input rest := by
              intro p a m hm
              exact hqueue p a m (by simp [hm])
            exact ih rest explored prePath cycle start finish source hrest hresult
          · let neighbors := neighborsOf input path current
            cases hc : cycleCandidate active current neighbors with
            | none =>
                rw [hc] at hresult
                let explored' := current :: explored
                let blocked := active.map (fun entry => entry.2) ++ explored'
                let fresh := freshNeighbors neighbors blocked
                let entries := fresh.map (fun pr =>
                  (pr.1, (pr.1, pr.2) :: active, pr.2))
                have hentry := hqueue path active current (by simp)
                have hfresh : WFQueueReplay input entries := by
                  intro p a m hm
                  rcases List.mem_map.mp hm with ⟨pr, hpr, heq⟩
                  cases heq
                  have hmem : pr ∈ neighbors := freshNeighbors_mem hpr
                  have hnext := neighbors_replay input input.marking path current
                    hentry.1 hmem
                  have hshape := neighbors_path_shape input path current hmem
                  refine ⟨hnext, ?_, ?_⟩
                  · intro ap am ham
                    simp only [activeReplay, List.mem_cons] at ham ⊢
                    cases ham with
                    | inl hhead =>
                        injection hhead with hp hm
                        subst hp
                        subst hm
                        exact hnext
                    | inr hold => exact hentry.2.1 ap am hold
                  · intro ap am ham
                    simp only [List.mem_cons] at ham
                    cases ham with
                    | inl hhead =>
                        injection hhead with hp hm
                        subst hp
                        subst hm
                        exact ⟨[], by simp⟩
                    | inr hold =>
                        rcases hentry.2.2 ap am hold with ⟨tail, htail⟩
                        rcases hshape with ⟨transitionId, hpath⟩
                        refine ⟨tail ++ [transitionId], ?_⟩
                        simp [hpath, htail, List.append_assoc]
                have hrest : WFQueueReplay input rest := by
                  intro p a m hm
                  exact hqueue p a m (by simp [hm])
                have hqueue' := wfQueueReplay_append input hfresh hrest
                have hresult' : exploreWF input fuel (entries ++ rest) explored' =
                    .cycleFound prePath cycle start finish source := by
                  simpa [entries, fresh, blocked, explored', neighbors] using hresult
                exact ih (entries ++ rest) explored' prePath cycle start finish source
                  hqueue' hresult'
            | some candidate =>
                cases candidate with
                | mk candidatePrefix candidateRest =>
                  cases candidateRest with
                  | mk candidateCycle candidateRest =>
                    cases candidateRest with
                    | mk candidateStart candidateRest =>
                      cases candidateRest with
                      | mk candidateFinish candidateSource =>
                        rw [hc] at hresult
                        have hentry := hqueue path active current (by simp)
                        have hsound := cycleCandidate_sound input path active current
                          hentry.1 hentry.2.1 hentry.2.2 hc
                        cases hresult
                        exact hsound



private theorem exploreWF_closed_nodup (input : SolverInput)
    : ∀ fuel queue explored visited,
      explored.Nodup →
      exploreWF input fuel queue explored = .closedNoCycle visited →
      visited.Nodup := by
  intro fuel
  induction fuel with
  | zero =>
      intro queue explored visited hnodup hresult
      cases queue with
      | nil =>
          simp [exploreWF] at hresult
          cases hresult
          exact hnodup
      | cons entry rest => simp [exploreWF] at hresult
  | succ fuel ih =>
      intro queue explored visited hnodup hresult
      cases queue with
      | nil =>
          simp [exploreWF] at hresult
          cases hresult
          exact hnodup
      | cons entry rest =>
          rcases entry with ⟨path, active, current⟩
          simp only [exploreWF] at hresult
          split at hresult
          · exact ih rest explored visited hnodup hresult
          · cases hc : cycleCandidate active current (neighborsOf input path current) with
            | some candidate => simp [hc] at hresult
            | none =>
                rw [hc] at hresult
                let explored' := current :: explored
                have hnot : current ∉ explored := by
                  intro hmem
                  simp [hmem] at *
                have hnodup' : explored'.Nodup := by
                  simpa [explored'] using
                    (List.nodup_cons.mpr ⟨hnot, hnodup⟩)
                let neighbors := neighborsOf input path current
                let blocked := active.map (fun entry => entry.2) ++ explored'
                let fresh := freshNeighbors neighbors blocked
                let entries := fresh.map (fun pr =>
                  (pr.1, (pr.1, pr.2) :: active, pr.2))
                exact ih (entries ++ rest) explored' visited hnodup' hresult

private theorem exploreWF_closed_bound (input : SolverInput)
    : ∀ fuel queue explored visited,
      exploreWF input fuel queue explored = .closedNoCycle visited →
      visited.length ≤ explored.length + fuel := by
  intro fuel
  induction fuel with
  | zero =>
      intro queue explored visited hresult
      cases queue with
      | nil =>
          simp [exploreWF] at hresult
          cases hresult
          omega
      | cons entry rest => simp [exploreWF] at hresult
  | succ fuel ih =>
      intro queue explored visited hresult
      cases queue with
      | nil =>
          simp [exploreWF] at hresult
          cases hresult
          omega
      | cons entry rest =>
          rcases entry with ⟨path, active, current⟩
          simp only [exploreWF] at hresult
          split at hresult
          · have hresult' : exploreWF input fuel rest explored = .closedNoCycle visited := by
              simpa using hresult
            have hbound := ih rest explored visited hresult'
            omega
          · cases hc : cycleCandidate active current (neighborsOf input path current) with
            | some candidate => simp [hc] at hresult
            | none =>
                rw [hc] at hresult
                let explored' := current :: explored
                let neighbors := neighborsOf input path current
                let blocked := active.map (fun entry => entry.2) ++ explored'
                let fresh := freshNeighbors neighbors blocked
                let entries := fresh.map (fun pr =>
                  (pr.1, (pr.1, pr.2) :: active, pr.2))
                have hresult' : exploreWF input fuel (entries ++ rest) explored' =
                    .closedNoCycle visited := by
                  simpa [entries, fresh, blocked, explored', neighbors] using hresult
                have hbound := ih (entries ++ rest) explored' visited hresult'
                simp [explored'] at hbound
                omega

private def WFQueueMarkings (queue : List WFEntry) : List Marking :=
  queue.map (fun entry => entry.2.2)

private def WFClosureCovered (input : SolverInput)
    (queue : List WFEntry) (explored : List Marking) : Prop :=
  ∀ m, m ∈ explored → ∀ t, t ∈ input.transitions →
    ∀ n, stepAt input m t.identity = some n →
      n ∈ explored ∨ n ∈ WFQueueMarkings queue

private def WFActiveProcessed (queue : List WFEntry)
    (explored : List Marking) : Prop :=
  ∀ path active m, (path, active, m) ∈ queue →
    ∀ ancestorPath ancestor, (ancestorPath, ancestor) ∈ active →
      ancestor = m ∨ ancestor ∈ explored

private theorem exploreWF_closed_complete (input : SolverInput) :
    ∀ fuel queue explored final,
      (input.marking ∈ explored ∨ input.marking ∈ WFQueueMarkings queue) →
      WFClosureCovered input queue explored →
      WFActiveProcessed queue explored →
      exploreWF input fuel queue explored = .closedNoCycle final →
      input.marking ∈ final ∧
        (∀ m, m ∈ final → ∀ t, t ∈ input.transitions →
          ∀ n, stepAt input m t.identity = some n → n ∈ final) := by
  intro fuel
  induction fuel with
  | zero =>
      intro queue explored final hroot hcovered hactive hresult
      cases queue with
      | nil =>
          simp [exploreWF] at hresult
          cases hresult
          refine ⟨hroot.resolve_right (by simp [WFQueueMarkings]), ?_⟩
          intro m hm t ht n hs
          exact (hcovered m hm t ht n hs).resolve_right (by simp [WFQueueMarkings])
      | cons entry rest => simp [exploreWF] at hresult
  | succ fuel ih =>
      intro queue explored final hroot hcovered hactive hresult
      cases queue with
      | nil =>
          simp [exploreWF] at hresult
          cases hresult
          refine ⟨hroot.resolve_right (by simp [WFQueueMarkings]), ?_⟩
          intro m hm t ht n hs
          exact (hcovered m hm t ht n hs).resolve_right (by simp [WFQueueMarkings])
      | cons entry rest =>
          rcases entry with ⟨path, active, current⟩
          simp only [exploreWF] at hresult
          split at hresult
          · have hcurrent : current ∈ explored :=
              List.contains_iff_mem.mp (by assumption)
            have hroot' : input.marking ∈ explored ∨
                input.marking ∈ WFQueueMarkings rest := by
              rcases hroot with hv | hq
              · exact Or.inl hv
              · simp only [WFQueueMarkings, List.map_cons] at hq
                rcases List.mem_cons.mp hq with hhead | htail
                · exact Or.inl (hhead ▸ hcurrent)
                · exact Or.inr htail
            have hcovered' : WFClosureCovered input rest explored := by
              intro m hm t ht n hs
              rcases hcovered m hm t ht n hs with hv | hq
              · exact Or.inl hv
              · simp only [WFQueueMarkings, List.map_cons] at hq
                rcases List.mem_cons.mp hq with hhead | htail
                · exact Or.inl (hhead ▸ hcurrent)
                · exact Or.inr htail
            have hactive' : WFActiveProcessed rest explored := by
              intro p a m hentry ap am ha
              exact hactive p a m (by simp [hentry]) ap am ha
            exact ih rest explored final hroot' hcovered' hactive' hresult
          · cases hc : cycleCandidate active current (neighborsOf input path current) with
            | some candidate => simp [hc] at hresult
            | none =>
                rw [hc] at hresult
                let explored' := current :: explored
                let neighbors := neighborsOf input path current
                let blocked := active.map Prod.snd ++ explored'
                let fresh := freshNeighbors neighbors blocked
                let entries : List WFEntry := fresh.map (fun pr =>
                  (pr.1, (pr.1, pr.2) :: active, pr.2))
                let queue' := entries ++ rest
                have hroot' : input.marking ∈ explored' ∨
                    input.marking ∈ WFQueueMarkings queue' := by
                  rcases hroot with hv | hq
                  · exact Or.inl (List.mem_cons_of_mem current hv)
                  · simp only [WFQueueMarkings, List.map_cons] at hq
                    rcases List.mem_cons.mp hq with hhead | htail
                    · exact Or.inl (by simpa [explored'] using
                        (List.mem_cons.mpr (Or.inl hhead)))
                    · exact Or.inr (by
                        simp only [WFQueueMarkings, queue', List.map_append]
                        exact List.mem_append.mpr (Or.inr htail))
                have hcovered' : WFClosureCovered input queue' explored' := by
                  intro m hm t ht n hs
                  rcases List.mem_cons.mp hm with hhere | hold
                  · subst m
                    have hneighbor :
                        (path ++ [t.identity], n) ∈ neighbors :=
                      neighborsFrom_complete input input.transitions path current t ht hs
                    rcases freshNeighbors_covers
                        (neighbors := neighbors) (blocked := blocked) hneighbor with
                      hblocked | hfresh
                    · rcases List.mem_append.mp hblocked with ha | hv
                      · rcases List.mem_map.mp ha with ⟨pr, hpr, hprn⟩
                        rcases hactive path active current (by simp) pr.1 pr.2 hpr with
                          heq | hprev
                        · exact Or.inl (by
                            change n ∈ current :: explored
                            have hn : pr.2 = n := hprn
                            rw [← hn]
                            exact List.mem_cons.mpr (Or.inl heq))
                        · exact Or.inl (by
                            change n ∈ current :: explored
                            have hn : pr.2 = n := hprn
                            rw [← hn]
                            exact List.mem_cons_of_mem current hprev)
                      · exact Or.inl hv
                    · rcases List.mem_map.mp hfresh with ⟨pr, hpr, hprn⟩
                      have he : (pr.1, (pr.1, pr.2) :: active, pr.2) ∈ entries :=
                        List.mem_map.mpr ⟨pr, hpr, rfl⟩
                      exact Or.inr (by
                        simp only [WFQueueMarkings, queue', List.map_append]
                        exact List.mem_append.mpr (Or.inl
                          (List.mem_map.mpr ⟨_, he, hprn⟩)))
                  · rcases hcovered m hold t ht n hs with hv | hq
                    · exact Or.inl (List.mem_cons_of_mem current hv)
                    · simp only [WFQueueMarkings, List.map_cons] at hq
                      rcases List.mem_cons.mp hq with hhead | htail
                      · exact Or.inl (by simp [explored', hhead])
                      · exact Or.inr (by
                          simp only [WFQueueMarkings, queue', List.map_append]
                          exact List.mem_append.mpr (Or.inr htail))
                have hactive' : WFActiveProcessed queue' explored' := by
                  intro p a m hentry ap am ha
                  rcases List.mem_append.mp hentry with hnew | hold
                  · rcases List.mem_map.mp hnew with ⟨pr, hpr, heq⟩
                    cases heq
                    rcases List.mem_cons.mp ha with hfirst | htail
                    · exact Or.inl (congrArg Prod.snd hfirst)
                    · rcases hactive path active current (by simp) ap am htail with
                        hcurrent | hprev
                      · exact Or.inr (by simp [explored', hcurrent])
                      · exact Or.inr (by simp [explored', hprev])
                  · rcases hactive p a m (by simp [hold]) ap am ha with
                      hsame | hprev
                    · exact Or.inl hsame
                    · exact Or.inr (List.mem_cons_of_mem current hprev)
                have hresult' : exploreWF input fuel queue' explored' =
                    .closedNoCycle final := by
                  simpa [queue', entries, fresh, blocked, explored', neighbors] using hresult
                exact ih queue' explored' final hroot' hcovered' hactive' hresult'

private theorem nodup_subset_length {α : Type} [DecidableEq α]
    {xs ys : List α} (hnodup : xs.Nodup)
    (hsub : ∀ x, x ∈ xs → x ∈ ys) : xs.length ≤ ys.length := by
  induction xs generalizing ys with
  | nil => simp
  | cons x rest ih =>
      have hne : x ∉ rest := (List.nodup_cons.mp hnodup).1
      have hrest : rest.Nodup := (List.nodup_cons.mp hnodup).2
      have hx : x ∈ ys := hsub x (by simp)
      have hsub' : ∀ y, y ∈ rest → y ∈ ys.erase x := by
        intro y hy
        have hy' : y ∈ ys := hsub y (List.mem_cons_of_mem x hy)
        have hneq : y ≠ x := by
          intro heq
          exact hne (heq ▸ hy)
        exact (List.mem_erase_of_ne hneq).mpr hy'
      have hlen := ih hrest hsub'
      have herase := List.length_erase_of_mem hx
      have hpositive := List.length_pos_of_mem hx
      simp only [List.length_cons] at *
      omega

private theorem firstSome_none {α β : Type} {xs : List α} {f : α → Option β}
    (h : firstSome xs f = none) :
    ∀ x, x ∈ xs → f x = none := by
  induction xs with
  | nil => intro x hx; cases hx
  | cons y rest ih =>
      simp only [firstSome] at h
      cases hy : f y with
      | some value => simp [hy] at h
      | none =>
          simp only [hy] at h
          intro x hx
          rcases List.mem_cons.mp hx with heq | hrest
          · simpa [heq] using hy
          · exact ih h x hrest

private theorem findActive_none_of_mem
    (marking : Marking) (active : List (List String × Marking))
    (hfind : findActive marking active = none) :
    marking ∉ active.map Prod.snd := by
  induction active with
  | nil => simp
  | cons entry rest ih =>
      cases entry with
      | mk path m =>
          cases hb : (m == marking) with
          | true => simp [findActive, hb] at hfind
          | false =>
              have hrest : findActive marking rest = none := by
                simpa [findActive, hb] using hfind
              intro hmem
              rcases List.mem_cons.mp hmem with hhead | htail
              · have heq : m = marking := hhead.symm
                have hbeq : (m == marking) = true := beq_iff_eq.mpr heq
                rw [hb] at hbeq
                cases hbeq
              · exact ih hrest htail

private theorem cycleCandidate_none_noActive
    (active : List (List String × Marking)) (m : Marking)
    (neighbors : List (List String × Marking))
    (h : cycleCandidate active m neighbors = none)
    (entry : List String × Marking) (he : entry ∈ neighbors) :
    findActive entry.2 active = none := by
  induction neighbors with
  | nil => cases he
  | cons first rest ih =>
      simp only [cycleCandidate] at h
      cases hf : findActive first.2 active with
      | some value => simp [hf] at h
      | none =>
          simp only [hf] at h
          rcases List.mem_cons.mp he with hfirst | hrest
          · subst entry
            exact hf
          · exact ih h hrest

private def WFStep (input : SolverInput) (next current : Marking) : Prop :=
  ∃ t, t ∈ input.transitions ∧ stepAt input current t.identity = some next

private theorem findFiniteCycle_none_acc
    (input : SolverInput) (closure : List Marking)
    (hclosed : ∀ m, m ∈ closure → ∀ t, t ∈ input.transitions →
      ∀ n, stepAt input m t.identity = some n → n ∈ closure) :
    ∀ fuel path active m,
      (active.map Prod.snd).Nodup →
      (∀ x, x ∈ active.map Prod.snd → x ∈ closure) →
      active.length + fuel = closure.length + 1 →
      m ∈ closure →
      findFiniteCycle input fuel path active m = none →
      Acc (WFStep input) m := by
  intro fuel
  induction fuel with
  | zero =>
      intro path active m hnodup hsub hlength hm hnone
      have hle := nodup_subset_length hnodup hsub
      simp only [List.length_map] at hle
      simp only [Nat.add_zero] at hlength
      omega
  | succ fuel ih =>
      intro path active m hnodup hsub hlength hm hnone
      let neighbors := neighborsOf input path m
      let fresh := freshNeighbors neighbors (active.map Prod.snd)
      cases hc : cycleCandidate active m neighbors with
      | some candidate =>
          simp [findFiniteCycle, neighbors, hc] at hnone
      | none =>
          have hfirst : firstSome fresh (fun pr =>
              findFiniteCycle input fuel pr.1 ((pr.1, pr.2) :: active) pr.2) = none := by
            simpa only [findFiniteCycle, neighbors, fresh, hc] using hnone
          apply Acc.intro
          intro next hstep
          rcases hstep with ⟨t, ht, hs⟩
          have hn : next ∈ closure := hclosed m hm t ht next hs
          have hneighbor : (path ++ [t.identity], next) ∈ neighbors :=
            neighborsFrom_complete input input.transitions path m t ht hs
          have hnot : next ∉ active.map Prod.snd :=
            findActive_none_of_mem next active
              (cycleCandidate_none_noActive active m neighbors hc _ hneighbor)
          have hfresh : next ∈ fresh.map Prod.snd := by
            rcases freshNeighbors_covers (neighbors := neighbors)
                (blocked := active.map Prod.snd) hneighbor with hblocked | hnew
            · exact False.elim (hnot hblocked)
            · exact hnew
          rcases List.mem_map.mp hfresh with ⟨pr, hpr, hprnext⟩
          have hprnot : pr.2 ∉ active.map Prod.snd := by
            intro ha
            exact hnot (hprnext ▸ ha)
          have hprclosed : pr.2 ∈ closure := hprnext ▸ hn
          have hnodup' : (((pr.1, pr.2) :: active).map Prod.snd).Nodup := by
            simpa only [List.map_cons] using
              (List.nodup_cons.mpr ⟨hprnot, hnodup⟩)
          have hsub' :
              ∀ x, x ∈ ((pr.1, pr.2) :: active).map Prod.snd → x ∈ closure := by
            intro x hx
            rcases List.mem_cons.mp hx with hhead | htail
            · exact hhead ▸ hprclosed
            · exact hsub x htail
          have hlength' :
              ((pr.1, pr.2) :: active).length + fuel = closure.length + 1 := by
            simp only [List.length_cons] at *
            omega
          have hacc := ih pr.1 ((pr.1, pr.2) :: active) pr.2
            hnodup' hsub' hlength' hprclosed
            (firstSome_none hfirst pr hpr)
          exact hprnext ▸ hacc

private theorem wfAcc_no_cycle (input : SolverInput) {m : Marking}
    (hacc : Acc (WFStep input) m) :
    ∀ cycle, cycle ≠ [] → pathReplay input m cycle ≠ some m := by
  induction hacc with
  | intro m hdesc ih =>
      intro cycle hnonempty hcycle
      cases cycle with
      | nil => exact hnonempty rfl
      | cons id rest =>
          simp only [pathReplay] at hcycle
          cases hs : stepAt input m id with
          | none => simp [hs] at hcycle
          | some next =>
              have hstep : WFStep input next m := by
                rcases stepAt_implies_step input m id next hs with
                  ⟨t, ht, hid, _, _⟩
                exact ⟨t, ht, by simpa [hid] using hs⟩
              have hrest : pathReplay input next rest = some m := by
                simpa only [hs] using hcycle
              have hrotated : pathReplay input next (rest ++ [id]) =
                  some next := by
                rw [pathReplay_append, hrest]
                simp [pathReplay, hs]
              exact ih next hstep (rest ++ [id]) (by simp) hrotated

private theorem wfAcc_path (input : SolverInput)
    (hvalid : validate input = none)
    {start finish : Marking} {path : List String}
    (hacc : Acc (WFStep input) start)
    (hpath : PathExec input start path finish) :
    Acc (WFStep input) finish := by
  induction hpath with
  | nil start => exact hacc
  | @cons start middle finish id rest hstep htail ih =>
      have hs := step_implies_stepAt input start id middle hvalid hstep
      rcases hstep with ⟨t, ht, hid, _, _⟩
      have hrel : WFStep input middle start :=
        ⟨t, ht, by simpa [hid] using hs⟩
      exact ih (Acc.inv hacc hrel)

private theorem findFiniteCycle_some_sound (input : SolverInput) :
    ∀ fuel path active m pre cycle start finish source,
      pathReplay input input.marking path = some m →
      activeReplay input active →
      activePathPrefix path active →
      findFiniteCycle input fuel path active m =
        some (pre, cycle, start, finish, source) →
      pathReplay input input.marking pre = some start ∧
        pathReplay input start cycle = some finish ∧
        cycle ≠ [] ∧ start = finish := by
  intro fuel
  induction fuel with
  | zero =>
      intro path active m pre cycle start finish source hpath hactive hprefix hfind
      simp [findFiniteCycle] at hfind
  | succ fuel ih =>
      intro path active m pre cycle start finish source hpath hactive hprefix hfind
      let neighbors := neighborsOf input path m
      cases hc : cycleCandidate active m neighbors with
      | some candidate =>
          have hfound :
              some candidate = some (pre, cycle, start, finish, source) := by
            simpa only [findFiniteCycle, neighbors, hc] using hfind
          have heq := Option.some.inj hfound
          subst candidate
          exact cycleCandidate_sound input path active m
            hpath hactive hprefix hc
      | none =>
          let fresh := freshNeighbors neighbors (active.map Prod.snd)
          have hfound : firstSome fresh (fun pr =>
              findFiniteCycle input fuel pr.1 ((pr.1, pr.2) :: active) pr.2) =
              some (pre, cycle, start, finish, source) := by
            simpa only [findFiniteCycle, neighbors, fresh, hc] using hfind
          rcases firstSome_mem hfound with ⟨pr, hpr, hrec⟩
          have hneighbor : pr ∈ neighbors := freshNeighbors_mem hpr
          have hnext := neighbors_replay input input.marking path m hpath hneighbor
          have hshape := neighbors_path_shape input path m hneighbor
          have hactive' : activeReplay input ((pr.1, pr.2) :: active) := by
            intro ap am ham
            rcases List.mem_cons.mp ham with hhead | hold
            · cases hhead
              exact hnext
            · exact hactive ap am hold
          have hprefix' : activePathPrefix pr.1 ((pr.1, pr.2) :: active) := by
            intro ap am ham
            rcases List.mem_cons.mp ham with hhead | hold
            · cases hhead
              exact ⟨[], by simp⟩
            · rcases hprefix ap am hold with ⟨tail, htail⟩
              rcases hshape with ⟨id, hid⟩
              exact ⟨tail ++ [id], by simp [hid, htail, List.append_assoc]⟩
          exact ih pr.1 ((pr.1, pr.2) :: active) pr.2
            pre cycle start finish source hnext hactive' hprefix' hrec

theorem cycleWitnessSound (input : SolverInput) (w : CycleWitness)
    (h : checkWellFoundedness input = .notWellFounded w) :
    validate input = none ∧
      bindingBoundExceeded input = false ∧
      w.cyclePath ≠ [] ∧
      w.cycleStart = w.cycleEnd ∧
      pathReplay input input.marking w.prefixPath = some w.cycleStart ∧
      pathReplay input w.cycleStart w.cyclePath = some w.cycleEnd := by
  unfold checkWellFoundedness at h
  cases hv : validate input with
  | some reason => simp [hv] at h
  | none =>
    rw [hv] at h
    cases hb : bindingBoundExceeded input with
    | true => simp [hb] at h
    | false =>
      rw [hb] at h
      have hqueue : WFQueueReplay input [([], [([], input.marking)], input.marking)] := by
        intro path active marking hm
        have heq : (path, active, marking) =
            ([], [([], input.marking)], input.marking) := by simpa using hm
        cases heq
        refine ⟨rfl, ?_, ?_⟩
        · intro p m hm
          have heq' : (p, m) = ([], input.marking) := by simpa using hm
          cases heq'
          rfl
        · intro p m hm
          have heq' : (p, m) = ([], input.marking) := by simpa using hm
          cases heq'
          exact ⟨[], rfl⟩
      cases he : exploreWF input input.bound.maxSearchSteps
          [([], [([], input.marking)], input.marking)] [] with
      | cycleFound prePath cycle start finish source =>
        rw [he] at h
        simp only [cycleResult] at h
        cases h
        have hs := exploreWF_cycle_sound input input.bound.maxSearchSteps
          [([], [([], input.marking)], input.marking)] [] prePath cycle start finish source
          hqueue he
        exact ⟨rfl, rfl, hs.2.2.1, hs.2.2.2, hs.1, hs.2.1⟩
      | closedNoCycle explored =>
        rw [he] at h
        cases hc : findFiniteCycle input explored.length []
            [([], input.marking)] input.marking with
        | none => simp [hc] at h
        | some candidate =>
          rcases candidate with ⟨pre, cycle, start, finish, source⟩
          simp only [hc, cycleResult] at h
          cases h
          have hentry := hqueue [] [([], input.marking)] input.marking (by simp)
          have hs := findFiniteCycle_some_sound input explored.length []
            [([], input.marking)] input.marking pre cycle start finish source
            hentry.1 hentry.2.1 hentry.2.2 hc
          exact ⟨rfl, rfl, hs.2.2.1, hs.2.2.2, hs.1, hs.2.1⟩
      | boundHit explored => simp [he] at h

theorem cycleWitnessPathExec (input : SolverInput) (w : CycleWitness)
    (h : checkWellFoundedness input = .notWellFounded w) :
    PathExec input input.marking w.prefixPath w.cycleStart ∧
      PathExec input w.cycleStart w.cyclePath w.cycleEnd := by
  rcases cycleWitnessSound input w h with
    ⟨hvalid, _, _, _, hprefix, hcycle⟩
  exact ⟨pathReplay_implies_pathExec input hvalid hprefix,
    pathReplay_implies_pathExec input hvalid hcycle⟩

theorem acyclicWitnessSound (input : SolverInput) (w : AcyclicWitness)
    (h : checkWellFoundedness input = .wellFounded w) :
    validate input = none ∧
      bindingBoundExceeded input = false ∧
      w.frontier = [] ∧
      w.steps ≤ input.bound.maxSearchSteps ∧
      w.exploredMarkings.length = w.steps ∧
      w.exploredMarkings.Nodup ∧
      input.marking ∈ w.exploredMarkings ∧
      (∀ m, m ∈ w.exploredMarkings → ∀ id next,
        Step input m id next → next ∈ w.exploredMarkings) ∧
      (∀ prefixPath cycle start,
        PathExec input input.marking prefixPath start →
        cycle ≠ [] → ¬ PathExec input start cycle start) := by
  unfold checkWellFoundedness at h
  cases hv : validate input with
  | some reason => simp [hv] at h
  | none =>
    rw [hv] at h
    cases hb : bindingBoundExceeded input with
    | true => simp [hb] at h
    | false =>
      rw [hb] at h
      cases he : exploreWF input input.bound.maxSearchSteps
          [([], [([], input.marking)], input.marking)] [] with
      | cycleFound _prePath _cycle _start _finish _source =>
          simp [he, cycleResult] at h
      | boundHit explored => simp [he] at h
      | closedNoCycle explored =>
        rw [he] at h
        cases hc : findFiniteCycle input explored.length []
            [([], input.marking)] input.marking with
        | some candidate => simp [hc, cycleResult] at h
        | none =>
          simp only [hc] at h
          cases h
          have hnodup : explored.Nodup := by
            apply exploreWF_closed_nodup input input.bound.maxSearchSteps
              [([], [([], input.marking)], input.marking)] [] explored
            · simp
            · exact he
          have hbound := exploreWF_closed_bound input input.bound.maxSearchSteps
            [([], [([], input.marking)], input.marking)] [] explored he
          have hroot : input.marking ∈ ([] : List Marking) ∨
              input.marking ∈ WFQueueMarkings
                [([], [([], input.marking)], input.marking)] :=
            Or.inr (by simp [WFQueueMarkings])
          have hcovered : WFClosureCovered input
              [([], [([], input.marking)], input.marking)] [] := by
            intro m hm
            cases hm
          have hactive : WFActiveProcessed
              [([], [([], input.marking)], input.marking)] [] := by
            intro path active marking hentry ancestorPath ancestor ha
            have heq : (path, active, marking) =
                ([], [([], input.marking)], input.marking) := by simpa using hentry
            cases heq
            have heq' : (ancestorPath, ancestor) = ([], input.marking) := by
              simpa using ha
            cases heq'
            exact Or.inl rfl
          have hcomplete := exploreWF_closed_complete input input.bound.maxSearchSteps
            [([], [([], input.marking)], input.marking)] [] explored
            hroot hcovered hactive he
          have hacc : Acc (WFStep input) input.marking :=
            findFiniteCycle_none_acc input explored hcomplete.2 explored.length
              [] [([], input.marking)] input.marking
              (by simp)
              (by
                intro x hx
                have heq : x = input.marking := by simpa using hx
                exact heq ▸ hcomplete.1)
              (by simp only [List.length_cons, List.length_nil]; omega)
              hcomplete.1 hc
          have hclosure :
              ∀ m, m ∈ explored → ∀ id next,
                Step input m id next → next ∈ explored := by
            intro m hm id next hstep
            have hs := step_implies_stepAt input m id next hv hstep
            rcases hstep with ⟨t, ht, hid, _, _⟩
            exact hcomplete.2 m hm t ht next (by simpa [hid] using hs)
          have hnocycle :
              ∀ prefixPath cycle start,
                PathExec input input.marking prefixPath start →
                cycle ≠ [] → ¬ PathExec input start cycle start := by
            intro prefixPath cycle start hprefix hnonempty hcycle
            have hstart := wfAcc_path input hv hacc hprefix
            exact wfAcc_no_cycle input hstart cycle hnonempty
              (pathExec_implies_pathReplay input hv hcycle)
          exact ⟨rfl, rfl, rfl, by simpa using hbound, rfl, hnodup,
            hcomplete.1, hclosure, hnocycle⟩

end NecoherenceTools
