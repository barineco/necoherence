-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.ExactJson

namespace Necoherence.SemanticTypes

open Necoherence.ExactJson

structure SourceIdentity where
  repository : String
  revision : String
  path : String
  contentDigest : String
  deriving Repr, DecidableEq

structure Origin where
  source : SourceIdentity
  locator : List String
  deriving Repr, DecidableEq

structure SourceRef where
  repository : String
  revision : String
  path : String
  contentDigest : String
  documentId : String
  declaredRevision : Option Int := none
  deriving Repr, DecidableEq

structure ProfileRef where
  identity : String
  revision : String
  contentDigest : String
  deriving Repr, DecidableEq

structure TypeRef where
  source : SourceRef
  definitionName : String
  pointer : List String
  deriving Repr, DecidableEq

structure DefinitionRef where
  source : SourceRef
  name : String
  deriving Repr, DecidableEq

structure OccurrenceRef where
  source : SourceRef
  pointer : List String
  deriving Repr, DecidableEq

inductive IntegerDomain where
  | unbounded
  | inclusive (minimum maximum : Int)
  deriving BEq, Repr

inductive IntegerForm where
  | number
  | integralDecimal
  | decimalString
  deriving BEq, Repr

structure IntegerDomainBinding where
  name : String
  reference : ProfileRef
  range : IntegerDomain
  forms : List IntegerForm
  deriving BEq, Repr

structure NumberModel where
  decimals : Bool
  deriving BEq, Repr

inductive BytesAlphabet where
  | standard
  | urlSafe
  | either
  deriving BEq, Repr

inductive StringLengthUnit where
  | utf8Bytes
  | unicodeScalars
  | graphemes
  deriving BEq, Repr, DecidableEq

structure CodepointRange where
  first : Nat
  last : Nat
  deriving BEq, Repr

inductive GraphemeProperty where
  | other | cr | lf | control | extend | zwj | regionalIndicator
  | prepend | spacingMark | l | v | t | lv | lvt
  deriving BEq, Repr

structure GraphemeRange where
  first : Nat
  last : Nat
  property : GraphemeProperty
  deriving BEq, Repr

inductive IndicProperty where
  | other | consonant | extend | linker
  deriving BEq, Repr

structure IndicRange where
  first : Nat
  last : Nat
  property : IndicProperty
  deriving BEq, Repr

structure GraphemeComponent where
  unicodeVersion : String := "16.0.0"
  uax29Revision : String := "45"
  clusterProfile : String := "C1-1-default-extended-grapheme-cluster-no-tailoring"
  deriving BEq, Repr

structure GraphemeSource where
  role : String
  origin : Origin
  deriving BEq, Repr

structure GraphemeRules where
  reference : ProfileRef
  properties : List GraphemeRange
  extendedPictographic : List CodepointRange
  indicConjunct : List IndicRange
  component : GraphemeComponent := {}
  tableSha256 : String := ""
  sources : List GraphemeSource := []
  deriving BEq, Repr

structure BytesPolicy where
  reference : ProfileRef
  paddingOptional : Bool
  alphabet : BytesAlphabet := .standard
  strictPadBits : Bool := true
  wrapper : Option String := none
  deriving BEq, Repr

structure CalendarRule where
  allowSecond60 : Bool
  minimumYear : Nat
  maximumYear : Nat
  rejectUtcYearOutsideRange : Bool
  deriving BEq, Repr, DecidableEq

structure DfaTransition where
  fromState : Nat
  first : Nat
  last : Nat
  toState : Nat
  deriving BEq, Repr, DecidableEq

structure DfaSpec where
  stateCount : Nat
  initialState : Nat
  acceptingStates : List Nat
  transitions : List DfaTransition
  deriving BEq, Repr, DecidableEq

inductive FormatRule where
  | literal (value : String)
  | sequence (parts : List FormatRule)
  | optional (rule : FormatRule)
  | labels (separator : String) (minCount : Nat) (maxCount totalMax : Option Nat) (rule : FormatRule)
  | bounded (unit : StringLengthUnit) (maximum : Nat) (rule : FormatRule)
  | asciiDfa (spec : DfaSpec)
  | identifier (firstAlphabet restAlphabet : String) (exactLength : Option Nat)
      (minLength : Nat) (maxLength : Option Nat) (forbidden : List String)
  | timestamp (rule : CalendarRule)
  | absoluteUri (maxBytes : Option Nat)
  | languageTag (grandfathered : List String)
  | choice (rules : List FormatRule)
  | text
  | not (rule : FormatRule)
  deriving BEq, Repr, Inhabited

