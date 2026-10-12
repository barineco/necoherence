// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { profile, reference, sourceIdentity } from "./semantic-fixture.js";

const artifact = JSON.stringify({ profile });

it("admits the caller-bound @4 profile artifact", () => {
  expect(V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], artifact, artifact)).toEqual(profile);
  expect(S.checkProfile(V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], artifact, artifact))).toEqual(profile);
});

it("binds profile identity, sources and trusted bytes", () => {
  expect(() => V.decodeCanonicalProfileArtifact({ ...reference, identity: "other" }, [sourceIdentity], artifact, artifact)).toThrow(/profile reference/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [{ ...sourceIdentity, revision: "other" }], artifact, artifact)).toThrow(/profile sources/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], artifact, `${artifact} `)).toThrow(/profile artifact bytes/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], JSON.stringify({ profile, extra: true }), JSON.stringify({ profile, extra: true }))).toThrow(/profile artifact fields/);
});

it("rejects obsolete profile keys with a typed wire failure", () => {
  const obsolete = JSON.stringify({ profile: { ...profile, representation: null } });
  try {
    V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], obsolete, obsolete);
  } catch (error) {
    expect(error).toBeInstanceOf(V.ProfileWireError);
    expect((error as V.ProfileWireError).failure).toEqual({ tag: "UnknownField", value: "representation" });
    return;
  }
  throw new Error("obsolete profile key was accepted");
});

it("returns the Lean predicate identifier for invalid profile declarations", () => {
  expect(() => S.checkProfile({ ...profile, default_integer_domain: "missing" })).toThrow(/PR05/);
  expect(() => S.checkProfile({ ...profile, format_bindings: [...profile.format_bindings, profile.format_bindings[0]!] })).toThrow(/PR06/);
});
