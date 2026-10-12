-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
Typed mapping: finite typed places, transitions, colored tokens, input
bindings, input validation, one-step transitions and path replay.

All results are closed data; witnesses expose the finite path or closure
that produced the result.
-/

namespace Necoherence

inductive TokenKind where
  | input
  | output
  | failure
  | effect
  | observation
  | accepted
  deriving DecidableEq, Repr

structure ColoredToken where
  target : String
  index : Nat
  revision : Nat
  kind : TokenKind
  deriving DecidableEq, Repr

structure TypedPlace where
  identity : String
  tokenType : String
  revision : Nat
  deriving DecidableEq, Repr

structure TypedTransition where
  identity : String
  inputPlaces : List String
  outputPlaces : List String
  failurePlaces : List String
  revision : Nat
  deriving DecidableEq, Repr

inductive BindingMode where
  | read
  | consume
  deriving DecidableEq, Repr

structure InputBinding where
  transitionId : String
  name : String
  place : String
  tokenType : String
  identity : String
  provenance : String
  multiplicity : Nat
  mode : BindingMode
  requiredRevision : Nat
  deriving DecidableEq, Repr

structure DeclarationGraph where
  places : List String
  transitions : List String
  edges : List (String × String)
  revision : Nat
  deriving DecidableEq, Repr

structure DomainBound where
  targetIdentity : String
  index : Nat
  revision : Nat
  maxBindings : Nat
  maxSearchSteps : Nat
  deriving DecidableEq, Repr

structure Marking where
  places : List (String × List ColoredToken)
  deriving DecidableEq, Repr

def tokensAt (m : Marking) (place : String) : List ColoredToken :=
  match m.places.find? (fun p => p.1 == place) with
  | some (_, ts) => ts
  | none => []

inductive GoalPredicate where
  | placeHasAtLeast (place : String) (count : Nat)
  | placeHasToken (place : String) (target : String) (index : Nat) (revision : Nat)
  | glAnd (a b : GoalPredicate)
  | glOr (a b : GoalPredicate)
  | glNot (a : GoalPredicate)
  deriving DecidableEq, Repr

def evalGoal (m : Marking) : GoalPredicate → Bool
  | .placeHasAtLeast place count => count <= (tokensAt m place).length
  | .placeHasToken place target index revision =>
      (tokensAt m place).any (fun t => t.target == target && t.index == index && t.revision == revision)
  | .glAnd a b => evalGoal m a && evalGoal m b
  | .glOr a b => evalGoal m a || evalGoal m b
  | .glNot a => !evalGoal m a

structure SolverInput where
  places : List TypedPlace
  transitions : List TypedTransition
  bindings : List InputBinding
  goal : GoalPredicate
  graph : DeclarationGraph
  marking : Marking
  bound : DomainBound
  deriving DecidableEq, Repr

inductive InvalidReason where
  | unknownPlace (place : String)
  | unknownTransition (transitionId : String)
  | unknownInputPlace (transitionId place : String)
  | missingInputBinding (transitionId place : String)
  | duplicateTransitionIdentity (identity : String)
  | typeMismatch (place expected actual : String)
  | multiplicityMismatch (transitionId name : String) (expected actual : Nat)
  | revisionMismatch (transitionId name : String) (expected actual : Nat)
  | identityMismatch (transitionId name : String)
  | dependencyMismatch (transitionId place : String)
  deriving DecidableEq, Repr

inductive UnknownReason where
  | bindingBoundExhausted (limit : Nat)
  | searchStepBoundExhausted (limit : Nat)
  deriving DecidableEq, Repr

structure EnabledTransition where
  transitionId : String
  bindings : List InputBinding
  deriving DecidableEq, Repr

structure EnabledSet where
  enabled : List EnabledTransition
  deriving DecidableEq, Repr

inductive EnabledResult where
  | enabledSet (s : EnabledSet)
  | invalid (reason : InvalidReason)
  deriving DecidableEq, Repr

structure ReachabilityWitness where
  path : List String
  finalMarking : Marking
  deriving DecidableEq, Repr

structure ClosureWitness where
  exploredMarkings : List Marking
  steps : Nat
  frontier : List Marking
  deriving DecidableEq, Repr

inductive ReachabilityResult where
  | invalid (reason : InvalidReason)
  | reachable (witness : ReachabilityWitness)
  | unknown (reason : UnknownReason)
  | unreachable (closureWitness : ClosureWitness)
  deriving DecidableEq, Repr

structure DeadlockWitness where
  marking : Marking
  deriving DecidableEq, Repr

inductive DeadlockResult where
  | deadlocked (witness : DeadlockWitness)
  | invalid (reason : InvalidReason)
  | notDeadlocked (enabledSet : EnabledSet)
  | unknown (reason : UnknownReason)
  deriving DecidableEq, Repr

structure CycleWitness where
  prefixPath : List String
  cyclePath : List String
  cycleStart : Marking
  cycleEnd : Marking
  measureDecreasing : Bool
  deriving DecidableEq, Repr

structure AcyclicWitness where
  exploredMarkings : List Marking
  steps : Nat
  frontier : List Marking
  deriving DecidableEq, Repr

inductive WellFoundednessResult where
  | invalid (reason : InvalidReason)
  | notWellFounded (witness : CycleWitness)
  | unknown (reason : UnknownReason)
  | wellFounded (witness : AcyclicWitness)
  deriving DecidableEq, Repr

inductive SolverFailure where
  | contractViolation (message : String)
  | internalInvariantViolation (message : String)
  deriving DecidableEq, Repr

private def placeExists (places : List TypedPlace) (id : String) : Bool :=
  places.any (fun p => p.identity == id)

private def placeType (places : List TypedPlace) (id : String) : Option String :=
  (places.find? (fun p => p.identity == id)).map (fun p => p.tokenType)

private def transitionExists (transitions : List TypedTransition) (id : String) : Bool :=
  transitions.any (fun t => t.identity == id)

