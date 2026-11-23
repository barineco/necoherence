// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::identifiers::{
    boolean, lower, lower_identifier, quote, ref_name, reference_literal, upper_identifier, Names,
};
use super::wire::{field, invalid, list, scalar_text, tag, text, Result};
use crate::renderer::RenderFailure;
use serde_json::Value;

struct Parts {
    payload: String,
    declarations: Vec<String>,
    functions: Vec<String>,
}

pub(super) fn render_type(
    node: &Value,
    type_name: &str,
    names: &Names,
    profile: &Value,
) -> Result<Vec<String>> {
    let reference = field(node, "reference")?;
    let shape = field(node, "shape")?;
    let kind = tag(shape)?;
    let parts = match kind {
        "Product" => product(type_name, field(shape, "value")?, names)?,
        "Array" => array(type_name, field(shape, "value")?, names)?,
        "Alias" => alias(type_name, field(field(shape, "fields")?, "target")?, names)?,
        "TaggedUnion" => union(type_name, field(shape, "value")?, names)?,
        "Never" => never(type_name),
        "Sealed" => sealed(type_name, text(field(shape, "fields")?, "tag")?),
        "Opaque" => {
            return Err(RenderFailure::UndefinedType(
                text(reference, "definition_name")?.to_owned(),
            ))
        }
        _ => scalar(type_name, shape, profile)?,
    };
    let function_name = lower(type_name);
    let wire_field = match kind {
        "Bytes" | "RawBody" => ", wire: Option(String)",
        "Product" => ", member_order: List(String)",
        _ => "",
    };
    let wire_argument = match kind {
        "Bytes" | "RawBody" => ", None",
        "Product" => ", []",
        _ => "",
    };
    let mut lines = vec![String::new()];
    lines.extend(parts.declarations);
    lines.extend(common(
        type_name,
        &function_name,
        &parts.payload,
        wire_field,
        wire_argument,
        reference,
    )?);
    lines.extend(parts.functions);
    if let Some(literal) = default_literal(shape)? {
        lines.push(format!(
            "pub fn default_{function_name}(context: Context) -> Result({type_name}, ValueFailure) {{ new_{function_name}(context, {literal}) }}"
        ));
    }
    lines.push(String::new());
    Ok(lines)
}

fn common(
    type_name: &str,
    function_name: &str,
    payload: &str,
    wire_field: &str,
    wire_argument: &str,
    reference: &Value,
) -> Result<Vec<String>> {
    let reference_name = ref_name(type_name);
    Ok(vec![
        format!(
            "pub const {reference_name}: types.TypeRef = {}",
            reference_literal(reference)?
        ),
        format!(
            "pub opaque type {type_name} {{ {type_name}(value: {payload}{wire_field}) }}"
        ),
        format!(
            "pub fn value_{function_name}(value: {type_name}) -> {payload} {{ value.value }}"
        ),
        format!(
            "pub fn new_{function_name}(context: Context, value: {payload}) -> Result({type_name}, ValueFailure) {{"
        ),
        format!("  let wrapped = {type_name}(value{wire_argument})"),
        format!("  use raw <- result.try(pack_{function_name}(context, wrapped))"),
        format!(
            "  use _ <- result.try(runtime.validate_value(prepared(context), {reference_name}, raw))"
        ),
        "  Ok(wrapped)".to_owned(),
        "}".to_owned(),
        format!(
            "pub fn from_value_{function_name}(context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{"
        ),
        format!(
            "  use _ <- result.try(runtime.validate_value(prepared(context), {reference_name}, value))"
        ),
        format!("  unpack_{function_name}(context, value)"),
        "}".to_owned(),
        format!(
            "pub fn to_value_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{"
        ),
        format!("  use raw <- result.try(pack_{function_name}(context, value))"),
        format!(
            "  use _ <- result.try(runtime.validate_value(prepared(context), {reference_name}, raw))"
        ),
        "  Ok(raw)".to_owned(),
        "}".to_owned(),
        format!(
            "pub fn decode_{function_name}(context: Context, wire: String) -> Result({type_name}, ValueFailure) {{"
        ),
        format!(
            "  use raw <- result.try(result.map_error(values.parse_wire(wire), fn(failure) {{ runtime.Wire({reference_name}, failure) }}))"
        ),
        format!("  from_value_{function_name}(context, raw)"),
        "}".to_owned(),
        format!(
            "pub fn encode_{function_name}(context: Context, value: {type_name}) -> Result(String, ValueFailure) {{"
        ),
        format!("  use raw <- result.try(to_value_{function_name}(context, value))"),
        format!(
            "  result.map_error(values.encode_wire(raw), fn(failure) {{ runtime.Wire({reference_name}, failure) }})"
        ),
        "}".to_owned(),
        format!(
            "pub fn with_defaults_{function_name}(context: Context, wire: String) -> Result({type_name}, ValueFailure) {{"
        ),
        format!(
            "  use raw <- result.try(result.map_error(values.parse_wire(wire), fn(failure) {{ runtime.Wire({reference_name}, failure) }}))"
        ),
        format!(
            "  use defaulted <- result.try(result.map_error(validation.materialize_defaults(prepared(context), {reference_name}, raw), runtime.Constraint))"
        ),
        format!(
            "  unpack_{function_name}(context, validation.defaulted_value(defaulted))"
        ),
        "}".to_owned(),
    ])
}

