// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::emitter::{Emitter, Port};
use super::text::{
    emission, field, field_identifier, line, list, prefix, quote, tag, text, Result,
};
use std::collections::HashSet;

impl Emitter {
    pub(super) fn composition(&mut self) -> Result<()> {
        let problem = self
            .problem
            .clone()
            .ok_or_else(|| emission("composition problem"))?;
        let goal = field(&problem, "goal")?.clone();
        let mut initial_arguments = Vec::new();
        for initial in list(&problem, "initial_inputs")? {
            if tag(field(initial, "source")?)? == "Argument" {
                initial_arguments.push(initial.clone());
            }
        }
        let argument_ports = self.ports_of(&initial_arguments)?;
        self.port_class("Arguments", &argument_ports, "", "")?;
        let goal_outputs = list(&goal, "outputs")?.to_vec();
        let goal_ports = self.ports_of(&goal_outputs)?;
        self.port_class("Goals", &goal_ports, "", "")?;
        let providers = self.providers.clone();
        let mut provider_fields = Vec::new();
        let mut provider_names = HashSet::new();
        for (index, signature) in providers.iter().enumerate() {
            let name = self.function(index)?;
            let field_name = self.provider_field(index)?;
            if !provider_names.insert(field_name.clone()) {
                return Err(emission("provider identifier collision"));
            }
            let kind = if tag(field(signature, "effect")?)? != "HttpRequestResponse" {
                "Provider "
            } else {
                "HttpBinding "
            };
            provider_fields.push(format!("{name}{kind}{field_name}"));
        }
        line(
            &mut self.out,
            &format!(
                "  public record Providers({}) {{ public Providers {{",
                provider_fields.join(",")
            ),
        );
        for index in 0..providers.len() {
            let field_name = self.provider_field(index)?;
            line(
                &mut self.out,
                &format!("    Objects.requireNonNull({field_name});"),
            );
        }
        line(&mut self.out, "  } }");
        let mut failures = Vec::new();
        for embedding in list(&goal, "failures")? {
            let id = text(embedding, "id")?;
            let name = format!("{}Failure", prefix(id));
            self.reserve(&name)?;
            failures.push(name.clone());
            let contract = self.library_contract(field(embedding, "contract")?)?;
            let ports = vec![Port {
                id: "value".to_owned(),
                contract,
            }];
            let method = format!("    public String embeddingId(){{return {};}}", quote(id));
            self.port_class(&name, &ports, " implements Result", &method)?;
        }
        line(&mut self.out, "  public record Success(Goals values) implements Result { public Success { Objects.requireNonNull(values); } }");
        let permits = if failures.is_empty() {
            String::new()
        } else {
            format!(",{}", failures.join(","))
        };
        line(
            &mut self.out,
            &format!("  public sealed interface Result permits Success{permits} {{}}"),
        );
        for text in [
            "  public sealed interface RunProgress permits Completed,Pending {}",
            "  public record Completed(Result result,NetworkEffect.NetworkState network) implements RunProgress {}",
            "  public record Pending(SemanticExecution.Execution execution,SemanticExecution.NetworkInstruction instruction) implements RunProgress {}",
            "  public sealed interface InitializeResult permits Initialized,InitializeRejected {}",
            "  public static final class Initialized implements InitializeResult { private final CheckedGeneration generation; private final SemanticExecution.AdmittedComposition composition; private Initialized(CheckedGeneration generation,SemanticExecution.AdmittedComposition composition) { this.generation=generation; this.composition=composition; } public CheckedGeneration generation() { return generation; } }",
            "  public record InitializeRejected(GenerationFailure failure) implements InitializeResult {}",
            "  public sealed interface RunResult permits Progressed,Rejected {}",
            "  public sealed interface ResumeResult permits Progressed,ResumeRejected {}",
            "  public record Progressed(RunProgress progress) implements RunResult,ResumeResult {}",
            "  public record Rejected(SemanticExecution.RunFailure failure) implements RunResult {}",
            "  public record ResumeRejected(SemanticExecution.RunFailure failure) implements ResumeResult {}",
        ] {
            line(&mut self.out, text);
        }
        for text in [
            "  private sealed interface ProgressMapping permits ProgressAccepted,ProgressRejected {}",
            "  private record ProgressAccepted(RunProgress progress) implements ProgressMapping {}",
            "  private record ProgressRejected(SemanticExecution.RunFailure failure) implements ProgressMapping {}",
            "  private static SemanticExecution.PortValue providerPort(List<SemanticExecution.PortValue> ports,String id) { for(var port:ports) if(port.port().value().equals(id)) return port; return null; }",
            "  private static SemanticExecution.GoalValue goalPort(List<SemanticExecution.GoalValue> ports,String id) { for(var port:ports) if(port.port().value().equals(id)) return port; return null; }",
        ] {
            self.runtime_line(text);
        }
        for (index, signature) in providers.iter().enumerate() {
            self.provider_conversion(index, signature)?;
        }
        self.runtime_line("  private static SemanticExecution.ProviderResult<Result> decodeResult(SemanticExecution.ExecutionResult result) { try {");
        self.runtime_line("    if(result instanceof SemanticExecution.Success success) {");
        let mut goals = Vec::new();
        for (index, goal_output) in goal_outputs.iter().enumerate() {
            let local = format!("goal{index}");
            self.runtime_line(&format!(
                "      SemanticExecution.GoalValue {local}=goalPort(success.outputs(),{}); if({local}==null) return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"goal output missing\"));",
                quote(text(goal_output, "id")?)
            ));
            let contract = self.library_contract(field(goal_output, "contract")?)?;
            let port = self.port(contract);
            goals.push(format!(
                "readPort{port}(necoherence.semantic.WireJson.toWireSlot({local}.value()))"
            ));
        }
        self.runtime_line(&format!(
            "      return new SemanticExecution.ProviderSuccess<>(new Success(Goals.of({}))); }}",
            goals.join(",")
        ));
        self.runtime_line("    SemanticExecution.DeclaredFailure declared=(SemanticExecution.DeclaredFailure)result;");
        for embedding in list(&goal, "failures")? {
            let id = text(embedding, "id")?;
            let name = format!("{}Failure", prefix(id));
            let contract = self.library_contract(field(embedding, "contract")?)?;
            let port = self.port(contract);
            self.runtime_line(&format!(
                "    if(declared.embedding().value().equals({})) return new SemanticExecution.ProviderSuccess<>({name}.of(readPort{port}(necoherence.semantic.WireJson.toWireSlot(declared.value()))));",
                quote(id)
            ));
        }
        self.runtime_line("    return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"failure output missing\")); } catch(ValueRejection failure) { return new SemanticExecution.ProviderRejected<>(new SemanticExecution.Value(new SemanticValidation.ValueRejected(failure.failure()))); } }");
        self.runtime_line("  private static ProgressMapping mapProgress(SemanticExecution.RunResult result) { if(result instanceof SemanticExecution.RunRejected rejected) return new ProgressRejected(rejected.failure()); SemanticExecution.Progress progress=((SemanticExecution.Progressed)result).progress(); if(progress instanceof SemanticExecution.Pending pending) return new ProgressAccepted(new Pending(pending.execution(),pending.instruction())); SemanticExecution.Completed completed=(SemanticExecution.Completed)progress; SemanticExecution.ProviderResult<Result> decoded=decodeResult(completed.result()); if(decoded instanceof SemanticExecution.ProviderRejected<Result> rejected) return new ProgressRejected(new SemanticExecution.RunFailure(rejected.failure(),completed.network())); return new ProgressAccepted(new Completed(((SemanticExecution.ProviderSuccess<Result>)decoded).value(),completed.network())); }");
        let mut argument_values = Vec::new();
        for initial in &initial_arguments {
            let contract = self.library_contract(field(initial, "contract")?)?;
            let port = self.port(contract);
            argument_values.push(format!(
                "new SemanticExecution.ArgumentValue(new SemanticComposition.InputId({}),necoherence.semantic.WireJson.fromWireSlot(wirePort{port}(arguments.{}())))",
                quote(text(initial, "id")?),
                field_identifier(text(initial, "id")?)
            ));
        }
        self.runtime_line(&format!(
            "  private static List<SemanticExecution.ArgumentValue> argumentList(Arguments arguments) throws ValueRejection {{ return List.of({}); }}",
            argument_values.join(",")
        ));
        let runtime_name = self.runtime_name.clone();
        line(&mut self.out, &format!("  public static InitializeResult initialize() {{ return {runtime_name}.initialize(); }}"));
        self.runtime_line("  private static InitializeResult initialize() {");
        self.runtime_line("    CheckedGeneration checked;");
        self.runtime_line("    try { checked=TypeSignatures.admitGeneration(GenerationBasis.decode(generationBasisText()),generationDocumentText()); } catch(GenerationFailure failure) { return new InitializeRejected(failure); }");
        self.runtime_line("    var composition=checked.composition();");
        self.runtime_line("    if(composition==null) return new InitializeRejected(new GenerationFailure(\"$composition\",\"composition is absent\"));");
        self.runtime_line("    return new Initialized(checked,composition);");
        self.runtime_line("  }");
        line(&mut self.out, &format!("  public static RunResult run(Initialized initialized,Providers providers,Arguments arguments,NetworkEffect.NetworkState network) {{ return {runtime_name}.run(initialized,providers,arguments,network); }}"));
        self.runtime_line("  private static RunResult run(Initialized initialized,Providers providers,Arguments arguments,NetworkEffect.NetworkState network) {");
        self.runtime_line("    Objects.requireNonNull(initialized);Objects.requireNonNull(providers);Objects.requireNonNull(arguments);Objects.requireNonNull(network);");
        self.runtime_line("    var composition=initialized.composition;");
        self.runtime_line("    var preparedInput=composition.prepared();");
        let provider_list = self.provider_list("preparedInput")?;
        self.runtime_line(&format!(
            "    try {{ ProgressMapping mapped=mapProgress(SemanticExecution.start(composition,{provider_list},argumentList(arguments),network)); if(mapped instanceof ProgressRejected rejected)return new Rejected(rejected.failure()); return new Progressed(((ProgressAccepted)mapped).progress()); }} catch(ValueRejection failure) {{ return new Rejected(new SemanticExecution.RunFailure(new SemanticExecution.Value(new SemanticValidation.ValueRejected(failure.failure())),network)); }}"
        ));
        self.runtime_line("  }");
        line(&mut self.out, &format!("  public static ResumeResult resume(SemanticExecution.Execution execution,SemanticExecution.ExecutionObservation observation) {{ var result={runtime_name}.mapProgress(SemanticExecution.resume(execution,observation)); if(result instanceof {runtime_name}.ProgressRejected rejected)return new ResumeRejected(rejected.failure()); return new Progressed((({runtime_name}.ProgressAccepted)result).progress()); }}"));
        Ok(())
    }
}
