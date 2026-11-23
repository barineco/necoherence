// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_exchange::{
    decode_exact_value, decode_semantic_obligations, decode_signature_basis, decode_type_reference,
    encode, encode_exact_value, encode_semantic_obligations, encode_signature_basis, syntax,
    GenerationFailure,
};
use crate::semantic_refinement::{open_signature_evaluation, SignatureEvaluation};
use crate::semantic_types::{RefinementOutcome, ResidualSet, SemanticObligation, TypeRef};
use crate::signature_admission::{CheckedSignatureGeneration, SemanticValueInput};
use crate::type_signatures::SignatureGenerationBasis;
use neco_quotient_encoding::{
    canonical_bytes, decode_canonical, normalize_residuals, EncodingFailure, JsonValue as Neco,
};

pub const SEMANTIC_RESIDUAL_SCHEMA: &str = "necoherence.semantic-residual.v1";

const RECORD_FIELDS: [&str; 4] = ["schema", "basis", "input", "residuals"];
const INPUT_FIELDS: [&str; 2] = ["type_ref", "value"];

#[derive(Debug, Clone, PartialEq)]
pub struct SemanticResidualRecord {
    basis: SignatureGenerationBasis,
    input: SemanticValueInput,
    residuals: ResidualSet<SemanticObligation>,
}

