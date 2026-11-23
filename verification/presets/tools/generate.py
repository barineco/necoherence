# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
PROFILE_PATH = ROOT / "atproto-data-model" / "profile.json"
MANIFEST_PATH = ROOT / "manifest.json"
PROFILE_IDENTITY = "atproto-data-model"
PROFILE_REVISION = "1"

sys.dont_write_bytecode = True
sys.path.insert(0, str(TOOLS / "unicode"))
from materialize_unicode import materialize  # noqa: E402


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def tagged(tag: str, value: object | None = None, *, fields: dict | None = None) -> dict:
    if fields is not None:
        return {"tag": tag, "fields": fields}
    return {"tag": tag} if value is None else {"tag": tag, "value": value}


def identifier(alphabet: str, length: int) -> dict:
    return tagged("Identifier", fields={
        "first_alphabet": alphabet,
        "rest_alphabet": alphabet,
        "exact_length": str(length),
        "min_length": str(length),
        "max_length": str(length),
        "forbidden": [],
    })


def sequence(*rules: dict) -> dict:
    return tagged("Sequence", list(rules))


def choice(*rules: dict) -> dict:
    return tagged("Choice", list(rules))


def literal(value: str) -> dict:
    return tagged("Literal", value)


def negate(rule: dict) -> dict:
    return tagged("Not", rule)


def cid_rule(prefix: str) -> dict:
    return sequence(
        literal(prefix),
        identifier("abcdefgh", 1),
        identifier("abcdefghijklmnopqrstuvwxyz234567", 50),
        identifier("aeimquy4", 1),
    )


def format_rules() -> list[dict]:
    public = json.loads((TOOLS / "public-format-rules.json").read_text(encoding="utf-8"))
    by_name = {binding["name"]: binding["rule"] for binding in public}
    cid_raw = cid_rule("bafkrei")
    cid_dagcbor = cid_rule("bafyrei")
    text = tagged("Text")
    non_empty = negate(literal(""))
    tag_not_main = negate(choice(literal(""), sequence(text, literal("#"), literal("main"))))
    definition_name = negate(choice(
        literal(""),
        literal("main"),
        sequence(text, literal("#"), text),
    ))
    union_tag = choice(by_name["nsid"], sequence(by_name["nsid"], literal("#"), definition_name))
    conjunction = lambda left, right: negate(choice(negate(left), negate(right)))
    by_name["cid"] = choice(cid_raw, cid_dagcbor)
    by_name.update({
        "cid-raw": cid_raw,
        "cid-dagcbor": cid_dagcbor,
        "union-tag": union_tag,
        "tag-not-main": tag_not_main,
        "non-empty": non_empty,
        "key:tid": conjunction(by_name["record-key"], by_name["tid"]),
        "key:nsid": conjunction(by_name["record-key"], by_name["nsid"]),
    })
    order = [binding["name"] for binding in public]
    order.insert(order.index("datetime"), "cid")
    order.extend(["cid-raw", "cid-dagcbor", "union-tag", "tag-not-main", "non-empty", "key:tid", "key:nsid"])
    return [{"name": name, "rule": by_name[name]} for name in order]


def source_refs(unicode_data: dict) -> tuple[list[dict], dict[str, dict]]:
    atproto = json.loads((TOOLS / "atproto-sources.json").read_text(encoding="utf-8"))
    refs = [{
        "repository": atproto["repository"],
        "revision": atproto["revision"],
        "path": row["path"],
        "content_digest": row["content_digest"],
    } for row in atproto["sources"]]
    unicode_refs = [{
        "repository": "unicode-org/unicodetools",
        "revision": unicode_data["unicode"]["version"],
        "path": row["path"],
        "content_digest": row["sha256"],
    } for row in unicode_data["sources"]]
    uax = unicode_data["unicode"]["uax29_source"]
    unicode_refs.append({
        "repository": uax["repository"],
        "revision": uax["revision"],
        "path": uax["path"],
        "content_digest": uax["sha256"],
    })
    all_refs = refs + unicode_refs
    return all_refs, {row["path"]: row for row in unicode_refs}


def grapheme_rules(reference: dict, unicode_data: dict, unicode_by_path: dict[str, dict]) -> dict:
    role_paths = [
        ("grapheme_break_property", "GraphemeBreakProperty.txt"),
        ("emoji_data", "emoji-data.txt"),
        ("derived_core_properties", "DerivedCoreProperties.txt"),
        ("grapheme_break_test", "GraphemeBreakTest.txt"),
        ("license", "LICENSE.txt"),
        ("uax29", "reports/tr29/tr29-45.html"),
    ]
    property_tags = {
        "CR": "Cr", "LF": "Lf", "ZWJ": "Zwj", "Regional_Indicator": "RegionalIndicator",
        "LV": "Lv", "LVT": "Lvt",
    }
    properties = [{
        "first": str(first), "last": str(last),
        "property": tagged(property_tags.get(prop, prop)),
    } for first, last, prop in unicode_data["table"]["properties"]]
    indic = [{
        "first": str(first), "last": str(last), "property": tagged(prop),
    } for first, last, prop in unicode_data["table"]["indic_conjunct"]]
    pictographic = [{"first": str(first), "last": str(last)}
                    for first, last in unicode_data["table"]["extended_pictographic"]]
    return {
        "reference": reference,
        "component": {
            "unicode_version": "16.0.0",
            "uax29_revision": "45",
            "cluster_profile": "C1-1-default-extended-grapheme-cluster-no-tailoring",
        },
        "table_sha256": unicode_data["table_sha256"],
        "sources": [{
            "role": role,
            "origin": {"source": unicode_by_path[path], "locator": []},
        } for role, path in role_paths],
        "properties": properties,
        "extended_pictographic": pictographic,
        "indic_conjunct": indic,
    }


