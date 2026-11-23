// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

mod composition;
mod syntax;

use super::{check_meaning, RenderFailure};
use necoherence::semantic_exchange::{encode_type_signatures, Wire};
use necoherence::signature_admission::CheckedSignatureGeneration;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use syntax::{
    dict_literal, digest, identifier, json_literal, json_tuple_literal, optional_text_literal,
    qualified, text_literal, title, tuple_literal,
};

type Result<T> = std::result::Result<T, RenderFailure>;

static NULL: Value = Value::Null;

const HEADER: &[&str] = &[
    "import base64",
    "import json",
    "from collections.abc import Callable",
    "from dataclasses import dataclass, field as _dataclass_field",
    "from decimal import Decimal",
    "from typing import TypeAlias",
    "import necoherence.network_effect as _network",
    "import necoherence.semantic_composition as _composition",
    "import necoherence.semantic_execution as _execution",
    "import necoherence.signature_composition_wire as _wire",
    "import necoherence.type_signatures as _admission",
    "import necoherence.signature_values as _values",
    "import necoherence.typed_mapping as _typed_mapping",
    "from necoherence.signature_values import ABSENT, ABSENT_VALUE, MISSING_REQUIRED, Absent, DecimalLiteral, Uninhabited, ValueContext, ValueFailure as _ValueFailure, NO_BRANCH_SELECTED, PresentValue, select_union_branch, withMember, wrapDecode, wrapEncode",
    "",
];

fn invalid(message: &str) -> RenderFailure {
    RenderFailure::InvalidCheckedPlan(message.into())
}

fn parse(text: &str) -> Result<Value> {
    serde_json::from_str(text).map_err(|_| invalid("generated JSON"))
}

fn to_value<T: Serialize>(value: T) -> Result<Value> {
    serde_json::to_value(value).map_err(|_| invalid("generated wire value"))
}

fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value> {
    value
        .get(key)
        .ok_or_else(|| invalid(&format!("generated field {key}")))
}

fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    field(value, key)?
        .as_str()
        .ok_or_else(|| invalid("generated text"))
}

fn list<'a>(value: &'a Value, key: &str) -> Result<&'a [Value]> {
    field(value, key)?
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| invalid("generated list"))
}

fn flag(value: &Value, key: &str) -> Result<bool> {
    field(value, key)?
        .as_bool()
        .ok_or_else(|| invalid("generated flag"))
}

fn tag(value: &Value) -> Result<&str> {
    text(value, "tag")
}

fn payload(value: &Value) -> &Value {
    value
        .get("value")
        .or_else(|| value.get("fields"))
        .unwrap_or(&NULL)
}

fn required(contract: &Value) -> Result<bool> {
    flag(contract, "required")
}

fn nullable(contract: &Value) -> Result<bool> {
    flag(contract, "nullable")
}

fn type_id(contract: &Value) -> Result<&str> {
    text(contract, "type_id")
}

fn lookup<'v, T>(entries: &'v [(String, T)], key: &str) -> Result<&'v T> {
    entries
        .iter()
        .find(|(entry, _)| entry == key)
        .map(|(_, value)| value)
        .ok_or_else(|| invalid("generated identity"))
}

fn set_entry<T>(entries: &mut Vec<(String, T)>, key: String, value: T) {
    if let Some(position) = entries.iter().position(|(entry, _)| *entry == key) {
        if let Some(slot) = entries.get_mut(position) {
            slot.1 = value;
        }
    } else {
        entries.push((key, value));
    }
}

#[derive(Clone)]
struct Member {
    wire: String,
    attribute: String,
    contract: Value,
}

fn members(spec: &Value) -> Result<Vec<Member>> {
    list(spec, "fields")?
        .iter()
        .map(|member| {
            let wire = text(member, "wire_name")?;
            Ok(Member {
                wire: wire.to_owned(),
                attribute: identifier(wire),
                contract: field(member, "slot")?.clone(),
            })
        })
        .collect()
}

fn render_generation_failure(
    failure: necoherence::semantic_exchange::GenerationFailure,
) -> RenderFailure {
    RenderFailure::Generation(Box::new(failure))
}

