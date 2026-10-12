// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_composition::{PlanNode, PlanTree, ReturnPlan};
use necoherence::semantic_types::{BranchSelector, EffectPoint, MemberTest};
use necoherence::type_signatures::{
    CheckedLibrary, OutcomeCause, Shape, SignatureDefinitionShape, SignatureExtraMembers,
    SignatureGenerationBasis, SignatureGenerationInput, SignaturePort, TypeSignatureLibrary,
};

#[derive(Debug)]
pub enum RenderFailure {
    Generation(necoherence::semantic_exchange::GenerationFailure),
    Admission(necoherence::signature_admission::AdmissionFailure),
    InvalidLibrary(necoherence::type_signatures::LibraryCheckFailure),
    UndefinedType(String),
    InvalidCheckedPlan(String),
}
impl std::fmt::Display for RenderFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for RenderFailure {}

fn name(value: &str) -> String {
    let mut result = value.replace(|character: char| !character.is_ascii_alphanumeric(), "_");
    if result
        .chars()
        .next()
        .is_some_and(|character| character.is_ascii_digit())
    {
        result.insert(0, '_');
    }
    result
}
fn pascal(value: &str) -> String {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut characters = part.chars();
            characters.next().map_or_else(String::new, |first| {
                first.to_ascii_uppercase().to_string() + characters.as_str()
            })
        })
        .collect()
}
fn snake(value: &str) -> String {
    name(value).to_ascii_lowercase()
}
fn selector_code(selector: &BranchSelector) -> String {
    match selector {
        BranchSelector::InternalTag => {
            "necoherence::semantic_types::BranchSelector::InternalTag".into()
        }
        BranchSelector::Otherwise => {
            "necoherence::semantic_types::BranchSelector::Otherwise".into()
        }
        BranchSelector::Kind(kind) => format!(
            "necoherence::semantic_types::BranchSelector::Kind(necoherence::semantic_types::ValueKind::{kind:?})"
        ),
        BranchSelector::MemberShape(tests) => {
            let entries = tests
                .iter()
                .map(|(key, test)| match test {
                    MemberTest::Absent => format!(
                        "({key:?}.into(),necoherence::semantic_types::MemberTest::Absent)"
                    ),
                    MemberTest::Format(format) => format!(
                        "({key:?}.into(),necoherence::semantic_types::MemberTest::Format({format:?}.into()))"
                    ),
                })
                .collect::<Vec<_>>()
                .join(",");
            format!(
                "necoherence::semantic_types::BranchSelector::MemberShape(vec![{entries}])"
            )
        }
    }
}

pub fn render_library(library: &TypeSignatureLibrary) -> Result<String, RenderFailure> {
    let checked = necoherence::type_signatures::check_library(library)
        .map_err(RenderFailure::InvalidLibrary)?;
    render_checked(&checked)
}
pub fn render_signature_exchange(
    expected: &SignatureGenerationBasis,
    text: &str,
) -> Result<String, RenderFailure> {
    let input = necoherence::semantic_exchange::decode_signature_generation(text)
        .map_err(RenderFailure::Generation)?;
    let checked = necoherence::signature_admission::admit_signature_generation(expected, input)
        .map_err(RenderFailure::Admission)?;
    render_generation(checked.input())
}
pub fn render_generation(input: &SignatureGenerationInput) -> Result<String, RenderFailure> {
    let checked_library = necoherence::type_signatures::check_library(&input.signatures)
        .map_err(RenderFailure::InvalidLibrary)?;
    let mut output = render_checked(&checked_library)?;
    render_generation_metadata(&mut output, input)?;
    render_operations(&mut output, input);
    if input.composition.is_some() {
        let admitted = necoherence::signature_admission::admit_signature_generation(
            &input.basis,
            input.clone(),
        )
        .map_err(RenderFailure::Admission)?;
        let context = necoherence::semantic_exchange::signature_render_context(admitted)
            .map_err(RenderFailure::Generation)?;
        render_composition(&mut output, &context)?;
    }
    Ok(output)
}

