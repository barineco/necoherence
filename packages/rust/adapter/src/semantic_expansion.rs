// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use std::sync::Arc;

use crate::exact_json::JsonValue;
use crate::exact_json_view::JsonValueView;
use crate::semantic_prepared_validation::{
    ClassRef, PreparedMetadata, PreparedNode, PreparedProduct, PreparedProfile, PreparedRefinement,
    PreparedSealedField, PreparedSealedForm, PreparedShape, PreparedValidator,
};
use crate::semantic_types::*;
use crate::semantic_validation::{
    bounded, bytes_len, duplicate, format_use_accepts, meaning_obligations_in,
    sealed_leaf_condition, select_union_branch_index, string_condition_view, tag_member_failure,
    view_text, wrapper_payload_failure, wrapper_text, wrong_kind, ConditionView, FormatWorkspace,
    StringContext,
};
use num_bigint::BigUint;

#[derive(Clone, Copy)]
enum Step<'a> {
    Field(&'a str),
    Index(usize),
}

impl Step<'_> {
    fn path_step(self) -> PathStep {
        match self {
            Step::Field(name) => PathStep::Field(name.to_owned()),
            Step::Index(index) => PathStep::Index(BigUint::from(index)),
        }
    }
}

struct Frame<'p, 'a> {
    parent: Option<&'p Frame<'p, 'a>>,
    base: &'p [PathStep],
    reference: &'a TypeRef,
    step: Option<Step<'a>>,
}

impl<'a> Frame<'_, 'a> {
    fn child<'c>(&'c self, reference: &'a TypeRef, step: Option<Step<'a>>) -> Frame<'c, 'a> {
        Frame {
            parent: Some(self),
            base: &[],
            reference,
            step,
        }
    }

    fn path(&self) -> ValuePath {
        let mut steps = Vec::new();
        let mut base: &[PathStep] = &[];
        let mut current: Option<&Frame<'_, 'a>> = Some(self);
        while let Some(frame) = current {
            if let Some(step) = frame.step {
                steps.push(step.path_step());
            }
            base = frame.base;
            current = frame.parent;
        }
        let mut path = base.to_vec();
        path.extend(steps.into_iter().rev());
        path
    }

    fn trace(&self) -> Vec<TypeRef> {
        let mut types = Vec::new();
        let mut current = self.parent;
        while let Some(frame) = current {
            types.push(frame.reference.clone());
            current = frame.parent;
        }
        types
    }
}

fn revisits(parent: Option<&Frame<'_, '_>>, reference: &TypeRef, step: Option<Step<'_>>) -> bool {
    if step.is_some() {
        return false;
    }
    let mut current = parent;
    while let Some(frame) = current {
        if frame.reference == reference {
            return true;
        }
        if frame.step.is_some() {
            return false;
        }
        current = frame.parent;
    }
    false
}

#[derive(Clone, Copy)]
pub(crate) enum Observed<'a> {
    Present(JsonValueView<'a>),
    Null,
    Absent,
}

#[derive(Clone, Copy)]
enum Reason<'a> {
    Type,
    Membership,
    Opaque(&'a str),
}

enum Kind<'a> {
    Reject {
        condition: ConditionView<'a>,
        observed: Observed<'a>,
    },
    Unresolved(Reason<'a>),
}

struct Event<'a, 'p> {
    graph: &'a SemanticGraph,
    reference: &'a TypeRef,
    node: &'p Frame<'p, 'a>,
    location: &'p Frame<'p, 'a>,
    kind: Kind<'a>,
}

trait Mode<'a> {
    type Out;
    type Proof;
    type Children: Default;

    fn fail(event: Event<'a, '_>) -> Self::Out;
    fn accepted(children: Self::Children) -> Self::Proof;
    fn push(children: &mut Self::Children, proof: Self::Proof);
}

enum Stop {
    Rejected,
    Unresolved,
}

struct Status;

impl<'a> Mode<'a> for Status {
    type Out = Stop;
    type Proof = ();
    type Children = ();

    fn fail(event: Event<'a, '_>) -> Stop {
        match event.kind {
            Kind::Reject { .. } => Stop::Rejected,
            Kind::Unresolved(_) => Stop::Unresolved,
        }
    }

    fn accepted(_children: ()) {}

    fn push(_children: &mut (), _proof: ()) {}
}

enum ExpansionFailure {
    Value(ValueFailure),
    Unresolved(Vec<SemanticObligation>),
}

struct Owned;

impl<'a> Mode<'a> for Owned {
    type Out = ExpansionFailure;
    type Proof = MemberProof;
    type Children = Vec<MemberProof>;

    fn fail(event: Event<'a, '_>) -> ExpansionFailure {
        let Event {
            graph,
            reference,
            node,
            location,
            kind,
        } = event;
        match kind {
            Kind::Reject {
                condition,
                observed,
            } => ExpansionFailure::Value(failure_at(
                reference,
                location.path(),
                condition.into_owned(),
                owned_observed(observed),
                node.trace(),
            )),
            Kind::Unresolved(reason) => ExpansionFailure::Unresolved(vec![obligation_at(
                graph,
                reference,
                location.path(),
                reason,
            )]),
        }
    }

    fn accepted(children: Vec<MemberProof>) -> MemberProof {
        MemberProof::Node(children)
    }

    fn push(children: &mut Vec<MemberProof>, proof: MemberProof) {
        children.push(proof);
    }
}

