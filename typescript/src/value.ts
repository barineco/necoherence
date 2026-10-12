// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type { ResourceId, Revision } from "./core.js";

export type ValuePathPart = string | number;
export type ValuePath = readonly ValuePathPart[];

export type OwnedData =
  | null
  | boolean
  | string
  | bigint
  | readonly AdmittedValue[]
  | { readonly [key: string]: AdmittedValue }
  | ResourceId
  | Revision;

export interface ForeignHandle {
  readonly tag: "ForeignHandle";
  readonly handle: string;
  readonly capability: unknown;
  readonly observedAt: bigint;
}

export type AdmittedValue = OwnedData | ForeignHandle;

export interface ValueFailure {
  readonly type: "ValueFailure";
  readonly tag:
    | "UnsupportedValue"
    | "ValueAccessFailed"
    | "InvalidResourceId"
    | "InvalidRevision"
    | "DuplicateResource"
    | "RevisionAlias"
    | "RevisionReuse";
  readonly operation: string;
  readonly failingOperation: string;
  readonly failing_operation: string;
  readonly inputPath: ValuePath;
  readonly input_path: ValuePath;
  readonly path: string;
  readonly operandProvenance: Readonly<Record<string, string>>;
  readonly operand_provenance: Readonly<Record<string, string>>;
  readonly violatedCondition: string;
  readonly violated_condition: string;
  readonly witness: string;
  readonly contributingFailures: readonly ValueFailure[];
  readonly contributing_failures: readonly ValueFailure[];
  readonly resource?: ResourceId;
  readonly revision?: Revision;
  readonly firstPath?: ValuePath;
}

export interface Accepted<T = AdmittedValue> {
  readonly tag: "Accepted";
  readonly value: T;
}

export interface Foreign<T = ForeignHandle> {
  readonly tag: "Foreign";
  readonly value: T;
  readonly handle: string;
  readonly capability: unknown;
  readonly observedAt: bigint;
}

export interface Rejected {
  readonly tag: "Rejected";
  readonly failure: ValueFailure;
}

export type ValueAdmission<T extends AdmittedValue = AdmittedValue> =
  | Accepted<T>
  | Foreign<Extract<T, ForeignHandle>>
  | Rejected;

const foreignMarker = Symbol("necoherence.foreignHandle");

function pathText(path: ValuePath): string {
  if (path.length === 0) return "$";
  return path.reduce<string>(
    (text, part) =>
      typeof part === "number" ? `${text}[${part}]` : `${text}.${part}`,
    "$"
  );
}

function freezePath(path: ValuePath): ValuePath {
  return Object.freeze([...path]);
}

function failure(
  tag: ValueFailure["tag"],
  operation: string,
  inputPath: ValuePath,
  violatedCondition: string,
  witness: string,
  contributingFailures: readonly ValueFailure[] = [],
  extras: {
    readonly resource?: ResourceId;
    readonly revision?: Revision;
    readonly firstPath?: ValuePath;
  } = {}
): ValueFailure {
  const frozenPath = freezePath(inputPath);
  const frozenContributors = Object.freeze([...contributingFailures]);
  const provenance: Readonly<Record<string, string>> = Object.freeze({
    inputPath: pathText(frozenPath),
    operation,
  });
  return Object.freeze({
    type: "ValueFailure" as const,
    tag,
    operation,
    failingOperation: operation,
    failing_operation: operation,
    inputPath: frozenPath,
    input_path: frozenPath,
    path: pathText(frozenPath),
    operandProvenance: provenance,
    operand_provenance: provenance,
    violatedCondition,
    violated_condition: violatedCondition,
    witness,
    contributingFailures: frozenContributors,
    contributing_failures: frozenContributors,
    ...extras,
  });
}

function errorText(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  try {
    return String(error);
  } catch {
    return "unprintable host exception";
  }
}

function isObject(value: unknown): value is object {
  return typeof value === "object" && value !== null;
}

function isForeignHandle(value: unknown): value is ForeignHandle {
  if (!isObject(value)) return false;
  try {
    return (
      (value as Record<PropertyKey, unknown>)[foreignMarker] === true &&
      (value as Record<string, unknown>).tag === "ForeignHandle"
    );
  } catch {
    return false;
  }
}

