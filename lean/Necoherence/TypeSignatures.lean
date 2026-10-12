-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticCodec
import Necoherence.Sha256
import Necoherence.SemanticNetwork

namespace Necoherence.TypeSignatures

open Necoherence.SemanticTypes Necoherence.ExactJson

abbrev TypeId := String
abbrev DefinitionId := String
abbrev GroupId := String


inductive Target where
  | library
  | group (id : GroupId)
  | definition (id : DefinitionId)
  | type (id : TypeId)
  | outcome (definition : DefinitionId) (outcome : String)
  deriving Repr, DecidableEq

structure Annotation where
  target : Target
  key : String
  value : JsonValue
  deriving Repr, BEq

structure ProvenanceBinding where
  target : Target
  origins : List Origin
  deriving Repr, DecidableEq

structure DefinitionGroup where
  id : GroupId
  members : List DefinitionId
  deriving Repr, DecidableEq

structure ValueProfile where
  reference : ProfileRef
  sourceRefs : List SourceIdentity := []
  integerDomains : List IntegerDomainBinding := []
  defaultIntegerDomain : String := ""
  numbers : NumberModel := { decimals := false }
  graphemeRules : Option GraphemeRules := none
  formatBindings : List FormatBinding := []
  wrappers : List Wrapper := []
  tag : Option TagModel := none
  bytesPolicy : Option BytesPolicy := none
  deriving Repr, BEq

private def ValueProfile.semantic (profile : ValueProfile) : VersionedSemanticProfile :=
  { reference := profile.reference, sourceRefs := profile.sourceRefs,
    integerDomains := profile.integerDomains, defaultIntegerDomain := profile.defaultIntegerDomain,
    numbers := profile.numbers, graphemeRules := profile.graphemeRules,
    formatBindings := profile.formatBindings, bytesPolicy := profile.bytesPolicy,
    wrappers := profile.wrappers, tag := profile.tag }

structure Slot where
  typeId : TypeId
  required : Bool
  nullable : Bool
  deriving Repr, DecidableEq

structure Field where
  wireName : String
  slot : Slot
  deriving Repr, DecidableEq


structure ElementContract where
  typeId : TypeId
  nullable : Bool := false
  deriving Repr, BEq

inductive ExtraMembers where
  | reject
  | allow (keyFormat : Option FormatUse) (value : ElementContract)
  deriving Repr, BEq

structure ProductSpec where
  fields : List Field
  extras : ExtraMembers := .reject
  deriving Repr, BEq

structure ArraySpec where
  item : ElementContract
  minimum : Option Nat := none
  maximum : Option Nat := none
  deriving Repr, BEq

structure UnionBranch where
  target : TypeId
  wireTag : String
  selector : BranchSelector
  deriving Repr, BEq

structure UnionSpec where
  branches : List UnionBranch
  deriving Repr, BEq

structure SealedRefinement where
  key : String
  leaf : SealedLeaf
  deriving Repr, BEq

inductive Shape where
  | unknown (kind : UnknownKind)
  | unit
  | boolean (spec : BooleanSpec)
  | integer (spec : IntegerSpec)
  | decimal (spec : DecimalSpec)
  | string (spec : StringSpec)
  | bytes (spec : LengthSpec)
  | product (spec : ProductSpec)
  | array (spec : ArraySpec)
  | taggedUnion (spec : UnionSpec)
  | sealed (tag : String) (refinements : List SealedRefinement)
  | never
  | alias (target : TypeId)
  | rawBody (encoding : String)
  | opaque (name : String)
  deriving Repr, BEq

structure Node where
  id : TypeId
  shape : Shape
  deriving Repr, BEq

inductive OutcomeCause where
  | valueContract (origin : Origin)
  | externalCondition (specification : Origin)
  deriving Repr, DecidableEq

structure Port where
  id : String
  contract : Slot
  deriving Repr, DecidableEq

inductive OutcomeForm where
  | success
  | declaredFailure
  deriving Repr, DecidableEq

structure ResourceProduction where
  id : String
  tokenType : TypeId
  revision : Nat
  quantity : Nat
  provenance : String
  deriving Repr, DecidableEq
