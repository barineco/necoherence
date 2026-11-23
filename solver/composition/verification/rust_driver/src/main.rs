// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_composition::{check_assignable, operation_checker_without_library, operation_meaning_of, prepare_direct_composition, CompatibilityDecision, CompositionInputFailure, FunctionRef, InclusionFailure, ProducerRef, ProjectionFailure, TypeObligation, TypeObligationReason, ValueRef, WitnessFailure};
use necoherence_composition_solver::closure::{CompositionDecision, SelectionEvidence};
use necoherence_composition_solver::verification::{verify_composition, verify_composition_closure};
use necoherence::semantic_exchange::{
    decode_signature_basis, decode_signature_generation, decode_signature_problem,
    GenerationFailure,
};
use necoherence::semantic_types::{
    PathStep, SemanticObligation, SemanticReason, SlotContract, SourceRef, TypeRef, ValueFailure,
};
use necoherence::signature_admission::{admit_signature_generation, AdmissionFailure};
use necoherence_composition_solver::wire_admission::verified_signature_derivation;
use necoherence::semantic_exchange::SignatureCompositionAdmissionFailure;
use necoherence::typed_mapping as t;
use necoherence::Nat;
use serde_json::{json, Value};
use std::{fs, io::Write, sync::Arc};

fn source_detail(source: &SourceRef) -> Value {
    json!({"repository":source.repository,"revision":source.revision,"path":source.path,
        "contentDigest":source.content_digest,"documentId":source.document_id,
        "declaredRevision":source.declared_revision.as_ref().map(ToString::to_string)})
}

fn type_detail(reference: &TypeRef) -> Value {
    json!({"source":source_detail(reference.source.as_ref()),
        "definition":reference.definition_name.as_ref(),"pointer":reference.pointer.as_ref()})
}

fn path_detail(path: &[PathStep]) -> Value {
    Value::Array(
        path.iter()
            .map(|step| match step {
                PathStep::Field(name) => json!({"field":name}),
                PathStep::Index(index) => {
                    json!({"index":serde_json::from_str::<Value>(&index.to_string()).unwrap()})
                }
                PathStep::Variant(tag) => json!({"variant":tag}),
            })
            .collect(),
    )
}

fn nested(constructor: &str, arguments: Vec<Value>) -> Value {
    json!({"constructor":constructor,"arguments":arguments})
}

fn producer_detail(producer: &ProducerRef) -> Value {
    match producer {
        ProducerRef::Initial(id) => nested("initial", vec![json!(id.0)]),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => nested(
            "invocationOutcome",
            vec![json!(site.0), json!(outcome.0), json!(port.0)],
        ),
    }
}

fn value_ref_detail(reference: &ValueRef) -> Value {
    json!({"producer":producer_detail(&reference.producer),"path":path_detail(&reference.path)})
}

fn semantic_reason_detail(reason: &SemanticReason) -> Value {
    match reason {
        SemanticReason::UnknownFormat(value) => nested("unknownFormat", vec![json!(value)]),
        SemanticReason::MissingGraphemeRules => nested("missingGraphemeRules", vec![]),
        SemanticReason::MissingBytesPolicy => nested("missingBytesPolicy", vec![]),
        SemanticReason::UnknownIntegerDomain(value) => {
            nested("unknownIntegerDomain", vec![json!(value)])
        }
        SemanticReason::UnknownWrapper(value) => nested("unknownWrapper", vec![json!(value)]),
        SemanticReason::WrapperPayload(value) => nested("wrapperPayload", vec![json!(value)]),
        SemanticReason::UnknownSealedTag(value) => nested("unknownSealedTag", vec![json!(value)]),
        SemanticReason::DecimalNotAdmitted => nested("decimalNotAdmitted", vec![]),
        SemanticReason::IntegerBound => nested("integerBound", vec![]),
        SemanticReason::OpaqueType(value) => nested("opaqueType", vec![json!(value)]),
        SemanticReason::MissingTagModel => nested("missingTagModel", vec![]),
        SemanticReason::UninterpretedExtension(value) => {
            nested("uninterpretedExtension", vec![json!(value)])
        }
        SemanticReason::UnresolvedType => nested("unresolvedType", vec![]),
        SemanticReason::InvalidProfile(value) => nested("invalidProfile", vec![json!(value)]),
        SemanticReason::MembershipBound => nested("membershipBound", vec![]),
        SemanticReason::CertificateMismatch(value) => {
            nested("certificateMismatch", vec![json!(value)])
        }
        SemanticReason::ProjectionUnavailable(value) => {
            nested("projectionUnavailable", vec![json!(value)])
        }
    }
}

