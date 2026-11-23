// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::{field, flag, invalid, js, list, tag, text, Graph, Result};
use serde_json::Value;

const HELPERS: &str = r##"function integerValue(value: V.ExactJson, domain: string | null): Decoded<bigint> {
  const integer = V.integerValueForDomain(context.prepared, domain, value);
  return integer === null ? undecodable("validated integer") : decoded(integer);
}
function integerExact(shape: Extract<V.TypeShape, { readonly tag: "Integer" }>, value: bigint): V.ExactJson {
  const domain = context.profile.integer_domains.find(candidate => candidate.name === (shape.value.domain ?? context.profile.default_integer_domain));
  const forms = domain?.forms ?? [];
  if (forms.some(form => form.tag === "Number")) return { tag: "Integer", value: value.toString() };
  if (forms.some(form => form.tag === "IntegralDecimal")) return { tag: "Decimal", text: value.toString() + ".0" };
  if (forms.some(form => form.tag === "DecimalString")) return { tag: "String", value: value.toString() };
  throw new V.SemanticEvidenceError("integer encoding form");
}
type Decoded<T> = { readonly tag: "Ok"; readonly value: T } | { readonly tag: "Failed"; readonly condition: string };
function decoded<T>(value: T): Decoded<T> { return { tag: "Ok", value }; }
function undecodable(condition: string): Decoded<never> { return { tag: "Failed", condition }; }
function decodeCarrier(reference: V.TypeRef, value: V.ExactJson): Decoded<unknown> {
  const shape = context.node(reference).shape;
  if (shape.tag === "Alias") return decodeCarrier(shape.fields.target, value);
  if (shape.tag === "Never" || shape.tag === "Opaque") return undecodable("uninhabited type");
  if (shape.tag === "Unit") return value.tag === "Null" ? decoded(null) : undecodable("validated unit");
  if (shape.tag === "Boolean") return value.tag === "Bool" ? decoded(value.value) : undecodable("validated boolean");
  if (shape.tag === "Integer") return integerValue(value, shape.value.domain);
  if (shape.tag === "Decimal") return value.tag === "Decimal" ? decoded(new V.DecimalValue(value.text)) : undecodable("validated decimal");
  if (shape.tag === "String") return value.tag !== "String" && shape.value.wrapper === null ? undecodable("validated string") : decoded(shape.value.wrapper === null ? (value as Extract<V.ExactJson, { readonly tag: "String" }>).value : V.wrapDecode(context.prepared, shape.value.wrapper, value));
  if (shape.tag === "Bytes" || shape.tag === "RawBody") { const bytes = V.decodeBytes(context.prepared, value); return bytes === null ? undecodable("valid encoded bytes") : decoded(bytes); }
  if (shape.tag === "Unknown") return decoded(V.immutableDynamic(value));
  if (shape.tag === "Array") {
    if (value.tag !== "Array") return undecodable("validated array");
    const items: unknown[] = [];
    for (const item of value.items) {
      if (item.tag === "Null" && shape.value.item.nullable) { items.push(null); continue; }
      const child = decodeCarrier(shape.value.item.type_ref, item);
      if (child.tag === "Failed") return child;
      items.push(child.value);
    }
    return decoded(items);
  }
  if (shape.tag === "Product") {
    if (value.tag !== "Object") return undecodable("validated product");
    const result: Record<string, unknown> = Object.create(null);
    for (const field of shape.value.fields) {
      const item = V.memberValue(field.wire_name, value.members);
      if (item === undefined) continue;
      if (item.tag === "Null" && field.slot.nullable) { result[field.wire_name] = null; continue; }
      const child = decodeCarrier(field.slot.type_ref, item);
      if (child.tag === "Failed") return child;
      result[field.wire_name] = child.value;
    }
    if (shape.value.extras.tag === "Allow") for (const item of value.members) if (!shape.value.fields.some(field => field.wire_name === item.key) && item.key !== context.profile.tag?.key) {
      if (item.value.tag === "Null" && shape.value.extras.fields.value.nullable) { result[item.key] = null; continue; }
      const child = decodeCarrier(shape.value.extras.fields.value.type_ref, item.value);
      if (child.tag === "Failed") return child;
      result[item.key] = child.value;
    }
    const tagKey = context.profile.tag?.key;
    if (tagKey !== undefined && !Object.hasOwn(result, tagKey)) {
      const tag = V.memberValue(tagKey, value.members);
      if (tag !== undefined) result[tagKey] = V.immutableDynamic(tag);
    }
    return decoded(V.deepFreeze(V.preserveObjectOrder(result, value.members.map(item => item.key))));
  }
  if (shape.tag === "Sealed") {
    const form = context.profile.tag!.sealed.find(candidate => candidate.tag === shape.fields.tag)!;
    const result: Record<string, unknown> = {};
    for (const field of form.fields) {
      const item = value.tag === "Object" ? V.memberValue(field.key, value.members) : undefined;
      if (item === undefined) continue;
      const refinement = shape.fields.refinements.find(candidate => candidate.key === field.key)?.leaf ?? field.leaf;
      if (refinement.tag === "String") {
        if (refinement.value.wrapper === null && item.tag !== "String") return undecodable("validated string");
        result[field.key] = refinement.value.wrapper === null ? (item as Extract<V.ExactJson, { readonly tag: "String" }>).value : V.wrapDecode(context.prepared, refinement.value.wrapper, item);
      } else {
        const leaf = integerValue(item, refinement.value.domain);
        if (leaf.tag === "Failed") return leaf;
        result[field.key] = leaf.value;
      }
    }
    return decoded(V.deepFreeze(result));
  }
  if (shape.tag === "TaggedUnion") {
    const branch = V.selectBranch(context, reference, value);
    if (branch === null) return undecodable("validated union discriminator");
    const child = decodeCarrier(branch.target, value);
    return child.tag === "Failed" ? child : decoded(V.deepFreeze({ branch: branch.wire_tag, value: child.value }));
  }
  return decoded(value);
}
function encodeCarrier(reference: V.TypeRef, carrier: unknown): V.ExactJson {
  const shape = context.node(reference).shape;
  if (shape.tag === "Alias") return encodeCarrier(shape.fields.target, carrier);
  if (shape.tag === "Never" || shape.tag === "Opaque") throw new V.SemanticEvidenceError("uninhabited carrier");
  if (shape.tag === "Unit") return { tag: "Null" };
  if (shape.tag === "Boolean") return { tag: "Bool", value: carrier as boolean };
  if (shape.tag === "Integer") return integerExact(shape, carrier as bigint);
  if (shape.tag === "Decimal") return { tag: "Decimal", text: String(carrier) };
  if (shape.tag === "String") return shape.value.wrapper === null ? { tag: "String", value: carrier as string } : V.wrapEncode(context.profile, shape.value.wrapper, carrier as string);
  if (shape.tag === "Bytes" || shape.tag === "RawBody") return V.bytesExact(carrier as Uint8Array, context.profile);
  if (shape.tag === "Unknown") return V.dynamicExact(carrier as V.DynamicValue);
  if (shape.tag === "Array") return { tag: "Array", items: (carrier as readonly unknown[]).map(item => item === null && shape.value.item.nullable ? { tag: "Null" } : encodeCarrier(shape.value.item.type_ref, item)) };
  if (shape.tag === "Product") {
    const record = carrier as Record<string, unknown>, members: { key: string; value: V.ExactJson }[] = [];
    for (const field of shape.value.fields) if (record[field.wire_name] !== undefined) members.push({ key: field.wire_name, value: record[field.wire_name] === null && field.slot.nullable ? { tag: "Null" } : encodeCarrier(field.slot.type_ref, record[field.wire_name]) });
    if (shape.value.extras.tag === "Allow") for (const key of Object.keys(record)) if (!shape.value.fields.some(field => field.wire_name === key) && key !== context.profile.tag?.key) members.push({ key, value: record[key] === null && shape.value.extras.fields.value.nullable ? { tag: "Null" } : encodeCarrier(shape.value.extras.fields.value.type_ref, record[key]) });
    const tagKey = context.profile.tag?.key;
    if (tagKey !== undefined && !members.some(item => item.key === tagKey) && Object.hasOwn(record, tagKey)) members.push({ key: tagKey, value: { tag: "String", value: record[tagKey] as string } });
    return V.orderedObject(members, record);
  }
  if (shape.tag === "Sealed") {
    const record = carrier as Record<string, unknown>, form = context.profile.tag!.sealed.find(candidate => candidate.tag === shape.fields.tag)!, members: { key: string; value: V.ExactJson }[] = [];
    for (const field of form.fields) if (record[field.key] !== undefined) {
      const refinement = shape.fields.refinements.find(candidate => candidate.key === field.key)?.leaf ?? field.leaf;
      const value = refinement.tag === "String" ? (refinement.value.wrapper === null ? { tag: "String", value: record[field.key] as string } as const : V.wrapEncode(context.profile, refinement.value.wrapper, record[field.key] as string)) : integerExact({ tag: "Integer", value: refinement.value }, record[field.key] as bigint);
      members.push({ key: field.key, value });
    }
    return V.withMember(context.profile.tag!.key, shape.fields.tag, { tag: "Object", members });
  }
  if (shape.tag === "TaggedUnion") {
    const variant = carrier as { readonly branch: string; readonly value: unknown };
    const branch = shape.value.branches.find(candidate => candidate.wire_tag === variant.branch);
    if (branch === undefined) throw new V.SemanticEvidenceError("declared union branch");
    const encoded = encodeCarrier(branch.target, variant.value);
    return branch.selector.tag === "InternalTag" ? V.withMember(context.profile.tag!.key, branch.wire_tag, encoded) : encoded;
  }
  return carrier as V.ExactJson;
}
function carrierValue<T>(reference: V.TypeRef, value: V.ExactJson): T { const result = decodeCarrier(reference, value); if (result.tag === "Failed") throw new V.SemanticEvidenceError(result.condition); return result.value as T; }
function validatedJson(reference: V.TypeRef, value: V.ExactJson): V.ExactJson { V.validated(V.validateValue(context, reference, value), reference); return value; }
function carrierCodec<T>(reference: V.TypeRef) { return Object.freeze({ decode(value: V.ExactJson): T { return carrierValue<T>(reference, validatedJson(reference, value)); }, decodeWithDefaults(text: string): T { return carrierValue<T>(reference, context.decodeWithDefaults(reference, text).value); }, encode(value: T): V.ExactJson { return validatedJson(reference, encodeCarrier(reference, value)); } }); }
function unreachableCodec(reference: V.TypeRef) { return Object.freeze({ decode(value: V.ExactJson): never { throw new V.SemanticValueError(V.valueFailure(reference, [], { tag: "Uninhabited" }, { tag: "Present", value }, [])); }, decodeWithDefaults(text: string): never { const value = V.parseExact(text); context.decodeWithDefaults(reference, text); throw new V.SemanticValueError(V.valueFailure(reference, [], { tag: "Uninhabited" }, { tag: "Present", value }, [])); }, encode(value: never): V.ExactJson { return value; } }); }
"##;

