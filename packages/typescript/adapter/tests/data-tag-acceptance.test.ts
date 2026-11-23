// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { library } from "./semantic-fixture.js";
import { acceptedValue, valueFailure } from "./validation-support.js";

const object = (members: readonly { readonly key: string; readonly value: V.ExactJson }[]): V.ExactJson => ({ tag: "Object", members });

it("accepts a declared internal data tag and selects its branch", () => {
  const checked = S.checkLibrary(library());
  const value = object([{ key: "kind", value: { tag: "String", value: "sealed" } }, { key: "name", value: { tag: "String", value: "x" } }]);
  const union = checked.refs.get("union")!;
  expect(V.selectBranch(checked.context, union, value)?.wire_tag).toBe("sealed");
  expect(acceptedValue(checked.context, union, value)).toEqual(value);
});

it("classifies invalid effective tags at the tag member", () => {
  const checked = S.checkLibrary(library()), sealed = checked.refs.get("sealed")!;
  const cases: readonly (readonly [V.ExactJson, V.ValueCondition])[] = [
    [{ tag: "Integer", value: "7" }, { tag: "InvalidTag" }],
    [{ tag: "String", value: "invalid tag" }, { tag: "InvalidTag" }],
    [{ tag: "String", value: "\ud800" }, { tag: "InvalidDataModel" }],
  ];
  for (const [tag, condition] of cases) {
    expect(valueFailure(checked.context, sealed, object([{ key: "kind", value: tag }]))).toMatchObject({ condition, path: ["kind"] });
  }
});

it("enforces sealed required fields and rejects extras", () => {
  const checked = S.checkLibrary(library()), sealed = checked.refs.get("sealed")!;
  expect(valueFailure(checked.context, sealed, object([{ key: "kind", value: { tag: "String", value: "sealed" } }]))).toMatchObject({ condition: { tag: "MissingRequired" } });
  const extra = object([{ key: "kind", value: { tag: "String", value: "sealed" } }, { key: "name", value: { tag: "String", value: "x" } }, { key: "extra", value: { tag: "Bool", value: true } }]);
  expect(valueFailure(checked.context, sealed, extra)).toMatchObject({ condition: { tag: "UnexpectedField", value: "extra" }, path: ["extra"] });
});
