// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { createInterface } from "node:readline";
import { evaluateSemanticInvariant } from "../dist/index.js";

for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
  if (line.trim()) process.stdout.write(`${JSON.stringify(evaluateSemanticInvariant(JSON.parse(line)))}\n`);
}