fn attach_identities(graph: &mut Value) -> Result<()> {
    let nodes = graph
        .get_mut("nodes")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| invalid("generated graph nodes"))?;
    for node in nodes {
        let identity = node
            .get("reference")
            .and_then(|reference| reference.get("definition_name"))
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("generated graph identity"))?
            .to_owned();
        let object = node
            .as_object_mut()
            .ok_or_else(|| invalid("generated graph node"))?;
        object.insert("id".to_owned(), Value::String(identity));
    }
    Ok(())
}

pub(super) fn render_generation(
    checked: &CheckedSignatureGeneration,
    expected: &necoherence::type_signatures::ExpectedSignatureBasis,
    exchange_text: &str,
) -> Result<String> {
    let input = checked.input();
    if checked.composition().is_none() {
        check_meaning(checked.graph())?;
    }
    let library =
        parse(&encode_type_signatures(&input.signatures).map_err(render_generation_failure)?)?;
    let basis = parse(
        &necoherence::semantic_exchange::encode_expected_signature_basis(expected)
            .map_err(render_generation_failure)?,
    )?;
    for node in list(&library, "nodes")? {
        if tag(field(node, "shape")?)? == "Opaque" {
            return Err(RenderFailure::UndefinedType(text(node, "id")?.to_owned()));
        }
    }
    let mut graph = to_value(Wire(checked.graph()))?;
    attach_identities(&mut graph)?;
    let exchange = parse(exchange_text)?;
    let composition = exchange.get("composition").filter(|value| !value.is_null());
    let mut emitter = Emitter::new(
        &library,
        &basis,
        graph,
        &exchange,
        exchange_text,
        composition,
    )?;
    emitter.header();
    emitter.types()?;
    emitter.definitions()?;
    emitter.composition()?;
    emitter.finish()?;
    Ok(emitter.lines.join("\n"))
}

struct Emitter<'a> {
    library: &'a Value,
    basis: &'a Value,
    profile: &'a Value,
    graph: Value,
    entrypoints: &'a [Value],
    exchange_text: &'a str,
    composition: Option<&'a Value>,
    names: Vec<(String, String)>,
    shapes: HashMap<String, &'a Value>,
    sealed: HashMap<String, (String, String, Vec<Member>)>,
    unions: HashMap<String, Vec<String>>,
    entry_values: Vec<(String, String)>,
    entry_shapes: Vec<(String, (String, String))>,
    lines: Vec<String>,
}

impl<'a> Emitter<'a> {
    fn new(
        library: &'a Value,
        basis: &'a Value,
        graph: Value,
        exchange: &'a Value,
        exchange_text: &'a str,
        composition: Option<&'a Value>,
    ) -> Result<Self> {
        let mut names = Vec::new();
        let mut shapes = HashMap::new();
        for node in list(library, "nodes")? {
            let identity = text(node, "id")?;
            set_entry(&mut names, identity.to_owned(), qualified(identity));
            shapes.insert(identity.to_owned(), field(node, "shape")?);
        }
        Ok(Self {
            library,
            basis,
            profile: field(library, "profile")?,
            graph,
            entrypoints: list(exchange, "entrypoints")?,
            exchange_text,
            composition,
            names,
            shapes,
            sealed: HashMap::new(),
            unions: HashMap::new(),
            entry_values: Vec::new(),
            entry_shapes: Vec::new(),
            lines: Vec::new(),
        })
    }

    fn push(&mut self, line: impl Into<String>) {
        self.lines.push(line.into());
    }

    fn name(&self, identity: &str) -> Result<&str> {
        lookup(&self.names, identity).map(String::as_str)
    }

    fn child_function(&self, identity: &str, prefix: &str) -> Result<String> {
        Ok(format!("{prefix}{}", self.name(identity)?))
    }

    fn sealed_entry(&self, identity: &str) -> Result<(String, String, Vec<Member>)> {
        self.sealed
            .get(identity)
            .cloned()
            .ok_or_else(|| invalid("generated sealed form"))
    }

    fn union_variants(&self, identity: &str) -> Result<Vec<String>> {
        self.unions
            .get(identity)
            .cloned()
            .ok_or_else(|| invalid("generated union"))
    }