structure OutcomeContract where
  id : String
  form : OutcomeForm
  cause : OutcomeCause
  valuePorts : List Port
  producedResources : List ResourceProduction := []
  deriving Repr, DecidableEq
structure OperationContract where
  effect : EffectPoint
  inputs : List Port
  outcomes : List OutcomeContract
  deriving Repr, BEq

inductive DefinitionShape where
  | value (id : TypeId)
  | symbol (wireSymbol : String)
  | operation (contract : OperationContract)
  | message (id : TypeId)
  deriving Repr, BEq

structure Definition where
  id : DefinitionId
  wireIdentity : String
  shape : DefinitionShape
  deriving Repr, BEq

structure TypeSignatureLibrary where
  schema : String := "ncoh-type-signatures@1"
  identity : String
  revision : String
  profile : ValueProfile
  sources : List SourceIdentity := []
  provenance : List ProvenanceBinding := []
  groups : List DefinitionGroup := []
  annotations : List Annotation := []
  nodes : List Node
  definitions : List Definition
  deriving Repr, BEq

inductive LibraryPredicate where
  | lb01 | lb02 | lb03 | lb04 | lb05 | lb06 | lb07 | lb08 | lb09 | lb10
  | lb11 | lb12 | lb13 | lb14 | lb15 | lb16 | lb17 | lb18 | lb19
  deriving BEq, Repr, DecidableEq

structure LibraryFailure where
  reference : String
  predicate : LibraryPredicate
  location : List String
  deriving BEq, Repr

def Shape.references : Shape → List TypeId
  | .product spec => spec.fields.map (·.slot.typeId) ++ match spec.extras with
      | .reject => []
      | .allow _ value => [value.typeId]
  | .array spec => [spec.item.typeId]
  | .alias item => [item]
  | .taggedUnion spec => spec.branches.map (·.target)
  | _ => []

def Definition.references (definition : Definition) : List TypeId :=
  match definition.shape with
  | .value id | .message id => [id]
  | .symbol _ => []
  | .operation operation => operation.inputs.map (·.contract.typeId) ++
      operation.outcomes.flatMap (fun outcome => outcome.valuePorts.map (·.contract.typeId) ++ outcome.producedResources.map (·.tokenType))

def unique (ids : List String) : Bool :=
  ids.all (fun id => !id.isEmpty) && ids.eraseDups.length == ids.length

def validDigest (digest : String) : Bool :=
  digest.length == 64 && digest.toList.all (fun character =>
    ('0' ≤ character && character ≤ '9') || ('a' ≤ character && character ≤ 'f'))

def originValid (library : TypeSignatureLibrary) (origin : Origin) : Bool :=
  library.sources.contains origin.source

def targetValid (library : TypeSignatureLibrary) : Target → Bool
  | .library => true
  | .group id => library.groups.any (fun group => group.id == id)
  | .definition id => library.definitions.any (fun definition => definition.id == id)
  | .type id => library.nodes.any (fun node => node.id == id)
  | .outcome id outcome => library.definitions.any fun definition =>
      definition.id == id && match definition.shape with
        | .operation operation => operation.outcomes.any (fun item => item.id == outcome)
        | _ => false

def outcomeValid (library : TypeSignatureLibrary) (outcome : OutcomeContract) : Bool :=
  unique (outcome.valuePorts.map (·.id)) &&
  match outcome.cause with
  | .valueContract origin => originValid library origin
  | .externalCondition specification => originValid library specification &&
      !outcome.valuePorts.isEmpty && match outcome.form with
        | .declaredFailure => true
        | .success => false

