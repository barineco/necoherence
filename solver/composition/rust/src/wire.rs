// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::closure::*;
use super::document::*;
use super::enumeration::*;
use super::lowering::*;
use super::search_state::*;
use super::verification::*;
use necoherence::exact_json::JsonValue as ExchangeJson;
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::{
    field, field_path, keys, tag, Decoded, GenerationFailure, Wire, WireDecode, WireEncode,
};
use necoherence::semantic_types::*;
use necoherence::typed_mapping as resource;
use necoherence::{wire_enum, wire_enum_encode, wire_record, wire_record_encode};
use num_bigint::BigUint;
use serde::ser::SerializeStruct;
use serde::{Serialize, Serializer};

wire_record!(AvailableValue { producer: ProducerRef, contract: SlotContract, resource: Option<ResourceLotRef> });
wire_record!(BranchFact { guard: GuardId, inspected: ValueRef, arm: GuardArm, refinement: Option<SlotContract>, assumptions: Vec<ProjectionAssumption>, exact: Option<SlotValue> });
wire_record!(SearchState { available: Vec<AvailableValue>, used_sites: Vec<SiteId>, used_guards: Vec<GuardId>, facts: Vec<BranchFact>, trace: Vec<TraceStep>, pending_failure: Option<FailureOrigin> });
wire_enum_encode!(ChoiceSkeleton; units []; tuples []; records [Invoke { invocation: InvocationPlan, outcomes: Vec<OutcomeId>, empty_outcomes: Vec<OutcomeId> }, Guard { guard: GuardId, inspected: ValueRef, arms: Vec<GuardArm> }]);
wire_record_encode!(MissingSupply { site: Option<SiteId>, port: String, contract: SlotContract });
wire_enum_encode!(TerminalAssessment; units []; tuples [Feasible(ResourceTraceCertificate), EmptyValues(Vec<ProducerRef>), Unknown(Vec<UnresolvedObligation>)]; records [
    ResourceUnreachable { trace: BranchTrace, lowering: resource::SolverInput, correspondence: ResourceCorrespondence, closure: resource::ClosureWitness }
]);
wire_record_encode!(TerminalCoverage {
    terminal: ReturnPlan,
    assessment: TerminalAssessment
});
wire_record_encode!(ChoiceCoverage { choice: ChoiceSkeleton, children: Vec<BigUint> });
wire_record_encode!(ClosedSearchState { state: SearchState, terminals: Vec<TerminalCoverage>, choices: Vec<ChoiceCoverage>, rejected_connections: Vec<ConnectionFailure>, missing_supply: Vec<MissingSupply> });
wire_record_encode!(WireCompositionClosureWitness { input_snapshot: CompositionInput, root: BigUint, states: Vec<ClosedSearchState> });
wire_enum_encode!(WireSelectionEvidence; units [AnyFeasible]; tuples []; records [Unique { closure: Box<WireCompositionClosureWitness>, canonical_plan: String }]);
wire_record_encode!(WireRawComposition { plan: CompositionPlan, witness: CompositionWitness, selection: Arc<WireSelectionEvidence> });
wire_enum_encode!(LocalAction; units []; tuples [Invocation(InvocationPlan)]; records [Guard { guard: GuardId, inspected: ValueRef }]);
wire_record_encode!(CompositionClosureNode { state: SearchState, actions: Vec<LocalAction>, terminals: Vec<ResourceTraceCertificate> });
wire_record_encode!(CompositionClosureWitness { input_identity: String, input_revision: String, nodes: Vec<CompositionClosureNode>, steps: BigUint, binding_candidates: BigUint, branch_nodes: BigUint, frontier: Vec<SearchState>, obligations: Vec<UnresolvedObligation> });
wire_enum_encode!(SelectionEvidence; units [AnyFeasible]; tuples []; records [Unique { closure: Box<CompositionClosureWitness>, canonical_plan: String }]);
wire_record_encode!(RawComposition { plan: CompositionPlan, witness: CompositionWitness, selection: Arc<SelectionEvidence> });
wire_enum!(TraceStep; units []; tuples []; records [Invocation { invocation: InvocationPlan, outcome: OutcomeId }, Guard { guard: GuardId, inspected: ValueRef, arm: GuardArm }]);
wire_record!(BranchTrace { steps: Vec<TraceStep>, terminal: ReturnPlan });
wire_record!(ResourceLotCorrespondence {
    lot: ResourceLotRef,
    place: String,
    producer: ResourceProducer,
    token_target: String,
    token_type: String,
    revision: BigUint,
    quantity: BigUint,
    provenance: String
});
wire_record!(ValueCorrespondence {
    producer: ProducerRef,
    place: String,
    token_target: String,
    revision: BigUint
});
wire_record!(NormalizedResourceBinding {
    transition: String,
    lot: ResourceLotRef,
    read: BigUint,
    consume: BigUint,
    required_revision: BigUint
});
wire_record!(ResourceCorrespondence { lots: Vec<ResourceLotCorrespondence>, values: Vec<ValueCorrespondence>, normalized_bindings: Vec<NormalizedResourceBinding>, execution_order: Vec<String> });
wire_record!(ResourceTraceCertificate { trace: BranchTrace, lowering: resource::SolverInput, correspondence: ResourceCorrespondence, reachability: resource::ReachabilityWitness, acyclicity: resource::AcyclicWitness, value_sources: Vec<(ProducerRef, SlotValue)> });
wire_record!(CompositionWitness { input_snapshot: CompositionInput, initial_membership: Vec<(InputId, SlotValue)>, resource_traces: Vec<ResourceTraceCertificate> });
wire_record_encode!(ConnectionFailure { value: Option<ValueRef>, destination: SlotContract, counterexample: CounterexampleCertificate });