pub(super) fn default_literal(shape: &Value) -> Result<Option<String>> {
    let kind = tag(shape)?;
    if !matches!(kind, "Boolean" | "Integer" | "String") {
        return Ok(None);
    }
    let default = shape
        .get("value")
        .and_then(|spec| spec.get("default_value"))
        .filter(|value| !value.is_null());
    Ok(match (kind, default) {
        ("Boolean", Some(Value::Bool(value))) => Some(boolean(*value).to_owned()),
        ("Integer", Some(value)) => Some(scalar_text(value)?),
        ("String", Some(Value::String(value))) => Some(quote(value)),
        _ => None,
    })
}

fn integer_encoder(profile: &Value, domain: Option<&str>) -> Result<String> {
    let name = match domain {
        Some(name) => name,
        None => text(profile, "default_integer_domain")?,
    };
    let binding = list(profile, "integer_domains")?
        .iter()
        .find(|binding| binding.get("name").and_then(Value::as_str) == Some(name))
        .ok_or_else(|| invalid("integer encoding"))?;
    let forms: Vec<&str> = list(binding, "forms")?
        .iter()
        .filter_map(|form| form.get("tag").and_then(Value::as_str))
        .collect();
    if forms.contains(&"Number") {
        Ok("Ok(kdl.JsonValueNum(value.value))".to_owned())
    } else if forms.contains(&"IntegralDecimal") {
        Ok("Ok(values.integral_decimal_value(value.value))".to_owned())
    } else if forms.contains(&"DecimalString") {
        Ok("Ok(values.decimal_string_value(value.value))".to_owned())
    } else {
        Err(invalid("integer encoding"))
    }
}

fn domain_option(domain: Option<&str>) -> String {
    match domain {
        Some(name) => format!("Some({})", quote(name)),
        None => "None".to_owned(),
    }
}