fn semantic_obligation_detail(obligation: &SemanticObligation) -> Value {
    json!({
        "typeRef": type_detail(&obligation.type_ref),
        "valuePath": path_detail(&obligation.value_path),
        "reason": semantic_reason_detail(&obligation.reason),
    })
}

fn slot_contract_detail(contract: &SlotContract) -> Value {
    json!({"typeRef":type_detail(&contract.type_ref),"required":contract.required,"nullable":contract.nullable})
}

fn type_obligation_reason_detail(reason: &TypeObligationReason) -> Value {
    match reason {
        TypeObligationReason::Meaning(obligations) => nested(
            "meaning",
            vec![Value::Array(
                obligations.iter().map(semantic_obligation_detail).collect(),
            )],
        ),
        TypeObligationReason::ConstraintImplication => nested("constraintImplication", vec![]),
        TypeObligationReason::Presence => nested("presence", vec![]),
        TypeObligationReason::UnionRemainder => nested("unionRemainder", vec![]),
        TypeObligationReason::ExtraField(value) => nested("extraField", vec![json!(value)]),
        TypeObligationReason::Inhabitation => nested("inhabitation", vec![]),
        TypeObligationReason::ObligationBoundExhausted => {
            nested("obligationBoundExhausted", vec![])
        }
    }
}

fn type_obligation_detail(obligation: &TypeObligation) -> Value {
    json!({
        "pair": {
            "source": slot_contract_detail(&obligation.pair.source),
            "destination": slot_contract_detail(&obligation.pair.destination),
        },
        "path": path_detail(&obligation.path),
        "reason": type_obligation_reason_detail(&obligation.reason),
    })
}

fn function_detail(reference: &FunctionRef) -> Value {
    json!({"identity":reference.identity,"revision":reference.revision,
        "contentDigest":reference.content_digest})
}

fn value_failure_detail(failure: &ValueFailure) -> Value {
    let encoded: Value =
        serde_json::from_str(&necoherence::semantic_exchange::encode_diagnostic(failure).unwrap())
            .unwrap();
    json!({
        "typeRef": type_detail(&failure.type_ref),
        "definitionRef": {
            "source": source_detail(failure.definition_ref.source.as_ref()),
            "name": failure.definition_ref.name.as_ref(),
        },
        "origin": {
            "source": source_detail(failure.origin.source.as_ref()),
            "pointer": failure.origin.pointer.as_ref(),
        },
        "valuePath": path_detail(&failure.value_path),
        "condition": encoded["condition"],
        "observed": encoded["observed"],
        "referenceTrace": failure.reference_trace.iter().map(type_detail).collect::<Vec<_>>(),
    })
}