private def findTransition (transitions : List TypedTransition) (id : String) : Option TypedTransition :=
  transitions.find? (fun t => t.identity == id)

private def duplicateBindingName (input : SolverInput) (b : InputBinding) : Bool :=
  1 < (input.bindings.filter (fun b2 => b2.transitionId == b.transitionId && b2.name == b.name)).length

def firstSome (xs : List α) (f : α → Option β) : Option β :=
  match xs with
  | [] => none
  | x :: rest =>
    match f x with
    | some y => some y
    | none => firstSome rest f

private def checkInputPlaceMembership (input : SolverInput) : Option InvalidReason :=
  firstSome input.transitions (fun t =>
    firstSome t.inputPlaces (fun p =>
      if placeExists input.places p then none
      else some (.unknownInputPlace t.identity p)))

private def duplicateTransitionIdentity (transitions : List TypedTransition) : Option String :=
  match transitions with
  | [] => none
  | t :: rest =>
    if rest.any (fun other => other.identity == t.identity) then
      some t.identity
    else
      duplicateTransitionIdentity rest

private def checkDuplicateTransitionIdentity (input : SolverInput) : Option InvalidReason :=
  (duplicateTransitionIdentity input.transitions).map InvalidReason.duplicateTransitionIdentity

private def checkBindingCoverage (input : SolverInput) : Option InvalidReason :=
  firstSome input.transitions (fun t =>
    if t.inputPlaces.isEmpty then
      none
    else
      firstSome t.inputPlaces (fun p =>
        if input.bindings.any (fun b => b.transitionId == t.identity && b.place == p) then
          none
        else
          some (.missingInputBinding t.identity p)))

private def checkBindingStructure (input : SolverInput) (b : InputBinding) : Option InvalidReason :=
  if !transitionExists input.transitions b.transitionId then
    some (.unknownTransition b.transitionId)
  else if !placeExists input.places b.place then
    some (.unknownPlace b.place)
  else
    match findTransition input.transitions b.transitionId with
    | none => some (.unknownTransition b.transitionId)
    | some t =>
      if !t.inputPlaces.contains b.place then
        some (.dependencyMismatch b.transitionId b.place)
      else
        match placeType input.places b.place with
        | none => some (.unknownPlace b.place)
        | some ty =>
          if ty != b.tokenType then
            some (.typeMismatch b.place b.tokenType ty)
          else if b.multiplicity == 0 then
            some (.multiplicityMismatch b.transitionId b.name 1 0)
          else if duplicateBindingName input b then
            some (.identityMismatch b.transitionId b.name)
          else
            none

private def checkBindingRevision (input : SolverInput) (b : InputBinding) : Option InvalidReason :=
  match (tokensAt input.marking b.place).find? (fun t => t.target == b.identity && t.revision != b.requiredRevision) with
  | some t => some (.revisionMismatch b.transitionId b.name b.requiredRevision t.revision)
  | none => none

private def checkGraphPlaces (input : SolverInput) : Option InvalidReason :=
  match input.graph.places.find? (fun p => !placeExists input.places p) with
  | some p => some (.unknownPlace p)
  | none => none

private def checkGraphTransitions (input : SolverInput) : Option InvalidReason :=
  match input.graph.transitions.find? (fun t => !transitionExists input.transitions t) with
  | some t => some (.unknownTransition t)
  | none => none

private def isGraphNode (input : SolverInput) (id : String) : Bool :=
  input.graph.places.contains id || input.graph.transitions.contains id

private def checkGraphEdges (input : SolverInput) : Option InvalidReason :=
  match input.graph.edges.find? (fun e => !isGraphNode input e.1 || !isGraphNode input e.2) with
  | some e => some (.dependencyMismatch e.1 e.2)
  | none => none

private def checkBranchPlaces (input : SolverInput) : Option InvalidReason :=
  firstSome input.transitions (fun t =>
    firstSome (t.outputPlaces ++ t.failurePlaces) (fun p =>
      if placeExists input.places p then none else some (.dependencyMismatch t.identity p)))

def validate (input : SolverInput) : Option InvalidReason :=
  match checkInputPlaceMembership input with
  | some reason => some reason
  | none =>
    match checkDuplicateTransitionIdentity input with
    | some reason => some reason
    | none =>
      match checkBindingCoverage input with
      | some reason => some reason
      | none =>
        match firstSome input.bindings (checkBindingStructure input) with
        | some reason => some reason
        | none =>
          match firstSome input.bindings (checkBindingRevision input) with
          | some reason => some reason
          | none =>
            match checkGraphPlaces input with
            | some reason => some reason
            | none =>
              match checkGraphTransitions input with
              | some reason => some reason
              | none =>
                match checkGraphEdges input with
                | some reason => some reason
                | none => checkBranchPlaces input

def bindingsFor (input : SolverInput) (transitionId : String) : List InputBinding :=
  input.bindings.filter (fun b => b.transitionId == transitionId)

def bindingSatisfiedAt (m : Marking) (b : InputBinding) : Bool :=
  b.multiplicity <= ((tokensAt m b.place).filter (fun t => t.target == b.identity && t.revision == b.requiredRevision)).length

def transitionEnabledAt (bindings : List InputBinding) (m : Marking) : Bool :=
  bindings.all (bindingSatisfiedAt m)

def candidateBindingCount (input : SolverInput) : Nat :=
  input.transitions.foldl (fun acc t => acc + (bindingsFor input t.identity).length) 0

def bindingBoundExceeded (input : SolverInput) : Bool :=
  input.bound.maxBindings < candidateBindingCount input

def deriveEnabled (input : SolverInput) : EnabledResult :=
  match validate input with
  | some reason => .invalid reason
  | none =>
    let enabled :=
      input.transitions.filterMap (fun t =>
        let bs := bindingsFor input t.identity
        if transitionEnabledAt bs input.marking then
          some ({ transitionId := t.identity, bindings := bs } : EnabledTransition)
        else none)
    .enabledSet { enabled := enabled }

