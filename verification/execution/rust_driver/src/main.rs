// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::network_effect as network;
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};
use necoherence::semantic_composition::{
    FunctionRef, InputId, OutcomeId, PortId, ProducerRef, ResourceLotRef, SiteId, ValueRef,
};
use necoherence::semantic_exchange::{decode_signature_generation, signature_generation_context};
use necoherence::semantic_execution::{self as execution, ValidationFailure};
use necoherence::semantic_types::{
    PathStep, SemanticObligation, SemanticReason, SlotValue, TypeRef, ValueFailure,
};
use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
};

mod network_failure;

fn slot(value: &Value) -> SlotValue {
    match value["tag"].as_str().unwrap() {
        "absent" => SlotValue::Absent,
        "null" => SlotValue::Null,
        "present" => SlotValue::Present(
            necoherence::exact_json::bounded_json_parse(&value["value"].to_string()).unwrap(),
        ),
        _ => panic!("unknown slot"),
    }
}

fn slot_json(value: &SlotValue) -> Value {
    match value {
        SlotValue::Absent => json!({"tag":"absent"}),
        SlotValue::Null => json!({"tag":"null"}),
        SlotValue::Present(value) => {
            json!({"tag":"present","value":serde_json::to_value(value).unwrap()})
        }
    }
}

fn attempt_input(description: &Value) -> network::AttemptInput {
    network::AttemptInput {
        attempt: network::AttemptIdentity {
            logical: RequestIdentity {
                kind: "semantic".into(),
                provenance: description
                    .get("provenance")
                    .and_then(Value::as_str)
                    .unwrap_or("comparison")
                    .into(),
                revision: 1u8.into(),
            },
            ordinal: description
                .get("ordinal")
                .and_then(Value::as_u64)
                .unwrap_or(0)
                .into(),
        },
        instruction: network::HttpWireInstruction {
            method: description["method"].as_str().unwrap().into(),
            target: description["target"].as_str().unwrap().into(),
            headers: description["headers"]
                .as_array()
                .unwrap()
                .iter()
                .map(|value| network::RawHeaderField {
                    name: value["name"].as_str().unwrap().into(),
                    value: bytes(&value["value"]),
                })
                .collect(),
            body: bytes(&description["body"]),
        },
        deadline: None,
        configuration: network::HostConfiguration {
            request_body_limit: 1024u64.into(),
            response_body_limit: 1024u64.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    }
}

fn bytes(value: &Value) -> network::ByteString {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|value| u8::try_from(value.as_u64().unwrap()).unwrap())
        .collect()
}

fn providers(case: &Value, references: &[FunctionRef]) -> Vec<execution::Provider> {
    case["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|description| {
            let signature = description
                .get("signature")
                .and_then(Value::as_u64)
                .unwrap_or(0) as usize;
            let mut provider_reference = references[signature].clone();
            if description["reference"] == "other" {
                provider_reference.identity = "other".into();
            }
            let implementation = if description["effect"] == "pure" {
                let returned = call_result(description);
                execution::ProviderImplementation::Pure(Arc::new(move |_| Ok(returned.clone())))
            } else {
                let preparations = description["prepare"].clone();
                let next = Arc::new(AtomicUsize::new(0));
                let decode = description["decode"].clone();
                execution::ProviderImplementation::PreparedHttp(execution::PreparedNetworkOwner {
                    prepare: Arc::new(move |_| {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        let prepared = &preparations.as_array().unwrap()[index];
                        if prepared["tag"] == "completed" {
                            Ok(execution::PreparedCall::Completed(call_result(prepared)))
                        } else {
                            Ok(execution::PreparedCall::Ready(Arc::new(attempt_input(
                                &prepared["request"],
                            ))))
                        }
                    }),
                    decode: Arc::new(move |response| {
                        let decoded = decode
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|value| value["status"].as_u64() == response.status.to_u64())
                            .unwrap();
                        if let Some(failure) = decoded.get("failure") {
                            Err(execution::ExecutionFailure::Provider(
                                SiteId("operation".into()),
                                failure["message"].as_str().unwrap().into(),
                            ))
                        } else {
                            Ok(call_result(decoded))
                        }
                    }),
                })
            };
            execution::Provider {
                reference: provider_reference,
                implementation,
            }
        })
        .collect()
}

