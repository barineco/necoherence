// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_tools::composition_search::derive;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use std::time::Instant;

fn profile() -> ValueSemanticProfile {
    let reference = ProfileRef {
        identity: "composition-test".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    };
    ValueSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference: reference.clone(),
            range: IntegerDomain::Unbounded,
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        wrappers: vec![Wrapper {
            name: "bytes".into(),
            key: "bytes".into(),
            payload: WrapperPayload::Bytes,
        }],
        tag: Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![],
                extras: SealedExtras::Reject,
            }],
        }),
        bytes_policy: Some(BytesPolicy {
            reference: reference.clone(),
            padding_optional: true,
            alphabet: BytesAlphabet::Either,
            strict_pad_bits: true,
            wrapper: Some("bytes".into()),
        }),
    }
}

fn library() -> TypeSignatureLibrary {
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "composition-test-library".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        definitions: vec![],
        nodes: vec![
            TypeNodeInput {
                id: "text".into(),
                shape: Shape::String(StringSpec {
                    format: None,
                    lengths: vec![],
                    wrapper: None,
                    const_value: None,
                    enum_values: None,
                    examples: vec!["valid".into()],
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "never".into(),
                shape: Shape::Never,
            },
            TypeNodeInput {
                id: "integer".into(),
                shape: Shape::Integer(IntegerSpec {
                    domain: Some("integer".into()),
                    minimum: None,
                    maximum: None,
                    const_value: None,
                    enum_values: None,
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "raw_body".into(),
                shape: Shape::RawBody {
                    encoding: "raw".into(),
                },
            },
            TypeNodeInput {
                id: "bytes".into(),
                shape: Shape::Bytes(LengthSpec {
                    minimum: None,
                    maximum: None,
                }),
            },
            TypeNodeInput {
                id: "inner".into(),
                shape: Shape::Product(SignatureProduct {
                    fields: vec![
                        SignatureField {
                            wire_name: "content".into(),
                            slot: SignatureSlot {
                                type_id: "text".into(),
                                required: true,
                                nullable: false,
                            },
                        },
                        SignatureField {
                            wire_name: "body".into(),
                            slot: SignatureSlot {
                                type_id: "raw_body".into(),
                                required: false,
                                nullable: false,
                            },
                        },
                        SignatureField {
                            wire_name: "amount".into(),
                            slot: SignatureSlot {
                                type_id: "integer".into(),
                                required: false,
                                nullable: false,
                            },
                        },
                    ],
                    extras: SignatureExtraMembers::Reject,
                }),
            },
            TypeNodeInput {
                id: "outer".into(),
                shape: Shape::Product(SignatureProduct {
                    fields: vec![SignatureField {
                        wire_name: "payload".into(),
                        slot: SignatureSlot {
                            type_id: "inner".into(),
                            required: true,
                            nullable: false,
                        },
                    }],
                    extras: SignatureExtraMembers::Reject,
                }),
            },
            TypeNodeInput {
                id: "sealed".into(),
                shape: Shape::Sealed {
                    tag: "sealed".into(),
                    refinements: vec![],
                },
            },
            TypeNodeInput {
                id: "variant".into(),
                shape: Shape::TaggedUnion(SignatureUnion {
                    branches: vec![SignatureUnionBranch {
                        target: "sealed".into(),
                        wire_tag: "sealed".into(),
                        selector: BranchSelector::InternalTag,
                    }],
                }),
            },
        ],
    }
}

fn slot(library: &TypeSignatureLibrary, id: &str, required: bool, nullable: bool) -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref(library, &canonical_digest(library), id),
        required,
        nullable,
    }
}

fn presence_generation() -> SignatureGenerationInput {
    presence_generation_for("text")
}

fn presence_generation_for(type_id: &str) -> SignatureGenerationInput {
    let mut declaration = library();
    if !declaration.nodes.iter().any(|node| node.id == type_id) {
        declaration.nodes.push(TypeNodeInput {
            id: type_id.into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec!["valid".into()],
                default_value: None,
            }),
        });
    }
    let library = Arc::new(declaration);
    let graph = check_type_signatures(&library).unwrap();
    let optional_text = slot(&library, type_id, false, true);
    let required_text = slot(&library, type_id, true, false);
    let input = CompositionInput {
        identity: "presence-guard".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: optional_text.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: required_text,
                source_constraint: SourceConstraint::AnyCompatible,
            }],
            failures: vec![
                FailureEmbedding {
                    id: FailureEmbeddingId("absent".into()),
                    origin: FailureOrigin::Guard {
                        guard: GuardId("presence".into()),
                        arm: GuardArm::Absent,
                    },
                    contract: optional_text.clone(),
                    final_resources: vec![],
                },
                FailureEmbedding {
                    id: FailureEmbeddingId("null".into()),
                    origin: FailureOrigin::Guard {
                        guard: GuardId("presence".into()),
                        arm: GuardArm::Null,
                    },
                    contract: optional_text,
                    final_resources: vec![],
                },
            ],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![DeclaredGuard {
                id: GuardId("presence".into()),
                source_type: signature_type_ref(&library, &canonical_digest(&library), type_id),
                path: vec![],
                kind: GuardKind::Presence,
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: 59,
            ..SearchBounds::default()
        },
    };

    let prepared = prepare_composition(&graph, input.clone()).unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        other => panic!("presence composition is not solved: {other:?}"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let composition =
        signature_composition_from_native(&library, &input, checked.raw(), &[]).unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

fn validate_generation() -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let optional = slot(&library, "text", false, false);
    let required = slot(&library, "text", true, false);
    let guard_id = GuardId("validate".into());
    let input = CompositionInput {
        identity: "validate-guard".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: optional.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: required.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
            }],
            failures: vec![FailureEmbedding {
                id: FailureEmbeddingId("rejected".into()),
                origin: FailureOrigin::Guard {
                    guard: guard_id.clone(),
                    arm: GuardArm::Rejected,
                },
                contract: optional,
                final_resources: vec![],
            }],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "validate-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![DeclaredGuard {
                id: guard_id,
                source_type: required.type_ref.clone(),
                path: vec![],
                kind: GuardKind::Validate(required),
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: 59,
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_composition(&graph, input.clone()).unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        other => panic!("validate guard is not solved: {other:?}"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let composition =
        signature_composition_from_native(&library, &input, checked.raw(), &[]).unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}
