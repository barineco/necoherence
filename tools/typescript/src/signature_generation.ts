// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { semanticSignatures as S } from "necoherence";
import { renderSignatureSurface } from "./signature_renderer.js";

export function renderSignatureGenerationInput(expected: S.SignatureGenerationBasis, exchangeJson: string, runtimeModule = "necoherence"): string {
  const admitted = S.admitSignatureGeneration(expected, exchangeJson);
  if (admitted.tag === "Failed") {
    if (admitted.failure.tag === "Predicate") throw admitted.failure.value;
    throw new S.GenerationWireError(admitted.failure);
  }
  return renderSignatureGeneration(admitted.checked, runtimeModule);
}

export function renderSignatureGeneration(checked: S.CheckedSignatureGeneration, runtimeModule = "necoherence"): string {
  S.requireAdmittedGeneration(checked); const input = checked.input; const lines = [`// SPDX-License-Identifier: MIT`, `import { networkEffect as N, semanticSignatures as S, semanticValues as V } from ${JSON.stringify(runtimeModule)};`, `const admitted = S.admitSignatureGeneration(${JSON.stringify(input.basis)}, ${JSON.stringify(JSON.stringify(input))});`, `if (admitted.tag === "Failed") throw new Error(JSON.stringify(admitted.failure));`, `const checked = admitted.checked;`, `export const signatureGraph = checked.signatures.context.graph;`, `export const annotations = checked.input.signatures.annotations;`, `export function annotationsFor(target: S.AnnotationTarget) { return checked.annotations(target); }`];
  const name = (id: string): string => `N_${Array.from(new TextEncoder().encode(id), b => b.toString(16).padStart(2, "0")).join("")}`;
  const typeName = (id: string): string => `T_${name(id).slice(2)}`;
  const typeExpression = (shape: S.ValueTypeShape): string => {
    if (shape.tag === "Alias") return typeName(shape.fields.target);
    const tags: Record<string, string> = { Boolean: "Bool", Integer: "Integer", Decimal: "Decimal", String: "String", Unit: "Null", Array: "Array", Product: "Object", TaggedUnion: "Object", Sealed: "Object", Bytes: "String", RawBody: "String" };
    return tags[shape.tag] ? `Extract<V.ExactJson, { readonly tag: ${JSON.stringify(tags[shape.tag])} }>` : "V.ExactJson";
  };
  for (const n of checked.signatures.library.nodes) { checked.signatures.context.defined(checked.signatures.refs.get(n.id)!); lines.push(`export type ${typeName(n.id)} = ${typeExpression(n.shape)};`, `export const ${typeName(n.id)}Codec = checked.codec<${typeName(n.id)}>(${JSON.stringify(n.id)});`); }
  for (const d of checked.signatures.library.definitions) {
    if (d.shape.tag === "Operation") {
      const supplied = input.composition === null ? undefined : (input.composition as { problem: { signatures: readonly any[] } }).problem.signatures.find(s => s.form.tag === "Operation" && s.form.value === d.id);
      const o: S.OperationContract = supplied ? { effect: supplied.effect, inputs: supplied.inputs.map((p: any) => ({ id: p.id, contract: p.contract })), outcomes: supplied.outcomes.map((o: any) => ({ id: o.id, form: o.form, cause: o.cause, value_ports: o.value_ports.map((p: any) => ({ id: p.id, contract: p.contract })), produced_resources: o.produced_resources })) } : d.shape.value;
      lines.push(`export type ${name(d.id)}Outcome = ${o.outcomes.map(x => `{ readonly outcome: ${JSON.stringify(x.id)}; readonly values: { ${x.value_ports.map(p => `${JSON.stringify(p.id)}: S.TypedSignatureSlot<${typeName(p.contract.type_id)}, ${p.contract.required}, ${p.contract.nullable}>`).join("; ")} } }`).join(" | ")};`, `export const ${name(d.id)} = ${JSON.stringify(o)} as const;`);
      lines.push(`export type ${name(d.id)}Input = { ${o.inputs.map(p => `${JSON.stringify(p.id)}: S.TypedSignatureSlot<${typeName(p.contract.type_id)}, ${p.contract.required}, ${p.contract.nullable}>`).join("; ")} };`);
      if (o.effect.tag === "HttpRequestResponse") {
        const external = o.outcomes.filter(x => x.cause.tag === "ExternalCondition").map(x => JSON.stringify(x.id)).join(" | ") || "never";
        lines.push(
          `export type ${name(d.id)}ExternalOutcome = Extract<${name(d.id)}Outcome, { readonly outcome: ${external} }>;`,
          `export type ${name(d.id)}Preparation = { readonly tag: "Ready"; readonly value: N.AttemptInput } | { readonly tag: "Completed"; readonly value: { readonly outcome: ${external}; readonly value: ${name(d.id)}Outcome } };`,
          `export type ${name(d.id)}HttpBinding = HttpBinding<${name(d.id)}Input, ${name(d.id)}Outcome>;`,
          `export function ${name(d.id)}Prepare(value: ${name(d.id)}Preparation) { return validateHttpPreparation(${name(d.id)}, value); }`,
          `export function ${name(d.id)}Execute(input: ${name(d.id)}Input, binding: ${name(d.id)}HttpBinding, network: NetworkBindings) { return execute(${name(d.id)}, input, binding, network); }`,
        );
      }
    } else if (d.shape.tag === "Symbol") lines.push(`export const ${name(d.id)} = ${JSON.stringify(d.shape.value)};`);
    else lines.push(`export const ${name(d.id)}Codec = checked.codec<${typeName(d.shape.value)}>(${JSON.stringify(d.shape.value)});`);
  }
  if (input.composition !== null) S.checkSignatureComposition(checked.signatures, input.composition);
  const concrete = renderSignatureSurface({ checked: checked.signatures, basis: input.basis }, runtimeModule);
  return lines.join("\n") + "\n" + concrete.split("\n").slice(2).join("\n");
}
