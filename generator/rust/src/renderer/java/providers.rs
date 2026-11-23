// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::emitter::Emitter;
use super::text::{
    collection, field, field_identifier, line, list, prefix, quote, tag, text, wire_text, Result,
};
use serde_json::Value;

impl Emitter {
    pub(super) fn provider(&mut self, index: usize, signature: &Value) -> Result<()> {
        let name = self.function(index)?;
        let outcomes = list(signature, "outcomes")?.to_vec();
        let inputs = self.ports_of(list(signature, "inputs")?)?;
        self.port_class(&format!("{name}Input"), &inputs, "", "")?;
        let mut variants = Vec::new();
        for outcome in &outcomes {
            let variant = Self::outcome_name(&name, outcome)?;
            self.reserve(&variant)?;
            variants.push(variant);
        }
        line(
            &mut self.out,
            &format!(
                "  public sealed interface {name}Outcome permits {} {{ String outcomeId(); void validate() throws ValueRejection; }}",
                variants.join(",")
            ),
        );
        for (outcome, variant) in outcomes.iter().zip(&variants) {
            let ports = self.ports_of(list(outcome, "value_ports")?)?;
            let method = format!(
                "    public String outcomeId() {{ return {}; }}",
                quote(text(outcome, "id")?)
            );
            self.port_class(
                variant,
                &ports,
                &format!(" implements {name}Outcome"),
                &method,
            )?;
        }
        if tag(field(signature, "effect")?)? != "HttpRequestResponse" {
            line(
                &mut self.out,
                &format!(
                    "  @FunctionalInterface public interface {name}Provider {{ String SIGNATURE_ASSUMPTION={}; SemanticExecution.ProviderResult<{name}Outcome> call({name}Input input); }}",
                    quote(text(signature, "assumption_ref")?)
                ),
            );
        } else {
            self.reserve(&format!("{name}HttpBinding"))?;
            self.provider_preparation(&name, &format!("{name}Input"), &format!("{name}Outcome"));
            line(
                &mut self.out,
                &format!(
                    "  @FunctionalInterface public interface {name}Decoder {{ SemanticExecution.ProviderResult<{name}Outcome> decode(NetworkEffect.RawHttpResponse response); }}"
                ),
            );
            line(
                &mut self.out,
                &format!(
                    "  public record {name}HttpBinding({name}Binding prepare,{name}Decoder decoder) {{ public {name}HttpBinding {{Objects.requireNonNull(prepare);Objects.requireNonNull(decoder);}} }}"
                ),
            );
        }
        Ok(())
    }

    pub(super) fn provider_preparation(
        &mut self,
        name: &str,
        input_type: &str,
        outcome_type: &str,
    ) {
        line(
            &mut self.out,
            &format!("  public sealed interface {name}Preparation permits {name}Ready,{name}Completed {{}}"),
        );
        line(
            &mut self.out,
            &format!("  public record {name}Ready(NetworkEffect.AttemptInput input) implements {name}Preparation {{public {name}Ready {{Objects.requireNonNull(input);}}}}"),
        );
        line(
            &mut self.out,
            &format!("  public record {name}Completed({outcome_type} outcome) implements {name}Preparation {{public {name}Completed {{Objects.requireNonNull(outcome);}}}}"),
        );
        line(
            &mut self.out,
            &format!("  @FunctionalInterface public interface {name}Binding {{ SemanticExecution.ProviderResult<{name}Preparation> prepare({input_type} input); }}"),
        );
    }