fn render_generation_metadata(
    output: &mut String,
    input: &SignatureGenerationInput,
) -> Result<(), RenderFailure> {
    let document = necoherence::semantic_exchange::encode_signature_generation(input)
        .map_err(RenderFailure::Generation)?;
    output.push_str(&format!(
        "pub const SIGNATURE_GENERATION_DOCUMENT:&str={document:?};\n\
         pub fn generation_context()->Result<necoherence::semantic_exchange::GenerationContext,necoherence::semantic_exchange::GenerationFailure>{{\
         let input=necoherence::semantic_exchange::decode_signature_generation(SIGNATURE_GENERATION_DOCUMENT)?;\
         necoherence::semantic_exchange::signature_generation_context(&input.basis,SIGNATURE_GENERATION_DOCUMENT)}}\n\
         pub fn graph(context:&necoherence::semantic_exchange::GenerationContext)->&necoherence::semantic_types::SemanticGraph{{context.graph()}}\n\
         pub fn annotations(context:&necoherence::semantic_exchange::GenerationContext)->&[necoherence::type_signatures::Annotation]{{&context.signature_input().signatures.annotations}}\n"
    ));
    Ok(())
}
fn render_plan_node(output: &mut String, tree: &PlanTree, next: &mut usize) -> usize {
    let index = *next;
    *next += 1;
    let children = match &tree.node {
        PlanNode::Invoke { arms, .. } => arms
            .iter()
            .map(|(outcome, child)| (outcome.0.clone(), render_plan_node(output, child, next)))
            .collect::<Vec<_>>(),
        PlanNode::Guard { arms, .. } => arms
            .iter()
            .map(|(arm, child)| (format!("{arm:?}"), render_plan_node(output, child, next)))
            .collect::<Vec<_>>(),
        PlanNode::Return(_) => vec![],
    };
    output.push_str(&format!(
        "fn drive_{index}(values:Vec<rt::JsonValue>,providers:&mut impl Providers)->Result<CompositionOutcome,rt::RuntimeFailure>{{"
    ));
    match &tree.node {
        PlanNode::Return(ReturnPlan::Success(_)) => {
            output.push_str("Ok(CompositionOutcome::Success(CompositionOutput(values)))");
        }
        PlanNode::Return(ReturnPlan::Failure { .. }) => {
            output.push_str("Ok(CompositionOutcome::Failure(CompositionOutput(values)))");
        }
        PlanNode::Invoke { invocation, .. } => {
            output.push_str(&format!(
                "let provided=providers.call_provider({:?},values)?;match provided.outcome_id.as_str(){{",
                invocation.function.identity
            ));
            for (outcome, child) in children {
                output.push_str(&format!(
                    "{outcome:?}=>drive_{child}(provided.values,providers),"
                ));
            }
            output.push_str("_=>Err(rt::representation(\"declared provider outcome\")),}");
        }
        PlanNode::Guard { .. } => {
            output.push_str(
                "let _=(values,providers);Err(rt::representation(\"generated guard execution\"))",
            );
        }
    }
    output.push_str("}\n");
    index
}

fn render_composition(
    output: &mut String,
    context: &necoherence::semantic_exchange::GenerationContext,
) -> Result<(), RenderFailure> {
    let problem = context
        .problem()
        .ok_or_else(|| RenderFailure::InvalidCheckedPlan("composition is absent".into()))?;
    let plan = context
        .plan()
        .ok_or_else(|| RenderFailure::InvalidCheckedPlan("composition plan is absent".into()))?;
    output.push_str(
        "pub mod composed {\n\
         use super::*;\n\
         #[derive(Debug,Clone,PartialEq)] pub struct CompositionInput(pub Vec<rt::JsonValue>);\n\
         #[derive(Debug,Clone,PartialEq)] pub struct CompositionOutput(pub Vec<rt::JsonValue>);\n\
         #[derive(Debug,Clone,PartialEq)] pub enum CompositionOutcome { Success(CompositionOutput), Failure(CompositionOutput) }\n\
         #[derive(Debug,Clone,PartialEq)] pub struct ProviderOutcome { pub outcome_id:String, pub values:Vec<rt::JsonValue> }\n\
         #[derive(Debug,Clone,PartialEq)] pub struct CompositionContinuation { pub input:CompositionInput }\n\
         pub trait Providers { fn call_provider(&mut self,function:&str,input:Vec<rt::JsonValue>)->Result<ProviderOutcome,rt::RuntimeFailure>; }\n",
    );
    output.push_str("pub const PROVIDERS:&[(&str,&str,&str)]=&[");
    for signature in &problem.signatures {
        output.push_str(&format!(
            "({:?},{:?},{:?}),",
            signature.reference.identity,
            signature.reference.revision,
            signature.reference.content_digest
        ));
    }
    output.push_str("];\n");
    let root = render_plan_node(output, &plan.root, &mut 0);
    output.push_str(&format!(
        "pub fn execute(_cx:&Context<'_>,input:CompositionInput,providers:&mut impl Providers)->Result<CompositionOutcome,rt::RuntimeFailure>{{drive_{root}(input.0,providers)}}\n\
         pub fn resume(cx:&Context<'_>,continuation:CompositionContinuation,providers:&mut impl Providers)->Result<CompositionOutcome,rt::RuntimeFailure>{{execute(cx,continuation.input,providers)}}\n\
         }}\n\
         pub use composed::*;\n"
    ));
    Ok(())
}

