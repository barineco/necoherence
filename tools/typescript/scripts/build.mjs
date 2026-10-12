// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { execFileSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const directory = fileURLToPath(new URL("../", import.meta.url));
rmSync(new URL("../dist/", import.meta.url), { recursive: true, force: true });
execFileSync(process.execPath, [fileURLToPath(new URL("../node_modules/typescript/bin/tsc", import.meta.url)), "--project", "tsconfig.build.json"], { cwd: directory, stdio: "inherit" });
