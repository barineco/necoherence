# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

from verification.network_effect import differential, host_failure_matrix


def exit_value(module, entry: str, report: dict, arguments: list[str]) -> int:
    with mock.patch.object(module, entry, return_value=report), \
            mock.patch.object(sys, "argv", ["check", *arguments]), \
            contextlib.redirect_stdout(io.StringIO()):
        return module.main()


def differential_exit(report: dict) -> int:
    covered = {"pairwiseCoverage": {"allCovered": True}}
    return exit_value(differential, "run_differential", {**covered, **report}, ["--all"])


def matrix_exit(report: dict) -> int:
    return exit_value(host_failure_matrix, "run_matrix", report, ["--all"])


class DifferentialExit(unittest.TestCase):
    def test_agreement_on_available_lanes_exits_zero(self) -> None:
        self.assertEqual(differential_exit({"unavailableLanes": [], "mismatchCount": 0}), 0)

    def test_mismatch_exits_one(self) -> None:
        self.assertEqual(differential_exit({"unavailableLanes": [], "mismatchCount": 3}), 1)

    def test_unavailable_lane_exits_one(self) -> None:
        self.assertEqual(differential_exit({"unavailableLanes": ["java"], "mismatchCount": 0}), 1)


    def test_lost_pairwise_coverage_exits_one(self) -> None:
        report = {"unavailableLanes": [], "mismatchCount": 0, "pairwiseCoverage": {"allCovered": False}}
        self.assertEqual(differential_exit(report), 1)


class DifferentialReference(unittest.TestCase):
    def report(self, reference_available: bool) -> dict:
        specs = tuple(
            differential.RunnerSpec(name, ("true",), Path("."))
            for name in ("lean", "python")
        )

        def invoke(spec, invocation, timeout=30.0):
            available = reference_available if spec.name == "lean" else True
            return differential.RunnerObservation(spec.name, available, {"result": "Accepted"})

        with mock.patch.object(differential, "runner_specs", return_value=specs), \
                mock.patch.object(differential, "prepare_runner", side_effect=lambda spec: (spec, None)), \
                mock.patch.object(differential, "invoke", side_effect=invoke):
            return differential.run_differential(full=False, limit=1)

    def test_available_reference_exits_zero(self) -> None:
        report = self.report(True)
        self.assertEqual(report["unavailableLanes"], [])
        self.assertEqual(differential_exit(report), 0)

    def test_unavailable_reference_exits_one(self) -> None:
        report = self.report(False)
        self.assertEqual(report["unavailableLanes"], ["lean"])
        self.assertEqual(differential_exit(report), 1)


class HostFailureMatrixExit(unittest.TestCase):
    def test_every_lane_available_exits_zero(self) -> None:
        self.assertEqual(matrix_exit({"errorRows": [], "unobservedRuntimes": []}), 0)

    def test_error_row_exits_one(self) -> None:
        self.assertEqual(matrix_exit({"errorRows": ["Start/java"], "unobservedRuntimes": []}), 1)

    def test_unobserved_runtime_exits_one(self) -> None:
        self.assertEqual(matrix_exit({"errorRows": [], "unobservedRuntimes": ["java"]}), 1)


def matrix_row(runtime: str, real: dict) -> dict:
    return {"constructor": "Start", "runtime": runtime, "testOnlyPort": False, "mock": {}, "real": real}


EVIDENCE = {"cause": "Start", "peerReceivedCount": 1, "issuedCommandCount": 1}


def named_row(runtime: str, constructor: str, **real) -> dict:
    return {"constructor": constructor, "runtime": runtime, "testOnlyPort": False, "mock": {}, "real": {"cause": constructor.split("(", 1)[0], **real}}


def declared_exception_rows() -> list[dict]:
    return [
        named_row(runtime, name, **declared)
        for (runtime, name), declared in host_failure_matrix.DECLARED_CAUSE_EXCEPTIONS.items()
    ]


def conforming_rows() -> list[dict]:
    names = ("Start", "CancellationRejected(ForeignCapability)", "ResponseHeadersFailed", "MalformedResponse")
    declared = host_failure_matrix.DECLARED_CAUSE_EXCEPTIONS
    rows = [
        named_row(runtime, name)
        for runtime in host_failure_matrix.RUNTIMES
        for name in names
        if (runtime, name.split("(", 1)[0]) not in declared
    ]
    return rows + declared_exception_rows()


def findings(rows: list[dict]) -> tuple[list, list]:
    return host_failure_matrix.cause_declaration_findings(rows)


def replaced(rows: list[dict], runtime: str, name: str, **real) -> list[dict]:
    return [
        {**row, "real": {**row["real"], **real}}
        if (row["runtime"], row["constructor"]) == (runtime, name)
        else row
        for row in rows
    ]


