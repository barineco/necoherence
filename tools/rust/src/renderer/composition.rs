// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::{field_name, name, RenderFailure};
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::GenerationContext;
use necoherence::semantic_types::{PathStep, SlotContract, SlotValue, TypeRef, TypeShape};
use std::collections::HashSet;

type Result<T> = std::result::Result<T, RenderFailure>;

fn invalid(message: &str) -> RenderFailure {
    RenderFailure::InvalidCheckedPlan(message.into())
}
fn natural(value: &necoherence::core::Nat) -> String {
    format!("rt::BigUint::from_bytes_be(&{:?})", value.to_bytes_be())
}
fn reference(value: &TypeRef) -> String {
    format!("type_ref(cx,{:?})?", value.definition_name)
}
fn contract(value: &SlotContract) -> String {
    format!(
        "SlotContract{{type_ref:{},required:{},nullable:{}}}",
        reference(&value.type_ref),
        value.required,
        value.nullable
    )
}
fn native(value: &SlotContract) -> String {
    let ty = format!("super::{}", name(&value.type_ref.definition_name));
    let ty = if value.nullable {
        format!("rt::Nullable<{ty}>")
    } else {
        ty
    };
    if value.required {
        ty
    } else {
        format!("Option<{ty}>")
    }
}
fn path(value: &[PathStep]) -> String {
    let elements = value
        .iter()
        .map(|step| match step {
            PathStep::Field(field) => format!("PathStep::Field({field:?}.into())"),
            PathStep::Variant(tag) => format!("PathStep::Variant({tag:?}.into())"),
            PathStep::Index(index) => format!("PathStep::Index({})", natural(index)),
        })
        .collect::<Vec<_>>()
        .join(",");
    format!("vec![{elements}]")
}
fn producer(value: &ProducerRef) -> String {
    match value {
        ProducerRef::Initial(id) => format!("ProducerRef::Initial(InputId({:?}.into()))", id.0),
        ProducerRef::InvocationOutcome { site, outcome, port } => format!("ProducerRef::InvocationOutcome{{site:SiteId({:?}.into()),outcome:OutcomeId({:?}.into()),port:PortId({:?}.into())}}", site.0, outcome.0, port.0),
    }
}
fn value_ref(value: &ValueRef) -> String {
    format!(
        "ValueRef{{producer:{},path:{}}}",
        producer(&value.producer),
        path(&value.path)
    )
}
fn function_ref(value: &FunctionRef) -> String {
    format!(
        "FunctionRef{{identity:{:?}.into(),revision:{:?}.into(),content_digest:{:?}.into()}}",
        value.identity, value.revision, value.content_digest
    )
}
fn lot_ref(value: &ResourceLotRef) -> String {
    match value {
        ResourceLotRef::Initial(id) => format!("ResourceLotRef::Initial(LotId({:?}.into()))", id.0),
        ResourceLotRef::Produced { site, outcome, production } => format!("ResourceLotRef::Produced{{site:SiteId({:?}.into()),outcome:OutcomeId({:?}.into()),production:ProductionId({:?}.into())}}", site.0, outcome.0, production.0),
    }
}
fn resource_producer(value: &ResourceProducer) -> String {
    match value {
        ResourceProducer::Initial { identity, revision } => format!("ResourceProducer::Initial{{identity:{identity:?}.into(),revision:{revision:?}.into()}}"),
        ResourceProducer::InvocationOutcome { site, outcome } => format!("ResourceProducer::InvocationOutcome{{site:SiteId({:?}.into()),outcome:OutcomeId({:?}.into())}}", site.0, outcome.0),
    }
}
fn requirement(value: &ResourceRequirement) -> String {
    let identity = match &value.identity {
        ResourceIdentityConstraint::Any => "ResourceIdentityConstraint::Any".into(),
        ResourceIdentityConstraint::Exactly(value) => format!(
            "ResourceIdentityConstraint::Exactly({})",
            resource_producer(value)
        ),
    };
    format!("ResourceRequirement{{id:RequirementId({:?}.into()),token_type:{},mode:necoherence::typed_mapping::BindingMode::{:?},multiplicity:{},required_revision:{},identity:{identity}}}", value.id.0, reference(&value.token_type), value.mode, natural(&value.multiplicity), natural(&value.required_revision))
}
fn lot(value: &ResourceLot) -> String {
    format!("ResourceLot{{id:LotId({:?}.into()),token_type:{},producer:{},revision:{},quantity:{},provenance:{:?}.into()}}", value.id.0, reference(&value.token_type), resource_producer(&value.producer), natural(&value.revision), natural(&value.quantity), value.provenance)
}
fn arm(value: &GuardArm) -> String {
    match value {
        GuardArm::Variant(tag) => format!("GuardArm::Variant({tag:?}.into())"),
        other => format!("GuardArm::{other:?}"),
    }
}
fn guard(value: &DeclaredGuard) -> String {
    let kind = match &value.kind {
        GuardKind::Presence => "GuardKind::Presence".into(),
        GuardKind::Variants => "GuardKind::Variants".into(),
        GuardKind::Validate(slot) => format!("GuardKind::Validate({})", contract(slot)),
    };
    format!(
        "DeclaredGuard{{id:GuardId({:?}.into()),source_type:{},path:{},kind:{kind}}}",
        value.id.0,
        reference(&value.source_type),
        path(&value.path)
    )
}
fn supplied(value: &SlotValue) -> Result<String> {
    Ok(match value {
        SlotValue::Absent => "SlotValue::Absent".into(),
        SlotValue::Null => "SlotValue::Null".into(),
        SlotValue::Present(value) => {
            let text = necoherence::semantic_codegen_runtime::encode_json(value)
                .map_err(|failure| invalid(&format!("supplied value: {failure}")))?;
            format!("SlotValue::Present(rt::decode_json({text:?}).map_err(|cause|failure(cause,\"supplied input\",None))?)")
        }
    })
}
fn encode(value: &str, slot: &SlotContract) -> String {
    let present = if slot.nullable {
        "match value{rt::Nullable::Null=>SlotValue::Null,rt::Nullable::Value(value)=>SlotValue::Present(value.write_wire(cx).map_err(|cause|failure(cause,\"native output\",None))?)}".to_owned()
    } else {
        "SlotValue::Present(value.write_wire(cx).map_err(|cause|failure(cause,\"native output\",None))?)".into()
    };
    if slot.required {
        format!("{{let value={value};{present}}}")
    } else {
        format!("match {value}{{None=>SlotValue::Absent,Some(value)=>{present}}}")
    }
}
fn decode(value: &str, slot: &SlotContract) -> String {
    let ty = format!("super::{}", name(&slot.type_ref.definition_name));
    let present =
        format!("{ty}::read_wire(cx,value).map_err(|cause|failure(cause,\"native input\",None))?");
    let present = if slot.nullable {
        format!("rt::Nullable::Value({present})")
    } else {
        present
    };
    let present = if slot.required {
        present
    } else {
        format!("Some({present})")
    };
    let absent = if slot.required {
        "return Err(failure(rt::representation(\"required native port\"),\"native input\",None))"
    } else {
        "None"
    };
    let null = if slot.nullable {
        if slot.required {
            "rt::Nullable::Null"
        } else {
            "Some(rt::Nullable::Null)"
        }
    } else {
        "return Err(failure(rt::representation(\"non-null native port\"),\"native input\",None))"
    };
    format!("match {value}{{SlotValue::Absent=>{absent},SlotValue::Null=>{null},SlotValue::Present(value)=>{present}}}")
}
fn record(output: &mut String, id: &str, ports: &[(&str, &SlotContract)]) -> Result<()> {
    let mut names = HashSet::new();
    output.push_str(&format!(
        "#[derive(Debug,Clone,PartialEq)] pub struct {id}{{"
    ));
    for (port, slot) in ports {
        let field = field_name(port);
        if !names.insert(field.clone()) {
            return Err(invalid("generated port identifier collision"));
        }
        output.push_str(&format!("pub {field}:{},", native(slot)));
    }
    output.push_str("}\n");
    Ok(())
}
fn site_name(site: &InvocationSite) -> String {
    format!(
        "site_{}_{}",
        name(&site.id.0),
        name(&site.function.identity)
    )
}