fn scalar(type_name: &str, shape: &Value, profile: &Value) -> Result<Parts> {
    let function_name = lower(type_name);
    let reference = ref_name(type_name);
    let kind = tag(shape)?;
    let spec = shape.get("value");
    let domain = spec
        .and_then(|spec| spec.get("domain"))
        .and_then(Value::as_str);
    let wrapper = spec
        .and_then(|spec| spec.get("wrapper"))
        .and_then(Value::as_str);
    let (payload, encoded, decoded) = match kind {
        "Boolean" => (
            "Bool",
            "Ok(kdl.JsonValueBool(value.value))".to_owned(),
            format!(
                "case value {{ kdl.JsonValueBool(value) -> Ok({type_name}(value)) _ -> representation({reference}) }}"
            ),
        ),
        "Integer" => (
            "Int",
            integer_encoder(profile, domain)?,
            format!(
                "case validation.integer_value_for_domain(prepared(context), {}, value) {{ Some(integer) -> Ok({type_name}(integer)) None -> representation({reference}) }}",
                domain_option(domain)
            ),
        ),
        "Decimal" => (
            "String",
            "Ok(kdl.JsonValueDec(value.value))".to_owned(),
            format!(
                "case value {{ kdl.JsonValueDec(value) -> Ok({type_name}(value)) _ -> representation({reference}) }}"
            ),
        ),
        "String" => match wrapper {
            None => (
                "String",
                "Ok(kdl.JsonValueStr(value.value))".to_owned(),
                format!(
                    "case value {{ kdl.JsonValueStr(value) -> Ok({type_name}(value)) _ -> representation({reference}) }}"
                ),
            ),
            Some(wrapper) => (
                "String",
                format!(
                    "result.map_error(result.map(runtime.named_wrapper(prepared(context), {}), fn(wrapper) {{ runtime.wrap_encode(wrapper, value.value) }}), fn(_) {{ runtime.Representation({reference}, \"wrapper encode\") }})",
                    quote(wrapper)
                ),
                format!(
                    "use text <- result.try(result.map_error(result.try(runtime.named_wrapper(prepared(context), {}), fn(wrapper) {{ runtime.wrap_decode(wrapper, value) }}), fn(_) {{ runtime.Representation({reference}, \"wrapper decode\") }})) Ok({type_name}(text))",
                    quote(wrapper)
                ),
            ),
        },
        "Bytes" | "RawBody" => (
            "List(Int)",
            format!(
                "use encoded <- result.try(case value.wire {{ Some(text) -> Ok(text) None -> result.map_error(native.encode_bytes(value.value), fn(_) {{ runtime.Representation({reference}, \"byte outside 0..255\") }}) }}) Ok(runtime.bytes_wire(prepared(context), encoded))"
            ),
            format!(
                "use payload <- result.try(case graph(context).profile.bytes_policy {{ Some(types.BytesPolicy(wrapper: Some(name), ..)) -> result.map(result.map_error(result.try(runtime.named_wrapper(prepared(context), name), fn(wrapper) {{ runtime.wrap_decode(wrapper, value) }}), fn(_) {{ runtime.Representation({reference}, \"wrapper decode\") }}), kdl.JsonValueStr) _ -> Ok(value) }}) case payload {{ kdl.JsonValueStr(text) -> {{ use bytes <- result.try(result.map_error(native.decode_bytes(text), fn(_) {{ runtime.Representation({reference}, \"invalid base64\") }})) Ok({type_name}(bytes, Some(text))) }} _ -> representation({reference}) }}"
            ),
        ),
        "Unit" => (
            "Nil",
            "Ok(kdl.JsonValueNull)".to_owned(),
            format!(
                "case value {{ kdl.JsonValueNull -> Ok({type_name}(Nil)) _ -> representation({reference}) }}"
            ),
        ),
        "Unknown" => (
            "kdl.JsonValue",
            "Ok(value.value)".to_owned(),
            format!("Ok({type_name}(value))"),
        ),
        _ => return Err(invalid("generated scalar shape")),
    };
    Ok(Parts {
        payload: payload.to_owned(),
        declarations: Vec::new(),
        functions: vec![
            format!(
                "fn pack_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{ {encoded} }}"
            ),
            format!(
                "fn unpack_{function_name}(context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{ {decoded} }}"
            ),
        ],
    })
}

fn never(type_name: &str) -> Parts {
    let payload = format!("{type_name}Payload");
    let function_name = lower(type_name);
    let reference = ref_name(type_name);
    Parts {
        payload: payload.clone(),
        declarations: vec![format!("pub type {payload} {{}}")],
        functions: vec![
            format!(
                "fn pack_{function_name}(_context: Context, _value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{ Error(runtime.Representation({reference}, \"Uninhabited\")) }}"
            ),
            format!(
                "fn unpack_{function_name}(_context: Context, _value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{ Error(runtime.Representation({reference}, \"Uninhabited\")) }}"
            ),
        ],
    }
}

fn sealed(type_name: &str, form_tag: &str) -> Parts {
    let function_name = lower(type_name);
    let reference = ref_name(type_name);
    Parts {
        payload: "kdl.JsonValue".to_owned(),
        declarations: Vec::new(),
        functions: vec![
            format!(
                "fn pack_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{ use model <- result.try(case graph(context).profile.tag {{ Some(model) -> Ok(model) None -> Error(runtime.Representation({reference}, \"tag model\")) }}) result.map_error(runtime.with_member(model.key, {}, value.value), fn(_) {{ runtime.Representation({reference}, \"sealed encode\") }}) }}",
                quote(form_tag)
            ),
            format!(
                "fn unpack_{function_name}(_context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{ Ok({type_name}(value)) }}"
            ),
        ],
    }
}