enum CheckFailure<O> {
    Expansion(O),
    Certificate(&'static str),
}

impl<O> From<O> for CheckFailure<O> {
    fn from(failure: O) -> Self {
        CheckFailure::Expansion(failure)
    }
}

fn stop_of(failure: CheckFailure<Stop>) -> Stop {
    match failure {
        CheckFailure::Expansion(stop) => stop,
        CheckFailure::Certificate(_) => Stop::Unresolved,
    }
}

fn validation_failure(failure: CheckFailure<ExpansionFailure>) -> ValidationFailure {
    match failure {
        CheckFailure::Expansion(ExpansionFailure::Value(failure)) => {
            ValidationFailure::Value(failure)
        }
        CheckFailure::Expansion(ExpansionFailure::Unresolved(obligations)) => {
            ValidationFailure::Unresolved(obligations)
        }
        CheckFailure::Certificate(condition) => {
            ValidationFailure::CertificateMismatch(condition.to_owned())
        }
    }
}

fn owned_observed(observed: Observed<'_>) -> SlotValue {
    match observed {
        Observed::Present(value) => SlotValue::Present(value.to_owned()),
        Observed::Null => SlotValue::Null,
        Observed::Absent => SlotValue::Absent,
    }
}

fn failure_at(
    reference: &TypeRef,
    path: ValuePath,
    condition: ValueCondition,
    observed: SlotValue,
    trace: Vec<TypeRef>,
) -> ValueFailure {
    let observed = if condition == ValueCondition::MissingRequired {
        SlotValue::Absent
    } else {
        observed
    };
    value_failure(reference, path, condition, observed, trace)
}

fn value_failure(
    reference: &TypeRef,
    path: ValuePath,
    condition: ValueCondition,
    observed: SlotValue,
    trace: Vec<TypeRef>,
) -> ValueFailure {
    ValueFailure {
        type_ref: reference.clone(),
        definition_ref: DefinitionRef {
            source: reference.source.clone(),
            name: reference.definition_name.clone(),
        },
        origin: reference.into(),
        value_path: path,
        condition,
        observed,
        reference_trace: trace,
    }
}

fn obligation_at(
    graph: &SemanticGraph,
    reference: &TypeRef,
    path: ValuePath,
    reason: Reason<'_>,
) -> SemanticObligation {
    SemanticObligation {
        type_ref: reference.clone(),
        origin: reference.into(),
        value_path: path,
        profile: graph.profile.reference.clone(),
        reason: match reason {
            Reason::Type => SemanticReason::UnresolvedType,
            Reason::Membership => SemanticReason::MembershipBound,
            Reason::Opaque(name) => SemanticReason::OpaqueType(name.to_owned()),
        },
    }
}

fn reject<'a, 'p, M: Mode<'a>, E: From<M::Out>>(
    graph: &'a SemanticGraph,
    reference: &'a TypeRef,
    node: &'p Frame<'p, 'a>,
    location: &'p Frame<'p, 'a>,
    condition: ConditionView<'a>,
    observed: Observed<'a>,
) -> E {
    E::from(M::fail(Event {
        graph,
        reference,
        node,
        location,
        kind: Kind::Reject {
            condition,
            observed,
        },
    }))
}

fn unresolved<'a, 'p, M: Mode<'a>, E: From<M::Out>>(
    graph: &'a SemanticGraph,
    reference: &'a TypeRef,
    node: &'p Frame<'p, 'a>,
    location: &'p Frame<'p, 'a>,
    reason: Reason<'a>,
) -> E {
    E::from(M::fail(Event {
        graph,
        reference,
        node,
        location,
        kind: Kind::Unresolved(reason),
    }))
}

pub(crate) struct Cx<'g, 'w> {
    metadata: &'w PreparedMetadata<'g>,
    workspace: &'w mut FormatWorkspace,
}