impl SemanticResidualRecord {
    pub fn new(
        basis: SignatureGenerationBasis,
        input: SemanticValueInput,
        residuals: ResidualSet<SemanticObligation>,
    ) -> Self {
        Self {
            basis,
            input,
            residuals,
        }
    }
    pub fn basis(&self) -> &SignatureGenerationBasis {
        &self.basis
    }
    pub fn input(&self) -> &SemanticValueInput {
        &self.input
    }
    pub fn residuals(&self) -> &ResidualSet<SemanticObligation> {
        &self.residuals
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SemanticResidualFailure {
    Encoding(EncodingFailure),
    Wire(GenerationFailure),
    MissingField(&'static str),
    UnknownField(String),
    UnsupportedSchema(String),
    ResidualsNotNormalized,
    BasisMismatch {
        recorded: SignatureGenerationBasis,
        admitted: SignatureGenerationBasis,
    },
    ResidualMismatch {
        recorded: Vec<SemanticObligation>,
        evaluated: Vec<SemanticObligation>,
    },
}

impl From<EncodingFailure> for SemanticResidualFailure {
    fn from(failure: EncodingFailure) -> Self {
        Self::Encoding(failure)
    }
}

impl From<GenerationFailure> for SemanticResidualFailure {
    fn from(failure: GenerationFailure) -> Self {
        Self::Wire(failure)
    }
}

fn to_neco(value: serde_json::Value) -> Neco {
    match value {
        serde_json::Value::Null => Neco::Null,
        serde_json::Value::Bool(flag) => Neco::Bool(flag),
        serde_json::Value::Number(number) => Neco::Number(number.as_f64().unwrap_or(f64::NAN)),
        serde_json::Value::String(text) => Neco::String(text),
        serde_json::Value::Array(items) => Neco::Array(items.into_iter().map(to_neco).collect()),
        serde_json::Value::Object(members) => Neco::Object(
            members
                .into_iter()
                .map(|(key, child)| (key, to_neco(child)))
                .collect(),
        ),
    }
}

fn wire_to_neco(text: &str) -> Result<Neco, SemanticResidualFailure> {
    serde_json::from_str::<serde_json::Value>(text)
        .map(to_neco)
        .map_err(|failure| {
            SemanticResidualFailure::Wire(GenerationFailure::Encoding(failure.to_string()))
        })
}

fn neco_to_text(value: &Neco) -> Result<String, SemanticResidualFailure> {
    let bytes = canonical_bytes(value)?;
    String::from_utf8(bytes).map_err(|failure| {
        SemanticResidualFailure::Wire(GenerationFailure::Encoding(failure.to_string()))
    })
}

pub fn encode_semantic_residual(
    basis: &SignatureGenerationBasis,
    type_ref: &TypeRef,
    value: &crate::semantic_types::JsonValue,
    obligations: &[SemanticObligation],
) -> Result<Vec<u8>, SemanticResidualFailure> {
    let basis_wire = wire_to_neco(&encode_signature_basis(basis)?)?;
    let type_ref_wire = wire_to_neco(&encode(type_ref)?)?;
    let value_wire = wire_to_neco(&encode_exact_value(value)?)?;
    let obligations_wire = match wire_to_neco(&encode_semantic_obligations(obligations)?)? {
        Neco::Array(items) => items,
        other => vec![other],
    };
    let residuals = normalize_residuals(obligations_wire)?;
    let record = Neco::Object(vec![
        (
            "schema".into(),
            Neco::String(SEMANTIC_RESIDUAL_SCHEMA.into()),
        ),
        ("basis".into(), basis_wire),
        (
            "input".into(),
            Neco::Object(vec![
                ("type_ref".into(), type_ref_wire),
                ("value".into(), value_wire),
            ]),
        ),
        ("residuals".into(), Neco::Array(residuals)),
    ]);
    Ok(canonical_bytes(&record)?)
}

fn take_fields<'a>(
    fields: &'a [(String, Neco)],
    expected: &[&'static str],
) -> Result<Vec<&'a Neco>, SemanticResidualFailure> {
    let mut found = Vec::new();
    for name in expected {
        match fields.iter().find(|(key, _)| key == name) {
            Some((_, child)) => found.push(child),
            None => return Err(SemanticResidualFailure::MissingField(name)),
        }
    }
    if let Some((key, _)) = fields
        .iter()
        .find(|(key, _)| !expected.contains(&key.as_str()))
    {
        return Err(SemanticResidualFailure::UnknownField(key.clone()));
    }
    Ok(found)
}

fn shape(path: &str) -> SemanticResidualFailure {
    SemanticResidualFailure::Wire(syntax(path, "unexpected shape"))
}

pub fn decode_semantic_residual(
    bytes: &[u8],
) -> Result<SemanticResidualRecord, SemanticResidualFailure> {
    let Neco::Object(fields) = decode_canonical(bytes)? else {
        return Err(shape("$"));
    };
    let parts = take_fields(&fields, &RECORD_FIELDS)?;
    let [schema, basis, input, residuals] = parts.as_slice() else {
        return Err(shape("$"));
    };
    match schema {
        Neco::String(text) if text == SEMANTIC_RESIDUAL_SCHEMA => {}
        Neco::String(text) => return Err(SemanticResidualFailure::UnsupportedSchema(text.clone())),
        other => {
            return Err(SemanticResidualFailure::UnsupportedSchema(format!(
                "{other:?}"
            )))
        }
    }
    let Neco::Object(input_fields) = input else {
        return Err(shape("$.input"));
    };
    let input_parts = take_fields(input_fields, &INPUT_FIELDS)?;
    let [type_ref, value] = input_parts.as_slice() else {
        return Err(shape("$.input"));
    };
    let Neco::Array(items) = residuals else {
        return Err(shape("$.residuals"));
    };
    if normalize_residuals(items.clone())? != *items {
        return Err(SemanticResidualFailure::ResidualsNotNormalized);
    }
    let basis = decode_signature_basis(&neco_to_text(basis)?)?;
    let type_ref = decode_type_reference(&neco_to_text(type_ref)?)?;
    let value = decode_exact_value(&neco_to_text(value)?)?;
    let obligations = decode_semantic_obligations(&neco_to_text(residuals)?)?;
    Ok(SemanticResidualRecord {
        basis,
        input: SemanticValueInput { type_ref, value },
        residuals: ResidualSet::new(obligations),
    })
}

pub fn open_semantic_residual(
    checked: &CheckedSignatureGeneration,
    record: &SemanticResidualRecord,
    graph_revision: String,
) -> Result<SignatureEvaluation, SemanticResidualFailure> {
    if record.basis != checked.input().basis {
        return Err(SemanticResidualFailure::BasisMismatch {
            recorded: record.basis.clone(),
            admitted: checked.input().basis.clone(),
        });
    }
    let evaluation = open_signature_evaluation(checked, record.input.clone(), graph_revision);
    let evaluated = match evaluation.outcome() {
        Ok(RefinementOutcome::Resolved(_)) => ResidualSet::new([]),
        Ok(RefinementOutcome::Residual { residuals, .. })
        | Ok(RefinementOutcome::Stopped { residuals, .. }) => residuals.clone(),
        Err(failure) => failure.residuals.clone(),
    };
    if evaluated != record.residuals {
        return Err(SemanticResidualFailure::ResidualMismatch {
            recorded: record.residuals.iter().cloned().collect(),
            evaluated: evaluated.iter().cloned().collect(),
        });
    }
    Ok(evaluation)
}