def string_spec(*, named_format: str | None = None, wrapper: str | None = None,
                minimum_utf8: int | None = None) -> dict:
    lengths = [] if minimum_utf8 is None else [{
        "unit": tagged("Utf8Bytes"), "minimum": str(minimum_utf8), "maximum": None,
    }]
    return {
        "format": None if named_format is None else tagged("Named", named_format),
        "lengths": lengths,
        "wrapper": wrapper,
        "const_value": None,
        "enum_values": None,
        "examples": [],
        "default_value": None,
    }


def integer_spec(*, minimum: int | None = None) -> dict:
    return {
        "domain": None,
        "minimum": None if minimum is None else str(minimum),
        "maximum": None,
        "const_value": None,
        "enum_values": None,
        "default_value": None,
    }


def blank_profile_reference_digests(value: object, identity: str, revision: str) -> object:
    result = copy.deepcopy(value)

    def visit(node: object) -> None:
        if isinstance(node, dict):
            if node.get("identity") == identity and node.get("revision") == revision and "content_digest" in node:
                node["content_digest"] = ""
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(result)
    return result


def profile_reference_digest(profile: dict) -> str:
    reference = profile["reference"]
    blanked = blank_profile_reference_digests(profile, reference["identity"], reference["revision"])
    return sha256(canonical_bytes(blanked))


def profile_document_digest(profile_bytes: bytes) -> str:
    return sha256(profile_bytes)


def build_profile() -> dict:
    unicode_data = materialize(TOOLS / "unicode", TOOLS / "unicode" / "source-manifest.json")
    sources, unicode_by_path = source_refs(unicode_data)
    reference = {"identity": PROFILE_IDENTITY, "revision": PROFILE_REVISION, "content_digest": ""}
    bindings = [{"name": row["name"], "reference": reference, "rule": row["rule"]}
                for row in format_rules()]
    profile = {
        "reference": reference,
        "source_refs": sources,
        "integer_domains": [{
            "name": "int64",
            "reference": reference,
            "range": tagged("Inclusive", fields={
                "minimum": str(-(2**63)), "maximum": str(2**63 - 1),
            }),
            "forms": [tagged("Number"), tagged("IntegralDecimal")],
        }],
        "default_integer_domain": "int64",
        "numbers": {"decimals": False},
        "grapheme_rules": grapheme_rules(reference, unicode_data, unicode_by_path),
        "format_bindings": bindings,
        "bytes_policy": {
            "reference": reference,
            "padding_optional": True,
            "alphabet": tagged("Standard"),
            "strict_pad_bits": False,
            "wrapper": "binary",
        },
        "wrappers": [
            {"name": "binary", "key": "$bytes", "payload": tagged("Bytes")},
            {"name": "reference", "key": "$link", "payload": tagged("Text", "cid")},
        ],
        "tag": {
            "key": "$type",
            "format": "tag-not-main",
            "sealed": [{
                "tag": "blob",
                "fields": [
                    {"key": "ref", "required": True,
                     "leaf": tagged("String", string_spec(named_format="cid-raw", wrapper="reference"))},
                    {"key": "mimeType", "required": True,
                     "leaf": tagged("String", string_spec(minimum_utf8=1))},
                    {"key": "size", "required": True,
                     "leaf": tagged("Integer", integer_spec(minimum=1))},
                ],
                "extras": tagged("Any"),
            }],
        },
    }
    digest = profile_reference_digest(profile)
    reference["content_digest"] = digest
    return profile


def build_outputs() -> tuple[bytes, bytes]:
    profile = build_profile()
    profile_bytes = canonical_bytes(profile)
    manifest = {
        "schema": "necoherence-presets@1",
        "presets": [{
            "identity": profile["reference"]["identity"],
            "revision": profile["reference"]["revision"],
            "path": "atproto-data-model/profile.json",
            "profile_ref_content_digest": profile["reference"]["content_digest"],
            "content_digest": profile_document_digest(profile_bytes),
            "source_refs": profile["source_refs"],
        }],
    }
    return profile_bytes, canonical_bytes(manifest)


def check_outputs(profile_bytes: bytes, manifest_bytes: bytes) -> None:
    if PROFILE_PATH.read_bytes() != profile_bytes:
        raise SystemExit(f"generated bytes differ: {PROFILE_PATH}")
    if MANIFEST_PATH.read_bytes() != manifest_bytes:
        raise SystemExit(f"generated bytes differ: {MANIFEST_PATH}")
    profile = json.loads(profile_bytes)
    manifest = json.loads(manifest_bytes)
    expected_ref = profile_reference_digest(profile)
    actual_ref = profile["reference"]["content_digest"]
    if actual_ref != expected_ref:
        raise SystemExit("profile reference digest differs")
    expected_document = profile_document_digest(profile_bytes)
    actual_document = manifest["presets"][0]["content_digest"]
    if actual_document != expected_document:
        raise SystemExit("manifest profile digest differs")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    profile_bytes, manifest_bytes = build_outputs()
    if args.check:
        check_outputs(profile_bytes, manifest_bytes)
        return
    PROFILE_PATH.parent.mkdir(parents=True, exist_ok=True)
    PROFILE_PATH.write_bytes(profile_bytes)
    MANIFEST_PATH.write_bytes(manifest_bytes)


if __name__ == "__main__":
    main()