mutual
  private def formatRuleDecidableEq : (left right : FormatRule) → Decidable (left = right)
    | .literal left, .literal right =>
      if equal : left = right then isTrue (equal ▸ rfl)
      else isFalse (fun same => equal (FormatRule.literal.inj same))
    | .sequence left, .sequence right =>
      match formatRulesDecidableEq left right with
      | isTrue equal => isTrue (equal ▸ rfl)
      | isFalse different => isFalse (fun same => different (FormatRule.sequence.inj same))
    | .optional left, .optional right =>
      match formatRuleDecidableEq left right with
      | isTrue equal => isTrue (equal ▸ rfl)
      | isFalse different => isFalse (fun same => different (FormatRule.optional.inj same))
    | .labels ls lm lmax ltotal lr, .labels rs rm rmax rtotal rr =>
      if fields : (ls, lm, lmax, ltotal) = (rs, rm, rmax, rtotal) then
        match formatRuleDecidableEq lr rr with
        | isTrue rule => isTrue (by cases fields; cases rule; rfl)
        | isFalse different => isFalse (by intro same; cases same; exact different rfl)
      else isFalse (by intro same; cases same; exact fields rfl)
    | .bounded lu lm lr, .bounded ru rm rr =>
      if fields : (lu, lm) = (ru, rm) then
        match formatRuleDecidableEq lr rr with
        | isTrue rule => isTrue (by cases fields; cases rule; rfl)
        | isFalse different => isFalse (by intro same; cases same; exact different rfl)
      else isFalse (by intro same; cases same; exact fields rfl)
    | .asciiDfa left, .asciiDfa right =>
      if equal : left = right then isTrue (equal ▸ rfl)
      else isFalse (fun same => equal (FormatRule.asciiDfa.inj same))
    | .identifier lf lr le lmin lmax lforbidden,
        .identifier rf rr re rmin rmax rforbidden =>
      if fields : (lf, lr, le, lmin, lmax, lforbidden) =
          (rf, rr, re, rmin, rmax, rforbidden) then
        isTrue (by cases fields; rfl)
      else isFalse (by intro same; cases same; exact fields rfl)
    | .timestamp left, .timestamp right =>
      if equal : left = right then isTrue (equal ▸ rfl)
      else isFalse (fun same => equal (FormatRule.timestamp.inj same))
    | .absoluteUri left, .absoluteUri right =>
      if equal : left = right then isTrue (equal ▸ rfl)
      else isFalse (fun same => equal (FormatRule.absoluteUri.inj same))
    | .languageTag left, .languageTag right =>
      if equal : left = right then isTrue (equal ▸ rfl)
      else isFalse (fun same => equal (FormatRule.languageTag.inj same))
    | .choice left, .choice right =>
      match formatRulesDecidableEq left right with
      | isTrue equal => isTrue (equal ▸ rfl)
      | isFalse different => isFalse (fun same => different (FormatRule.choice.inj same))
    | .text, .text => isTrue rfl
    | .not left, .not right =>
      match formatRuleDecidableEq left right with
      | isTrue equal => isTrue (equal ▸ rfl)
      | isFalse different => isFalse (fun same => different (FormatRule.not.inj same))
    | .literal _, .sequence _ => isFalse (by intro same; contradiction)
    | .literal _, .optional _ => isFalse (by intro same; contradiction)
    | .literal _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .literal _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .literal _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .literal _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .literal _, .timestamp _ => isFalse (by intro same; contradiction)
    | .literal _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .literal _, .languageTag _ => isFalse (by intro same; contradiction)
    | .literal _, .choice _ => isFalse (by intro same; contradiction)
    | .literal _, .text => isFalse (by intro same; contradiction)
    | .literal _, .not _ => isFalse (by intro same; contradiction)
    | .sequence _, .literal _ => isFalse (by intro same; contradiction)
    | .sequence _, .optional _ => isFalse (by intro same; contradiction)
    | .sequence _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .sequence _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .sequence _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .sequence _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .sequence _, .timestamp _ => isFalse (by intro same; contradiction)
    | .sequence _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .sequence _, .languageTag _ => isFalse (by intro same; contradiction)
    | .sequence _, .choice _ => isFalse (by intro same; contradiction)
    | .sequence _, .text => isFalse (by intro same; contradiction)
    | .sequence _, .not _ => isFalse (by intro same; contradiction)
    | .optional _, .literal _ => isFalse (by intro same; contradiction)
    | .optional _, .sequence _ => isFalse (by intro same; contradiction)
    | .optional _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .optional _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .optional _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .optional _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .optional _, .timestamp _ => isFalse (by intro same; contradiction)
    | .optional _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .optional _, .languageTag _ => isFalse (by intro same; contradiction)
    | .optional _, .choice _ => isFalse (by intro same; contradiction)
    | .optional _, .text => isFalse (by intro same; contradiction)
    | .optional _, .not _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .literal _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .sequence _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .optional _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .timestamp _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .languageTag _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .choice _ => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .text => isFalse (by intro same; contradiction)
    | .labels _ _ _ _ _, .not _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .literal _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .sequence _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .optional _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .timestamp _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .languageTag _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .choice _ => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .text => isFalse (by intro same; contradiction)
    | .bounded _ _ _, .not _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .literal _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .sequence _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .optional _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .timestamp _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .languageTag _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .choice _ => isFalse (by intro same; contradiction)
    | .asciiDfa _, .text => isFalse (by intro same; contradiction)
    | .asciiDfa _, .not _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .literal _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .sequence _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .optional _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .timestamp _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .languageTag _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .choice _ => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .text => isFalse (by intro same; contradiction)
    | .identifier _ _ _ _ _ _, .not _ => isFalse (by intro same; contradiction)
    | .timestamp _, .literal _ => isFalse (by intro same; contradiction)
    | .timestamp _, .sequence _ => isFalse (by intro same; contradiction)
    | .timestamp _, .optional _ => isFalse (by intro same; contradiction)
    | .timestamp _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .timestamp _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .timestamp _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .timestamp _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .timestamp _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .timestamp _, .languageTag _ => isFalse (by intro same; contradiction)
    | .timestamp _, .choice _ => isFalse (by intro same; contradiction)
    | .timestamp _, .text => isFalse (by intro same; contradiction)
    | .timestamp _, .not _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .literal _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .sequence _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .optional _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .timestamp _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .languageTag _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .choice _ => isFalse (by intro same; contradiction)
    | .absoluteUri _, .text => isFalse (by intro same; contradiction)
    | .absoluteUri _, .not _ => isFalse (by intro same; contradiction)
    | .languageTag _, .literal _ => isFalse (by intro same; contradiction)
    | .languageTag _, .sequence _ => isFalse (by intro same; contradiction)
    | .languageTag _, .optional _ => isFalse (by intro same; contradiction)
    | .languageTag _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .languageTag _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .languageTag _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .languageTag _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .languageTag _, .timestamp _ => isFalse (by intro same; contradiction)
    | .languageTag _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .languageTag _, .choice _ => isFalse (by intro same; contradiction)
    | .languageTag _, .text => isFalse (by intro same; contradiction)
    | .languageTag _, .not _ => isFalse (by intro same; contradiction)
    | .choice _, .literal _ => isFalse (by intro same; contradiction)
    | .choice _, .sequence _ => isFalse (by intro same; contradiction)
    | .choice _, .optional _ => isFalse (by intro same; contradiction)
    | .choice _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .choice _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .choice _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .choice _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .choice _, .timestamp _ => isFalse (by intro same; contradiction)
    | .choice _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .choice _, .languageTag _ => isFalse (by intro same; contradiction)
    | .choice _, .text => isFalse (by intro same; contradiction)
    | .choice _, .not _ => isFalse (by intro same; contradiction)
    | .text, .literal _ => isFalse (by intro same; contradiction)
    | .text, .sequence _ => isFalse (by intro same; contradiction)
    | .text, .optional _ => isFalse (by intro same; contradiction)
    | .text, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .text, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .text, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .text, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .text, .timestamp _ => isFalse (by intro same; contradiction)
    | .text, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .text, .languageTag _ => isFalse (by intro same; contradiction)
    | .text, .choice _ => isFalse (by intro same; contradiction)
    | .text, .not _ => isFalse (by intro same; contradiction)
    | .not _, .literal _ => isFalse (by intro same; contradiction)
    | .not _, .sequence _ => isFalse (by intro same; contradiction)
    | .not _, .optional _ => isFalse (by intro same; contradiction)
    | .not _, .labels _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .not _, .bounded _ _ _ => isFalse (by intro same; contradiction)
    | .not _, .asciiDfa _ => isFalse (by intro same; contradiction)
    | .not _, .identifier _ _ _ _ _ _ => isFalse (by intro same; contradiction)
    | .not _, .timestamp _ => isFalse (by intro same; contradiction)
    | .not _, .absoluteUri _ => isFalse (by intro same; contradiction)
    | .not _, .languageTag _ => isFalse (by intro same; contradiction)
    | .not _, .choice _ => isFalse (by intro same; contradiction)
    | .not _, .text => isFalse (by intro same; contradiction)

  private def formatRulesDecidableEq :
      (left right : List FormatRule) → Decidable (left = right)
    | [], [] => isTrue rfl
    | left :: leftRest, right :: rightRest =>
      match formatRuleDecidableEq left right with
      | isFalse different => isFalse (by intro same; cases same; exact different rfl)
      | isTrue equal =>
        match formatRulesDecidableEq leftRest rightRest with
        | isTrue rest => isTrue (by cases equal; cases rest; rfl)
        | isFalse different => isFalse (by intro same; cases same; exact different rfl)
    | [], _ :: _ => isFalse (by intro same; contradiction)
    | _ :: _, [] => isFalse (by intro same; contradiction)
