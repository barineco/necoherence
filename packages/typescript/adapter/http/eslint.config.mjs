// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import tseslint from "typescript-eslint";
import config from "../lint/eslint.config.mjs";

export default [
  { files: ["**/*.ts"], ...tseslint.configs.base },
  ...config.map(item => ({ files: ["**/*.ts"], ...item })),
];