private def selectMatching (tokens : List ColoredToken) (b : InputBinding) : List ColoredToken :=
  (tokens.filter (fun t => t.target == b.identity && t.revision == b.requiredRevision)).take b.multiplicity

def consumedAt (bindings : List InputBinding) (m : Marking) (place : String) : List ColoredToken :=
  (bindings.filter (fun b => b.place == place && b.mode == .consume)).foldl
    (fun acc b => acc ++ selectMatching (tokensAt m place) b) []

private def eraseFirst : List ColoredToken → ColoredToken → List ColoredToken
  | [], _ => []
  | x :: rest, t => if x = t then rest else x :: eraseFirst rest t

def subtractTokens (tokens toRemove : List ColoredToken) : List ColoredToken :=
  toRemove.foldl eraseFirst tokens

def applyConsumption (m : Marking) (bindings : List InputBinding) : Marking :=
  { places := m.places.map (fun pr => (pr.1, subtractTokens pr.2 (consumedAt bindings m pr.1))) }

private def addToken (m : Marking) (place : String) (tok : ColoredToken) : Marking :=
  if (m.places.find? (fun p => p.1 == place)).isSome then
    { places := m.places.map (fun p => if p.1 == place then (p.1, tok :: p.2) else p) }
  else
    { places := m.places ++ [(place, [tok])] }

private def addTokens (m : Marking) (places : List String) (tok : ColoredToken) : Marking :=
  places.foldl (fun acc place => addToken acc place tok) m

def producedToken (t : TypedTransition) : ColoredToken :=
  { target := t.identity, index := 0, revision := t.revision, kind := .output }

def applyBranchAt (m : Marking) (t : TypedTransition) (bindings : List InputBinding) : Marking :=
  addTokens (applyConsumption m bindings) t.outputPlaces (producedToken t)

def checkTokenColorPreserved (before after : List ColoredToken) : Bool :=
  after.all (fun t => before.contains t)

def checkReadConsumeAtomicity (before consumed retained : List ColoredToken) : Bool :=
  (before ++ consumed ++ retained).all (fun t =>
    decide (retained.countP (fun u => decide (u = t)) =
      before.countP (fun u => decide (u = t)) - consumed.countP (fun u => decide (u = t))))

def checkDeadlockGoalSeparation (goalHolds deadlocked : Bool) : Bool :=
  !(goalHolds && deadlocked)

def checkClosureRequiredForUnreachable (closureComplete reportedUnreachable : Bool) : Bool :=
  !reportedUnreachable || closureComplete

private theorem subtractTokens_nil (cs : List ColoredToken) : subtractTokens [] cs = [] := by
  induction cs with
  | nil => rfl
  | cons c cs' ih =>
    unfold subtractTokens at ih ⊢
    rw [List.foldl_cons]
    exact ih

theorem tokensAt_applyConsumption (m : Marking) (bindings : List InputBinding) (place : String) :
    tokensAt (applyConsumption m bindings) place =
      subtractTokens (tokensAt m place) (consumedAt bindings m place) := by
  unfold tokensAt applyConsumption
  induction m.places with
  | nil => simp [subtractTokens_nil]
  | cons hd tl ih =>
    cases hbeq : hd.1 == place with
    | true =>
      have heq : hd.1 = place := eq_of_beq hbeq
      simp only [List.map_cons, List.find?, heq, BEq.rfl]
    | false =>
      simp only [List.map_cons, List.find?, hbeq]
      exact ih

private theorem mem_eraseFirst {x u : ColoredToken} {ts : List ColoredToken} :
    x ∈ eraseFirst ts u → x ∈ ts := by
  induction ts with
  | nil => intro h; exact h
  | cons y ys ih =>
    intro h
    simp only [eraseFirst] at h
    split at h
    · exact List.mem_cons_of_mem y h
    · cases List.mem_cons.mp h with
      | inl hxy => exact List.mem_cons.mpr (Or.inl hxy)
      | inr h' => exact List.mem_cons_of_mem y (ih h')

private theorem mem_subtractTokens {x : ColoredToken} {ts cs : List ColoredToken} :
    x ∈ subtractTokens ts cs → x ∈ ts := by
  induction cs generalizing ts with
  | nil => intro h; exact h
  | cons c cs' ih =>
    intro h
    exact mem_eraseFirst (ih h)

theorem tokenColorPreserved (m : Marking) (bindings : List InputBinding) (place : String) :
    checkTokenColorPreserved (tokensAt m place) (tokensAt (applyConsumption m bindings) place) = true := by
  rw [tokensAt_applyConsumption]
  unfold checkTokenColorPreserved
  simp only [List.all_eq_true, List.contains_eq_mem, decide_eq_true_eq]
  exact fun x hx => mem_subtractTokens hx

private theorem countP_eraseFirst (t u : ColoredToken) (ts : List ColoredToken) :
    (eraseFirst ts u).countP (fun x => decide (x = t)) =
      ts.countP (fun x => decide (x = t)) - (if u = t then 1 else 0) := by
  induction ts with
  | nil => by_cases h : u = t <;> simp [eraseFirst, h]
  | cons y ys ih =>
    simp only [eraseFirst]
    split
    · next hy =>
      subst hy
      simp only [List.countP_cons]
      by_cases hut : y = t <;> simp [hut]
    · next hy =>
      simp only [List.countP_cons]
      rw [ih]
      by_cases hyt : y = t
      · have hut : ¬(u = t) := fun h => hy (hyt.trans h.symm)
        simp [hyt, hut]
      · by_cases hut : u = t <;> simp [hyt, hut]