fn composition_input_detail(failure: &CompositionInputFailure) -> Value {
    match failure {
        CompositionInputFailure::BasisMismatch => nested("basisMismatch", vec![]),
        CompositionInputFailure::DuplicateIdentity { kind, identity } => {
            nested("duplicateIdentity", vec![json!(kind), json!(identity)])
        }
        CompositionInputFailure::UnresolvedType(reference) => {
            nested("unresolvedType", vec![type_detail(reference)])
        }
        CompositionInputFailure::UnresolvedFunction(reference) => {
            nested("unresolvedFunction", vec![function_detail(reference)])
        }
        CompositionInputFailure::InvalidSignature { function, reason } => nested(
            "invalidSignature",
            vec![function_detail(function), json!(reason.text())],
        ),
        CompositionInputFailure::InvalidInitialValue { input, failure } => nested(
            "invalidInitialValue",
            vec![json!(input.0), value_failure_detail(failure)],
        ),
        CompositionInputFailure::SiteEffectNotPermitted { site, effect } => nested(
            "siteEffectNotPermitted",
            vec![json!(site.0), encoded_detail(effect)],
        ),
        CompositionInputFailure::TransformNotPermitted(reference) => {
            nested("transformNotPermitted", vec![function_detail(reference)])
        }
        CompositionInputFailure::EmptyGoal => nested("emptyGoal", vec![]),
        CompositionInputFailure::GoalSourceConstraintUndefined { port, constraint } => nested(
            "goalSourceConstraintUndefined",
            vec![json!(port.0), encoded_detail(constraint)],
        ),
        CompositionInputFailure::FailureEmbeddingOriginUndefined { embedding, origin } => nested(
            "failureEmbeddingOriginUndefined",
            vec![json!(embedding.0), encoded_detail(origin)],
        ),
        CompositionInputFailure::ConstructionNotProduct { identity, type_ref } => nested(
            "constructionNotProduct",
            vec![json!(identity), type_detail(type_ref)],
        ),
        CompositionInputFailure::FieldConstraintUnknownField { identity, field } => nested(
            "fieldConstraintUnknownField",
            vec![json!(identity), json!(field)],
        ),
        CompositionInputFailure::ConstrainedNestedField { identity, field } => nested(
            "constrainedNestedField",
            vec![json!(identity), json!(field)],
        ),
        CompositionInputFailure::ConstructionFieldSourceUndefined {
            identity,
            constraint,
        } => nested(
            "constructionFieldSourceUndefined",
            vec![json!(identity), encoded_detail(constraint)],
        ),
        CompositionInputFailure::NestedFieldUndeclared { identity, field } => {
            nested("nestedFieldUndeclared", vec![json!(identity), json!(field)])
        }
        CompositionInputFailure::NestedConstructionMismatch {
            identity,
            field,
            nested: target,
            type_ref,
        } => nested(
            "nestedConstructionMismatch",
            vec![
                json!(identity),
                json!(field),
                json!(target),
                type_detail(type_ref),
            ],
        ),
        CompositionInputFailure::CyclicConstruction { identity } => {
            nested("cyclicConstruction", vec![json!(identity)])
        }
        CompositionInputFailure::ExplicitSiteOrderInvalid { before, after } => nested(
            "explicitSiteOrderInvalid",
            vec![json!(before.0), json!(after.0)],
        ),
        CompositionInputFailure::InvalidEmptyTypeClosure(failure) => {
            nested("invalidEmptyTypeClosure", vec![inclusion_detail(failure)])
        }
        CompositionInputFailure::InvalidResourceDeclaration(reason) => {
            nested("invalidResourceDeclaration", vec![json!(reason)])
        }
        CompositionInputFailure::InvalidLibrary(failure) => {
            nested("invalidLibrary", vec![library_check_detail(failure)])
        }
    }
}

fn encoded_detail<T: necoherence::semantic_exchange::WireEncode + ?Sized>(value: &T) -> Value {
    serde_json::to_value(necoherence::semantic_exchange::Wire(value)).unwrap()
}

fn library_check_detail(failure: &necoherence::type_signatures::LibraryCheckFailure) -> Value {
    match failure {
        necoherence::type_signatures::LibraryCheckFailure::Profile(failure) => nested(
            "profile",
            vec![
                json!({"identity":failure.reference.identity,"revision":failure.reference.revision,
                    "contentDigest":failure.reference.content_digest}),
                json!(format!("{:?}", failure.predicate).to_lowercase()),
                json!(failure.location),
            ],
        ),
        necoherence::type_signatures::LibraryCheckFailure::Library(failure) => nested(
            "library",
            vec![
                json!(failure.reference),
                json!(format!("{:?}", failure.predicate).to_lowercase()),
                json!(failure.location),
            ],
        ),
    }
}

