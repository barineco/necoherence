// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures

fn canonical(text: String) -> String {
  let assert Ok(value) = values.parse_wire(text)
  let assert Ok(canonical) = signatures.canonical(value)
  canonical
}

pub fn control_characters_are_escaped_as_lowercase_four_digit_units_test() {
  let assert "{\"a\":\"\\u0008\\u000c\\u001b\\\"\\\\\\n\\r\",\"b\":\"x\\u0009y\"}" =
    canonical("{\"b\":\"x\\ty\",\"a\":\"\\b\\f\\u001B\\\"\\\\\\n\\r\"}")
  let assert "{\"k\\u0009ey\":\"\\u0000\\u001f\u{7f}\u{e9}\"}" =
    canonical("{\"k\\tey\":\"\\u0000\\u001F\\u007f\\u00e9\"}")
}

pub fn numbers_are_printed_in_the_lean_compress_form_test() {
  let assert "[1.5,100,1,1,0,0,0.0000000001e-10]" =
    canonical("[1.50,1e2,1.0,10e-1,0.0,-0.0,1e-20]")
  let assert "[-1,-2.5,0.5,15,1,1.1,12]" =
    canonical("[-1.0,-2.50,0.5,1.5e1,100e-2,1.10,12.000]")
  let assert "[0.0001,123456789.0125,0.0125,0.5]" =
    canonical("[0.0001,123456789012.5e-3,1.25e-2,5e-1]")
}
