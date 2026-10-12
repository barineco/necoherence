// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
use necoherence::semantic_composition::{
    check_assignable, slot_samples, CompatibilityDecision, SearchBounds,
};
use necoherence::semantic_exchange::{decode_signature_generation, encode_signature_generation};
use necoherence::semantic_types::{
    JsonValue, PathStep, SlotContract, ValueCondition, ValueDecision,
};
use necoherence::semantic_validation::accepts_value;
use necoherence::signature_admission::{admit_signature_generation, signature_type_ref};
use num_traits::ToPrimitive;
use std::io::{self, BufRead, Write};
fn condition(v: &ValueCondition) -> String {
    format!("{v:?}")
}
fn path(path: &[PathStep]) -> Vec<serde_json::Value> {
    path.iter()
        .map(|step| match step {
            PathStep::Field(name) => serde_json::json!(name),
            PathStep::Index(index) => index.to_u64().map_or_else(
                || serde_json::json!(index.to_string()),
                |value| serde_json::json!(value),
            ),
            PathStep::Variant(tag) => serde_json::json!(format!("variant:{tag}")),
        })
        .collect()
}
fn type_ref(reference: &necoherence::semantic_types::TypeRef) -> serde_json::Value {
    serde_json::json!({
        "source": {
            "repository": reference.source.repository,
            "revision": reference.source.revision,
            "path": reference.source.path,
            "content_digest": reference.source.content_digest,
            "document_id": reference.source.document_id,
            "declared_revision": reference.source.declared_revision.as_ref().map(ToString::to_string),
        },
        "definition_name": reference.definition_name.as_ref(),
        "pointer": reference.pointer.as_ref(),
    })
}
fn exact_json(value: &serde_json::Value) -> Result<JsonValue, String> {
    let fields = value.as_object().ok_or("exact JSON object")?;
    let tag = fields
        .get("tag")
        .and_then(serde_json::Value::as_str)
        .ok_or("exact JSON tag")?;
    match tag {
        "Null" => Ok(JsonValue::Null),
        "Bool" => fields
            .get("value")
            .and_then(serde_json::Value::as_bool)
            .map(JsonValue::Bool)
            .ok_or_else(|| "exact JSON boolean".to_owned()),
        "Integer" => fields
            .get("value")
            .and_then(serde_json::Value::as_str)
            .ok_or("exact JSON integer")?
            .parse()
            .map(JsonValue::Num)
            .map_err(|failure| format!("exact JSON integer: {failure}")),
        "Decimal" => fields
            .get("text")
            .and_then(serde_json::Value::as_str)
            .map(|text| JsonValue::Dec(text.to_owned()))
            .ok_or_else(|| "exact JSON decimal".to_owned()),
        "String" => fields
            .get("value")
            .and_then(serde_json::Value::as_str)
            .map(|text| JsonValue::Str(text.to_owned()))
            .ok_or_else(|| "exact JSON string".to_owned()),
        "Array" => fields
            .get("items")
            .and_then(serde_json::Value::as_array)
            .ok_or("exact JSON array")?
            .iter()
            .map(exact_json)
            .collect::<Result<Vec<_>, _>>()
            .map(JsonValue::Arr),
        "Object" => fields
            .get("members")
            .and_then(serde_json::Value::as_array)
            .ok_or("exact JSON members")?
            .iter()
            .map(|member| {
                let member = member.as_object().ok_or("exact JSON member")?;
                let key = member
                    .get("key")
                    .and_then(serde_json::Value::as_str)
                    .ok_or("exact JSON member key")?;
                let value = member.get("value").ok_or("exact JSON member value")?;
                Ok((key.to_owned(), exact_json(value)?))
            })
            .collect::<Result<Vec<_>, String>>()
            .map(JsonValue::Obj),
        _ => Err(format!("unknown exact JSON tag: {tag}")),
    }
}
fn canonicalize_text_wrapper_payloads(
    exchange: &mut serde_json::Value,
) -> Result<(), &'static str> {
    let wrappers = exchange
        .get_mut("signatures")
        .and_then(|signatures| signatures.get_mut("profile"))
        .and_then(|profile| profile.get_mut("wrappers"))
        .and_then(serde_json::Value::as_array_mut)
        .ok_or("profile wrappers required")?;
    for wrapper in wrappers {
        let Some(payload) = wrapper
            .get_mut("payload")
            .and_then(serde_json::Value::as_object_mut)
        else {
            continue;
        };
        if payload.get("tag").and_then(serde_json::Value::as_str) != Some("Text")
            || payload.contains_key("value")
        {
            continue;
        }
        let value = payload
            .remove("fields")
            .and_then(|fields| fields.as_object().cloned())
            .and_then(|mut fields| fields.remove("format"))
            .ok_or("text wrapper format required")?;
        payload.insert("value".into(), value);
    }
    Ok(())
}

