// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::core::Nat;
use crate::exact_json::JsonValue;
use crate::exact_json_view::JsonValueView;
use crate::network_effect::{
    observe as observe_network, observe_start, prepare, read_network_state, send_command,
    AttemptInput, CommandStep, HostObservation, NetworkFailure, NetworkOutcome, NetworkState,
    NetworkStep, PrepareStep, RawHttpResponse, ReadStateStep, SendCommand, StartObservation,
    StartedAttempt,
};
use crate::semantic_composition::{
    project_slot, AdmittedComposition, BindingExpr, CompositionEffect, CompositionInput,
    DeclaredGuard, FailureEmbeddingId, FunctionRef, FunctionSignature, GoalPortId, GuardArm,
    GuardKind, InitialSource, InputId, OutcomeId, PlanNode, PlanTree, PortId,
    PreparedCompositionInput, ProducerRef, ResourceLotRef, ReturnPlan, SiteId, ValueRef,
};
use crate::semantic_prepared_validation::PreparedMetadata;
use crate::semantic_types::{
    PathStep, SemanticGraph, SemanticObligation, SlotContract, SlotValue, TypeShape, ValueDecision,
    ValueFailure, ValueKind,
};
use crate::semantic_validation::{
    decide_slot_in, meaning_obligations, select_union_branch_view, BorrowedValueDecision,
    FormatWorkspace, PreparedValidator,
};
use crate::typed_mapping::BindingMode;
use neco_quotient_application::{apply, keyed_blocks_of, Applied, KeyedBlocks};
use num_traits::ToPrimitive;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq)]
pub enum ValidationFailure {
    Value(ValueFailure),
    Unresolved(Vec<SemanticObligation>),
    CertificateMismatch(String),
}

#[derive(Clone, Debug, PartialEq)]
pub enum ExecutionFailure {
    Value(ValidationFailure),
    MissingArgument(InputId),
    ArgumentCoverage(String),
    MissingValue(ValueRef),
    MissingProvider(FunctionRef),
    ProviderCoverage(String),
    ProviderEffect(FunctionRef),
    Provider(SiteId, String),
    InvalidOutcome(SiteId, OutcomeId),
    Resource(ResourceLotRef, String),
    InvalidPlan(String),
    Network(NetworkFailure),
    NetworkTerminal(crate::network_effect::NetworkTerminal),
}

#[derive(Clone, Debug, PartialEq)]
pub struct CallResult {
    pub outcome: OutcomeId,
    pub outputs: Vec<(PortId, SlotValue)>,
}