end

instance : DecidableEq FormatRule := formatRuleDecidableEq

structure LengthBound where
  unit : StringLengthUnit
  minimum : Option Nat := none
  maximum : Option Nat := none
  deriving BEq, Repr, DecidableEq

inductive FormatUse where
  | named (name : String)
  | inline (rule : FormatRule)
  deriving BEq, Repr

structure FormatBinding where
  name : String
  reference : ProfileRef
  rule : FormatRule
  deriving BEq, Repr



structure SlotContract where
  typeRef : TypeRef
  required : Bool
  nullable : Bool
  deriving Repr, DecidableEq

inductive SlotValue where
  | absent
  | null
  | present (value : JsonValue)
  deriving BEq, Repr

inductive PathStep where
  | field (wireName : String)
  | index (index : Nat)
  | variant (wireTag : String)
  deriving Repr, DecidableEq

abbrev ValuePath := List PathStep

structure LengthSpec where
  minimum : Option Nat := none
  maximum : Option Nat := none
  deriving BEq, Repr

structure BooleanSpec where
  constValue : Option Bool := none
  defaultValue : Option Bool := none
  deriving BEq, Repr

structure IntegerSpec where
  domain : Option String := none
  minimum : Option Int := none
  maximum : Option Int := none
  constValue : Option Int := none
  enumValues : Option (List Int) := none
  defaultValue : Option Int := none
  deriving BEq, Repr

