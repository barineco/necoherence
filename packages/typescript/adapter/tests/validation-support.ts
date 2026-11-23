// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as V from "../src/semantic_values.js";

const text = (value: unknown): string => JSON.stringify(value, (_key, item) => typeof item === "bigint" ? item.toString() : item);

export function acceptedValue(context: V.ValueContext, reference: V.TypeRef, value: V.ExactJson): V.ExactJson {
  const result = V.validateValue(context, reference, value);
  if (result.tag === "Failed") throw new Error(`expected acceptance: ${text(result.failure)}`);
  return value;
}

export function validationFailure(context: V.ValueContext, reference: V.TypeRef, value: V.ExactJson): V.ValidationFailure {
  const result = V.validateValue(context, reference, value);
  if (result.tag === "Ok") throw new Error("expected rejection");
  return result.failure;
}

export function valueFailure(context: V.ValueContext, reference: V.TypeRef, value: V.ExactJson): V.ValueFailure {
  const failure = validationFailure(context, reference, value);
  if (failure.tag !== "Value") throw new Error(`expected a value failure: ${text(failure)}`);
  return failure.failure;
}