pub type ProviderCallback = Arc<dyn Fn(&Arguments<'_>) -> Result<CallResult, ExecutionFailure>>;
pub type DecodeCallback = Arc<dyn Fn(&RawHttpResponse) -> Result<CallResult, ExecutionFailure>>;
pub type BindingEncodeCallback<A> = Arc<dyn Fn(&A) -> Result<AttemptInput, ExecutionFailure>>;
pub type BindingDecodeCallback<B> = Arc<dyn Fn(&RawHttpResponse) -> Result<B, ExecutionFailure>>;

#[derive(Clone)]
pub struct NetworkTransport<B> {
    pub encode: BindingEncodeCallback<AttemptInput>,
    pub decode: BindingDecodeCallback<B>,
}

pub enum BindingPreparedCall<B> {
    Ready(Arc<AttemptInput>),
    Completed(OutcomeId, B),
}

pub type BindingPrepareCallback<A, B> =
    Arc<dyn Fn(&A) -> Result<BindingPreparedCall<B>, ExecutionFailure>>;

#[derive(Clone)]
pub struct NetworkBinding<A, B> {
    pub transport: NetworkTransport<B>,
    pub prepare: BindingPrepareCallback<A, B>,
}

pub fn prepare_call<A, B>(
    binding: &NetworkBinding<A, B>,
    arguments: &A,
    outcome_id: impl Fn(&B) -> OutcomeId,
    completed_valid: impl Fn(&OutcomeId) -> bool,
) -> Result<BindingPreparedCall<B>, ExecutionFailure> {
    match (binding.prepare)(arguments)? {
        BindingPreparedCall::Ready(attempt) => Ok(BindingPreparedCall::Ready(attempt)),
        BindingPreparedCall::Completed(outcome, result)
            if completed_valid(&outcome) && outcome_id(&result) == outcome =>
        {
            Ok(BindingPreparedCall::Completed(outcome, result))
        }
        BindingPreparedCall::Completed(_, _) => Err(ExecutionFailure::InvalidPlan(
            "undeclared external completion".into(),
        )),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum PreparedCall {
    Ready(Arc<AttemptInput>),
    Completed(CallResult),
}

pub type PrepareCallback = Arc<dyn Fn(&Arguments<'_>) -> Result<PreparedCall, ExecutionFailure>>;

#[derive(Clone)]
pub struct PreparedNetworkOwner {
    pub prepare: PrepareCallback,
    pub decode: DecodeCallback,
}

#[derive(Clone)]
pub enum ProviderImplementation {
    Pure(ProviderCallback),
    PreparedHttp(PreparedNetworkOwner),
}

#[derive(Clone)]
pub struct Provider {
    pub reference: FunctionRef,
    pub implementation: ProviderImplementation,
}

/// 完了した実行の結果。目標ポートは準備した計画の識別子を借用する。
#[derive(Clone, Debug, PartialEq)]
pub enum ExecutionResult<'r> {
    Success(Vec<(&'r GoalPortId, SlotValue)>),
    Failure(&'r FailureEmbeddingId, SlotValue),
}

#[derive(Clone, Debug, PartialEq)]
pub struct RunFailure {
    pub cause: ExecutionFailure,
    pub network: NetworkState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetworkInstruction {
    Send,
    Observe,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ExecutionObservation {
    Start(StartObservation),
    Host(HostObservation),
}

enum PendingNetwork {
    Start {
        node: usize,
        decode: DecodeCallback,
        command: SendCommand,
    },
    Response {
        node: usize,
        decode: DecodeCallback,
        started: StartedAttempt,
    },
}

/// 準備段で一度だけ作る、計画の表と検証の表。実行は、これを借用して値だけを持つ。
pub struct PreparedRun<'g> {
    graph: &'g SemanticGraph,
    tag_key: &'g str,
    validator: PreparedValidator<'g>,
    input: CompositionInput,
    contracts: Vec<PreparedContract>,
    slots: Vec<ProducerRef>,
    supplied: Vec<(usize, SlotValue)>,
    initial: Vec<InitialPlan>,
    lots: Vec<LotPlan>,
    final_lots: Vec<Option<usize>>,
    guards: Vec<GuardPlan<'g>>,
    nodes: Vec<Node>,
    tags: HashMap<String, u32>,
    root: usize,
}

/// 実行の作業領域。値の表と資源の表を、準備段で確保した大きさで持つ。
pub struct Workspace<'r> {
    values: Vec<Option<SlotValue>>,
    lot_quantities: Vec<Nat>,
    lot_present: Vec<bool>,
    format: FormatWorkspace,
    outputs: Vec<(&'r GoalPortId, SlotValue)>,
}

pub struct Execution<'r, 'g> {
    run: &'r PreparedRun<'g>,
    workspace: Workspace<'r>,
    providers: Vec<Provider>,
    network: NetworkState,
    cursor: usize,
    pending: Option<PendingNetwork>,
}

pub enum Progress<'r, 'g> {
    Completed(ExecutionResult<'r>, NetworkState),
    Pending(Execution<'r, 'g>, NetworkInstruction),
}

struct PreparedContract {
    contract: SlotContract,
    obligations: Vec<SemanticObligation>,
}

impl PreparedContract {
    fn new(graph: &SemanticGraph, contract: &SlotContract) -> Self {
        Self {
            contract: contract.clone(),
            obligations: meaning_obligations(graph, std::slice::from_ref(&contract.type_ref)),
        }
    }
}

struct InitialPlan {
    id: InputId,
    argument: bool,
    slot: usize,
    contract: usize,
}

struct LotPlan {
    reference: ResourceLotRef,
    revision: Nat,
    quantity: Nat,
    initially_present: bool,
}

#[derive(Clone, Copy)]
enum UnionDefect {
    Projection,
    Declaration,
}

enum GuardPlan<'g> {
    Presence,
    Validate(PreparedContract),
    Variants {
        tag_key: &'g str,
        union: Result<&'g crate::semantic_types::UnionSpec, UnionDefect>,
    },
}

impl<'g> GuardPlan<'g> {
    fn new(metadata: &PreparedMetadata<'g>, guard: &DeclaredGuard) -> Self {
        let graph = metadata.graph();
        match &guard.kind {
            GuardKind::Presence => GuardPlan::Presence,
            GuardKind::Validate(contract) => {
                GuardPlan::Validate(PreparedContract::new(graph, contract))
            }
            GuardKind::Variants => {
                let union = match project_slot(
                    metadata,
                    &SlotContract {
                        type_ref: guard.source_type.clone(),
                        required: true,
                        nullable: false,
                    },
                    &guard.path,
                    &[],
                ) {
                    Err(_) => Err(UnionDefect::Projection),
                    Ok(projection) => match resolved_shape(graph, &projection.destination) {
                        Some(TypeShape::TaggedUnion(spec)) => Ok(spec),
                        _ => Err(UnionDefect::Declaration),
                    },
                };
                GuardPlan::Variants {
                    tag_key: graph
                        .profile
                        .tag
                        .as_ref()
                        .map_or("", |tag| tag.key.as_str()),
                    union,
                }
            }
        }
    }
}

#[derive(Debug)]
enum PreparedBinding {
    Source {
        slot: Option<usize>,
        reference: ValueRef,
    },
    Product {
        fields: Vec<(String, PreparedBinding)>,
    },
}

enum Node {
    Invoke(InvokeNode),
    Guard(GuardNode),
    Return(ReturnNode),
}

struct InvokeNode {
    site: SiteId,
    function: FunctionRef,
    signature: Option<usize>,
    inputs: Vec<InputPlan>,
    resources: Vec<ResourcePlan>,
    outcomes: Vec<OutcomePlan>,
    arms: Option<KeyedBlocks<OutcomeId, usize>>,
}

struct InputPlan {
    identity: PortId,
    contract: Option<usize>,
    binding: PreparedBinding,
}

struct ResourcePlan {
    lot_reference: ResourceLotRef,
    requirement: Option<usize>,
    lot: Option<usize>,
}

struct OutcomePlan {
    values: Vec<(usize, usize)>,
    produced: Vec<usize>,
}

struct GuardNode {
    guard: Option<usize>,
    inspected: PreparedBinding,
    arms: Option<KeyedBlocks<ArmKey, usize>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum ArmKey {
    Present,
    Absent,
    Null,
    UnknownVariant,
    Accepted,
    Rejected,
    Variant(u32),
}

enum ReturnNode {
    Success(Vec<OutputPlan>),
    Failure {
        index: Option<usize>,
        contract: Option<usize>,
        value: PreparedBinding,
    },
}

struct OutputPlan {
    port: Option<usize>,
    contract: Option<usize>,
    binding: PreparedBinding,
}

fn fail_at<T>(network: NetworkState, cause: ExecutionFailure) -> Result<T, RunFailure> {
    Err(RunFailure { cause, network })
}

impl<'r, 'g> Execution<'r, 'g> {
    pub fn send_command(&self) -> Option<&SendCommand> {
        match &self.pending {
            Some(PendingNetwork::Start { command, .. }) => Some(command),
            _ => None,
        }
    }

    pub fn observed_attempt(&self) -> Option<&StartedAttempt> {
        match &self.pending {
            Some(PendingNetwork::Response { started, .. }) => Some(started),
            _ => None,
        }
    }

    pub fn graph(&self) -> &'g SemanticGraph {
        self.run.graph
    }

    pub fn network_state(&self) -> &NetworkState {
        &self.network
    }

    fn fail<T>(&mut self, cause: ExecutionFailure) -> Result<T, RunFailure> {
        Err(RunFailure {
            cause,
            network: std::mem::take(&mut self.network),
        })
    }
}

fn view(value: &SlotValue) -> SlotValue<JsonValueView<'_>> {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
    }
}

fn to_owned_slot(value: SlotValue<JsonValueView<'_>>) -> SlotValue {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(value.to_owned()),
    }
}

fn source_view<'a>(
    tag_key: &str,
    values: &'a [Option<SlotValue>],
    binding: &PreparedBinding,
) -> Result<SlotValue<JsonValueView<'a>>, ExecutionFailure> {
    let PreparedBinding::Source { slot, reference } = binding else {
        return Err(ExecutionFailure::InvalidPlan(
            "source binding mismatch".into(),
        ));
    };
    let Some(value) = slot
        .and_then(|slot| values.get(slot))
        .and_then(Option::as_ref)
    else {
        return Err(ExecutionFailure::MissingValue(reference.clone()));
    };
    project_view(tag_key, view(value), &reference.path)
}

/// 積の束縛を借用の view として見せる。欄は計画の欄の列を借り、欄の値は slot の view から都度作る。
#[derive(Clone, Copy, Debug)]
pub(crate) struct ProductView<'a> {
    fields: &'a [(String, PreparedBinding)],
    values: &'a [Option<SlotValue>],
    tag_key: &'a str,
}

impl<'a> ProductView<'a> {
    fn checked(
        fields: &'a [(String, PreparedBinding)],
        values: &'a [Option<SlotValue>],
        tag_key: &'a str,
    ) -> Result<Self, ExecutionFailure> {
        check_product_fields(fields, values, tag_key)?;
        Ok(Self {
            fields,
            values,
            tag_key,
        })
    }

    pub(crate) fn field(
        &self,
        index: usize,
    ) -> Result<Option<(&'a str, SlotValue<JsonValueView<'a>>)>, ExecutionFailure> {
        let fields: &'a [(String, PreparedBinding)] = self.fields;
        let Some((name, binding)) = fields.get(index) else {
            return Ok(None);
        };
        let value = match binding {
            PreparedBinding::Source { .. } => source_view(self.tag_key, self.values, binding)?,
            PreparedBinding::Product { fields } => {
                SlotValue::Present(JsonValueView::product(ProductView {
                    fields,
                    values: self.values,
                    tag_key: self.tag_key,
                }))
            }
        };
        Ok(Some((name.as_str(), value)))
    }
}

fn check_product_fields(
    fields: &[(String, PreparedBinding)],
    values: &[Option<SlotValue>],
    tag_key: &str,
) -> Result<(), ExecutionFailure> {
    for (_, binding) in fields {
        match binding {
            PreparedBinding::Source { .. } => {
                source_view(tag_key, values, binding)?;
            }
            PreparedBinding::Product { fields } => check_product_fields(fields, values, tag_key)?,
        }
    }
    Ok(())
}

fn input_view<'a>(
    tag_key: &'a str,
    values: &'a [Option<SlotValue>],
    binding: &'a PreparedBinding,
) -> Result<SlotValue<JsonValueView<'a>>, ExecutionFailure> {
    match binding {
        PreparedBinding::Source { .. } => source_view(tag_key, values, binding),
        PreparedBinding::Product { fields } => Ok(SlotValue::Present(JsonValueView::product(
            ProductView::checked(fields, values, tag_key)?,
        ))),
    }
}