private def libraryDeclarationValid (library : TypeSignatureLibrary) : Bool :=
  library.schema == "ncoh-type-signatures@1" && !library.identity.isEmpty &&
  !library.revision.isEmpty && validDigest library.profile.reference.contentDigest &&
  library.sources.all (fun source => validDigest source.contentDigest) &&
  library.sources.eraseDups.length == library.sources.length &&
  unique (library.nodes.map (·.id)) && unique (library.definitions.map (·.id)) &&
  unique (library.groups.map (·.id)) &&
  library.nodes.all (fun node => node.shape.references.all (fun id => library.nodes.any (fun item => item.id == id))) &&
  library.definitions.all (fun definition =>
    definition.references.all (fun id => library.nodes.any (fun item => item.id == id)) &&
    match definition.shape with
    | .operation operation => unique (operation.inputs.map (·.id)) &&
        unique (operation.outcomes.map (·.id)) && !operation.outcomes.isEmpty &&
        operation.outcomes.all (outcomeValid library)
    | _ => true) &&
  library.groups.all (fun group => group.members.all (fun id => library.definitions.any (fun item => item.id == id))) &&
  library.provenance.all (fun binding => targetValid library binding.target && binding.origins.all (originValid library)) &&
  library.annotations.all (fun annotation => targetValid library annotation.target)

private def libraryFormatRule (profile : ValueProfile) : FormatUse → Option FormatRule
  | .named name => (profile.formatBindings.find? (fun binding => binding.name == name)).map (·.rule)
  | .inline rule => some rule

private def libraryBoundValid [LE α] [DecidableRel (α := α) (· ≤ ·)]
    (minimum maximum : Option α) : Bool :=
  match minimum, maximum with
  | some minimum, some maximum => decide (minimum ≤ maximum)
  | _, _ => true

private def duplicateSelection (left right : UnionBranch) : Bool :=
  match left.selector, right.selector with
  | .internalTag, .internalTag => left.wireTag == right.wireTag
  | _, _ => left.selector == right.selector