structure DecimalBound where
  mantissa : Int
  scale : Nat
  exclusive : Bool
  deriving BEq, Repr

structure DecimalSpec where
  minimum : Option DecimalBound := none
  maximum : Option DecimalBound := none
  deriving BEq, Repr

structure StringSpec where
  format : Option FormatUse := none
  lengths : List LengthBound := []
  wrapper : Option String := none
  constValue : Option String := none
  enumValues : Option (List String) := none
  examples : List String := []
  defaultValue : Option String := none
  deriving BEq, Repr

inductive WrapperPayload where
  | bytes
  | text (format : Option String)
  deriving BEq, Repr

structure Wrapper where
  name : String
  key : String
  payload : WrapperPayload
  deriving BEq, Repr

inductive SealedLeaf where
  | string (spec : StringSpec)
  | integer (spec : IntegerSpec)
  deriving BEq, Repr

structure SealedField where
  key : String
  required : Bool
  leaf : SealedLeaf
  deriving BEq, Repr

inductive SealedExtras where
  | reject
  | any
  deriving BEq, Repr

structure SealedForm where
  tag : String
  fields : List SealedField
  extras : SealedExtras
  deriving BEq, Repr

structure TagModel where
  key : String
  format : Option String
  sealed : List SealedForm
  deriving BEq, Repr

