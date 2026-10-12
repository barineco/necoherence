// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Temporal ownership harness for Rust.
//! Public surface: ten shared feature families, module by module.

#![allow(clippy::result_large_err, clippy::large_enum_variant)]

pub mod call;
pub mod core;
pub mod dynamic_admission;
pub mod file_effect;
pub mod http_adapter;
pub mod iteration;
pub mod network_effect;
pub mod reconcile;
pub mod record;
pub mod request_progression;
pub mod step_transition;
pub mod store;

pub mod exact_json;
pub mod semantic_codegen_runtime;
pub mod semantic_composition;
pub mod semantic_exchange;
pub mod semantic_types;
pub mod semantic_validation;
pub mod signature_admission;
pub mod type_signatures;
pub mod typed_mapping;

pub use call::{
    deferred_of, immediate_of, io, issue, missing, BoundaryDiagnosis, CallResult, Deferred,
    Immediate, ProjectionFailed, Request,
};
pub use core::{
    apply, bump, command_of, entries, lookup, world_of, Basis, Command, Lookup, Nat, Never,
    Observation, Outcome, ResourceId, Revision, StaleBasis, UnknownResource, World,
};
pub use dynamic_admission::{
    admit_dynamic_request, elide_admission_provenance, AdmissionDecision, AdmissionProvenance,
    AdmissionSignal, CapacityObservation, CoalescingWitness, DynamicAdmissionFailure,
    DynamicAdmissionInput, DynamicAdmissionResult, DynamicAdmissionState, EffectiveBudget,
    EnvironmentSpecification, FutureUseSet, Outcome2, OutstandingSignalSet,
    ProvenanceErasureWitness, SignalKind,
};
pub use file_effect::{
    lookup_digest, normalize_path, read, replace, set_digest, track, ContentDigest, DigestLookup,
    Digests, ExternalFileState, ExternalMutation, FileRecord, FileSnapshot, NormalizedPath, Read,
    ReadFailure, ReadReq, ReadResult, ReplaceConflict, ReplaceContents, ReplaceRejection,
    ReplaceReq, ReplaceResult, Replaced, ResourcePathMismatch, TrackReq, TrackResult, Tracked,
    UnobservedContents, WriteFailure,
};
pub use iteration::{
    closure_output, fold_output, recurse_output, ClosureOutcome, ClosureState, FoldOutcome,
    Measure, RecurseOutcome, StageProjectionFailed, StepOutcome,
};
pub use reconcile::{coherent, reconcile, sorted_divergences, Divergence, Reconciliation};
pub use record::{has_edge, record_of, record_on_basis, CallRecord};
pub use request_progression::{
    apply_completion_observation, apply_start_observation, decide_cancel, decide_start,
    derive_concurrent, derive_in_flight, derive_pending, empty, submit, Accepted, AdapterCommand,
    AdapterFailure, AdapterResult, AdapterSignal, CancelDecisionResult, CancelFailure,
    CompletionObservationFailure, CompletionObservationResult, ConfiguredSafetyLimit,
    CostSelection, EvidenceVersion, ExecutionHandle, MeaningPermission, PermissionDenial,
    RequestEffectClass, RequestEntry, RequestFootprint, RequestIdentity, RequestInput,
    RequestPhase, RequestPolicy, RequestProgressionSnapshot, ResourceBudget, ResourceDemand,
    Running, StartDecisionFailure, StartDecisionResult, StartObservationFailure,
    StartObservationResult, Starting, SubmitFailure, SubmitResult,
};
pub use step_transition::{
    step, Capacity, Consumption, PositiveLimit, StepFailure, StepTransition,
};
pub use store::{observe, store_entries, store_of, world_of_store, Observed, Store};
pub use typed_mapping::{
    apply_branch_at, apply_consumption, binding_satisfied_at, bindings_for,
    check_closure_required_for_unreachable, check_deadlock_goal_separation,
    check_read_consume_atomicity, check_token_color_preserved, consumed_at, derive_enabled,
    eval_goal, produced_token, remove_all_tokens, AcyclicWitness, ClosureWitness, ColoredToken,
    CycleWitness, DeadlockResult, DeadlockWitness, DeclarationGraph, DomainBound, EnabledResult,
    EnabledSet, EnabledTransition, GoalPredicate, InputBinding, InvalidReason, Marking,
    ReachabilityResult, ReachabilityWitness, SolverFailure, SolverInput, TokenKind, TypedPlace,
    TypedTransition, UnknownReason, WellFoundednessResult,
};
