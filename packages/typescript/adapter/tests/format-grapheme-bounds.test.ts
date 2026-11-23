// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { profile, source, stringSpec } from "./semantic-fixture.js";

const graphemes: V.StringLengthUnit = { tag: "Graphemes" };
const text: V.FormatRule = { tag: "Text" };
const bounded = (unit: V.StringLengthUnit, maximum: string, rule: V.FormatRule): V.FormatRule => ({ tag: "Bounded", fields: { unit, maximum, rule } });
const rules = profile.grapheme_rules! as V.GraphemeRules;
const typeRef = (name: string): V.TypeRef => ({ source, definition_name: name, pointer: [] });
const node = (shape: V.TypeShape): V.TypeNode => ({ reference: typeRef("subject"), shape, description: null, attributes: [], extensions: [] });

it("rejects a grapheme bound when the profile has no grapheme rules", () => {
  expect(V.recognizeFormat(bounded(graphemes, "1", text), "a", null)).toBe(false);
});

it("counts a grapheme bound by the profile grapheme rules rather than by codepoints", () => {
  expect(V.recognizeFormat(bounded(graphemes, "1", text), "a\u0301", rules)).toBe(true);
  expect(V.recognizeFormat(bounded(graphemes, "1", text), "a\u0301b", rules)).toBe(false);
});