function isResourceShape(value: unknown): value is ResourceId {
  if (!isObject(value)) return false;
  try {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) return false;
    const keys = Reflect.ownKeys(value);
    if (keys.length !== 2 || !keys.includes("kind") || !keys.includes("name")) {
      return false;
    }
    const kind = Reflect.get(value, "kind");
    const name = Reflect.get(value, "name");
    return typeof kind === "string" && typeof name === "string";
  } catch {
    return false;
  }
}

function isRevisionShape(value: unknown): value is Revision {
  if (!isObject(value)) return false;
  try {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) return false;
    const keys = Reflect.ownKeys(value);
    return (
      keys.length === 1 &&
      keys[0] === "value" &&
      typeof Reflect.get(value, "value") === "bigint"
    );
  } catch {
    return false;
  }
}

function ownDataKeys(
  value: object,
  path: ValuePath,
  operation: string
): ValuePath | ValueFailure {
  let keys: readonly PropertyKey[];
  try {
    keys = Reflect.ownKeys(value);
  } catch (error) {
    return failure(
      "ValueAccessFailed",
      operation,
      path,
      "own properties must be readable",
      errorText(error)
    );
  }
  for (const key of keys) {
    if (typeof key !== "string") {
      return failure(
        "UnsupportedValue",
        operation,
        [...path, String(key)],
        "plain records use string own data properties",
        "symbol property"
      );
    }
    let descriptor: PropertyDescriptor | undefined;
    try {
      descriptor = Object.getOwnPropertyDescriptor(value, key);
    } catch (error) {
      return failure(
        "ValueAccessFailed",
        operation,
        [...path, key],
        "property descriptors must be readable",
        errorText(error)
      );
    }
    if (descriptor === undefined) {
      return failure(
        "ValueAccessFailed",
        operation,
        [...path, key],
        "property descriptors must remain available",
        "missing descriptor"
      );
    }
    if (!("value" in descriptor)) {
      return failure(
        "ValueAccessFailed",
        operation,
        [...path, key],
        "accessor properties require an explicit adapter",
        "getter or setter"
      );
    }
  }
  return freezePath(keys.filter((key): key is string => typeof key === "string"));
}

function snapshotForeign(
  input: ForeignHandle,
  path: ValuePath,
  operation: string
): ValueAdmission<ForeignHandle> {
  let handle: unknown;
  let capability: unknown;
  let observedAt: unknown;
  try {
    handle = input.handle;
    capability = input.capability;
    observedAt = input.observedAt;
  } catch (error) {
    return {
      tag: "Rejected",
      failure: failure(
        "ValueAccessFailed",
        operation,
        path,
        "foreign handle fields must be readable",
        errorText(error)
      ),
    };
  }
  if (typeof handle !== "string" || typeof observedAt !== "bigint" || observedAt < 0n) {
    return {
      tag: "Rejected",
      failure: failure(
        "InvalidRevision",
        operation,
        path,
        "foreign handle requires a string handle and non-negative observedAt",
        "invalid foreign handle metadata"
      ),
    };
  }
  const copied = Object.freeze({
    tag: "ForeignHandle" as const,
    handle,
    capability,
    observedAt,
    [foreignMarker]: true as const,
  });
  return {
    tag: "Foreign",
    value: copied,
    handle,
    capability,
    observedAt,
  };
}

