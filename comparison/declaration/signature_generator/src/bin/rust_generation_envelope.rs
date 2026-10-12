// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::{decode_type_signatures, encode_signature_generation};
use necoherence::signature_admission::assemble_signature_generation;
use necoherence::type_signatures::SignatureEntrypoint;
use std::io::{self, BufRead, Write};

fn canonicalize_text_wrapper_payloads(
    library: &mut serde_json::Value,
) -> Result<(), Box<dyn std::error::Error>> {
    let wrappers = library
        .get_mut("profile")
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

fn envelope(line: &str) -> Result<String, Box<dyn std::error::Error>> {
    let request: serde_json::Value = serde_json::from_str(line)?;
    let mut library_document = request["library"].clone();
    canonicalize_text_wrapper_payloads(&mut library_document)?;
    let library = decode_type_signatures(&library_document.to_string())?;
    let entrypoints = request["entrypoints"]
        .as_array()
        .ok_or("entrypoints required")?
        .iter()
        .map(|entrypoint| {
            Ok(SignatureEntrypoint {
                identity: entrypoint["identity"]
                    .as_str()
                    .ok_or("entrypoint identity required")?
                    .to_owned(),
                definition: entrypoint["definition"]
                    .as_str()
                    .ok_or("entrypoint definition required")?
                    .to_owned(),
            })
        })
        .collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
    let input = assemble_signature_generation(library, None, entrypoints)?;
    Ok(encode_signature_generation(&input)?)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut output = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let result = match envelope(&line?) {
            Ok(exchange) => serde_json::json!({"exchange": exchange}),
            Err(error) => serde_json::json!({"error": error.to_string()}),
        };
        serde_json::to_writer(&mut output, &result)?;
        output.write_all(b"\n")?;
    }
    Ok(())
}