private theorem countP_subtractTokens (t : ColoredToken) (ts cs : List ColoredToken) :
    (subtractTokens ts cs).countP (fun x => decide (x = t)) =
      ts.countP (fun x => decide (x = t)) - cs.countP (fun x => decide (x = t)) := by
  induction cs generalizing ts with
  | nil => simp [subtractTokens]
  | cons c cs' ih =>
    show (subtractTokens (eraseFirst ts c) cs').countP (fun x => decide (x = t)) = _
    rw [ih, countP_eraseFirst, List.countP_cons]
    by_cases h : c = t <;> simp [h] <;> omega

theorem readConsumeAtomicity (m : Marking) (bindings : List InputBinding) (place : String) :
    checkReadConsumeAtomicity (tokensAt m place) (consumedAt bindings m place)
      (tokensAt (applyConsumption m bindings) place) = true := by
  unfold checkReadConsumeAtomicity
  rw [tokensAt_applyConsumption]
  simp only [List.all_eq_true, decide_eq_true_eq]
  exact fun t _ => countP_subtractTokens t _ _

theorem producedTokenColor (t : TypedTransition) :
    producedToken t = { target := t.identity, index := 0, revision := t.revision, kind := .output } := rfl

/-! Path replay -/

def stepAt (input : SolverInput) (m : Marking) (transitionId : String) : Option Marking :=
  match findTransition input.transitions transitionId with
  | none => none
  | some t =>
    let bs := bindingsFor input transitionId
    if transitionEnabledAt bs m then
      some (applyBranchAt m t bs)
    else
      none

def pathReplay (input : SolverInput) (start : Marking) : List String → Option Marking
  | [] => some start
  | transitionId :: rest =>
    match stepAt input start transitionId with
    | none => none
    | some next => pathReplay input next rest

def Step (input : SolverInput) (m : Marking)
    (identity : String) (next : Marking) : Prop :=
  ∃ t, t ∈ input.transitions ∧ t.identity = identity ∧
    transitionEnabledAt (bindingsFor input identity) m = true ∧
    applyBranchAt m t (bindingsFor input identity) = next

inductive PathExec (input : SolverInput) : Marking → List String → Marking → Prop where
  | nil (start : Marking) : PathExec input start [] start
  | cons {start middle finish : Marking} {id : String} {rest : List String}
      (head : Step input start id middle)
      (tail : PathExec input middle rest finish) :
      PathExec input start (id :: rest) finish

private theorem transition_identity_nodup_of_duplicate_none :
    ∀ transitions : List TypedTransition,
      duplicateTransitionIdentity transitions = none →
      (transitions.map (fun t => t.identity)).Nodup := by
  intro transitions
  induction transitions with
  | nil =>
      intro h
      simp
  | cons head rest ih =>
      intro hnone
      cases hdup : rest.any (fun t => t.identity == head.identity) with
      | true =>
          simp [duplicateTransitionIdentity, hdup] at hnone
      | false =>
          have hrest : duplicateTransitionIdentity rest = none := by
            simp [duplicateTransitionIdentity, hdup] at hnone ⊢
            exact hnone
          have hnodup := ih hrest
          have hnot : head.identity ∉ rest.map (fun t => t.identity) := by
            intro hm
            rcases List.mem_map.mp hm with ⟨t, ht, htid⟩
            have hany : rest.any (fun u => u.identity == head.identity) = true :=
              List.any_eq_true.mpr ⟨t, ht, by simpa [htid]⟩
            rw [hdup] at hany
            cases hany
          exact List.nodup_cons.mpr ⟨hnot, hnodup⟩

private theorem transition_identities_nodup (input : SolverInput)
    (hvalid : validate input = none) :
    (input.transitions.map (fun t => t.identity)).Nodup := by
  apply transition_identity_nodup_of_duplicate_none
  unfold validate at hvalid
  cases hi : checkInputPlaceMembership input with
  | some r => rw [hi] at hvalid; cases hvalid
  | none =>
      rw [hi] at hvalid
      cases hd : checkDuplicateTransitionIdentity input with
      | some r => rw [hd] at hvalid; cases hvalid
      | none =>
          unfold checkDuplicateTransitionIdentity at hd
          cases hdup : duplicateTransitionIdentity input.transitions with
          | none => simpa only [hdup]
          | some identity => simp [hdup] at hd
private theorem transition_identity_unique_of_nodup
    {transitions : List TypedTransition}
    (hnodup : (transitions.map (fun t => t.identity)).Nodup)
    {t₁ t₂ : TypedTransition}
    (h₁ : t₁ ∈ transitions) (h₂ : t₂ ∈ transitions)
    (hid : t₁.identity = t₂.identity) : t₁ = t₂ := by
  induction transitions with
  | nil => cases h₁
  | cons head rest ih =>
      have hnodupRest : (rest.map (fun t => t.identity)).Nodup :=
        (List.nodup_cons.mp hnodup).2
      have hnotHead : head.identity ∉ rest.map (fun t => t.identity) :=
        (List.nodup_cons.mp hnodup).1
      cases List.mem_cons.mp h₁ with
      | inl h₁head =>
          cases List.mem_cons.mp h₂ with
          | inl h₂head =>
              cases h₁head
              cases h₂head
              rfl
          | inr h₂rest =>
              have hmem : head.identity ∈ rest.map (fun t => t.identity) := by
                have htid : t₂.identity = head.identity := by
                  calc
                    t₂.identity = t₁.identity := hid.symm
                    _ = head.identity := by simpa [h₁head]
                exact List.mem_map.mpr ⟨t₂, h₂rest, htid⟩
              exact False.elim (hnotHead hmem)
      | inr h₁rest =>
          cases List.mem_cons.mp h₂ with
          | inl h₂head =>
              have hmem : head.identity ∈ rest.map (fun t => t.identity) := by
                have htid : t₁.identity = head.identity := by
                  calc
                    t₁.identity = t₂.identity := hid
                    _ = head.identity := by simpa [h₂head]
                exact List.mem_map.mpr ⟨t₁, h₁rest, htid⟩
              exact False.elim (hnotHead hmem)
          | inr h₂rest =>
              exact ih hnodupRest h₁rest h₂rest

private theorem transition_identity_unique
    (input : SolverInput) (hvalid : validate input = none)
    {t₁ t₂ : TypedTransition}
    (h₁ : t₁ ∈ input.transitions) (h₂ : t₂ ∈ input.transitions)
    (hid : t₁.identity = t₂.identity) : t₁ = t₂ :=
  transition_identity_unique_of_nodup
    (transition_identities_nodup input hvalid) h₁ h₂ hid

private theorem findTransition_of_mem_valid
    (input : SolverInput) (id : String)
    (hvalid : validate input = none) {t : TypedTransition}
    (ht : t ∈ input.transitions) (hid : t.identity = id) :
    findTransition input.transitions id = some t := by
  unfold findTransition
  have hsome : (input.transitions.find? (fun u => u.identity == id)).isSome :=
    List.find?_isSome.mpr ⟨t, ht, by simp [hid]⟩
  cases hfind : input.transitions.find? (fun u => u.identity == id) with
  | none => simp [hfind] at hsome
  | some u =>
      have hu : u ∈ input.transitions := List.mem_of_find?_eq_some hfind
      have hp : (u.identity == id) = true :=
        List.find?_some (p := fun v : TypedTransition => v.identity == id) hfind
      have huid : u.identity = id := beq_iff_eq.mp hp
      have htu : u = t :=
        transition_identity_unique input hvalid hu ht (huid.trans hid.symm)
      exact congrArg some htu

theorem step_implies_stepAt
    (input : SolverInput) (m : Marking) (id : String) (next : Marking)
    (hvalid : validate input = none) (hstep : Step input m id next) :
    stepAt input m id = some next := by
  rcases hstep with ⟨t, ht, hid, hen, happ⟩
  unfold stepAt
  rw [findTransition_of_mem_valid input id hvalid ht hid]
  simp only [hen, if_true, happ]

theorem stepAt_implies_step
    (input : SolverInput) (m : Marking) (id : String) (next : Marking)
    (h : stepAt input m id = some next) : Step input m id next := by
  unfold stepAt at h
  cases hfind : findTransition input.transitions id with
  | none => simp [hfind] at h
  | some t =>
      cases hen : transitionEnabledAt (bindingsFor input id) m with
      | false => simp [hfind, hen] at h
      | true =>
          have hnext : applyBranchAt m t (bindingsFor input id) = next :=
            Option.some.inj (by simpa [hfind, hen] using h)
          have hmem : t ∈ input.transitions := by
            unfold findTransition at hfind
            exact List.mem_of_find?_eq_some hfind
          have hid : t.identity = id := by
            unfold findTransition at hfind
            exact beq_iff_eq.mp
              (List.find?_some (p := fun u : TypedTransition => u.identity == id) hfind)
          exact ⟨t, hmem, hid, hen, hnext⟩

theorem pathExec_implies_pathReplay
    (input : SolverInput) (hvalid : validate input = none)
    {start finish : Marking} {path : List String}
    (h : PathExec input start path finish) :
    pathReplay input start path = some finish := by
  induction h with
  | nil start => rfl
  | @cons start middle finish id rest hstep _tail ih =>
      simp only [pathReplay, step_implies_stepAt input start id middle hvalid hstep]
      exact ih

theorem pathReplay_implies_pathExec
    (input : SolverInput) (_hvalid : validate input = none)
    {start finish : Marking} {path : List String}
    (h : pathReplay input start path = some finish) :
    PathExec input start path finish := by
  induction path generalizing start with
  | nil =>
      have heq : start = finish := Option.some.inj (by simpa [pathReplay] using h)
      subst finish
      exact .nil start
  | cons id rest ih =>
      simp only [pathReplay] at h
      cases hs : stepAt input start id with
      | none => simp [hs] at h
      | some next =>
          simp only [hs] at h
          exact .cons (stepAt_implies_step input start id next hs) (ih h)

theorem step_deterministic (input : SolverInput) (m : Marking)
    (identity : String) {first second : Marking}
    (hvalid : validate input = none)
    (hfirst : Step input m identity first)
    (hsecond : Step input m identity second) : first = second := by
  rcases hfirst with ⟨t₁, ht₁, hid₁, hen₁, happ₁⟩
  rcases hsecond with ⟨t₂, ht₂, hid₂, hen₂, happ₂⟩
  have hteq := transition_identity_unique input hvalid ht₁ ht₂
    (hid₁.trans hid₂.symm)
  subst t₂
  rw [happ₁] at happ₂
  exact happ₂

def pathEnabled (input : SolverInput) (start : Marking) : List String → Bool
  | [] => true
  | transitionId :: rest =>
    match stepAt input start transitionId with
    | none => false
    | some next => pathEnabled input next rest

theorem pathReplay_append (input : SolverInput) (start : Marking)
    (prePath suffix : List String) :
    pathReplay input start (prePath ++ suffix) =
      match pathReplay input start prePath with
      | none => none
      | some middle => pathReplay input middle suffix := by
  induction prePath generalizing start with
  | nil => simp [pathReplay]
  | cons id rest ih =>
    simp only [List.cons_append, pathReplay]
    cases hs : stepAt input start id with
    | none => simp [hs]
    | some next =>
      simp [hs, ih]

theorem pathReplayEnabled (input : SolverInput) (start : Marking) (path : List String)
    {finish : Marking} (h : pathReplay input start path = some finish) :
    pathEnabled input start path = true := by
  induction path generalizing start finish with
  | nil => simp [pathReplay, pathEnabled] at h ⊢
  | cons id rest ih =>
    simp only [pathReplay] at h
    cases hs : stepAt input start id with
    | none => simp [hs] at h
    | some next =>
      simp only [hs] at h
      simp [pathEnabled, hs, ih (start := next) h]

theorem pathReplayUnique (input : SolverInput) (start : Marking) (path : List String)
    {first second : Marking}
    (hvalid : validate input = none)
    (hfirst : PathExec input start path first)
    (hsecond : PathExec input start path second) :
    first = second ∧
      pathReplay input start path = some first ∧
      pathReplay input start path = some second := by
  have hterminal : first = second := by
    induction hfirst generalizing second with
    | nil start =>
        cases hsecond
        rfl
    | @cons start middle finish id rest hstep _tail ih =>
        cases hsecond with
        | cons hstep' htail' =>
            have hmiddle := step_deterministic input start id hvalid hstep hstep'
            cases hmiddle
            exact ih htail'
  exact ⟨hterminal,
    pathExec_implies_pathReplay input hvalid hfirst,
    pathExec_implies_pathReplay input hvalid hsecond⟩

theorem firstSome_mem {xs : List α} {f : α → Option β} {y : β}
    (h : firstSome xs f = some y) :
    ∃ x, x ∈ xs ∧ f x = some y := by
  induction xs with
  | nil => simp [firstSome] at h
  | cons x rest ih =>
    simp only [firstSome] at h
    cases hf : f x with
    | some value =>
        simp only [hf] at h
        injection h with hy
        exact ⟨x, by simp, by simpa [hy] using hf⟩
    | none =>
        simp only [hf] at h
        rcases ih h with ⟨z, hz, hzf⟩
        exact ⟨z, by simp [hz], hzf⟩

def invalidReasonSound (input : SolverInput) (reason : InvalidReason) : Prop :=
  match reason with
  | .unknownInputPlace transitionId place =>
      ∃ t, t ∈ input.transitions ∧ t.identity = transitionId ∧
        place ∈ t.inputPlaces ∧ placeExists input.places place = false
  | .missingInputBinding transitionId place =>
      ∃ t, t ∈ input.transitions ∧ t.identity = transitionId ∧
        place ∈ t.inputPlaces ∧
        input.bindings.any (fun b => b.transitionId == transitionId && b.place == place) = false
  | .duplicateTransitionIdentity identity =>
      ∃ prePaths t rest, input.transitions = prePaths ++ t :: rest ∧
        t.identity = identity ∧
        rest.any (fun other => other.identity == identity)
  | _ => True

private theorem inputPlaceCheck_sound (input : SolverInput)
    {transitionId place : String}
    (h : checkInputPlaceMembership input =
      some (.unknownInputPlace transitionId place)) :
    ∃ t, t ∈ input.transitions ∧ t.identity = transitionId ∧
      place ∈ t.inputPlaces ∧ placeExists input.places place = false := by
  rcases firstSome_mem h with ⟨t, ht, hplaces⟩
  rcases firstSome_mem hplaces with ⟨p, hp, hplace⟩
  cases he : placeExists input.places p with
  | true => simp [he] at hplace
  | false =>
      simp only [he] at hplace
      cases hplace
      exact ⟨t, ht, rfl, hp, he⟩

private theorem bindingCoverageCheck_sound (input : SolverInput)
    {transitionId place : String}
    (h : checkBindingCoverage input =
      some (.missingInputBinding transitionId place)) :
    ∃ t, t ∈ input.transitions ∧ t.identity = transitionId ∧
      place ∈ t.inputPlaces ∧
      input.bindings.any (fun b => b.transitionId == transitionId && b.place == place) = false := by
  rcases firstSome_mem h with ⟨t, ht, hplaces⟩
  cases hempty : t.inputPlaces.isEmpty with
  | true => simp [hempty] at hplaces
  | false =>
    have hplaces' : firstSome t.inputPlaces (fun p =>
        if input.bindings.any (fun b => b.transitionId == t.identity && b.place == p)
        then none else some (InvalidReason.missingInputBinding t.identity p)) =
        some (InvalidReason.missingInputBinding transitionId place) := by
      simpa [hempty] using hplaces
    rcases firstSome_mem hplaces' with ⟨p, hp, hplace⟩
    cases hb : (input.bindings.any (fun b =>
        b.transitionId == t.identity && b.place == p)) with
    | true => simp [hb] at hplace
    | false =>
      simp only [hb] at hplace
      cases hplace
      exact ⟨t, ht, rfl, hp, hb⟩