pub struct Arguments<'a> {
    inputs: &'a [InputPlan],
    values: &'a [Option<SlotValue>],
    tag_key: &'a str,
}

impl<'a> Arguments<'a> {
    pub fn get(&self, identity: &PortId) -> Result<SlotValue<JsonValueView<'a>>, ExecutionFailure> {
        let inputs: &'a [InputPlan] = self.inputs;
        let Some(input) = inputs.iter().find(|input| &input.identity == identity) else {
            return Err(ExecutionFailure::InvalidPlan(
                "missing provider input".into(),
            ));
        };
        input_view(self.tag_key, self.values, &input.binding)
    }

    pub fn owned(&self, identity: &PortId) -> Result<SlotValue, ExecutionFailure> {
        self.get(identity).map(to_owned_slot)
    }
}

/// 借用の値の上で射影する。失敗の条件は、所有の射影と同じ形で返す。
fn project_view<'a>(
    tag_key: &str,
    value: SlotValue<JsonValueView<'a>>,
    path: &[PathStep],
) -> Result<SlotValue<JsonValueView<'a>>, ExecutionFailure> {
    let mut current = value;
    for step in path {
        current = match (current, step) {
            (SlotValue::Present(view), PathStep::Field(name))
                if view.kind() == ValueKind::Object =>
            {
                match view.member(name) {
                    None => SlotValue::Absent,
                    Some(member) if member.kind() == ValueKind::Null => SlotValue::Null,
                    Some(member) => SlotValue::Present(member),
                }
            }
            (SlotValue::Present(view), PathStep::Index(index))
                if view.kind() == ValueKind::Array =>
            {
                let Some(index) = ToPrimitive::to_usize(index) else {
                    return Err(ExecutionFailure::InvalidPlan(
                        "array projection outside value".into(),
                    ));
                };
                let Some(item) = view.as_array().and_then(|items| items.get(index)) else {
                    return Err(ExecutionFailure::InvalidPlan(
                        "array projection outside value".into(),
                    ));
                };
                if *item == JsonValue::Null {
                    SlotValue::Null
                } else {
                    SlotValue::Present(JsonValueView::from_json(item))
                }
            }
            (SlotValue::Present(view), PathStep::Variant(tag))
                if view.kind() == ValueKind::Object =>
            {
                if view.member(tag_key).and_then(JsonValueView::as_str) == Some(tag.as_str()) {
                    SlotValue::Present(view)
                } else {
                    return Err(ExecutionFailure::InvalidPlan(
                        "variant projection mismatch".into(),
                    ));
                }
            }
            _ => {
                return Err(ExecutionFailure::InvalidPlan(
                    "projection shape mismatch".into(),
                ))
            }
        };
    }
    Ok(current)
}

fn check_slot(
    metadata: &Arc<PreparedMetadata<'_>>,
    format: &mut FormatWorkspace,
    prepared: &PreparedContract,
    value: SlotValue<JsonValueView<'_>>,
) -> Result<(), ExecutionFailure> {
    if !prepared.obligations.is_empty() {
        return Err(ExecutionFailure::Value(ValidationFailure::Unresolved(
            prepared.obligations.clone(),
        )));
    }
    match decide_slot_in(metadata, format, &prepared.contract, value) {
        BorrowedValueDecision::Accepted => Ok(()),
        BorrowedValueDecision::Rejected(recipe) | BorrowedValueDecision::Unresolved(recipe) => {
            match recipe.materialize() {
                ValueDecision::Rejected(failure) => {
                    Err(ExecutionFailure::Value(ValidationFailure::Value(failure)))
                }
                ValueDecision::Unresolved(obligations) => Err(ExecutionFailure::Value(
                    ValidationFailure::Unresolved(obligations),
                )),
                ValueDecision::Accepted => Ok(()),
            }
        }
    }
}

fn plan_entry<T>(items: &[T], index: usize) -> Result<&T, ExecutionFailure> {
    items
        .get(index)
        .ok_or_else(|| ExecutionFailure::InvalidPlan("plan index mismatch".into()))
}

fn plan_entry_mut<T>(items: &mut [T], index: usize) -> Result<&mut T, ExecutionFailure> {
    items
        .get_mut(index)
        .ok_or_else(|| ExecutionFailure::InvalidPlan("plan index mismatch".into()))
}

fn evaluate_binding(
    run: &PreparedRun<'_>,
    values: &[Option<SlotValue>],
    binding: &PreparedBinding,
) -> Result<SlotValue, ExecutionFailure> {
    match binding {
        PreparedBinding::Source { .. } => {
            Ok(to_owned_slot(source_view(run.tag_key, values, binding)?))
        }
        PreparedBinding::Product { fields } => {
            let mut members = Vec::new();
            for (name, binding) in fields {
                match evaluate_binding(run, values, binding)? {
                    SlotValue::Absent => {}
                    SlotValue::Null => members.push((name.clone(), JsonValue::Null)),
                    SlotValue::Present(value) => members.push((name.clone(), value)),
                }
            }
            Ok(SlotValue::Present(JsonValue::Obj(members)))
        }
    }
}