    fn header(&mut self) {
        for line in super::generated_header_lines("#") {
            self.push(line);
        }
        for line in HEADER {
            self.push(*line);
        }
        let graph = json_literal(&self.graph);
        self.push(format!("_ctx = ValueContext({graph})"));
        self.push("");
    }

    fn integer_binding(&self, domain: Option<&str>) -> Option<&'a Value> {
        let profile: &'a Value = self.profile;
        let name = match domain {
            Some(name) => name,
            None => profile.get("default_integer_domain")?.as_str()?,
        };
        profile
            .get("integer_domains")?
            .as_array()?
            .iter()
            .find(|binding| binding.get("name").and_then(Value::as_str) == Some(name))
    }

    fn integer_encoding(&self, spec: &Value) -> Result<String> {
        let domain = spec.get("domain").and_then(Value::as_str);
        let forms: Vec<&str> = self
            .integer_binding(domain)
            .and_then(|binding| binding.get("forms"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|form| form.get("tag").and_then(Value::as_str))
            .collect();
        if forms.contains(&"Number") {
            return Ok("value".to_owned());
        }
        if forms.contains(&"IntegralDecimal") {
            return Ok("_values.DecimalLiteral(_values.integer_digits(value) + '.0')".to_owned());
        }
        if forms.contains(&"DecimalString") {
            return Ok("_values.integer_digits(value)".to_owned());
        }
        Err(RenderFailure::IntegerEncodingFailure(
            domain.unwrap_or_default().to_owned(),
        ))
    }

    fn integer_bearing(&self, identity: &str, seen: &[String]) -> Result<bool> {
        if seen.iter().any(|entry| entry == identity) {
            return Ok(false);
        }
        let shape = self
            .shapes
            .get(identity)
            .copied()
            .ok_or_else(|| invalid("generated shape"))?;
        let spec = payload(shape);
        let mut seen = seen.to_vec();
        seen.push(identity.to_owned());
        match tag(shape)? {
            "Integer" => Ok(true),
            "Product" => {
                for member in members(spec)? {
                    if self.integer_bearing(type_id(&member.contract)?, &seen)? {
                        return Ok(true);
                    }
                }
                Ok(false)
            }
            "Array" => self.integer_bearing(text(field(spec, "item")?, "type_id")?, &seen),
            "Alias" => self.integer_bearing(text(spec, "target")?, &seen),
            "TaggedUnion" => {
                for branch in list(spec, "branches")? {
                    if self.integer_bearing(text(branch, "target")?, &seen)? {
                        return Ok(true);
                    }
                }
                Ok(false)
            }
            _ => Ok(false),
        }
    }

    fn field_read(&self, wire: &str, contract: &Value) -> Result<String> {
        let read = format!("value.get({})", text_literal(wire));
        let identity = type_id(contract)?;
        if !self.integer_bearing(identity, &[])? {
            return Ok(read);
        }
        Ok(format!(
            "_values.decode_optional({}, {read})",
            self.child_function(identity, "_build_")?
        ))
    }

    fn field_write(&self, attribute: &str, contract: &Value) -> Result<String> {
        let write = format!("value.{attribute}");
        let identity = type_id(contract)?;
        if !self.integer_bearing(identity, &[])? {
            return Ok(write);
        }
        Ok(format!(
            "_values.encode_optional({}, {write})",
            self.child_function(identity, "encode_")?
        ))
    }

    fn branch_function(&self, branch: &Value, prefix: &str) -> Result<String> {
        let target = text(branch, "target")?;
        if !self.integer_bearing(target, &[])? {
            return Ok("lambda value: value".to_owned());
        }
        Ok(format!(
            "lambda value: {}(value)",
            self.child_function(target, prefix)?
        ))
    }

    fn validate_and_return(&mut self, identity_literal: &str) {
        self.push(format!("    _ctx.validate({identity_literal}, result)"));
        self.push("    return result");
    }

    fn types(&mut self) -> Result<()> {
        for node in list(self.library, "nodes")? {
            let identity = text(node, "id")?.to_owned();
            let shape = field(node, "shape")?;
            let name = self.name(&identity)?.to_owned();
            let spec = payload(shape);
            match tag(shape)? {
                "Never" => {
                    self.push(format!("class {name}(Uninhabited):"));
                    self.push("    pass");
                    self.push("");
                }
                "Product" => {
                    self.push("@dataclass(frozen=True, slots=True, kw_only=True)");
                    self.push(format!("class {name}:"));
                    for member in members(spec)? {
                        let default = if !required(&member.contract)? || nullable(&member.contract)?
                        {
                            " = None"
                        } else {
                            ""
                        };
                        self.push(format!("    {}: object{default}", member.attribute));
                    }
                    if tag(field(spec, "extras")?)? == "Allow" {
                        self.push("    extras: tuple[tuple[str, object], ...] = ()");
                    }
                    self.push("    _present_members: tuple[str, ...] = _dataclass_field(default=(), init=False, repr=False, compare=False)");
                    self.push("");
                }
                "Sealed" => {
                    let model = field(self.profile, "tag")?;
                    let form_tag = text(spec, "tag")?;
                    let form = list(model, "sealed")?
                        .iter()
                        .find(|form| form.get("tag").and_then(Value::as_str) == Some(form_tag))
                        .ok_or_else(|| invalid("generated sealed form"))?;
                    let fields = list(form, "fields")?
                        .iter()
                        .map(|item| {
                            let key = text(item, "key")?;
                            Ok(Member {
                                wire: key.to_owned(),
                                attribute: identifier(key),
                                contract: json!({
                                    "required": flag(item, "required")?,
                                    "nullable": false,
                                }),
                            })
                        })
                        .collect::<Result<Vec<Member>>>()?;
                    self.push("@dataclass(frozen=True, slots=True, kw_only=True)");
                    self.push(format!("class {name}:"));
                    for member in &fields {
                        let default = if required(&member.contract)? {
                            ""
                        } else {
                            " = None"
                        };
                        self.push(format!("    {}: object{default}", member.attribute));
                    }
                    if fields.is_empty() {
                        self.push("    pass");
                    }
                    self.push("");
                    let key = text(model, "key")?.to_owned();
                    self.sealed
                        .insert(identity.clone(), (key, form_tag.to_owned(), fields));
                }
                "TaggedUnion" => {
                    let mut variants = Vec::new();
                    for branch in list(spec, "branches")? {
                        let variant =
                            format!("{name}_{}", title(&identifier(text(branch, "wire_tag")?)));
                        self.push("@dataclass(frozen=True, slots=True)");
                        self.push(format!("class {variant}:"));
                        self.push("    value: object");
                        self.push("");
                        variants.push(variant);
                    }
                    self.push(format!("{name} = {}", variants.join(" | ")));
                    self.push("");
                    self.unions.insert(identity.clone(), variants);
                }
                kind => {
                    let alias = match kind {
                        "Decimal" => "DecimalLiteral",
                        "Bytes" | "RawBody" => "bytes",
                        "Boolean" => "bool",
                        "Integer" => "int",
                        "String" => "str",
                        "Array" => "list",
                        "Unit" => "type(None)",
                        _ => "object",
                    };
                    self.push(format!("{name} = {alias}"));
                    self.push("");
                }
            }
            self.codec(&identity, shape)?;
        }
        Ok(())
    }

    fn codec(&mut self, identity: &str, shape: &Value) -> Result<()> {
        let name = self.name(identity)?.to_owned();
        let kind = tag(shape)?.to_owned();
        let spec = payload(shape);
        let integer_bearing = self.integer_bearing(identity, &[])?;
        let identity_literal = text_literal(identity);
        let wrapper = spec
            .get("wrapper")
            .and_then(Value::as_str)
            .map(text_literal);
        let bytes_wrapper = self
            .profile
            .get("bytes_policy")
            .and_then(|policy| policy.get("wrapper"))
            .and_then(Value::as_str)
            .map(text_literal);
        if kind == "TaggedUnion" {
            self.push(format!(
                "_BRANCHES_{name} = {}",
                json_literal(field(spec, "branches")?)
            ));
            self.push("");
        }
        self.push(format!("def decode_with_defaults_{name}(text):"));
        self.push(format!(
            "    defaulted = _ctx.decode_with_defaults({identity_literal}, text)"
        ));
        self.push(format!("    return _build_{name}(defaulted.value)"));
        self.push("");
        self.push(format!("def decode_{name}(value):"));
        self.push(format!(
            "    return _decode_{name}(_values.exact_from_json(value))"
        ));
        self.push("");
        self.push(format!("def _decode_{name}(value):"));
        self.push(format!("    _ctx.validate({identity_literal}, value)"));
        self.push(format!("    return _build_{name}(value)"));
        self.push("");
        self.push(format!("def _build_{name}(value):"));
        match kind.as_str() {
            "Product" => {
                let fields = members(spec)?;
                let mut arguments = Vec::new();
                for member in &fields {
                    arguments.push(format!(
                        "{}={}",
                        member.attribute,
                        self.field_read(&member.wire, &member.contract)?
                    ));
                }
                let mut arguments = arguments.join(", ");
                if tag(field(spec, "extras")?)? == "Allow" {
                    let known: Vec<String> = fields
                        .iter()
                        .map(|member| text_literal(&member.wire))
                        .collect();
                    if !arguments.is_empty() {
                        arguments.push_str(", ");
                    }
                    arguments.push_str(&format!(
                        "extras=tuple((key, item) for key, item in value.items() if key not in {})",
                        tuple_literal(&known)
                    ));
                }
                self.push(format!("    result = {name}({arguments})"));
                self.push("    object.__setattr__(result, '_present_members', tuple(value))");
                self.push("    return result");
            }
            "Sealed" => {
                let (_, _, fields) = self.sealed_entry(identity)?;
                let arguments = fields
                    .iter()
                    .map(|member| {
                        format!(
                            "{}=value.get({})",
                            member.attribute,
                            text_literal(&member.wire)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                self.push(format!("    return {name}({arguments})"));
            }
            "TaggedUnion" => {
                let variants = self.union_variants(identity)?;
                let mut decoders = Vec::new();
                for branch in list(spec, "branches")? {
                    decoders.push(self.branch_function(branch, "_build_")?);
                }
                self.push(format!(
                    "    selected = select_union_branch(_ctx.profile, _BRANCHES_{name}, value)"
                ));
                self.push(format!(
                    "    if selected is None: raise _ValueFailure({identity_literal}, (), NO_BRANCH_SELECTED, PresentValue(value))"
                ));
                self.push(format!("    constructors = ({},)", variants.join(", ")));
                self.push(format!("    decoders = ({},)", decoders.join(", ")));
                self.push(format!("    index = _BRANCHES_{name}.index(selected)"));
                self.push("    return constructors[index](decoders[index](value))");
            }
            "Integer" => {
                let domain = optional_text_literal(spec.get("domain"));
                self.push(format!(
                    "    result = _values.integer_value_for_domain(_ctx.profile, {domain}, value)"
                ));
                self.push(format!(
                    "    if result is None: raise _ValueFailure({identity_literal}, (), _values.INTEGER_DOMAIN, PresentValue(value))"
                ));
                self.push("    return result");
            }
            "Array" if integer_bearing => {
                let item = text(field(spec, "item")?, "type_id")?;
                self.push(format!(
                    "    return [_values.decode_optional({}, item) for item in value]",
                    self.child_function(item, "_build_")?
                ));
            }
            "Alias" if integer_bearing => {
                let target = text(spec, "target")?;
                self.push(format!(
                    "    return {}(value)",
                    self.child_function(target, "_build_")?
                ));
            }
            "String" if wrapper.is_some() => {
                self.push(format!(
                    "    return wrapDecode(_ctx.profile, {}, value)",
                    wrapper.clone().unwrap_or_default()
                ));
            }
            "Bytes" | "RawBody" => {
                match &bytes_wrapper {
                    None => self.push("    text = value"),
                    Some(wrapper) => self.push(format!(
                        "    text = wrapDecode(_ctx.profile, {wrapper}, value)"
                    )),
                }
                self.push("    return base64.b64decode(text.replace('-', '+').replace('_', '/') + '=' * ((-len(text)) % 4))");
            }
            _ => self.push("    return value"),
        }
        self.push("");
        self.push(format!("def encode_{name}(value):"));
        match kind.as_str() {
            "Product" => {
                self.push("    result = {}");
                for member in members(spec)? {
                    let write = self.field_write(&member.attribute, &member.contract)?;
                    let wire = text_literal(&member.wire);
                    if required(&member.contract)? {
                        self.push(format!("    result[{wire}] = {write}"));
                    } else {
                        self.push(format!(
                            "    if value.{} is not None or {wire} in value._present_members: result[{wire}] = {write}",
                            member.attribute
                        ));
                    }
                }
                self.push("    if hasattr(value, 'extras'): result.update(value.extras)");
                self.push(format!("    _ctx.validate({identity_literal}, result)"));
                self.push("    return result");
            }
            "Sealed" => {
                let (key, tag_value, fields) = self.sealed_entry(identity)?;
                self.push("    result = {}");
                for member in &fields {
                    let wire = text_literal(&member.wire);
                    if required(&member.contract)? {
                        self.push(format!("    result[{wire}] = value.{}", member.attribute));
                    } else {
                        self.push(format!(
                            "    if value.{0} is not None: result[{wire}] = value.{0}",
                            member.attribute
                        ));
                    }
                }
                self.push(format!(
                    "    result = withMember({}, {}, result)",
                    text_literal(&key),
                    text_literal(&tag_value)
                ));
                self.push(format!("    _ctx.validate({identity_literal}, result)"));
                self.push("    return result");
            }
            "TaggedUnion" if integer_bearing => {
                let variants = self.union_variants(identity)?;
                let mut encoders = Vec::new();
                for branch in list(spec, "branches")? {
                    encoders.push(self.branch_function(branch, "encode_")?);
                }
                self.push(format!("    constructors = ({},)", variants.join(", ")));
                self.push(format!("    encoders = ({},)", encoders.join(", ")));
                self.push("    result = encoders[constructors.index(type(value))](value.value)");
                self.validate_and_return(&identity_literal);
            }
            "TaggedUnion" => {
                self.push("    result = value.value");
                self.validate_and_return(&identity_literal);
            }
            "Array" if integer_bearing => {
                let item = text(field(spec, "item")?, "type_id")?;
                self.push(format!(
                    "    result = [_values.encode_optional({}, item) for item in value]",
                    self.child_function(item, "encode_")?
                ));
                self.validate_and_return(&identity_literal);
            }
            "Alias" if integer_bearing => {
                let target = text(spec, "target")?;
                self.push(format!(
                    "    result = {}(value)",
                    self.child_function(target, "encode_")?
                ));
                self.validate_and_return(&identity_literal);
            }
            "String" if wrapper.is_some() => {
                self.push(format!(
                    "    result = wrapEncode(_ctx.profile, {}, value)",
                    wrapper.clone().unwrap_or_default()
                ));
                self.validate_and_return(&identity_literal);
            }
            "Bytes" | "RawBody" => {
                self.push("    text = base64.b64encode(value).decode('ascii')");
                match &bytes_wrapper {
                    None => self.push("    result = text"),
                    Some(wrapper) => self.push(format!(
                        "    result = wrapEncode(_ctx.profile, {wrapper}, text)"
                    )),
                }
                self.validate_and_return(&identity_literal);
            }
            "Integer" => {
                let encoding = self.integer_encoding(spec)?;
                self.push(format!("    result = {encoding}"));
                self.validate_and_return(&identity_literal);
            }
            _ => {
                self.push(format!("    _ctx.validate({identity_literal}, value)"));
                self.push("    return value");
            }
        }
        let examples = spec
            .get("examples")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[])
            .iter()
            .map(|example| {
                example
                    .as_str()
                    .map(text_literal)
                    .ok_or_else(|| invalid("generated example"))
            })
            .collect::<Result<Vec<String>>>()?;
        self.push("");
        self.push(format!("def examples_{name}():"));
        self.push(format!("    return {}", tuple_literal(&examples)));
        self.push("");
        Ok(())
    }

    fn port_class(&mut self, name: &str, ports: &[Value]) -> Result<()> {
        self.push("@dataclass(frozen=True, slots=True, kw_only=True)");
        self.push(format!("class {name}:"));
        for port in ports {
            let attribute = identifier(text(port, "id")?);
            let contract = field(port, "contract")?;
            let default = if !required(contract)? || nullable(contract)? {
                " = None"
            } else {
                ""
            };
            self.push(format!("    {attribute}: object{default}"));
        }
        if ports.is_empty() {
            self.push("    pass");
        }
        self.push("");
        self.push("    def __post_init__(self):");
        if ports.is_empty() {
            self.push("        pass");
        }
        for port in ports {
            let attribute = identifier(text(port, "id")?);
            let contract = field(port, "contract")?;
            self.push(format!("        if self.{attribute} is None:"));
            if !required(contract)? || nullable(contract)? {
                self.push("            pass");
            } else {
                self.push("            raise TypeError(\"required operation port\")");
            }
            self.push("        else:");
            self.push(format!(
                "            _ctx.validate({}, self.{attribute})",
                text_literal(type_id(contract)?)
            ));
        }
        self.push("");
        Ok(())
    }

    fn definitions(&mut self) -> Result<()> {
        for definition in list(self.library, "definitions")? {
            let identity = text(definition, "id")?.to_owned();
            let shape = field(definition, "shape")?;
            let spec = payload(shape);
            match tag(shape)? {
                "Value" | "Message" => {
                    let target = spec
                        .as_str()
                        .ok_or_else(|| invalid("generated value target"))?;
                    let value = format!("CODECS[{}][0]", text_literal(target));
                    set_entry(&mut self.entry_values, identity, value);
                }
                "Symbol" => {
                    let name = format!("D_{}_{}", identifier(&identity), digest(&identity, 12));
                    let value = spec.as_str().ok_or_else(|| invalid("generated symbol"))?;
                    self.push(format!("{name} = {}", text_literal(value)));
                    self.push("");
                    set_entry(&mut self.entry_values, identity, name);
                }
                "Operation" => self.operation(identity, spec)?,
                _ => {}
            }
        }
        Ok(())
    }

    fn operation(&mut self, identity: String, spec: &Value) -> Result<()> {
        let name = format!("D_{}_{}", identifier(&identity), digest(&identity, 12));
        let arguments = format!("{name}Arguments");
        self.port_class(&arguments, list(spec, "inputs")?)?;
        let mut outcomes: Vec<String> = Vec::new();
        let mut external: Vec<(String, String)> = Vec::new();
        for outcome in list(spec, "outcomes")? {
            let outcome_id = text(outcome, "id")?;
            let outcome_name = format!(
                "{name}Outcome_{}_{}",
                identifier(outcome_id),
                digest(outcome_id, 8)
            );
            self.port_class(&outcome_name, list(outcome, "value_ports")?)?;
            self.push(format!(
                "{outcome_name}.outcome_id = {}",
                text_literal(outcome_id)
            ));
            self.push(format!(
                "{outcome_name}.cause = {}",
                json_literal(field(outcome, "cause")?)
            ));
            self.push("");
            if tag(field(outcome, "cause")?)? == "ExternalCondition"
                && tag(field(outcome, "form")?)? == "DeclaredFailure"
            {
                external.push((outcome_name.clone(), outcome_id.to_owned()));
            }
            outcomes.push(outcome_name);
        }
        let result = format!("{name}Result");
        self.push(format!("{result}: TypeAlias = {}", outcomes.join(" | ")));
        self.push("");
        let function = format!("prepare_{name}");
        let external_values: Vec<String> = external
            .iter()
            .map(|(outcome_name, outcome_id)| {
                format!("({outcome_name}, {})", text_literal(outcome_id))
            })
            .collect();
        let trailing = if external_values.is_empty() { "" } else { "," };
        self.push(format!("def {function}(arguments, binding):"));
        self.push(format!(
            "    if type(arguments) is not {arguments}: raise TypeError('operation arguments have the wrong type')"
        ));
        self.push("    if type(binding) is not _execution.NetworkBinding: raise TypeError('operations require NetworkBinding')");
        self.push("    result = binding.prepare(arguments)");
        self.push("    if isinstance(result, _execution.ExecutionFailure): return result");
        self.push("    if isinstance(result, _execution.ReadyCall): return result");
        self.push("    if not isinstance(result, _execution.CompletedCall): return _execution.InvalidPlan('provider preparation representation')");
        self.push("    outcome = result.result");
        self.push(format!(
            "    matching = next((identity for outcome_type, identity in ({}{trailing}) if type(outcome) is outcome_type), None)",
            external_values.join(", ")
        ));
        self.push("    if matching is None or binding.outcome_id(outcome) != matching: return _execution.InvalidPlan('undeclared external completion')");
        self.push("    result = outcome");
        self.push(format!(
            "    if type(result) not in ({},): raise TypeError('undeclared operation outcome')",
            outcomes.join(", ")
        ));
        self.push("    return _execution.CompletedCall(result)");
        self.push("");
        set_entry(&mut self.entry_values, identity.clone(), function);
        set_entry(&mut self.entry_shapes, identity, (arguments, result));
        Ok(())
    }

    fn finish(&mut self) -> Result<()> {
        let names: Vec<(String, String)> = self
            .names
            .iter()
            .map(|(identity, name)| (text_literal(identity), text_literal(name)))
            .collect();
        let codecs: Vec<String> = self
            .names
            .iter()
            .map(|(identity, name)| {
                format!("{}: (decode_{name}, encode_{name})", text_literal(identity))
            })
            .collect();
        self.push(format!("TYPE_NAMES = {}", dict_literal(&names)));
        self.push(format!("CODECS = {{{}}}", codecs.join(", ")));
        self.push("");
        self.push("def examples(reference):");
        self.push("    name = TYPE_NAMES[reference]");
        self.push("    return globals()['examples_' + name]()");
        self.push("");

        let mut entries: Vec<(String, String)> = Vec::new();
        for entry in self.entrypoints {
            let identity = text(entry, "identity")?;
            let value = lookup(&self.entry_values, text(entry, "definition")?)?.clone();
            set_entry(&mut entries, identity.to_owned(), value);
        }
        if let Some(composition) = self.composition {
            let identity = text(field(composition, "problem")?, "identity")?;
            let value = lookup(&self.entry_values, identity)?.clone();
            set_entry(&mut entries, identity.to_owned(), value);
        }
        let entry_pairs: Vec<(String, String)> = entries
            .iter()
            .map(|(identity, value)| (text_literal(identity), value.clone()))
            .collect();
        self.push(format!("ENTRYPOINTS = {}", dict_literal(&entry_pairs)));

        let mut shapes: Vec<(String, (String, String))> = Vec::new();
        for entry in self.entrypoints {
            let definition = text(entry, "definition")?;
            if let Some(shape) = self
                .entry_shapes
                .iter()
                .find(|(entry_identity, _)| entry_identity == definition)
                .map(|(_, shape)| shape.clone())
            {
                set_entry(&mut shapes, text(entry, "identity")?.to_owned(), shape);
            }
        }
        if let Some(composition) = self.composition {
            let identity = text(field(composition, "problem")?, "identity")?;
            let shape = lookup(&self.entry_shapes, identity)?.clone();
            set_entry(&mut shapes, identity.to_owned(), shape);
        }
        let shape_pairs: Vec<(String, String)> = shapes
            .iter()
            .map(|(identity, (arguments, result))| {
                (
                    text_literal(identity),
                    tuple_literal(&[text_literal(arguments), text_literal(result)]),
                )
            })
            .collect();
        self.push(format!(
            "ENTRYPOINT_SHAPES = {}",
            dict_literal(&shape_pairs)
        ));
        self.push(format!(
            "ANNOTATIONS = {}",
            json_tuple_literal(field(self.library, "annotations")?)
        ));
        self.push(format!(
            "GROUPS = {}",
            json_tuple_literal(field(self.library, "groups")?)
        ));
        self.push(format!(
            "DECLARATIONS = {}",
            json_tuple_literal(field(self.library, "definitions")?)
        ));
        self.push("");
        Ok(())
    }
}