private def libraryPredicate (library : TypeSignatureLibrary) : Option LibraryPredicate :=
  if !libraryDeclarationValid library then some .lb01
  else if library.nodes.any (fun node => match node.shape with
    | .product spec => !unique (spec.fields.map (·.wireName))
    | _ => false) then some .lb02
  else if library.nodes.any (fun node => match node.shape with
    | .product spec => spec.fields.any (fun field =>
        library.profile.wrappers.any (fun wrapper => wrapper.key == field.wireName))
    | _ => false) then some .lb03
  else if library.nodes.any (fun node => match node.shape with
    | .taggedUnion spec =>
      (spec.branches.map (·.wireTag)).eraseDups.length != spec.branches.length
    | _ => false) then some .lb04
  else if library.nodes.any (fun node => match node.shape with
    | .taggedUnion spec =>
      spec.branches.zipIdx.any (fun (branch, index) =>
        branch.selector == .otherwise && index + 1 != spec.branches.length)
    | _ => false) then some .lb05
  else if library.nodes.any (fun node => match node.shape with
    | .taggedUnion spec => spec.branches.any (fun branch =>
        branch.wireTag == "" || match branch.selector with
          | .memberShape tests => tests.any (fun test => test.1 == "")
          | _ => false)
    | _ => false) then some .lb06
  else if library.nodes.any (fun node => match node.shape, library.profile.tag with
    | .taggedUnion spec, some tag => spec.branches.any (fun branch =>
      branch.selector == .internalTag && tag.format.any (fun name =>
        match library.profile.formatBindings.find? (fun binding => binding.name == name) with
        | none => true
        | some binding => !Necoherence.SemanticValidation.formatAcceptsFast binding.rule branch.wireTag))
    | _, _ => false) then some .lb07
  else if library.nodes.any (fun node => match node.shape, library.profile.tag with
    | .taggedUnion spec, some tag => spec.branches.any (fun branch =>
      branch.selector == .internalTag &&
      (tag.sealed.any (fun form => form.tag == branch.wireTag) !=
        library.nodes.any (fun target => target.id == branch.target &&
          match target.shape with | .sealed sealedTag _ => sealedTag == branch.wireTag | _ => false)))
    | _, _ => false) then some .lb08
  else if library.nodes.any (fun node => match node.shape with
    | .taggedUnion spec => spec.branches.any (fun branch => match branch.selector with
      | .memberShape tests =>
        !unique (tests.map Prod.fst) || tests.any (fun test => match test.2 with
          | .format name => !library.profile.formatBindings.any (fun binding => binding.name == name)
          | _ => false)
      | _ => false)
    | _ => false) then some .lb09
  else if library.nodes.any (fun node => match node.shape, library.profile.tag with
    | .sealed tag refinements, some model =>
      match model.sealed.find? (fun form => form.tag == tag) with
      | none => true
      | some form => !unique (refinements.map (·.key)) ||
        refinements.any (fun refinement => !form.fields.any (fun field =>
          field.key == refinement.key &&
          match field.leaf, refinement.leaf with
          | .string _, .string _ | .integer _, .integer _ => true
          | _, _ => false))
    | .sealed _ _, none => true
    | _, _ => false) then some .lb10
  else if library.nodes.any (fun node => match node.shape with
    | .taggedUnion spec => spec.branches.any (fun branch =>
      branch.selector == .internalTag && !library.nodes.any (fun target =>
        target.id == branch.target && match target.shape with
          | .product _ | .sealed _ _ => true
          | _ => false))
    | _ => false) then some .lb11
  else if library.nodes.any (fun node => match node.shape with
    | .product spec => match spec.extras with
      | .allow (some format) _ => (libraryFormatRule library.profile format).isNone
      | _ => false
    | _ => false) then some .lb12
  else if library.nodes.any (fun node => match node.shape with
    | .string spec =>
      spec.wrapper.any (fun name => !library.profile.wrappers.any (fun wrapper =>
        wrapper.name == name && match wrapper.payload with | .text _ => true | _ => false)) ||
      spec.format.any (fun use => match libraryFormatRule library.profile use with
        | none => true
        | some rule => !Necoherence.SemanticValidation.formatRuleWellFormed
            (formatRuleDepth rule + 1) rule) ||
      spec.lengths.any (fun bound => !libraryBoundValid bound.minimum bound.maximum)
    | _ => false) then some .lb13
  else if library.nodes.any (fun node => match node.shape with
    | .integer spec =>
      !libraryBoundValid spec.minimum spec.maximum ||
      spec.domain.any (fun name => !library.profile.integerDomains.any (fun binding => binding.name == name))
    | _ => false) then some .lb14
  else if library.nodes.any (fun node => match node.shape with
    | .decimal spec => match spec.minimum, spec.maximum with
      | some minimum, some maximum =>
        minimum.scale != maximum.scale || maximum.mantissa < minimum.mantissa
      | _, _ => false
    | _ => false) then some .lb15
  else if library.nodes.any (fun node => match node.shape with
    | .array spec => !libraryBoundValid spec.minimum spec.maximum
    | .bytes spec => !libraryBoundValid spec.minimum spec.maximum
    | _ => false) then some .lb16
  else if library.nodes.any (fun node => match node.shape, library.profile.tag with
    | .taggedUnion spec, some tag => spec.branches.any (fun branch =>
      branch.selector == .internalTag && library.nodes.any (fun target =>
        target.id == branch.target && match target.shape with
          | .product product =>
            match product.fields.find? (fun field => field.wireName == tag.key) with
            | none => true
            | some field =>
              match library.nodes.find? (fun fieldType => fieldType.id == field.slot.typeId) with
              | some { shape := .string stringSpec, .. } =>
                (Necoherence.SemanticValidation.stringCondition
                  library.profile.semantic stringSpec branch.wireTag).isSome
              | _ => true
          | _ => false))
    | _, _ => false) then some .lb17
  else if library.nodes.any (fun node => match node.shape with
    | .taggedUnion spec =>
      spec.branches.zipIdx.any (fun (branch, index) =>
        (spec.branches.drop (index + 1)).any (duplicateSelection branch))
    | _ => false) then some .lb18
  else if library.nodes.any (fun node => match node.shape with
    | .string spec =>
      let values := spec.constValue.toList ++ spec.enumValues.getD [] ++
        spec.defaultValue.toList
      values.any (fun value =>
        (Necoherence.SemanticValidation.stringCondition library.profile.semantic spec value).isSome)
    | .integer spec =>
      let values := spec.constValue.toList ++ spec.enumValues.getD [] ++
        spec.defaultValue.toList
      values.any (fun value =>
        (Necoherence.SemanticValidation.integerCondition library.profile.semantic spec (.num value)).isSome)
    | _ => false) then some .lb19
  else none

