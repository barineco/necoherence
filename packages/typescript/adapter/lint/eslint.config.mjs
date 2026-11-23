// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
// ESLint configuration for consumer code; typescript/README.md describes the rules.

import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    languageOptions: {
      parserOptions: {
        project: true,
      },
    },
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/no-unsafe-call": "error",
      "@typescript-eslint/no-unsafe-member-access": "error",
      "@typescript-eslint/no-unsafe-return": "error",
      "@typescript-eslint/no-unsafe-argument": "error",
      "no-restricted-syntax": [
        "error",
        {
          selector: "TSAsExpression > TSAsExpression",
          message: "Nested type assertions bypass input validation",
        },
      ],
    },
  },
);
