// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as V from "../src/semantic_values.js";
import { profile, reference } from "./semantic-fixture.js";

const bytes = Uint8Array.from([251, 255]);

it("encodes bytes as standard base64 when the profile has no bytes policy", () => {
  expect(V.bytesExact(bytes, { ...profile, bytes_policy: null })).toEqual({ tag: "String", value: "+/8=" });
});

it("encodes bytes as a string when the bytes policy names no wrapper", () => {
  expect(V.bytesExact(bytes, { ...profile, bytes_policy: { reference, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: null } })).toEqual({ tag: "String", value: "+/8=" });
});

it("encodes bytes as a string when the named wrapper is not declared", () => {
  expect(V.bytesExact(bytes, { ...profile, bytes_policy: { ...profile.bytes_policy!, wrapper: "missing" } })).toEqual({ tag: "String", value: "+/8=" });
});

it("encodes bytes inside the declared wrapper", () => {
  expect(V.bytesExact(bytes, profile)).toEqual({ tag: "Object", members: [{ key: "binary", value: { tag: "String", value: "+/8=" } }] });
});