struct Requirement<'a> {
    reference: &'a TypeRef,
    node: Option<usize>,
    step: Option<Step<'a>>,
    value: JsonValueView<'a>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ValueRequirement {
    pub type_ref: TypeRef,
    pub value_path: ValuePath,
    pub value: JsonValue,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expansion {
    Requirements(Vec<ValueRequirement>),
    Rejected(ValueFailure),
    Unresolved(Vec<SemanticObligation>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemberProof {
    Node(Vec<MemberProof>),
}

impl Drop for MemberProof {
    fn drop(&mut self) {
        let mut pending = Vec::new();
        let MemberProof::Node(children) = self;
        pending.append(children);
        while let Some(mut proof) = pending.pop() {
            let MemberProof::Node(children) = &mut proof;
            pending.append(children);
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MemberCertificate {
    pub profile: ProfileRef,
    pub source_refs: Vec<SourceRef>,
    pub contract: SlotContract,
    pub value: SlotValue,
    pub proof: Option<MemberProof>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ValidationFailure {
    Value(ValueFailure),
    Unresolved(Vec<SemanticObligation>),
    CertificateMismatch(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedValue {
    proof: MemberProof,
}

impl ValidatedValue {
    pub fn proof(&self) -> &MemberProof {
        &self.proof
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ValidatedSlot {
    certificate: MemberCertificate,
}

impl ValidatedSlot {
    pub fn certificate(&self) -> &MemberCertificate {
        &self.certificate
    }
}

pub enum BorrowedValueDecision<'a, 'g> {
    Accepted,
    Rejected(DiagnosticRecipe<'a, 'g>),
    Unresolved(DiagnosticRecipe<'a, 'g>),
}

pub struct DiagnosticRecipe<'a, 'g> {
    root: RecipeRoot<'a, 'g>,
}

struct RecipeRoot<'a, 'g> {
    metadata: Arc<PreparedMetadata<'g>>,
    slot: &'a SlotContract,
    value: SlotValue<JsonValueView<'a>>,
}

impl DiagnosticRecipe<'_, '_> {
    pub fn materialize(&self) -> ValueDecision {
        let metadata = &*self.root.metadata;
        let mut workspace = FormatWorkspace::empty();
        match validate_slot_view(
            metadata,
            &mut workspace,
            self.root.slot,
            self.root.value.clone(),
        ) {
            Ok(_) => ValueDecision::Accepted,
            Err(failure) => decision_of(metadata.graph(), &self.root.slot.type_ref, failure),
        }
    }
}

fn element_requirements<'g: 'a, 'a, E, F>(
    cx: &mut Cx<'g, '_>,
    contract: &'a ElementContract,
    target: Option<usize>,
    step: Step<'a>,
    value: JsonValueView<'a>,
    handler: &mut F,
) -> Result<(), E>
where
    F: FnMut(&mut Cx<'g, '_>, Requirement<'a>) -> Result<(), E>,
{
    if value.kind() == ValueKind::Null && contract.nullable {
        return Ok(());
    }
    handler(
        cx,
        Requirement {
            reference: &contract.type_ref,
            node: target,
            step: Some(step),
            value,
        },
    )
}
fn product_row<'a>(
    product: &PreparedProduct<'_>,
    value: JsonValueView<'a>,
) -> Vec<Option<JsonValueView<'a>>> {
    let mut row = vec![None; product.spec().fields.len()];
    for (key, member) in value.members().into_iter().flatten() {
        if let Some(entry) = product.slot_of(key).and_then(|slot| row.get_mut(slot)) {
            entry.get_or_insert(member);
        }
    }
    row
}
fn slot_requirements<'g: 'a, 'a, M, E, F>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    value: JsonValueView<'a>,
    product: &PreparedProduct<'g>,
    handler: &mut F,
) -> Result<(), E>
where
    M: Mode<'a>,
    E: From<M::Out>,
    F: FnMut(&mut Cx<'g, '_>, Requirement<'a>) -> Result<(), E>,
{
    let metadata: &PreparedMetadata<'g> = cx.metadata;
    let graph = metadata.graph();
    let fields: &'g [FieldSpec] = &product.spec().fields;
    let row = (!product.scans_fields()).then(|| product_row(product, value));
    let member_of = |field: &FieldSpec| match &row {
        None => value.member(&field.wire_name),
        Some(row) => product
            .slot_of(&field.wire_name)
            .and_then(|slot| row.get(slot).copied().flatten()),
    };
    for field in fields {
        let slot_reference: &'a TypeRef = &field.slot.type_ref;
        let step = Some(Step::Field(field.wire_name.as_str()));
        match member_of(field) {
            None if field.slot.required => {
                let location = node.child(slot_reference, step);
                return Err(reject::<M, _>(
                    graph,
                    slot_reference,
                    node,
                    &location,
                    ValueCondition::MissingRequired.into(),
                    Observed::Absent,
                ));
            }
            Some(member) if member.kind() == ValueKind::Null && !field.slot.nullable => {
                let location = node.child(slot_reference, step);
                return Err(reject::<M, _>(
                    graph,
                    slot_reference,
                    node,
                    &location,
                    ValueCondition::NullNotAllowed.into(),
                    Observed::Null,
                ));
            }
            _ => {}
        }
    }
    for (field, target) in fields.iter().zip(product.field_targets()) {
        if let Some(member) = member_of(field) {
            if member.kind() != ValueKind::Null {
                handler(
                    cx,
                    Requirement {
                        reference: &field.slot.type_ref,
                        node: target.resolve(),
                        step: Some(Step::Field(field.wire_name.as_str())),
                        value: member,
                    },
                )?;
            }
        }
    }
    Ok(())
}
fn is_known_product_member(
    product: &PreparedProduct<'_>,
    tag_key: Option<&str>,
    key: &str,
) -> bool {
    product.slot_of(key).is_some() || tag_key == Some(key)
}
fn extra_field_requirements<'g: 'a, 'a, E, F>(
    cx: &mut Cx<'g, '_>,
    product: &PreparedProduct<'g>,
    members: impl Iterator<Item = (&'a str, JsonValueView<'a>)>,
    handler: &mut F,
) -> Result<(), E>
where
    F: FnMut(&mut Cx<'g, '_>, Requirement<'a>) -> Result<(), E>,
{
    let spec: &'g ProductSpec = product.spec();
    let ExtraMembers::Allow {
        value: contract, ..
    } = &spec.extras
    else {
        return Ok(());
    };
    let metadata: &PreparedMetadata<'g> = cx.metadata;
    let tag_key = metadata
        .profile()
        .profile()
        .tag
        .as_ref()
        .map(|tag| tag.key.as_str());
    let target = product.extra_target().and_then(|target| target.resolve());
    for (key, member) in members {
        if is_known_product_member(product, tag_key, key) {
            continue;
        }
        element_requirements::<E, F>(cx, contract, target, Step::Field(key), member, handler)?;
    }
    Ok(())
}
fn extra_members_failure<'g: 'a, 'a>(
    profile: &PreparedProfile<'g>,
    workspace: &mut FormatWorkspace,
    product: &PreparedProduct<'g>,
    members: impl Iterator<Item = (&'a str, JsonValueView<'a>)>,
) -> Option<(&'a str, ConditionView<'a>, JsonValueView<'a>)> {
    let spec = product.spec();
    let tag_key = profile.profile().tag.as_ref().map(|tag| tag.key.as_str());
    for (key, member) in members {
        if is_known_product_member(product, tag_key, key) {
            continue;
        }
        match &spec.extras {
            ExtraMembers::Reject => {
                return Some((key, view_text(ValueCondition::UnexpectedField, key), member));
            }
            ExtraMembers::Allow { .. } => {
                if let Some(usage) = product.key_format() {
                    if !format_use_accepts(profile, workspace, usage, key) {
                        return Some((key, view_text(ValueCondition::KeyFormat, key), member));
                    }
                }
            }
        }
    }
    None
}
fn product_requirements<'g: 'a, 'a, M, E, F>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    value: JsonValueView<'a>,
    product: &PreparedProduct<'g>,
    members: impl Iterator<Item = (&'a str, JsonValueView<'a>)>,
    handler: &mut F,
) -> Result<(), E>
where
    M: Mode<'a>,
    E: From<M::Out>,
    F: FnMut(&mut Cx<'g, '_>, Requirement<'a>) -> Result<(), E>,
{
    slot_requirements::<M, E, F>(cx, node, value, product, handler)?;
    extra_field_requirements::<E, F>(cx, product, members, handler)
}
fn expand_node<'g: 'a, 'a, M, E, F>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    value: JsonValueView<'a>,
    shape: Option<&PreparedNode<'g>>,
    handler: &mut F,
) -> Result<(), E>
where
    M: Mode<'a>,
    E: From<M::Out>,
    F: FnMut(&mut Cx<'g, '_>, Requirement<'a>) -> Result<(), E>,
{
    let metadata: &PreparedMetadata<'g> = cx.metadata;
    let graph = metadata.graph();
    let reference = node.reference;
    let Some(prepared) = shape else {
        return Err(unresolved::<M, _>(
            graph,
            reference,
            node,
            node,
            Reason::Type,
        ));
    };
    let profile = metadata.profile();
    let present = Observed::Present(value);
    let fail = |condition: ConditionView<'a>| -> E {
        reject::<M, _>(graph, reference, node, node, condition, present)
    };
    match prepared.shape() {
        PreparedShape::Boolean(spec) => match value.as_bool() {
            Some(actual) if spec.const_value.is_some_and(|expected| expected != actual) => {
                Err(fail(ValueCondition::ConstMismatch.into()))
            }
            Some(_) => Ok(()),
            None => Err(fail(wrong_kind("boolean"))),
        },
        PreparedShape::Integer(numeric) => match numeric.check(value) {
            Some(condition) => Err(fail(condition)),
            None => Ok(()),
        },
        PreparedShape::Decimal(numeric) => match value.as_decimal_text() {
            Some(text) => match numeric.check(text) {
                Some(condition) => Err(fail(condition)),
                None => Ok(()),
            },
            None => Err(fail(wrong_kind("decimal"))),
        },
        PreparedShape::String(spec) => {
            let text = match spec.spec().wrapper.as_ref() {
                None => value.as_str().ok_or_else(|| wrong_kind("string")),
                Some(name) => match profile.classify(value) {
                    ClassRef::Wrapper(wrapper) if wrapper.name == *name => {
                        wrapper_text(profile, &mut *cx.workspace, wrapper, value)
                            .ok_or_else(|| wrapper_payload_failure(wrapper))
                    }
                    _ => Err(wrong_kind("string wrapper")),
                },
            };
            match text {
                Ok(text) => match string_condition_view(
                    profile,
                    &mut *cx.workspace,
                    spec.spec(),
                    spec.format(),
                    text,
                    StringContext::Typed,
                ) {
                    Some(condition) => Err(fail(condition)),
                    None => Ok(()),
                },
                Err(condition) => Err(fail(condition)),
            }
        }
        PreparedShape::Bytes(spec) => match bytes_len(profile, &mut *cx.workspace, value) {
            None => Err(fail(ValueCondition::InvalidBytes.into())),
            Some(length) if bounded(&BigUint::from(length), &spec.minimum, &spec.maximum) => Ok(()),
            Some(_) => Err(fail(ValueCondition::BytesLength.into())),
        },
        PreparedShape::Product(product) => {
            let Some(members) = value.members() else {
                return Err(fail(wrong_kind("object")));
            };
            if let Some((key, condition, observed)) =
                object_member_failure(profile, &mut *cx.workspace, value)
            {
                let location = node.child(reference, key.map(Step::Field));
                return Err(reject::<M, _>(
                    graph, reference, node, &location, condition, observed,
                ));
            }
            if !matches!(profile.classify(value), ClassRef::Ordinary) {
                return Err(fail(wrong_kind("plain data object")));
            }
            if let Some((key, condition, observed)) =
                extra_members_failure(profile, &mut *cx.workspace, product, members.clone())
            {
                let location = node.child(reference, Some(Step::Field(key)));
                return Err(reject::<M, _>(
                    graph,
                    reference,
                    node,
                    &location,
                    condition,
                    Observed::Present(observed),
                ));
            }
            product_requirements::<M, E, F>(cx, node, value, product, members, handler)
        }
        PreparedShape::Array(spec, target) => match value.as_array() {
            Some(items)
                if bounded(
                    &BigUint::from(items.len()),
                    &spec.min_length,
                    &spec.max_length,
                ) =>
            {
                for (index, item) in items.iter().enumerate() {
                    let item = JsonValueView::from_json(item);
                    element_requirements::<E, F>(
                        cx,
                        &spec.item,
                        target.resolve(),
                        Step::Index(index),
                        item,
                        handler,
                    )?;
                }
                Ok(())
            }
            Some(_) => Err(fail(ValueCondition::ArrayLength.into())),
            None => Err(fail(wrong_kind("array"))),
        },
        PreparedShape::Alias(target, target_node) => handler(
            cx,
            Requirement {
                reference: target,
                node: target_node.resolve(),
                step: None,
                value,
            },
        ),
        PreparedShape::TaggedUnion(spec, targets) => {
            if value.members().is_some() {
                if let Some((key, condition, observed)) =
                    object_member_failure(profile, &mut *cx.workspace, value)
                {
                    let location = node.child(reference, key.map(Step::Field));
                    return Err(reject::<M, _>(
                        graph, reference, node, &location, condition, observed,
                    ));
                }
            }
            match select_union_branch_index(profile, &mut *cx.workspace, spec, value)
                .and_then(|index| Some((spec.branches.get(index)?, targets.get(index)?)))
            {
                Some((branch, target)) => handler(
                    cx,
                    Requirement {
                        reference: &branch.target,
                        node: target.resolve(),
                        step: None,
                        value,
                    },
                ),
                None => Err(fail(ValueCondition::NoBranchSelected.into())),
            }
        }
        PreparedShape::Sealed { tag, refinements } => {
            let Some(members) = value.members() else {
                return Err(fail(wrong_kind("sealed object")));
            };
            if let Some((key, condition, observed)) =
                object_member_failure(profile, &mut *cx.workspace, value)
            {
                let location = node.child(reference, key.map(Step::Field));
                return Err(reject::<M, _>(
                    graph, reference, node, &location, condition, observed,
                ));
            }
            let ClassRef::Sealed { form, .. } = profile.classify(value) else {
                return Err(fail(wrong_kind("sealed object")));
            };
            if form.form().tag.as_str() != *tag {
                return Err(fail(ValueCondition::InvalidDataModel.into()));
            }
            if let Some((key, condition, observed)) =
                sealed_fields_failure(profile, &mut *cx.workspace, form, value)
            {
                let location = node.child(reference, Some(Step::Field(key)));
                return Err(reject::<M, _>(
                    graph, reference, node, &location, condition, observed,
                ));
            }
            sealed_extras::<M, E, _>(cx, node, node, form, value, members)?;
            if let Some((key, condition, observed)) =
                sealed_refinements_failure(profile, &mut *cx.workspace, refinements, value)
            {
                let location = node.child(reference, Some(Step::Field(key)));
                return Err(reject::<M, _>(
                    graph,
                    reference,
                    node,
                    &location,
                    condition,
                    Observed::Present(observed),
                ));
            }
            Ok(())
        }
        PreparedShape::Never => Err(fail(ValueCondition::InvalidDataModel.into())),
        PreparedShape::Unknown(UnknownKind::OrdinaryObject) => {
            if value.members().is_none() {
                return Err(fail(wrong_kind("ordinary object")));
            }
            if let Some((key, condition, observed)) =
                object_member_failure(profile, &mut *cx.workspace, value)
            {
                let location = node.child(reference, key.map(Step::Field));
                return Err(reject::<M, _>(
                    graph, reference, node, &location, condition, observed,
                ));
            }
            if !matches!(profile.classify(value), ClassRef::Ordinary) {
                return Err(fail(wrong_kind("ordinary object")));
            }
            data_value::<M, E>(cx, node, node, value)
        }
        PreparedShape::Unknown(UnknownKind::Any) => data_value::<M, E>(cx, node, node, value),
        PreparedShape::Unit => {
            if value.kind() == ValueKind::Null {
                Ok(())
            } else {
                Err(fail(wrong_kind("unit")))
            }
        }
        PreparedShape::RawBody => {
            if bytes_len(profile, &mut *cx.workspace, value).is_some() {
                Ok(())
            } else {
                Err(fail(ValueCondition::InvalidBytes.into()))
            }
        }
        PreparedShape::Opaque(name) => Err(unresolved::<M, _>(
            graph,
            reference,
            node,
            node,
            Reason::Opaque(name),
        )),
    }
}

fn data_value<'g: 'a, 'a, M: Mode<'a>, E: From<M::Out>>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    location: &Frame<'_, 'a>,
    value: JsonValueView<'a>,
) -> Result<(), E> {
    let metadata: &PreparedMetadata<'g> = cx.metadata;
    let graph = metadata.graph();
    let reference = node.reference;
    let present = Observed::Present(value);
    if let Some(integer) = value.as_integer() {
        return match metadata.profile().data_numeric().check_number(integer) {
            Some(condition) => Err(reject::<M, _>(
                graph, reference, node, location, condition, present,
            )),
            None => Ok(()),
        };
    }
    if let Some(text) = value.as_decimal_text() {
        return match metadata.profile().data_numeric().check_decimal(text) {
            Some(condition) => Err(reject::<M, _>(
                graph, reference, node, location, condition, present,
            )),
            None => Ok(()),
        };
    }
    if let Some(items) = value.as_array() {
        return data_items::<M, E>(cx, node, location, items);
    }
    let Some(members) = value.members() else {
        return Ok(());
    };
    let profile = metadata.profile();
    if let Some(key) = duplicate(value) {
        return Err(reject::<M, _>(
            graph,
            reference,
            node,
            location,
            view_text(ValueCondition::DuplicateField, key),
            present,
        ));
    }
    if let Some((key, condition, observed)) = tag_member_failure(profile, &mut *cx.workspace, value)
    {
        let key_location = location.child(reference, Some(Step::Field(key)));
        return Err(reject::<M, _>(
            graph,
            reference,
            node,
            &key_location,
            condition,
            Observed::Present(observed),
        ));
    }
    match profile.classify(value) {
        ClassRef::Wrapper(wrapper) => {
            if wrapper_text(profile, &mut *cx.workspace, wrapper, value).is_none() {
                Err(reject::<M, _>(
                    graph,
                    reference,
                    node,
                    location,
                    wrapper_payload_failure(wrapper),
                    present,
                ))
            } else {
                Ok(())
            }
        }
        ClassRef::Sealed { form, .. } => {
            if let Some((key, condition, observed)) =
                sealed_fields_failure(profile, &mut *cx.workspace, form, value)
            {
                let key_location = location.child(reference, Some(Step::Field(key)));
                return Err(reject::<M, _>(
                    graph,
                    reference,
                    node,
                    &key_location,
                    condition,
                    observed,
                ));
            }
            sealed_extras::<M, E, _>(cx, node, location, form, value, members)
        }
        ClassRef::Ordinary => data_members::<M, E, _>(cx, node, location, members),
    }
}
fn data_items<'g: 'a, 'a, M: Mode<'a>, E: From<M::Out>>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    location: &Frame<'_, 'a>,
    items: &'a [JsonValue],
) -> Result<(), E> {
    let reference = node.reference;
    for (index, item) in items.iter().enumerate() {
        let item_location = location.child(reference, Some(Step::Index(index)));
        data_value::<M, E>(cx, node, &item_location, JsonValueView::from_json(item))?;
    }
    Ok(())
}
fn data_members<'g: 'a, 'a, M: Mode<'a>, E: From<M::Out>, I>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    location: &Frame<'_, 'a>,
    members: I,
) -> Result<(), E>
where
    I: Iterator<Item = (&'a str, JsonValueView<'a>)>,
{
    let reference = node.reference;
    for (key, member) in members {
        let key_location = location.child(reference, Some(Step::Field(key)));
        data_value::<M, E>(cx, node, &key_location, member)?;
    }
    Ok(())
}
fn sealed_extras<'g: 'a, 'a, M: Mode<'a>, E: From<M::Out>, I>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    location: &Frame<'_, 'a>,
    form: &PreparedSealedForm<'g>,
    value: JsonValueView<'a>,
    members: I,
) -> Result<(), E>
where
    I: Iterator<Item = (&'a str, JsonValueView<'a>)>,
{
    let metadata: &PreparedMetadata<'g> = cx.metadata;
    match metadata.profile().profile().tag.as_ref() {
        Some(tag_model) => {
            data_sealed_members::<M, E>(cx, node, location, tag_model, form, members)
        }
        None => Err(reject::<M, _>(
            metadata.graph(),
            node.reference,
            node,
            location,
            ValueCondition::InvalidDataModel.into(),
            Observed::Present(value),
        )),
    }
}

fn data_sealed_members<'g: 'a, 'a, M: Mode<'a>, E: From<M::Out>>(
    cx: &mut Cx<'g, '_>,
    node: &Frame<'_, 'a>,
    location: &Frame<'_, 'a>,
    tag: &TagModel,
    form: &PreparedSealedForm<'g>,
    members: impl Iterator<Item = (&'a str, JsonValueView<'a>)>,
) -> Result<(), E> {
    let graph = cx.metadata.graph();
    let reference = node.reference;
    for (key, member) in members {
        if sealed_known_field(tag, form, key) {
            continue;
        }
        let key_location = location.child(reference, Some(Step::Field(key)));
        if form.form().extras == SealedExtras::Reject {
            return Err(reject::<M, _>(
                graph,
                reference,
                node,
                &key_location,
                view_text(ValueCondition::UnexpectedField, key),
                Observed::Present(member),
            ));
        }
        data_value::<M, E>(cx, node, &key_location, member)?;
    }
    Ok(())
}
fn sealed_known_field(tag: &TagModel, form: &PreparedSealedForm<'_>, key: &str) -> bool {
    key == tag.key || form.fields().iter().any(|field| field.key() == key)
}

fn object_member_failure<'g: 'a, 'a>(
    profile: &PreparedProfile<'g>,
    workspace: &mut FormatWorkspace,
    value: JsonValueView<'a>,
) -> Option<(Option<&'a str>, ConditionView<'a>, Observed<'a>)> {
    if let Some(key) = duplicate(value) {
        return Some((
            None,
            view_text(ValueCondition::DuplicateField, key),
            Observed::Present(value),
        ));
    }
    tag_member_failure(profile, workspace, value)
        .map(|(key, condition, observed)| (Some(key), condition, Observed::Present(observed)))
}

fn sealed_field_failure<'g: 'a, 'a>(
    profile: &PreparedProfile<'g>,
    workspace: &mut FormatWorkspace,
    field: &PreparedSealedField<'g>,
    members: JsonValueView<'a>,
) -> Option<(&'g str, ConditionView<'a>, Observed<'a>)> {
    match members.member(field.key()) {
        None if field.required() => Some((
            field.key(),
            ValueCondition::MissingRequired.into(),
            Observed::Absent,
        )),
        None => None,
        Some(member) => sealed_leaf_condition(profile, workspace, field.leaf(), member)
            .map(|condition| (field.key(), condition, Observed::Present(member))),
    }
}
pub(crate) fn sealed_fields_failure<'g: 'a, 'a>(
    profile: &PreparedProfile<'g>,
    workspace: &mut FormatWorkspace,
    form: &PreparedSealedForm<'g>,
    members: JsonValueView<'a>,
) -> Option<(&'g str, ConditionView<'a>, Observed<'a>)> {
    form.fields()
        .iter()
        .find_map(|field| sealed_field_failure(profile, &mut *workspace, field, members))
}

