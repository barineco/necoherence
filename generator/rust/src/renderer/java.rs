// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

mod composition;
mod emitter;
mod providers;
mod text;

use super::{check_meaning, RenderFailure};
use emitter::{Emitter, Model};
use necoherence::semantic_exchange::{encode_type_signatures, Wire};
use necoherence::signature_admission::CheckedSignatureGeneration;
use serde::Serialize;
use serde_json::Value;
use text::{field, list, tag, text as text_of};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JavaTarget {
    pub package_name: String,
    pub class_name: String,
}

pub(super) fn validate(target: &JavaTarget) -> Result<(), RenderFailure> {
    if text::valid_target(&target.package_name, &target.class_name) {
        Ok(())
    } else {
        Err(RenderFailure::InvalidJavaTarget)
    }
}

fn parse(text: &str) -> Result<Value, RenderFailure> {
    serde_json::from_str(text).map_err(|_| text::emission("generated JSON"))
}

fn encoded<T: Serialize>(value: T) -> Result<Value, RenderFailure> {
    serde_json::to_value(value).map_err(|_| text::emission("generated wire value"))
}

pub(super) fn render(
    checked: &CheckedSignatureGeneration,
    expected: &necoherence::type_signatures::ExpectedSignatureBasis,
    exchange_text: &str,
    target: &JavaTarget,
) -> Result<String, RenderFailure> {
    validate(target)?;
    let input = checked.input();
    if checked.composition().is_none() {
        check_meaning(checked.graph())?;
    }
    let library = parse(
        &encode_type_signatures(&input.signatures)
            .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?,
    )?;
    let basis = parse(
        &necoherence::semantic_exchange::encode_expected_signature_basis(expected)
            .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?,
    )?;
    for node in list(&library, "nodes")? {
        if tag(field(node, "shape")?)? == "Opaque" {
            return Err(RenderFailure::UndefinedType(
                text_of(node, "id")?.to_owned(),
            ));
        }
    }
    let graph = encoded(Wire(checked.graph()))?;
    let exchange = parse(exchange_text)?;
    let composition = exchange
        .get("composition")
        .filter(|value| !value.is_null())
        .map(|value| -> Result<Value, RenderFailure> { Ok(field(value, "problem")?.clone()) })
        .transpose()?;
    let mut entrypoints = Vec::new();
    for entry in list(&exchange, "entrypoints")? {
        entrypoints.push(text_of(entry, "definition")?.to_owned());
    }
    let model = Model {
        graph,
        library,
        entrypoints,
        composition,
        generation_document: exchange_text.to_owned(),
        generation_basis: basis.to_string(),
    };
    Emitter::new(model, &target.package_name, &target.class_name)?.emit()
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod tests {
    use super::JavaTarget;
    use crate::renderer::{render_signature_exchange_for, Target};

    const BYTES_EXCHANGE: &str = r#"{"schema":"ncoh-checked-generation@5","basis":{"signature_schema":"ncoh-type-signatures@1","library_identity":"generated.signatures","library_revision":"1","profile":{"identity":"ncoh-value-semantics","revision":"1","content_digest":"0000000000000000000000000000000000000000000000000000000000000000"},"graph_sha256":"4dc277f7214cc20ab34bb868a3b5f964ab706cf4d57eba8d7e302f2632535ff9","provenance_sha256":"b0451fdaa8db0f78d20fa9b1b47849534694d4a8a91f95bf2316b2c7c865df9d","metadata_sha256":"388eab25dacb83c11f5de42de596a8a33f13b5615e91f64e31e92696a9ce642d","problem_sha256":null,"observations_sha256":null,"entrypoints_sha256":"df7e24abefb9c2bbbcc1c63047542db0e246c973e68300f9a6be43a06b91677b"},"signatures":{"schema":"ncoh-type-signatures@1","identity":"generated.signatures","revision":"1","profile":{"reference":{"identity":"ncoh-value-semantics","revision":"1","content_digest":"0000000000000000000000000000000000000000000000000000000000000000"},"source_refs":[],"integer_domains":[{"name":"integer","reference":{"identity":"ncoh-value-semantics","revision":"1","content_digest":"0000000000000000000000000000000000000000000000000000000000000000"},"range":{"tag":"Inclusive","fields":{"minimum":"-10","maximum":"10"}},"forms":[{"tag":"Number"},{"tag":"DecimalString"}]}],"default_integer_domain":"integer","numbers":{"decimals":true},"grapheme_rules":null,"format_bindings":[],"bytes_policy":{"reference":{"identity":"ncoh-value-semantics","revision":"1","content_digest":"0000000000000000000000000000000000000000000000000000000000000000"},"padding_optional":true,"alphabet":{"tag":"Standard"},"strict_pad_bits":true,"wrapper":null},"wrappers":[],"tag":null},"sources":[{"repository":"adapter","revision":"1","path":"contract","content_digest":"0000000000000000000000000000000000000000000000000000000000000000"}],"provenance":[],"groups":[{"id":"document","members":["value","third"]}],"annotations":[],"nodes":[{"id":"blob","shape":{"tag":"Bytes","value":{"minimum":null,"maximum":null}}},{"id":"pack","shape":{"tag":"Array","value":{"item":{"type_id":"blob","nullable":false},"min_length":null,"max_length":null}}}],"definitions":[{"id":"value","wire_identity":"Example","shape":{"tag":"Value","value":"blob"}},{"id":"third","wire_identity":"Example3","shape":{"tag":"Value","value":"pack"}}]},"composition":null,"entrypoints":[{"identity":"example","definition":"value"},{"identity":"third","definition":"third"}]}"#;

    fn rendered() -> String {
        let input = necoherence::semantic_exchange::decode_signature_generation(BYTES_EXCHANGE)
            .expect("the exchange decodes");
        let expected = necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input);
        let target = Target::Java(JavaTarget {
            package_name: String::new(),
            class_name: "GeneratedBytes".to_owned(),
        });
        render_signature_exchange_for(&target, &expected, BYTES_EXCHANGE)
            .expect("the exchange renders")
    }

    #[test]
    fn a_bytes_leaf_is_read_from_a_value_that_was_validated_once() {
        let text = rendered();
        assert!(!text.contains("decodeBytes"));
        let reads: Vec<&str> = text
            .lines()
            .filter(|line| line.contains("CONTEXT.bytes("))
            .collect();
        assert!(reads.len() >= 2, "{reads:?}");
        for line in &reads {
            assert!(line.contains("CONTEXT.bytes(checked,"), "{line}");
            assert!(!line.contains(".validate("), "{line}");
        }
        for line in text.lines().filter(|line| line.contains(" fromWire(")) {
            assert!(line.contains("CONTEXT.check("), "{line}");
            assert!(!line.contains(".validate("), "{line}");
        }
    }
}