fn inclusion_detail(failure: &InclusionFailure) -> Value {
    match failure {
        InclusionFailure::BasisMismatch => nested("basisMismatch", vec![]),
        InclusionFailure::ContractMismatch => nested("contractMismatch", vec![]),
        InclusionFailure::UndefinedMeaning(obligations) => nested(
            "undefinedMeaning",
            vec![Value::Array(
                obligations.iter().map(semantic_obligation_detail).collect(),
            )],
        ),
        InclusionFailure::MissingPair => nested("missingPair", vec![]),
        InclusionFailure::PairMismatch(index) => nested("pairMismatch", vec![json!(index)]),
        InclusionFailure::RuleMismatch(index) => nested("ruleMismatch", vec![json!(index)]),
        InclusionFailure::ChildCoverage(index) => nested("childCoverage", vec![json!(index)]),
        InclusionFailure::ForgedEmptiness => nested("forgedEmptiness", vec![]),
        InclusionFailure::CounterexampleMismatch => nested("counterexampleMismatch", vec![]),
        InclusionFailure::Unresolved(obligation) => {
            nested("unresolved", vec![type_obligation_detail(obligation)])
        }
    }
}

fn projection_detail(failure: &ProjectionFailure) -> Value {
    match failure {
        ProjectionFailure::WrongShape { type_ref, path } => {
            nested("wrongShape", vec![type_detail(type_ref), path_detail(path)])
        }
        ProjectionFailure::MissingField { type_ref, name } => {
            nested("missingField", vec![type_detail(type_ref), json!(name)])
        }
        ProjectionFailure::MissingVariant { type_ref, tag } => {
            nested("missingVariant", vec![type_detail(type_ref), json!(tag)])
        }
        ProjectionFailure::BranchAssumptionRequired { path, tag } => nested(
            "branchAssumptionRequired",
            vec![path_detail(path), json!(tag)],
        ),
        ProjectionFailure::VariantSelectionUndetermined { path, tag } => nested(
            "variantSelectionUndetermined",
            vec![path_detail(path), json!(tag)],
        ),
        ProjectionFailure::Unresolved(obligations) => nested(
            "unresolved",
            vec![Value::Array(
                obligations.iter().map(semantic_obligation_detail).collect(),
            )],
        ),
        ProjectionFailure::CertificateMismatch(condition) => {
            nested("certificateMismatch", vec![json!(condition)])
        }
    }
}

fn witness_detail(failure: &WitnessFailure) -> Value {
    match failure {
        WitnessFailure::InputRevisionMismatch => nested("inputRevisionMismatch", vec![]),
        WitnessFailure::InitialMembership(id) => nested("initialMembership", vec![json!(id.0)]),
        WitnessFailure::ProducerMismatch(reference) => {
            nested("producerMismatch", vec![value_ref_detail(reference)])
        }
        WitnessFailure::ProjectionMismatch(projection) => {
            nested("projectionMismatch", vec![projection_detail(projection)])
        }
        WitnessFailure::SourceConstraintMismatch(reference) => nested(
            "sourceConstraintMismatch",
            vec![value_ref_detail(reference)],
        ),
        WitnessFailure::Inclusion(failure) => nested("inclusion", vec![inclusion_detail(failure)]),
        WitnessFailure::SuppliedValueMismatch(reference) => {
            nested("suppliedValueMismatch", vec![value_ref_detail(reference)])
        }
        WitnessFailure::ConstructionMismatch(reference) => {
            nested("constructionMismatch", vec![type_detail(reference)])
        }
        WitnessFailure::MissingBinding(identity) => nested("missingBinding", vec![json!(identity)]),
        WitnessFailure::SignatureMismatch(site) => nested("signatureMismatch", vec![json!(site.0)]),
        WitnessFailure::GuardNotDominating(reference) => {
            nested("guardNotDominating", vec![value_ref_detail(reference)])
        }
        WitnessFailure::IncompleteBranchCoverage(identity) => {
            nested("incompleteBranchCoverage", vec![json!(identity)])
        }
        WitnessFailure::FailureEmbeddingMismatch(id) => {
            nested("failureEmbeddingMismatch", vec![json!(id.0)])
        }
        WitnessFailure::GoalMismatch => nested("goalMismatch", vec![]),
        WitnessFailure::RankViolation => nested("rankViolation", vec![]),
        WitnessFailure::ResourceLoweringMismatch(reason) => {
            nested("resourceLoweringMismatch", vec![json!(reason)])
        }
        WitnessFailure::ResourceReplayMismatch(reason) => {
            nested("resourceReplayMismatch", vec![json!(reason)])
        }
        WitnessFailure::ForgedClosure(reason) => nested("forgedClosure", vec![json!(reason)]),
        WitnessFailure::ForgedAcyclicity(reason) => nested("forgedAcyclicity", vec![json!(reason)]),
        WitnessFailure::MissingEvidence(reason) => nested("missingEvidence", vec![json!(reason)]),
    }
}