fn sealed_refinements_failure<'g: 'a, 'a>(
    profile: &PreparedProfile<'g>,
    workspace: &mut FormatWorkspace,
    refinements: &[PreparedRefinement<'g>],
    members: JsonValueView<'a>,
) -> Option<(&'g str, ConditionView<'a>, JsonValueView<'a>)> {
    for refinement in refinements {
        if let Some(member) = members.member(refinement.key()) {
            if let Some(condition) =
                sealed_leaf_condition(profile, workspace, refinement.leaf(), member)
            {
                return Some((refinement.key(), condition, member));
            }
        }
    }
    None
}

fn check_value<'g: 'a, 'a, M: Mode<'a>>(
    cx: &mut Cx<'g, '_>,
    fuel: usize,
    frame: &Frame<'_, 'a>,
    node: Option<usize>,
    value: JsonValueView<'a>,
    expected: Option<&MemberProof>,
) -> Result<M::Proof, CheckFailure<M::Out>> {
    crate::stack_growth::grow(|| check_value_frame::<M>(cx, fuel, frame, node, value, expected))
}

fn check_value_frame<'g: 'a, 'a, M: Mode<'a>>(
    cx: &mut Cx<'g, '_>,
    fuel: usize,
    frame: &Frame<'_, 'a>,
    node: Option<usize>,
    value: JsonValueView<'a>,
    expected: Option<&MemberProof>,
) -> Result<M::Proof, CheckFailure<M::Out>> {
    let graph = cx.metadata.graph();
    let reference = frame.reference;
    let Some(child_fuel) = fuel.checked_sub(1) else {
        return Err(unresolved::<M, _>(
            graph,
            reference,
            frame,
            frame,
            Reason::Membership,
        ));
    };
    if revisits(frame.parent, reference, frame.step) {
        return Err(reject::<M, _>(
            graph,
            reference,
            frame,
            frame,
            ValueCondition::ReferenceCycle.into(),
            Observed::Present(value),
        ));
    }
    let shape = cx.metadata.node(node);
    let mut wanted = expected.map(|MemberProof::Node(children)| children.as_slice());
    let mut children = M::Children::default();
    expand_node::<M, CheckFailure<M::Out>, _>(cx, frame, value, shape, &mut |cx, requirement| {
        let head = match wanted {
            None => None,
            Some([]) => return Err(CheckFailure::Certificate("missing membership children")),
            Some([first, rest @ ..]) => {
                wanted = Some(rest);
                Some(first)
            }
        };
        let child_frame = frame.child(requirement.reference, requirement.step);
        let proof = check_value::<M>(
            cx,
            child_fuel,
            &child_frame,
            requirement.node,
            requirement.value,
            head,
        )?;
        M::push(&mut children, proof);
        Ok(())
    })?;
    if matches!(wanted, Some([_, ..])) {
        return Err(CheckFailure::Certificate("extra membership children"));
    }
    Ok(M::accepted(children))
}

