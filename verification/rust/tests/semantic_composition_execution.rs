// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_composition_solver::composition_search::derive;
use necoherence_composition_solver::{closure::*, document::*, verification::*};
use num_bigint::BigUint;
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
        sources: [
            ("transform", "d"),
            ("seed", "f"),
            ("assemble", "f"),
            ("decode", "a"),
        ]
        .into_iter()
        .map(|(path, digest)| SourceIdentity {
            repository: "semantic-composition-execution-test".into(),
            revision: "1".into(),
            path: path.into(),
            content_digest: digest.repeat(64),
        })
        .collect(),
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

fn slot(id: &str, required: bool, nullable: bool) -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref(id),
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
    let optional_text = slot(type_id, false, true);
    let required_text = slot(type_id, true, false);
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
                source_type: signature_type_ref(type_id),
                path: vec![],
                kind: GuardKind::Presence,
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };

    let prepared = prepare_direct_composition(
        &graph,
        input.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("presence composition is not solved"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let composition =
        signature_composition_from_native(&library, &input, checked.raw(), &[]).unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

fn validate_generation() -> SignatureGenerationInput {
    validate_generation_with(library(), "text")
}

fn validate_generation_with(
    declaration: TypeSignatureLibrary,
    target: &str,
) -> SignatureGenerationInput {
    let library = Arc::new(declaration);
    let graph = check_type_signatures(&library).unwrap();
    let optional = slot("text", false, false);
    let required = slot("text", true, false);
    let target_contract = slot(target, true, false);
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
                kind: GuardKind::Validate(target_contract),
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_direct_composition(
        &graph,
        input.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("validate guard is not solved"),
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
    let contract = slot("text", true, false);
    let body_contract = slot("raw_body", true, false);
    let amount_contract = slot("integer", true, false);
    let bytes_contract = slot("bytes", true, false);
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
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("two-site composition is not solved"),
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

const EXECUTE_ONCE: &str = "#[derive(Debug)] #[allow(dead_code)] enum ExecuteOnce{Execution(necoherence::semantic_execution::RunFailure),Pending}\n\
#[allow(unused_macros)] macro_rules! execute_once{($($module:ident)::*;$arguments:expr,$providers:expr)=>{{let generation=initialize().unwrap();let prepared=$($module::)*composed::prepare(&generation).unwrap();match $($module::)*composed::run(&prepared,$providers,$arguments,Default::default()){Ok($($module::)*composed::RunProgress::Completed(result,_))=>Ok(result),Ok(_)=>Err(ExecuteOnce::Pending),Err(failure)=>Err(ExecuteOnce::Execution(failure))}}}}";

fn compile_and_run(program: &str) -> std::process::Output {
    static NEXT_PROJECT: AtomicUsize = AtomicUsize::new(0);
    let sequence = NEXT_PROJECT.fetch_add(1, Ordering::Relaxed);
    let project = std::env::temp_dir().join(format!(
        "necoherence-composition-{}-{sequence}",
        std::process::id()
    ));
    std::fs::create_dir_all(project.join("src")).unwrap();
    let necoherence_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../packages/rust/adapter")
        .canonicalize()
        .unwrap();
    std::fs::write(
        project.join("Cargo.toml"),
        format!(
            "[package]\nname=\"generated-composition-consumer\"\nversion=\"0.0.0\"\nedition=\"2021\"\n\n[workspace]\n\n[dependencies]\nnecoherence={{path={necoherence_path:?}}}\n"
        ),
    )
    .unwrap();
    std::fs::write(
        project.join("src/main.rs"),
        format!("{EXECUTE_ONCE}\n{program}\n"),
    )
    .unwrap();
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
    let full = render_admitted(&input);
    let fragment = rust_fragment(&input, &document);
    assert!(full.ends_with(&fragment));
    assert_eq!(fragment, rust_fragment(&input, &document));
    assert!(!fragment.contains("CompositionContinuation"));
    let program = format!(
        r#"{full}
struct Owner;
impl composed::Providers for Owner {{
    }}
fn main() {{
    let present=execute_once!(; composed::Arguments{{argument:Some(rt::Nullable::Value(text("valid".into())))}},Owner).unwrap();
    assert!(matches!(present,composed::Result::Success(composed::Success{{result:text(ref value)}}) if value=="valid"));
    let absent=execute_once!(; composed::Arguments{{argument:None}},Owner).unwrap();
    assert!(matches!(absent,composed::Result::Failure0(None)));
    let null=execute_once!(; composed::Arguments{{argument:Some(rt::Nullable::Null)}},Owner).unwrap();
    assert!(matches!(null,composed::Result::Failure1(Some(rt::Nullable::Null))));
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
    let full = render_admitted(&input);
    let fragment_a = rust_fragment(&input, &document);
    let fragment_b = rust_fragment(&input, &document);
    let types = full.strip_suffix(&fragment_a).unwrap();
    let source = format!(
        "{types}\npub mod recipe_a{{use super::*;{fragment_a}}}\npub mod recipe_b{{use super::*;{fragment_b}}}\n\
         struct Host;\n\
         impl recipe_a::composed::Providers for Host{{}}\n\
         impl recipe_b::composed::Providers for Host{{}}\n\
         fn main(){{let value=text(\"shared\".into());\
         let a=execute_once!(recipe_a; recipe_a::composed::Arguments{{argument:Some(rt::Nullable::Value(value.clone()))}},Host).unwrap();\
         let b=execute_once!(recipe_b; recipe_b::composed::Arguments{{argument:Some(rt::Nullable::Value(value))}},Host).unwrap();\
         assert!(matches!(a,recipe_a::composed::Result::Success(_)));\
         assert!(matches!(b,recipe_b::composed::Result::Success(_)));}}\n"
    );
    assert_eq!(source.matches("pub struct text").count(), 1);
    compile_and_run(&source);
}

#[test]
fn two_sites_preserve_provider_failure_and_repeated_runs() {
    let input = two_site_generation(necoherence::typed_mapping::BindingMode::Consume);
    let generated = render_admitted(&input);
    let runner = r#"
struct Host { calls: std::rc::Rc<std::cell::Cell<usize>>, fail_first: bool }
impl composed::Providers for Host {
    fn call_0(&mut self,input:composed::Function0Input)->std::result::Result<composed::Function0Outcome,necoherence::semantic_execution::ExecutionFailure>{
        assert_eq!(input.input.0,"start");
        assert_eq!(input.body.0.data,vec![0,128,255]);
        assert_eq!(input.octets.0.data,vec![0,128,255]);
        assert_eq!(input.amount.0,rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap());
        let calls=self.calls.get()+1;
        self.calls.set(calls);
        if self.fail_first { return Err(necoherence::semantic_execution::ExecutionFailure::Provider(necoherence::semantic_composition::SiteId("first".into()),"opaque host failure".into())); }
        Ok(composed::Function0Outcome::Outcome0(composed::Function0Outcome0{value:text((if calls==1{"middle"}else{"done"}).into()),body:raw_body(vec![0,128,255].into()),amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),octets:bytes(vec![0,128,255].into())}))
    }
}
fn main(){
    let input=composed::Arguments{argument:text("start".into()),body:raw_body(vec![0,128,255].into()),amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),octets:bytes(vec![0,128,255].into())};
    let calls=std::rc::Rc::new(std::cell::Cell::new(0usize));
    let result=execute_once!(; input.clone(),Host{calls:calls.clone(),fail_first:false}).unwrap();
    assert_eq!(calls.get(),2);
    assert!(matches!(result,composed::Result::Success(composed::Success{result:text(ref value),body_result:raw_body(ref body_bytes),amount_result:integer(ref large_amount),octets_result:bytes(ref exact_bytes)}) if value=="done" && body_bytes.data==vec![0,128,255] && exact_bytes.data==vec![0,128,255] && large_amount==&rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()));
    let failing_calls=std::rc::Rc::new(std::cell::Cell::new(0usize));
    let error=execute_once!(; input.clone(),Host{calls:failing_calls.clone(),fail_first:true}).unwrap_err();
    assert_eq!(failing_calls.get(),1);
    assert!(matches!(error,ExecuteOnce::Execution(necoherence::semantic_execution::RunFailure{cause:necoherence::semantic_execution::ExecutionFailure::Provider(ref site,ref message),..}) if site.0=="first" && message=="opaque host failure"));
    let again=execute_once!(; input,Host{calls:calls.clone(),fail_first:false}).unwrap();
    assert!(matches!(again,composed::Result::Success(composed::Success{result:text(ref value),..}) if value=="done"));
    assert_eq!(calls.get(),4);
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn read_resource_bindings_preserve_lot_quantity_at_both_sites() {
    let input = two_site_generation(necoherence::typed_mapping::BindingMode::Read);
    let generated = render_admitted(&input);
    let runner = r#"
struct Host{calls:std::rc::Rc<std::cell::Cell<usize>>}
impl composed::Providers for Host {
    fn call_0(&mut self,input:composed::Function0Input)->std::result::Result<composed::Function0Outcome,necoherence::semantic_execution::ExecutionFailure>{
        assert_eq!(input.octets.0.data,vec![0,128,255]);
        let calls=self.calls.get()+1;
        self.calls.set(calls);
        Ok(composed::Function0Outcome::Outcome0(composed::Function0Outcome0{
            value:text((if calls==1{"first"}else{"second"}).into()),body:raw_body(vec![0,128,255].into()),
            amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
            octets:bytes(vec![0,128,255].into()),
        }))
    }
}
fn main(){
    let input=composed::Arguments{
        argument:text("start".into()),body:raw_body(vec![0,128,255].into()),
        amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
        octets:bytes(vec![0,128,255].into()),
    };
    let calls=std::rc::Rc::new(std::cell::Cell::new(0usize));
    let result=execute_once!(; input.clone(),Host{calls:calls.clone()}).unwrap();
    assert_eq!(calls.get(),2);
    assert!(matches!(result,composed::Result::Success(composed::Success{result:text(ref value),body_result:raw_body(ref body_bytes),amount_result:integer(ref amount),octets_result:bytes(ref octets)}) if value=="second" && body_bytes.data==vec![0,128,255] && octets.data==vec![0,128,255] && amount==&rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()));
    let again=execute_once!(; input,Host{calls:calls.clone()}).unwrap();
    assert!(matches!(again,composed::Result::Success(composed::Success{result:text(ref value),..}) if value=="second"));
    assert_eq!(calls.get(),4);
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn recursive_construction_generation() -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let text = slot("text", true, false);
    let amount = slot("integer", true, false);
    let outer = slot("outer", true, false);
    let inner = slot("inner", true, false);
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
    let type_ref = |id: &str| signature_type_ref(id);
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
                contract: slot("text", true, false),
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
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("recursive projected product is not solved"),
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
    let generated = render_admitted(&input);
    let runner = r#"
struct Host{invalid:bool}
impl composed::Providers for Host {
    fn call_0(&mut self,input:composed::Function0Input)->std::result::Result<composed::Function0Outcome,necoherence::semantic_execution::ExecutionFailure>{
        assert_eq!(input.content.0,"initial text");
        assert_eq!(input.amount.0,rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap());
        Ok(composed::Function0Outcome::Outcome0(composed::Function0Outcome0{
            output:inner{content:Some(rt::JsonValue::Str("produced text".into())),body:None,amount:Some(rt::JsonValue::Num(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()))},
        }))
    }
    fn call_1(&mut self,input:composed::Function1Input)->std::result::Result<composed::Function1Outcome,necoherence::semantic_execution::ExecutionFailure>{
        let Some(rt::JsonValue::Obj(members))=&input.payload.payload else { panic!("nested construction missing"); };
        assert!(members.iter().any(|(key,value)|key=="content"&&value==&rt::JsonValue::Str("produced text".into())));
        assert!(members.iter().any(|(key,value)|key=="amount"&&matches!(value,rt::JsonValue::Num(number) if number.to_string()=="900719925474099312345678901234567890")));
        Ok(composed::Function1Outcome::Outcome0(composed::Function1Outcome0{
            output:inner{content:Some(if self.invalid { rt::JsonValue::Bool(true) } else { rt::JsonValue::Str("selected".into()) }),body:None,amount:Some(rt::JsonValue::Num(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()))},
        }))
    }
}
fn main(){
    let generation=initialize().unwrap();
    let input=composed::Arguments{
        argument:text("initial text".into()),
        amount:integer(rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap()),
    };
    let result=execute_once!(; input.clone(),Host{invalid:false}).unwrap();
    assert!(matches!(result,composed::Result::Success(composed::Success{selected:text(ref value)}) if value=="selected"));
    let invalid=execute_once!(; input,Host{invalid:true}).unwrap_err();
    let graph=generation.graph();
    let text_ref=graph.nodes.iter().find(|node|node.reference.definition_name.as_ref()=="text").unwrap().reference.clone();
    let inner_ref=graph.nodes.iter().find(|node|node.reference.definition_name.as_ref()=="inner").unwrap().reference.clone();
    let expected=necoherence::semantic_types::ValueFailure{
        type_ref:text_ref.clone(),
        definition_ref:necoherence::semantic_types::DefinitionRef{source:text_ref.source.clone(),name:text_ref.definition_name.clone()},
        origin:(&text_ref).into(),
        value_path:vec![necoherence::semantic_types::PathStep::Field("content".into())],
        condition:necoherence::semantic_types::ValueCondition::WrongValueKind("string".into()),
        observed:necoherence::semantic_types::SlotValue::Present(rt::JsonValue::Bool(true)),
        reference_trace:vec![inner_ref],
    };
    assert!(matches!(invalid,ExecuteOnce::Execution(necoherence::semantic_execution::RunFailure{cause:necoherence::semantic_execution::ExecutionFailure::Value(necoherence::semantic_execution::ValidationFailure::Value(ref failure)),..}) if failure==&expected));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn validate_guard_dispatches_accepted_and_rejected_values() {
    let input = validate_generation();
    let generated = render_admitted(&input);
    let runner = r#"
struct Host;
impl composed::Providers for Host { }
fn main(){
    let accepted=execute_once!(; composed::Arguments{argument:Some(text("valid".into()))},Host).unwrap();
    assert!(matches!(accepted,composed::Result::Success(composed::Success{result:text(ref value)}) if value=="valid"));
    let rejected=execute_once!(; composed::Arguments{argument:None},Host).unwrap();
    assert!(matches!(rejected,composed::Result::Failure0(None)));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn variant_generation() -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let contract = slot("variant", true, false);
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
                contract: slot("sealed", true, false),
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
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_direct_composition(
        &graph,
        input.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("variant guard is not solved"),
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
    let generated = render_admitted(&input);
    let runner = r#"
struct Host;
impl composed::Providers for Host { }
fn main(){
    let value=variant::sealed(rt::JsonValue::Obj(vec![]));
    let result=execute_once!(; composed::Arguments{argument:value.clone()},Host).unwrap();
    assert!(matches!(result,composed::Result::Success(composed::Success{result:sealed(_)})));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn native_type_named_composition_output_compiles_inside_generated_module() {
    let input = presence_generation_for("CompositionOutput");
    let generated = render_admitted(&input);
    let runner = r#"
struct Host;
impl composed::Providers for Host { }
fn main(){
    let argument=CompositionOutput("valid".into());
    let result=execute_once!(; composed::Arguments{argument:Some(rt::Nullable::Value(argument))},Host).unwrap();
    assert!(matches!(result,composed::Result::Success(_)));
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
    let integral = slot("integer_integral", true, false);
    let projected_contract = slot("integer_projected", true, false);
    let product = slot("decimal_source", true, false);
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
                source_type: signature_type_ref("decimal_source"),
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
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("integer composition is not solved"),
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
    let generated = render_admitted(&input);
    let runner = r#"
struct Host;
impl composed::Providers for Host {
    fn call_0(&mut self,input:composed::Function0Input)->std::result::Result<composed::Function0Outcome,necoherence::semantic_execution::ExecutionFailure>{
        assert_eq!(input.projected.0,rt::BigInt::from(1000u32));
        assert_eq!(input.supplied.0,rt::BigInt::from(1000u32));
        Ok(composed::Function0Outcome::Outcome0(composed::Function0Outcome0{
            projected:integer_projected(input.projected.0),
            supplied:integer_projected(input.supplied.0),
        }))
    }
}
fn read_checked<T:WireValue>(cx:&Context<'_>,value:rt::JsonValue)->Result<T,rt::RuntimeFailure>{cx.checked_for::<T>(value).and_then(|value|T::read_wire(cx,value))}
fn main(){
    let generation=initialize().unwrap();
    let context=Context::new(&generation);
    let input=composed::Arguments{
        argument:decimal_source{amount:Some(rt::JsonValue::Dec("1e3".into()))},
    };
    let output=execute_once!(; input,Host).unwrap();
    assert!(matches!(output,composed::Result::Success(composed::Success{projected:integer_projected(ref projected),supplied:integer_projected(ref supplied)}) if projected==&rt::BigInt::from(1000u32) && supplied==&rt::BigInt::from(1000u32)));
    let values=[
        rt::BigInt::from(0u8),
        rt::BigInt::from(-42i32),
        rt::BigInt::parse_bytes(b"900719925474099312345678901234567890",10).unwrap(),
    ];
    for value in values {
        let number=integer_number(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&number,rt::JsonValue::Num(encoded) if encoded==&value));
        assert_eq!(read_checked::<integer_number>(&context,number).unwrap().0,value);
        let decimal=integer_integral(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&decimal,rt::JsonValue::Dec(_)));
        assert_eq!(read_checked::<integer_integral>(&context,decimal).unwrap().0,value);
        let string=integer_string(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&string,rt::JsonValue::Str(_)));
        assert_eq!(read_checked::<integer_string>(&context,string).unwrap().0,value);
        let combined=integer_combined(value.clone()).write_wire(&context).unwrap();
        assert!(matches!(&combined,rt::JsonValue::Num(_)));
        assert_eq!(read_checked::<integer_combined>(&context,combined).unwrap().0,value);
    }

    assert!(matches!(
        read_checked::<integer_number>(&context,rt::JsonValue::Dec("1e3".into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    assert!(matches!(
        read_checked::<integer_integral>(&context,rt::JsonValue::Num(3.into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    assert!(matches!(
        read_checked::<integer_integral>(&context,rt::JsonValue::Dec("1.5".into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    assert!(matches!(
        integer_limited(rt::BigInt::from(11)).write_wire(&context),
        Err(rt::RuntimeFailure::Validation(_))
    ));
    let named=read_checked::<integer_string>(&context,rt::JsonValue::Str("-42".into())).unwrap();
    assert_eq!(named.0,rt::BigInt::from(-42i32));
    assert!(matches!(
        read_checked::<integer_string>(&context,rt::JsonValue::Num((-42).into())),
        Err(rt::RuntimeFailure::Validation(_))
    ));
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

#[test]
fn integer_wire_text_reads_follow_lean_validated_decode() {
    let input = integer_codec_generation();
    let generated = render_admitted(&input);
    let runner = r#"
fn read_checked<T:WireValue>(cx:&Context<'_>,value:rt::JsonValue)->Result<T,rt::RuntimeFailure>{cx.checked_for::<T>(value).and_then(|value|T::read_wire(cx,value))}
fn read_each(context:&Context<'_>,wire_text:&str)->[Option<rt::BigInt>;5]{
    let value=|| rt::decode_json(wire_text).unwrap();
    [
        read_checked::<integer_combined>(context,value()).ok().map(|value|value.0),
        read_checked::<integer_number>(context,value()).ok().map(|value|value.0),
        read_checked::<integer_integral>(context,value()).ok().map(|value|value.0),
        read_checked::<integer_string>(context,value()).ok().map(|value|value.0),
        read_checked::<integer_limited>(context,value()).ok().map(|value|value.0),
    ]
}
fn main(){
    let generation=initialize().unwrap();
    let context=Context::new(&generation);
    let cases:[(&str,[Option<i64>;5]);10]=[
        ("0.0",[Some(0),None,Some(0),None,None]),
        ("-0.0",[Some(0),None,Some(0),None,None]),
        ("1e1",[Some(10),Some(10),None,None,Some(10)]),
        ("1.0e1",[Some(10),Some(10),None,None,Some(10)]),
        ("10",[Some(10),Some(10),None,None,Some(10)]),
        ("1.5e1",[Some(15),Some(15),None,None,None]),
        ("0e11",[Some(0),Some(0),None,None,Some(0)]),
        ("0e-100",[Some(0),None,Some(0),None,None]),
        ("1.5",[None,None,None,None,None]),
        ("1.50e0",[None,None,None,None,None]),
    ];
    for (wire_text,expected) in cases {
        let actual=read_each(&context,wire_text);
        for (index,value) in expected.into_iter().enumerate() {
            assert_eq!(actual[index],value.map(rt::BigInt::from),"{wire_text} at column {index}");
        }
    }
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn generated_decode_allocations(filler: usize) -> usize {
    let mut declaration = library();
    for index in 0..filler {
        declaration.nodes.push(TypeNodeInput {
            id: format!("filler_{index}"),
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
    }
    let generated = render_admitted(&validate_generation_with(declaration, "text"));
    let runner = r#"
struct Counting;
static ALLOCATIONS:std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);
unsafe impl std::alloc::GlobalAlloc for Counting{
    unsafe fn alloc(&self,layout:std::alloc::Layout)->*mut u8{ALLOCATIONS.fetch_add(1,std::sync::atomic::Ordering::SeqCst);std::alloc::System.alloc(layout)}
    unsafe fn dealloc(&self,pointer:*mut u8,layout:std::alloc::Layout){std::alloc::System.dealloc(pointer,layout)}
}
#[global_allocator]
static COUNTING:Counting=Counting;
fn main(){
    let generation=initialize().unwrap();
    let context=Context::new(&generation);
    let reference=graph(&generation).nodes.iter().find(|node|node.reference.definition_name.as_ref()=="text").unwrap().reference.clone();
    let decoded=decode::<text>(&context,&reference,"\"abc\"").unwrap();
    assert!(decoded.0=="abc");
    let before=ALLOCATIONS.load(std::sync::atomic::Ordering::SeqCst);
    for _ in 0..16 {
        let decoded=decode::<text>(&context,&reference,"\"abc\"").unwrap();
        assert!(decoded.0=="abc");
    }
    let after=ALLOCATIONS.load(std::sync::atomic::Ordering::SeqCst);
    println!("decode_allocations={}",after-before);
}
"#;
    let output = compile_and_run(&format!("{generated}\n{runner}"));
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| line.strip_prefix("decode_allocations="))
        .unwrap()
        .parse()
        .unwrap()
}

#[test]
fn generated_code_does_not_scan_graph_nodes_per_validation() {
    let generated = render_admitted(&validate_generation());
    assert!(!generated.contains("graph.nodes.iter().find("));
    assert!(!generated.contains("self.graph.nodes.iter()"));
}

#[test]
fn generated_decode_allocations_do_not_scale_with_library_types() {
    let small = generated_decode_allocations(20);
    let large = generated_decode_allocations(200);
    println!("generated decode allocations: small={small} large={large}");
    assert_eq!(small, large);
}

#[test]
fn named_format_validation_does_not_leak_between_runs() {
    let mut declaration = library();
    let reference = declaration.profile.reference.clone();
    declaration.profile.format_bindings.push(FormatBinding {
        name: "memo-literal".into(),
        reference,
        rule: FormatRule::Literal("ab".into()),
    });
    let Shape::String(spec) = &mut declaration
        .nodes
        .iter_mut()
        .find(|node| node.id == "text")
        .unwrap()
        .shape
    else {
        panic!("text declaration is not String")
    };
    spec.format = Some(FormatUse::Named("memo-literal".into()));
    spec.examples = vec!["ab".into()];
    let generation = validate_generation_with(declaration, "text");
    let generated = render_admitted(&generation);
    let runner = r#"
struct Host;
impl composed::Providers for Host { }
fn main() {
    for _round in 0..2 {
        for input in ["cd","ab","cd"] {
            let result=execute_once!(; composed::Arguments{argument:Some(text(input.into()))},Host);
            if input=="ab" {
                assert!(matches!(result,Ok(composed::Result::Success(composed::Success{result:text(ref value)})) if value=="ab"));
            } else {
                assert!(matches!(result,Err(ExecuteOnce::Execution(necoherence::semantic_execution::RunFailure{cause:necoherence::semantic_execution::ExecutionFailure::Value(necoherence::semantic_execution::ValidationFailure::Value(_)),..}))));
            }
        }
        let absent=execute_once!(; composed::Arguments{argument:None},Host).unwrap();
        assert!(matches!(absent,composed::Result::Failure0(None)));
    }
}
"#;
    compile_and_run(&format!("{generated}\n{runner}"));
}

fn refresh_basis(input: &mut SignatureGenerationInput) {
    input.basis = signature_basis(
        &input.signatures,
        input.composition.as_ref(),
        &input.entrypoints,
    )
    .unwrap();
}

#[test]
fn embedded_composition_with_rejected_goal_is_rejected_at_admission() {
    let mut input = presence_generation();
    let derivation = &mut input.composition.as_mut().unwrap()["derivation"];
    *derivation.pointer_mut("/plan/root/node").unwrap() =
        serde_json::json!({"tag":"Return","value":{"tag":"Success","value":[]}});
    refresh_basis(&mut input);
    let failure = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    )
    .err();
    let rendered = format!("{failure:?}");
    assert!(
        matches!(failure, Some(AdmissionFailure::Certificate(_)))
            && rendered.contains("observations: Mismatched")
            && rendered.matches("Mismatched").count() == 1,
        "{rendered}"
    );
}

#[test]
fn admitted_validate_guard_refuses_undefined_meaning_with_origin() {
    let mut declaration = library();
    let shape = declaration
        .nodes
        .iter()
        .find(|node| node.id == "text")
        .unwrap()
        .shape
        .clone();
    declaration.nodes.push(TypeNodeInput {
        id: "checked_text".into(),
        shape,
    });
    let primary = validate_generation_with(declaration.clone(), "checked_text");
    let primary_context = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&primary),
        primary.clone(),
    )
    .unwrap();
    let (composition, derivation) =
        necoherence_composition_solver::wire_admission::verified_signature_derivation(
            &primary,
            primary_context.graph(),
        )
        .ok()
        .flatten()
        .unwrap();

    let mut alternate_declaration = declaration;
    alternate_declaration
        .nodes
        .iter_mut()
        .find(|node| node.id == "checked_text")
        .unwrap()
        .shape = Shape::Opaque {
        type_name: "guard target".into(),
    };
    alternate_declaration.definitions.push(DefinitionInput {
        id: "checked_text".into(),
        wire_identity: "checked_text".into(),
        shape: SignatureDefinitionShape::Value("checked_text".into()),
    });
    let alternate = assemble_signature_generation(
        alternate_declaration,
        None,
        vec![SignatureEntrypoint {
            identity: "entry".into(),
            definition: "checked_text".into(),
        }],
    )
    .unwrap();
    let alternate_document = encode_signature_generation(&alternate).unwrap();
    let alternate_context = signature_generation_context(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&alternate),
        &alternate_document,
    )
    .unwrap();
    let graph = alternate_context.graph();
    let target = graph
        .nodes
        .iter()
        .find(|node| node.reference.definition_name.as_ref() == "checked_text")
        .unwrap()
        .reference
        .clone();
    let expected = SemanticObligation {
        type_ref: target.clone(),
        origin: OccurrenceRef::from(&target),
        value_path: vec![],
        profile: graph.profile.reference.clone(),
        reason: SemanticReason::OpaqueType("guard target".into()),
    };

    let prepared = prepare_direct_composition(
        graph,
        composition.problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(graph),
    )
    .unwrap();
    let refusal = verify_composition(&prepared, &derivation);
    assert!(matches!(
        refusal,
        Err(WitnessFailure::Inclusion(InclusionFailure::UndefinedMeaning(ref obligations)))
            if obligations == &vec![expected.clone()]
    ));
}

fn rust_fragment(input: &SignatureGenerationInput, document: &str) -> String {
    let source = necoherence_generator::renderer::render_signature_exchange_for(
        &necoherence_generator::renderer::Target::Rust,
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(input),
        document,
    )
    .unwrap();
    let start = source.rfind("pub mod composed{").unwrap();
    source[start..].to_owned()
}

fn render_admitted(input: &SignatureGenerationInput) -> String {
    let document = encode_signature_generation(input).unwrap();
    necoherence_generator::renderer::render_signature_exchange_for(
        &necoherence_generator::renderer::Target::Rust,
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(input),
        &document,
    )
    .unwrap()
}
