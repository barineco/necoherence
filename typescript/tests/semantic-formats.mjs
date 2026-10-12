// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import assert from "node:assert/strict";
import { recognizeFormat } from "../dist/semantic_values.js";

const cases = [
  [{ tag: "Labels", fields: { separator: "::", min_count: "2", max_count: null, total_max: null, rule: { tag: "Literal", value: "a" } } }, "a::a", true],
  [{ tag: "Labels", fields: { separator: "::", min_count: "2", max_count: null, total_max: null, rule: { tag: "Literal", value: "a" } } }, "a:a", false],
  [{ tag: "Not", value: { tag: "Literal", value: "a" } }, "aa", true],
  [{ tag: "Sequence", value: [{ tag: "Literal", value: "a" }, { tag: "Optional", value: { tag: "Literal", value: "b" } }] }, "ab", true],
];
export function checkFormats() {
  for (const [rule, value, expected] of cases) assert.equal(recognizeFormat(rule, value), expected);
  return cases.length;
}

if (import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  process.stdout.write(JSON.stringify({ checked: checkFormats() }) + "\n");
}