fn two_site_generation(mode: necoherence::typed_mapping::BindingMode) -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let initial_quantity = if mode == necoherence::typed_mapping::BindingMode::Consume {
        2u8.into()
    } else {
        1u8.into()
    };
    let contract = slot(&library, "text", true, false);
    let body_contract = slot(&library, "raw_body", true, false);
    let amount_contract = slot(&library, "integer", true, false);
    let bytes_contract = slot(&library, "bytes", true, false);
    let function = FunctionRef {
        identity: "transform".into(),
        revision: "1".into(),
        content_digest: "c".repeat(64),
    };
    let outcome_id = OutcomeId("success".into());
    let port_id = PortId("value".into());
    let body_port_id = PortId("body".into());
    let amount_port_id = PortId("amount".into());
    let bytes_port_id = PortId("octets".into());
    let production_id = ProductionId("next-lot".into());
    let requirement = ResourceRequirement {
        id: RequirementId("access".into()),
        token_type: contract.type_ref.clone(),
        mode: mode.clone(),
        multiplicity: 1u8.into(),
        required_revision: 0u8.into(),
        identity: ResourceIdentityConstraint::Any,
    };
    let signature = FunctionSignature {
        reference: function.clone(),
        form: FunctionForm::DeclaredTransform,
        effect: CompositionEffect::PureFunction,
        inputs: vec![
            InputPort {
                id: PortId("input".into()),
                contract: contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: Some(requirement.id.clone()),
            },
            InputPort {
                id: PortId("body".into()),
                contract: body_contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
            InputPort {
                id: amount_port_id.clone(),
                contract: amount_contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
            InputPort {
                id: bytes_port_id.clone(),
                contract: bytes_contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
        ],
        outcomes: vec![OutcomeContract {
            id: outcome_id.clone(),
            form: necoherence::semantic_composition::OutcomeForm::Success,
            value_ports: vec![
                OutputPort {
                    id: port_id.clone(),
                    contract: contract.clone(),
                    resource_production: None,
                },
                OutputPort {
                    id: body_port_id.clone(),
                    contract: body_contract.clone(),
                    resource_production: None,
                },
                OutputPort {
                    id: amount_port_id.clone(),
                    contract: amount_contract.clone(),
                    resource_production: None,
                },
                OutputPort {
                    id: bytes_port_id.clone(),
                    contract: bytes_contract.clone(),
                    resource_production: None,
                },
            ],
            produced_resources: vec![ResourceProduction {
                id: production_id.clone(),
                token_type: contract.type_ref.clone(),
                revision: 0u8.into(),
                quantity: 1u8.into(),
                provenance: "transform result".into(),
            }],
        }],
        resource_inputs: vec![requirement],
        assumption_ref: "test provider".into(),
        handles_failure: None,
    };
    let first = SiteId("first".into());
    let second = SiteId("second".into());
    let problem = CompositionInput {
        identity: "two-site-resource-flow".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![signature],
        initial_inputs: vec![
            InitialInput {
                id: InputId("argument".into()),
                contract: contract.clone(),
                source: InitialSource::Argument,
                resource: Some(LotId("original-lot".into())),
            },
            InitialInput {
                id: InputId("body".into()),
                contract: body_contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("amount".into()),
                contract: amount_contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("octets".into()),
                contract: bytes_contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
        ],
        initial_resources: vec![ResourceLot {
            id: LotId("original-lot".into()),
            token_type: contract.type_ref.clone(),
            producer: ResourceProducer::Initial {
                identity: "session".into(),
                revision: "1".into(),
            },
            revision: 0u8.into(),
            quantity: initial_quantity,
            provenance: "initial authority".into(),
        }],
        goal: GoalSpec {
            outputs: vec![
                GoalPort {
                    id: GoalPortId("result".into()),
                    contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: port_id.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("body_result".into()),
                    contract: body_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: body_port_id.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("amount_result".into()),
                    contract: amount_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: amount_port_id.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("octets_result".into()),
                    contract: bytes_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: bytes_port_id.clone(),
                        path: vec![],
                    },
                },
            ],
            failures: vec![],
            final_resources: vec![ResourceGoal {
                lot: ResourceLotRef::Produced {
                    site: second.clone(),
                    outcome: outcome_id.clone(),
                    production: production_id.clone(),
                },
                multiplicity: 1u8.into(),
                revision: 0u8.into(),
            }],
        },
        invocation_domain: InvocationDomain {
            identity: "two-sites".into(),
            revision: "1".into(),
            sites: vec![
                InvocationSite {
                    id: first.clone(),
                    function: function.clone(),
                },
                InvocationSite {
                    id: second.clone(),
                    function: function.clone(),
                },
            ],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![function.clone()],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: 59,
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_composition(&graph, problem.clone()).unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        other => panic!("two-site composition is not solved: {other:?}"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let origin = OutcomeCause::ValueContract {
        origin: Origin {
            source: SourceIdentity {
                repository: "semantic-composition-execution-test".into(),
                revision: "1".into(),
                path: "transform".into(),
                content_digest: "d".repeat(64),
            },
            locator: vec!["success".into()],
        },
    };
    let composition = signature_composition_from_native(
        &library,
        &problem,
        checked.raw(),
        &[(function, vec![(outcome_id, origin)])],
    )
    .unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

fn compile_and_run(program: &str) -> std::process::Output {
    static NEXT_PROJECT: AtomicUsize = AtomicUsize::new(0);
    let sequence = NEXT_PROJECT.fetch_add(1, Ordering::Relaxed);
    let project = std::env::temp_dir().join(format!(
        "necoherence-composition-{}-{sequence}",
        std::process::id()
    ));
    std::fs::create_dir_all(project.join("src")).unwrap();
    let necoherence_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../rust")
        .canonicalize()
        .unwrap();
    std::fs::write(
        project.join("Cargo.toml"),
        format!(
            "[package]\nname=\"generated-composition-consumer\"\nversion=\"0.0.0\"\nedition=\"2021\"\n\n[workspace]\n\n[dependencies]\nnecoherence={{path={necoherence_path:?}}}\n"
        ),
    )
    .unwrap();
    std::fs::write(project.join("src/main.rs"), program).unwrap();
    let manifest_path = project.join("Cargo.toml");
    let started = Instant::now();
    let output = std::process::Command::new(env!("CARGO"))
        .args(["run", "--offline", "--manifest-path"])
        .arg(&manifest_path)
        .env("CARGO_TARGET_DIR", project.join("target"))
        .output()
        .unwrap();
    println!(
        "generated_consumer_command: {} run --offline --manifest-path {}",
        env!("CARGO"),
        manifest_path.display()
    );
    println!("generated_consumer_exit_status: {}", output.status);
    println!(
        "generated_consumer_elapsed_seconds: {:.6}",
        started.elapsed().as_secs_f64()
    );
    println!(
        "generated_consumer_stdout:\\n{}",
        String::from_utf8_lossy(&output.stdout)
    );
    println!(
        "generated_consumer_stderr:\\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    std::fs::remove_dir_all(project).unwrap();
    output
}

#[test]
fn admitted_presence_guard_uses_declared_native_branches() {
    let input = presence_generation();
    let document = encode_signature_generation(&input).unwrap();
    let full = necoherence_tools::renderer::render_generation(&input).unwrap();
    let fragment =
        necoherence_tools::renderer::render_signature_composition(&input.basis, &document).unwrap();
    assert!(full.ends_with(&fragment));
    assert_eq!(
        fragment,
        necoherence_tools::renderer::render_signature_composition(&input.basis, &document).unwrap()
    );
    assert!(!fragment.contains("CompositionContinuation"));
    let program = format!(
        r#"{full}
struct Owner;
impl composed::Providers for Owner {{
    type Failure=();
}}
fn main() {{
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let mut owner=Owner;
    let present=composed::execute(&context,composed::CompositionInput{{argument:Some(rt::Nullable::Value(text("valid".into())))}},&mut owner).unwrap();
    assert!(matches!(present,composed::CompositionOutcome::Success(composed::CompositionOutput{{result:text(ref value)}}) if value=="valid"));
    let absent=composed::execute(&context,composed::CompositionInput{{argument:None}},&mut owner).unwrap();
    assert!(matches!(absent,composed::CompositionOutcome::DeclaredFailure(composed::DeclaredFailure::failure_absent(None))));
    let null=composed::execute(&context,composed::CompositionInput{{argument:Some(rt::Nullable::Null)}},&mut owner).unwrap();
    assert!(matches!(null,composed::CompositionOutcome::DeclaredFailure(composed::DeclaredFailure::failure_null(Some(rt::Nullable::Null)))));
}}
"#
    );
    let output = compile_and_run(&program);
    assert!(output.status.success());
}

#[test]
fn two_recipe_fragments_share_one_native_type_library() {
    let input = presence_generation();
    let document = encode_signature_generation(&input).unwrap();
    let full = necoherence_tools::renderer::render_generation(&input).unwrap();
    let fragment_a =
        necoherence_tools::renderer::render_signature_composition(&input.basis, &document).unwrap();
    let fragment_b =
        necoherence_tools::renderer::render_signature_composition(&input.basis, &document).unwrap();
    let types = full.strip_suffix(&fragment_a).unwrap();
    let source = format!(
        "{types}\npub mod recipe_a{{use super::*;{fragment_a}}}\npub mod recipe_b{{use super::*;{fragment_b}}}\n\
         struct Host;\n\
         impl recipe_a::composed::Providers for Host{{type Failure=();}}\n\
         impl recipe_b::composed::Providers for Host{{type Failure=();}}\n\
         fn main(){{let value=text(\"shared\".into());\
         let generation=generation_context().unwrap();let context=Context::new(&generation);\
         let mut owner=Host;\
         let a=recipe_a::composed::execute(&context,recipe_a::composed::CompositionInput{{argument:Some(rt::Nullable::Value(value.clone()))}},&mut owner).unwrap();\
         let b=recipe_b::composed::execute(&context,recipe_b::composed::CompositionInput{{argument:Some(rt::Nullable::Value(value))}},&mut owner).unwrap();\
         assert!(matches!(a,recipe_a::composed::CompositionOutcome::Success(_)));\
         assert!(matches!(b,recipe_b::composed::CompositionOutcome::Success(_)));}}\n"
    );
    assert_eq!(source.matches("pub struct text").count(), 1);
    compile_and_run(&source);
}

#[test]
fn two_sites_preserve_provider_failure_and_resource_metadata() {
    let input = two_site_generation(necoherence::typed_mapping::BindingMode::Consume);
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
#[derive(Debug)]
struct OpaqueError { marker: &'static str }
struct Host { calls: usize, fail_first: bool }
impl composed::Providers for Host {
    type Failure=OpaqueError;
    fn site_first_transform(&mut self,input:composed::site_first_transform_Input,resources:&[composed::BoundResource])->Result<composed::site_first_transform_Outcome,Self::Failure>{
        assert_eq!(input.input.0,"start");
        assert_eq!(input.body.0,vec![0,128,255]);
        assert_eq!(input.octets.0,vec![0,128,255]);
        assert_eq!(input.amount.0,rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap());
        assert_eq!(resources.len(),1);
        assert_eq!(resources[0].reference,necoherence::semantic_composition::ResourceLotRef::Initial(necoherence::semantic_composition::LotId("original-lot".into())));
        assert_eq!(resources[0].lot.provenance,"initial authority");
        assert_eq!(resources[0].lot.token_type.definition_name.as_ref(),"text");
        assert!(matches!(&resources[0].lot.producer,necoherence::semantic_composition::ResourceProducer::Initial{identity,revision} if identity=="session" && revision=="1"));
        assert_eq!(resources[0].lot.revision,0u8.into());
        assert_eq!(resources[0].lot.quantity,2u8.into());
        assert_eq!(resources[0].requirement.mode,necoherence::typed_mapping::BindingMode::Consume);
        assert_eq!(resources[0].requirement.multiplicity,1u8.into());
        assert_eq!(resources[0].requirement.required_revision,0u8.into());
        assert_eq!(resources[0].requirement.identity,necoherence::semantic_composition::ResourceIdentityConstraint::Any);
        self.calls+=1;
        if self.fail_first { return Err(OpaqueError{marker:"opaque host failure"}); }
        Ok(composed::site_first_transform_Outcome::outcome_success(composed::site_first_transform_outcome_success{value:text("middle".into()),body:raw_body(vec![0,128,255]),amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),octets:bytes(vec![0,128,255])}))
    }
    fn site_second_transform(&mut self,input:composed::site_second_transform_Input,resources:&[composed::BoundResource])->Result<composed::site_second_transform_Outcome,Self::Failure>{
        assert_eq!(input.input.0,"start");
        assert_eq!(input.body.0,vec![0,128,255]);
        assert_eq!(input.octets.0,vec![0,128,255]);
        assert_eq!(input.amount.0,rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap());
        assert_eq!(resources.len(),1);
        assert_eq!(resources[0].reference,necoherence::semantic_composition::ResourceLotRef::Initial(necoherence::semantic_composition::LotId("original-lot".into())));
        assert_eq!(resources[0].lot.quantity,1u8.into());
        assert_eq!(resources[0].lot.provenance,"initial authority");
        assert_eq!(resources[0].requirement.mode,necoherence::typed_mapping::BindingMode::Consume);
        self.calls+=1;
        Ok(composed::site_second_transform_Outcome::outcome_success(composed::site_second_transform_outcome_success{value:text("done".into()),body:raw_body(vec![0,128,255]),amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),octets:bytes(vec![0,128,255])}))
    }
}
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let input=composed::CompositionInput{argument:text("start".into()),body:raw_body(vec![0,128,255]),amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),octets:bytes(vec![0,128,255])};
    let mut host=Host{calls:0,fail_first:false};
    let result=composed::execute(&context,input.clone(),&mut host).unwrap();
    assert_eq!(host.calls,2);
    assert!(matches!(result,composed::CompositionOutcome::Success(composed::CompositionOutput{result:text(ref value),body_result:raw_body(ref body_bytes),amount_result:integer(ref large_amount),octets_result:bytes(ref exact_bytes)}) if value=="done" && body_bytes==&vec![0,128,255] && exact_bytes==&vec![0,128,255] && large_amount==&rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()));
    let mut host=Host{calls:0,fail_first:true};
    let error=composed::execute(&context,input,&mut host).unwrap_err();
    match error {
        composed::CompositionFailure::Provider{site,function,cause}=>{
            assert_eq!(site.0,"first");
            assert_eq!(function.identity,"transform");
            assert_eq!(cause.marker,"opaque host failure");
        }
        other=>panic!("provider error changed category: {other:?}"),
    }
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn read_resource_bindings_preserve_lot_quantity_at_both_sites() {
    let input = two_site_generation(necoherence::typed_mapping::BindingMode::Read);
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
struct Host{calls:usize}
impl composed::Providers for Host {
    type Failure=();
    fn site_first_transform(&mut self,input:composed::site_first_transform_Input,resources:&[composed::BoundResource])->Result<composed::site_first_transform_Outcome,Self::Failure>{
        assert_eq!(input.octets.0,vec![0,128,255]);
        assert_eq!(resources[0].lot.quantity,1u8.into());
        assert_eq!(resources[0].requirement.mode,necoherence::typed_mapping::BindingMode::Read);
        self.calls+=1;
        Ok(composed::site_first_transform_Outcome::outcome_success(composed::site_first_transform_outcome_success{
            value:text("first".into()),body:raw_body(vec![0,128,255]),
            amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
            octets:bytes(vec![0,128,255]),
        }))
    }
    fn site_second_transform(&mut self,input:composed::site_second_transform_Input,resources:&[composed::BoundResource])->Result<composed::site_second_transform_Outcome,Self::Failure>{
        assert_eq!(input.octets.0,vec![0,128,255]);
        assert_eq!(resources[0].lot.quantity,1u8.into());
        assert_eq!(resources[0].requirement.mode,necoherence::typed_mapping::BindingMode::Read);
        self.calls+=1;
        Ok(composed::site_second_transform_Outcome::outcome_success(composed::site_second_transform_outcome_success{
            value:text("second".into()),body:raw_body(vec![0,128,255]),
            amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
            octets:bytes(vec![0,128,255]),
        }))
    }
}
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let input=composed::CompositionInput{
        argument:text("start".into()),body:raw_body(vec![0,128,255]),
        amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
        octets:bytes(vec![0,128,255]),
    };
    let mut host=Host{calls:0};
    let result=composed::execute(&context,input,&mut host).unwrap();
    assert_eq!(host.calls,2);
    assert!(matches!(result,composed::CompositionOutcome::Success(composed::CompositionOutput{result:text(ref value),body_result:raw_body(ref body_bytes),amount_result:integer(ref amount),octets_result:bytes(ref octets)}) if value=="second" && body_bytes==&vec![0,128,255] && octets==&vec![0,128,255] && amount==&rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn recursive_construction_generation() -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let text = slot(&library, "text", true, false);
    let amount = slot(&library, "integer", true, false);
    let outer = slot(&library, "outer", true, false);
    let inner = slot(&library, "inner", true, false);
    let seed = FunctionRef {
        identity: "seed".into(),
        revision: "1".into(),
        content_digest: "e".repeat(64),
    };
    let assemble = FunctionRef {
        identity: "assemble".into(),
        revision: "1".into(),
        content_digest: "f".repeat(64),
    };
    let seed_site = SiteId("seed".into());
    let assemble_site = SiteId("assemble".into());
    let outcome = OutcomeId("success".into());
    let seed_output = PortId("output".into());
    let assemble_output = PortId("output".into());
    let type_ref = |id: &str| signature_type_ref(&library, &canonical_digest(&library), id);
    let seed_signature = FunctionSignature {
        reference: seed.clone(),
        form: FunctionForm::DeclaredTransform,
        effect: CompositionEffect::PureFunction,
        inputs: vec![
            InputPort {
                id: PortId("content".into()),
                contract: text.clone(),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: vec![],
                },
                resource_requirement: None,
            },
            InputPort {
                id: PortId("amount".into()),
                contract: amount.clone(),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("amount".into()),
                    path: vec![],
                },
                resource_requirement: None,
            },
        ],
        outcomes: vec![OutcomeContract {
            id: outcome.clone(),
            form: necoherence::semantic_composition::OutcomeForm::Success,
            value_ports: vec![OutputPort {
                id: seed_output.clone(),
                contract: inner.clone(),
                resource_production: None,
            }],
            produced_resources: vec![],
        }],
        resource_inputs: vec![],
        assumption_ref: "seed".into(),
        handles_failure: None,
    };
    let assemble_signature = FunctionSignature {
        reference: assemble.clone(),
        form: FunctionForm::DeclaredTransform,
        effect: CompositionEffect::PureFunction,
        inputs: vec![InputPort {
            id: PortId("payload".into()),
            contract: outer,
            source_constraint: SourceConstraint::AnyCompatible,
            resource_requirement: None,
        }],
        outcomes: vec![OutcomeContract {
            id: outcome.clone(),
            form: necoherence::semantic_composition::OutcomeForm::Success,
            value_ports: vec![OutputPort {
                id: assemble_output.clone(),
                contract: inner,
                resource_production: None,
            }],
            produced_resources: vec![],
        }],
        resource_inputs: vec![],
        assumption_ref: "recursive assembly".into(),
        handles_failure: None,
    };
    let produced = |path: &str| SourceConstraint::ProducedBy {
        site: seed_site.clone(),
        outcome: outcome.clone(),
        port: seed_output.clone(),
        path: vec![PathStep::Field(path.into())],
    };
    let problem = CompositionInput {
        identity: "recursive-projected-product".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![seed_signature, assemble_signature],
        initial_inputs: vec![
            InitialInput {
                id: InputId("argument".into()),
                contract: text,
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("amount".into()),
                contract: amount,
                source: InitialSource::Argument,
                resource: None,
            },
        ],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("selected".into()),
                contract: slot(&library, "text", true, false),
                source_constraint: SourceConstraint::ProducedBy {
                    site: assemble_site.clone(),
                    outcome: outcome.clone(),
                    port: assemble_output,
                    path: vec![PathStep::Field("content".into())],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "recursive-construction-domain".into(),
            revision: "1".into(),
            sites: vec![
                InvocationSite {
                    id: seed_site.clone(),
                    function: seed.clone(),
                },
                InvocationSite {
                    id: assemble_site,
                    function: assemble.clone(),
                },
            ],
            permitted_projections: vec![
                PermittedProjection {
                    source_type: type_ref("inner"),
                    path: vec![PathStep::Field("content".into())],
                },
                PermittedProjection {
                    source_type: type_ref("inner"),
                    path: vec![PathStep::Field("amount".into())],
                },
            ],
            permitted_constructions: vec![
                ConstructionRule {
                    identity: "inner-builder".into(),
                    type_ref: type_ref("inner"),
                    nested_fields: vec![],
                    field_constraints: vec![
                        FieldConstraint {
                            field: "content".into(),
                            source: produced("content"),
                            presence: FieldPresence::Required,
                        },
                        FieldConstraint {
                            field: "amount".into(),
                            source: produced("amount"),
                            presence: FieldPresence::Required,
                        },
                    ],
                },
                ConstructionRule {
                    identity: "outer-builder".into(),
                    type_ref: type_ref("outer"),
                    nested_fields: vec![("payload".into(), "inner-builder".into())],
                    field_constraints: vec![],
                },
            ],
            permitted_transforms: vec![seed.clone(), assemble.clone()],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: 59,
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_composition(&graph, problem.clone()).unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        other => panic!("recursive projected product is not solved: {other:?}"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let cause = |path: &str| OutcomeCause::ValueContract {
        origin: Origin {
            source: SourceIdentity {
                repository: "semantic-composition-execution-test".into(),
                revision: "1".into(),
                path: path.into(),
                content_digest: "f".repeat(64),
            },
            locator: vec!["success".into()],
        },
    };
    let composition = signature_composition_from_native(
        &library,
        &problem,
        checked.raw(),
        &[
            (seed, vec![(outcome.clone(), cause("seed"))]),
            (assemble, vec![(outcome, cause("assemble"))]),
        ],
    )
    .unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}
#[test]
fn recursive_product_binding_projects_only_the_declared_goal() {
    let input = recursive_construction_generation();
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
struct Host{invalid:bool}
impl composed::Providers for Host {
    type Failure=();
    fn site_seed_seed(&mut self,input:composed::site_seed_seed_Input,resources:&[composed::BoundResource])->Result<composed::site_seed_seed_Outcome,Self::Failure>{
        assert!(resources.is_empty());
        assert_eq!(input.content.0,"initial text");
        assert_eq!(input.amount.0,rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap());
        Ok(composed::site_seed_seed_Outcome::outcome_success(composed::site_seed_seed_outcome_success{
            output:inner{content:Some(rt::JsonValue::Str("produced text".into())),body:None,amount:Some(rt::JsonValue::Num(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()))},
        }))
    }
    fn site_assemble_assemble(&mut self,input:composed::site_assemble_assemble_Input,resources:&[composed::BoundResource])->Result<composed::site_assemble_assemble_Outcome,Self::Failure>{
        assert!(resources.is_empty());
        let Some(rt::JsonValue::Obj(members))=input.payload.payload else { panic!("nested construction missing"); };
        assert!(members.iter().any(|(key,value)|key=="content"&&value==&rt::JsonValue::Str("produced text".into())));
        assert!(members.iter().any(|(key,value)|key=="amount"&&matches!(value,rt::JsonValue::Num(number) if number.to_string()=="900719925474099312345678901234567890")));
        Ok(composed::site_assemble_assemble_Outcome::outcome_success(composed::site_assemble_assemble_outcome_success{
            output:inner{content:Some(if self.invalid { rt::JsonValue::Bool(true) } else { rt::JsonValue::Str("selected".into()) }),body:None,amount:Some(rt::JsonValue::Num(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()))},
        }))
    }
}
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let input=composed::CompositionInput{
        argument:text("initial text".into()),
        amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
    };
    let result=composed::execute(&context,input.clone(),&mut Host{invalid:false}).unwrap();
    assert!(matches!(result,composed::CompositionOutcome::Success(composed::CompositionOutput{selected:text(ref value)}) if value=="selected"));
    let invalid=composed::execute(&context,input,&mut Host{invalid:true}).unwrap_err();
    assert!(matches!(invalid,composed::CompositionFailure::Runtime{cause:rt::RuntimeFailure::Validation(_),..}));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn validate_guard_dispatches_accepted_and_rejected_values() {
    let input = validate_generation();
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
struct Host;
impl composed::Providers for Host { type Failure=(); }
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let accepted=composed::execute(&context,composed::CompositionInput{argument:Some(text("valid".into()))},&mut Host).unwrap();
    assert!(matches!(accepted,composed::CompositionOutcome::Success(composed::CompositionOutput{result:text(ref value)}) if value=="valid"));
    let rejected=composed::execute(&context,composed::CompositionInput{argument:None},&mut Host).unwrap();
    assert!(matches!(rejected,composed::CompositionOutcome::DeclaredFailure(composed::DeclaredFailure::failure_rejected(None))));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn variant_generation() -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let contract = slot(&library, "variant", true, false);
    let guard_id = GuardId("variants".into());
    let input = CompositionInput {
        identity: "variant-guard".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: contract.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: slot(&library, "sealed", true, false),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: vec![PathStep::Variant("sealed".into())],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "variant-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![PermittedProjection {
                source_type: contract.type_ref.clone(),
                path: vec![PathStep::Variant("sealed".into())],
            }],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![DeclaredGuard {
                id: guard_id.clone(),
                source_type: contract.type_ref.clone(),
                path: vec![],
                kind: GuardKind::Variants,
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: 59,
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_composition(&graph, input.clone()).unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        other => panic!("variant guard is not solved: {other:?}"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    assert!(matches!(
        &checked.raw().plan.root.node,
        PlanNode::Guard { guard, .. } if guard == &guard_id
    ));
    let composition =
        signature_composition_from_native(&library, &input, checked.raw(), &[]).unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

#[test]
fn variants_guard_selects_the_declared_tag_branch() {
    let input = variant_generation();
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
struct Host;
impl composed::Providers for Host { type Failure=(); }
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let value=variant::sealed(rt::JsonValue::Obj(vec![]));
    let result=composed::execute(&context,composed::CompositionInput{argument:value.clone()},&mut Host).unwrap();
    assert!(matches!(result,composed::CompositionOutcome::Success(composed::CompositionOutput{result:sealed(_)})));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn native_type_named_composition_output_compiles_inside_generated_module() {
    let input = presence_generation_for("CompositionOutput");
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
struct Host;
impl composed::Providers for Host { type Failure=(); }
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let argument=CompositionOutput("valid".into());
    let result=composed::execute(&context,composed::CompositionInput{argument:Some(rt::Nullable::Value(argument))},&mut Host).unwrap();
    assert!(matches!(result,composed::CompositionOutcome::Success(_)));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn integer_codec_generation() -> SignatureGenerationInput {
    let mut declaration = library();
    let profile_reference = declaration.profile.reference.clone();
    declaration.profile.integer_domains = vec![
        IntegerDomainBinding {
            name: "integer".into(),
            reference: profile_reference.clone(),
            range: IntegerDomain::Unbounded,
            forms: vec![
                IntegerForm::Number,
                IntegerForm::IntegralDecimal,
                IntegerForm::DecimalString,
            ],
        },
        IntegerDomainBinding {
            name: "number-only".into(),
            reference: profile_reference.clone(),
            range: IntegerDomain::Unbounded,
            forms: vec![IntegerForm::Number],
        },
        IntegerDomainBinding {
            name: "integral-only".into(),
            reference: profile_reference.clone(),
            range: IntegerDomain::Unbounded,
            forms: vec![IntegerForm::IntegralDecimal],
        },
        IntegerDomainBinding {
            name: "string-only".into(),
            reference: profile_reference.clone(),
            range: IntegerDomain::Unbounded,
            forms: vec![IntegerForm::DecimalString],
        },
        IntegerDomainBinding {
            name: "limited".into(),
            reference: profile_reference,
            range: IntegerDomain::Inclusive {
                minimum: (-10).into(),
                maximum: 10.into(),
            },
            forms: vec![IntegerForm::Number],
        },
    ];
    declaration.profile.default_integer_domain = "integer".into();
    for (id, domain) in [
        ("integer_number", "number-only"),
        ("integer_integral", "integral-only"),
        ("integer_string", "string-only"),
        ("integer_combined", "integer"),
        ("integer_limited", "limited"),
    ] {
        declaration.nodes.push(TypeNodeInput {
            id: id.into(),
            shape: Shape::Integer(IntegerSpec {
                domain: Some(domain.into()),
                minimum: None,
                maximum: None,
                const_value: None,
                enum_values: None,
                default_value: None,
            }),
        });
    }
    declaration.nodes.push(TypeNodeInput {
        id: "integer_projected".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: None,
            maximum: None,
            const_value: Some(1000.into()),
            enum_values: None,
            default_value: None,
        }),
    });
    declaration.nodes.push(TypeNodeInput {
        id: "decimal_source".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "amount".into(),
                slot: SignatureSlot {
                    type_id: "integer_projected".into(),
                    required: true,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let library = Arc::new(declaration);
    let graph = check_type_signatures(&library).unwrap();
    let integral = slot(&library, "integer_integral", true, false);
    let projected_contract = slot(&library, "integer_projected", true, false);
    let product = slot(&library, "decimal_source", true, false);
    let function = FunctionRef {
        identity: "decode".into(),
        revision: "1".into(),
        content_digest: "9".repeat(64),
    };
    let site = SiteId("decode".into());
    let outcome = OutcomeId("success".into());
    let projected = PortId("projected".into());
    let supplied = PortId("supplied".into());
    let problem = CompositionInput {
        identity: "domain-aware-integer-composition".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![FunctionSignature {
            reference: function.clone(),
            form: FunctionForm::DeclaredTransform,
            effect: CompositionEffect::PureFunction,
            inputs: vec![
                InputPort {
                    id: projected.clone(),
                    contract: projected_contract.clone(),
                    source_constraint: SourceConstraint::InitialOnly {
                        input: InputId("argument".into()),
                        path: vec![PathStep::Field("amount".into())],
                    },
                    resource_requirement: None,
                },
                InputPort {
                    id: supplied.clone(),
                    contract: integral.clone(),
                    source_constraint: SourceConstraint::InitialOnly {
                        input: InputId("supplied".into()),
                        path: vec![],
                    },
                    resource_requirement: None,
                },
            ],
            outcomes: vec![OutcomeContract {
                id: outcome.clone(),
                form: necoherence::semantic_composition::OutcomeForm::Success,
                value_ports: vec![
                    OutputPort {
                        id: projected.clone(),
                        contract: projected_contract.clone(),
                        resource_production: None,
                    },
                    OutputPort {
                        id: supplied.clone(),
                        contract: projected_contract.clone(),
                        resource_production: None,
                    },
                ],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "integer codec test".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![
            InitialInput {
                id: InputId("argument".into()),
                contract: product,
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("supplied".into()),
                contract: integral.clone(),
                source: InitialSource::SuppliedValue(SlotValue::Present(JsonValue::Dec(
                    "1e3".into(),
                ))),
                resource: None,
            },
        ],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![
                GoalPort {
                    id: GoalPortId("projected".into()),
                    contract: projected_contract.clone(),
                    source_constraint: SourceConstraint::ProducedBy {
                        site: site.clone(),
                        outcome: outcome.clone(),
                        port: projected.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("supplied".into()),
                    contract: projected_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: site.clone(),
                        outcome: outcome.clone(),
                        port: supplied.clone(),
                        path: vec![],
                    },
                },
            ],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "integer-domain".into(),
            revision: "1".into(),
            sites: vec![InvocationSite {
                id: site.clone(),
                function: function.clone(),
            }],
            permitted_projections: vec![PermittedProjection {
                source_type: signature_type_ref(
                    &library,
                    &canonical_digest(&library),
                    "decimal_source",
                ),
                path: vec![PathStep::Field("amount".into())],
            }],
            permitted_constructions: vec![],
            permitted_transforms: vec![function.clone()],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: 59,
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_composition(&graph, problem.clone()).unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        other => panic!("integer composition is not solved: {other:?}"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let cause = OutcomeCause::ValueContract {
        origin: Origin {
            source: SourceIdentity {
                repository: "semantic-composition-execution-test".into(),
                revision: "1".into(),
                path: "decode".into(),
                content_digest: "a".repeat(64),
            },
            locator: vec!["success".into()],
        },
    };
    let composition = signature_composition_from_native(
        &library,
        &problem,
        checked.raw(),
        &[(function, vec![(outcome, cause)])],
    )
    .unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

#[test]
fn integer_ports_preserve_integral_decimal_projection_and_declared_forms() {
    let input = integer_codec_generation();
    let generated = necoherence_tools::renderer::render_generation(&input).unwrap();
    let runner = r#"
struct Host;
impl composed::Providers for Host {
    type Failure=();
    fn site_decode_decode(&mut self,input:composed::site_decode_decode_Input,resources:&[composed::BoundResource])->Result<composed::site_decode_decode_Outcome,Self::Failure>{
        assert!(resources.is_empty());
        assert_eq!(input.projected.0,rt::BigInt::from(1000u32));
        assert_eq!(input.supplied.0,rt::BigInt::from(1000u32));
        Ok(composed::site_decode_decode_Outcome::outcome_success(composed::site_decode_decode_outcome_success{
            projected:integer_projected(input.projected.0),
            supplied:integer_projected(input.supplied.0),
        }))
    }
}
fn main(){
    let generation=generation_context().unwrap();
    let context=Context::new(&generation);
    let input=composed::CompositionInput{
        argument:decimal_source{amount:Some(rt::JsonValue::Dec("1e3".into()))},
    };
    let output=composed::execute(&context,input,&mut Host).unwrap();
    assert!(matches!(output,composed::CompositionOutcome::Success(composed::CompositionOutput{projected:integer_projected(ref projected),supplied:integer_projected(ref supplied)}) if projected==&rt::BigInt::from(1000u32) && supplied==&rt::BigInt::from(1000u32)));

    let values=[
        rt::BigInt::from(0u8),
        rt::BigInt::from(-42i32),
        rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap(),
    ];
    for value in values {
        let number=integer_number(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&number,rt::JsonValue::Num(encoded) if encoded==&value));
        assert_eq!(integer_number::read_wire(&context,number).unwrap().0,value);
        let decimal=integer_integral(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&decimal,rt::JsonValue::Dec(_)));
        assert_eq!(integer_integral::read_wire(&context,decimal).unwrap().0,value);
        let string=integer_string(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&string,rt::JsonValue::Str(_)));
        assert_eq!(integer_string::read_wire(&context,string).unwrap().0,value);
        let combined=integer_combined(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&combined,rt::JsonValue::Num(_)));
        assert_eq!(integer_combined::read_wire(&context,combined).unwrap().0,value);
    }

    assert!(matches!(
        integer_number::read_wire(&context,rt::JsonValue::Dec("1e3".into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    assert!(matches!(
        integer_integral::read_wire(&context,rt::JsonValue::Num(3.into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    assert!(matches!(
        integer_integral::read_wire(&context,rt::JsonValue::Dec("1.5".into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    assert!(matches!(
        integer_limited(rt::BigInt::from(11)).write_wire(&context),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    let named=integer_string::read_wire(&context,rt::JsonValue::Str("-42".into())).unwrap();
    assert_eq!(named.0,rt::BigInt::from(-42i32));
    assert!(matches!(
        integer_string::read_wire(&context,rt::JsonValue::Num((-42).into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}
