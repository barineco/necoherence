-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticExecution

namespace Necoherence.SemanticExecution

open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition

private theorem armApply_of_ok {K : Type} [DecidableEq K] (arms : List (K × PlanTree))
    (table : NecoQuotient.KeyedBlocks K PlanTree) (hq : NecoQuotient.keyedBlocksOf arms = .ok table)
    (key : K) : armApply arms key = .ok (table.apply key) := by
  unfold armApply
  rw [hq]
  rfl

private theorem lookupEntry_eq_find {K : Type} [DecidableEq K] {W : Type} (entries : List (K × W)) (key : K) :
    NecoQuotient.lookupEntry entries key = (entries.find? (fun pair => pair.1 == key)).map Prod.snd := by
  induction entries with
  | nil => rfl
  | cons e rest ih =>
    obtain ⟨k', w⟩ := e
    by_cases h : k' = key
    · simp [NecoQuotient.lookupEntry, h]
    · simp [NecoQuotient.lookupEntry, h, ih]

theorem armSelection_eq_find {K : Type} [DecidableEq K] (arms : List (K × PlanTree))
    (hn : (arms.map Prod.fst).Nodup) (key : K) :
    armApply arms key = .ok (match arms.find? (fun pair => pair.1 == key) with
      | some (_, tree) => .value tree
      | none => .residual key) := by
  obtain ⟨Q, hQ⟩ := (NecoQuotient.keyedBlocksOf_ok_iff arms).1.2 hn
  have hE : Q.entries = arms := (NecoQuotient.keyedBlocksOf_ok_iff arms).2 Q hQ
  have hl := lookupEntry_eq_find arms key
  subst hE
  rw [armApply_of_ok Q.entries Q hQ key]
  unfold NecoQuotient.KeyedBlocks.apply
  rw [hl]
  cases h : Q.entries.find? (fun pair => pair.1 == key) with
  | none => rfl
  | some p => obtain ⟨a, b⟩ := p; rfl

def guardKey (graph : SemanticGraph) (guard : DeclaredGuard) (value : SlotValue) : GuardArm :=
  match inspectGuard graph guard value with
  | .ok arm => arm
  | .error _ => .absent

theorem guardSelection_block (graph : SemanticGraph) (guard : DeclaredGuard)
    (arms : List (GuardArm × PlanTree)) (table : NecoQuotient.KeyedBlocks GuardArm PlanTree)
    (hq : NecoQuotient.keyedBlocksOf arms = .ok table)
    (x : SlotValue) (arm : GuardArm) (hx : inspectGuard graph guard x = .ok arm) (tree : PlanTree) :
    armApply arms arm = .ok (.value tree) ↔
      ∃ b, b ∈ table.blocks (guardKey graph guard) ∧ b.region x ∧ b.value = tree := by
  have hk : guardKey graph guard x = arm := by simp [guardKey, hx]
  have hA : armApply arms arm = .ok (table.apply arm) := armApply_of_ok arms table hq arm
  have hv := NecoQuotient.apply_value_iff table (guardKey graph guard) x tree
  rw [hk] at hv
  rw [hA, ← hv]
  constructor
  · intro h; injection h
  · intro h; rw [h]

theorem guardSelection_congr (graph : SemanticGraph) (guard : DeclaredGuard)
    (arms : List (GuardArm × PlanTree)) (table : NecoQuotient.KeyedBlocks GuardArm PlanTree)
    (hq : NecoQuotient.keyedBlocksOf arms = .ok table)
    (x y : SlotValue) (arm : GuardArm)
    (hx : inspectGuard graph guard x = .ok arm) (hy : inspectGuard graph guard y = .ok arm) :
    armApply arms (guardKey graph guard x) = armApply arms (guardKey graph guard y) ∧
      table.apply (guardKey graph guard x) = table.apply (guardKey graph guard y) := by
  have hkx : guardKey graph guard x = arm := by simp [guardKey, hx]
  have hky : guardKey graph guard y = arm := by simp [guardKey, hy]
  have hc := NecoQuotient.apply_congr table (guardKey graph guard) (x := x) (y := y) (by rw [hkx, hky])
  refine ⟨?_, hc⟩
  rw [armApply_of_ok arms table hq, armApply_of_ok arms table hq, hc]

