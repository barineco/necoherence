// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

const registries = new WeakMap<object, ReadonlyMap<string, unknown>>();

export function registerRecords(owner: object, records: ReadonlyMap<string, unknown>): void {
  registries.set(owner, records);
}

export function recordCount(owner: object): number {
  return registries.get(owner)?.size ?? 0;
}