fn check_root<'g: 'a, 'a, M: Mode<'a>>(
    cx: &mut Cx<'g, '_>,
    base: &'a [PathStep],
    reference: &'a TypeRef,
    value: JsonValueView<'a>,
    expected: Option<&MemberProof>,
) -> Result<M::Proof, CheckFailure<M::Out>> {
    let fuel = (value.size() + 1) * (cx.metadata.graph().nodes.len() + 1);
    let frame = Frame {
        parent: None,
        base,
        reference,
        step: None,
    };
    let node = cx.metadata.node_index(reference);
    check_value::<M>(cx, fuel, &frame, node, value, expected)
}

fn unresolved_in(
    metadata: &PreparedMetadata<'_>,
    reference: &TypeRef,
) -> Option<Vec<SemanticObligation>> {
    if !metadata.meaning_blocked(reference) {
        return None;
    }
    let obligations = meaning_obligations_in(
        metadata.graph(),
        metadata.index(),
        std::slice::from_ref(reference),
    );
    (!obligations.is_empty()).then_some(obligations)
}

fn validate_view(
    metadata: &PreparedMetadata<'_>,
    workspace: &mut FormatWorkspace,
    reference: &TypeRef,
    value: JsonValueView<'_>,
    proof: Option<&MemberProof>,
) -> Result<MemberProof, ValidationFailure> {
    if let Some(obligations) = unresolved_in(metadata, reference) {
        return Err(ValidationFailure::Unresolved(obligations));
    }
    check_view_in(metadata, workspace, reference, value, proof)
}