fn call_result(description: &Value) -> execution::CallResult {
    execution::CallResult {
        outcome: OutcomeId(description["outcome"].as_str().unwrap().into()),
        outputs: description["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| {
                (
                    PortId(value["id"].as_str().unwrap().into()),
                    slot(&value["value"]),
                )
            })
            .collect(),
    }
}

fn function_json(function: &FunctionRef) -> Value {
    json!({"identity":function.identity,"revision":function.revision,"contentDigest":function.content_digest})
}

fn nested(constructor: &str, arguments: Vec<Value>) -> Value {
    json!({"constructor":constructor,"arguments":arguments})
}

fn source_json(source: &necoherence::semantic_types::SourceRef) -> Value {
    json!({"repository":source.repository,"revision":source.revision,"path":source.path,
        "contentDigest":source.content_digest,"documentId":source.document_id,
        "declaredRevision":source.declared_revision.as_ref().map(ToString::to_string)})
}

fn type_json(reference: &TypeRef) -> Value {
    let source = reference.source.as_ref();
    json!({"source":source_json(source),
        "definition":reference.definition_name.as_ref(),"pointer":reference.pointer.as_ref()})
}

fn path_json(path: &[PathStep]) -> Value {
    Value::Array(
        path.iter()
            .map(|step| match step {
                PathStep::Field(name) => json!({"field":name}),
                PathStep::Index(index) => {
                    json!({"index":index.to_string().parse::<u64>().unwrap()})
                }
                PathStep::Variant(tag) => json!({"variant":tag}),
            })
            .collect(),
    )
}