fn render_port_record(output: &mut String, record_name: &str, ports: &[SignaturePort]) {
    output.push_str(&format!(
        "#[derive(Debug,Clone,PartialEq)] pub struct {record_name} {{"
    ));
    for port in ports {
        output.push_str(&format!("pub {}:Option<rt::JsonValue>,", name(&port.id)));
    }
    output.push_str("}\n");
}
fn render_operations(output: &mut String, input: &SignatureGenerationInput) {
    output.push_str(
        "pub enum SignatureHttpPrepare<T>{Ready(necoherence::network_effect::AttemptInput),Completed{outcome_id:&'static str,value:T}}\n\
         pub trait SignatureHttpTransport{type Started;fn start(&mut self,input:necoherence::network_effect::AttemptInput)->Result<Self::Started,rt::RuntimeFailure>;fn observe(&mut self,started:&Self::Started)->Result<necoherence::network_effect::NetworkTerminal,rt::RuntimeFailure>;}\n\
         pub mod signature_operations {\nuse super::*;\n",
    );
    for definition in &input.signatures.definitions {
        let SignatureDefinitionShape::Operation(operation) = &definition.shape else {
            continue;
        };
        let type_name = pascal(&definition.wire_identity);
        render_port_record(output, &format!("{type_name}Input"), &operation.inputs);
        for (index, outcome) in operation.outcomes.iter().enumerate() {
            render_port_record(
                output,
                &format!("{type_name}Outcome{index}"),
                &outcome.value_ports,
            );
        }
        output.push_str(&format!(
            "#[derive(Debug,Clone,PartialEq)] pub enum {type_name}Result {{"
        ));
        for index in 0..operation.outcomes.len() {
            output.push_str(&format!("Outcome{index}({type_name}Outcome{index}),"));
        }
        output.push_str("}\n");
        output.push_str(&format!(
            "impl {type_name}Result {{ pub fn outcome_id(&self)->&'static str{{match self{{"
        ));
        for (index, outcome) in operation.outcomes.iter().enumerate() {
            output.push_str(&format!("Self::Outcome{index}(..)=>{:?},", outcome.id));
        }
        output.push_str("}}}\n");
        if operation.effect == EffectPoint::HttpRequestResponse {
            let function = snake(&definition.wire_identity);
            let external = operation
                .outcomes
                .iter()
                .filter(|outcome| {
                    matches!(outcome.cause, OutcomeCause::ExternalCondition { .. })
                        && outcome.form
                            == necoherence::type_signatures::OutcomeForm::DeclaredFailure
                })
                .map(|outcome| format!("outcome_id=={:?}", outcome.id))
                .chain(std::iter::once("false".to_owned()))
                .collect::<Vec<_>>()
                .join("||");
            output.push_str(&format!(
                "pub trait {type_name}Binding {{\
                   fn prepare(&mut self,cx:&Context<'_>,input:{type_name}Input)->Result<SignatureHttpPrepare<{type_name}Result>,rt::RuntimeFailure>;\
                   fn decode(&mut self,cx:&Context<'_>,terminal:&necoherence::network_effect::NetworkTerminal)->Result<{type_name}Result,rt::RuntimeFailure>;\
                 }}\n\
                 pub enum {type_name}Start<S> {{Completed({type_name}Result),Started(S)}}\n\
                 pub fn {function}_call<T:SignatureHttpTransport>(cx:&Context<'_>,input:{type_name}Input,owner:&mut impl {type_name}Binding,transport:&mut T)->Result<{type_name}Start<T::Started>,rt::RuntimeFailure>{{\
                   match owner.prepare(cx,input)?{{\
                     SignatureHttpPrepare::Ready(attempt)=>Ok({type_name}Start::Started(transport.start(attempt)?)),\
                     SignatureHttpPrepare::Completed{{outcome_id,value}}=>{{\
                       if !({external})||value.outcome_id()!=outcome_id{{return Err(rt::representation(\"declared external completion\"));}}\
                       Ok({type_name}Start::Completed(value))\
                     }}\
                   }}\
                 }}\n\
                 pub fn {function}_observe<T:SignatureHttpTransport>(cx:&Context<'_>,started:&T::Started,owner:&mut impl {type_name}Binding,transport:&mut T)->Result<{type_name}Result,rt::RuntimeFailure>{{let terminal=transport.observe(started)?;owner.decode(cx,&terminal)}}\n"
            ));
        }
    }
    output.push_str("}\npub use signature_operations::*;\n");
}