private theorem unionSpec_iff_resolvedShapeFuel (graph : SemanticGraph) :
    ∀ (fuel : Nat) (ref : TypeRef) (spec : UnionSpec),
      unionSpec graph fuel ref = some spec ↔ resolvedShapeFuel graph fuel ref = some (.taggedUnion spec)
  | 0, _, _ => by simp [unionSpec, resolvedShapeFuel]
  | fuel + 1, ref, spec => by
    unfold unionSpec resolvedShapeFuel
    cases hfind : graph.findType ref with
    | none => simp
    | some node =>
      simp only [bind, Option.bind]
      cases hshape : node.shape with
      | alias target _ =>
        exact unionSpec_iff_resolvedShapeFuel graph fuel target spec
      | taggedUnion s =>
        simp [pure]
      | _ =>
        simp

theorem unionSpec_iff_resolvedShape (graph : SemanticGraph) (ref : TypeRef) (spec : UnionSpec) :
    unionSpec graph (graph.nodes.length + 1) ref = some spec ↔
      resolvedShape graph ref = some (.taggedUnion spec) :=
  unionSpec_iff_resolvedShapeFuel graph (graph.nodes.length + 1) ref spec

theorem inspectGuard_eq_evaluateGuardArm_presence (prepared : PreparedCompositionInput)
    (guard : DeclaredGuard) (contract : SlotContract) (value : SlotValue) (arm : GuardArm)
    (hkind : guard.kind = .presence) :
    inspectGuard prepared.graph guard value = .ok arm ↔
      evaluateGuardArm prepared guard contract value = .ok arm := by
  cases value <;> simp [inspectGuard, evaluateGuardArm, hkind, pure, Except.pure]

theorem inspectGuard_eq_evaluateGuardArm_validate (prepared : PreparedCompositionInput)
    (guard : DeclaredGuard) (target contract : SlotContract) (value : SlotValue) (arm : GuardArm)
    (hkind : guard.kind = .validate target) :
    inspectGuard prepared.graph guard value = .ok arm ↔
      evaluateGuardArm prepared guard contract value = .ok arm := by
  unfold inspectGuard evaluateGuardArm
  rw [hkind]
  simp only []
  cases hval : validateSlot prepared.graph target value with
  | ok _ =>
    have ha : acceptsSlot prepared.graph target value = .accepted := by
      unfold acceptsSlot; rw [hval]; rfl
    rw [ha]
    simp [pure, Except.pure]
  | error err =>
    cases err with
    | value f =>
      have ha : acceptsSlot prepared.graph target value = .rejected f := by
        unfold acceptsSlot; rw [hval]; rfl
      rw [ha]
      simp [pure, Except.pure]
    | unresolved o =>
      have ha : acceptsSlot prepared.graph target value = .unresolved o := by
        unfold acceptsSlot; rw [hval]; rfl
      rw [ha]
      simp [throw, throwThe, MonadExceptOf.throw]
    | certificateMismatch c =>
      have ha : acceptsSlot prepared.graph target value =
          .unresolved [obligationAt prepared.graph target.typeRef [] (.certificateMismatch c)] := by
        unfold acceptsSlot; rw [hval]; rfl
      rw [ha]
      simp [throw, throwThe, MonadExceptOf.throw]

