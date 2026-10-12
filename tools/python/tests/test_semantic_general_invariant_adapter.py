# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from necoherence.signature_values import recognize_format, variant


def test_optional_prefix_sequence_accepts_empty_left():
    rule=variant("Sequence",[variant("Optional",variant("Literal","a")),variant("Literal","b")])
    assert recognize_format(rule,"b")
    assert recognize_format(rule,"ab")
