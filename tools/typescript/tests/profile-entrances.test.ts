// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { expect, it } from "vitest";
import { semanticSignatures as S } from "necoherence";
import { renderSignatureGenerationInput, renderSignatureSurface } from "../src/index.js";
import { generation } from "./semantic-fixture.js";

it("stops the renderer and code generator at PR01 before producing source", () => {
  const input = generation();
  const invalidProfile = { ...input.signatures.profile, grapheme_rules: null, reference: { ...input.signatures.profile.reference, identity: "" } };
  const invalidLibrary = { ...input.signatures, profile: invalidProfile };
  expect(() => S.checkLibrary(invalidLibrary)).toThrowError(S.PredicateFailure);
  try {
    S.checkLibrary(invalidLibrary);
  } catch (error) {
    expect((error as S.PredicateFailure).predicate).toBe("PR01");
  }
  expect(() => renderSignatureSurface({ checked: {} as S.CheckedSignatureLibrary, basis: input.basis }, "necoherence")).toThrow(/checked library authority/);
  const invalidInput = { ...input, signatures: { ...input.signatures, profile: invalidProfile } };
  expect(() => renderSignatureGenerationInput(input.basis, JSON.stringify(invalidInput))).toThrowError(S.PredicateFailure);
  try {
    renderSignatureGenerationInput(input.basis, JSON.stringify(invalidInput));
  } catch (error) {
    expect((error as S.PredicateFailure).predicate).toBe("PR01");
  }
});