fn product(type_name: &str, spec: &Value, names: &Names) -> Result<Parts> {
    let fields = list(spec, "fields")?
        .iter()
        .map(|member| {
            let slot = field(member, "slot")?;
            let child = names.name(field(slot, "type_ref")?)?.to_owned();
            Ok((
                text(member, "wire_name")?.to_owned(),
                lower_identifier(text(member, "wire_name")?, "field"),
                child,
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    let payload = format!("{type_name}Payload");
    let function_name = lower(type_name);
    let reference = ref_name(type_name);
    let mut slots: Vec<String> = fields
        .iter()
        .map(|(_, variable, child)| format!("{variable}: types.SlotValue({child})"))
        .collect();
    slots.push("extras: List(#(String, kdl.JsonValue))".to_owned());
    let declaration = vec![
        format!("pub type {payload} {{"),
        format!("  {payload}({})", slots.join(", ")),
        "}".to_owned(),
    ];
    let mut pack = vec![format!(
        "fn pack_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{"
    )];
    for (_, variable, child) in &fields {
        pack.push(format!(
            "  use {variable}_slot <- result.try(runtime.map_slot(value.value.{variable}, fn(item) {{ pack_{}(context, item) }}))",
            lower(child)
        ));
    }
    let mut members: Vec<String> = fields
        .iter()
        .map(|(wire, variable, _)| {
            format!("runtime.slot_members({}, {variable}_slot)", quote(wire))
        })
        .collect();
    members.push("value.value.extras".to_owned());
    pack.push(format!(
        "  Ok(kdl.JsonValueObj(runtime.ordered_members(list.flatten([{}]), value.member_order)))",
        members.join(", ")
    ));
    pack.push("}".to_owned());
    let wires: Vec<String> = fields.iter().map(|(wire, _, _)| quote(wire)).collect();
    let mut unpack = vec![
        format!(
            "fn unpack_{function_name}(context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{"
        ),
        "  case value {".to_owned(),
        "    kdl.JsonValueObj(members) -> {".to_owned(),
    ];
    for (wire, variable, child) in &fields {
        unpack.push(format!(
            "      use {variable}_slot <- result.try(runtime.map_slot(runtime.member_slot(members, {}), fn(item) {{ unpack_{}(context, item) }}))",
            quote(wire),
            lower(child)
        ));
    }
    unpack.push(format!(
        "      let extras = list.filter(members, fn(member) {{ !list.contains([{}], member.0) }})",
        wires.join(", ")
    ));
    let mut arguments: Vec<String> = fields
        .iter()
        .map(|(_, variable, _)| format!("{variable}_slot"))
        .collect();
    arguments.push("extras".to_owned());
    unpack.push(format!(
        "      Ok({type_name}({payload}({}), list.map(members, fn(member) {{ member.0 }})))",
        arguments.join(", ")
    ));
    unpack.push("    }".to_owned());
    unpack.push(format!("    _ -> representation({reference})"));
    unpack.push("  }".to_owned());
    unpack.push("}".to_owned());
    let functions = pack.into_iter().chain(unpack).collect();
    Ok(Parts {
        payload,
        declarations: declaration,
        functions,
    })
}

fn array(type_name: &str, spec: &Value, names: &Names) -> Result<Parts> {
    let child = names
        .name(field(field(spec, "item")?, "type_ref")?)?
        .to_owned();
    let function_name = lower(type_name);
    let reference = ref_name(type_name);
    Ok(Parts {
        payload: format!("List({child})"),
        declarations: Vec::new(),
        functions: vec![
            format!(
                "fn pack_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{ result.map(list.try_map(value.value, fn(item) {{ pack_{}(context, item) }}), kdl.JsonValueArr) }}",
                lower(&child)
            ),
            format!(
                "fn unpack_{function_name}(context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{ case value {{ kdl.JsonValueArr(items) -> result.map(list.try_map(items, fn(item) {{ unpack_{}(context, item) }}), {type_name}) _ -> representation({reference}) }} }}",
                lower(&child)
            ),
        ],
    })
}

fn alias(type_name: &str, target: &Value, names: &Names) -> Result<Parts> {
    let child = names.name(target)?.to_owned();
    let function_name = lower(type_name);
    Ok(Parts {
        payload: child.clone(),
        declarations: Vec::new(),
        functions: vec![
            format!(
                "fn pack_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{ pack_{}(context, value.value) }}",
                lower(&child)
            ),
            format!(
                "fn unpack_{function_name}(context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{ result.map(unpack_{}(context, value), {type_name}) }}",
                lower(&child)
            ),
        ],
    })
}

fn value_kind_literal(kind: &str) -> Result<&'static str> {
    Ok(match kind {
        "Null" => "types.NullKind",
        "Boolean" => "types.BooleanKind",
        "Number" => "types.NumberKind",
        "String" => "types.StringKind",
        "Array" => "types.ArrayKind",
        "Object" => "types.ObjectKind",
        _ => return Err(invalid("generated value kind")),
    })
}

fn kind_name(value: &Value) -> Result<&str> {
    match value {
        Value::String(name) => Ok(name),
        _ => tag(value),
    }
}

fn selector_literal(selector: &Value) -> Result<String> {
    Ok(match tag(selector)? {
        "InternalTag" => "types.InternalTag".to_owned(),
        "Otherwise" => "types.Otherwise".to_owned(),
        "Kind" => format!(
            "types.Kind({})",
            value_kind_literal(kind_name(field(selector, "value")?)?)?
        ),
        "MemberShape" => {
            let entries = list(selector, "value")?
                .iter()
                .map(|check| {
                    let test = field(check, "test")?;
                    let test_literal = match tag(test)? {
                        "Absent" => "types.AbsentMember".to_owned(),
                        "Format" => format!("types.FormatMember({})", quote(text(test, "value")?)),
                        _ => return Err(invalid("generated member test")),
                    };
                    Ok(format!("#({}, {test_literal})", quote(text(check, "key")?)))
                })
                .collect::<Result<Vec<_>>>()?;
            format!("types.MemberShape([{}])", entries.join(", "))
        }
        _ => return Err(invalid("generated branch selector")),
    })
}

fn union(type_name: &str, spec: &Value, names: &Names) -> Result<Parts> {
    let branches = list(spec, "branches")?
        .iter()
        .map(|branch| {
            let target = field(branch, "target")?;
            Ok((
                branch,
                upper_identifier(text(branch, "wire_tag")?, "Variant"),
                names.name(target)?.to_owned(),
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    let payload = format!("{type_name}Payload");
    let function_name = lower(type_name);
    let reference = ref_name(type_name);
    let mut declaration = vec![format!("pub type {payload} {{")];
    for (_, variant, child) in &branches {
        declaration.push(format!("  {type_name}{variant}(value: {child})"));
    }
    declaration.push("}".to_owned());
    let mut functions = vec![
        format!(
            "fn pack_{function_name}(context: Context, value: {type_name}) -> Result(kdl.JsonValue, ValueFailure) {{"
        ),
        "  case value.value {".to_owned(),
    ];
    for (branch, variant, child) in &branches {
        let encoded = if tag(field(branch, "selector")?)? == "InternalTag" {
            format!(
                "runtime.tag_object(graph(context).profile, {reference}, payload, {})",
                quote(text(branch, "wire_tag")?)
            )
        } else {
            "Ok(payload)".to_owned()
        };
        functions.push(format!(
            "    {type_name}{variant}(value) -> {{ use payload <- result.try(pack_{}(context, value)) {encoded} }}",
            lower(child)
        ));
    }
    functions.push("  }".to_owned());
    functions.push("}".to_owned());
    let selectors = branches
        .iter()
        .map(|(branch, _, _)| {
            Ok(format!(
                "#({}, {})",
                quote(text(branch, "wire_tag")?),
                selector_literal(field(branch, "selector")?)?
            ))
        })
        .collect::<Result<Vec<_>>>()?
        .join(", ");
    functions.push(format!(
        "fn unpack_{function_name}(context: Context, value: kdl.JsonValue) -> Result({type_name}, ValueFailure) {{"
    ));
    functions.push(format!(
        "  case runtime.select_branch(prepared(context), [{selectors}], value) {{"
    ));
    for (index, (_, variant, child)) in branches.iter().enumerate() {
        functions.push(format!(
            "    Ok({index}) -> result.map(unpack_{}(context, value), fn(child) {{ {type_name}({type_name}{variant}(child)) }})",
            lower(child)
        ));
    }
    functions.push(format!("    _ -> representation({reference})"));
    functions.push("  }".to_owned());
    functions.push("}".to_owned());
    Ok(Parts {
        payload,
        declarations: declaration,
        functions,
    })
}
