// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

mod signature_scenario;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use std::io::Write;
fn profile(identity: &str) -> ValueSemanticProfile {
    let reference = ProfileRef {
        identity: identity.into(),
        revision: "1".into(),
        content_digest: "0".repeat(64),
    };
    ValueSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference,
            range: IntegerDomain::Inclusive {
                minimum: (-10).into(),
                maximum: 10.into(),
            },
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        wrappers: vec![],
        tag: None,
        bytes_policy: None,
    }
}
fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let semantic_profile = profile("ncoh-value-semantics");
    let source = SourceIdentity {
        repository: "adapter".into(),
        revision: "1".into(),
        path: "contract".into(),
        content_digest: "0".repeat(64),
    };
    let origin = Origin {
        source: source.clone(),
        locator: vec!["operation".into()],
    };
    let port = |id: &str, ty: &str| SignaturePort {
        id: id.into(),
        contract: SignatureSlot {
            type_id: ty.into(),
            required: true,
            nullable: false,
        },
    };
    let library = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "generated.signatures".into(),
        revision: "1".into(),
        profile: semantic_profile,
        sources: vec![source],
        provenance: vec![],
        groups: vec![DefinitionGroup {
            id: "document".into(),
            members: vec!["value".into(), "operation".into()],
        }],
        annotations: vec![Annotation {
            target: AnnotationTarget::Group("document".into()),
            key: "description".into(),
            value: JsonValue::Str("generated group description".into()),
        }],
        nodes: vec![
            TypeNodeInput {
                id: "truth".into(),
                shape: Shape::Boolean(BooleanSpec {
                    const_value: None,
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "unit".into(),
                shape: Shape::Unit,
            },
        ],
        definitions: vec![
            DefinitionInput {
                id: "value".into(),
                wire_identity: "Example".into(),
                shape: SignatureDefinitionShape::Value("truth".into()),
            },
            DefinitionInput {
                id: "operation".into(),
                wire_identity: "ExampleOperation".into(),
                shape: SignatureDefinitionShape::Operation(OperationContract {
                    effect: EffectPoint::HttpRequestResponse,
                    inputs: vec![port("input", "truth")],
                    outcomes: vec![
                        SignatureOutcome {
                            id: "success".into(),
                            form: necoherence::type_signatures::OutcomeForm::Success,
                            cause: OutcomeCause::ValueContract {
                                origin: origin.clone(),
                            },
                            value_ports: vec![port("output", "truth")],
                            produced_resources: vec![],
                        },
                        SignatureOutcome {
                            id: "refused".into(),
                            form: necoherence::type_signatures::OutcomeForm::DeclaredFailure,
                            cause: OutcomeCause::ExternalCondition {
                                specification: origin,
                            },
                            value_ports: vec![port("reason", "unit")],
                            produced_resources: vec![],
                        },
                    ],
                }),
            },
        ],
    };
    let command = std::env::args().nth(1);
    if command.as_deref() == Some("no-handler") {
        writeln!(
            std::io::stdout().lock(),
            "{}",
            signature_scenario::without_handler(library)?
        )?;
        return Ok(());
    }
    let mut library = library;
    if command.as_deref() == Some("render-synthetic") {
        library.profile = profile("synthetic-profile");
        library.nodes.push(TypeNodeInput {
            id: "synthetic_text".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        });
        library.nodes[0].shape = Shape::Product(SignatureProduct {
            fields: vec![
                SignatureField {
                    wire_name: "kind".into(),
                    slot: SignatureSlot {
                        type_id: "synthetic_text".into(),
                        required: false,
                        nullable: false,
                    },
                },
                SignatureField {
                    wire_name: "label".into(),
                    slot: SignatureSlot {
                        type_id: "synthetic_text".into(),
                        required: false,
                        nullable: false,
                    },
                },
            ],
            extras: SignatureExtraMembers::Reject,
        });
    }
    let input = if matches!(
        command.as_deref(),
        Some("composition" | "render-composition")
    ) {
        signature_scenario::composition(library)?
    } else {
        assemble_signature_generation(
            library,
            None,
            vec![
                SignatureEntrypoint {
                    identity: "example".into(),
                    definition: "value".into(),
                },
                SignatureEntrypoint {
                    identity: "operation".into(),
                    definition: "operation".into(),
                },
            ],
        )?
    };
    let output = match command.as_deref() {
        Some("schema") => signature_generation_schema().to_string(),
        Some("render" | "render-composition" | "render-synthetic") => {
            necoherence_tools::renderer::render_signature_exchange(
                &input.basis,
                &encode_signature_generation(&input)?,
            )?
        }
        _ => encode_signature_generation(&input)?,
    };
    writeln!(std::io::stdout().lock(), "{output}")?;
    Ok(())
}