private theorem duplicateTransitionIdentity_sound (transitions : List TypedTransition)
    {identity : String} (h : duplicateTransitionIdentity transitions = some identity) :
    ∃ prePaths t rest, transitions = prePaths ++ t :: rest ∧ t.identity = identity ∧
      rest.any (fun other => other.identity == identity) := by
  induction transitions with
  | nil => simp [duplicateTransitionIdentity] at h
  | cons t rest ih =>
    simp only [duplicateTransitionIdentity] at h
    cases hd : rest.any (fun other => other.identity == t.identity) with
    | true =>
        simp only [hd] at h
        injection h with hident
        have hd' : rest.any (fun other => other.identity == identity) = true := by
          simpa [hident] using hd
        exact ⟨[], t, rest, by simp, hident, hd'⟩
    | false =>
        simp only [hd] at h
        rcases ih h with ⟨prePaths, t', rest', hts, hident, hany⟩
        exact ⟨t :: prePaths, t', rest',
          by simp [hts, List.cons_append], hident, hany⟩
private theorem duplicateCheck_cases (input : SolverInput) :
    checkDuplicateTransitionIdentity input = none ∨
      ∃ identity, checkDuplicateTransitionIdentity input =
        some (.duplicateTransitionIdentity identity) := by
  unfold checkDuplicateTransitionIdentity
  cases hdup : duplicateTransitionIdentity input.transitions with
  | none => exact Or.inl (by simp [hdup])
  | some identity => exact Or.inr ⟨identity, by simp [hdup]⟩


