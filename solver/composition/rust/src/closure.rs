// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::enumeration::*;
use super::lowering::*;
use super::search_state::*;
use super::verification::*;
use necoherence::semantic_composition::*;
use necoherence::semantic_types::*;
use necoherence::typed_mapping as resource;
use num_bigint::BigUint;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq)]
pub struct MissingSupply {
    pub site: Option<SiteId>,
    pub port: String,
    pub contract: SlotContract,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalAssessment {
    Feasible(ResourceTraceCertificate),
    ResourceUnreachable {
        trace: BranchTrace,
        lowering: resource::SolverInput,
        correspondence: ResourceCorrespondence,
        closure: resource::ClosureWitness,
    },
    EmptyValues(Vec<ProducerRef>),
    Unknown(Vec<UnresolvedObligation>),
}

pub fn classify_terminal_assessment(
    provenance: CompositionProvenance,
    assessment: TerminalAssessment,
) -> CompositionEvaluation<TerminalAssessment> {
    use neco_quotient_certificate::RefinementOutcome;
    match &assessment {
        TerminalAssessment::Unknown(obligations) => {
            match classify_unresolved_obligations(provenance.clone(), obligations.clone())? {
                RefinementOutcome::Residual { residuals, .. } => Ok(RefinementOutcome::Residual {
                    value: CompositionJudgment {
                        provenance,
                        value: assessment,
                    },
                    residuals,
                }),
                RefinementOutcome::Stopped {
                    residuals, cause, ..
                } => Ok(RefinementOutcome::Stopped {
                    value: CompositionJudgment {
                        provenance,
                        value: assessment,
                    },
                    residuals,
                    cause,
                }),
                RefinementOutcome::Resolved(_) => {
                    Ok(RefinementOutcome::Resolved(CompositionJudgment {
                        provenance,
                        value: assessment,
                    }))
                }
            }
        }
        TerminalAssessment::Feasible(_)
        | TerminalAssessment::ResourceUnreachable { .. }
        | TerminalAssessment::EmptyValues(_) => {
            Ok(RefinementOutcome::Resolved(CompositionJudgment {
                provenance,
                value: assessment,
            }))
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalCoverage {
    pub terminal: ReturnPlan,
    pub assessment: TerminalAssessment,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChoiceCoverage {
    pub choice: ChoiceSkeleton,
    pub children: Vec<BigUint>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ClosedSearchState {
    pub state: SearchState,
    pub terminals: Vec<TerminalCoverage>,
    pub choices: Vec<ChoiceCoverage>,
    pub rejected_connections: Vec<ConnectionFailure>,
    pub missing_supply: Vec<MissingSupply>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LocalAction {
    Invocation(InvocationPlan),
    Guard { guard: GuardId, inspected: ValueRef },
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompositionClosureNode {
    pub state: SearchState,
    pub actions: Vec<LocalAction>,
    pub terminals: Vec<ResourceTraceCertificate>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompositionClosureWitness {
    pub input_identity: String,
    pub input_revision: String,
    pub nodes: Vec<CompositionClosureNode>,
    pub steps: BigUint,
    pub binding_candidates: BigUint,
    pub branch_nodes: BigUint,
    pub frontier: Vec<SearchState>,
    pub obligations: Vec<UnresolvedObligation>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SelectionEvidence {
    AnyFeasible,
    Unique {
        closure: Box<CompositionClosureWitness>,
        canonical_plan: String,
    },
}

pub enum CompositionDecision<'p, 'g> {
    Solved(CheckedComposition<'g>, Arc<SelectionEvidence>),
    Unreachable(CheckedUnreachable),
    Incomplete {
        evaluation: neco_quotient_certificate::RefinementOutcome<
            CompositionJudgment<Vec<UnresolvedObligation>>,
            UnresolvedObligation,
            Vec<UnresolvedObligation>,
        >,
        frontier: Vec<SearchState>,
        rejected_connections: Vec<ConnectionFailure>,
    },
    Ambiguous {
        candidates: Vec<VerifiedCompositionCandidate<'p, 'g>>,
        canonical_plans: Vec<String>,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub struct ConnectionFailure {
    pub value: Option<ValueRef>,
    pub destination: SlotContract,
    pub counterexample: CounterexampleCertificate,
}
#[derive(Debug, Clone, PartialEq)]
pub enum CompositionEngineFailure {
    ContractViolation(String),
    Resource(resource::SolverFailure),
    Witness(WitnessFailure),
    Reasons(CompositionReasonFailure),
}