fn native(graph: &Graph, reference: &Value) -> Result<String> {
    let shape = graph
        .shape(reference)
        .ok_or_else(|| invalid("resolved declaration"))?;
    Ok(match tag(shape)? {
        "Boolean" => "boolean".to_owned(),
        "Integer" => "bigint".to_owned(),
        "Decimal" => "V.DecimalValue".to_owned(),
        "String" => "string".to_owned(),
        _ => graph
            .name(reference)
            .unwrap_or_else(|| "V.ExactJson".to_owned()),
    })
}

fn declaration(graph: &Graph, index: usize, node: &Value) -> Result<String> {
    let reference = field(node, "reference")?;
    let id = graph
        .name(reference)
        .unwrap_or_else(|| "V.ExactJson".to_owned());
    let shape = field(node, "shape")?;
    let node_reference = format!("graph.nodes[{index}].reference");
    let carrier = |ty: String| {
        format!(
            "export type {id} = {ty};\nexport const {id}Codec = carrierCodec<{id}>({node_reference});"
        )
    };
    Ok(match tag(shape)? {
        "Never" => format!(
            "export type {id} = never;\nexport const {id}Codec = unreachableCodec({node_reference});"
        ),
        "Boolean" => carrier("boolean".to_owned()),
        "Integer" => carrier("bigint".to_owned()),
        "Decimal" => carrier("V.DecimalValue".to_owned()),
        "String" => carrier("string".to_owned()),
        "Unit" => carrier("null".to_owned()),
        "Alias" => carrier(native(graph, field(field(shape, "fields")?, "target")?)?),
        "Array" => {
            let item = field(field(shape, "value")?, "item")?;
            let suffix = if flag(item, "nullable")? { " | null" } else { "" };
            carrier(format!(
                "readonly ({}{suffix})[]",
                native(graph, field(item, "type_ref")?)?
            ))
        }
        "Product" => {
            let members = list(field(shape, "value")?, "fields")?
                .iter()
                .map(|member| {
                    let slot = field(member, "slot")?;
                    Ok(format!(
                        "readonly {}{}: {}{}",
                        js(text(member, "wire_name")?),
                        if flag(slot, "required")? { "" } else { "?" },
                        native(graph, field(slot, "type_ref")?)?,
                        if flag(slot, "nullable")? { " | null" } else { "" }
                    ))
                })
                .collect::<Result<Vec<_>>>()?
                .join("; ");
            format!(
                "export interface {id} {{ readonly [key: string]: unknown; {members} }}\nexport const {id}Codec = carrierCodec<{id}>({node_reference});"
            )
        }
        "Sealed" => {
            let members = graph
                .sealed_fields(text(field(shape, "fields")?, "tag")?)
                .iter()
                .map(|member| {
                    let leaf = if tag(field(member, "leaf")?)? == "String" {
                        "string"
                    } else {
                        "bigint"
                    };
                    Ok(format!(
                        "readonly {}{}: {leaf}",
                        js(text(member, "key")?),
                        if flag(member, "required")? { "" } else { "?" }
                    ))
                })
                .collect::<Result<Vec<_>>>()?
                .join("; ");
            format!(
                "export interface {id} {{ {members} }}\nexport const {id}Codec = carrierCodec<{id}>({node_reference});"
            )
        }
        "TaggedUnion" => {
            let branches = list(field(shape, "value")?, "branches")?
                .iter()
                .map(|branch| {
                    Ok(format!(
                        "{{ readonly branch: {}; readonly value: {} }}",
                        js(text(branch, "wire_tag")?),
                        native(graph, field(branch, "target")?)?
                    ))
                })
                .collect::<Result<Vec<_>>>()?
                .join(" | ");
            carrier(if branches.is_empty() {
                "never".to_owned()
            } else {
                branches
            })
        }
        "Bytes" | "RawBody" => carrier("Uint8Array".to_owned()),
        "Unknown" => carrier("V.DynamicValue".to_owned()),
        _ => carrier("V.ExactJson".to_owned()),
    })
}

pub(super) fn render(
    out: &mut String,
    graph: &Graph,
    library_json: &str,
    basis_json: &str,
) -> Result<()> {
    out.push_str(&format!(
        "const graph: V.ValueGraph = V.deepFreeze({});\nconst context = new V.ValueContext(graph);\nconst signatureLibrary = S.checkLibrary({library_json});\n",
        graph.value
    ));
    out.push_str(HELPERS);
    let declarations = graph
        .nodes
        .iter()
        .enumerate()
        .map(|(index, node)| declaration(graph, index, node))
        .collect::<Result<Vec<_>>>()?;
    out.push_str(&declarations.join("\n\n"));
    out.push_str(&format!(
        "\n\nexport const generationBasis: S.ExpectedSignatureBasis = V.deepFreeze({basis_json});\n"
    ));
    Ok(())
}