private def isNewReason : InvalidReason → Bool
  | .unknownInputPlace _ _ => true
  | .missingInputBinding _ _ => true
  | .duplicateTransitionIdentity _ => true
  | _ => false

private theorem firstSome_notNew {xs : List α} {f : α → Option InvalidReason}
    (hf : ∀ x ∈ xs, ∀ r, f x = some r → isNewReason r = false)
    {r : InvalidReason} (h : firstSome xs f = some r) :
    isNewReason r = false := by
  induction xs with
  | nil => simp [firstSome] at h
  | cons x rest ih =>
      simp only [firstSome] at h
      cases hx : f x with
      | some q =>
          simp only [hx] at h
          injection h with hr
          subst r
          exact hf x (by simp) q hx
      | none =>
          simp only [hx] at h
          exact ih (fun y hy s hs => hf y (by simp [hy]) s hs) h

private theorem bindingStructure_notNew (input : SolverInput) (b : InputBinding)
    {r : InvalidReason} (h : checkBindingStructure input b = some r) :
    isNewReason r = false := by
  unfold checkBindingStructure at h
  repeat' first | split at h
  all_goals cases r <;> simp_all [isNewReason]

private theorem bindingRevision_notNew (input : SolverInput) (b : InputBinding)
    {r : InvalidReason} (h : checkBindingRevision input b = some r) :
    isNewReason r = false := by
  unfold checkBindingRevision at h
  split at h <;> cases r <;> simp_all [isNewReason]

