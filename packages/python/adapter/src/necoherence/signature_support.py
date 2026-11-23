# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from dataclasses import dataclass

import neco_quotient_certificate as nqc

from .signature_values import classify_dispositions, payload, semantic_reason_disposition, sum_tag, variant


@dataclass(frozen=True, slots=True)
class CompositionJudgment:
    obligations: tuple
    provenance: object


@dataclass(frozen=True, slots=True)
class CompositionReasonFailure:
    obligations: tuple
    residuals: nqc.ResidualSet
    classifications: tuple
    provenance: object


type CompositionEvaluation = nqc.RefinementOutcome[CompositionJudgment, object, tuple] | CompositionReasonFailure


def _type_reason_classifications(reason):
    category = sum_tag(reason["reason"])
    if category == "Meaning":
        meanings = payload(reason["reason"])
        if not meanings:
            return ["Failed"]
        return [semantic_reason_disposition(meaning["reason"]) for meaning in meanings]
    if category not in ("ConstraintImplication", "Presence", "UnionRemainder", "Inhabitation", "ExtraField", "ObligationBoundExhausted"):
        raise ValueError("unknown type obligation reason")
    return ["Stopped" if category == "ObligationBoundExhausted" else "Residual"]


def _type_atoms(obligation):
    value = payload(obligation)
    if not value["obligations"]:
        return [obligation]
    atoms = []
    for reason in value["obligations"]:
        if sum_tag(reason["reason"]) == "Meaning":
            meanings = payload(reason["reason"])
            if not meanings:
                atoms.append(variant("Type", fields={**value, "obligations": [reason]}))
            for meaning in meanings:
                atoms.append(variant("Type", fields={**value, "obligations": [{**reason, "reason": variant("Meaning", [meaning])}]}))
        else:
            atoms.append(variant("Type", fields={**value, "obligations": [reason]}))
    return atoms


def _unresolved_atoms(obligation):
    kind = sum_tag(obligation)
    if kind in ("Meaning", "SemanticMeaning"):
        reasons = payload(obligation)
        if not reasons:
            return [obligation]
        return [variant(kind, [reason]) for reason in reasons]
    if kind == "Type":
        return _type_atoms(obligation)
    return [obligation]


def _unresolved_classifications(obligation):
    kind = sum_tag(obligation)
    if kind == "Type":
        value = payload(obligation)
        if not value["obligations"]:
            return ["Failed"]
        return [disposition for reason in value["obligations"] for disposition in _type_reason_classifications(reason)]
    if kind in ("Meaning", "SemanticMeaning"):
        reasons = payload(obligation)
        if not reasons:
            return ["Failed"]
        return [semantic_reason_disposition(reason["reason"]) for reason in reasons]
    if kind in ("Inhabitation", "BranchInhabitation", "UnresolvedUniqueness"):
        return ["Residual"]
    if kind in ("StateBoundExhausted", "BindingBoundExhausted", "BranchBoundExhausted", "ResourceSolverUnknown", "ResourceCapacityBound"):
        return ["Stopped"]
    raise ValueError("unknown unresolved obligation")


def unresolved_atoms_with(obligations, disposition):
    return tuple(
        atom
        for obligation in obligations
        for atom in _unresolved_atoms(obligation)
        if classify_dispositions(_unresolved_classifications(atom)) == disposition
    )


def classify_unresolved_obligations(obligations, provenance):
    obligations = tuple(obligations)
    classes = tuple(disposition for obligation in obligations for disposition in _unresolved_classifications(obligation))
    residuals = nqc.ResidualSet(unresolved_atoms_with(obligations, "Residual"))
    judgment = CompositionJudgment(obligations, provenance)
    match classify_dispositions(classes):
        case "Residual":
            return nqc.Residual(judgment, residuals)
        case "Stopped":
            return nqc.Stopped(judgment, residuals, unresolved_atoms_with(obligations, "Stopped"))
    return CompositionReasonFailure(obligations, residuals, classes, provenance)


__all__ = ["CompositionEvaluation", "CompositionJudgment", "CompositionReasonFailure", "classify_unresolved_obligations", "unresolved_atoms_with"]
