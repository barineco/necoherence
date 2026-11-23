// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::text::{
    chunks, collection, emission, field, field_identifier, flag, line, list, prefix, quote, tag,
    text, utf16_length, wire_text, Result,
};
use serde_json::Value;
use std::collections::HashSet;

const RESERVED: &[&str] = &[
    "Arguments",
    "Goals",
    "Providers",
    "Result",
    "Success",
    "RunProgress",
    "Completed",
    "Pending",
    "RunResult",
    "Progressed",
    "Rejected",
    "Admission",
];

const HELPERS: &[&str] = &[
    "  @FunctionalInterface private interface Writer<T> { WireValue write(T value) throws ValueRejection; }",
    "  private static <T> T nonNull(T value,WireValue reference,List<WireValue> path) throws ValueRejection { if(value==null) throw new ValueRejection(reference,path,SimpleValueCondition.NULL_NOT_ALLOWED,List.of(),new NullSlot<>()); if(value instanceof String text) for(int i=0;i<text.length();i++){ char c=text.charAt(i); if(Character.isHighSurrogate(c)){ if(++i==text.length() || !Character.isLowSurrogate(text.charAt(i))) throw new ValueRejection(reference,path,SimpleValueCondition.INVALID_DATA_MODEL,List.of(),new Present<>(new necoherence.semantic.ExactJson.JsonStr(text))); } else if(Character.isLowSurrogate(c)) throw new ValueRejection(reference,path,SimpleValueCondition.INVALID_DATA_MODEL,List.of(),new Present<>(new necoherence.semantic.ExactJson.JsonStr(text))); } return value; }",
    "  private static WireValue parseWire(WireValue reference,String wire) { return SemanticGeneration.readJson(wire); }",
    "  private static <T> Slot<WireValue> wireSlot(Slot<T> value, Writer<T> writer) throws ValueRejection { if(value instanceof Absent<T>) return new Absent<>(); if(value instanceof NullSlot<T>) return new NullSlot<>(); return new Present<>(writer.write(((Present<T>)value).value())); }",
    "  private static Slot<WireValue> field(WireValue value) { return value == null ? new Absent<>() : value instanceof NullValue ? new NullSlot<>() : new Present<>(value); }",
    "  private static WireValue scalar(Slot<WireValue> value) { return ((Present<WireValue>)value).value(); }",
    "  private static WireValue tagged(WireValue reference,WireValue value, String tag) throws ValueRejection { ObjectValue object=(ObjectValue)value; WireValue previous=object.get($TAG$); if(previous != null && !new StringValue(tag).equals(previous)) throw new ValueRejection(reference,List.of(SemanticValues.variant(\"Field\",new StringValue($TAG$))),SimpleValueCondition.INVALID_TAG,List.of(),new Present<>(necoherence.semantic.WireJson.fromWire(previous))); if(previous != null) return value; return SemanticValues.withMember($TAG$,tag,value); }",
    "  private static void put(List<Member> fields,String key,Slot<WireValue> value) { if(value instanceof Present<WireValue> present) fields.add(new Member(key,present.value())); else if(value instanceof NullSlot<WireValue>) fields.add(new Member(key,new NullValue())); }",
    "  private static Map<String,WireValue> extras(ObjectValue value,Set<String> known) { Map<String,WireValue> result=new LinkedHashMap<>(); for(Member member:value.members()) if(!known.contains(member.key())) result.put(member.key(),member.value()); return result; }",
    "  private static Map<String,WireValue> copyExtra(Map<String,WireValue> value,Set<String> known,WireValue reference) throws ValueRejection { Map<String,WireValue> result=new LinkedHashMap<>(); for(var entry:nonNull(value,reference,List.of()).entrySet()){ List<WireValue> path=List.of(SemanticValues.variant(\"Field\",new StringValue(entry.getKey()))); if(known.contains(entry.getKey())) throw new ValueRejection(reference,path,new UnexpectedField(entry.getKey()),List.of(),new Present<>(necoherence.semantic.WireJson.fromWire(entry.getValue()))); result.put(entry.getKey(),nonNull(entry.getValue(),reference,path)); } return Collections.unmodifiableMap(result); }",
    "  private static WireValue bytesWire(Bytes value) { return $RUNTIME$.CONTEXT.encodeBytes(value); }",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Contract {
    pub(super) ty: usize,
    pub(super) required: bool,
    pub(super) nullable: bool,
}

#[derive(Clone, Debug)]
pub(super) struct Port {
    pub(super) id: String,
    pub(super) contract: Contract,
}

#[derive(Clone, Debug)]
pub(super) struct Field {
    pub(super) wire: String,
    pub(super) name: String,
    pub(super) java_type: String,
    pub(super) read: String,
    pub(super) write: String,
    pub(super) reference: Value,
}

pub(super) struct Model {
    pub(super) graph: Value,
    pub(super) library: Value,
    pub(super) entrypoints: Vec<String>,
    pub(super) composition: Option<Value>,
    pub(super) generation_document: String,
    pub(super) generation_basis: String,
}

pub(super) struct Emitter {
    pub(super) package_name: String,
    pub(super) class_name: String,
    pub(super) nodes: Vec<Value>,
    pub(super) definition_names: Vec<String>,
    pub(super) names: Vec<String>,
    pub(super) types: Vec<usize>,
    pub(super) graph: Value,
    pub(super) library: Value,
    pub(super) problem: Option<Value>,
    pub(super) generation_document: String,
    pub(super) generation_basis: String,
    pub(super) tag_key: String,
    pub(super) integer_profile: Value,
    pub(super) providers: Vec<Value>,
    pub(super) functions: Vec<String>,
    pub(super) definitions: Vec<Value>,
    pub(super) contracts: Vec<Contract>,
    pub(super) reserved: HashSet<String>,
    pub(super) runtime_name: String,
    pub(super) initializer_id: usize,
    pub(super) out: String,
    pub(super) runtime: String,
}

impl Emitter {
    pub(super) fn new(model: Model, package_name: &str, class_name: &str) -> Result<Self> {
        let nodes = list(&model.graph, "nodes")?.to_vec();
        let mut definition_names = Vec::with_capacity(nodes.len());
        for node in &nodes {
            definition_names.push(text(field(node, "reference")?, "definition_name")?.to_owned());
        }
        let mut types: Vec<usize> = (0..nodes.len()).collect();
        types.sort_by_key(|&index| definition_names.get(index).cloned().unwrap_or_default());
        let profile = field(&model.graph, "profile")?.clone();
        let tag_key = match profile.get("tag") {
            None | Some(Value::Null) => String::new(),
            Some(tag_model) => text(tag_model, "key")?.to_owned(),
        };
        let problem = model.composition;
        let providers = match &problem {
            Some(problem) => list(problem, "signatures")?.to_vec(),
            None => Vec::new(),
        };
        let mut functions = Vec::with_capacity(providers.len());
        for provider in &providers {
            functions.push(prefix(text(field(provider, "reference")?, "identity")?));
        }
        let library_definitions = list(&model.library, "definitions")?.to_vec();
        let mut definitions = Vec::new();
        for entry in &model.entrypoints {
            let definition = library_definitions
                .iter()
                .find(|candidate| candidate.get("id").and_then(Value::as_str) == Some(entry))
                .ok_or_else(|| emission(format!("unresolved entrypoint {entry}")))?;
            definitions.push(definition.clone());
        }
        let mut emitter = Self {
            package_name: package_name.to_owned(),
            class_name: class_name.to_owned(),
            names: vec![String::new(); nodes.len()],
            nodes,
            definition_names,
            types,
            graph: model.graph,
            library: model.library,
            problem,
            generation_document: model.generation_document,
            generation_basis: model.generation_basis,
            tag_key,
            integer_profile: profile,
            providers,
            functions,
            definitions,
            contracts: Vec::new(),
            reserved: RESERVED.iter().map(|name| (*name).to_owned()).collect(),
            runtime_name: String::new(),
            initializer_id: 0,
            out: String::new(),
            runtime: String::new(),
        };
        emitter.reserve(class_name)?;
        for ty in emitter.types.clone() {
            let name = format!("Type{}", prefix(&emitter.definition_name(ty)?));
            emitter.reserve(&name)?;
            *emitter
                .names
                .get_mut(ty)
                .ok_or_else(|| emission("type name"))? = name;
        }
        for (index, provider) in emitter.providers.clone().iter().enumerate() {
            let name = emitter.function(index)?;
            emitter.reserve(&format!("{name}Input"))?;
            emitter.reserve(&format!("{name}Outcome"))?;
            emitter.reserve(&format!("{name}Provider"))?;
            for port in list(provider, "inputs")? {
                let contract = emitter.library_contract(field(port, "contract")?)?;
                emitter.port(contract);
            }
            for outcome in list(provider, "outcomes")? {
                for output in list(outcome, "value_ports")? {
                    let contract = emitter.library_contract(field(output, "contract")?)?;
                    emitter.port(contract);
                }
            }
        }
        for definition in emitter.definitions.clone() {
            let shape = field(&definition, "shape")?;
            if tag(shape)? == "Operation" {
                let operation = emitter.payload(shape)?.clone();
                for port in list(&operation, "inputs")? {
                    let contract = emitter.library_contract(field(port, "contract")?)?;
                    emitter.port(contract);
                }
                for outcome in list(&operation, "outcomes")? {
                    for port in list(outcome, "value_ports")? {
                        let contract = emitter.library_contract(field(port, "contract")?)?;
                        emitter.port(contract);
                    }
                }
            }
        }
        for ty in emitter.types.clone() {
            let shape = emitter.shape(ty)?.clone();
            if tag(&shape)? == "Product" {
                for spec in list(emitter.payload(&shape)?, "fields")? {
                    let contract = emitter.graph_contract(field(spec, "slot")?)?;
                    emitter.port(contract);
                }
            }
        }
        if let Some(problem) = emitter.problem.clone() {
            let goal = field(&problem, "goal")?;
            for initial in list(&problem, "initial_inputs")? {
                let contract = emitter.library_contract(field(initial, "contract")?)?;
                emitter.port(contract);
            }
            for output in list(goal, "outputs")? {
                let contract = emitter.library_contract(field(output, "contract")?)?;
                emitter.port(contract);
            }
            for failure in list(goal, "failures")? {
                let contract = emitter.library_contract(field(failure, "contract")?)?;
                emitter.port(contract);
            }
        }
        emitter.runtime_name = emitter.runtime_identifier()?;
        let runtime_name = emitter.runtime_name.clone();
        emitter.reserve(&runtime_name)?;
        Ok(emitter)
    }

    pub(super) fn reserve(&mut self, name: &str) -> Result<()> {
        if !self.reserved.insert(name.to_owned()) {
            return Err(emission(format!("Java identifier collision: {name}")));
        }
        Ok(())
    }

    pub(super) fn function(&self, index: usize) -> Result<String> {
        self.functions
            .get(index)
            .cloned()
            .ok_or_else(|| emission("provider index"))
    }

    pub(super) fn provider_field(&self, index: usize) -> Result<String> {
        let name = self.function(index)?;
        let mut characters = name.chars();
        let first = characters.next().ok_or_else(|| emission("provider name"))?;
        Ok(format!(
            "{}{}",
            first.to_ascii_lowercase(),
            characters.as_str()
        ))
    }

    pub(super) fn outcome_name(function: &str, outcome: &Value) -> Result<String> {
        Ok(format!("{function}Outcome{}", prefix(text(outcome, "id")?)))
    }

    fn runtime_identifier(&self) -> Result<String> {
        let mut forbidden = self.reserved.clone();
        forbidden.insert(self.class_name.clone());
        for &ty in &self.types {
            let shape = self.shape(ty)?;
            if tag(shape)? == "Product" {
                for spec in list(self.payload(shape)?, "fields")? {
                    forbidden.insert(field_identifier(text(spec, "wire_name")?));
                }
            } else if tag(shape)? == "TaggedUnion" {
                let branches = list(self.payload(shape)?, "branches")?;
                for index in 0..branches.len() {
                    forbidden.insert(format!("{}Branch{index}", self.name(ty)?));
                }
            }
        }
        for index in 0..self.providers.len() {
            let name = self.function(index)?;
            let provider = self
                .providers
                .get(index)
                .ok_or_else(|| emission("provider index"))?;
            self.operation_names(&mut forbidden, &name, provider)?;
            forbidden.insert(self.provider_field(index)?);
            for outcome in list(provider, "outcomes")? {
                forbidden.insert(Self::outcome_name(&name, outcome)?);
            }
        }
        for definition in &self.definitions {
            let name = prefix(text(definition, "id")?);
            let shape = field(definition, "shape")?;
            if tag(shape)? == "Operation" {
                self.operation_names(&mut forbidden, &name, self.payload(shape)?)?;
            } else if tag(shape)? == "Symbol" {
                forbidden.insert(format!("{name}Symbol"));
            }
        }
        if let Some(problem) = &self.problem {
            let goal = field(problem, "goal")?;
            self.port_names(&mut forbidden, list(problem, "initial_inputs")?)?;
            self.port_names(&mut forbidden, list(goal, "outputs")?)?;
            for failure in list(goal, "failures")? {
                forbidden.insert(format!("{}Failure", prefix(text(failure, "id")?)));
            }
        }
        let mut name = "_Runtime".to_owned();
        while forbidden.contains(&name) {
            name.push('_');
        }
        Ok(name)
    }

    fn operation_names(
        &self,
        forbidden: &mut HashSet<String>,
        name: &str,
        operation: &Value,
    ) -> Result<()> {
        for suffix in [
            "Input",
            "Outcome",
            "Provider",
            "HttpBinding",
            "OperationInput",
            "Preparation",
            "Ready",
            "Completed",
            "Binding",
            "Start",
            "Prepared",
            "Started",
        ] {
            forbidden.insert(format!("{name}{suffix}"));
        }
        self.port_names(forbidden, list(operation, "inputs")?)?;
        for outcome in list(operation, "outcomes")? {
            forbidden.insert(format!("{name}{}", prefix(text(outcome, "id")?)));
            self.port_names(forbidden, list(outcome, "value_ports")?)?;
        }
        Ok(())
    }

    fn port_names(&self, forbidden: &mut HashSet<String>, ports: &[Value]) -> Result<()> {
        for port in ports {
            forbidden.insert(field_identifier(text(port, "id")?));
        }
        Ok(())
    }

    pub(super) fn shape(&self, ty: usize) -> Result<&Value> {
        let node = self.nodes.get(ty).ok_or_else(|| emission("type index"))?;
        field(node, "shape")
    }

    pub(super) fn payload<'v>(&self, shape: &'v Value) -> Result<&'v Value> {
        match tag(shape)? {
            "Alias" | "Sealed" => field(shape, "fields"),
            _ => field(shape, "value"),
        }
    }

    pub(super) fn reference_of(&self, ty: usize) -> Result<Value> {
        let node = self.nodes.get(ty).ok_or_else(|| emission("type index"))?;
        Ok(field(node, "reference")?.clone())
    }

    pub(super) fn index_of(&self, id: &str) -> Result<usize> {
        self.definition_names
            .iter()
            .position(|name| name == id)
            .ok_or_else(|| emission(format!("type outside admitted surface {id}")))
    }

    pub(super) fn library_contract(&self, slot: &Value) -> Result<Contract> {
        Ok(Contract {
            ty: self.index_of(text(slot, "type_id")?)?,
            required: flag(slot, "required")?,
            nullable: flag(slot, "nullable")?,
        })
    }

    pub(super) fn graph_contract(&self, slot: &Value) -> Result<Contract> {
        Ok(Contract {
            ty: self.index_of(text(field(slot, "type_ref")?, "definition_name")?)?,
            required: flag(slot, "required")?,
            nullable: flag(slot, "nullable")?,
        })
    }

    pub(super) fn ports_of(&self, slots: &[Value]) -> Result<Vec<Port>> {
        slots
            .iter()
            .map(|port| {
                Ok(Port {
                    id: text(port, "id")?.to_owned(),
                    contract: self.library_contract(field(port, "contract")?)?,
                })
            })
            .collect()
    }

    pub(super) fn port(&mut self, contract: Contract) -> usize {
        if let Some(index) = self.contracts.iter().position(|known| *known == contract) {
            return index;
        }
        self.contracts.push(contract);
        self.contracts.len() - 1
    }

    pub(super) fn definition_name(&self, ty: usize) -> Result<String> {
        self.definition_names
            .get(ty)
            .cloned()
            .ok_or_else(|| emission("type index"))
    }

    pub(super) fn name(&self, ty: usize) -> Result<String> {
        self.names
            .get(ty)
            .cloned()
            .ok_or_else(|| emission("type name"))
    }

    pub(super) fn type_ref(&self, ty: usize) -> String {
        format!("{}.CONTEXT.reference({ty})", self.runtime_name)
    }

    pub(super) fn storage(&self, ty: usize) -> Result<String> {
        Ok(match tag(self.shape(ty)?)? {
            "Boolean" => "Boolean".to_owned(),
            "Integer" => "BigInteger".to_owned(),
            "Decimal" | "String" => "String".to_owned(),
            "Bytes" | "RawBody" => "Bytes".to_owned(),
            "Unit" => "Unit".to_owned(),
            "Unknown" => "WireValue".to_owned(),
            _ => self.name(ty)?,
        })
    }

    pub(super) fn native_port(&self, contract: &Contract) -> Result<String> {
        let ty = self.storage(contract.ty)?;
        Ok(match (contract.required, contract.nullable) {
            (true, true) => format!("Nullable<{ty}>"),
            (true, false) => ty,
            (false, true) => format!("Slot<{ty}>"),
            (false, false) => format!("Optional<{ty}>"),
        })
    }

    pub(super) fn runtime_line(&mut self, text: &str) {
        line(&mut self.runtime, text);
    }

    pub(super) fn embed(&mut self, method: &str, text: &str) {
        let statements: Vec<String> = chunks(text, 4000)
            .iter()
            .map(|chunk| format!("value.append({});", quote(chunk)))
            .collect();
        let initialized = collection(
            &mut self.runtime,
            &mut self.initializer_id,
            "StringBuilder",
            &format!("new StringBuilder({})", utf16_length(text)),
            "value",
            &statements,
        );
        line(
            &mut self.runtime,
            &format!("  private static String {method}() {{ return {initialized}.toString(); }}"),
        );
    }

    pub(super) fn emit(&mut self) -> Result<String> {
        let runtime_name = self.runtime_name.clone();
        let package_name = self.package_name.clone();
        let class_name = self.class_name.clone();
        for header in crate::renderer::generated_header_lines("//") {
            line(&mut self.out, &header);
        }
        if !package_name.is_empty() {
            line(&mut self.out, &format!("package {package_name};"));
        }
        for import in [
            "import necoherence.semantic.TypeSignatures;",
            "import java.math.BigInteger;",
            "import java.util.*;",
            "import necoherence.semantic.SemanticGeneration;",
            "import necoherence.semantic.SemanticGeneration.*;",
            "import necoherence.semantic.SemanticValues;",
            "import necoherence.semantic.SemanticValidation;",
            "import necoherence.semantic.SemanticValues.*;",
            "import necoherence.network.NetworkEffect;",
            "import necoherence.composition.SignatureCompositionWire;",
            "import necoherence.composition.SemanticComposition;",
            "import necoherence.composition.SemanticExecution;",
        ] {
            line(&mut self.out, import);
        }
        line(
            &mut self.out,
            &format!("public final class {class_name} {{"),
        );
        line(
            &mut self.out,
            &format!(
                "  public static final String GENERATION_PACKAGE = {};",
                quote(&package_name)
            ),
        );
        line(
            &mut self.out,
            &format!(
                "  public static final String GENERATION_CLASS = {};",
                quote(&class_name)
            ),
        );
        line(&mut self.out, &format!("  private {class_name}() {{}}"));
        self.runtime_line(
            "  private static final TypeSignatures.TypeSignatureLibrary LIBRARY = loadLibrary();",
        );
        self.runtime_line("  private static final WireValue LIBRARY_VALUE = TypeSignatures.parseWire(LIBRARY.encode());");
        self.runtime_line("  private static final Context CONTEXT = new Context(TypeSignatures.parseWire(contextText()));");
        self.runtime_line("  private static TypeSignatures.TypeSignatureLibrary loadLibrary() { try { return TypeSignatures.TypeSignatureLibrary.decode(libraryText()); } catch (GenerationFailure failure) { throw new ExceptionInInitializerError(failure); } }");
        let library_text = wire_text(&self.library);
        self.embed("libraryText", &library_text);
        let graph_text = wire_text(&self.graph);
        self.embed("contextText", &graph_text);
        if self.problem.is_some() {
            let document = self.generation_document.clone();
            let basis = self.generation_basis.clone();
            self.embed("generationDocumentText", &document);
            self.embed("generationBasisText", &basis);
        }
        self.helpers();
        for ty in self.types.clone() {
            self.type_declaration(ty)?;
        }
        for (id, contract) in self.contracts.clone().into_iter().enumerate() {
            self.port_codec(&contract, id)?;
        }
        for (index, provider) in self.providers.clone().iter().enumerate() {
            self.provider(index, provider)?;
        }
        self.signature_definitions()?;
        if self.problem.is_some() {
            self.composition()?;
        }
        line(
            &mut self.out,
            &format!("  private static final class {runtime_name} {{"),
        );
        let runtime = std::mem::take(&mut self.runtime);
        for text in runtime.lines() {
            line(&mut self.out, &format!("  {text}"));
        }
        line(&mut self.out, "  }");
        line(&mut self.out, "}");
        Ok(std::mem::take(&mut self.out))
    }

    fn helpers(&mut self) {
        let runtime_name = self.runtime_name.clone();
        let discriminator = quote(&self.tag_key);
        for helper in HELPERS {
            let text = helper
                .replace("$RUNTIME$", &runtime_name)
                .replace("$TAG$", &discriminator);
            self.runtime_line(&text);
        }
    }

    fn type_declaration(&mut self, ty: usize) -> Result<()> {
        let kind = tag(self.shape(ty)?)?.to_owned();
        match kind.as_str() {
            "Product" => self.product(ty)?,
            "TaggedUnion" => self.union(ty)?,
            "Array" => self.array(ty)?,
            "Sealed" => self.opaque_carrier(ty)?,
            "Never" => self.never(ty)?,
            _ => self.scalar_type(ty)?,
        }
        self.codec(ty)
    }

    fn codec(&mut self, ty: usize) -> Result<()> {
        let kind = tag(self.shape(ty)?)?.to_owned();
        let native = self.storage(ty)?;
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        if kind == "Never" {
            self.runtime_line(&format!("  private static {native} read{ty}(necoherence.semantic.Checked checked,WireValue value) throws ValueRejection {{ throw new ValueRejection({type_ref},List.of(),SimpleValueCondition.UNINHABITED,List.of(),new Present<>(necoherence.semantic.WireJson.fromWire(value))); }}"));
            self.runtime_line(&format!("  private static WireValue write{ty}({native} value) throws ValueRejection {{ nonNull(value,{type_ref},List.of()); throw new AssertionError(\"uninhabited type\"); }}"));
            return Ok(());
        }
        let (read, write) = match kind.as_str() {
            "Boolean" => (
                "((BooleanValue)value).value()".to_owned(),
                "new BooleanValue(value)".to_owned(),
            ),
            "Integer" => (
                format!("{rt}.CONTEXT.integerValue({type_ref},value)"),
                self.integer_wire(ty, "value")?,
            ),
            "Decimal" => (
                "((DecimalValue)value).text()".to_owned(),
                "new DecimalValue(value)".to_owned(),
            ),
            "String" => (
                format!("{rt}.CONTEXT.decodeText({type_ref},value)"),
                format!("{rt}.CONTEXT.encodeText({type_ref},value)"),
            ),
            "Bytes" | "RawBody" => (
                format!("{rt}.CONTEXT.bytes(checked,value)"),
                "bytesWire(value)".to_owned(),
            ),
            "Unit" => ("Unit.VALUE".to_owned(), "new NullValue()".to_owned()),
            "Unknown" => ("value".to_owned(), "value".to_owned()),
            _ => (
                format!("{}.decoded(checked,value)", self.name(ty)?),
                "value.rawWire()".to_owned(),
            ),
        };
        self.runtime_line(&format!("  private static {native} read{ty}(necoherence.semantic.Checked checked,WireValue value) throws ValueRejection {{ return {read}; }}"));
        self.runtime_line(&format!("  private static WireValue write{ty}({native} value) throws ValueRejection {{ nonNull(value,{type_ref},List.of()); return {write}; }}"));
        Ok(())
    }

    fn integer_wire(&self, ty: usize, value: &str) -> Result<String> {
        let spec = self.payload(self.shape(ty)?)?;
        let profile = &self.integer_profile;
        let name = match spec.get("domain").and_then(Value::as_str) {
            Some(domain) => domain.to_owned(),
            None => text(profile, "default_integer_domain")?.to_owned(),
        };
        let binding = list(profile, "integer_domains")?
            .iter()
            .find(|candidate| candidate.get("name").and_then(Value::as_str) == Some(name.as_str()))
            .ok_or_else(|| emission("integer domain unresolved"))?;
        let forms: Vec<&str> = list(binding, "forms")?
            .iter()
            .filter_map(|form| form.get("tag").and_then(Value::as_str))
            .collect();
        if forms.contains(&"Number") {
            return Ok(format!("new IntegerValue({value})"));
        }
        if forms.contains(&"IntegralDecimal") {
            return Ok(format!(
                "new DecimalValue(String.valueOf({value}) + \".0\")"
            ));
        }
        if forms.contains(&"DecimalString") {
            return Ok(format!("new StringValue(String.valueOf({value}))"));
        }
        Err(emission("integer domain has no encoding form"))
    }

    fn primitive_read(&self, ty: usize, value: &str) -> Result<String> {
        let rt = &self.runtime_name;
        let type_ref = self.type_ref(ty);
        let shape = self.shape(ty)?;
        Ok(match tag(shape)? {
            "Boolean" => format!("((BooleanValue){value}).value()"),
            "Integer" => format!("{rt}.CONTEXT.integerValue({type_ref},{value})"),
            "Decimal" => format!("((DecimalValue){value}).text()"),
            "String" => format!("{rt}.CONTEXT.decodeText({type_ref},{value})"),
            "Bytes" => format!("{rt}.CONTEXT.bytes(checked,{value})"),
            "RawBody" => format!(
                "new RawBody({},{rt}.CONTEXT.bytes(checked,{value}))",
                quote(text(self.payload(shape)?, "encoding")?)
            ),
            "Unit" => "Unit.VALUE".to_owned(),
            _ => value.to_owned(),
        })
    }

    fn primitive_write(&self, ty: usize, value: &str) -> Result<String> {
        let rt = &self.runtime_name;
        let type_ref = self.type_ref(ty);
        Ok(match tag(self.shape(ty)?)? {
            "Boolean" => format!("new BooleanValue({value})"),
            "Integer" => self.integer_wire(ty, value)?,
            "Decimal" => format!("new DecimalValue({value})"),
            "String" => format!("{rt}.CONTEXT.encodeText({type_ref},{value})"),
            "Bytes" => format!("{rt}.bytesWire({value})"),
            "RawBody" => format!("{rt}.write{ty}({value})"),
            "Unit" => "new NullValue()".to_owned(),
            _ => value.to_owned(),
        })
    }

    fn scalar_type(&mut self, ty: usize) -> Result<()> {
        let name = self.name(ty)?;
        let kind = tag(self.shape(ty)?)?.to_owned();
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        let target = if kind == "Alias" {
            let target_name = text(
                field(self.payload(self.shape(ty)?)?, "target")?,
                "definition_name",
            )?;
            self.index_of(target_name)?
        } else {
            ty
        };
        let stored = self.storage(target)?;
        line(
            &mut self.out,
            &format!("  public static final class {name} {{"),
        );
        line(&mut self.out, &format!("    private final {stored} value;"));
        line(&mut self.out, &format!("    private {name}({stored} value) throws ValueRejection {{ this.value={rt}.nonNull(value,{type_ref},List.of()); }}"));
        line(&mut self.out, &format!("    public static {name} of({stored} value) throws ValueRejection {{ {name} result=new {name}(value); {rt}.CONTEXT.validate({type_ref},result.rawWire()); return result; }}"));
        let decode = if kind == "Alias" {
            format!("{rt}.read{target}(checked,value)")
        } else {
            self.primitive_read(ty, "value")?
        };
        line(&mut self.out, &format!("    private static {name} decoded(necoherence.semantic.Checked checked,WireValue value) throws ValueRejection {{ return new {name}({decode}); }}"));
        line(&mut self.out, &format!("    public static {name} fromWire(WireValue value) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.check({type_ref},value); return decoded(checked,value); }}"));
        line(&mut self.out, &format!("    public static {name} decode(String text) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.decodeChecked({type_ref},text); return decoded(checked,checked.value()); }}"));
        line(&mut self.out, &format!("    public static {name} decodeWithDefaults(String text) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.decodeCheckedWithDefaults({type_ref},text); return decoded(checked,checked.value()); }}"));
        line(
            &mut self.out,
            &format!("    public {stored} value() {{ return value; }}"),
        );
        let raw = if kind == "Alias" {
            format!("{rt}.write{target}(value)")
        } else {
            self.primitive_write(ty, "value")?
        };
        line(
            &mut self.out,
            &format!("    private WireValue rawWire() throws ValueRejection {{ return {raw}; }}"),
        );
        line(&mut self.out, &format!("    public WireValue wire() throws ValueRejection {{ WireValue value=rawWire(); {rt}.CONTEXT.validate({type_ref},value); return value; }}"));
        line(&mut self.out, "    public String encode() throws ValueRejection { return SemanticValues.encodeWire(wire()); }");
        line(&mut self.out, "  }");
        Ok(())
    }

    fn fields_of(&self, specs: &[Value]) -> Result<Vec<Field>> {
        let rt = &self.runtime_name;
        let mut fields = Vec::new();
        for spec in specs {
            let wire = text(spec, "wire_name")?.to_owned();
            let java = field_identifier(&wire);
            let slot = field(spec, "slot")?;
            let contract = self.graph_contract(slot)?;
            let port = self.port_index(&contract)?;
            fields.push(Field {
                java_type: self.native_port(&contract)?,
                read: format!(
                    "{rt}.readPort{port}({rt}.field(object.get({})))",
                    quote(&wire)
                ),
                write: format!("{rt}.wirePort{port}({java})"),
                reference: self.reference_of(contract.ty)?,
                wire,
                name: java,
            });
        }
        Ok(fields)
    }

    pub(super) fn port_index(&self, contract: &Contract) -> Result<usize> {
        self.contracts
            .iter()
            .position(|known| known == contract)
            .ok_or_else(|| emission("unregistered contract"))
    }

    fn product(&mut self, ty: usize) -> Result<()> {
        let name = self.name(ty)?;
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        let specs = list(self.payload(self.shape(ty)?)?, "fields")?.to_vec();
        let mut seen = HashSet::new();
        for spec in &specs {
            let java = field_identifier(text(spec, "wire_name")?);
            if !seen.insert(java.clone()) || java == "extra" {
                return Err(emission(format!("Java field collision: {name}.{java}")));
            }
        }
        let mut fields = self.fields_of(&specs)?;
        fields.push(Field {
            wire: String::new(),
            name: "extra".to_owned(),
            java_type: "Map<String,WireValue>".to_owned(),
            read: format!("{rt}.extras(object,KNOWN)"),
            write: String::new(),
            reference: self.reference_of(ty)?,
        });
        let known_names: Vec<String> = specs
            .iter()
            .map(|spec| text(spec, "wire_name").map(quote))
            .collect::<Result<_>>()?;
        line(
            &mut self.out,
            &format!("  public static final class {name} {{"),
        );
        line(
            &mut self.out,
            &format!(
                "    private static final Set<String> KNOWN=Set.of({});",
                known_names.join(",")
            ),
        );
        self.data_class(
            &name,
            &fields,
            "      this.extra=Collections.unmodifiableMap(new LinkedHashMap<>(extra));",
            false,
            true,
        )?;
        line(&mut self.out, &format!("    public static {name} of({}) throws ValueRejection {{ extra={rt}.copyExtra(extra,KNOWN,{type_ref}); {name} result=new {name}({}); {rt}.CONTEXT.validate({type_ref},result.rawWire()); return result; }}", parameters(&fields), arguments(&fields)));
        let (_, known) = fields
            .split_last()
            .ok_or_else(|| emission("product fields"))?;
        let comma = if known.is_empty() { "" } else { "," };
        line(&mut self.out, &format!("    public static {name} of({}) throws ValueRejection {{ return of({}{comma}Map.of()); }}", parameters(known), arguments(known)));
        let reads: Vec<String> = fields.iter().map(|field| field.read.clone()).collect();
        line(&mut self.out, &format!("    private static {name} decoded(necoherence.semantic.Checked checked,WireValue value) throws ValueRejection {{ ObjectValue object=(ObjectValue)value; return new {name}({},object.members().stream().map(Member::key).toList()); }}", reads.join(",")));
        self.common_decode(&name, ty)?;
        line(&mut self.out, "    private WireValue rawWire() throws ValueRejection { List<Member> fields=new ArrayList<>();");
        for field in known {
            line(
                &mut self.out,
                &format!(
                    "      {rt}.put(fields,{},{});",
                    quote(&field.wire),
                    field.write
                ),
            );
        }
        line(&mut self.out, "      for(var entry:extra.entrySet()) fields.add(new Member(entry.getKey(),entry.getValue())); return SemanticValues.orderedObject(fields,_memberOrder); }");
        self.common_encode(ty)?;
        line(&mut self.out, "  }");
        Ok(())
    }

    pub(super) fn data_class(
        &mut self,
        name: &str,
        fields: &[Field],
        special: &str,
        validate_ports: bool,
        ordered: bool,
    ) -> Result<()> {
        let rt = self.runtime_name.clone();
        for field in fields {
            line(
                &mut self.out,
                &format!("    private final {} {};", field.java_type, field.name),
            );
        }
        if ordered {
            line(
                &mut self.out,
                "    private final List<String> _memberOrder;",
            );
            line(
                &mut self.out,
                &format!(
                    "    private {name}({}) throws ValueRejection {{ this({},List.of()); }}",
                    parameters(fields),
                    arguments(fields)
                ),
            );
        }
        let order = if ordered {
            ",List<String> _memberOrder"
        } else {
            ""
        };
        line(
            &mut self.out,
            &format!(
                "    private {name}({}{order}) throws ValueRejection {{",
                parameters(fields)
            ),
        );
        for field in fields {
            if field.name != "extra" || special.is_empty() {
                line(&mut self.out, &format!(
                    "      this.{n}={rt}.nonNull({n},TypeSignatures.parseWire({}),List.of(SemanticValues.variant(\"Field\",new StringValue({}))));",
                    quote(&wire_text(&field.reference)),
                    quote(&field.wire),
                    n = field.name
                ));
            }
        }
        if !special.is_empty() {
            line(&mut self.out, special);
        }
        if ordered {
            line(
                &mut self.out,
                "      this._memberOrder=List.copyOf(_memberOrder);",
            );
        }
        line(&mut self.out, "    }");
        for field in fields {
            line(
                &mut self.out,
                &format!(
                    "    public {} {}() {{ return {}; }}",
                    field.java_type, field.name, field.name
                ),
            );
        }
        if validate_ports {
            line(
                &mut self.out,
                "    public void validate() throws ValueRejection {",
            );
            for field in fields {
                line(&mut self.out, &format!("      {};", field.write));
            }
            line(&mut self.out, "    }");
        }
        Ok(())
    }

    fn common_decode(&mut self, name: &str, ty: usize) -> Result<()> {
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        line(&mut self.out, &format!("    public static {name} fromWire(WireValue value) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.check({type_ref},value); return decoded(checked,value); }}"));
        line(&mut self.out, &format!("    public static {name} decode(String text) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.decodeChecked({type_ref},text); return decoded(checked,checked.value()); }}"));
        line(&mut self.out, &format!("    public static {name} decodeWithDefaults(String text) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.decodeCheckedWithDefaults({type_ref},text); return decoded(checked,checked.value()); }}"));
        Ok(())
    }

    fn common_encode(&mut self, ty: usize) -> Result<()> {
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        line(&mut self.out, &format!("    public WireValue wire() throws ValueRejection {{ WireValue value=rawWire(); {rt}.CONTEXT.validate({type_ref},value); return value; }}"));
        line(&mut self.out, "    public String encode() throws ValueRejection { return SemanticValues.encodeWire(wire()); }");
        Ok(())
    }

    fn opaque_carrier(&mut self, ty: usize) -> Result<()> {
        let name = self.name(ty)?;
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        line(&mut self.out, &format!("  public static final class {name} {{ private final WireValue value; private {name}(WireValue value){{this.value=value;}} public static {name} fromWire(WireValue value) throws ValueRejection {{ {rt}.CONTEXT.validate({type_ref},value); return new {name}(value); }} private static {name} decoded(necoherence.semantic.Checked checked,WireValue value){{return new {name}(value);}} public WireValue value(){{return value;}} private WireValue rawWire(){{return value;}} public String encode() throws ValueRejection {{ {rt}.CONTEXT.validate({type_ref},value); return SemanticValues.encodeWire(value); }} }}"));
        Ok(())
    }

    fn never(&mut self, ty: usize) -> Result<()> {
        let name = self.name(ty)?;
        line(&mut self.out, &format!("  public enum {name} {{}}"));
        Ok(())
    }

    fn array(&mut self, ty: usize) -> Result<()> {
        let name = self.name(ty)?;
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        let item_contract = field(self.payload(self.shape(ty)?)?, "item")?;
        let item = self.index_of(text(field(item_contract, "type_ref")?, "definition_name")?)?;
        let item_type = self.storage(item)?;
        line(
            &mut self.out,
            &format!("  public static final class {name} {{"),
        );
        line(
            &mut self.out,
            &format!("    private final List<{item_type}> items;"),
        );
        line(&mut self.out, &format!("    private {name}(List<{item_type}> items) throws ValueRejection {{ {rt}.nonNull(items,{type_ref},List.of()); for(int i=0;i<items.size();i++) {rt}.nonNull(items.get(i),{type_ref},List.of(SemanticValues.variant(\"Index\",new StringValue(Integer.toString(i))))); this.items=List.copyOf(items); }}"));
        line(&mut self.out, &format!("    public static {name} of(List<{item_type}> items) throws ValueRejection {{ {name} result=new {name}(items); {rt}.CONTEXT.validate({type_ref},result.rawWire()); return result; }}"));
        line(&mut self.out, &format!("    private static {name} decoded(necoherence.semantic.Checked checked,WireValue value) throws ValueRejection {{ List<{item_type}> items=new ArrayList<>(); for(WireValue item:((ArrayValue)value).items()) items.add({rt}.read{item}(checked,item)); return new {name}(items); }}"));
        self.common_decode(&name, ty)?;
        line(
            &mut self.out,
            &format!("    public List<{item_type}> items() {{ return items; }}"),
        );
        line(&mut self.out, &format!("    private WireValue rawWire() throws ValueRejection {{ List<WireValue> values=new ArrayList<>(); for({item_type} item:items) values.add({rt}.write{item}(item)); return new ArrayValue(values); }}"));
        self.common_encode(ty)?;
        line(&mut self.out, "  }");
        Ok(())
    }

    fn union(&mut self, ty: usize) -> Result<()> {
        let name = self.name(ty)?;
        let rt = self.runtime_name.clone();
        let type_ref = self.type_ref(ty);
        let branches = list(self.payload(self.shape(ty)?)?, "branches")?.to_vec();
        let mut variants = Vec::new();
        for index in 0..branches.len() {
            let variant = format!("{name}Branch{index}");
            self.reserve(&variant)?;
            variants.push(variant);
        }
        line(
            &mut self.out,
            &format!(
                "  public static abstract sealed class {name} permits {} {{",
                variants.join(",")
            ),
        );
        line(&mut self.out, &format!("    private {name}() {{}}"));
        line(
            &mut self.out,
            "    abstract WireValue rawWire() throws ValueRejection;",
        );
        line(&mut self.out, &format!("    private static {name} decoded(necoherence.semantic.Checked checked,WireValue value) throws ValueRejection {{ switch({rt}.CONTEXT.selectBranch({type_ref},value)) {{"));
        for (index, branch) in branches.iter().enumerate() {
            let target = self.index_of(text(field(branch, "target")?, "definition_name")?)?;
            line(
                &mut self.out,
                &format!(
                    "      case {index}: return new {name}Branch{index}({rt}.read{target}(checked,value));"
                ),
            );
        }
        line(&mut self.out, &format!("      default: throw new ValueRejection({type_ref},List.of(),SimpleValueCondition.NO_BRANCH_SELECTED,List.of(),new Present<>(necoherence.semantic.WireJson.fromWire(value))); }} }}"));
        self.common_decode(&name, ty)?;
        self.common_encode(ty)?;
        line(&mut self.out, "  }");
        for (index, branch) in branches.iter().enumerate() {
            let target = self.index_of(text(field(branch, "target")?, "definition_name")?)?;
            let variant = format!("{name}Branch{index}");
            let java_type = self.storage(target)?;
            let encoded = if tag(field(branch, "selector")?)? == "InternalTag" {
                format!(
                    "{rt}.tagged({type_ref},{rt}.write{target}(value),{})",
                    quote(text(branch, "wire_tag")?)
                )
            } else {
                format!("{rt}.write{target}(value)")
            };
            line(
                &mut self.out,
                &format!("  public static final class {variant} extends {name} {{"),
            );
            line(
                &mut self.out,
                &format!("    private final {java_type} value;"),
            );
            line(&mut self.out, &format!("    private {variant}({java_type} value) throws ValueRejection {{ this.value={rt}.nonNull(value,{type_ref},List.of()); }}"));
            line(&mut self.out, &format!("    public static {variant} of({java_type} value) throws ValueRejection {{ {variant} result=new {variant}(value); {rt}.CONTEXT.validate({type_ref},result.rawWire()); return result; }}"));
            line(
                &mut self.out,
                &format!("    public {java_type} value() {{ return value; }}"),
            );
            line(
                &mut self.out,
                &format!("    WireValue rawWire() throws ValueRejection {{ return {encoded}; }}"),
            );
            line(&mut self.out, "  }");
        }
        Ok(())
    }

    pub(super) fn port_codec(&mut self, contract: &Contract, id: usize) -> Result<()> {
        let rt = self.runtime_name.clone();
        let ty = contract.ty;
        let type_ref = self.type_ref(ty);
        let storage = self.storage(ty)?;
        let native = self.native_port(contract)?;
        let (required, nullable) = (contract.required, contract.nullable);
        self.runtime_line(&format!("  private static {native} readPort{id}(Slot<WireValue> value) throws ValueRejection {{ necoherence.semantic.Checked checked={rt}.CONTEXT.checkSlot({type_ref},{required},{nullable},value);"));
        if required && !nullable {
            self.runtime_line(&format!("    return read{ty}(checked,scalar(value));"));
        } else if required {
            self.runtime_line(&format!("    return value instanceof NullSlot<WireValue> ? new Null<>() : new NonNull<>(read{ty}(checked,scalar(value)));"));
        } else if !nullable {
            self.runtime_line(&format!("    return value instanceof Absent<WireValue> ? Optional.empty() : Optional.of(read{ty}(checked,scalar(value)));"));
        } else {
            self.runtime_line(&format!("    if(value instanceof Absent<WireValue>) return new Absent<>(); if(value instanceof NullSlot<WireValue>) return new NullSlot<>(); return new Present<>(read{ty}(checked,scalar(value)));"));
        }
        self.runtime_line("  }");
        self.runtime_line(&format!("  private static Slot<WireValue> wirePort{id}({native} value) throws ValueRejection {{ nonNull(value,{type_ref},List.of()); Slot<WireValue> result;"));
        if required && !nullable {
            self.runtime_line(&format!("    result=new Present<>(write{ty}(value));"));
        } else if required {
            self.runtime_line(&format!("    result=value instanceof Null<{storage}> ? new NullSlot<>() : new Present<>(write{ty}((({}<{storage}>)value).value()));", "NonNull"));
        } else if !nullable {
            self.runtime_line(&format!("    result=value.isEmpty() ? new Absent<>() : new Present<>(write{ty}(value.get()));"));
        } else {
            self.runtime_line(&format!("    result=wireSlot(value,{rt}::write{ty});"));
        }
        self.runtime_line(&format!("    {rt}.CONTEXT.validateSlot({type_ref},{required},{nullable},result); return result; }}"));
        self.runtime_line(&format!(
            "  private static Slot<{storage}> liftPort{id}({native} value) {{"
        ));
        if required && !nullable {
            self.runtime_line("    return new Present<>(value);");
        } else if required {
            self.runtime_line(&format!("    return value instanceof Null<{storage}> ? new NullSlot<>() : new Present<>((({}<{storage}>)value).value());", "NonNull"));
        } else if !nullable {
            self.runtime_line(
                "    return value.isEmpty() ? new Absent<>() : new Present<>(value.get());",
            );
        } else {
            self.runtime_line("    return value;");
        }
        self.runtime_line("  }");
        Ok(())
    }

    pub(super) fn port_class(
        &mut self,
        name: &str,
        ports: &[Port],
        extension: &str,
        extra_methods: &str,
    ) -> Result<()> {
        let mut fields = Vec::new();
        let mut names = HashSet::new();
        let rt = self.runtime_name.clone();
        for port in ports {
            let java = field_identifier(&port.id);
            if !names.insert(java.clone()) {
                return Err(emission(format!("Java port identifier collision: {java}")));
            }
            let index = self.port(port.contract.clone());
            fields.push(Field {
                wire: port.id.clone(),
                name: java.clone(),
                java_type: self.native_port(&port.contract)?,
                read: String::new(),
                write: format!("{rt}.wirePort{index}({java})"),
                reference: self.reference_of(port.contract.ty)?,
            });
        }
        line(
            &mut self.out,
            &format!("  public static final class {name}{extension} {{"),
        );
        self.data_class(name, &fields, "", true, false)?;
        let mut local = "result".to_owned();
        while fields.iter().any(|field| field.name == local) {
            local.push('_');
        }
        line(&mut self.out, &format!("    public static {name} of({}) throws ValueRejection {{ {name} {local}=new {name}({}); {local}.validate(); return {local}; }}", parameters(&fields), arguments(&fields)));
        if !extra_methods.is_empty() {
            line(&mut self.out, extra_methods);
        }
        line(&mut self.out, "  }");
        Ok(())
    }
}

pub(super) fn parameters(fields: &[Field]) -> String {
    fields
        .iter()
        .map(|field| format!("{} {}", field.java_type, field.name))
        .collect::<Vec<_>>()
        .join(",")
}

pub(super) fn arguments(fields: &[Field]) -> String {
    fields
        .iter()
        .map(|field| field.name.clone())
        .collect::<Vec<_>>()
        .join(",")
}