fn evaluate(line: io::Result<String>) -> Result<serde_json::Value, String> {
    let line = line.map_err(|e| e.to_string())?;
    let case: serde_json::Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    let id = case.get("id").cloned().unwrap_or(serde_json::Value::Null);
    let kind = case.get("kind").and_then(|v| v.as_str()).unwrap_or("admit");
    if kind == "wire" {
        let value = case.get("value").ok_or("value")?;
        let input = decode_signature_generation(&value.to_string()).map_err(|e| e.to_string())?;
        let encoded = encode_signature_generation(&input).map_err(|e| e.to_string())?;
        return Ok(serde_json::json!({
            "id": id,
            "status": "Accepted",
            "encoded": serde_json::from_str::<serde_json::Value>(&encoded)
                .map_err(|e| e.to_string())?
        }));
    }
    let mut exchange = case.get("exchange").ok_or("exchange")?.clone();
    if !exchange.is_string() {
        canonicalize_text_wrapper_payloads(&mut exchange)?;
    }
    let text = exchange
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| exchange.to_string());
    let input = decode_signature_generation(&text).map_err(|e| e.to_string())?;
    let checked =
        admit_signature_generation(&input.basis, input.clone()).map_err(|e| e.to_string())?;
    let graph = checked.graph();
    if kind == "admit" {
        return Ok(serde_json::json!({"id":id,"status":"Accepted"}));
    }
    let type_id = case
        .get("type_id")
        .and_then(|v| v.as_str())
        .ok_or("type_id")?;
    let reference = signature_type_ref(&input.signatures, &input.basis.graph_sha256, type_id);
    if kind == "value" {
        let value = exact_json(case.get("value").ok_or("value")?)?;
        return Ok(match accepts_value(graph, &reference, &value) {
            ValueDecision::Accepted => serde_json::json!({"id":id,"status":"Accepted"}),
            ValueDecision::Rejected(f) => {
                let trace: Vec<_> = f
                    .reference_trace
                    .iter()
                    .map(|reference| reference.definition_name.as_ref())
                    .collect();
                serde_json::json!({"id":id,"status":"Rejected","type_ref":type_ref(&f.type_ref),"condition":condition(&f.condition),"path":path(&f.value_path),"trace":trace})
            }
            ValueDecision::Unresolved(o) => {
                serde_json::json!({"id":id,"status":"Unresolved","obligations":format!("{o:?}")})
            }
        });
    }
    let slot = SlotContract {
        type_ref: reference,
        required: true,
        nullable: false,
    };
    if kind == "samples" {
        let r = slot_samples(graph, &SearchBounds::default(), &slot);
        return Ok(
            serde_json::json!({"id":id,"status":"Samples","values":r.values.iter().map(|v|format!("{v:?}")).collect::<Vec<_>>(),"obligations":format!("{:?}",r.obligations)}),
        );
    }
    let destination = case
        .get("destination_type_id")
        .and_then(|v| v.as_str())
        .ok_or("destination_type_id")?;
    let d = SlotContract {
        type_ref: signature_type_ref(&input.signatures, &input.basis.graph_sha256, destination),
        required: true,
        nullable: false,
    };
    Ok(match check_assignable(graph, &slot, &d, 64) {
        CompatibilityDecision::Compatible(certificate) => {
            let rule = certificate.rule;
            serde_json::json!({"id":id,"status":"Compatible","rule":format!("{rule:?}")})
        }
        CompatibilityDecision::Incompatible(c) => {
            serde_json::json!({"id":id,"status":"Incompatible","condition":condition(&c.destination_failure.condition)})
        }
        CompatibilityDecision::Unknown(o) => {
            serde_json::json!({"id":id,"status":"Unknown","obligations":format!("{o:?}")})
        }
    })
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    for line in io::stdin().lock().lines() {
        let value =
            evaluate(line).unwrap_or_else(|e| serde_json::json!({"status":"Error","message":e}));
        serde_json::to_writer(&mut output, &value)?;
        output.write_all(b"\n")?;
    }
    Ok(())
}