fn initial_state(
    run: &PreparedRun<'_>,
    workspace: &mut Workspace<'_>,
    arguments: Vec<(InputId, SlotValue)>,
) -> Result<(), ExecutionFailure> {
    for (identity, _) in &arguments {
        let count = arguments
            .iter()
            .filter(|(candidate, _)| candidate == identity)
            .count();
        let declared = run.input.initial_inputs.iter().any(|initial| {
            &initial.id == identity && matches!(initial.source, InitialSource::Argument)
        });
        if count != 1 || !declared {
            return Err(ExecutionFailure::ArgumentCoverage(
                "unique declared argument identifiers required".into(),
            ));
        }
    }
    let mut arguments = arguments;
    for initial in &run.initial {
        if initial.argument {
            let Some(position) = arguments
                .iter()
                .position(|(identity, _)| identity == &initial.id)
            else {
                return Err(ExecutionFailure::MissingArgument(initial.id.clone()));
            };
            let (_, value) = arguments.swap_remove(position);
            *plan_entry_mut(&mut workspace.values, initial.slot)? = Some(value);
        }
        let Workspace { values, format, .. } = workspace;
        let Some(value) = values.get(initial.slot).and_then(Option::as_ref) else {
            return Err(ExecutionFailure::MissingArgument(initial.id.clone()));
        };
        check_slot(
            run.validator.shared_metadata(),
            format,
            plan_entry(&run.contracts, initial.contract)?,
            view(value),
        )?;
    }
    Ok(())
}

fn bind_resources(
    run: &PreparedRun<'_>,
    workspace: &mut Workspace<'_>,
    signature: &FunctionSignature,
    invocation: &InvokeNode,
) -> Result<(), ExecutionFailure> {
    for resource in &invocation.resources {
        let Some(requirement) = resource
            .requirement
            .and_then(|index| signature.resource_inputs.get(index))
        else {
            return Err(ExecutionFailure::InvalidPlan(
                "resource requirement mismatch".into(),
            ));
        };
        let Some(slot) = resource
            .lot
            .filter(|slot| workspace.lot_present.get(*slot) == Some(&true))
        else {
            return Err(ExecutionFailure::Resource(
                resource.lot_reference.clone(),
                "missing lot".into(),
            ));
        };
        if plan_entry(&run.lots, slot)?.revision != requirement.required_revision {
            return Err(ExecutionFailure::Resource(
                resource.lot_reference.clone(),
                "revision mismatch".into(),
            ));
        }
        if *plan_entry(&workspace.lot_quantities, slot)? < requirement.multiplicity {
            return Err(ExecutionFailure::Resource(
                resource.lot_reference.clone(),
                "insufficient quantity".into(),
            ));
        }
        if requirement.mode == BindingMode::Consume {
            *plan_entry_mut(&mut workspace.lot_quantities, slot)? -= &requirement.multiplicity;
        }
    }
    Ok(())
}

/// 分岐の判定の結果。借用の値に対して、値の並びを作らずに分岐を選ぶ。
enum ArmView<'a> {
    Absent,
    Null,
    Present,
    Accepted,
    Rejected,
    Variant(&'a str),
}

fn inspect_guard_view<'g>(
    metadata: &Arc<PreparedMetadata<'g>>,
    format: &mut FormatWorkspace,
    plan: &GuardPlan<'g>,
    value: SlotValue<JsonValueView<'_>>,
) -> Result<ArmView<'g>, ExecutionFailure> {
    match plan {
        GuardPlan::Presence => Ok(match value {
            SlotValue::Absent => ArmView::Absent,
            SlotValue::Null => ArmView::Null,
            SlotValue::Present(_) => ArmView::Present,
        }),
        GuardPlan::Validate(contract) => match check_slot(metadata, format, contract, value) {
            Ok(()) => Ok(ArmView::Accepted),
            Err(ExecutionFailure::Value(ValidationFailure::Value(_))) => Ok(ArmView::Rejected),
            Err(failure) => Err(failure),
        },
        GuardPlan::Variants { tag_key, union } => match value {
            SlotValue::Absent => Ok(ArmView::Absent),
            SlotValue::Null => Ok(ArmView::Null),
            SlotValue::Present(members) if members.kind() == ValueKind::Object => {
                if members
                    .member(tag_key)
                    .and_then(JsonValueView::as_str)
                    .is_none()
                {
                    return Err(ExecutionFailure::InvalidPlan(
                        "union guard discriminator".into(),
                    ));
                }
                let spec = match union {
                    Ok(spec) => *spec,
                    Err(UnionDefect::Projection) => {
                        return Err(ExecutionFailure::InvalidPlan(
                            "union guard projection".into(),
                        ))
                    }
                    Err(UnionDefect::Declaration) => {
                        return Err(ExecutionFailure::InvalidPlan(
                            "union guard declaration".into(),
                        ))
                    }
                };
                let Some(branch) =
                    select_union_branch_view(metadata.profile(), format, spec, members)
                else {
                    return Err(ExecutionFailure::InvalidPlan(
                        "union branch selection".into(),
                    ));
                };
                Ok(ArmView::Variant(branch.wire_tag.as_str()))
            }
            SlotValue::Present(_) => Err(ExecutionFailure::InvalidPlan("union guard shape".into())),
        },
    }
}

/// 検査済みの準備入力のガードの添字から、ガードの判定を一度だけ行う。準備段の表と同じ判定を使う。
pub fn inspect_guard(
    prepared: &PreparedCompositionInput<'_>,
    guard: usize,
    value: &SlotValue,
) -> Result<GuardArm, ExecutionFailure> {
    let guard = prepared
        .input()
        .invocation_domain
        .guards
        .get(guard)
        .ok_or_else(|| ExecutionFailure::InvalidPlan("guard index".into()))?;
    let validator = prepared.validator();
    let plan = GuardPlan::new(validator.metadata(), guard);
    let arm = inspect_guard_view(
        validator.shared_metadata(),
        &mut FormatWorkspace::empty(),
        &plan,
        view(value),
    )?;
    Ok(arm.into_owned())
}

fn validate_providers(
    input: &CompositionInput,
    providers: &[Provider],
) -> Result<(), ExecutionFailure> {
    if providers.len() != input.signatures.len() {
        return Err(ExecutionFailure::ProviderCoverage(
            "exact provider coverage required".into(),
        ));
    }
    for provider in providers {
        if providers
            .iter()
            .filter(|candidate| candidate.reference == provider.reference)
            .count()
            != 1
        {
            return Err(ExecutionFailure::ProviderCoverage(
                "unique provider references required".into(),
            ));
        }
    }
    for signature in &input.signatures {
        let provider = providers
            .iter()
            .find(|provider| provider.reference == signature.reference)
            .ok_or_else(|| ExecutionFailure::MissingProvider(signature.reference.clone()))?;
        if !provider_effect_matches(signature.effect, &provider.implementation) {
            return Err(ExecutionFailure::ProviderEffect(
                signature.reference.clone(),
            ));
        }
    }
    Ok(())
}