struct Emitter<'a> {
    problem: &'a CompositionInput,
    context: &'a GenerationContext,
    next: usize,
}
impl Emitter<'_> {
    fn binding(&self, binding: &BindingExpr, destination: &SlotContract) -> Result<String> {
        let expression = match binding {
            BindingExpr::Source { value, .. } => format!("source(env,&{})?", value_ref(value)),
            BindingExpr::Product {
                type_ref, fields, ..
            } => {
                let graph = self.context.graph();
                let mut current = type_ref;
                let mut visited = Vec::new();
                let product = loop {
                    if visited.contains(&current) {
                        return Err(invalid("recursive construction alias"));
                    }
                    visited.push(current);
                    let node = graph
                        .find_type(current)
                        .ok_or_else(|| invalid("construction type"))?;
                    match &node.shape {
                        TypeShape::Alias { target, .. } => current = target,
                        TypeShape::Product(product) => break product,
                        _ => return Err(invalid("construction product")),
                    }
                };
                let mut body = "{let mut members=Vec::new();".to_string();
                for (field, child) in fields {
                    let field_slot = &product
                        .fields
                        .iter()
                        .find(|candidate| candidate.wire_name == *field)
                        .ok_or_else(|| invalid("construction field"))?
                        .slot;
                    let expression = self.binding(child, field_slot)?;
                    body.push_str(&format!("match {expression}{{SlotValue::Absent=>{{}},SlotValue::Null=>members.push(({field:?}.into(),rt::JsonValue::Null)),SlotValue::Present(value)=>members.push(({field:?}.into(),value))}};"));
                }
                body.push_str("SlotValue::Present(rt::JsonValue::Obj(members))}");
                body
            }
        };
        let origin = match binding {
            BindingExpr::Source { value, .. } => format!("Some({})", value_ref(value)),
            _ => "None".into(),
        };
        Ok(format!(
            "checked(cx,{expression},&{},\"binding\",{origin})?",
            contract(destination)
        ))
    }
    fn resources(
        &self,
        invocation: &InvocationPlan,
        signature: &FunctionSignature,
    ) -> Result<String> {
        let mut body = "let mut resources=Vec::new();".to_string();
        for binding in &invocation.resources {
            let req = signature
                .resource_inputs
                .iter()
                .find(|req| req.id == binding.requirement)
                .ok_or_else(|| invalid("resource requirement"))?;
            body.push_str(&format!(
                "resources.push(bound_resource(env,{}, {})?);",
                lot_ref(&binding.lot),
                requirement(req)
            ));
        }
        Ok(body)
    }
    fn goals(&self, goals: &[ResourceGoal]) -> String {
        let mut body = String::new();
        for goal in goals {
            body.push_str(&format!(
                "resource_goal(env,&{},&{},&{})?;",
                lot_ref(&goal.lot),
                natural(&goal.multiplicity),
                natural(&goal.revision)
            ));
        }
        body
    }
    fn node(&mut self, output: &mut String, tree: &PlanTree) -> Result<usize> {
        let index = self.next;
        self.next += 1;
        let mut children = Vec::new();
        match &tree.node {
            PlanNode::Invoke { arms, .. } => {
                for (_, child) in arms {
                    children.push(self.node(output, child)?);
                }
            }
            PlanNode::Guard { arms, .. } => {
                for (_, child) in arms {
                    children.push(self.node(output, child)?);
                }
            }
            PlanNode::Return(_) => {}
        }
        output.push_str(&format!("fn drive_{index}<P:Providers>(cx:&Context<'_>,env:&mut Environment,providers:&mut P)->Result<CompositionOutcome,CompositionFailure<P::Failure>>{{"));
        match &tree.node {
            PlanNode::Return(ReturnPlan::Success(bindings)) => {
                output.push_str(&self.goals(&self.problem.goal.final_resources));
                output.push_str("Ok(CompositionOutcome::Success(CompositionOutput{");
                for goal in &self.problem.goal.outputs {
                    let binding = &bindings
                        .iter()
                        .find(|(id, _)| *id == goal.id)
                        .ok_or_else(|| invalid("return goal binding"))?
                        .1;
                    let expression = self.binding(binding, &goal.contract)?;
                    output.push_str(&format!(
                        "{}:{},",
                        field_name(&goal.id.0),
                        decode(&expression, &goal.contract)
                    ));
                }
                output.push_str("}))");
            }
            PlanNode::Return(ReturnPlan::Failure { embedding, value }) => {
                let declaration = self
                    .problem
                    .goal
                    .failures
                    .iter()
                    .find(|item| item.id == *embedding)
                    .ok_or_else(|| invalid("failure embedding"))?;
                output.push_str(&self.goals(&declaration.final_resources));
                let expression = self.binding(value, &declaration.contract)?;
                output.push_str(&format!(
                    "Ok(CompositionOutcome::DeclaredFailure(DeclaredFailure::failure_{}({})))",
                    name(&embedding.0),
                    decode(&expression, &declaration.contract)
                ));
            }
            PlanNode::Guard {
                guard: id,
                inspected,
                arms,
            } => {
                let declaration = self
                    .problem
                    .invocation_domain
                    .guards
                    .iter()
                    .find(|item| item.id == *id)
                    .ok_or_else(|| invalid("guard declaration"))?;
                output.push_str(&format!("let inspected=source(env,&{})?;let declaration={};let selected=evaluate_guard_arm(cx.graph,&declaration,borrowed(&inspected)).map_err(|cause|failure(rt::RuntimeFailure::Validation(cause),\"guard\",Some({})))?;",value_ref(inspected),guard(declaration),value_ref(inspected)));
                for ((selected, _), child) in arms.iter().zip(children) {
                    output.push_str(&format!(
                        "if selected=={}{{return drive_{child}(cx,env,providers);}}",
                        arm(selected)
                    ));
                }
                output.push_str(
                    "Err(failure(rt::representation(\"undeclared guard arm\"),\"guard\",None))",
                );
            }
            PlanNode::Invoke {
                invocation, arms, ..
            } => {
                let site = self
                    .problem
                    .invocation_domain
                    .sites
                    .iter()
                    .find(|site| site.id == invocation.site)
                    .ok_or_else(|| invalid("invocation site"))?;
                let signature = self
                    .problem
                    .signatures
                    .iter()
                    .find(|signature| signature.reference == invocation.function)
                    .ok_or_else(|| invalid("invocation signature"))?;
                let prefix = site_name(site);
                output.push_str(&self.resources(invocation, signature)?);
                output.push_str(&format!("let input={prefix}_Input{{"));
                for port in &signature.inputs {
                    let binding = &invocation
                        .bindings
                        .iter()
                        .find(|(id, _)| *id == port.id)
                        .ok_or_else(|| invalid("invocation input"))?
                        .1;
                    let expression = self.binding(binding, &port.contract)?;
                    output.push_str(&format!(
                        "{}:{},",
                        field_name(&port.id.0),
                        decode(&expression, &port.contract)
                    ));
                }
                output.push_str(&format!("}};let outcome=providers.{prefix}(input,&resources).map_err(|cause|CompositionFailure::Provider{{site:SiteId({:?}.into()),function:{},cause}})?;consume_resources(env,&resources)?;match outcome{{",site.id.0,function_ref(&invocation.function)));
                for outcome in &signature.outcomes {
                    output.push_str(&format!(
                        "{prefix}_Outcome::outcome_{}(ports)=>{{",
                        name(&outcome.id.0)
                    ));
                    for port in &outcome.value_ports {
                        let source = ProducerRef::InvocationOutcome {
                            site: site.id.clone(),
                            outcome: outcome.id.clone(),
                            port: port.id.clone(),
                        };
                        let value =
                            encode(&format!("ports.{}", field_name(&port.id.0)), &port.contract);
                        output.push_str(&format!("let value=checked(cx,{value},&{},\"provider output\",Some(ValueRef{{producer:{},path:vec![]}}))?;env.values.push(({},value));",contract(&port.contract),producer(&source),producer(&source)));
                    }
                    for production in &outcome.produced_resources {
                        let reference = ResourceLotRef::Produced {
                            site: site.id.clone(),
                            outcome: outcome.id.clone(),
                            production: production.id.clone(),
                        };
                        let declared = ResourceLot {
                            id: LotId(production.id.0.clone()),
                            token_type: production.token_type.clone(),
                            producer: ResourceProducer::InvocationOutcome {
                                site: site.id.clone(),
                                outcome: outcome.id.clone(),
                            },
                            revision: production.revision.clone(),
                            quantity: production.quantity.clone(),
                            provenance: production.provenance.clone(),
                        };
                        output.push_str(&format!(
                            "env.resources.push(({},{}));",
                            lot_ref(&reference),
                            lot(&declared)
                        ));
                    }
                    if let Some(position) = arms.iter().position(|(id, _)| *id == outcome.id) {
                        let child = children
                            .get(position)
                            .ok_or_else(|| invalid("outcome branch"))?;
                        output.push_str(&format!("drive_{child}(cx,env,providers)"));
                    } else {
                        output.push_str("Err(failure(rt::representation(\"uninhabited provider outcome\"),\"provider output\",None))");
                    }
                    output.push_str("},");
                }
                output.push('}');
            }
        }
        output.push_str("}\n");
        Ok(index)
    }
}