fn wire_detail(failure: &GenerationFailure) -> Value {
    match failure {
        GenerationFailure::InvalidJson(message) => {
            nested("syntax", vec![json!("$"), json!(message)])
        }
        GenerationFailure::UnsupportedSchema { path, observed } => {
            json!({"constructor":"unsupportedSchema","arguments":[path,observed]})
        }
        GenerationFailure::UnknownField { path, field } => {
            json!({"constructor":"unknownField","arguments":[path,field]})
        }
        GenerationFailure::UnknownTag { path, tag } => {
            json!({"constructor":"unknownTag","arguments":[path,tag]})
        }
        GenerationFailure::Syntax { path, message } => {
            json!({"constructor":"syntax","arguments":[path,message]})
        }
        GenerationFailure::Profile(failure) => nested(
            "profile",
            vec![json!(failure.reference.identity), json!(failure.location)],
        ),
        GenerationFailure::Library(_) => nested("library", vec![]),
        GenerationFailure::Composition(failure) => witness_detail(failure),
        GenerationFailure::Encoding(message) => nested("encoding", vec![json!(message)]),
        GenerationFailure::Admission(failure) => nested(&admission_name(failure), vec![]),
    }
}

fn n(value: u64) -> Nat {
    value.into()
}
fn token(target: &str) -> t::ColoredToken {
    t::ColoredToken {
        target: target.into(),
        index: n(0),
        revision: n(1),
        kind: t::TokenKind::Input,
    }
}
fn ready() -> t::Marking {
    t::Marking {
        places: vec![
            ("P-READY".into(), vec![token("job-1")]),
            ("P-DONE".into(), vec![]),
        ],
    }
}
fn fixture(goal: u64, closed: bool) -> t::SolverInput {
    let transition = t::TypedTransition {
        identity: "T-RUN".into(),
        input_places: vec!["P-READY".into()],
        output_places: vec!["P-DONE".into()],
        failure_places: vec![],
        revision: n(1),
    };
    let binding = t::InputBinding {
        transition_id: "T-RUN".into(),
        name: "job".into(),
        place: "P-READY".into(),
        token_type: "T-JOB".into(),
        identity: "job-1".into(),
        provenance: "test".into(),
        multiplicity: n(1),
        mode: t::BindingMode::Consume,
        required_revision: n(1),
    };
    t::SolverInput {
        places: vec![
            t::TypedPlace {
                identity: "P-READY".into(),
                token_type: "T-JOB".into(),
                revision: n(1),
            },
            t::TypedPlace {
                identity: "P-DONE".into(),
                token_type: "T-JOB".into(),
                revision: n(1),
            },
        ],
        transitions: if closed { vec![] } else { vec![transition] },
        bindings: if closed { vec![] } else { vec![binding] },
        goal: t::GoalPredicate::PlaceHasAtLeast {
            place: "P-DONE".into(),
            count: n(goal),
        },
        graph: t::DeclarationGraph {
            places: vec!["P-READY".into(), "P-DONE".into()],
            transitions: if closed { vec![] } else { vec!["T-RUN".into()] },
            edges: vec![("P-READY".into(), "P-DONE".into())],
            revision: n(1),
        },
        marking: ready(),
        bound: t::DomainBound {
            target_identity: "unit".into(),
            index: n(0),
            revision: n(1),
            max_bindings: n(10),
            max_search_steps: n(10),
        },
    }
}
fn admission_name(error: &AdmissionFailure) -> String {
    match error {
        AdmissionFailure::UnsupportedSchema(_) => "UnsupportedSchema",
        AdmissionFailure::RuleTable(_) => "RuleTable",
        AdmissionFailure::EntrypointsEmpty
        | AdmissionFailure::EntrypointIdentityEmpty
        | AdmissionFailure::EntrypointDuplicate(_) => "InvalidEntrypoints",
        AdmissionFailure::EntrypointUnresolved { .. } => "UnresolvedEntrypoint",
        AdmissionFailure::Library(_) => "Library",
        AdmissionFailure::Certificate(_) => "Certificate",
        AdmissionFailure::Wire(_) => "Wire",
        AdmissionFailure::CompositionInput(_) => "CompositionInput",
        AdmissionFailure::Composition(_) => "Composition",
        AdmissionFailure::Generation(_) => "Generation",
    }
    .into()
}

