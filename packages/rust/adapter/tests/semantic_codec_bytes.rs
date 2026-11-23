// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]

use necoherence::exact_json::JsonValue;
use necoherence::semantic_codegen_runtime::{bytes_decode, bytes_encode, Bytes};
use necoherence::semantic_types::{
    BytesAlphabet, BytesPolicy, ProfileRef, VersionedSemanticProfile, Wrapper, WrapperPayload,
};
use necoherence::signature_admission::check_type_signatures;

#[path = "fixtures/semantic_execution_samples.rs"]
#[allow(dead_code, unused_imports)]
mod samples;

fn profile(
    alphabet: BytesAlphabet,
    padding_optional: bool,
    wrapper: Option<&str>,
) -> VersionedSemanticProfile {
    let graph = check_type_signatures(&samples::library()).unwrap();
    let mut profile = graph.profile.clone();
    profile.bytes_policy = Some(BytesPolicy {
        reference: ProfileRef {
            identity: "bytes".into(),
            revision: "1".into(),
            content_digest: "bytes".into(),
        },
        padding_optional,
        alphabet,
        strict_pad_bits: true,
        wrapper: wrapper.map(str::to_owned),
    });
    profile.wrappers = vec![Wrapper {
        name: "bytes".into(),
        key: "$bytes".into(),
        payload: WrapperPayload::Bytes,
    }];
    profile
}

fn wrapped(text: &str) -> JsonValue {
    JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str(text.into()))])
}

fn native(data: Vec<u8>) -> Bytes {
    Bytes { data, wire: None }
}

#[test]
fn encoding_without_wire_pads_under_optional_padding() {
    let standard = profile(BytesAlphabet::Standard, true, Some("bytes"));
    assert_eq!(
        bytes_encode(&standard, &native(vec![1, 2])).unwrap(),
        wrapped("AQI=")
    );
    assert_eq!(
        bytes_encode(&standard, &native(vec![1])).unwrap(),
        wrapped("AQ==")
    );
    assert_eq!(
        bytes_encode(&standard, &native(vec![1, 2, 3])).unwrap(),
        wrapped("AQID")
    );
    assert_eq!(
        bytes_encode(&standard, &native(vec![251, 255])).unwrap(),
        wrapped("+/8=")
    );
    let url_safe = profile(BytesAlphabet::UrlSafe, true, Some("bytes"));
    assert_eq!(
        bytes_encode(&url_safe, &native(vec![251, 255])).unwrap(),
        wrapped("-_8=")
    );
}

#[test]
fn native_bytes_encode_without_wire_spelling() {
    let standard = profile(BytesAlphabet::Standard, true, Some("bytes"));
    assert_eq!(
        bytes_encode(&standard, &native(vec![1, 2])).unwrap(),
        wrapped("AQI=")
    );
}

#[test]
fn decoded_wire_spelling_is_kept_while_it_matches_the_data() {
    let optional = profile(BytesAlphabet::Standard, true, Some("bytes"));
    for wire in ["AQI", "AQI="] {
        let decoded = bytes_decode(&optional, wrapped(wire)).unwrap();
        assert_eq!(
            decoded,
            Bytes {
                data: vec![1, 2],
                wire: Some(wire.into()),
            }
        );
        assert_eq!(bytes_encode(&optional, &decoded).unwrap(), wrapped(wire));
    }
}

#[test]
fn changed_data_replaces_the_wire_spelling() {
    let optional = profile(BytesAlphabet::Standard, true, Some("bytes"));
    let changed = Bytes {
        data: vec![255],
        wire: Some("AQI".into()),
    };
    assert_eq!(bytes_encode(&optional, &changed).unwrap(), wrapped("/w=="));
}

#[test]
fn wire_spelling_outside_the_policy_length_is_replaced_by_the_padded_form() {
    let padded = profile(BytesAlphabet::Standard, false, Some("bytes"));
    let unpadded = Bytes {
        data: vec![1, 2],
        wire: Some("AQI".into()),
    };
    assert_eq!(bytes_encode(&padded, &unpadded).unwrap(), wrapped("AQI="));
}

#[test]
fn unpadded_wire_is_rejected_without_optional_padding() {
    let padded = profile(BytesAlphabet::Standard, false, Some("bytes"));
    assert!(bytes_decode(&padded, wrapped("AQI")).is_err());
}

#[test]
fn missing_policy_encodes_with_the_default_policy() {
    let mut missing = profile(BytesAlphabet::Standard, true, None);
    missing.bytes_policy = None;
    assert_eq!(
        bytes_encode(&missing, &native(vec![1, 2])).unwrap(),
        JsonValue::Str("AQI=".into())
    );
    assert!(bytes_decode(&missing, JsonValue::Str("AQI=".into())).is_err());
}

#[test]
fn unknown_wrapper_encodes_the_plain_text() {
    let unknown = profile(BytesAlphabet::Standard, true, Some("missing"));
    assert_eq!(
        bytes_encode(&unknown, &native(vec![1, 2])).unwrap(),
        JsonValue::Str("AQI=".into())
    );
}