pub fn render_checked(checked: &CheckedLibrary) -> Result<String, RenderFailure> {
    let mut output = String::from(
        "// SPDX-License-Identifier: MIT\n\
         use necoherence::semantic_codegen_runtime as rt;\n\
         use necoherence::semantic_types::{SemanticGraph,VersionedSemanticProfile,ValueDecision};\n\
         pub struct Context<'a>{pub profile:&'a VersionedSemanticProfile,pub graph:Option<&'a SemanticGraph>}\n\
         impl<'a> Context<'a>{\
           pub fn new(generation:&'a necoherence::semantic_exchange::GenerationContext)->Self{Self{profile:generation.graph().profile(),graph:Some(generation.graph())}}\
           fn validate(&self,id:&str,value:&rt::JsonValue)->Result<(),rt::RuntimeFailure>{\
             let Some(graph)=self.graph else{return Ok(())};\
             let reference=graph.nodes.iter().find(|node|node.reference.definition_name.as_ref()==id).map(|node|&node.reference).ok_or_else(||rt::representation(\"generated type reference\"))?;\
             match necoherence::semantic_validation::accepts_value(graph,reference,value){ValueDecision::Accepted=>Ok(()),failure=>Err(rt::representation(format!(\"{failure:?}\")))}\
           }\
         }\n\
         pub trait WireValue: Sized {\
         fn write_wire(&self,cx:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>;\
         fn read_wire(cx:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>;\
         }\n",
    );
    for node in &checked.library.nodes {
        let type_name = name(&node.id);
        match &node.shape {
            Shape::Unknown(_) => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub rt::JsonValue); impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{Ok(self.0.clone())}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{Ok(Self(value))}} }}\n")),
            Shape::Unit => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}; impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{Ok(rt::JsonValue::Null)}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{match value{{rt::JsonValue::Null=>Ok(Self),_=>Err(rt::representation(\"unit\"))}}}} }}\n")),
            Shape::Boolean(_) => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub bool); impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{Ok(rt::JsonValue::Bool(self.0))}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{match value{{rt::JsonValue::Bool(value)=>Ok(Self(value)),_=>Err(rt::representation(\"boolean\"))}}}} }}\n")),
            Shape::Integer(_) => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub rt::BigInt); impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{Ok(rt::JsonValue::Num(self.0.clone()))}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{match value{{rt::JsonValue::Num(value)=>Ok(Self(value)),rt::JsonValue::Str(value)=>Ok(Self(rt::parse_integer(&value)?)),_=>Err(rt::representation(\"integer\"))}}}} }}\n")),
            Shape::Decimal(_) => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub String); impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{Ok(rt::JsonValue::Dec(self.0.clone()))}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{match value{{rt::JsonValue::Dec(value)=>Ok(Self(value)),_=>Err(rt::representation(\"decimal\"))}}}} }}\n")),
            Shape::String(spec) => {
                let write = spec.wrapper.as_ref().map_or(
                    "Ok(rt::JsonValue::Str(self.0.clone()))".to_owned(),
                    |wrapper| format!("rt::wrap_encode(cx.profile,{wrapper:?},self.0.clone())"),
                );
                let read = spec.wrapper.as_ref().map_or(
                    "match value { rt::JsonValue::Str(value)=>Ok(Self(value)), _=>Err(rt::representation(\"string\")) }".to_owned(),
                    |wrapper| format!("Ok(Self(rt::wrap_decode(cx.profile,{wrapper:?},value)?))"),
                );
                output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub String); impl {type_name} {{ pub fn examples()->&'static[&'static str]{{&["));
                for example in &spec.examples {
                    output.push_str(&format!("{example:?},"));
                }
                output.push_str(&format!("]}} }} impl WireValue for {type_name} {{ fn write_wire(&self,cx:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{{write}}} fn read_wire(cx:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{{read}}} }}\n"));
            }
            Shape::Bytes(_) | Shape::RawBody { .. } => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub Vec<u8>); impl WireValue for {type_name} {{ fn write_wire(&self,cx:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{rt::bytes_encode(cx.profile,&self.0)}} fn read_wire(cx:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{Ok(Self(rt::bytes_decode(cx.profile,value)?))}} }}\n")),
            Shape::Product(product) => {
                output.push_str(&format!(
                    "#[derive(Debug,Clone,PartialEq)] pub struct {type_name} {{"
                ));
                for field in &product.fields {
                    output.push_str(&format!(
                        "pub {}:Option<rt::JsonValue>,",
                        name(&field.wire_name)
                    ));
                }
                if matches!(product.extras, SignatureExtraMembers::Allow { .. }) {
                    output.push_str("pub extras:Vec<(String,rt::JsonValue)>");
                }
                output.push_str("}\n");
                output.push_str(&format!("impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{let mut members=vec![];"));
                if matches!(product.extras, SignatureExtraMembers::Allow { .. }) {
                    output.push_str("members.extend(self.extras.clone());");
                }
                for field in &product.fields {
                    let native = name(&field.wire_name);
                    output.push_str(&format!(
                        "if let Some(value)=&self.{native}{{members.push(({:?}.into(),value.clone()));}}",
                        field.wire_name
                    ));
                }
                output.push_str(&format!("Ok(rt::JsonValue::Obj(members))}} fn read_wire(cx:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{cx.validate({:?},&value)?;let mut members=rt::object(value)?;",node.id));
                for field in &product.fields {
                    output.push_str(&format!(
                        "let {}=match members.iter().position(|member|member.0=={:?}){{Some(index)=>Some(members.remove(index).1),None=>None}};",
                        name(&field.wire_name),
                        field.wire_name
                    ));
                }
                if matches!(product.extras, SignatureExtraMembers::Reject) {
                    output.push_str("if !members.is_empty(){return Err(rt::representation(\"unexpected member\"));}");
                }
                output.push_str("Ok(Self{");
                for field in &product.fields {
                    let native = name(&field.wire_name);
                    output.push_str(&format!("{native},"));
                }
                if matches!(product.extras, SignatureExtraMembers::Allow { .. }) {
                    output.push_str("extras:members,");
                }
                output.push_str("})} }\n");
            }
            Shape::Array(_) => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub Vec<rt::JsonValue>); impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{Ok(rt::JsonValue::Arr(self.0.clone()))}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{match value{{rt::JsonValue::Arr(values)=>Ok(Self(values)),_=>Err(rt::representation(\"array\"))}}}} }}\n")),
            Shape::TaggedUnion(union) => {
                output.push_str(&format!(
                    "#[derive(Debug,Clone,PartialEq)] pub enum {type_name} {{"
                ));
                for branch in &union.branches {
                    output.push_str(&format!("{}(rt::JsonValue),", name(&branch.wire_tag)));
                }
                output.push_str(&format!("}} impl WireValue for {type_name} {{ fn write_wire(&self,cx:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{match self{{"));
                for branch in &union.branches {
                    let variant = name(&branch.wire_tag);
                    if branch.selector == BranchSelector::InternalTag {
                        output.push_str(&format!("Self::{variant}(value)=>rt::with_member(&cx.profile.tag.as_ref().ok_or_else(||rt::representation(\"tag model\"))?.key,{:?},value.clone()),",branch.wire_tag));
                    } else {
                        output.push_str(&format!("Self::{variant}(value)=>Ok(value.clone()),"));
                    }
                }
                output.push_str("}} fn read_wire(cx:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{");
                for branch in &union.branches {
                    output.push_str(&format!("if rt::branch_selector_matches(cx.profile,&{}, {:?},&value){{return Ok(Self::{}(value));}}",selector_code(&branch.selector),branch.wire_tag,name(&branch.wire_tag)));
                }
                output.push_str("Err(rt::representation(\"union branch\"))} }\n");
            }
            Shape::Sealed { tag, .. } => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub struct {type_name}(pub rt::JsonValue); impl WireValue for {type_name} {{ fn write_wire(&self,cx:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{rt::with_member(&cx.profile.tag.as_ref().ok_or_else(||rt::representation(\"tag model\"))?.key,{tag:?},self.0.clone())}} fn read_wire(_:&Context<'_>,value:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{Ok(Self(value))}} }}\n")),
            Shape::Never => output.push_str(&format!("#[derive(Debug,Clone,PartialEq)] pub enum {type_name} {{}} impl WireValue for {type_name} {{ fn write_wire(&self,_:&Context<'_>)->Result<rt::JsonValue,rt::RuntimeFailure>{{match *self{{}}}} fn read_wire(_:&Context<'_>,_:rt::JsonValue)->Result<Self,rt::RuntimeFailure>{{Err(rt::representation(\"never\"))}} }}\n")),
            Shape::Alias { target } => output.push_str(&format!("pub type {type_name}={};\n", name(target))),
            Shape::Opaque { .. } => return Err(RenderFailure::UndefinedType(node.id.clone())),
        }
    }
    Ok(output)
}