fn failure(error: &AdmissionFailure) -> (String, Option<Value>) {
    match error {
        AdmissionFailure::Composition(value) => ("Composition".into(), Some(witness_detail(value))),
        AdmissionFailure::CompositionInput(value) => (
            "CompositionInput".into(),
            Some(composition_input_detail(value)),
        ),
        AdmissionFailure::Wire(GenerationFailure::Admission(inner)) => failure(inner),
        AdmissionFailure::Wire(value) => ("Wire".into(), Some(wire_detail(value))),
        AdmissionFailure::Generation(_) => ("Generation".into(), None),
        _ => (admission_name(error), None),
    }
}

fn closure(case: &Value) -> (String, Option<String>, Option<Value>) {
    let input = match decode_signature_generation(case["exchange"].as_str().unwrap()) {
        Ok(value) => value,
        Err(error) => {
            return (
                "Rejected".into(),
                Some("Wire".into()),
                Some(wire_detail(&error)),
            )
        }
    };
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input.clone(),
    )
    .unwrap();
    let composition = input.composition.as_ref().unwrap();
    let problem = decode_signature_problem(&input.signatures, &composition["problem"]).unwrap();
    let prepared = prepare_direct_composition(
        checked.graph(),
        problem,
        operation_checker_without_library(),
        operation_meaning_of(checked.graph()),
    )
    .unwrap();
    let CompositionDecision::Solved(selected, _) =
        necoherence_composition_solver::composition_search::derive(&prepared).unwrap()
    else {
        panic!("unique closure input must solve")
    };
    let SelectionEvidence::Unique { closure, .. } = selected.raw().selection.as_ref() else {
        panic!("unique evidence required")
    };
    let mut closure = (**closure).clone();
    let refresh_counts =
        |closure: &mut necoherence_composition_solver::closure::CompositionClosureWitness| {
            closure.steps = closure.nodes.len().saturating_sub(1).into();
            closure.binding_candidates = closure
                .nodes
                .iter()
                .map(|node| {
                    necoherence_composition_solver::enumeration::closure_binding_candidates(
                        &prepared,
                        &node.state,
                    )
                })
                .sum::<usize>()
                .into();
            closure.branch_nodes = closure
                .nodes
                .iter()
                .flat_map(|node| node.actions.iter().map(|action| (&node.state, action)))
                .map(|(state, action)| {
                    necoherence_composition_solver::enumeration::action_successors(&prepared, state, action)
                        .unwrap()
                        .len()
                })
                .sum::<usize>()
                .into();
        };
    match case["mutation"].as_str().unwrap() {
        "local" => {
            closure.nodes[0].actions.clear();
            refresh_counts(&mut closure);
        }
        "initial" => {
            let initial = necoherence_composition_solver::search_state::initial_state(&prepared);
            closure.nodes.retain(|node| node.state != initial);
            refresh_counts(&mut closure);
        }
        "successor" => {
            closure.nodes.pop();
            refresh_counts(&mut closure);
        }
        "frontier" => closure
            .frontier
            .push(necoherence_composition_solver::search_state::initial_state(&prepared)),
        "obligations" => closure
            .obligations
            .push(necoherence::semantic_composition::UnresolvedObligation::UnresolvedUniqueness),
        mutation => panic!("unknown closure mutation {mutation}"),
    }
    match verify_composition_closure(&prepared, &closure) {
        Ok(_) => ("Accepted".into(), None, None),
        Err(error) => (
            "Rejected".into(),
            Some("Composition".into()),
            Some(witness_detail(&error)),
        ),
    }
}