function snapshot(
  input: unknown,
  path: ValuePath,
  operation: string,
  ancestors: WeakSet<object>
): ValueAdmission {
  if (input === null) return { tag: "Accepted", value: null };
  switch (typeof input) {
    case "boolean":
    case "string":
    case "bigint":
      return { tag: "Accepted", value: input };
    case "undefined":
      return {
        tag: "Rejected",
        failure: failure(
          "UnsupportedValue",
          operation,
          path,
          "undefined is outside OwnedData",
          "undefined"
        ),
      };
    case "number":
      return {
        tag: "Rejected",
        failure: failure(
          "UnsupportedValue",
          operation,
          path,
          "number is outside OwnedData",
          Number.isFinite(input) ? "number" : "non-finite number"
        ),
      };
    case "symbol":
    case "function":
      return {
        tag: "Rejected",
        failure: failure(
          "UnsupportedValue",
          operation,
          path,
          "symbol and function are outside OwnedData",
          typeof input
        ),
      };
  }

  if (isForeignHandle(input)) return snapshotForeign(input, path, operation);
  if (ancestors.has(input)) {
    return {
      tag: "Rejected",
      failure: failure(
        "UnsupportedValue",
        operation,
        path,
        "OwnedData must be acyclic",
        "circular reference"
      ),
    };
  }
  ancestors.add(input);
  try {
    const dataKeysResult = ownDataKeys(input, path, operation);
    if (!Array.isArray(dataKeysResult)) {
      return { tag: "Rejected", failure: dataKeysResult as ValueFailure };
    }
    const dataKeys = dataKeysResult;

    if (isResourceShape(input)) {
      let kind: unknown;
      let name: unknown;
      try {
        kind = Reflect.get(input, "kind");
        name = Reflect.get(input, "name");
      } catch (error) {
        return {
          tag: "Rejected",
          failure: failure(
            "ValueAccessFailed",
            operation,
            [...path, "resource"],
            "ResourceId fields must be readable data",
            errorText(error)
          ),
        };
      }
      if (typeof kind !== "string" || typeof name !== "string") {
        return {
          tag: "Rejected",
          failure: failure(
            "InvalidResourceId",
            operation,
            path,
            "ResourceId requires string kind and name",
            "invalid ResourceId"
          ),
        };
      }
      return {
        tag: "Accepted",
        value: Object.freeze({ kind, name }),
      };
    }

    if (isRevisionShape(input)) {
      let value: unknown;
      try {
        value = Reflect.get(input, "value");
      } catch (error) {
        return {
          tag: "Rejected",
          failure: failure(
            "ValueAccessFailed",
            operation,
            [...path, "revision"],
            "Revision value must be readable data",
            errorText(error)
          ),
        };
      }
      if (typeof value !== "bigint" || value < 0n) {
        return {
          tag: "Rejected",
          failure: failure(
            "InvalidRevision",
            operation,
            path,
            "Revision requires a non-negative bigint value",
            String(value)
          ),
        };
      }
      return { tag: "Accepted", value: Object.freeze({ value }) };
    }

    if (Array.isArray(input)) {
      const keys = dataKeys.filter((key) => key !== "length");
      if (keys.length !== input.length || keys.some((key, index) => key !== String(index))) {
        return {
          tag: "Rejected",
          failure: failure(
            "UnsupportedValue",
            operation,
            path,
            "arrays must have finite contiguous data indices",
            "sparse or extended array"
          ),
        };
      }
      const values: AdmittedValue[] = [];
      for (let index = 0; index < input.length; index += 1) {
        let child: unknown;
        try {
          child = Reflect.get(input, index);
        } catch (error) {
          return {
            tag: "Rejected",
            failure: failure(
              "ValueAccessFailed",
              operation,
              [...path, index],
              "array elements must be readable data",
              errorText(error)
            ),
          };
        }
        const result = snapshot(child, [...path, index], operation, ancestors);
        if (result.tag === "Rejected") return result;
        if (result.tag === "Foreign") {
          values.push(result.value);
        } else {
          values.push(result.value);
        }
      }
      return { tag: "Accepted", value: Object.freeze(values) };
    }

    let prototype: object | null;
    try {
      prototype = Object.getPrototypeOf(input);
    } catch (error) {
      return {
        tag: "Rejected",
        failure: failure(
          "ValueAccessFailed",
          operation,
          path,
          "plain record prototype must be readable",
          errorText(error)
        ),
      };
    }
    if (prototype !== Object.prototype && prototype !== null) {
      return {
        tag: "Rejected",
        failure: failure(
          "UnsupportedValue",
          operation,
          path,
          "only plain records with Object.prototype or null prototype are accepted",
          Object.prototype.toString.call(input)
        ),
      };
    }
    const keys = dataKeys;
    const record = Object.create(null) as Record<string, AdmittedValue>;
    for (const key of keys) {
      let child: unknown;
      try {
        child = Reflect.get(input, key);
      } catch (error) {
        return {
          tag: "Rejected",
          failure: failure(
            "ValueAccessFailed",
            operation,
            [...path, key],
            "record fields must be readable data",
            errorText(error)
          ),
        };
      }
      const result = snapshot(child, [...path, key], operation, ancestors);
      if (result.tag === "Rejected") return result;
      record[key] = result.tag === "Foreign" ? result.value : result.value;
    }
    return { tag: "Accepted", value: Object.freeze(record) };
  } finally {
    ancestors.delete(input);
  }
}

