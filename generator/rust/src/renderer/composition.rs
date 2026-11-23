// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::{field_name, name, RenderFailure};
use necoherence::semantic_composition::*;
use necoherence::semantic_types::SlotContract;
use necoherence::signature_admission::CheckedSignatureGeneration;
use necoherence::type_signatures::SignatureDefinitionShape;
use std::collections::HashSet;

type Result<T> = std::result::Result<T, RenderFailure>;

fn invalid(message: &str) -> RenderFailure {
    RenderFailure::InvalidCheckedPlan(message.into())
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

fn encode(value: &str, slot: &SlotContract, context: &str) -> String {
    let present_value = if slot.required { value } else { "value" };
    let present = if slot.nullable {
        format!("match {present_value}{{rt::Nullable::Null=>SlotValue::Null,rt::Nullable::Value(value)=>SlotValue::Present(value.write_wire(&cx).map_err(|cause|conversion_failure(cause,{context:?}))?)}}")
    } else {
        format!("SlotValue::Present({present_value}.write_wire(&cx).map_err(|cause|conversion_failure(cause,{context:?}))?)")
    };
    if slot.required {
        present
    } else {
        format!("match {value}{{None=>SlotValue::Absent,Some(value)=>{present}}}")
    }
}

fn decode(value: &str, slot: &SlotContract, context: &str) -> String {
    let ty = format!("super::{}", name(&slot.type_ref.definition_name));
    let present =
        format!("cx.checked_for::<{ty}>(value).and_then(|value|{ty}::read_wire(cx,value)).map_err(|cause|conversion_failure(cause,{context:?}))?");
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
        format!("return Err(ExecutionFailure::InvalidPlan({context:?}.into()))")
    } else {
        "None".into()
    };
    let null = if slot.nullable {
        if slot.required {
            "rt::Nullable::Null".into()
        } else {
            "Some(rt::Nullable::Null)".into()
        }
    } else {
        format!("return Err(ExecutionFailure::InvalidPlan({context:?}.into()))")
    };
    format!("match {value}{{SlotValue::Absent=>{absent},SlotValue::Null=>{null},SlotValue::Present(value)=>{present}}}")
}

fn function_prefix(index: usize) -> String {
    format!("Function{index}")
}

fn completion_predicate(
    context: &CheckedSignatureGeneration,
    signature: &FunctionSignature,
) -> Result<String> {
    let FunctionForm::Operation(reference) = &signature.form else {
        return Err(invalid("HTTP provider is not an operation"));
    };
    let definition = context
        .input()
        .signatures
        .definitions
        .iter()
        .find(|definition| definition.id == reference.name.as_ref())
        .ok_or_else(|| invalid("HTTP operation contract is absent"))?;
    let SignatureDefinitionShape::Operation(operation) = &definition.shape else {
        return Err(invalid("HTTP provider contract is not an operation"));
    };
    Ok(super::operation_completion_predicate(operation))
}

