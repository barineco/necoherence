# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from necoherence.signature_values import variant, wrapper_text_accepts


def _profile(*wrappers):
    return {"wrappers": list(wrappers)}


def _text(name, key):
    return {"name": name, "key": key, "payload": variant("Text", None)}


def _bytes(name, key):
    return {"name": name, "key": key, "payload": variant("Bytes")}


def test_text_wrapper_accepts_a_value_with_its_key_and_text() -> None:
    assert wrapper_text_accepts(_profile(_text("w", "text")), {"text": "ok"}) is True


def test_text_wrapper_rejects_a_value_with_extra_members_or_a_non_text_payload() -> None:
    profile = _profile(_text("w", "text"))
    assert wrapper_text_accepts(profile, {"text": "ok", "extra": 1}) is False
    assert wrapper_text_accepts(profile, {"text": 1}) is False


def test_text_wrapper_is_the_first_wrapper_with_a_text_payload() -> None:
    profile = _profile(_bytes("b", "bytes"), _text("w", "text"))
    assert wrapper_text_accepts(profile, {"text": "ok"}) is True
    assert wrapper_text_accepts(profile, {"bytes": "AA=="}) is False


def test_first_text_wrapper_decides_acceptance_over_a_later_text_wrapper() -> None:
    profile = _profile(_text("first", "text"), _text("second", "other"))
    assert wrapper_text_accepts(profile, {"text": "ok"}) is True
    assert wrapper_text_accepts(profile, {"other": "ok"}) is False


def test_profile_without_a_text_wrapper_accepts_no_value() -> None:
    assert wrapper_text_accepts(_profile(_bytes("b", "bytes")), {"bytes": "AA=="}) is False
    assert wrapper_text_accepts(_profile(), {"text": "ok"}) is False