fn check_view_in(
    metadata: &PreparedMetadata<'_>,
    workspace: &mut FormatWorkspace,
    reference: &TypeRef,
    value: JsonValueView<'_>,
    proof: Option<&MemberProof>,
) -> Result<MemberProof, ValidationFailure> {
    let mut cx = Cx {
        metadata,
        workspace,
    };
    check_root::<Owned>(&mut cx, &[], reference, value, proof).map_err(validation_failure)
}

pub(crate) fn accepts_view_in(
    metadata: &PreparedMetadata<'_>,
    reference: &TypeRef,
    value: JsonValueView<'_>,
) -> bool {
    if metadata.meaning_blocked(reference) {
        return false;
    }
    let mut workspace = FormatWorkspace::empty();
    let mut cx = Cx {
        metadata,
        workspace: &mut workspace,
    };
    check_root::<Status>(&mut cx, &[], reference, value, None).is_ok()
}

pub(crate) fn accepts_value_in(
    metadata: &PreparedMetadata<'_>,
    reference: &TypeRef,
    value: &JsonValue,
) -> ValueDecision {
    decide_value_in(
        metadata,
        &mut FormatWorkspace::empty(),
        reference,
        JsonValueView::from_json(value),
    )
}

fn decide_value_in(
    metadata: &PreparedMetadata<'_>,
    workspace: &mut FormatWorkspace,
    reference: &TypeRef,
    value: JsonValueView<'_>,
) -> ValueDecision {
    match validate_view(metadata, workspace, reference, value, None) {
        Ok(_) => ValueDecision::Accepted,
        Err(failure) => decision_of(metadata.graph(), reference, failure),
    }
}

fn validate_slot_view(
    metadata: &PreparedMetadata<'_>,
    workspace: &mut FormatWorkspace,
    slot: &SlotContract,
    value: SlotValue<JsonValueView<'_>>,
) -> Result<Option<MemberProof>, ValidationFailure> {
    if let Some(obligations) = unresolved_in(metadata, &slot.type_ref) {
        return Err(ValidationFailure::Unresolved(obligations));
    }
    match value {
        SlotValue::Absent => {
            if slot.required {
                Err(ValidationFailure::Value(failure_at(
                    &slot.type_ref,
                    Vec::new(),
                    ValueCondition::MissingRequired,
                    SlotValue::Absent,
                    Vec::new(),
                )))
            } else {
                Ok(None)
            }
        }
        SlotValue::Null => {
            if slot.nullable {
                Ok(None)
            } else {
                Err(ValidationFailure::Value(failure_at(
                    &slot.type_ref,
                    Vec::new(),
                    ValueCondition::NullNotAllowed,
                    SlotValue::Null,
                    Vec::new(),
                )))
            }
        }
        SlotValue::Present(actual) => {
            check_view_in(metadata, workspace, &slot.type_ref, actual, None).map(Some)
        }
    }
}

fn decision_of(
    graph: &SemanticGraph,
    reference: &TypeRef,
    failure: ValidationFailure,
) -> ValueDecision {
    match failure {
        ValidationFailure::Value(failure) => ValueDecision::Rejected(failure),
        ValidationFailure::Unresolved(obligations) => ValueDecision::Unresolved(obligations),
        ValidationFailure::CertificateMismatch(condition) => {
            ValueDecision::Unresolved(vec![SemanticObligation {
                type_ref: reference.clone(),
                origin: reference.into(),
                value_path: Vec::new(),
                profile: graph.profile.reference.clone(),
                reason: SemanticReason::CertificateMismatch(condition),
            }])
        }
    }
}

fn slot_view(value: SlotValue<&JsonValue>) -> SlotValue<JsonValueView<'_>> {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
    }
}

