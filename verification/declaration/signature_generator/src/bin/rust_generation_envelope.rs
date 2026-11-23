// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::{
    decode_type_signatures, encode_signature_generation, GenerationFailure,
};
use necoherence::signature_admission::{assemble_signature_generation, AdmissionFailure};
use necoherence::type_signatures::SignatureEntrypoint;
use std::io::{self, BufRead, Write};

#[derive(Debug)]
enum EnvelopeFailure {
    Io(io::Error),
    Json(serde_json::Error),
    Generation(GenerationFailure),
    Admission(Box<AdmissionFailure>),
    Input(&'static str),
}

impl EnvelopeFailure {
    fn message(&self) -> String {
        match self {
            Self::Io(failure) => failure.to_string(),
            Self::Json(failure) => failure.to_string(),
            Self::Generation(failure) => failure.to_string(),
            Self::Admission(failure) => failure.to_string(),
            Self::Input(name) => (*name).to_owned(),
        }
    }
}

impl From<io::Error> for EnvelopeFailure {
    fn from(failure: io::Error) -> Self {
        Self::Io(failure)
    }
}

impl From<serde_json::Error> for EnvelopeFailure {
    fn from(failure: serde_json::Error) -> Self {
        Self::Json(failure)
    }
}

impl From<GenerationFailure> for EnvelopeFailure {
    fn from(failure: GenerationFailure) -> Self {
        Self::Generation(failure)
    }
}

impl From<AdmissionFailure> for EnvelopeFailure {
    fn from(failure: AdmissionFailure) -> Self {
        Self::Admission(Box::new(failure))
    }
}

impl From<&'static str> for EnvelopeFailure {
    fn from(name: &'static str) -> Self {
        Self::Input(name)
    }
}

fn canonicalize_text_wrapper_payloads(
    library: &mut serde_json::Value,
) -> Result<(), EnvelopeFailure> {
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

fn envelope(line: &str) -> Result<String, EnvelopeFailure> {
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
        .collect::<Result<Vec<_>, EnvelopeFailure>>()?;
    let input = assemble_signature_generation(library, None, entrypoints)?;
    Ok(encode_signature_generation(&input)?)
}

fn main() -> Result<(), EnvelopeFailure> {
    let mut output = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let result = match envelope(&line?) {
            Ok(exchange) => serde_json::json!({"exchange": exchange}),
            Err(failure) => serde_json::json!({"error": failure.message()}),
        };
        serde_json::to_writer(&mut output, &result)?;
        output.write_all(b"\n")?;
    }
    Ok(())
}
