// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import { library } from "./semantic-fixture.js";

it("reports no library check failure for the valid library", () => {
  expect(S.libraryCheckFailure(library())).toBeNull();
});

it("reports the declaration predicate of a library whose node identity is duplicated", () => {
  const valid = library();
  const duplicated = { ...valid, nodes: [...valid.nodes, valid.nodes[0]!] };
  expect(S.libraryCheckFailure(duplicated)).toEqual({
    tag: "Library",
    value: { reference: valid.identity, predicate: "LB01", location: ["library"] },
  });
});

it("reports the profile predicate of a library whose profile declares no valid default integer domain", () => {
  const valid = library();
  const profile = { ...valid.profile, default_integer_domain: "missing" };
  const failure = S.libraryCheckFailure({ ...valid, profile });
  expect(failure?.tag).toBe("Profile");
  expect(failure?.value).toMatchObject({ predicate: expect.stringMatching(/^PR\d\d$/), location: expect.any(Array) });
});