pub(super) fn render(output: &mut String, context: &GenerationContext) -> Result<()> {
    let problem = context
        .problem()
        .ok_or_else(|| invalid("composition is absent"))?;
    let plan = context
        .plan()
        .ok_or_else(|| invalid("composition plan is absent"))?;
    output.push_str("pub mod composed{use super::*;use necoherence::semantic_composition::*;use necoherence::semantic_types::{SlotValue,SlotContract,TypeRef,PathStep};\n");
    output.push_str(RUNTIME);
    let inputs = problem
        .initial_inputs
        .iter()
        .filter(|input| matches!(input.source, InitialSource::Argument))
        .map(|input| (input.id.0.as_str(), &input.contract))
        .collect::<Vec<_>>();
    record(output, "CompositionInput", &inputs)?;
    record(
        output,
        "CompositionOutput",
        &problem
            .goal
            .outputs
            .iter()
            .map(|goal| (goal.id.0.as_str(), &goal.contract))
            .collect::<Vec<_>>(),
    )?;
    output.push_str("#[derive(Debug,Clone,PartialEq)] pub enum DeclaredFailure{");
    let mut failure_names = HashSet::new();
    for failure in &problem.goal.failures {
        let id = name(&failure.id.0);
        if !failure_names.insert(id.clone()) {
            return Err(invalid("generated failure identifier collision"));
        }
        output.push_str(&format!("failure_{id}({}),", native(&failure.contract)));
    }
    output.push_str("}\n#[derive(Debug,Clone,PartialEq)] pub enum CompositionOutcome{Success(CompositionOutput),DeclaredFailure(DeclaredFailure)}\n");
    let mut methods = String::from("pub trait Providers{type Failure;");
    let mut site_names = HashSet::new();
    for site in &problem.invocation_domain.sites {
        let signature = problem
            .signatures
            .iter()
            .find(|signature| signature.reference == site.function)
            .ok_or_else(|| invalid("site signature"))?;
        let prefix = site_name(site);
        if !site_names.insert(prefix.clone()) {
            return Err(invalid("generated site identifier collision"));
        }
        record(
            output,
            &format!("{prefix}_Input"),
            &signature
                .inputs
                .iter()
                .map(|port| (port.id.0.as_str(), &port.contract))
                .collect::<Vec<_>>(),
        )?;
        let mut variants = String::new();
        let mut outcome_names = HashSet::new();
        for outcome in &signature.outcomes {
            let id = name(&outcome.id.0);
            if !outcome_names.insert(id.clone()) {
                return Err(invalid("generated outcome identifier collision"));
            }
            let record_id = format!("{prefix}_outcome_{id}");
            record(
                output,
                &record_id,
                &outcome
                    .value_ports
                    .iter()
                    .map(|port| (port.id.0.as_str(), &port.contract))
                    .collect::<Vec<_>>(),
            )?;
            variants.push_str(&format!("outcome_{id}({record_id}),"));
        }
        output.push_str(&format!(
            "#[derive(Debug,Clone,PartialEq)]pub enum {prefix}_Outcome{{{variants}}}\n"
        ));
        methods.push_str(&format!("fn {prefix}(&mut self,input:{prefix}_Input,resources:&[BoundResource])->Result<{prefix}_Outcome,Self::Failure>;"));
    }
    methods.push_str("}\n");
    output.push_str(&methods);
    let mut emitter = Emitter {
        problem,
        context,
        next: 0,
    };
    let root = emitter.node(output, &plan.root)?;
    output.push_str("pub fn execute<P:Providers>(cx:&Context<'_>,input:CompositionInput,providers:&mut P)->Result<CompositionOutcome,CompositionFailure<P::Failure>>{let mut environment=Environment{values:Vec::new(),resources:Vec::new()};let env=&mut environment;");
    for initial in &problem.initial_inputs {
        let expression = match &initial.source {
            InitialSource::Argument => encode(
                &format!("input.{}", field_name(&initial.id.0)),
                &initial.contract,
            ),
            InitialSource::SuppliedValue(value) => supplied(value)?,
        };
        let source = producer(&ProducerRef::Initial(initial.id.clone()));
        output.push_str(&format!("let value=checked(cx,{expression},&{},\"initial input\",Some(ValueRef{{producer:{source},path:vec![]}}))?;env.values.push(({source},value));",contract(&initial.contract)));
    }
    for initial in &problem.initial_resources {
        output.push_str(&format!(
            "env.resources.push(({},{}));",
            lot_ref(&ResourceLotRef::Initial(initial.id.clone())),
            lot(initial)
        ));
    }
    output.push_str(&format!(
        "drive_{root}(cx,env,providers)}}\n}}\npub use composed::*;\n"
    ));
    Ok(())
}