fn render_function(output: &mut String, signature: &FunctionSignature, index: usize) -> Result<()> {
    let prefix = function_prefix(index);
    record(
        output,
        &format!("{prefix}Input"),
        &signature
            .inputs
            .iter()
            .map(|port| (port.id.0.as_str(), &port.contract))
            .collect::<Vec<_>>(),
    )?;
    let mut variants = String::new();
    let mut outcome_names = HashSet::new();
    for (arm, outcome) in signature.outcomes.iter().enumerate() {
        if !outcome_names.insert(name(&outcome.id.0)) {
            return Err(invalid("generated outcome identifier collision"));
        }
        let variant = format!("Outcome{arm}");
        record(
            output,
            &format!("{prefix}{variant}"),
            &outcome
                .value_ports
                .iter()
                .map(|port| (port.id.0.as_str(), &port.contract))
                .collect::<Vec<_>>(),
        )?;
        variants.push_str(&format!("{variant}({prefix}{variant}),"));
    }
    output.push_str(&format!(
        "#[derive(Debug,Clone,PartialEq)] pub enum {prefix}Outcome{{{variants}}}\n"
    ));
    output.push_str(&format!(
        "impl {prefix}Outcome{{pub fn outcome_id(&self)->OutcomeId{{match self{{"
    ));
    for (arm, outcome) in signature.outcomes.iter().enumerate() {
        output.push_str(&format!(
            "Self::Outcome{arm}(..)=>OutcomeId({:?}.into()),",
            outcome.id.0
        ));
    }
    output.push_str("}}}\n");
    output.push_str(&format!(
        "fn arguments_{index}(cx:&Context<'_>,ports:&execution::Arguments<'_>)->std::result::Result<{prefix}Input,ExecutionFailure>{{Ok({prefix}Input{{"
    ));
    for port in &signature.inputs {
        let field = field_name(&port.id.0);
        let value = format!("ports.owned(&PortId({:?}.into()))?", port.id.0);
        output.push_str(&format!(
            "{field}:{},",
            decode(&value, &port.contract, "provider input representation")
        ));
    }
    output.push_str("})}\n");
    output.push_str(&format!(
        "fn result_{index}(cx:&Context<'_>,outcome:{prefix}Outcome)->std::result::Result<CallResult,ExecutionFailure>{{let id=outcome.outcome_id();match outcome{{"
    ));
    for (arm, outcome) in signature.outcomes.iter().enumerate() {
        output.push_str(&format!(
            "{prefix}Outcome::Outcome{arm}(ports)=>Ok(CallResult{{outcome:id,outputs:vec!["
        ));
        for port in &outcome.value_ports {
            output.push_str(&format!(
                "(PortId({:?}.into()),{}),",
                port.id.0,
                encode(
                    &format!("ports.{}", field_name(&port.id.0)),
                    &port.contract,
                    "provider output representation"
                )
            ));
        }
        output.push_str("]}),");
    }
    output.push_str("}}\n");
    Ok(())
}

