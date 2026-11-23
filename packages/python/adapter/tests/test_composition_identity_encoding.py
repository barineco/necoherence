# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from necoherence.semantic_identity import encode_tuple


def test_encode_tuple_prefixes_each_part_with_its_utf8_byte_length() -> None:
    assert encode_tuple(()) == ""
    assert encode_tuple(("type", "日本")) == "4:type6:日本"
    assert encode_tuple(("😀",)) == "4:😀"
