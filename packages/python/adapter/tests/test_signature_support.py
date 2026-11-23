# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import neco_quotient_certificate as nqc

from necoherence.signature_support import CompositionJudgment, CompositionReasonFailure, classify_unresolved_obligations
from necoherence.signature_values import SemanticDecisionFailure, classify_dispositions, classify_semantic_obligations, variant


def test_unresolved_type_meaning_obligation_is_residual():
    obligation = variant("Meaning", [{"reason": variant("UnresolvedType")}])
    classified = classify_unresolved_obligations([obligation], {})
    assert classified == nqc.Residual(CompositionJudgment((obligation,), {}), [obligation])


def test_empty_obligations_fail_with_no_classifications():
    classified = classify_unresolved_obligations([], {"operation": "compose"})
    assert classified == CompositionReasonFailure((), nqc.ResidualSet([]), (), {"operation": "compose"})


def test_empty_disposition_list_is_failed():
    assert classify_dispositions([]) == "Failed"


def test_failed_evaluation_carries_flat_dispositions_in_obligation_order():
    inhabitation = variant("Inhabitation", None)
    empty_meaning = variant("Meaning", [])
    classified = classify_unresolved_obligations([inhabitation, empty_meaning], {})
    assert isinstance(classified, CompositionReasonFailure)
    assert (classified.residuals.values, classified.classifications) == ((inhabitation,), ("Residual", "Failed"))


def test_stopped_evaluation_keeps_residuals_and_stops_apart():
    residual = variant("Inhabitation", None)
    stopped = variant("StateBoundExhausted", None)
    classified = classify_unresolved_obligations([residual, stopped], {})
    assert classified == nqc.Stopped(CompositionJudgment((residual, stopped), {}), [residual], (stopped,))


def test_semantic_classification_prefers_failure_then_stop_then_residual():
    residual = {"reason": variant("UnresolvedType")}
    stopped = {"reason": variant("MembershipBound")}
    failed = {"reason": variant("IntegerBound")}
    assert isinstance(classify_semantic_obligations([residual, stopped, failed], {}), SemanticDecisionFailure)
    assert isinstance(classify_semantic_obligations([residual, stopped], {}), nqc.Stopped)
    assert isinstance(classify_semantic_obligations([residual], {}), nqc.Residual)
    assert isinstance(classify_semantic_obligations([], {}), SemanticDecisionFailure)