private theorem graphPlaces_notNew (input : SolverInput)
    {r : InvalidReason} (h : checkGraphPlaces input = some r) :
    isNewReason r = false := by
  unfold checkGraphPlaces at h
  split at h <;> cases r <;> simp_all [isNewReason]

private theorem graphTransitions_notNew (input : SolverInput)
    {r : InvalidReason} (h : checkGraphTransitions input = some r) :
    isNewReason r = false := by
  unfold checkGraphTransitions at h
  split at h <;> cases r <;> simp_all [isNewReason]

private theorem graphEdges_notNew (input : SolverInput)
    {r : InvalidReason} (h : checkGraphEdges input = some r) :
    isNewReason r = false := by
  unfold checkGraphEdges at h
  split at h <;> cases r <;> simp_all [isNewReason]

private theorem branchPlaces_notNew (input : SolverInput)
    {r : InvalidReason} (h : checkBranchPlaces input = some r) :
    isNewReason r = false := by
  unfold checkBranchPlaces at h
  apply firstSome_notNew (f := fun (t : TypedTransition) =>
    firstSome (t.outputPlaces ++ t.failurePlaces) (fun p =>
      if placeExists input.places p then none
      else some (.dependencyMismatch t.identity p)))
  · intro t ht r hr
    apply firstSome_notNew (f := fun p =>
      if placeExists input.places p then none
      else some (.dependencyMismatch t.identity p))
    · intro p hp s hs
      split at hs <;> cases s <;> simp_all [isNewReason]
    · exact hr
  · exact h

private theorem postValidation_notNew (input : SolverInput)
    {r : InvalidReason}
    (h : (match firstSome input.bindings (checkBindingStructure input) with
      | some reason => some reason
      | none =>
        match firstSome input.bindings (checkBindingRevision input) with
        | some reason => some reason
        | none =>
          match checkGraphPlaces input with
          | some reason => some reason
          | none =>
            match checkGraphTransitions input with
            | some reason => some reason
            | none =>
              match checkGraphEdges input with
              | some reason => some reason
              | none => checkBranchPlaces input) = some r) :
    isNewReason r = false := by
  cases hb : firstSome input.bindings (checkBindingStructure input) with
  | some q =>
      have hfirst : firstSome input.bindings (checkBindingStructure input) = some r := by
        simpa [hb] using h
      exact firstSome_notNew (xs := input.bindings) (f := checkBindingStructure input)
        (fun b _ s hs => bindingStructure_notNew input b hs) hfirst
  | none =>
      rw [hb] at h
      cases hr : firstSome input.bindings (checkBindingRevision input) with
      | some q =>
          have hfirst : firstSome input.bindings (checkBindingRevision input) = some r := by
            simpa [hb, hr] using h
          exact firstSome_notNew (xs := input.bindings) (f := checkBindingRevision input)
            (fun b _ s hs => bindingRevision_notNew input b hs) hfirst
      | none =>
          rw [hr] at h
          cases hg : checkGraphPlaces input with
          | some q =>
              simp only [hg] at h
              injection h with hr
              subst r
              exact graphPlaces_notNew input hg
          | none =>
              rw [hg] at h
              cases hgt : checkGraphTransitions input with
              | some q =>
                  simp only [hgt] at h
                  injection h with hr
                  subst r
                  exact graphTransitions_notNew input hgt
              | none =>
                  rw [hgt] at h
                  cases hge : checkGraphEdges input with
                  | some q =>
                      simp only [hge] at h
                      injection h with hr
                      subst r
                      exact graphEdges_notNew input hge
                  | none =>
                      simp only [hge] at h
                      exact branchPlaces_notNew input h


private theorem inputPlaceCheck_onlyUnknown (input : SolverInput)
    {r : InvalidReason} (h : checkInputPlaceMembership input = some r) :
    ∃ transitionId place,
      r = .unknownInputPlace transitionId place := by
  unfold checkInputPlaceMembership at h
  rcases firstSome_mem h with ⟨t, ht, hcheck⟩
  rcases firstSome_mem hcheck with ⟨p, hp, hplace⟩
  cases he : placeExists input.places p with
  | true => simp [he] at hplace
  | false =>
      simp only [he] at hplace
      cases hplace
      exact ⟨t.identity, p, rfl⟩

private theorem bindingCoverageCheck_onlyMissing (input : SolverInput)
    {r : InvalidReason} (h : checkBindingCoverage input = some r) :
    ∃ transitionId place,
      r = .missingInputBinding transitionId place := by
  unfold checkBindingCoverage at h
  rcases firstSome_mem h with ⟨t, ht, hcheck⟩
  cases he : t.inputPlaces.isEmpty with
  | true => simp [he] at hcheck
  | false =>
      have hcheck' : firstSome t.inputPlaces (fun p =>
          if input.bindings.any (fun b =>
              b.transitionId == t.identity && b.place == p)
          then none else some (.missingInputBinding t.identity p)) = some r := by
        simpa [he] using hcheck
      rcases firstSome_mem hcheck' with ⟨p, hp, hplace⟩
      cases hb : input.bindings.any (fun b =>
          b.transitionId == t.identity && b.place == p) with
      | true => simp [hb] at hplace
      | false =>
          simp only [hb] at hplace
          cases hplace
          exact ⟨t.identity, p, rfl⟩