theorem inspectGuard_eq_evaluateGuardArm_variants (prepared : PreparedCompositionInput)
    (guard : DeclaredGuard) (contract : SlotContract) (value : SlotValue) (arm : GuardArm)
    (hkind : guard.kind = .variants)
    (projection : ProjectionCertificate)
    (hproj : projectSlot prepared.graph
      { typeRef := guard.sourceType, required := true, nullable := false } guard.path = .ok projection)
    (htype : projection.destination.typeRef = contract.typeRef) :
    inspectGuard prepared.graph guard value = .ok arm ↔
      evaluateGuardArm prepared guard contract value = .ok arm := by
  unfold inspectGuard evaluateGuardArm
  rw [hkind]
  cases value with
  | absent => simp [pure, Except.pure]
  | null => simp [pure, Except.pure]
  | present jv =>
    cases jv with
    | obj members =>
      simp only []
      cases htag : memberValue ((prepared.graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") members with
      | none => simp [throw, throwThe, MonadExceptOf.throw]
      | some tv =>
        cases tv with
        | str tag =>
          simp only [hproj]
          cases hspec : unionSpec prepared.graph (prepared.graph.nodes.length + 1) projection.destination.typeRef with
          | none =>
            cases hr : resolvedShape prepared.graph contract.typeRef with
            | none => simp [throw, throwThe, MonadExceptOf.throw]
            | some sh =>
              cases sh with
              | taggedUnion s =>
                have hu := (unionSpec_iff_resolvedShape prepared.graph projection.destination.typeRef s).mpr (by rw [htype]; exact hr)
                rw [hspec] at hu
                cases hu
              | _ => simp [throw, throwThe, MonadExceptOf.throw]
          | some spec =>
            have hr : resolvedShape prepared.graph contract.typeRef = some (.taggedUnion spec) := by
              rw [← htype]
              exact (unionSpec_iff_resolvedShape prepared.graph projection.destination.typeRef spec).mp hspec
            simp only [hr]
            cases hbr : selectUnionBranch prepared.graph.profile spec (.obj members) with
            | none => simp [throw, throwThe, MonadExceptOf.throw]
            | some branch => simp [pure, Except.pure]
        | _ => simp [throw, throwThe, MonadExceptOf.throw]
    | _ => simp [throw, throwThe, MonadExceptOf.throw]

private theorem find_some_of_mem_unique {α : Type} (l : List α) (p : α → Bool) (x : α)
    (hmem : x ∈ l) (hp : p x = true) : ∃ y, l.find? p = some y := by
  induction l with
  | nil => simp at hmem
  | cons a rest ih =>
    simp only [List.find?_cons]
    cases hpa : p a with
    | true => exact ⟨a, rfl⟩
    | false =>
      rcases List.mem_cons.mp hmem with rfl | hrest
      · rw [hp] at hpa; cases hpa
      · exact ih hrest

private theorem selectArm_of_nodup_mem {K : Type} [DecidableEq K] (arms : List (K × PlanTree))
    (hn : (arms.map Prod.fst).Nodup) (key : K) (child : PlanTree) (hmem : (key, child) ∈ arms)
    (dup mismatch : String) :
    ∃ table : NecoQuotient.KeyedBlocks K PlanTree,
      NecoQuotient.keyedBlocksOf arms = .ok table ∧
      table.apply key = .value child ∧
      selectArm arms key dup mismatch = .ok child := by
  obtain ⟨table, hq⟩ := (NecoQuotient.keyedBlocksOf_ok_iff arms).1.2 hn
  have hE : table.entries = arms := (NecoQuotient.keyedBlocksOf_ok_iff arms).2 table hq
  have hfind : arms.find? (fun pair => pair.1 == key) = some (key, child) := by
    clear table hq hE
    induction arms with
    | nil => simp at hmem
    | cons head rest ih =>
      obtain ⟨k', t'⟩ := head
      simp only [List.map_cons, List.nodup_cons] at hn
      rcases List.mem_cons.mp hmem with hhead | hrest
      · injection hhead with hk ht
        subst hk; subst ht
        simp
      · have hne : k' ≠ key := by
          intro heq
          subst heq
          exact hn.1 (List.mem_map.mpr ⟨(k', child), hrest, rfl⟩)
        have hfalse : (k' == key) = false := by rw [beq_eq_false_iff_ne]; exact hne
        simp only [List.find?_cons, hfalse]
        exact ih hn.2 hrest
  have happly : armApply arms key = .ok (.value child) := by
    rw [armSelection_eq_find arms hn key, hfind]
  have htapply : table.apply key = .value child := by
    rw [armApply_of_ok arms table hq key] at happly
    injection happly
  refine ⟨table, hq, htapply, ?_⟩
  simp [selectArm, happly, pure, Except.pure]

private theorem required_false_of_accepts_absent (graph : SemanticGraph) (slot : SlotContract)
    (hslot : acceptsSlot graph slot .absent = .accepted) : slot.required = false := by
  cases hr : slot.required with
  | false => rfl
  | true =>
    exfalso
    cases hval : validateSlot graph slot .absent with
    | ok v =>
      exact required_absent_rejected graph slot hr v.member
    | error err =>
      cases err with
      | value f =>
        have ha : acceptsSlot graph slot .absent = .rejected f := by
          unfold acceptsSlot; rw [hval]; rfl
        rw [ha] at hslot; cases hslot
      | unresolved o =>
        have ha : acceptsSlot graph slot .absent = .unresolved o := by
          unfold acceptsSlot; rw [hval]; rfl
        rw [ha] at hslot; cases hslot
      | certificateMismatch c =>
        have ha : acceptsSlot graph slot .absent =
            .unresolved [obligationAt graph slot.typeRef [] (.certificateMismatch c)] := by
          unfold acceptsSlot; rw [hval]; rfl
        rw [ha] at hslot; cases hslot

private theorem nullable_true_of_accepts_null (graph : SemanticGraph) (slot : SlotContract)
    (hslot : acceptsSlot graph slot .null = .accepted) : slot.nullable = true := by
  cases hn : slot.nullable with
  | true => rfl
  | false =>
    exfalso
    cases hval : validateSlot graph slot .null with
    | ok v =>
      exact nonnullable_null_rejected graph slot hn v.member
    | error err =>
      cases err with
      | value f =>
        have ha : acceptsSlot graph slot .null = .rejected f := by
          unfold acceptsSlot; rw [hval]; rfl
        rw [ha] at hslot; cases hslot
      | unresolved o =>
        have ha : acceptsSlot graph slot .null = .unresolved o := by
          unfold acceptsSlot; rw [hval]; rfl
        rw [ha] at hslot; cases hslot
      | certificateMismatch c =>
        have ha : acceptsSlot graph slot .null =
            .unresolved [obligationAt graph slot.typeRef [] (.certificateMismatch c)] := by
          unfold acceptsSlot; rw [hval]; rfl
        rw [ha] at hslot; cases hslot

theorem inspectGuard_mem_guardArms (prepared : PreparedCompositionInput) (state : SearchState)
    (guard : DeclaredGuard) (inspected : ValueRef) (partition : List GuardArm)
    (hga : guardArms prepared state guard inspected = .ok partition)
    (projected : ProjectionCertificate)
    (hproj : effectiveProjection prepared state inspected = .ok projected)
    (value : SlotValue) (arm : GuardArm)
    (hinsp : inspectGuard prepared.graph guard value = .ok arm)
    (hslot : acceptsSlot prepared.graph projected.destination value = .accepted)
    (hexact : ∀ v, exactValue prepared state inspected = some v → value = v)
    (hvarProj : guard.kind = .variants →
      ∃ projection, projectSlot prepared.graph
        { typeRef := guard.sourceType, required := true, nullable := false } guard.path = .ok projection ∧
        projection.destination.typeRef = projected.destination.typeRef) :
    arm ∈ partition := by
  unfold guardArms at hga
  cases hused : state.usedGuards.contains guard.id with
  | true =>
    rw [hused] at hga
    simp [bind, Except.bind, throw, throwThe, MonadExceptOf.throw] at hga
  | false =>
    simp only [hused, Bool.false_eq_true, ↓reduceIte] at hga
    cases hsrc : state.available.find? (fun source => source.producer == inspected.producer) with
    | none => simp [hsrc, throw, throwThe, MonadExceptOf.throw] at hga
    | some source =>
      simp only [hsrc] at hga
      cases hdom : (source.contract.typeRef != guard.sourceType || inspected.path != guard.path) with
      | true =>
        rw [hdom] at hga
        simp [bind, Except.bind, throw, throwThe, MonadExceptOf.throw] at hga
      | false =>
        simp only [hdom, Bool.false_eq_true, ↓reduceIte, hproj, bind, Except.bind] at hga
        cases hex : exactValue prepared state inspected with
        | some v =>
          have hveq : value = v := hexact v hex
          subst hveq
          simp only [hex] at hga
          cases heval : evaluateGuardArm prepared guard projected.destination value with
          | error _ => simp [heval] at hga
          | ok arm' =>
            simp only [heval, pure, Except.pure, Except.ok.injEq] at hga
            subst hga
            have hsame : evaluateGuardArm prepared guard projected.destination value = .ok arm := by
              cases hkind : guard.kind with
              | presence =>
                exact (inspectGuard_eq_evaluateGuardArm_presence prepared guard projected.destination value arm hkind).mp hinsp
              | validate target =>
                exact (inspectGuard_eq_evaluateGuardArm_validate prepared guard target projected.destination value arm hkind).mp hinsp
              | variants =>
                obtain ⟨projection, hp, ht⟩ := hvarProj hkind
                exact (inspectGuard_eq_evaluateGuardArm_variants prepared guard projected.destination value arm hkind projection hp ht).mp hinsp
            rw [heval] at hsame
            injection hsame with harmEq
            subst harmEq
            simp
        | none =>
          simp only [hex] at hga
          cases hkind : guard.kind with
          | validate target =>
            simp only [hkind] at hga hinsp
            cases hob : (meaningObligations prepared.graph [target.typeRef]).isEmpty with
            | false => simp [hob, throw, throwThe, MonadExceptOf.throw] at hga
            | true =>
              simp only [hob, Bool.not_true, Bool.false_eq_true, ↓reduceIte, pure, Except.pure, Except.ok.injEq] at hga
              subst hga
              unfold inspectGuard at hinsp
              rw [hkind] at hinsp
              cases hval : validateSlot prepared.graph target value with
              | ok _ =>
                simp [hval, pure, Except.pure] at hinsp
                subst hinsp; simp
              | error err =>
                cases err with
                | value _ =>
                  simp [hval, pure, Except.pure] at hinsp
                  subst hinsp; simp
                | unresolved _ => simp [hval, throw, throwThe, MonadExceptOf.throw] at hinsp
                | certificateMismatch _ => simp [hval, throw, throwThe, MonadExceptOf.throw] at hinsp
          | presence =>
            simp only [hkind, pure, Except.pure, Except.ok.injEq] at hga
            subst hga
            unfold inspectGuard at hinsp
            rw [hkind] at hinsp
            cases value with
            | absent =>
              simp [pure, Except.pure] at hinsp
              subst hinsp
              simp [required_false_of_accepts_absent prepared.graph projected.destination hslot]
            | null =>
              simp [pure, Except.pure] at hinsp
              subst hinsp
              simp [nullable_true_of_accepts_null prepared.graph projected.destination hslot]
            | present _ =>
              simp [pure, Except.pure] at hinsp
              subst hinsp
              simp
          | variants =>
            simp only [hkind] at hga
            cases hres : resolvedShape prepared.graph projected.destination.typeRef with
            | none => simp [hres, throw, throwThe, MonadExceptOf.throw] at hga
            | some sh =>
              cases sh with
              | taggedUnion spec =>
                simp only [hres, pure, Except.pure, Except.ok.injEq] at hga
                subst hga
                unfold inspectGuard at hinsp
                rw [hkind] at hinsp
                cases value with
                | absent =>
                  simp [pure, Except.pure] at hinsp
                  subst hinsp
                  simp [required_false_of_accepts_absent prepared.graph projected.destination hslot]
                | null =>
                  simp [pure, Except.pure] at hinsp
                  subst hinsp
                  simp [nullable_true_of_accepts_null prepared.graph projected.destination hslot]
                | present jv =>
                  cases jv with
                  | obj members =>
                    obtain ⟨projection, hp, ht⟩ := hvarProj hkind
                    have hu : unionSpec prepared.graph (prepared.graph.nodes.length + 1) projection.destination.typeRef = some spec :=
                      (unionSpec_iff_resolvedShape prepared.graph projection.destination.typeRef spec).mpr (by rw [ht]; exact hres)
                    simp only [] at hinsp
                    cases htag : memberValue ((prepared.graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") members with
                    | none => simp [htag, throw, throwThe, MonadExceptOf.throw] at hinsp
                    | some tv =>
                      cases tv with
                      | str tag =>
                        simp only [htag, hp, hu] at hinsp
                        cases hbr : selectUnionBranch prepared.graph.profile spec (.obj members) with
                        | none => simp [hbr, throw, throwThe, MonadExceptOf.throw] at hinsp
                        | some branch =>
                          simp only [hbr, pure, Except.pure, Except.ok.injEq] at hinsp
                          subst hinsp
                          have hbmem : branch ∈ spec.branches := by
                            unfold selectUnionBranch at hbr
                            exact List.mem_of_find?_eq_some hbr
                          have hvmem : GuardArm.variant branch.wireTag ∈ spec.branches.map (fun b => GuardArm.variant b.wireTag) :=
                            List.mem_map.mpr ⟨branch, hbmem, rfl⟩
                          simp [hvmem]
                      | _ => simp [htag, throw, throwThe, MonadExceptOf.throw] at hinsp
                  | _ => simp [throw, throwThe, MonadExceptOf.throw] at hinsp
              | _ => simp [hres, throw, throwThe, MonadExceptOf.throw] at hga

theorem justified_guard_no_invalidPlan (prepared : PreparedCompositionInput)
    (state : SearchState) (rank : Nat) (id : GuardId) (inspected : ValueRef)
    (arms : List (GuardArm × PlanTree))
    (hplan : PlanJustified prepared state (.guard rank id inspected arms))
    (dup mismatch : String) :
    (∃ decl, prepared.input.invocationDomain.guards.find? (fun g => g.id == id) = some decl) ∧
    (∃ (declaration : DeclaredGuard) (partition : List GuardArm)
        (table : NecoQuotient.KeyedBlocks GuardArm PlanTree),
      declaration ∈ prepared.input.invocationDomain.guards ∧
      declaration.id = id ∧
      guardArms prepared state declaration inspected = .ok partition ∧
      NecoQuotient.keyedBlocksOf arms = .ok table ∧
      ∀ arm ∈ partition, ∃ child,
        selectArm arms arm dup mismatch = .ok child ∧
        table.apply arm = .value child ∧
        (arm, child) ∈ arms ∧
        ∃ next, afterGuard prepared state declaration inspected arm = .ok next ∧
          PlanJustified prepared next child) := by
  cases hplan with
  | guard _ _ _ _ _ declaration declared partition computed coverage children =>
    have hfind : ∃ decl, prepared.input.invocationDomain.guards.find? (fun g => g.id == id) = some decl :=
      find_some_of_mem_unique prepared.input.invocationDomain.guards (fun g => g.id == id) declaration declared.1
        (by simp [declared.2])
    obtain ⟨table, hq⟩ := (NecoQuotient.keyedBlocksOf_ok_iff arms).1.2 coverage.1
    refine ⟨hfind, declaration, partition, table, declared.1, declared.2, computed, hq, ?_⟩
    intro arm harm
    obtain ⟨child, hmem⟩ := coverage.2 arm harm
    obtain ⟨table', hq', htapply, hsel⟩ := selectArm_of_nodup_mem arms coverage.1 arm child hmem dup mismatch
    have hteq : table' = table := by rw [hq] at hq'; cases hq'; rfl
    subst hteq
    have hchild := PlanJ.guardChildren children (arm, child) hmem
    obtain ⟨_, next, htrans, _, hnext⟩ := hchild
    exact ⟨child, hsel, htapply, hmem, next, htrans, hnext⟩

theorem justified_invocation_no_invalidPlan (prepared : PreparedCompositionInput)
    (state : SearchState) (rank : Nat) (invocation : InvocationPlan)
    (arms : List (OutcomeId × PlanTree)) (empty : List OutcomeId)
    (hplan : PlanJustified prepared state (.invoke rank invocation arms empty))
    (dup mismatch : String) :
    (∃ sig, prepared.input.signatures.find? (fun s => s.reference == invocation.function) = some sig) ∧
    (∃ (checked : InvocationJustified prepared state invocation)
        (table : NecoQuotient.KeyedBlocks OutcomeId PlanTree),
      NecoQuotient.keyedBlocksOf arms = .ok table ∧
      ∀ outcome ∈ checked.function.outcomes,
        ¬ OutcomeImpossible prepared.graph outcome →
        ∃ child,
          selectArm arms outcome.id dup mismatch = .ok child ∧
          table.apply outcome.id = .value child ∧
          (outcome.id, child) ∈ arms ∧
          PlanJustified prepared (afterInvocation state invocation outcome) child) := by
  cases hplan with
  | invocation _ _ _ _ _ checked emptySound coverage children =>
    have hsig : ∃ sig, prepared.input.signatures.find? (fun s => s.reference == invocation.function) = some sig := by
      have hres := checked.resolved
      unfold siteSignature at hres
      cases hsite : prepared.input.invocationDomain.sites.find? (fun candidate => decide (candidate.id = invocation.site)) with
      | none => simp [hsite] at hres
      | some siteDecl =>
        simp only [hsite] at hres
        have hmem : checked.function ∈ prepared.input.signatures :=
          List.mem_of_find?_eq_some hres
        exact find_some_of_mem_unique prepared.input.signatures (fun s => s.reference == invocation.function)
          checked.function hmem (by simp [checked.identity])
    obtain ⟨table, hq⟩ := (NecoQuotient.keyedBlocksOf_ok_iff arms).1.2 coverage.1
    refine ⟨hsig, checked, table, hq, ?_⟩
    intro outcome hout hposs
    have hnotEmpty : outcome.id ∉ empty := fun hem => hposs (emptySound outcome hout hem)
    have hmem : ∃ child, (outcome.id, child) ∈ arms := by
      rcases coverage.2 outcome hout with hem | hcov
      · exact False.elim (hnotEmpty hem)
      · exact hcov
    obtain ⟨child, hcmem⟩ := hmem
    obtain ⟨table', hq', htapply, hsel⟩ := selectArm_of_nodup_mem arms coverage.1 outcome.id child hcmem dup mismatch
    have hteq : table' = table := by rw [hq] at hq'; cases hq'; rfl
    subst hteq
    have hchild := PlanJ.outcomeChildren children (outcome.id, child) hcmem
    obtain ⟨outcome', hout', hid', _, hnext⟩ := hchild
    have heqOut : outcome' = outcome := by
      have hnodup := checked.outcomeUnique
      generalize houts : checked.function.outcomes = outs at hnodup hout hout'
      clear houts
      induction outs with
      | nil => simp at hout
      | cons a rest ih =>
        simp only [List.map_cons, List.nodup_cons] at hnodup
        rcases List.mem_cons.mp hout with rfl | hrest
        · rcases List.mem_cons.mp hout' with rfl | hrest'
          · rfl
          · exact False.elim (hnodup.1 (List.mem_map.mpr ⟨outcome', hrest', hid'⟩))
        · rcases List.mem_cons.mp hout' with rfl | hrest'
          · exact False.elim (hnodup.1 (List.mem_map.mpr ⟨outcome, hrest, hid'.symm⟩))
          · exact ih hnodup.2 hrest hrest'
    subst heqOut
    exact ⟨child, hsel, htapply, hcmem, hnext⟩

theorem justified_terminal_failure_no_invalidPlan (prepared : PreparedCompositionInput)
    (state : SearchState) (rank : Nat) (embedding : FailureEmbeddingId) (binding : BindingExpr)
    (hplan : PlanJustified prepared state (.returnValue rank (.failure embedding binding))) :
    ∃ decl, prepared.input.goal.failures.find? (fun e => e.id == embedding) = some decl := by
  cases hplan with
  | terminal _ _ _ checked =>
    obtain ⟨decl, hmem, hid, _, _⟩ := checked.failureBinding embedding binding rfl
    exact find_some_of_mem_unique prepared.input.goal.failures (fun e => e.id == embedding) decl hmem (by simp [hid])

theorem justified_terminal_success_coverage (prepared : PreparedCompositionInput)
    (state : SearchState) (rank : Nat) (outputs : List (GoalPortId × BindingExpr))
    (hplan : PlanJustified prepared state (.returnValue rank (.success outputs))) :
    ∀ goal ∈ prepared.input.goal.outputs, ∃ binding ∈ outputs, binding.1 = goal.id := by
  cases hplan with
  | terminal _ _ _ checked =>
    intro goal hgoal
    obtain ⟨binding, hmem, hid, _⟩ := checked.successBindings outputs rfl goal hgoal
    exact ⟨binding, hmem, hid⟩

end Necoherence.SemanticExecution