fn provider_effect_matches(
    effect: CompositionEffect,
    implementation: &ProviderImplementation,
) -> bool {
    match implementation {
        ProviderImplementation::Pure(_) => {
            matches!(
                effect,
                CompositionEffect::PureFunction | CompositionEffect::DataOnly
            )
        }
        ProviderImplementation::PreparedHttp(_) => effect == CompositionEffect::HttpRequestResponse,
    }
}

fn accept_outcome(
    execution: &mut Execution<'_, '_>,
    invocation: &InvokeNode,
    signature: &FunctionSignature,
    result: CallResult,
) -> Result<(), ExecutionFailure> {
    let run = execution.run;
    let Some(outcome_index) = signature
        .outcomes
        .iter()
        .position(|outcome| outcome.id == result.outcome)
    else {
        return Err(ExecutionFailure::InvalidOutcome(
            invocation.site.clone(),
            result.outcome,
        ));
    };
    let outcome = plan_entry(&signature.outcomes, outcome_index)?;
    let Some(plan) = invocation.outcomes.get(outcome_index) else {
        return Err(ExecutionFailure::InvalidPlan(
            "outcome branch mismatch".into(),
        ));
    };
    if result.outputs.len() != outcome.value_ports.len() {
        return Err(ExecutionFailure::InvalidPlan("output port coverage".into()));
    }
    let mut outputs = result.outputs;
    let workspace = &mut execution.workspace;
    for (port, (slot, contract)) in outcome.value_ports.iter().zip(&plan.values) {
        let Some(position) = outputs
            .iter()
            .position(|(identity, _)| identity == &port.id)
        else {
            return Err(ExecutionFailure::InvalidPlan("missing output port".into()));
        };
        let (_, value) = outputs.swap_remove(position);
        check_slot(
            run.validator.shared_metadata(),
            &mut workspace.format,
            plan_entry(&run.contracts, *contract)?,
            view(&value),
        )?;
        *plan_entry_mut(&mut workspace.values, *slot)? = Some(value);
    }
    for slot in &plan.produced {
        *plan_entry_mut(&mut workspace.lot_present, *slot)? = true;
    }
    let Some(arms) = &invocation.arms else {
        return Err(ExecutionFailure::InvalidPlan(
            "duplicate outcome branch".into(),
        ));
    };
    let Applied::Value(next) = apply(arms, &outcome.id) else {
        return Err(ExecutionFailure::InvalidPlan(
            "outcome branch mismatch".into(),
        ));
    };
    execution.cursor = *next;
    execution.pending = None;
    Ok(())
}

fn start_http<'r, 'g>(
    mut execution: Execution<'r, 'g>,
    node: usize,
    input: Arc<AttemptInput>,
    decode: DecodeCallback,
) -> Result<Progress<'r, 'g>, RunFailure> {
    let network = std::mem::take(&mut execution.network);
    let (network, prepared) = match prepare(network, input) {
        PrepareStep::Prepared(network, prepared) => (network, prepared),
        PrepareStep::Rejected(network, failure) => {
            return fail_at(network, ExecutionFailure::Network(failure))
        }
    };
    let (network, command) = match send_command(network, prepared) {
        CommandStep::CommandReady(network, command) => (network, command),
        CommandStep::Rejected(network, failure) => {
            return fail_at(network, ExecutionFailure::Network(failure))
        }
    };
    execution.network = network;
    execution.pending = Some(PendingNetwork::Start {
        node,
        decode,
        command,
    });
    Ok(Progress::Pending(execution, NetworkInstruction::Send))
}