pub(super) fn render(output: &mut String, context: &CheckedSignatureGeneration) -> Result<()> {
    let composition = context
        .composition()
        .ok_or_else(|| invalid("composition is absent"))?;
    let problem = &composition.problem;
    output.push_str("pub mod composed{use super::*;use necoherence::semantic_composition::*;use necoherence::semantic_execution::{self as execution,CallResult,ExecutionFailure};use necoherence::semantic_types::*;use necoherence::typed_mapping as resource;use std::{cell::RefCell,rc::Rc,sync::Arc};\n");
    output.push_str(RUNTIME);

    for (index, signature) in problem.signatures.iter().enumerate() {
        render_function(output, signature, index)?;
    }

    let arguments = problem
        .initial_inputs
        .iter()
        .filter(|input| matches!(input.source, InitialSource::Argument))
        .map(|input| (input.id.0.as_str(), &input.contract))
        .collect::<Vec<_>>();
    record(output, "Arguments", &arguments)?;
    record(
        output,
        "Success",
        &problem
            .goal
            .outputs
            .iter()
            .map(|goal| (goal.id.0.as_str(), &goal.contract))
            .collect::<Vec<_>>(),
    )?;

    output.push_str("#[derive(Debug,Clone,PartialEq)] pub enum Result{Success(Success),");
    let mut failure_names = HashSet::new();
    for (index, failure) in problem.goal.failures.iter().enumerate() {
        if !failure_names.insert(name(&failure.id.0)) {
            return Err(invalid("generated failure identifier collision"));
        }
        output.push_str(&format!("Failure{index}({}),", native(&failure.contract)));
    }
    output.push_str("}\n");
    output.push_str("pub enum RunProgress<'r,'g>{Completed(Result,necoherence::network_effect::NetworkState),Pending(execution::Execution<'r,'g>,execution::NetworkInstruction)}\n");
    output.push_str("#[derive(Clone,Debug,PartialEq)] pub enum PrepareFailure{Preparation(CompositionInputFailure),CompositionAbsent}\n");
    output.push_str(
        "pub struct Prepared<'g>{run:execution::PreparedRun<'g>,graph:Rc<SemanticGraph>}\n",
    );
    output.push_str("pub fn prepare(generation:&necoherence::signature_admission::CheckedSignatureGeneration)->std::result::Result<Prepared<'_>,PrepareFailure>{let admission=generation.prepare_admission().map_err(PrepareFailure::Preparation)?.ok_or(PrepareFailure::CompositionAbsent)?;Ok(Prepared{run:execution::PreparedRun::new(admission.admitted()),graph:Rc::new(generation.graph().clone())})}\n");
    output.push_str("pub trait Providers:'static{");
    for (index, signature) in problem.signatures.iter().enumerate() {
        let prefix = function_prefix(index);
        if signature.effect == CompositionEffect::HttpRequestResponse {
            output.push_str(&format!("fn call_{index}(&mut self)->execution::NetworkBinding<{prefix}Input,{prefix}Outcome>;"));
        } else {
            output.push_str(&format!("fn call_{index}(&mut self,input:{prefix}Input)->std::result::Result<{prefix}Outcome,ExecutionFailure>;"));
        }
    }
    output.push_str("}\n");

    output.push_str("fn provider_list<P:Providers>(providers:P,problem:&CompositionInput,graph:&Rc<SemanticGraph>)->Vec<execution::Provider>{let providers=Rc::new(RefCell::new(providers));vec![");
    for (index, signature) in problem.signatures.iter().enumerate() {
        if signature.effect == CompositionEffect::HttpRequestResponse {
            let completed = completion_predicate(context, signature)?;
            output.push_str(&format!("{{let binding=Arc::new(providers.borrow_mut().call_{index}());let prepare_binding=binding.clone();let decode_binding=binding.clone();let prepare_graph=graph.clone();let decode_graph=graph.clone();execution::Provider{{reference:problem.signatures[{index}].reference.clone(),implementation:execution::ProviderImplementation::PreparedHttp(execution::PreparedNetworkOwner{{prepare:Arc::new(move|ports:&execution::Arguments<'_>|{{let cx=context(&prepare_graph);let arguments=arguments_{index}(&cx,ports)?;match execution::prepare_call(prepare_binding.as_ref(),&arguments,|outcome|outcome.outcome_id(),|outcome|{completed})?{{execution::BindingPreparedCall::Ready(attempt)=>Ok(execution::PreparedCall::Ready(attempt)),execution::BindingPreparedCall::Completed(_,result)=>Ok(execution::PreparedCall::Completed(result_{index}(&cx,result)?))}}}}),decode:Arc::new(move|response:&necoherence::network_effect::RawHttpResponse|{{let cx=context(&decode_graph);let outcome=(decode_binding.transport.decode)(response)?;result_{index}(&cx,outcome)}})}})}}}},"));
        } else {
            output.push_str(&format!("{{let providers=providers.clone();let graph=graph.clone();execution::Provider{{reference:problem.signatures[{index}].reference.clone(),implementation:execution::ProviderImplementation::Pure(Arc::new(move|ports:&execution::Arguments<'_>|{{let cx=context(&graph);let arguments=arguments_{index}(&cx,ports)?;let outcome=providers.borrow_mut().call_{index}(arguments)?;result_{index}(&cx,outcome)}}))}}}},"));
        }
    }
    output.push_str("]}\n");

    output.push_str("fn arguments_values(cx:&Context<'_>,arguments:Arguments)->std::result::Result<Vec<(InputId,SlotValue)>,ExecutionFailure>{Ok(vec![");
    for input in problem
        .initial_inputs
        .iter()
        .filter(|input| matches!(input.source, InitialSource::Argument))
    {
        output.push_str(&format!(
            "(InputId({:?}.into()),{}),",
            input.id.0,
            encode(
                &format!("arguments.{}", field_name(&input.id.0)),
                &input.contract,
                "argument representation"
            )
        ));
    }
    output.push_str("])}\n");

    output.push_str("fn decode_result(cx:&Context<'_>,result:execution::ExecutionResult)->std::result::Result<Result,ExecutionFailure>{match result{");
    output.push_str("execution::ExecutionResult::Success(outputs)=>Ok(Result::Success(Success{");
    for goal in &problem.goal.outputs {
        let field = field_name(&goal.id.0);
        let value = format!("outputs.iter().find(|(id,_)|id.0=={:?}).map(|(_,value)|value.clone()).ok_or_else(||ExecutionFailure::InvalidPlan(\"goal output missing\".into()))?", goal.id.0);
        output.push_str(&format!(
            "{field}:{},",
            decode(&value, &goal.contract, "goal output representation")
        ));
    }
    output.push_str(
        "})),execution::ExecutionResult::Failure(embedding,value)=>match embedding.0.as_str(){",
    );
    for (index, failure) in problem.goal.failures.iter().enumerate() {
        output.push_str(&format!(
            "{:?}=>Ok(Result::Failure{index}({})),",
            failure.id.0,
            decode("value", &failure.contract, "failure output representation")
        ));
    }
    output
        .push_str("_=>Err(ExecutionFailure::InvalidPlan(\"failure output missing\".into()))}}}\n");

    output.push_str("fn map_progress<'r,'g>(graph:&SemanticGraph,progress:execution::Progress<'r,'g>)->std::result::Result<RunProgress<'r,'g>,execution::RunFailure>{match progress{execution::Progress::Completed(result,network)=>{let cx=context(graph);decode_result(&cx,result).map(|result|RunProgress::Completed(result,network.clone())).map_err(|cause|execution::RunFailure{cause,network})},execution::Progress::Pending(execution,instruction)=>Ok(RunProgress::Pending(execution,instruction))}}\n");
    output.push_str("pub fn run<'r,'g,P:Providers>(prepared:&'r Prepared<'g>,providers:P,arguments:Arguments,network:necoherence::network_effect::NetworkState)->std::result::Result<RunProgress<'r,'g>,execution::RunFailure>{let run=&prepared.run;let graph=run.graph();let cx=context(graph);let arguments=arguments_values(&cx,arguments).map_err(|cause|execution::RunFailure{cause,network:network.clone()})?;let providers=provider_list(providers,run.input(),&prepared.graph);let workspace=run.workspace();let progress=execution::start(run,workspace,providers,arguments,network)?;map_progress(graph,progress)}\n");
    output.push_str("pub fn resume<'r,'g>(execution:execution::Execution<'r,'g>,observation:execution::ExecutionObservation)->std::result::Result<RunProgress<'r,'g>,execution::RunFailure>{let graph=execution.graph();map_progress(graph,execution::resume(execution,observation)?)}\n");
    output.push_str("}\n");
    Ok(())
}