export function snapshotValue(input: unknown): ValueAdmission {
  return snapshot(input, [], "snapshotValue", new WeakSet<object>());
}

export function snapshotResourceId(input: unknown, inputPath: ValuePath = []): ValueAdmission<ResourceId> {
  const result = snapshot(input, inputPath, "snapshotResourceId", new WeakSet<object>());
  if (result.tag !== "Accepted" || !isResourceShape(result.value)) {
    if (result.tag === "Rejected") return result;
    return {
      tag: "Rejected",
      failure: failure(
        "InvalidResourceId",
        "snapshotResourceId",
        inputPath,
        "ResourceId requires exactly string kind and name",
        "invalid ResourceId"
      ),
    };
  }
  return { tag: "Accepted", value: Object.freeze({ kind: result.value.kind, name: result.value.name }) };
}

export function snapshotRevision(input: unknown, inputPath: ValuePath = []): ValueAdmission<Revision> {
  const result = snapshot(input, inputPath, "snapshotRevision", new WeakSet<object>());
  if (result.tag !== "Accepted" || !isRevisionShape(result.value)) {
    if (result.tag === "Rejected") return result;
    return {
      tag: "Rejected",
      failure: failure(
        "InvalidRevision",
        "snapshotRevision",
        inputPath,
        "Revision requires exactly a non-negative bigint value",
        "invalid Revision"
      ),
    };
  }
  if (result.value.value < 0n) {
    return {
      tag: "Rejected",
      failure: failure(
        "InvalidRevision",
        "snapshotRevision",
        inputPath,
        "Revision requires a non-negative bigint value",
        String(result.value.value)
      ),
    };
  }
  return { tag: "Accepted", value: Object.freeze({ value: result.value.value }) };
}

export function foreignHandle(capability: unknown, observedAt: bigint): ForeignHandle;
export function foreignHandle(handle: string, capability: unknown, observedAt: bigint): ForeignHandle;
export function foreignHandle(
  first: unknown,
  second: unknown,
  third?: bigint
): ForeignHandle {
  const handle = third === undefined ? "foreign" : first;
  const capability = third === undefined ? first : second;
  const observedAt = third === undefined ? second : third;
  if (typeof handle !== "string") throw new TypeError("foreign handle must be a string");
  if (typeof observedAt !== "bigint" || observedAt < 0n) {
    throw new RangeError("foreign handle observedAt must be a non-negative bigint");
  }
  return Object.freeze({
    tag: "ForeignHandle" as const,
    handle,
    capability,
    observedAt,
    [foreignMarker]: true as const,
  });
}

export const createForeignHandle = foreignHandle;

export function isOwnedData(value: unknown): value is OwnedData {
  const result = snapshotValue(value);
  return result.tag === "Accepted";
}

export function isForeignValue(value: unknown): value is ForeignHandle {
  return isForeignHandle(value);
}

export function valueFailure(
  tag: ValueFailure["tag"],
  operation: string,
  inputPath: ValuePath,
  violatedCondition: string,
  witness: string,
  contributingFailures: readonly ValueFailure[] = [],
  extras: {
    readonly resource?: ResourceId;
    readonly revision?: Revision;
    readonly firstPath?: ValuePath;
  } = {}
): ValueFailure {
  return failure(tag, operation, inputPath, violatedCondition, witness, contributingFailures, extras);
}