theorem invalidInputReasonSound (input : SolverInput) (reason : InvalidReason)
    (h : validate input = some reason) : invalidReasonSound input reason := by
  cases reason with
  | unknownInputPlace transitionId place =>
      unfold validate at h
      have hcase : checkInputPlaceMembership input =
          some (.unknownInputPlace transitionId place) ∨
          invalidReasonSound input (.unknownInputPlace transitionId place) := by
        cases hi : checkInputPlaceMembership input with
        | some r =>
            have hr : r = .unknownInputPlace transitionId place := by
              rw [hi] at h
              injection h
            exact Or.inl (congrArg some hr)
        | none =>
            rw [hi] at h
            cases hd : checkDuplicateTransitionIdentity input with
            | some r =>
                rw [hd] at h
                have hr : r = .unknownInputPlace transitionId place := Option.some.inj h
                subst r
                have hdup := duplicateCheck_cases input
                cases hdup with
                | inl hnone => rw [hnone] at hd; cases hd
                | inr hex =>
                    rcases hex with ⟨identity, hid⟩
                    simp [hid] at hd
            | none =>
                cases hc : checkBindingCoverage input with
                | some r =>
                    simp [hc, hd] at h
                    have hr : r = .unknownInputPlace transitionId place := h
                    subst r
                    have hm := bindingCoverageCheck_onlyMissing input hc
                    rcases hm with ⟨tid, p, hm⟩
                    cases hm
                | none =>
                    simp [hd, hc] at h
                    have hpost :
                        (match firstSome input.bindings (checkBindingStructure input) with
                        | some reason => some reason
                        | none =>
                          match firstSome input.bindings (checkBindingRevision input) with
                          | some reason => some reason
                          | none =>
                            match checkGraphPlaces input with
                            | some reason => some reason
                            | none =>
                              match checkGraphTransitions input with
                              | some reason => some reason
                              | none =>
                                match checkGraphEdges input with
                                | some reason => some reason
                                | none => checkBranchPlaces input) =
                        some (.unknownInputPlace transitionId place) := by
                      exact h
                    have hn := postValidation_notNew input hpost
                    simp [isNewReason] at hn
      cases hcase with
      | inl hcheck => exact inputPlaceCheck_sound input hcheck
      | inr hs => exact hs
  | missingInputBinding transitionId place =>
      have hcase : checkBindingCoverage input =
          some (.missingInputBinding transitionId place) := by
        unfold validate at h
        cases hi : checkInputPlaceMembership input with
        | some r =>
            rw [hi] at h
            have hr : r = .missingInputBinding transitionId place := Option.some.inj h
            have ho := inputPlaceCheck_onlyUnknown input hi
            rcases ho with ⟨tid, p, ho⟩
            subst r
            cases ho
        | none =>
            rw [hi] at h
            cases hd : checkDuplicateTransitionIdentity input with
            | some r =>
                simp [hd] at h
                have hr : r = .missingInputBinding transitionId place := h
                have hdup := duplicateCheck_cases input
                cases hdup with
                | inl hnone => rw [hnone] at hd; cases hd
                | inr hex =>
                    rcases hex with ⟨identity, hid⟩
                    simp [hid] at hd
                    have hbad : InvalidReason.duplicateTransitionIdentity identity =
                        .missingInputBinding transitionId place := hd.trans hr
                    cases hbad
            | none =>
                cases hc : checkBindingCoverage input with
                | some r =>
                    simp [hc, hd] at h
                    have hr : r = .missingInputBinding transitionId place := h
                    subst r
                    exact rfl
                | none =>
                    simp [hc, hd] at h
                    have hn := postValidation_notNew input (by
                      simpa [hc] using h)
                    simp [isNewReason] at hn
      exact bindingCoverageCheck_sound input hcase
  | duplicateTransitionIdentity identity =>
      have hcase : checkDuplicateTransitionIdentity input =
          some (.duplicateTransitionIdentity identity) := by
        unfold validate at h
        cases hi : checkInputPlaceMembership input with
        | some r =>
            rw [hi] at h
            have hr : r = .duplicateTransitionIdentity identity := Option.some.inj h
            have ho := inputPlaceCheck_onlyUnknown input hi
            rcases ho with ⟨tid, p, ho⟩
            subst r
            cases ho
        | none =>
            rw [hi] at h
            cases hd : checkDuplicateTransitionIdentity input with
            | some r =>
                simp [hd] at h
                have hr : r = .duplicateTransitionIdentity identity := h
                subst r
                exact rfl
            | none =>
                cases hc : checkBindingCoverage input with
                | some r =>
                    simp [hc, hd] at h
                    have hr : r = .duplicateTransitionIdentity identity := h
                    have hm := bindingCoverageCheck_onlyMissing input hc
                    rcases hm with ⟨tid, p, hm⟩
                    have hbad : InvalidReason.missingInputBinding tid p =
                        InvalidReason.duplicateTransitionIdentity identity := hm.symm.trans hr
                    cases hbad
                | none =>
                    simp [hc, hd] at h
                    have hn := postValidation_notNew input (by
                      simpa [hc] using h)
                    simp [isNewReason] at hn
      unfold checkDuplicateTransitionIdentity at hcase
      cases hdup : duplicateTransitionIdentity input.transitions with
      | none => simp [hdup] at hcase
      | some found =>
          simp only [hdup] at hcase
          injection hcase with hident
          cases hident
          have hs := duplicateTransitionIdentity_sound input.transitions hdup
          rcases hs with ⟨prePaths, t, rest, hts, htid, hany⟩
          exact ⟨prePaths, t, rest, hts, htid, hany⟩
  | unknownPlace _ | unknownTransition _ | typeMismatch _ _ _
    | multiplicityMismatch _ _ _ _ | revisionMismatch _ _ _ _
    | identityMismatch _ _ | dependencyMismatch _ _ =>
      trivial



end Necoherence