structure SealedRefinement where
  key : String
  leaf : SealedLeaf
  deriving BEq, Repr

inductive ObjectClass where
  | sealed (form : SealedForm)
  | wrapper (wrapper : Wrapper)
  | ordinary
  deriving BEq, Repr

structure VersionedSemanticProfile where
  reference : ProfileRef
  sourceRefs : List SourceIdentity := []
  integerDomains : List IntegerDomainBinding := []
  defaultIntegerDomain : String := ""
  numbers : NumberModel := { decimals := false }
  graphemeRules : Option GraphemeRules := none
  formatBindings : List FormatBinding := []
  bytesPolicy : Option BytesPolicy := none
  wrappers : List Wrapper := []
  tag : Option TagModel := none
  deriving BEq, Repr

structure FieldSpec where
  wireName : String
  slot : SlotContract
  origin : OccurrenceRef
  deriving BEq, Repr

structure ElementContract where
  typeRef : TypeRef
  nullable : Bool := false
  deriving BEq, Repr

inductive ExtraMembers where
  | reject
  | allow (keyFormat : Option FormatUse) (value : ElementContract)
  deriving BEq, Repr

structure ProductSpec where
  fields : List FieldSpec
  extras : ExtraMembers := .reject
  deriving BEq, Repr

structure ArraySpec where
  item : ElementContract
  minLength : Option Nat := none
  maxLength : Option Nat := none
  deriving BEq, Repr

inductive ValueKind where
  | null | boolean | number | string | array | object
  deriving BEq, Repr, DecidableEq

inductive MemberTest where
  | absent
  | format (name : String)
  deriving BEq, Repr, DecidableEq

inductive BranchSelector where
  | internalTag
  | memberShape (tests : List (String × MemberTest))
  | kind (kind : ValueKind)
  | otherwise
  deriving BEq, Repr, DecidableEq

structure UnionBranch where
  target : TypeRef
  wireTag : String
  selector : BranchSelector := .internalTag
  origin : OccurrenceRef
  deriving BEq, Repr

structure UnionSpec where
  branches : List UnionBranch
  deriving BEq, Repr

inductive UnknownKind where
  | any
  | ordinaryObject
  deriving BEq, Repr, DecidableEq

inductive TypeShape where
  | boolean (spec : BooleanSpec)
  | integer (spec : IntegerSpec)
  | decimal (spec : DecimalSpec)
  | string (spec : StringSpec)
  | bytes (spec : LengthSpec)
  | product (spec : ProductSpec)
  | array (spec : ArraySpec)
  | alias (target : TypeRef) (referenceText : String)
  | taggedUnion (spec : UnionSpec)
  | sealed (tag : String) (refinements : List SealedRefinement)
  | never
  | unknown (kind : UnknownKind)
  | unit
  | rawBody (encoding : String)
  | opaque (typeName : String)
  deriving BEq, Repr

structure TypeNode where
  ref : TypeRef
  shape : TypeShape
  description : Option String
  attributes : List OccurrenceRef
  extensions : List OccurrenceRef
  deriving BEq, Repr

inductive EffectPoint where
  | httpRequestResponse
  | dataOnly
  deriving BEq, Repr

structure SemanticGraph where
  profile : VersionedSemanticProfile
  nodes : List TypeNode
  sourceRefs : List SourceRef := []
  deriving BEq, Repr

inductive ProfilePredicate where
  | pr01 | pr02 | pr03 | pr04 | pr05 | pr06 | pr07 | pr08
  | pr09 | pr10 | pr11 | pr12 | pr13 | pr14 | pr15 | pr16
  deriving BEq, Repr, DecidableEq

inductive MeaningObligation where
  | mo01 | mo02 | mo03 | mo04 | mo05 | mo06
  | mo07 | mo08 | mo09 | mo10 | mo11
  deriving BEq, Repr, DecidableEq

structure ProfileFailure where
  reference : ProfileRef
  predicate : ProfilePredicate
  location : List String
  deriving BEq, Repr

structure MeaningFailure where
  typeRef : TypeRef
  predicate : MeaningObligation
  location : List String
  deriving BEq, Repr

structure CheckedProfile where
  profile : VersionedSemanticProfile
  deriving BEq, Repr

inductive DeclarationFailure where
  | invalidProfile (reference : ProfileRef) (condition : String)
  deriving BEq, Repr

