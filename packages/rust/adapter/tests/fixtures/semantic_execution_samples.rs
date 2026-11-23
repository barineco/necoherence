// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used,
    clippy::indexing_slicing
)]

use necoherence::network_effect::*;
use necoherence::request_progression::RequestIdentity;
use necoherence::semantic_composition as composition;
use necoherence::semantic_execution as execution;
use necoherence::semantic_types::*;
use necoherence::signature_admission::signature_type_ref;
use necoherence::type_signatures::*;
use num_bigint::BigInt;
use std::sync::Arc;

pub const PURE: &str = include_str!("execution-pure.json");
pub const HTTP: &str = include_str!("execution-http.json");
pub const PRESENCE: &str = include_str!("execution-presence.json");
pub const PAIR: &str = include_str!("execution-pair.json");
pub const PAIR_HTTP: &str = include_str!("execution-pair-http.json");

pub fn admitted(text: &str) -> necoherence::signature_admission::CheckedSignatureGeneration {
    let basis = ExpectedSignatureBasis::of_input(
        &necoherence::semantic_exchange::decode_signature_generation(text).expect("decode"),
    );
    necoherence::semantic_exchange::signature_generation_context(&basis, text).expect("admission")
}

pub fn operation_reference(
    prepared: &composition::PreparedCompositionInput<'_>,
) -> composition::FunctionRef {
    prepared.input().signatures[0].reference.clone()
}

pub fn argument_true() -> (composition::InputId, SlotValue) {
    (
        composition::InputId("argument".into()),
        SlotValue::Present(JsonValue::Bool(true)),
    )
}

pub fn profile_reference() -> ProfileRef {
    ProfileRef {
        identity: "execution-profile".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    }
}

pub fn library() -> TypeSignatureLibrary {
    let reference = profile_reference();
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "execution-library".into(),
        revision: "1".into(),
        profile: ValueSemanticProfile {
            reference: reference.clone(),
            source_refs: vec![],
            integer_domains: vec![IntegerDomainBinding {
                name: "integer".into(),
                reference: reference.clone(),
                range: IntegerDomain::Inclusive {
                    minimum: BigInt::from(-10),
                    maximum: BigInt::from(10),
                },
                forms: vec![IntegerForm::Number],
            }],
            default_integer_domain: "integer".into(),
            numbers: NumberModel { decimals: false },
            grapheme_rules: None,
            format_bindings: vec![],
            bytes_policy: None,
            wrappers: vec![],
            tag: None,
        },
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        }],
        definitions: vec![DefinitionInput {
            id: "operation".into(),
            wire_identity: "operation".into(),
            shape: SignatureDefinitionShape::Value("boolean".into()),
        }],
    }
}

pub fn bool_contract() -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref("boolean"),
        required: true,
        nullable: false,
    }
}

pub fn function_reference() -> composition::FunctionRef {
    composition::FunctionRef {
        identity: "provider".into(),
        revision: "1".into(),
        content_digest: "b".repeat(64),
    }
}