const RUNTIME: &str = r#"
fn context(graph:&SemanticGraph)->Context<'_>{Context::from_graph(graph)}
trait GeneratedNatural{fn generated_natural(negative:bool,digits:&[u8])->Self;}
impl GeneratedNatural for necoherence::Nat{fn generated_natural(_:bool,digits:&[u8])->Self{necoherence::Nat::from_bytes_be(digits)}}
fn integer_from_signed_bytes(negative:bool,digits:&[u8])->rt::BigInt{let value=rt::BigInt::from(rt::BigUint::from_bytes_be(digits));if negative{-value}else{value}}
impl GeneratedNatural for rt::BigInt{fn generated_natural(negative:bool,digits:&[u8])->Self{integer_from_signed_bytes(negative,digits)}}
impl GeneratedNatural for usize{fn generated_natural(_:bool,digits:&[u8])->Self{digits.iter().fold(0usize,|value,digit|value*256+usize::from(*digit))}}
impl GeneratedNatural for u32{fn generated_natural(_:bool,digits:&[u8])->Self{digits.iter().fold(0u32,|value,digit|value*256+u32::from(*digit))}}
impl GeneratedNatural for u8{fn generated_natural(_:bool,digits:&[u8])->Self{digits.first().copied().unwrap_or(0)}}
fn generated_natural<T:GeneratedNatural>(negative:bool,digits:&[u8])->T{T::generated_natural(negative,digits)}
fn validation_failure(failure:necoherence::semantic_validation::ValidationFailure)->ExecutionFailure{match failure{necoherence::semantic_validation::ValidationFailure::Value(value)=>ExecutionFailure::Value(execution::ValidationFailure::Value(value)),necoherence::semantic_validation::ValidationFailure::Unresolved(obligations)=>ExecutionFailure::Value(execution::ValidationFailure::Unresolved(obligations)),necoherence::semantic_validation::ValidationFailure::CertificateMismatch(condition)=>ExecutionFailure::Value(execution::ValidationFailure::CertificateMismatch(condition))}}
fn conversion_failure(cause:rt::RuntimeFailure,condition:&str)->ExecutionFailure{match cause{rt::RuntimeFailure::Validation(evaluation)=>validation_failure(evaluation),_=>ExecutionFailure::InvalidPlan(condition.into())}}
"#;