    pub(super) fn signature_definitions(&mut self) -> Result<()> {
        line(&mut self.out, "  @FunctionalInterface public interface Decoder<T> { T decode(String wire) throws ValueRejection; }");
        line(&mut self.out, "  @FunctionalInterface public interface Encoder<T> { String encode(T value) throws ValueRejection; }");
        line(&mut self.out, "  public record Codec<T>(Decoder<T> decoder,Decoder<T> defaultDecoder,Encoder<T> encoder) { public T decodeWithDefaults(String wire) throws ValueRejection { return defaultDecoder.decode(wire); } }");
        let rt = self.runtime_name.clone();
        let mut type_entries = Vec::new();
        let mut codec_entries = Vec::new();
        for ty in self.types.clone() {
            let definition_name = self.definition_name(ty)?;
            let storage = self.storage(ty)?;
            let type_ref = self.type_ref(ty);
            type_entries.push(format!(
                "value.put({},{});",
                quote(&definition_name),
                quote(&storage)
            ));
            codec_entries.push(format!(
                "value.put({},new Codec<{storage}>(wire->{{necoherence.semantic.Checked checked={rt}.CONTEXT.decodeChecked({type_ref},wire);return {rt}.read{ty}(checked,checked.value());}},wire->{{necoherence.semantic.Checked checked={rt}.CONTEXT.decodeCheckedWithDefaults({type_ref},wire);return {rt}.read{ty}(checked,checked.value());}},item->{{WireValue wire={rt}.write{ty}(item);{rt}.CONTEXT.validate({type_ref},wire);return SemanticValues.encodeWire(wire);}}));",
                quote(&definition_name)
            ));
        }
        let type_names = collection(
            &mut self.out,
            &mut self.initializer_id,
            "Map<String,String>",
            "new HashMap<>()",
            "Map.copyOf(value)",
            &type_entries,
        );
        line(
            &mut self.out,
            &format!("  public static final Map<String,String> TYPE_NAMES={type_names};"),
        );
        let codecs = collection(
            &mut self.out,
            &mut self.initializer_id,
            "Map<String,Codec<?>>",
            "new HashMap<>()",
            "Map.copyOf(value)",
            &codec_entries,
        );
        line(
            &mut self.out,
            &format!("  public static final Map<String,Codec<?>> CODECS={codecs};"),
        );
        line(&mut self.out, &format!("  public static final List<WireValue> ANNOTATIONS=List.copyOf({rt}.LIBRARY.annotations());"));
        line(&mut self.out, "  public static List<WireValue> annotations(WireValue target) { return ANNOTATIONS.stream().filter(value->SemanticValues.f(value,\"target\").equals(target)).toList(); }");
        let mut declaration_entries = Vec::new();
        for definition in self.definitions.clone() {
            declaration_entries.push(format!(
                "value.put({},TypeSignatures.parseWire({}));",
                quote(text(&definition, "id")?),
                quote(&wire_text(&definition))
            ));
        }
        let declarations = collection(
            &mut self.out,
            &mut self.initializer_id,
            "Map<String,WireValue>",
            "new HashMap<>()",
            "Map.copyOf(value)",
            &declaration_entries,
        );
        line(
            &mut self.out,
            &format!("  public static final Map<String,WireValue> DECLARATIONS={declarations};"),
        );
        for definition in self.definitions.clone() {
            let name = prefix(text(&definition, "id")?);
            let shape = field(&definition, "shape")?.clone();
            match tag(&shape)? {
                "Symbol" => {
                    let symbol = text(&shape, "value")?;
                    line(
                        &mut self.out,
                        &format!(
                            "  public static final String {name}Symbol={};",
                            quote(symbol)
                        ),
                    );
                }
                "Operation" => {
                    let operation = field(&shape, "value")?.clone();
                    self.signature_operation(&name, &operation)?;
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn signature_operation(&mut self, name: &str, operation: &Value) -> Result<()> {
        self.reserve(&format!("{name}OperationInput"))?;
        let inputs = self.ports_of(list(operation, "inputs")?)?;
        self.port_class(&format!("{name}OperationInput"), &inputs, "", "")?;
        let outcomes = list(operation, "outcomes")?.to_vec();
        let mut variants = Vec::new();
        for outcome in &outcomes {
            variants.push(format!("{name}{}", prefix(text(outcome, "id")?)));
        }
        line(
            &mut self.out,
            &format!(
                "  public sealed interface {name}Outcome permits {} {{ String outcomeId(); void validate() throws ValueRejection; }}",
                variants.join(",")
            ),
        );
        for (outcome, variant) in outcomes.iter().zip(&variants) {
            self.reserve(variant)?;
            let ports = self.ports_of(list(outcome, "value_ports")?)?;
            let method = format!(
                "    public String outcomeId(){{return {};}}",
                quote(text(outcome, "id")?)
            );
            self.port_class(
                variant,
                &ports,
                &format!(" implements {name}Outcome"),
                &method,
            )?;
        }
        if tag(field(operation, "effect")?)? == "HttpRequestResponse" {
            self.provider_preparation(
                name,
                &format!("{name}OperationInput"),
                &format!("{name}Outcome"),
            );
            let mut permitted = Vec::new();
            for outcome in &outcomes {
                if tag(field(outcome, "cause")?)? == "ExternalCondition"
                    && tag(field(outcome, "form")?)? == "DeclaredFailure"
                {
                    permitted.push(quote(text(outcome, "id")?));
                }
            }
            let permitted = format!("Set.of({})", permitted.join(","));
            line(
                &mut self.out,
                &format!(
                    "  public static SemanticExecution.ProviderResult<{name}Preparation> prepare{name}({name}OperationInput input,{name}Binding binding) {{ try {{ input.validate(); var supplied=binding.prepare(input); if(supplied==null)return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider preparation representation\")); if(supplied instanceof SemanticExecution.ProviderRejected<{name}Preparation> rejected)return rejected; var prepared=((SemanticExecution.ProviderSuccess<{name}Preparation>)supplied).value(); if(prepared==null)return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider preparation representation\")); if(prepared instanceof {name}Completed completed&&!{permitted}.contains(completed.outcome().outcomeId()))return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"undeclared external completion\")); return new SemanticExecution.ProviderSuccess<>(prepared); }} catch(ValueRejection failure) {{ return new SemanticExecution.ProviderRejected<>(new SemanticExecution.Value(new SemanticValidation.ValueRejected(failure.failure()))); }} }}"
                ),
            );
        }
        Ok(())
    }

    pub(super) fn provider_conversion(&mut self, index: usize, signature: &Value) -> Result<()> {
        let name = self.function(index)?;
        let inputs = list(signature, "inputs")?.to_vec();
        let mut arguments = Vec::new();
        self.runtime_line(&format!("  private static SemanticExecution.ProviderResult<{name}Input> arguments{name}(List<SemanticExecution.PortValue> ports) {{ try {{"));
        for (position, input) in inputs.iter().enumerate() {
            let local = format!("port{position}");
            self.runtime_line(&format!(
                "    SemanticExecution.PortValue {local}=providerPort(ports,{}); if({local}==null) return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"missing provider input\"));",
                quote(text(input, "id")?)
            ));
            let contract = self.library_contract(field(input, "contract")?)?;
            let port = self.port(contract);
            arguments.push(format!(
                "readPort{port}(necoherence.semantic.WireJson.toWireSlot({local}.value()))"
            ));
        }
        self.runtime_line(&format!(
            "    return new SemanticExecution.ProviderSuccess<>({name}Input.of({})); }} catch(ValueRejection failure) {{ return new SemanticExecution.ProviderRejected<>(new SemanticExecution.Value(new SemanticValidation.ValueRejected(failure.failure()))); }} }}",
            arguments.join(",")
        ));
        self.runtime_line(&format!("  private static SemanticExecution.ProviderResult<SemanticExecution.CallResult> result{name}(SemanticExecution.ProviderResult<{name}Outcome> supplied) {{ if(supplied==null) return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider result representation\")); if(supplied instanceof SemanticExecution.ProviderRejected<{name}Outcome> rejected) return new SemanticExecution.ProviderRejected<>(rejected.failure()); {name}Outcome outcome=((SemanticExecution.ProviderSuccess<{name}Outcome>)supplied).value(); if(outcome==null) return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider result representation\")); try {{"));
        for outcome in list(signature, "outcomes")? {
            let variant = Self::outcome_name(&name, outcome)?;
            let mut outputs = Vec::new();
            for output in list(outcome, "value_ports")? {
                let contract = self.library_contract(field(output, "contract")?)?;
                let port = self.port(contract);
                outputs.push(format!(
                    "new SemanticExecution.PortValue(new SemanticComposition.PortId({}),necoherence.semantic.WireJson.fromWireSlot(wirePort{port}(value.{}())))",
                    quote(text(output, "id")?),
                    field_identifier(text(output, "id")?)
                ));
            }
            self.runtime_line(&format!(
                "    if(outcome instanceof {variant} value) return new SemanticExecution.ProviderSuccess<>(new SemanticExecution.CallResult(new SemanticComposition.OutcomeId({}),List.of({}))); ",
                quote(text(outcome, "id")?),
                outputs.join(",")
            ));
        }
        self.runtime_line("    return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider result representation\")); } catch(ValueRejection failure) { return new SemanticExecution.ProviderRejected<>(new SemanticExecution.Value(new SemanticValidation.ValueRejected(failure.failure()))); } }");
        Ok(())
    }

    pub(super) fn provider_list(&mut self, prepared: &str) -> Result<String> {
        let mut values = Vec::new();
        for (index, signature) in self.providers.clone().iter().enumerate() {
            let name = self.function(index)?;
            let field_name = self.provider_field(index)?;
            let reference = format!("{prepared}.input().signatures().get({index}).reference()");
            if tag(field(signature, "effect")?)? != "HttpRequestResponse" {
                values.push(format!(
                    "new SemanticExecution.Provider({reference},new SemanticExecution.PureProvider(ports->{{var converted=arguments{name}(ports);if(converted instanceof SemanticExecution.ProviderRejected<{name}Input> rejected)return new SemanticExecution.ProviderRejected<>(rejected.failure());return result{name}(providers.{field_name}().call(((SemanticExecution.ProviderSuccess<{name}Input>)converted).value()));}}))"
                ));
            } else {
                let mut permitted = Vec::new();
                for outcome in list(signature, "outcomes")? {
                    if tag(field(outcome, "cause")?)? == "ExternalCondition"
                        && tag(field(outcome, "form")?)? == "DeclaredFailure"
                    {
                        permitted.push(quote(text(outcome, "id")?));
                    }
                }
                let permitted = format!("Set.of({})", permitted.join(","));
                values.push(format!(
                    "new SemanticExecution.Provider({reference},new SemanticExecution.PreparedHttpProvider(new SemanticExecution.PreparedNetworkOwner(ports->{{var converted=arguments{name}(ports);if(converted instanceof SemanticExecution.ProviderRejected<{name}Input> rejected)return new SemanticExecution.ProviderRejected<>(rejected.failure());var supplied=providers.{field_name}().prepare().prepare(((SemanticExecution.ProviderSuccess<{name}Input>)converted).value());if(supplied==null)return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider preparation representation\"));if(supplied instanceof SemanticExecution.ProviderRejected<{name}Preparation> rejected)return new SemanticExecution.ProviderRejected<>(rejected.failure());var prepared=((SemanticExecution.ProviderSuccess<{name}Preparation>)supplied).value();if(prepared==null)return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"provider preparation representation\"));if(prepared instanceof {name}Ready ready)return new SemanticExecution.ProviderSuccess<>(new SemanticExecution.Ready(ready.input()));var completed=({name}Completed)prepared;if(!{permitted}.contains(completed.outcome().outcomeId()))return new SemanticExecution.ProviderRejected<>(new SemanticExecution.InvalidPlan(\"undeclared external completion\"));var result=result{name}(new SemanticExecution.ProviderSuccess<>(completed.outcome()));if(result instanceof SemanticExecution.ProviderRejected<SemanticExecution.CallResult> rejected)return new SemanticExecution.ProviderRejected<>(rejected.failure());return new SemanticExecution.ProviderSuccess<>(new SemanticExecution.CompletedCall(((SemanticExecution.ProviderSuccess<SemanticExecution.CallResult>)result).value()));}},response->result{name}(providers.{field_name}().decoder().decode(response)))))"
                ));
            }
        }
        Ok(format!("List.of({})", values.join(",")))
    }
}