pub fn invocation_problem(
    graph: &SemanticGraph,
    contract: &SlotContract,
    effect: composition::CompositionEffect,
) -> composition::CompositionInput {
    let function = function_reference();
    let site = composition::SiteId("site".into());
    let success = composition::OutcomeId("success".into());
    let failure = composition::OutcomeId("failure".into());
    let success_port = composition::PortId("value".into());
    let failure_port = composition::PortId("error".into());
    composition::CompositionInput {
        identity: "execution".into(),
        revision: "1".into(),
        basis: composition::SemanticBasis::of(graph),
        signatures: vec![composition::FunctionSignature {
            reference: function.clone(),
            form: composition::FunctionForm::Operation(DefinitionRef {
                source: contract.type_ref.source.clone(),
                name: Arc::from("operation"),
            }),
            effect,
            inputs: vec![],
            outcomes: vec![
                composition::OutcomeContract {
                    id: success.clone(),
                    form: composition::OutcomeForm::Success,
                    value_ports: vec![composition::OutputPort {
                        id: success_port.clone(),
                        contract: contract.clone(),
                        resource_production: None,
                    }],
                    produced_resources: vec![],
                },
                composition::OutcomeContract {
                    id: failure.clone(),
                    form: composition::OutcomeForm::DeclaredFailure,
                    value_ports: vec![composition::OutputPort {
                        id: failure_port,
                        contract: contract.clone(),
                        resource_production: None,
                    }],
                    produced_resources: vec![],
                },
            ],
            resource_inputs: vec![],
            assumption_ref: "execution test".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: composition::GoalSpec {
            outputs: vec![composition::GoalPort {
                id: composition::GoalPortId("result".into()),
                contract: contract.clone(),
                source_constraint: composition::SourceConstraint::ProducedBy {
                    site: site.clone(),
                    outcome: success,
                    port: success_port,
                    path: vec![],
                },
            }],
            failures: vec![composition::FailureEmbedding {
                id: composition::FailureEmbeddingId("declared".into()),
                origin: composition::FailureOrigin::Function {
                    function: function.clone(),
                    outcome: failure,
                },
                contract: contract.clone(),
                final_resources: vec![],
            }],
            final_resources: vec![],
        },
        invocation_domain: composition::InvocationDomain {
            identity: "execution-domain".into(),
            revision: "1".into(),
            sites: vec![composition::InvocationSite {
                id: site,
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![],
        },
        allowed_effects: vec![effect],
        explicit_order: vec![],
        selection_policy: Some(composition::SelectionPolicy::AnyFeasible),
        bounds: composition::SearchBounds::default(),
    }
}

pub fn pure_provider(
    reference: &composition::FunctionRef,
    outcome: &str,
    value: SlotValue,
) -> execution::Provider {
    let outcome = composition::OutcomeId(outcome.into());
    let port = composition::PortId(if outcome.0 == "success" {
        "output".into()
    } else {
        "reason".into()
    });
    execution::Provider {
        reference: reference.clone(),
        implementation: execution::ProviderImplementation::Pure(Arc::new(move |_| {
            Ok(execution::CallResult {
                outcome: outcome.clone(),
                outputs: vec![(port.clone(), value.clone())],
            })
        })),
    }
}

pub fn attempt_input() -> AttemptInput {
    AttemptInput {
        attempt: AttemptIdentity {
            logical: RequestIdentity {
                kind: "semantic-execution".into(),
                provenance: "test".into(),
                revision: 0u8.into(),
            },
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: "GET".into(),
            target: "http://127.0.0.1/".into(),
            headers: vec![],
            body: vec![],
        },
        deadline: None,
        configuration: HostConfiguration {
            request_body_limit: 16u8.into(),
            response_body_limit: 16u8.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    }
}

pub fn http_provider(reference: &composition::FunctionRef) -> execution::Provider {
    let decode: execution::DecodeCallback = Arc::new(|_| {
        Ok(execution::CallResult {
            outcome: composition::OutcomeId("success".into()),
            outputs: vec![(
                composition::PortId("output".into()),
                SlotValue::Present(JsonValue::Bool(true)),
            )],
        })
    });
    let implementation =
        execution::ProviderImplementation::PreparedHttp(execution::PreparedNetworkOwner {
            prepare: Arc::new(|_| Ok(execution::PreparedCall::Ready(Arc::new(attempt_input())))),
            decode,
        });
    execution::Provider {
        reference: reference.clone(),
        implementation,
    }
}

pub fn response(started: &StartedAttempt) -> AdapterObservation {
    AdapterObservation::ResponseObservation {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle.clone(),
        source_sequence: None,
        response: RawHttpResponse {
            status: 200u16.into(),
            headers: vec![],
            body: vec![],
        },
        provenance: HeaderProvenance::LibraryNormalized,
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::ProtocolWitnessMissing,
        },
    }
}

fn argument_is_true(
    arguments: &execution::Arguments<'_>,
) -> Result<(), execution::ExecutionFailure> {
    match arguments.get(&composition::PortId("input".into()))? {
        SlotValue::Present(value) if value.as_bool() == Some(true) => Ok(()),
        _ => Err(execution::ExecutionFailure::InvalidPlan(
            "argument mismatch".into(),
        )),
    }
}

pub fn pure_argument_provider(reference: &composition::FunctionRef) -> execution::Provider {
    execution::Provider {
        reference: reference.clone(),
        implementation: execution::ProviderImplementation::Pure(Arc::new(
            |arguments: &execution::Arguments<'_>| {
                argument_is_true(arguments)?;
                Ok(execution::CallResult {
                    outcome: composition::OutcomeId("success".into()),
                    outputs: vec![(
                        composition::PortId("output".into()),
                        SlotValue::Present(JsonValue::Bool(true)),
                    )],
                })
            },
        )),
    }
}

pub fn http_argument_provider(reference: &composition::FunctionRef) -> execution::Provider {
    let decode: execution::DecodeCallback = Arc::new(|_| {
        Ok(execution::CallResult {
            outcome: composition::OutcomeId("success".into()),
            outputs: vec![(
                composition::PortId("output".into()),
                SlotValue::Present(JsonValue::Bool(true)),
            )],
        })
    });
    let implementation =
        execution::ProviderImplementation::PreparedHttp(execution::PreparedNetworkOwner {
            prepare: Arc::new(|arguments: &execution::Arguments<'_>| {
                argument_is_true(arguments)?;
                Ok(execution::PreparedCall::Ready(Arc::new(attempt_input())))
            }),
            decode,
        });
    execution::Provider {
        reference: reference.clone(),
        implementation,
    }
}

fn pair_is_true(arguments: &execution::Arguments<'_>) -> Result<(), execution::ExecutionFailure> {
    let SlotValue::Present(pair) = arguments.get(&composition::PortId("input".into()))? else {
        return Err(execution::ExecutionFailure::InvalidPlan(
            "pair mismatch".into(),
        ));
    };
    let is_true = |name: &str| {
        pair.member(name)
            .and_then(necoherence::exact_json_view::JsonValueView::as_bool)
            == Some(true)
    };
    if is_true("left") && is_true("right") {
        Ok(())
    } else {
        Err(execution::ExecutionFailure::InvalidPlan(
            "pair mismatch".into(),
        ))
    }
}

pub fn pure_pair_provider(reference: &composition::FunctionRef) -> execution::Provider {
    execution::Provider {
        reference: reference.clone(),
        implementation: execution::ProviderImplementation::Pure(Arc::new(
            |arguments: &execution::Arguments<'_>| {
                pair_is_true(arguments)?;
                Ok(execution::CallResult {
                    outcome: composition::OutcomeId("success".into()),
                    outputs: vec![(
                        composition::PortId("output".into()),
                        SlotValue::Present(JsonValue::Bool(true)),
                    )],
                })
            },
        )),
    }
}

pub fn http_pair_provider(reference: &composition::FunctionRef) -> execution::Provider {
    let decode: execution::DecodeCallback = Arc::new(|_| {
        Ok(execution::CallResult {
            outcome: composition::OutcomeId("success".into()),
            outputs: vec![(
                composition::PortId("output".into()),
                SlotValue::Present(JsonValue::Bool(true)),
            )],
        })
    });
    let implementation =
        execution::ProviderImplementation::PreparedHttp(execution::PreparedNetworkOwner {
            prepare: Arc::new(|arguments: &execution::Arguments<'_>| {
                pair_is_true(arguments)?;
                Ok(execution::PreparedCall::Ready(Arc::new(attempt_input())))
            }),
            decode,
        });
    execution::Provider {
        reference: reference.clone(),
        implementation,
    }
}
