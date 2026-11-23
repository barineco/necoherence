// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";
import { profile, reference, sourceIdentity } from "./semantic-fixture.js";

const artifact = JSON.stringify(profile);

it("admits the caller-bound @4 profile artifact", () => {
  expect(V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], artifact, artifact)).toEqual(profile);
  expect(S.checkProfile(V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], artifact, artifact)).profile).toEqual(profile);
});

it("binds profile identity, sources and trusted bytes", () => {
  expect(() => V.decodeCanonicalProfileArtifact({ ...reference, identity: "other" }, [sourceIdentity], artifact, artifact)).toThrow(/profile reference/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [{ ...sourceIdentity, revision: "other" }], artifact, artifact)).toThrow(/profile sources/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], artifact, `${artifact} `)).toThrow(/profile artifact bytes/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], JSON.stringify({ profile }), JSON.stringify({ profile }))).toThrow(/UnknownField:profile/);
});

it("checks the bound reference before the profile predicates", () => {
  const invalid = JSON.stringify({ ...profile, default_integer_domain: "missing" });
  expect(() => V.decodeCanonicalProfileArtifact({ ...reference, identity: "other" }, [sourceIdentity], invalid, invalid)).toThrow(/profile reference/);
  expect(() => V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], invalid, invalid)).toThrow(/PR05/);
});

it("rejects obsolete profile keys with a typed wire failure", () => {
  const obsolete = JSON.stringify({ ...profile, representation: null });
  try {
    V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], obsolete, obsolete);
  } catch (error) {
    expect(error).toBeInstanceOf(V.WireError);
    expect((error as V.WireError).failure).toEqual({ tag: "UnknownField", path: "$.representation", value: "representation" });
    return;
  }
  throw new Error("obsolete profile key was accepted");
});

it("admits the profile artifact text as the Lean decodeProfileJson does", () => {
  const artifactFailure = (member: string): V.WireFailure => {
    const text = `${artifact.slice(0, -1)},"unknown":${member}}`;
    try { V.decodeCanonicalProfileArtifact(reference, [sourceIdentity], text, text); } catch (error) {
      expect(error).toBeInstanceOf(V.WireError);
      return (error as V.WireError).failure;
    }
    throw new Error("profile artifact failure expected");
  };
  expect(artifactFailure('"\\ud800"')).toEqual({ tag: "Syntax", path: "$", value: "unpaired Unicode surrogate" });
  expect(artifactFailure('"\\udc00"')).toEqual({ tag: "Syntax", path: "$", value: "unpaired Unicode surrogate" });
  expect(artifactFailure('"\\ud83d\\u0041"')).toEqual({ tag: "Syntax", path: "$", value: "unpaired Unicode surrogate" });
  expect(artifactFailure('"\\ud83d\\ude00"')).toEqual({ tag: "UnknownField", path: "$.unknown", value: "unknown" });
  expect(artifactFailure("1e10000")).toEqual({ tag: "Syntax", path: "$", value: "exponent too large" });
  expect(artifactFailure("1e9999")).toEqual({ tag: "UnknownField", path: "$.unknown", value: "unknown" });
});

it("returns the Lean predicate identifier for invalid profile declarations", () => {
  expect(() => S.checkProfile({ ...profile, default_integer_domain: "missing" })).toThrow(/PR05/);
  expect(() => S.checkProfile({ ...profile, format_bindings: [...profile.format_bindings, profile.format_bindings[0]!] })).toThrow(/PR06/);
});
