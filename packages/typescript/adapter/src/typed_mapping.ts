// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type * as V from "./semantic_values.js";
import { failed, ok, same } from "./semantic_values.js";

export type TokenKind = { readonly tag: "Input" | "Output" | "Failure" | "Effect" | "Observation" | "Accepted" };

export interface ColoredToken {
  readonly target: string;
  readonly index: bigint;
  readonly revision: bigint;
  readonly kind: TokenKind;
}

export interface TypedPlace {
  readonly identity: string;
  readonly tokenType: string;
  readonly revision: bigint;
}

export interface TypedTransition {
  readonly identity: string;
  readonly inputPlaces: readonly string[];
  readonly outputPlaces: readonly string[];
  readonly failurePlaces: readonly string[];
  readonly revision: bigint;
}

export type BindingMode = { readonly tag: "Read" | "Consume" };

export interface InputBinding {
  readonly transitionId: string;
  readonly name: string;
  readonly place: string;
  readonly tokenType: string;
  readonly identity: string;
  readonly provenance: string;
  readonly multiplicity: bigint;
  readonly mode: BindingMode;
  readonly requiredRevision: bigint;
}

export interface DeclarationGraph {
  readonly places: readonly string[];
  readonly transitions: readonly string[];
  readonly edges: readonly (readonly [string, string])[];
  readonly revision: bigint;
}

export interface DomainBound {
  readonly targetIdentity: string;
  readonly index: bigint;
  readonly revision: bigint;
  readonly maxBindings: bigint;
  readonly maxSearchSteps: bigint;
}

export interface Marking {
  readonly places: readonly (readonly [string, readonly ColoredToken[]])[];
}


export type GoalPredicate =
  | { readonly tag: "PlaceHasAtLeast"; readonly fields: { readonly place: string; readonly count: bigint } }
  | { readonly tag: "PlaceHasToken"; readonly fields: { readonly place: string; readonly target: string; readonly index: bigint; readonly revision: bigint } }
  | { readonly tag: "And" | "Or"; readonly value: readonly [GoalPredicate, GoalPredicate] }
  | { readonly tag: "Not"; readonly value: GoalPredicate };


export interface SolverInput {
  readonly places: readonly TypedPlace[];
  readonly transitions: readonly TypedTransition[];
  readonly bindings: readonly InputBinding[];
  readonly goal: GoalPredicate;
  readonly graph: DeclarationGraph;
  readonly marking: Marking;
  readonly bound: DomainBound;
}


export type UnknownReason =
  | { readonly tag: "BindingBoundExhausted"; readonly value: bigint }
  | { readonly tag: "SearchStepBoundExhausted"; readonly value: bigint };




export interface ReachabilityWitness {
  readonly path: readonly string[];
  readonly finalMarking: Marking;
}






export interface AcyclicWitness {
  readonly exploredMarkings: readonly Marking[];
  readonly steps: bigint;
  readonly frontier: readonly Marking[];
}


export type SolverFailure =
  | { readonly tag: "ContractViolation"; readonly value: string }
  | { readonly tag: "InternalInvariantViolation"; readonly value: string };



















