fn selection(case: &Value) -> (String, Option<String>, Option<Value>) {
    let input = decode_signature_generation(case["exchange"].as_str().unwrap()).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input.clone(),
    )
    .unwrap();
    let composition = input.composition.as_ref().unwrap();
    let problem = decode_signature_problem(&input.signatures, &composition["problem"]).unwrap();
    let prepared = prepare_direct_composition(
        checked.graph(),
        problem,
        operation_checker_without_library(),
        operation_meaning_of(checked.graph()),
    )
    .unwrap();
    let CompositionDecision::Solved(selected, _) =
        necoherence_composition_solver::composition_search::derive(&prepared).unwrap()
    else {
        panic!("unique selection input must solve")
    };
    let mut raw = selected.raw().clone();
    let SelectionEvidence::Unique { closure, .. } = raw.selection.as_ref() else {
        panic!("unique evidence required")
    };
    raw.selection = Arc::new(SelectionEvidence::Unique {
        closure: closure.clone(),
        canonical_plan: "forged".into(),
    });
    let result = match verify_composition(&prepared, &raw) {
        Ok(_) => ("Accepted".into(), None, None),
        Err(error) => (
            "Rejected".into(),
            Some("Composition".into()),
            Some(witness_detail(&error)),
        ),
    };
    result
}
fn witness(case: &Value) -> (String, Option<String>, Option<Value>) {
    let operation = case["operation"].as_str().unwrap();
    let mutation = case["mutation"].as_str().unwrap();
    let result = if operation == "reachability" {
        let input = fixture(1, false);
        let mut final_marking = t::apply_branch_at(
            input.marking.clone(),
            &input.transitions[0],
            &input.bindings,
        );
        if mutation == "final-marking" {
            final_marking = input.marking.clone();
        }
        necoherence::resource_witness::verify_reachability_witness(
            &input,
            &t::ReachabilityWitness {
                path: vec!["T-RUN".into()],
                final_marking,
            },
        )
        .map(|_| ())
    } else {
        let input = fixture(2, true);
        let markings = vec![input.marking.clone()];
        let steps = if mutation == "steps" { n(0) } else { n(1) };
        let frontier = if mutation == "frontier" {
            markings.clone()
        } else {
            vec![]
        };
        if operation == "closure" {
            necoherence_composition_solver::composition_search::verify_closure_witness(
                &input,
                &t::ClosureWitness {
                    explored_markings: markings,
                    steps,
                    frontier,
                },
            )
            .map(|_| ())
        } else if mutation == "cycle" {
            let marking = t::Marking {
                places: vec![("P".into(), vec![token("token")])],
            };
            let input = t::SolverInput {
                places: vec![t::TypedPlace {
                    identity: "P".into(),
                    token_type: "T".into(),
                    revision: n(1),
                }],
                transitions: vec![t::TypedTransition {
                    identity: "LOOP".into(),
                    input_places: vec!["P".into()],
                    output_places: vec![],
                    failure_places: vec![],
                    revision: n(1),
                }],
                bindings: vec![t::InputBinding {
                    transition_id: "LOOP".into(),
                    name: "read".into(),
                    place: "P".into(),
                    token_type: "T".into(),
                    identity: "token".into(),
                    provenance: "test".into(),
                    multiplicity: n(1),
                    mode: t::BindingMode::Read,
                    required_revision: n(1),
                }],
                goal: t::GoalPredicate::PlaceHasAtLeast {
                    place: "P".into(),
                    count: n(2),
                },
                graph: t::DeclarationGraph {
                    places: vec!["P".into()],
                    transitions: vec!["LOOP".into()],
                    edges: vec![("P".into(), "LOOP".into()), ("LOOP".into(), "P".into())],
                    revision: n(1),
                },
                marking: marking.clone(),
                bound: t::DomainBound {
                    target_identity: "unit".into(),
                    index: n(0),
                    revision: n(1),
                    max_bindings: n(10),
                    max_search_steps: n(10),
                },
            };
            necoherence::resource_witness::verify_acyclic_witness(
                &input,
                &t::AcyclicWitness {
                    explored_markings: vec![marking],
                    steps: n(1),
                    frontier: vec![],
                },
            )
            .map(|_| ())
        } else {
            necoherence::resource_witness::verify_acyclic_witness(
                &input,
                &t::AcyclicWitness {
                    explored_markings: markings,
                    steps,
                    frontier,
                },
            )
            .map(|_| ())
        }
    };
    match result {
        Ok(()) => ("Accepted".into(), None, None),
        Err(error) => (
            "Rejected".into(),
            Some("composition".into()),
            Some(witness_detail(&error)),
        ),
    }
}
fn run(case: &Value) -> (String, Option<String>, Option<Value>) {
    match case["kind"].as_str().unwrap() {
        "closure" => return closure(case),
        "selection" => return selection(case),
        "generation" => {
            let basis = decode_signature_basis(case["expected"].as_str().unwrap()).unwrap();
            let input = match decode_signature_generation(case["exchange"].as_str().unwrap()) {
                Ok(value) => value,
                Err(error) => {
                    return (
                        "Rejected".into(),
                        Some("Wire".into()),
                        Some(wire_detail(&error)),
                    )
                }
            };
            let expected = necoherence::type_signatures::ExpectedSignatureBasis {
                basis,
                ..necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input)
            };
            let outcome = admit_signature_generation(&expected, input).and_then(|checked| {
                verified_signature_derivation(checked.input(), checked.graph())
                    .map(|_| ())
                    .map_err(|error| match error {
                        SignatureCompositionAdmissionFailure::Wire(value) => {
                            AdmissionFailure::Wire(value)
                        }
                        SignatureCompositionAdmissionFailure::CompositionInput(value) => {
                            AdmissionFailure::CompositionInput(value)
                        }
                        SignatureCompositionAdmissionFailure::Composition(value) => {
                            AdmissionFailure::Composition(value)
                        }
                    })
            });
            match outcome {
                Ok(()) => ("Accepted".into(), None, None),
                Err(error) => {
                    let (name, detail) = failure(&error);
                    ("Rejected".into(), Some(name), detail)
                }
            }
        }
        "inclusion" => {
            let basis = decode_signature_basis(case["expected"].as_str().unwrap()).unwrap();
            let input = decode_signature_generation(case["exchange"].as_str().unwrap()).unwrap();
            let expected = necoherence::type_signatures::ExpectedSignatureBasis {
                basis,
                ..necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input)
            };
            let checked = admit_signature_generation(&expected, input).unwrap();
            let graph = checked.graph();
            let reference = |name: &str| {
                graph
                    .nodes
                    .iter()
                    .find(|node| node.reference.definition_name.as_ref() == name)
                    .unwrap()
                    .reference
                    .clone()
            };
            let slot = |name: &str| SlotContract {
                type_ref: reference(name),
                required: true,
                nullable: false,
            };
            let decision = match check_assignable(
                graph,
                &slot(case["source"].as_str().unwrap()),
                &slot(case["destination"].as_str().unwrap()),
                10000,
            ) {
                CompatibilityDecision::Compatible(_) => "Compatible",
                CompatibilityDecision::Incompatible(_) => "Incompatible",
                CompatibilityDecision::Unknown(_) => "Unknown",
            };
            (decision.into(), None, None)
        }
        _ => witness(case),
    }
}
fn main() {
    let document: Value =
        serde_json::from_str(&fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap())
            .unwrap();
    let rows: Vec<Value> = document["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| {
            let (decision, failure, detail) = run(case);
            if ["Compatible", "Incompatible", "Unknown"].contains(&decision.as_str()) {
                json!({"case":case["case"],"decision":decision})
            } else {
                let mut row = json!({"case":case["case"],"decision":decision,"failure":failure});
                if let Some(detail) = detail {
                    row.as_object_mut().unwrap().insert("detail".into(), detail);
                }
                row
            }
        })
        .collect();
    let mut output = std::io::stdout().lock();
    output
        .write_all(serde_json::to_string(&rows).unwrap().as_bytes())
        .unwrap();
    output.write_all(b"\n").unwrap();
}