fn producer_json(producer: &ProducerRef) -> Value {
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

fn value_ref_json(reference: &ValueRef) -> Value {
    json!({"producer":producer_json(&reference.producer),"path":path_json(&reference.path)})
}

fn lot_json(lot: &ResourceLotRef) -> Value {
    match lot {
        ResourceLotRef::Initial(id) => nested("initial", vec![json!(id.0)]),
        ResourceLotRef::Produced {
            site,
            outcome,
            production,
        } => nested(
            "produced",
            vec![json!(site.0), json!(outcome.0), json!(production.0)],
        ),
    }
}

fn value_failure_json(failure: &ValueFailure) -> Value {
    let encoded: Value =
        serde_json::from_str(&necoherence::semantic_exchange::encode_diagnostic(failure).unwrap())
            .unwrap();
    json!({"typeRef":type_json(&failure.type_ref),
        "definitionRef":{"source":source_json(failure.definition_ref.source.as_ref()),"name":failure.definition_ref.name.as_ref()},
        "origin":{"source":source_json(failure.origin.source.as_ref()),"pointer":failure.origin.pointer.as_ref()},
        "valuePath":path_json(&failure.value_path),
        "condition":encoded["condition"],"observed":encoded["observed"],
        "referenceTrace":failure.reference_trace.iter().map(type_json).collect::<Vec<_>>()})
}

fn semantic_reason_json(reason: &SemanticReason) -> Value {
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

fn semantic_obligation_json(obligation: &SemanticObligation) -> Value {
    json!({
        "typeRef": type_json(&obligation.type_ref),
        "valuePath": path_json(&obligation.value_path),
        "reason": semantic_reason_json(&obligation.reason),
    })
}

fn validation_failure_json(failure: &ValidationFailure) -> Value {
    match failure {
        ValidationFailure::Value(value) => nested("value", vec![value_failure_json(value)]),
        ValidationFailure::Unresolved(obligations) => nested(
            "unresolved",
            vec![Value::Array(
                obligations.iter().map(semantic_obligation_json).collect(),
            )],
        ),
        ValidationFailure::CertificateMismatch(condition) => {
            nested("certificateMismatch", vec![json!(condition)])
        }
    }
}

fn failure_json(failure: &execution::ExecutionFailure) -> Value {
    match failure {
        execution::ExecutionFailure::Value(value) => {
            json!({"tag":"Value","detail":validation_failure_json(value)})
        }
        execution::ExecutionFailure::MissingArgument(id) => {
            json!({"tag":"MissingArgument","input":id.0})
        }
        execution::ExecutionFailure::ArgumentCoverage(condition) => {
            json!({"tag":"ArgumentCoverage","condition":condition})
        }
        execution::ExecutionFailure::MissingValue(value) => {
            json!({"tag":"MissingValue","detail":value_ref_json(value)})
        }
        execution::ExecutionFailure::MissingProvider(function) => {
            json!({"tag":"MissingProvider","function":function_json(function)})
        }
        execution::ExecutionFailure::ProviderCoverage(condition) => {
            json!({"tag":"ProviderCoverage","condition":condition})
        }
        execution::ExecutionFailure::ProviderEffect(function) => {
            json!({"tag":"ProviderEffect","function":function_json(function)})
        }
        execution::ExecutionFailure::Provider(site, message) => {
            json!({"tag":"Provider","site":site.0,"message":message})
        }
        execution::ExecutionFailure::InvalidOutcome(site, outcome) => {
            json!({"tag":"InvalidOutcome","site":site.0,"outcome":outcome.0})
        }
        execution::ExecutionFailure::Resource(lot, condition) => {
            json!({"tag":"Resource","lot":lot_json(lot),"condition":condition})
        }
        execution::ExecutionFailure::InvalidPlan(condition) => {
            json!({"tag":"InvalidPlan","condition":condition})
        }
        execution::ExecutionFailure::Network(value) => {
            json!({"tag":"Network","detail":network_failure::json(value)})
        }
        execution::ExecutionFailure::NetworkTerminal(value) => {
            let (outcome, stage, cause) = match &value.outcome {
                network::NetworkOutcome::Failed { failure } => (
                    "Failed",
                    Some(format!("{:?}", failure.stage)),
                    Some(match &failure.cause {
                        network::HostFailure::Timeout { .. } => "Timeout".into(),
                        other => format!("{other:?}"),
                    }),
                ),
                network::NetworkOutcome::Response { .. } => ("Response", None, None),
                network::NetworkOutcome::Cancelled => ("Cancelled", None, None),
                network::NetworkOutcome::DeadlineExceeded { .. } => {
                    ("DeadlineExceeded", None, None)
                }
            };
            let (effect, reason) = match &value.effect {
                network::EffectStatus::NoEffect { .. } => ("NoEffect", None),
                network::EffectStatus::EffectOccurred { .. } => ("EffectOccurred", None),
                network::EffectStatus::Unknown { reason } => {
                    ("Unknown", Some(format!("{reason:?}")))
                }
            };
            json!({"tag":"NetworkTerminal","outcome":outcome,"stage":stage,"cause":cause,"effect":effect,"reason":reason})
        }
    }
}

fn request_for(case: &Value, index: usize) -> network::AttemptInput {
    let ready: Vec<&Value> = case["providers"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|provider| {
            provider
                .get("prepare")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|value| value["tag"] == "ready")
        })
        .collect();
    if !ready.is_empty() {
        return attempt_input(&ready[index]["request"]);
    }
    attempt_input(&case["providers"][0]["request"])
}

fn run(case: &Value) -> Result<Value, Box<dyn std::error::Error>> {
    let exchange = case["exchange"].as_str().unwrap();
    let basis = necoherence::type_signatures::ExpectedSignatureBasis::of_input(
        &decode_signature_generation(exchange)?,
    );
    let context = signature_generation_context(&basis, exchange)?;
    let preparation = context
        .prepare_admission()
        .map_err(|failure| format!("{failure:?}"))?
        .ok_or("composition required")?;
    let prepared = preparation.prepared();
    let admitted = preparation.admitted();
    let references: Vec<_> = prepared
        .input()
        .signatures
        .iter()
        .map(|signature| signature.reference.clone())
        .collect();
    let references = if references.is_empty() {
        vec![FunctionRef {
            identity: "unused".into(),
            revision: "0".into(),
            content_digest: "0".repeat(64),
        }]
    } else {
        references
    };
    let arguments = case["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| {
            (
                InputId(value["id"].as_str().unwrap().into()),
                slot(&value["value"]),
            )
        })
        .collect();
    let run = execution::PreparedRun::new(admitted);
    let mut current = execution::start(
        &run,
        run.workspace(),
        providers(case, &references),
        arguments,
        network::NetworkState::default(),
    );
    let mut progress = Vec::new();
    let mut observation_index = 0usize;
    loop {
        match current {
            Err(failure) => {
                return Ok(
                    json!({"case":case["case"],"progress":progress,"failure":failure_json(&failure.cause)}),
                )
            }
            Ok(execution::Progress::Completed(result, _)) => {
                progress.push(json!({"tag":"completed"}));
                let result = match result {
                    execution::ExecutionResult::Success(outputs) => {
                        json!({"tag":"success","outcome":outputs.iter().map(|(name,value)| json!([name.0,slot_json(value)])).collect::<Vec<_>>() })
                    }
                    execution::ExecutionResult::Failure(embedding, value) => {
                        json!({"tag":"failure","embedding":embedding.0,"value":slot_json(&value)})
                    }
                };
                return Ok(json!({"case":case["case"],"progress":progress,"result":result}));
            }
            Ok(execution::Progress::Pending(suspended, instruction)) => {
                progress.push(json!({"tag":"pending","instruction":match instruction { execution::NetworkInstruction::Send => "send", execution::NetworkInstruction::Observe => "observe" }}));
                let observation = &case["observations"][observation_index];
                observation_index += 1;
                let request_index = observation
                    .get("request")
                    .and_then(Value::as_u64)
                    .unwrap_or(0) as usize;
                let request = request_for(case, request_index);
                let handle = ExecutionHandle {
                    value: observation
                        .get("handle")
                        .and_then(Value::as_str)
                        .unwrap_or("handle")
                        .into(),
                };
                let supplied = if observation["tag"] == "start" && observation["kind"] == "started"
                {
                    execution::ExecutionObservation::Start(network::StartObservation::Started {
                        attempt: request.attempt,
                        handle,
                    })
                } else if observation["tag"] == "start" {
                    let failure = network::NetworkHostFailure {
                        attempt: request.attempt,
                        stage: network::HostStage::Start,
                        configuration: request.configuration,
                        cause: network::HostFailure::ExecutionStartFailed,
                    };
                    execution::ExecutionObservation::Start(network::StartObservation::StartFailed {
                        failure,
                        effect: network::EffectStatus::Unknown {
                            reason: network::UnknownEffectReason::NoResponse,
                        },
                    })
                } else {
                    let response = network::AdapterObservation::ResponseObservation {
                        attempt: request.attempt,
                        handle,
                        source_sequence: None,
                        response: network::RawHttpResponse {
                            status: observation["status"].as_u64().unwrap().into(),
                            headers: observation["headers"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .map(|value| network::RawHeaderField {
                                    name: value["name"].as_str().unwrap().into(),
                                    value: bytes(&value["value"]),
                                })
                                .collect(),
                            body: bytes(&observation["body"]),
                        },
                        provenance: network::HeaderProvenance::LibraryNormalized,
                        effect: network::EffectStatus::Unknown {
                            reason: network::UnknownEffectReason::NoResponse,
                        },
                    };
                    execution::ExecutionObservation::Host(network::HostObservation::Delivered {
                        delivery: observation
                            .get("delivery")
                            .and_then(Value::as_u64)
                            .unwrap_or(0)
                            .into(),
                        observation: response,
                    })
                };
                current = execution::resume(suspended, supplied);
            }
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let document: Value = serde_json::from_str(&fs::read_to_string(
        std::env::args().nth(1).ok_or("input path required")?,
    )?)?;
    let rows = document["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(run)
        .collect::<Result<Vec<_>, _>>()?;
    let mut output = std::io::stdout().lock();
    writeln!(output, "{}", serde_json::to_string(&rows)?)?;
    Ok(())
}