inductive LibraryCheckFailure where
  | profile (failure : ProfileFailure)
  | library (failure : LibraryFailure)
  deriving BEq, Repr

structure CheckedLibrary (library : TypeSignatureLibrary) : Type where
  profile : CheckedProfile
  declarationValid : libraryDeclarationValid library = true
  predicatesValid : libraryPredicate library = none

def checkLibrary (library : TypeSignatureLibrary) :
    Except LibraryCheckFailure (CheckedLibrary library) := do
  let profile ← (Necoherence.SemanticValidation.checkProfile library.profile.semantic).mapError
    LibraryCheckFailure.profile
  match predicate : libraryPredicate library with
  | some failed =>
    throw (.library { reference := library.identity, predicate := failed, location := ["library"] })
  | none =>
    if valid : libraryDeclarationValid library = true then
      pure { profile, declarationValid := valid, predicatesValid := predicate }
    else
      throw (.library { reference := library.identity, predicate := .lb01, location := ["library"] })

theorem signatureStructureSound (library : TypeSignatureLibrary) (checked : CheckedLibrary library) :
    libraryDeclarationValid library = true := checked.declarationValid

theorem signatureReferencesSound (library : TypeSignatureLibrary) (checked : CheckedLibrary library)
    (node : Node) (member : node ∈ library.nodes) (id : TypeId) (reference : id ∈ node.shape.references) :
    ∃ declared ∈ library.nodes, declared.id = id := by
  have valid := checked.declarationValid
  simp only [libraryDeclarationValid, Bool.and_eq_true, List.all_eq_true] at valid
  have resolved : library.nodes.any (fun item => item.id == id) = true := by grind
  simpa only [List.any_eq_true, beq_iff_eq] using resolved

def operationExtensionValid (base extended : OperationContract) (library : TypeSignatureLibrary) : Bool :=
  base.effect == extended.effect && base.inputs == extended.inputs &&
  unique (extended.outcomes.map (·.id)) &&
  base.outcomes.all (fun outcome => extended.outcomes.contains outcome) &&
  extended.outcomes.all (fun outcome => base.outcomes.contains outcome ||
    match outcome.cause with
    | .externalCondition _ => outcomeValid library outcome
    | .valueContract _ => false)

theorem signatureBaseOutcomesPreserved (base extended : OperationContract) (library : TypeSignatureLibrary)
    (valid : operationExtensionValid base extended library = true)
    (outcome : OutcomeContract) (member : outcome ∈ base.outcomes) : outcome ∈ extended.outcomes := by
  simp only [operationExtensionValid, Bool.and_eq_true, List.all_eq_true] at valid
  have preserved : extended.outcomes.contains outcome = true := by grind
  simpa only [List.contains_iff_mem] using preserved

def OutcomesCovered (operation : OperationContract) (handled : List String) : Prop :=
  ∀ outcome ∈ operation.outcomes, outcome.id ∈ handled

instance (operation : OperationContract) (handled : List String) : Decidable (OutcomesCovered operation handled) :=
  inferInstanceAs (Decidable (∀ outcome ∈ operation.outcomes, outcome.id ∈ handled))