inductive SemanticReason where
  | unknownFormat (name : String)
  | missingGraphemeRules
  | missingBytesPolicy
  | unknownIntegerDomain (name : String)
  | unknownWrapper (name : String)
  | wrapperPayload (name : String)
  | unknownSealedTag (tag : String)
  | decimalNotAdmitted
  | integerBound
  | opaqueType (name : String)
  | missingTagModel
  | uninterpretedExtension (key : String)
  | unresolvedType
  | invalidProfile (condition : String)
  | membershipBound
  | certificateMismatch (condition : String)
  | projectionUnavailable (condition : String)
  deriving BEq, Repr

structure SemanticObligation where
  typeRef : TypeRef
  origin : OccurrenceRef
  valuePath : ValuePath
  profile : ProfileRef
  reason : SemanticReason
  deriving BEq, Repr

inductive ValueCondition where
  | missingRequired
  | nullNotAllowed
  | wrongValueKind (expected : String)
  | constMismatch
  | enumMismatch
  | belowMinimum
  | aboveMaximum
  | integerDomain
  | stringLength
  | arrayLength
  | bytesLength
  | format (name : String)
  | invalidBytes
  | invalidWrapper (name : String)
  | invalidTag
  | reservedForm
  | noBranchSelected
  | keyFormat (name : String)
  | uninhabited
  | duplicateField (name : String)
  | unexpectedField (name : String)
  | invalidDataModel
  | referenceCycle
  deriving BEq, Repr

structure ValueFailure where
  typeRef : TypeRef
  definitionRef : DefinitionRef
  origin : OccurrenceRef
  valuePath : ValuePath
  condition : ValueCondition
  observed : SlotValue
  referenceTrace : List TypeRef
  deriving BEq, Repr

inductive ValueDecision where
  | accepted
  | rejected (failure : ValueFailure)
  | unresolved (obligations : List SemanticObligation)
  deriving BEq, Repr

def SemanticGraph.findType (graph : SemanticGraph) (ref : TypeRef) : Option TypeNode :=
  graph.nodes.find? (fun node => decide (node.ref = ref))

def typeChildren : TypeShape → List TypeRef
  | .product spec => spec.fields.map (·.slot.typeRef)
  | .array spec => [spec.item.typeRef]
  | .alias target _ => [target]
  | .taggedUnion spec => spec.branches.map (·.target)
  | _ => []

def typeDefault : TypeShape → Option JsonValue
  | .boolean spec => spec.defaultValue.map JsonValue.bool
  | .integer spec => spec.defaultValue.map JsonValue.num
  | .string spec => spec.defaultValue.map JsonValue.str
  | _ => none

mutual
  def formatRuleDepth : FormatRule → Nat
    | .literal _ => 1
    | .sequence parts => 1 + formatRulesDepth parts
    | .optional rule => 1 + formatRuleDepth rule
    | .labels _ _ _ _ rule => 1 + formatRuleDepth rule
    | .bounded _ _ rule => 1 + formatRuleDepth rule
    | .choice rules => 1 + formatRulesDepth rules
    | .not rule => 1 + formatRuleDepth rule
    | _ => 1

  def formatRulesDepth : List FormatRule → Nat
    | [] => 0
    | rule :: rest => max (formatRuleDepth rule) (formatRulesDepth rest)
end

deriving instance DecidableEq for FormatUse
deriving instance DecidableEq for ElementContract
deriving instance DecidableEq for ExtraMembers
deriving instance DecidableEq for LengthSpec
deriving instance DecidableEq for BooleanSpec
deriving instance DecidableEq for IntegerSpec
deriving instance DecidableEq for DecimalBound
deriving instance DecidableEq for DecimalSpec
deriving instance DecidableEq for StringSpec
deriving instance DecidableEq for SealedLeaf
deriving instance DecidableEq for SealedRefinement
deriving instance DecidableEq for SlotContract
deriving instance DecidableEq for FieldSpec
deriving instance DecidableEq for ProductSpec
deriving instance DecidableEq for ArraySpec
deriving instance DecidableEq for UnionBranch
deriving instance DecidableEq for UnionSpec
deriving instance DecidableEq for TypeShape
deriving instance DecidableEq for TypeNode

end Necoherence.SemanticTypes
