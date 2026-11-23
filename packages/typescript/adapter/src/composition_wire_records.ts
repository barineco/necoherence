// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as C from "./semantic_composition.js";
import * as V from "./semantic_values.js";

export type Row = Record<string, unknown>;

export function fail(tag: "UnknownField" | "UnknownTag" | "Syntax", path: string, detail: string): never {
  throw new V.WireError({ tag, path, value: detail });
}

export function row(value: unknown, keys: readonly string[], path: string): Row {
  V.wireKeys(value, path, keys);
  return value;
}

export function text(value: unknown, path: string): string {
  V.wireString(value, path);
  return value as string;
}

export function unitTag<T extends string>(value: unknown, path: string, tags: readonly T[]): { readonly tag: T } {
  const tag = V.wireTag(value, path);
  if (!tags.includes(tag as T)) return fail("UnknownTag", `${path}.tag`, tag);
  row(value, ["tag"], path);
  return { tag: tag as T };
}

export function tupleTag(value: unknown, path: string, expected: string): unknown {
  const record = row(value, ["tag", "value"], path), tag = text(record.tag, `${path}.tag`);
  if (tag !== expected) return fail("UnknownTag", `${path}.tag`, tag);
  return record.value;
}

export function recordTag(value: unknown, path: string, expected: string, keys: readonly string[]): Row {
  const record = row(value, ["tag", "fields"], path), tag = text(record.tag, `${path}.tag`);
  if (tag !== expected) return fail("UnknownTag", `${path}.tag`, tag);
  return row(record.fields, keys, `${path}.fields`);
}

export function functionRef(value: unknown, path: string): C.FunctionRef {
  const record = row(value, ["identity", "revision", "content_digest"], path);
  return { identity: text(record.identity, `${path}.identity`), revision: text(record.revision, `${path}.revision`), contentDigest: text(record.content_digest, `${path}.content_digest`) };
}

export function resourceLotRef(value: unknown, path: string): C.ResourceLotRef {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Initial") return { tag, value: text(tupleTag(value, path, tag), `${path}.value`) };
  if (tag === "Produced") { const fields = recordTag(value, path, tag, ["site", "outcome", "production"]); return { tag, fields: { site: text(fields.site, `${path}.fields.site`), outcome: text(fields.outcome, `${path}.fields.outcome`), production: text(fields.production, `${path}.fields.production`) } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}

export function producerRef(value: unknown, path: string): C.ProducerRef {
  const tag = text((value as Row)?.tag, `${path}.tag`);
  if (tag === "Initial") return { tag, value: text(tupleTag(value, path, tag), `${path}.value`) };
  if (tag === "InvocationOutcome") { const fields = recordTag(value, path, tag, ["site", "outcome", "port"]); return { tag, fields: { site: text(fields.site, `${path}.fields.site`), outcome: text(fields.outcome, `${path}.fields.outcome`), port: text(fields.port, `${path}.fields.port`) } }; }
  return fail("UnknownTag", `${path}.tag`, tag);
}
