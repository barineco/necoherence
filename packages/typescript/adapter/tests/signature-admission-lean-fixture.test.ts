// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";

type AdmissionRequest = { readonly exchange: string; readonly expected_basis: Parameters<typeof S.admitSignatureGeneration>[0] };

const rejectedClosure = JSON.parse(readFileSync(new URL("../../../../verification/declaration/signature_admission/examples/rejected-closure-used-site.request.json", import.meta.url), "utf8")) as AdmissionRequest;

it("admits a closure that uses a site again, because the runtime admission decodes only the plan", () => {
  const admitted = S.admitSignatureGeneration(rejectedClosure.expected_basis, rejectedClosure.exchange);
  expect(admitted.tag).toBe("Admitted");
});
