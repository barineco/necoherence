# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import copy
import json

import pytest

from necoherence.signature_values import WireFailure
from necoherence.type_signatures import AdmissionFailure, DeclarationFailure, checkProfile, decode_profile_artifact
from v4_samples import profile


def test_wrapper_names_and_keys_are_unique():
    value = profile(); value["wrappers"][1]["key"] = value["wrappers"][0]["key"]
    with pytest.raises(DeclarationFailure) as caught: checkProfile(value)
    assert caught.value.predicate == "PR08"


def test_bytes_wrapper_must_name_a_bytes_wrapper():
    value = profile(); value["bytes_policy"]["wrapper"] = "text"
    with pytest.raises(DeclarationFailure) as caught: checkProfile(value)
    assert caught.value.predicate == "PR10"


def test_profile_artifact_matches_trusted_bytes_reference_and_sources():
    value = profile()
    wire = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    assert decode_profile_artifact(value["reference"], [], wire, wire) == value
    wire_bytes = wire.encode()
    assert decode_profile_artifact(value["reference"], [], wire_bytes, wire_bytes) == value

    with pytest.raises(AdmissionFailure) as caught:
        decode_profile_artifact(value["reference"], [], wire, wire + " ")
    assert caught.value.kind == "DigestMismatch"

    changed_reference = copy.deepcopy(value["reference"])
    changed_reference["revision"] = "other"
    with pytest.raises(AdmissionFailure) as caught:
        decode_profile_artifact(changed_reference, [], wire, wire)
    assert caught.value.kind == "BasisMismatch"

    with pytest.raises(AdmissionFailure) as caught:
        decode_profile_artifact(value["reference"], [{
            "repository": "repo", "revision": "rev", "path": "profile.json",
            "content_digest": "b" * 64,
        }], wire, wire)
    assert caught.value.kind == "BasisMismatch"


def test_profile_artifact_rejects_legacy_keys_as_wire_failures():
    value = profile()
    value["representation"] = {}
    wire = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    with pytest.raises(WireFailure) as caught:
        decode_profile_artifact(value["reference"], [], wire, wire)
    assert caught.value.kind == "UnknownField"