pub(crate) fn decide_slot_in<'g: 'a, 'a>(
    metadata: &Arc<PreparedMetadata<'g>>,
    workspace: &mut FormatWorkspace,
    slot: &'a SlotContract,
    value: SlotValue<JsonValueView<'a>>,
) -> BorrowedValueDecision<'a, 'g> {
    let root = RecipeRoot {
        metadata: Arc::clone(metadata),
        slot,
        value: value.clone(),
    };
    let outcome = if metadata.meaning_blocked(&slot.type_ref) {
        Err(Stop::Unresolved)
    } else {
        match value {
            SlotValue::Absent => {
                if slot.required {
                    Err(Stop::Rejected)
                } else {
                    Ok(())
                }
            }
            SlotValue::Null => {
                if slot.nullable {
                    Ok(())
                } else {
                    Err(Stop::Rejected)
                }
            }
            SlotValue::Present(actual) => {
                let mut cx = Cx {
                    metadata,
                    workspace,
                };
                check_root::<Status>(&mut cx, &[], &slot.type_ref, actual, None).map_err(stop_of)
            }
        }
    };
    match outcome {
        Ok(()) => BorrowedValueDecision::Accepted,
        Err(Stop::Rejected) => BorrowedValueDecision::Rejected(DiagnosticRecipe { root }),
        Err(Stop::Unresolved) => BorrowedValueDecision::Unresolved(DiagnosticRecipe { root }),
    }
}

impl<'g> PreparedValidator<'g> {
    pub fn accepts_value(&mut self, r: &TypeRef, v: &JsonValue) -> ValueDecision {
        let (metadata, workspace) = self.parts();
        decide_value_in(metadata, workspace, r, JsonValueView::from_json(v))
    }

    pub fn accepts_slot(&mut self, s: &SlotContract, v: SlotValue<&JsonValue>) -> ValueDecision {
        self.decide_slot_view(s, slot_view(v))
    }

    fn decide_slot_view(
        &mut self,
        slot: &SlotContract,
        value: SlotValue<JsonValueView<'_>>,
    ) -> ValueDecision {
        let (metadata, workspace) = self.parts();
        match validate_slot_view(metadata, workspace, slot, value) {
            Ok(_) => ValueDecision::Accepted,
            Err(failure) => decision_of(metadata.graph(), &slot.type_ref, failure),
        }
    }

    pub fn validate_value(
        &mut self,
        reference: &TypeRef,
        value: &JsonValue,
        proof: Option<&MemberProof>,
    ) -> Result<ValidatedValue, ValidationFailure> {
        let (metadata, workspace) = self.parts();
        validate_view(
            metadata,
            workspace,
            reference,
            JsonValueView::from_json(value),
            proof,
        )
        .map(|proof| ValidatedValue { proof })
    }

    pub fn validate_slot(
        &mut self,
        slot: &SlotContract,
        value: SlotValue<&JsonValue>,
    ) -> Result<ValidatedSlot, ValidationFailure> {
        let graph = self.graph();
        let (metadata, workspace) = self.parts();
        let proof = validate_slot_view(metadata, workspace, slot, slot_view(value.clone()))?;
        Ok(ValidatedSlot {
            certificate: MemberCertificate {
                profile: graph.profile.reference.clone(),
                source_refs: graph.source_refs.clone(),
                contract: slot.clone(),
                value: match value {
                    SlotValue::Absent => SlotValue::Absent,
                    SlotValue::Null => SlotValue::Null,
                    SlotValue::Present(actual) => SlotValue::Present(actual.clone()),
                },
                proof,
            },
        })
    }
}

impl<'g> PreparedValidator<'g> {
    pub fn expand_value(
        &mut self,
        reference: &TypeRef,
        path: &[PathStep],
        value: &JsonValue,
    ) -> Expansion {
        let (metadata, workspace) = self.parts();
        let mut cx = Cx {
            metadata,
            workspace,
        };
        expand_requirements(&mut cx, reference, path, value)
    }

    pub(crate) fn reject_value_fuel(
        &mut self,
        fuel: usize,
        reference: &TypeRef,
        path: &[PathStep],
        value: &JsonValue,
    ) -> Option<ValueFailure> {
        let (metadata, workspace) = self.parts();
        let mut cx = Cx {
            metadata,
            workspace,
        };
        let node = metadata.node_index(reference);
        let mut steps = path.to_vec();
        reject_view_fuel(
            &mut cx,
            fuel,
            reference,
            node,
            &mut steps,
            JsonValueView::from_json(value),
        )
    }
}

fn expand_requirements(
    cx: &mut Cx<'_, '_>,
    reference: &TypeRef,
    path: &[PathStep],
    value: &JsonValue,
) -> Expansion {
    let root = Frame {
        parent: None,
        base: path,
        reference,
        step: None,
    };
    let shape = cx.metadata.node(cx.metadata.node_index(reference));
    let mut requirements = Vec::new();
    let outcome = expand_node::<Owned, ExpansionFailure, _>(
        cx,
        &root,
        JsonValueView::from_json(value),
        shape,
        &mut |_, requirement| {
            let child_frame = root.child(requirement.reference, requirement.step);
            requirements.push(ValueRequirement {
                type_ref: requirement.reference.clone(),
                value_path: child_frame.path(),
                value: requirement.value.to_owned(),
            });
            Ok(())
        },
    );
    match outcome {
        Ok(()) => Expansion::Requirements(requirements),
        Err(ExpansionFailure::Value(failure)) => Expansion::Rejected(failure),
        Err(ExpansionFailure::Unresolved(obligations)) => Expansion::Unresolved(obligations),
    }
}

pub(crate) fn rejection_failure(
    reference: &TypeRef,
    value: SlotValue,
    condition: ValueCondition,
) -> ValueFailure {
    value_failure(reference, Vec::new(), condition, value, Vec::new())
}

fn reject_view_fuel<'g: 'a, 'a>(
    cx: &mut Cx<'g, '_>,
    fuel: usize,
    reference: &'a TypeRef,
    node: Option<usize>,
    path: &mut Vec<PathStep>,
    value: JsonValueView<'a>,
) -> Option<ValueFailure> {
    if fuel == 0 {
        return None;
    }
    let root = Frame {
        parent: None,
        base: path.as_slice(),
        reference,
        step: None,
    };
    let shape = cx.metadata.node(node);
    let mut children = Vec::new();
    let outcome = expand_node::<Owned, ExpansionFailure, _>(
        cx,
        &root,
        value,
        shape,
        &mut |_, requirement| {
            children.push(requirement);
            Ok(())
        },
    );
    match outcome {
        Err(ExpansionFailure::Unresolved(_)) => None,
        Err(ExpansionFailure::Value(failure)) => Some(failure),
        Ok(()) => children.into_iter().find_map(|child| {
            let depth = path.len();
            path.extend(child.step.map(Step::path_step));
            let failure = crate::stack_growth::grow(|| {
                reject_view_fuel(cx, fuel - 1, child.reference, child.node, path, child.value)
            });
            path.truncate(depth);
            failure
        }),
    }
}