const RUNTIME: &str = r#"
#[derive(Debug,Clone,PartialEq)] pub struct BindingProvenance{pub operation:&'static str,pub source:Option<ValueRef>}
#[derive(Debug)] pub enum CompositionFailure<E>{Runtime{cause:rt::RuntimeFailure,provenance:BindingProvenance},Provider{site:SiteId,function:FunctionRef,cause:E}}
#[derive(Debug,Clone,PartialEq)] pub struct BoundResource{pub reference:ResourceLotRef,pub lot:ResourceLot,pub requirement:ResourceRequirement}
struct Environment{values:Vec<(ProducerRef,SlotValue)>,resources:Vec<(ResourceLotRef,ResourceLot)>}
fn failure<E>(cause:rt::RuntimeFailure,operation:&'static str,source:Option<ValueRef>)->CompositionFailure<E>{CompositionFailure::Runtime{cause,provenance:BindingProvenance{operation,source}}}
fn type_ref<E>(cx:&Context<'_>,id:&str)->Result<TypeRef,CompositionFailure<E>>{cx.graph.nodes.iter().find(|node|node.reference.definition_name.as_ref()==id).map(|node|node.reference.clone()).ok_or_else(||failure(rt::representation("composition type"),"type reference",None))}
fn borrowed(value:&SlotValue)->SlotValue<&rt::JsonValue>{match value{SlotValue::Absent=>SlotValue::Absent,SlotValue::Null=>SlotValue::Null,SlotValue::Present(value)=>SlotValue::Present(value)}}
fn checked<E>(cx:&Context<'_>,value:SlotValue,contract:&SlotContract,operation:&'static str,source:Option<ValueRef>)->Result<SlotValue,CompositionFailure<E>>{match necoherence::semantic_validation::accepts_slot(cx.graph,contract,borrowed(&value)){ValueDecision::Accepted=>Ok(value),cause=>Err(failure(rt::RuntimeFailure::Validation(cause),operation,source))}}
fn source<E>(env:&Environment,reference:&ValueRef)->Result<SlotValue,CompositionFailure<E>>{let value=env.values.iter().find(|(producer,_)|producer==&reference.producer).map(|(_,value)|value).ok_or_else(||failure(rt::representation("missing producer"),"binding",Some(reference.clone())))?;Ok(project_owned(value,&reference.path,&()))}
fn bound_resource<E>(env:&Environment,reference:ResourceLotRef,requirement:ResourceRequirement)->Result<BoundResource,CompositionFailure<E>>{let lot=env.resources.iter().find(|(id,_)|id==&reference).map(|(_,lot)|lot).ok_or_else(||failure(rt::representation("missing resource lot"),"resource binding",None))?;if lot.quantity<requirement.multiplicity||lot.revision!=requirement.required_revision||matches!(&requirement.identity,ResourceIdentityConstraint::Exactly(producer) if *producer!=lot.producer){return Err(failure(rt::representation("resource requirement"),"resource binding",None));}Ok(BoundResource{reference,lot:lot.clone(),requirement})}
fn consume_resources<E>(env:&mut Environment,resources:&[BoundResource])->Result<(),CompositionFailure<E>>{for resource in resources{if resource.requirement.mode==necoherence::typed_mapping::BindingMode::Consume{let lot=env.resources.iter_mut().find(|(id,_)|id==&resource.reference).map(|(_,lot)|lot).ok_or_else(||failure(rt::representation("missing consumed resource"),"resource consumption",None))?;if lot.quantity<resource.requirement.multiplicity{return Err(failure(rt::representation("resource quantity"),"resource consumption",None));}lot.quantity-=&resource.requirement.multiplicity;}}Ok(())}
fn resource_goal<E>(env:&Environment,reference:&ResourceLotRef,quantity:&rt::BigUint,revision:&rt::BigUint)->Result<(),CompositionFailure<E>>{match env.resources.iter().find(|(id,_)|id==reference){Some((_,lot)) if lot.quantity>=*quantity&&lot.revision==*revision=>Ok(()),_=>Err(failure(rt::representation("final resource goal"),"resource goal",None))}}
"#;
