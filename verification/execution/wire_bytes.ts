// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type { RawHeaderField } from "../../packages/typescript/adapter/src/network-effect.js";

interface JsonHeaderField {
  readonly name: string;
  readonly value: readonly number[];
}

export function headerFields(headers: readonly JsonHeaderField[]): readonly RawHeaderField[] {
  return headers.map((header) => ({ name: header.name, value: Uint8Array.from(header.value) }));
}