#[cfg(test)]
mod rejection_failure_tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn rejection_failure_keeps_the_observed_value_like_lean() {
        let source = Arc::new(SourceRef {
            repository: "rejection".into(),
            revision: "1".into(),
            path: String::new(),
            content_digest: String::new(),
            document_id: String::new(),
            declared_revision: None,
        });
        let reference = TypeRef::new(source, "boolean", Vec::<String>::new());
        let failure =
            rejection_failure(&reference, SlotValue::Null, ValueCondition::MissingRequired);
        assert_eq!(failure.observed, SlotValue::Null);
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod slot_evaluation_tests {
    use super::*;
    use crate::signature_admission::*;
    use crate::type_signatures::*;
    use num_bigint::BigInt;

    fn reference() -> ProfileRef {
        ProfileRef {
            identity: "p".into(),
            revision: "1".into(),
            content_digest: "a".repeat(64),
        }
    }

    fn profile() -> ValueSemanticProfile {
        ValueSemanticProfile {
            reference: reference(),
            source_refs: vec![],
            integer_domains: vec![IntegerDomainBinding {
                name: "integer".into(),
                reference: reference(),
                range: IntegerDomain::Inclusive {
                    minimum: BigInt::from(-10),
                    maximum: BigInt::from(10),
                },
                forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
            }],
            default_integer_domain: "integer".into(),
            numbers: NumberModel { decimals: true },
            grapheme_rules: None,
            format_bindings: vec![FormatBinding {
                name: "name".into(),
                reference: reference(),
                rule: FormatRule::Not(Box::new(FormatRule::Literal("bad".into()))),
            }],
            wrappers: vec![Wrapper {
                name: "wrapped".into(),
                key: "$value".into(),
                payload: WrapperPayload::Text { format: None },
            }],
            tag: Some(TagModel {
                key: "kind".into(),
                format: None,
                sealed: vec![SealedForm {
                    tag: "sealed".into(),
                    fields: vec![SealedField {
                        key: "name".into(),
                        required: true,
                        leaf: SealedLeaf::String(StringSpec {
                            format: None,
                            lengths: vec![],
                            wrapper: None,
                            const_value: None,
                            enum_values: None,
                            examples: vec![],
                            default_value: None,
                        }),
                    }],
                    extras: SealedExtras::Reject,
                }],
            }),
            bytes_policy: None,
        }
    }

    fn library() -> TypeSignatureLibrary {
        TypeSignatureLibrary {
            schema: "ncoh-type-signatures@1".into(),
            identity: "library".into(),
            revision: "1".into(),
            profile: profile(),
            sources: vec![],
            provenance: vec![],
            groups: vec![],
            annotations: vec![],
            nodes: vec![
                TypeNodeInput {
                    id: "text".into(),
                    shape: Shape::String(StringSpec {
                        format: Some(FormatUse::Named("name".into())),
                        lengths: vec![LengthBound {
                            unit: StringLengthUnit::UnicodeScalars,
                            minimum: Some(BigUint::from(1u8)),
                            maximum: Some(BigUint::from(8u8)),
                        }],
                        wrapper: None,
                        const_value: None,
                        enum_values: None,
                        examples: vec!["ok".into()],
                        default_value: None,
                    }),
                },
                TypeNodeInput {
                    id: "never".into(),
                    shape: Shape::Never,
                },
                TypeNodeInput {
                    id: "sealed".into(),
                    shape: Shape::Sealed {
                        tag: "sealed".into(),
                        refinements: vec![],
                    },
                },
                TypeNodeInput {
                    id: "choice".into(),
                    shape: Shape::TaggedUnion(SignatureUnion {
                        branches: vec![
                            SignatureUnionBranch {
                                target: "sealed".into(),
                                wire_tag: "sealed".into(),
                                selector: BranchSelector::InternalTag,
                            },
                            SignatureUnionBranch {
                                target: "text".into(),
                                wire_tag: "text".into(),
                                selector: BranchSelector::Kind(ValueKind::String),
                            },
                        ],
                    }),
                },
            ],
            definitions: vec![DefinitionInput {
                id: "entry".into(),
                wire_identity: "entry".into(),
                shape: SignatureDefinitionShape::Value("choice".into()),
            }],
        }
    }

    #[test]
    fn missing_format_precedes_value_shape_in_all_classified_validation_entries() {
        let mut graph = check_type_signatures(&library()).unwrap();
        let node = graph
            .nodes
            .iter_mut()
            .find(|node| matches!(node.shape, TypeShape::String(_)))
            .unwrap();
        let reference = node.reference.clone();
        let TypeShape::String(spec) = &mut node.shape else {
            unreachable!()
        };
        spec.format = Some(FormatUse::Named("undeclared".into()));
        let slot = SlotContract {
            type_ref: reference.clone(),
            required: true,
            nullable: false,
        };
        for value in [JsonValue::Bool(true), JsonValue::Str("ok".into())] {
            let expected = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&reference, &value);
            assert!(
                matches!(&expected, ValueDecision::Unresolved(obligations) if obligations.len() == 1 && obligations.iter().all(|reason| reason.type_ref == reference && reason.reason == SemanticReason::UnknownFormat("undeclared".into())))
            );
            assert_eq!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_slot(&slot, SlotValue::Present(&value)),
                expected
            );
            let mut prepared = crate::semantic_prepared_validation::PreparedValidator::new(
                &graph,
                FormatWorkspace::empty(),
            );
            match prepared
                .decide_view_slot(&slot, SlotValue::Present(JsonValueView::from_json(&value)))
            {
                BorrowedValueDecision::Rejected(recipe)
                | BorrowedValueDecision::Unresolved(recipe) => {
                    assert_eq!(recipe.materialize(), expected)
                }
                BorrowedValueDecision::Accepted => assert!(matches!(value, JsonValue::Str(_))),
            }
        }
    }

    #[test]
    fn defined_references_never_compute_meaning_obligations() {
        use crate::semantic_validation::MEANING_OBLIGATION_CALLS as CALLS;
        let graph = check_type_signatures(&library()).unwrap();
        let reference = graph
            .nodes
            .iter()
            .find(|node| matches!(node.shape, TypeShape::String(_)))
            .unwrap()
            .reference
            .clone();
        let slot = SlotContract {
            type_ref: reference.clone(),
            required: true,
            nullable: false,
        };
        let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
        CALLS.with(|calls| calls.set(0));
        for value in [JsonValue::Bool(true), JsonValue::Str("ok".into())] {
            validator.accepts_value(&reference, &value);
            let _ = validator.validate_value(&reference, &value, None);
            validator.accepts_slot(&slot, SlotValue::Present(&value));
            let _ = validator.validate_slot(&slot, SlotValue::Present(&value));
        }
        let _ = validator.validate_slot(&slot, SlotValue::Absent);
        let _ = validator.validate_slot(&slot, SlotValue::Null);
        assert_eq!(CALLS.with(|calls| calls.get()), 0);
    }
}