def checkCoverage (operation : OperationContract) (handled : List String) :
    Except String { _proof : Unit // OutcomesCovered operation handled } :=
  if h : OutcomesCovered operation handled then .ok ⟨(), h⟩ else .error "uncovered outcome"

theorem signatureOutcomeCoverageSound (operation : OperationContract) (handled : List String)
    (checked : { _proof : Unit // OutcomesCovered operation handled })
    (outcome : OutcomeContract) (member : outcome ∈ operation.outcomes) : outcome.id ∈ handled :=
  checked.property outcome member

theorem externalOutcomeCoverageSound (operation : OperationContract) (handled : List String)
    (covered : OutcomesCovered operation handled) (outcome : OutcomeContract)
    (member : outcome ∈ operation.outcomes) (specification : Origin)
    (_cause : outcome.cause = .externalCondition specification) : outcome.id ∈ handled :=
  covered outcome member

private def syntheticSource : SourceRef :=
  { repository := "ncoh-type-signatures", revision := "1", path := "", contentDigest := "", documentId := "" }

def typeRef (id : TypeId) : TypeRef :=
  { source := syntheticSource, definitionName := id, pointer := [] }

private def occurrence : OccurrenceRef := { source := syntheticSource, pointer := [] }

private def Slot.semantic (slot : Slot) : SlotContract :=
  { typeRef := typeRef slot.typeId, required := slot.required, nullable := slot.nullable }



private def Shape.semantic : Shape → TypeShape
  | .unknown kind => .unknown kind
  | .unit => .unit
  | .boolean spec => .boolean spec
  | .integer spec => .integer spec
  | .decimal spec => .decimal spec
  | .string spec => .string spec
  | .bytes spec => .bytes spec
  | .product spec => .product {
      fields := spec.fields.map fun field =>
        { wireName := field.wireName, slot := field.slot.semantic, origin := occurrence }
      extras := match spec.extras with
        | .reject => .reject
        | .allow keyFormat value => .allow keyFormat {
            typeRef := typeRef value.typeId, nullable := value.nullable } }
  | .array spec =>
    .array {
      item := {
        typeRef := typeRef spec.item.typeId
        nullable := spec.item.nullable }
      minLength := spec.minimum
      maxLength := spec.maximum }
  | .taggedUnion spec => .taggedUnion {
      branches := spec.branches.map fun branch =>
        { target := typeRef branch.target, wireTag := branch.wireTag,
          selector := branch.selector, origin := occurrence } }
  | .sealed tag refinements => .sealed tag (refinements.map fun refinement =>
      { key := refinement.key, leaf := refinement.leaf })
  | .never => .never
  | .alias target => .alias (typeRef target) ""
  | .rawBody encoding => .rawBody encoding
  | .opaque name => .opaque name

def TypeSignatureLibrary.graph (library : TypeSignatureLibrary) : SemanticGraph :=
  let profile := library.profile.semantic
  { profile
    nodes := library.nodes.map fun node =>
      { ref := typeRef node.id, shape := node.shape.semantic
        description := none, attributes := [], extensions := [] }
    sourceRefs := [] }


inductive PrepareResult (α : Type) where
  | ready (attempt : Necoherence.AttemptInput)
  | completed (outcome : OutcomeContract) (value : α)

def completedValid (operation : OperationContract) (outcome : OutcomeContract) : Bool :=
  operation.outcomes.contains outcome &&
  match outcome.cause, outcome.form with
  | .externalCondition _, .declaredFailure => true
  | _, _ => false

structure NetworkBinding (α β : Type) where
  transport : Necoherence.SemanticNetwork.NetworkBinding Necoherence.AttemptInput β
  prepare : α → Except Necoherence.SemanticExecution.ExecutionFailure (PrepareResult β)
  outcomeId : β → String

def call (operation : OperationContract) (binding : NetworkBinding α β) (value : α) :
    IO (Except Necoherence.SemanticExecution.ExecutionFailure β) :=
  match binding.prepare value with
  | .error failure => pure (.error failure)
  | .ok (.ready attempt) => Necoherence.SemanticNetwork.call binding.transport attempt
  | .ok (.completed outcome result) =>
      if completedValid operation outcome && binding.outcomeId result == outcome.id then pure (.ok result)
      else pure (.error (.invalidPlan "undeclared external completion"))

theorem signatureMetadataOrthogonality (library : TypeSignatureLibrary)
    (annotations : List Annotation) (groups : List DefinitionGroup) :
    ({ library with annotations := annotations, groups := groups } : TypeSignatureLibrary).graph = library.graph := rfl


def annotationsAt (library : TypeSignatureLibrary) (target : Target) : List Annotation :=
  library.annotations.filter (fun annotation => annotation.target == target)

end Necoherence.TypeSignatures