class HostFailureMatrixRows(unittest.TestCase):
    def exit_for(self, rows: list[dict], *arguments: str) -> int:
        with mock.patch.object(host_failure_matrix, "rows", return_value=iter(rows)), \
                mock.patch.object(sys, "argv", ["check", "--all", "--assert-counts", *arguments]), \
                contextlib.redirect_stdout(io.StringIO()):
            return host_failure_matrix.main()

    def all_lanes(self, real: dict) -> list[dict]:
        return [matrix_row(lane, real) for lane in host_failure_matrix.RUNTIMES] + declared_exception_rows()

    def test_rows_with_evidence_exit_zero(self) -> None:
        self.assertEqual(self.exit_for(self.all_lanes(EVIDENCE)), 0)

    def test_a_row_of_an_unusable_lane_exits_one(self) -> None:
        rows = [matrix_row("java", {"error": "ExecutableUnavailable:javac"})] + self.all_lanes(EVIDENCE)[1:]
        self.assertEqual(self.exit_for(rows), 1)

    def test_rows_of_only_unusable_lanes_exit_one(self) -> None:
        self.assertEqual(self.exit_for(self.all_lanes({"error": "lane unavailable"})), 1)

    def test_peer_count_above_dispatch_count_exits_one(self) -> None:
        injected = {"cause": "Start", "peerReceivedCount": 2, "issuedCommandCount": 1}
        rows = [matrix_row("gleam", injected)] + self.all_lanes(EVIDENCE)[1:]
        self.assertEqual(self.exit_for(rows), 1)

    def test_no_rows_exit_one(self) -> None:
        self.assertEqual(self.exit_for([]), 1)

    def test_a_subset_of_the_runtimes_exits_one(self) -> None:
        rows = [matrix_row("python", EVIDENCE)]
        self.assertEqual(self.exit_for(rows, "--runtime", "python"), 1)


class CauseDeclarationFindings(unittest.TestCase):
    def test_conforming_rows_leave_both_findings_empty(self) -> None:
        self.assertEqual(findings(conforming_rows()), ([], []))

    def test_undeclared_cause_difference_is_reported(self) -> None:
        rows = replaced(conforming_rows(), "gleam", "CancellationRejected(ForeignCapability)", cause=None, outcomeTag="Cancelled")
        undeclared, violations = findings(rows)
        self.assertEqual([(row["runtime"], row["constructor"]) for row in undeclared], [("gleam", "CancellationRejected(ForeignCapability)")])
        self.assertEqual(violations, [])

    def test_changed_effect_reason_of_declared_row_is_reported(self) -> None:
        rows = replaced(conforming_rows(), "java", "ResponseHeadersFailed", effectReason="HostFailure")
        undeclared, violations = findings(rows)
        self.assertEqual(undeclared, [])
        self.assertEqual([(row["runtime"], row["constructor"]) for row in violations], [("java", "ResponseHeadersFailed")])

    def test_declared_row_returning_its_own_cause_is_reported(self) -> None:
        rows = replaced(conforming_rows(), "java", "ResponseHeadersFailed", cause="ResponseHeadersFailed")
        undeclared, violations = findings(rows)
        self.assertEqual(undeclared, [])
        self.assertEqual([(row["runtime"], row["constructor"]) for row in violations], [("java", "ResponseHeadersFailed")])

    def test_missing_declared_row_is_reported(self) -> None:
        rows = [row for row in conforming_rows() if (row["runtime"], row["constructor"]) != ("gleam", "MalformedResponse")]
        undeclared, violations = findings(rows)
        self.assertEqual(undeclared, [])
        self.assertEqual([(row["runtime"], row["constructor"]) for row in violations], [("gleam", "MalformedResponse")])

    def test_a_row_without_a_cause_is_compared_by_its_outcome_tag(self) -> None:
        name = "DeadlineExceeded(BeforeDispatch)"
        outcome = {"cause": None, "outcomeTag": "DeadlineExceeded"}
        rows = conforming_rows() + [named_row(runtime, name, **outcome) for runtime in host_failure_matrix.RUNTIMES]
        self.assertEqual(findings(rows), ([], []))
        wrong = replaced(rows, "rust", name, outcomeTag="Failed")
        undeclared, _ = findings(wrong)
        self.assertEqual([(row["runtime"], row["constructor"]) for row in undeclared], [("rust", name)])

    def test_a_request_received_before_dispatch_deadline_exits_one(self) -> None:
        name = "DeadlineExceeded(BeforeDispatch)"
        real = {"outcomeTag": "DeadlineExceeded", "effectReason": "Deadline", "peerReceivedCount": 0, "peerAcceptedCount": 0}
        rows = [named_row(runtime, name, **{**real, "cause": None}) for runtime in host_failure_matrix.RUNTIMES]
        self.assertEqual(host_failure_matrix.before_dispatch_violations(rows), [])
        late = replaced(rows, "java", name, peerReceivedCount=1, peerAcceptedCount=1)
        self.assertEqual([row["runtime"] for row in host_failure_matrix.before_dispatch_violations(late)], ["java"])
        connected = replaced(rows, "rust", name, peerAcceptedCount=1)
        self.assertEqual([row["runtime"] for row in host_failure_matrix.before_dispatch_violations(connected)], ["rust"])
        unobserved = replaced(rows, "python", name, peerAcceptedCount=None)
        self.assertEqual([row["runtime"] for row in host_failure_matrix.before_dispatch_violations(unobserved)], ["python"])
        self.assertEqual(matrix_exit({"errorRows": [], "unobservedRuntimes": [], "beforeDispatchViolations": [{"runtime": "java"}]}), 1)

    def test_runtime_not_run_is_not_checked(self) -> None:
        rows = [row for row in conforming_rows() if row["runtime"] != "gleam"]
        self.assertEqual(host_failure_matrix.cause_declaration_findings(rows, ("python", "rust", "typescript", "java")), ([], []))


if __name__ == "__main__":
    unittest.main()
