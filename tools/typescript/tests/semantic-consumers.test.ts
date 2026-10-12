// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { expect, it } from "vitest";

it("admits and executes the @4 generated-code consumer", () => {
  const output = execFileSync(process.execPath, [resolve("tests/semantic-consumers.mjs")], { encoding: "utf8" });
  expect(JSON.parse(output)).toEqual({ admittedInputs: 1, codecRoundtrips: 1, generatedConsumers: 1 });
});