pub fn advance<'r, 'g>(mut execution: Execution<'r, 'g>) -> Result<Progress<'r, 'g>, RunFailure> {
    let run = execution.run;
    loop {
        let Some(node) = run.nodes.get(execution.cursor) else {
            return execution.fail(ExecutionFailure::InvalidPlan("plan node mismatch".into()));
        };
        match node {
            Node::Return(ReturnNode::Success(outputs)) => {
                let workspace = &mut execution.workspace;
                for output in outputs {
                    let Some(port) = output.port else {
                        return execution
                            .fail(ExecutionFailure::InvalidPlan("goal port mismatch".into()));
                    };
                    let value = match evaluate_binding(run, &workspace.values, &output.binding) {
                        Ok(value) => value,
                        Err(cause) => return execution.fail(cause),
                    };
                    let Some(contract) = output.contract else {
                        return execution
                            .fail(ExecutionFailure::InvalidPlan("goal port mismatch".into()));
                    };
                    let Some(contract_plan) = run.contracts.get(contract) else {
                        return execution.fail(ExecutionFailure::InvalidPlan(
                            "contract index mismatch".into(),
                        ));
                    };
                    if let Err(cause) = check_slot(
                        run.validator.shared_metadata(),
                        &mut workspace.format,
                        contract_plan,
                        view(&value),
                    ) {
                        return execution.fail(cause);
                    }
                    let Some(goal_port) = run.input.goal.outputs.get(port) else {
                        return execution
                            .fail(ExecutionFailure::InvalidPlan("goal port mismatch".into()));
                    };
                    workspace.outputs.push((&goal_port.id, value));
                }
                for (index, resource) in run.input.goal.final_resources.iter().enumerate() {
                    let Some(slot) =
                        run.final_lots.get(index).copied().flatten().filter(|slot| {
                            execution.workspace.lot_present.get(*slot) == Some(&true)
                        })
                    else {
                        return execution.fail(ExecutionFailure::Resource(
                            resource.lot.clone(),
                            "missing final lot".into(),
                        ));
                    };
                    let (Some(quantity), Some(lot)) = (
                        execution.workspace.lot_quantities.get(slot),
                        run.lots.get(slot),
                    ) else {
                        return execution
                            .fail(ExecutionFailure::InvalidPlan("final lot mismatch".into()));
                    };
                    if *quantity < resource.multiplicity || lot.revision != resource.revision {
                        return execution.fail(ExecutionFailure::Resource(
                            resource.lot.clone(),
                            "final resource mismatch".into(),
                        ));
                    }
                }
                let values = std::mem::take(&mut execution.workspace.outputs);
                let network = std::mem::take(&mut execution.network);
                return Ok(Progress::Completed(
                    ExecutionResult::Success(values),
                    network,
                ));
            }
            Node::Return(ReturnNode::Failure {
                index,
                contract,
                value,
            }) => {
                let Some(index) = *index else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "failure embedding mismatch".into(),
                    ));
                };
                let value = match evaluate_binding(run, &execution.workspace.values, value) {
                    Ok(value) => value,
                    Err(cause) => return execution.fail(cause),
                };
                let Some(contract) = *contract else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "failure embedding mismatch".into(),
                    ));
                };
                let Some(contract_plan) = run.contracts.get(contract) else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "contract index mismatch".into(),
                    ));
                };
                let Some(failure) = run.input.goal.failures.get(index) else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "failure index mismatch".into(),
                    ));
                };
                if let Err(cause) = check_slot(
                    run.validator.shared_metadata(),
                    &mut execution.workspace.format,
                    contract_plan,
                    view(&value),
                ) {
                    return execution.fail(cause);
                }
                let network = std::mem::take(&mut execution.network);
                return Ok(Progress::Completed(
                    ExecutionResult::Failure(&failure.id, value),
                    network,
                ));
            }
            Node::Guard(guard) => {
                let Some(plan) = guard.guard.and_then(|index| run.guards.get(index)) else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "guard identity mismatch".into(),
                    ));
                };
                let PreparedBinding::Source { slot, reference } = &guard.inspected else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "guard identity mismatch".into(),
                    ));
                };
                let Workspace { values, format, .. } = &mut execution.workspace;
                let Some(value) = slot
                    .and_then(|slot| values.get(slot))
                    .and_then(Option::as_ref)
                else {
                    return execution.fail(ExecutionFailure::MissingValue(reference.clone()));
                };
                let inspected = match project_view(run.tag_key, view(value), &reference.path) {
                    Ok(inspected) => inspected,
                    Err(cause) => return execution.fail(cause),
                };
                let arm = match inspect_guard_view(
                    run.validator.shared_metadata(),
                    format,
                    plan,
                    inspected,
                ) {
                    Ok(arm) => arm,
                    Err(cause) => return execution.fail(cause),
                };
                let Some(arms) = &guard.arms else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "duplicate guard branch".into(),
                    ));
                };
                let key = match arm {
                    ArmView::Absent => Some(ArmKey::Absent),
                    ArmView::Null => Some(ArmKey::Null),
                    ArmView::Present => Some(ArmKey::Present),
                    ArmView::Accepted => Some(ArmKey::Accepted),
                    ArmView::Rejected => Some(ArmKey::Rejected),
                    ArmView::Variant(tag) => run.tags.get(tag).map(|index| ArmKey::Variant(*index)),
                };
                let Some(Applied::Value(next)) = key.as_ref().map(|key| apply(arms, key)) else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "guard branch mismatch".into(),
                    ));
                };
                execution.cursor = *next;
            }
            Node::Invoke(invocation) => {
                let Some(signature) = invocation
                    .signature
                    .and_then(|index| run.input.signatures.get(index))
                else {
                    return execution.fail(ExecutionFailure::InvalidPlan(
                        "function identity mismatch".into(),
                    ));
                };
                if let Err(cause) =
                    bind_resources(run, &mut execution.workspace, signature, invocation)
                {
                    return execution.fail(cause);
                }
                for input in &invocation.inputs {
                    let Some(contract) = input.contract else {
                        return execution
                            .fail(ExecutionFailure::InvalidPlan("input port mismatch".into()));
                    };
                    let Some(contract_plan) = run.contracts.get(contract) else {
                        return execution.fail(ExecutionFailure::InvalidPlan(
                            "contract index mismatch".into(),
                        ));
                    };
                    let checked = match input_view(
                        run.tag_key,
                        &execution.workspace.values,
                        &input.binding,
                    ) {
                        Ok(value) => check_slot(
                            run.validator.shared_metadata(),
                            &mut execution.workspace.format,
                            contract_plan,
                            value,
                        ),
                        Err(cause) => Err(cause),
                    };
                    if let Err(cause) = checked {
                        return execution.fail(cause);
                    }
                }
                let Some(provider) = execution
                    .providers
                    .iter()
                    .find(|provider| provider.reference == invocation.function)
                else {
                    return execution.fail(ExecutionFailure::MissingProvider(
                        invocation.function.clone(),
                    ));
                };
                let implementation = provider.implementation.clone();
                let arguments = Arguments {
                    inputs: &invocation.inputs,
                    values: &execution.workspace.values,
                    tag_key: run.tag_key,
                };
                match implementation {
                    ProviderImplementation::Pure(callback) => {
                        let result = match callback(&arguments) {
                            Ok(result) => result,
                            Err(cause) => return execution.fail(cause),
                        };
                        if let Err(cause) =
                            accept_outcome(&mut execution, invocation, signature, result)
                        {
                            return execution.fail(cause);
                        }
                    }
                    ProviderImplementation::PreparedHttp(owner) => {
                        match (owner.prepare)(&arguments) {
                            Err(cause) => return execution.fail(cause),
                            Ok(PreparedCall::Ready(input)) => {
                                let node = execution.cursor;
                                return start_http(execution, node, input, owner.decode);
                            }
                            Ok(PreparedCall::Completed(result)) => {
                                if let Err(cause) =
                                    accept_outcome(&mut execution, invocation, signature, result)
                                {
                                    return execution.fail(cause);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

pub fn start<'r, 'g>(
    run: &'r PreparedRun<'g>,
    mut workspace: Workspace<'r>,
    providers: Vec<Provider>,
    arguments: Vec<(InputId, SlotValue)>,
    network: NetworkState,
) -> Result<Progress<'r, 'g>, RunFailure> {
    let network = match read_network_state(network) {
        ReadStateStep::Read(network) => network,
        ReadStateStep::Rejected(network, failure) => {
            return fail_at(network, ExecutionFailure::Network(failure))
        }
    };
    validate_providers(&run.input, &providers).map_err(|cause| RunFailure {
        cause,
        network: network.clone(),
    })?;
    initial_state(run, &mut workspace, arguments).map_err(|cause| RunFailure {
        cause,
        network: network.clone(),
    })?;
    advance(Execution {
        run,
        workspace,
        providers,
        network,
        cursor: run.root,
        pending: None,
    })
}

pub fn resume<'r, 'g>(
    mut execution: Execution<'r, 'g>,
    observation: ExecutionObservation,
) -> Result<Progress<'r, 'g>, RunFailure> {
    let run = execution.run;
    let pending = execution.pending.take();
    match (pending, observation) {
        (
            Some(PendingNetwork::Start {
                node,
                decode,
                command,
            }),
            ExecutionObservation::Start(observation),
        ) => {
            let network = std::mem::take(&mut execution.network);
            match observe_start(network, command.prepared, observation) {
                NetworkStep::Started(network, started) => {
                    execution.network = network;
                    execution.pending = Some(PendingNetwork::Response {
                        node,
                        decode,
                        started,
                    });
                    Ok(Progress::Pending(execution, NetworkInstruction::Observe))
                }
                NetworkStep::Terminal(network, settled) => {
                    fail_at(network, ExecutionFailure::NetworkTerminal(settled.terminal))
                }
                NetworkStep::Rejected(network, failure) => {
                    fail_at(network, ExecutionFailure::Network(failure))
                }
                NetworkStep::Pending(network, _)
                | NetworkStep::Late(network, _, _)
                | NetworkStep::Duplicate(network, _, _) => fail_at(
                    network,
                    ExecutionFailure::InvalidPlan("network start result".into()),
                ),
            }
        }
        (
            Some(PendingNetwork::Response {
                node,
                decode,
                started,
            }),
            ExecutionObservation::Host(observation),
        ) => {
            let network = std::mem::take(&mut execution.network);
            match observe_network(network, observation) {
                NetworkStep::Pending(network, next_started) => {
                    execution.network = network;
                    execution.pending = Some(PendingNetwork::Response {
                        node,
                        decode,
                        started: next_started,
                    });
                    Ok(Progress::Pending(execution, NetworkInstruction::Observe))
                }
                NetworkStep::Terminal(network, settled) => match settled.terminal.outcome {
                    NetworkOutcome::Response { response, .. } => {
                        let result = match decode(&response) {
                            Ok(result) => result,
                            Err(cause) => return fail_at(network, cause),
                        };
                        execution.network = network;
                        execution.pending = None;
                        let Some(Node::Invoke(invocation)) = run.nodes.get(node) else {
                            return execution.fail(ExecutionFailure::InvalidPlan(
                                "function identity mismatch".into(),
                            ));
                        };
                        let Some(signature) = invocation
                            .signature
                            .and_then(|index| run.input.signatures.get(index))
                        else {
                            return execution.fail(ExecutionFailure::InvalidPlan(
                                "function identity mismatch".into(),
                            ));
                        };
                        match accept_outcome(&mut execution, invocation, signature, result) {
                            Ok(()) => advance(execution),
                            Err(cause) => execution.fail(cause),
                        }
                    }
                    _ => fail_at(network, ExecutionFailure::NetworkTerminal(settled.terminal)),
                },
                NetworkStep::Duplicate(network, _, _) | NetworkStep::Late(network, _, _) => {
                    execution.network = network;
                    execution.pending = Some(PendingNetwork::Response {
                        node,
                        decode,
                        started,
                    });
                    Ok(Progress::Pending(execution, NetworkInstruction::Observe))
                }
                NetworkStep::Rejected(network, failure) => {
                    fail_at(network, ExecutionFailure::Network(failure))
                }
                NetworkStep::Started(network, _) => fail_at(
                    network,
                    ExecutionFailure::InvalidPlan("completion delivered a start result".into()),
                ),
            }
        }
        (None, _) => execution.fail(ExecutionFailure::InvalidPlan(
            "only pending executions may resume".into(),
        )),
        _ => execution.fail(ExecutionFailure::InvalidPlan(
            "network observation kind mismatch".into(),
        )),
    }
}

impl ArmView<'_> {
    fn into_owned(self) -> GuardArm {
        match self {
            ArmView::Absent => GuardArm::Absent,
            ArmView::Null => GuardArm::Null,
            ArmView::Present => GuardArm::Present,
            ArmView::Accepted => GuardArm::Accepted,
            ArmView::Rejected => GuardArm::Rejected,
            ArmView::Variant(tag) => GuardArm::Variant(tag.to_owned()),
        }
    }
}

impl<'g> PreparedRun<'g> {
    /// 検証済みの合成から、計画の表と検証の表を一度だけ作る。
    pub fn new(admitted: AdmittedComposition<'_, 'g>) -> Self {
        let prepared: &PreparedCompositionInput<'g> = admitted.prepared();
        let graph = prepared.graph();
        let input = prepared.input().clone();
        let mut builder = Builder {
            graph,
            validator: prepared.validator(),
            contracts: Vec::new(),
            slots: Vec::new(),
            lots: Vec::new(),
            nodes: Vec::new(),
            tags: HashMap::new(),
        };
        let mut initial = Vec::new();
        let mut supplied = Vec::new();
        for initial_input in &input.initial_inputs {
            let slot = builder.slots.len();
            builder
                .slots
                .push(ProducerRef::Initial(initial_input.id.clone()));
            let contract = builder.register(&initial_input.contract);
            let argument = matches!(initial_input.source, InitialSource::Argument);
            if let InitialSource::SuppliedValue(value) = &initial_input.source {
                supplied.push((slot, value.clone()));
            }
            initial.push(InitialPlan {
                id: initial_input.id.clone(),
                argument,
                slot,
                contract,
            });
        }
        for lot in &input.initial_resources {
            builder.lots.push(LotPlan {
                reference: ResourceLotRef::Initial(lot.id.clone()),
                revision: lot.revision.clone(),
                quantity: lot.quantity.clone(),
                initially_present: true,
            });
        }
        let root = builder.flatten(&admitted.plan().root, &input);
        let guards = input
            .invocation_domain
            .guards
            .iter()
            .map(|guard| builder.guard(guard))
            .collect();
        let final_lots = input
            .goal
            .final_resources
            .iter()
            .map(|resource| builder.lot_slot(&resource.lot))
            .collect();
        let tag_key = graph
            .profile
            .tag
            .as_ref()
            .map_or("", |tag| tag.key.as_str());
        Self {
            graph,
            tag_key,
            validator: prepared.validator(),
            input,
            contracts: builder.contracts,
            slots: builder.slots,
            supplied,
            initial,
            lots: builder.lots,
            final_lots,
            guards,
            nodes: builder.nodes,
            tags: builder.tags,
            root,
        }
    }

    /// 実行の作業領域を作る。準備段で確保し、`start` へ渡す。
    pub fn workspace(&self) -> Workspace<'_> {
        let mut values: Vec<Option<SlotValue>> = vec![None; self.slots.len()];
        for (slot, value) in &self.supplied {
            if let Some(entry) = values.get_mut(*slot) {
                *entry = Some(value.clone());
            }
        }
        Workspace {
            values,
            lot_quantities: self.lots.iter().map(|lot| lot.quantity.clone()).collect(),
            lot_present: self.lots.iter().map(|lot| lot.initially_present).collect(),
            format: FormatWorkspace::empty(),
            outputs: Vec::with_capacity(self.input.goal.outputs.len()),
        }
    }

    pub fn graph(&self) -> &'g SemanticGraph {
        self.graph
    }

    pub fn input(&self) -> &CompositionInput {
        &self.input
    }
}

struct Builder<'g> {
    graph: &'g SemanticGraph,
    validator: PreparedValidator<'g>,
    contracts: Vec<PreparedContract>,
    slots: Vec<ProducerRef>,
    lots: Vec<LotPlan>,
    nodes: Vec<Node>,
    tags: HashMap<String, u32>,
}

impl<'g> Builder<'g> {
    fn register(&mut self, contract: &SlotContract) -> usize {
        if let Some(index) = self
            .contracts
            .iter()
            .position(|candidate| candidate.contract == *contract)
        {
            return index;
        }
        self.contracts
            .push(PreparedContract::new(self.graph, contract));
        self.contracts.len() - 1
    }

    fn lot_slot(&self, reference: &ResourceLotRef) -> Option<usize> {
        self.lots.iter().position(|lot| &lot.reference == reference)
    }

    fn source(&self, value: &ValueRef) -> PreparedBinding {
        PreparedBinding::Source {
            slot: self
                .slots
                .iter()
                .position(|producer| producer == &value.producer),
            reference: value.clone(),
        }
    }

    fn binding(&self, expression: &BindingExpr) -> PreparedBinding {
        match expression {
            BindingExpr::Source { value, .. } => self.source(value),
            BindingExpr::Product { fields, .. } => PreparedBinding::Product {
                fields: fields
                    .iter()
                    .map(|(name, binding)| (name.clone(), self.binding(binding)))
                    .collect(),
            },
        }
    }

    fn guard(&mut self, guard: &DeclaredGuard) -> GuardPlan<'g> {
        GuardPlan::new(self.validator.metadata(), guard)
    }

    fn arm_key(&mut self, arm: &GuardArm) -> ArmKey {
        match arm {
            GuardArm::Present => ArmKey::Present,
            GuardArm::Absent => ArmKey::Absent,
            GuardArm::Null => ArmKey::Null,
            GuardArm::UnknownVariant => ArmKey::UnknownVariant,
            GuardArm::Accepted => ArmKey::Accepted,
            GuardArm::Rejected => ArmKey::Rejected,
            GuardArm::Variant(tag) => {
                let next = u32::try_from(self.tags.len()).unwrap_or(u32::MAX);
                ArmKey::Variant(*self.tags.entry(tag.clone()).or_insert(next))
            }
        }
    }

    fn flatten(&mut self, tree: &PlanTree, input: &CompositionInput) -> usize {
        let node = match &tree.node {
            PlanNode::Invoke {
                invocation, arms, ..
            } => {
                let signature_index = input
                    .signatures
                    .iter()
                    .position(|signature| signature.reference == invocation.function);
                let mut outcomes = Vec::new();
                let signature = signature_index.and_then(|index| input.signatures.get(index));
                if let Some(signature) = signature {
                    for outcome in &signature.outcomes {
                        let mut values = Vec::new();
                        for port in &outcome.value_ports {
                            let slot = self.slots.len();
                            self.slots.push(ProducerRef::InvocationOutcome {
                                site: invocation.site.clone(),
                                outcome: outcome.id.clone(),
                                port: port.id.clone(),
                            });
                            values.push((slot, self.register(&port.contract)));
                        }
                        let mut produced = Vec::new();
                        for production in &outcome.produced_resources {
                            produced.push(self.lots.len());
                            self.lots.push(LotPlan {
                                reference: ResourceLotRef::Produced {
                                    site: invocation.site.clone(),
                                    outcome: outcome.id.clone(),
                                    production: production.id.clone(),
                                },
                                revision: production.revision.clone(),
                                quantity: production.quantity.clone(),
                                initially_present: false,
                            });
                        }
                        outcomes.push(OutcomePlan { values, produced });
                    }
                }
                let mut inputs = Vec::new();
                for (identity, binding) in &invocation.bindings {
                    let contract = signature.and_then(|signature| {
                        signature
                            .inputs
                            .iter()
                            .find(|port| port.id == *identity)
                            .map(|port| port.contract.clone())
                    });
                    let contract = contract.map(|contract| self.register(&contract));
                    inputs.push(InputPlan {
                        identity: identity.clone(),
                        contract,
                        binding: self.binding(binding),
                    });
                }
                let resources = invocation
                    .resources
                    .iter()
                    .map(|binding| ResourcePlan {
                        lot_reference: binding.lot.clone(),
                        requirement: signature.and_then(|signature| {
                            signature
                                .resource_inputs
                                .iter()
                                .position(|requirement| requirement.id == binding.requirement)
                        }),
                        lot: self.lot_slot(&binding.lot),
                    })
                    .collect();
                let mut flat_arms = Vec::new();
                for (outcome, arm) in arms {
                    let next = self.flatten(arm, input);
                    flat_arms.push((outcome.clone(), next));
                }
                Node::Invoke(InvokeNode {
                    site: invocation.site.clone(),
                    function: invocation.function.clone(),
                    signature: signature_index,
                    inputs,
                    resources,
                    outcomes,
                    arms: keyed_blocks_of(flat_arms).ok(),
                })
            }
            PlanNode::Guard {
                guard,
                inspected,
                arms,
            } => {
                let inspected = self.source(inspected);
                let index = input
                    .invocation_domain
                    .guards
                    .iter()
                    .position(|declaration| declaration.id == *guard);
                let mut flat_arms = Vec::new();
                for (arm, tree) in arms {
                    let next = self.flatten(tree, input);
                    flat_arms.push((self.arm_key(arm), next));
                }
                Node::Guard(GuardNode {
                    guard: index,
                    inspected,
                    arms: keyed_blocks_of(flat_arms).ok(),
                })
            }
            PlanNode::Return(ReturnPlan::Success(outputs)) => {
                let outputs = outputs
                    .iter()
                    .map(|(identity, binding)| {
                        let port = input
                            .goal
                            .outputs
                            .iter()
                            .position(|port| port.id == *identity);
                        let contract = port
                            .and_then(|index| input.goal.outputs.get(index))
                            .map(|output| self.register(&output.contract));
                        OutputPlan {
                            port,
                            contract,
                            binding: self.binding(binding),
                        }
                    })
                    .collect();
                Node::Return(ReturnNode::Success(outputs))
            }
            PlanNode::Return(ReturnPlan::Failure { embedding, value }) => {
                let index = input
                    .goal
                    .failures
                    .iter()
                    .position(|failure| failure.id == *embedding);
                let contract = index
                    .and_then(|index| input.goal.failures.get(index))
                    .map(|failure| self.register(&failure.contract));
                Node::Return(ReturnNode::Failure {
                    index,
                    contract,
                    value: self.binding(value),
                })
            }
        };
        self.nodes.push(node);
        self.nodes.len() - 1
    }
}

fn resolved_shape<'a>(graph: &'a SemanticGraph, contract: &SlotContract) -> Option<&'a TypeShape> {
    let mut reference = &contract.type_ref;
    for _ in 0..=graph.nodes.len() {
        let node = graph.find_type(reference)?;
        match &node.shape {
            TypeShape::Alias { target, .. } => reference = target,
            shape => return Some(shape),
        }
    }
    None
}

#[cfg(test)]
mod product_view_tests {
    use super::*;
    use crate::semantic_composition::{InputId, ProducerRef, ValueRef};

    #[test]
    fn product_field_with_a_missing_source_is_a_failure() {
        let reference = ValueRef {
            producer: ProducerRef::Initial(InputId("input".into())),
            path: vec![],
        };
        let fields = [(
            "name".to_owned(),
            PreparedBinding::Source {
                slot: Some(0),
                reference: reference.clone(),
            },
        )];
        let values: [Option<SlotValue>; 1] = [None];
        let view = ProductView {
            fields: &fields,
            values: &values,
            tag_key: "tag",
        };
        assert!(matches!(
            view.field(0),
            Err(ExecutionFailure::MissingValue(found)) if found == reference
        ));
    }
}
