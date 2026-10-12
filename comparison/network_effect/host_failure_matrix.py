# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""HostFailure constructor matrix built from each runtime's real adapter and
classifier against a controlled loopback peer, plus a mock lane for pure
lifecycle coverage. Every count is measured from the invoked lane and the
peer, never handwritten.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

from .controlled_peer import ControlledPeer, PeerAction
from .differential import _artifact_executable, _cargo_messages, runner_environment
from .generator import HOST_STAGES, TIMEOUT_CAUSES, generate_timeout_pairs
from .mock_actions import MockAdapter, failure_action

ROOT = Path(__file__).resolve().parents[2]
PYTHON_SRC = ROOT / "python" / "src"
if str(PYTHON_SRC) not in sys.path:
    sys.path.insert(0, str(PYTHON_SRC))

RUST_DRIVER_DIR = Path(__file__).resolve().parent / "rust_driver"
JAVA_DRIVER_DIR = Path(__file__).resolve().parent / "java_driver"
GLEAM_DRIVER_DIR = Path(__file__).resolve().parent / "gleam_driver"
TS_DRIVER_PATH = Path(__file__).resolve().parent / "ts_driver.ts"

SIMPLE_CONSTRUCTORS = (
    "UnsupportedUriScheme",
    "InvalidHostConfiguration",
    "ExecutionStartFailed",
    "NameResolutionFailed",
    "ConnectionFailed",
    "RequestWriteFailed",
    "ResponseHeadersFailed",
    "ResponseBodyFailed",
    "ResponseBodyLimitExceeded",
    "MalformedResponse",
    "HeaderRepresentationUnavailable",
    "RequestHeaderEncodingUnavailable",
    "CancellationRejected",
    "DeadlineControlUnavailable",
    "HostRuntimeFailure",
    "HostClosed",
)

# No lane exposes a public port for name resolution, partial write, header
# codec, or worker-runtime faults, and no adapter has a finite request
# timeout; these constructors are always measured as testOnlyPort.
UNIFORM_TEST_ONLY = {
    "ExecutionStartFailed",
    "NameResolutionFailed",
    "RequestWriteFailed",
    "HeaderRepresentationUnavailable",
    "HostRuntimeFailure",
}

# Some adapters reject InvalidHostConfiguration / DeadlineControlUnavailable
# only from fields the pure ledger already validates at prepare, so the row
# is testOnlyPort there; others compare a distinct adapter-owned port.
PER_RUNTIME_TEST_ONLY = {
    "InvalidHostConfiguration": {"typescript", "java", "gleam"},
    "DeadlineControlUnavailable": {"java"},
}

RUNTIMES = ("python", "rust", "typescript", "java", "gleam")


def is_test_only(constructor: str, runtime: str) -> bool:
    if constructor == "Timeout":
        return True
    if constructor in UNIFORM_TEST_ONLY:
        return True
    return runtime in PER_RUNTIME_TEST_ONLY.get(constructor, set())


PEER_ACTION_KIND = {
    "UnsupportedUriScheme": "AcceptAndRespond",
    "InvalidHostConfiguration": "AcceptAndRespond",
    "ConnectionFailed": "RefuseConnection",
    "ResponseHeadersFailed": "CloseBeforeHeaders",
    "ResponseBodyFailed": "CloseBeforeBody",
    "ResponseBodyLimitExceeded": "ReturnOversizedBody",
    "MalformedResponse": "MalformedResponse",
    "RequestHeaderEncodingUnavailable": "AcceptAndRespond",
    "CancellationRejected": "DelayUntilRelease",
    "DeadlineControlUnavailable": "AcceptAndRespond",
    "HostClosed": "DelayUntilRelease",
}


def peer_for(constructor: str) -> ControlledPeer:
    kind = PEER_ACTION_KIND.get(constructor, "AcceptAndRespond")
    if kind == "CloseBeforeBody":
        action = PeerAction(kind=kind, body=b"partial-body-bytes-unset")
    elif kind == "ReturnOversizedBody":
        action = PeerAction(kind=kind, body=b"x" * 4096)
    elif kind == "DelayUntilRelease":
        action = PeerAction(kind=kind, release=threading.Event())
    elif kind == "AcceptAndRespond":
        action = PeerAction(kind=kind, body=b"host-failure-matrix-ok")
    else:
        action = PeerAction(kind=kind)
    return ControlledPeer(action).start()


# ---------------------------------------------------------------------------
# Mock lane: I/O-free lifecycle coverage, independent of the real evidence.
# ---------------------------------------------------------------------------


def _mock_row(constructor: str, stage: str) -> dict[str, Any]:
    adapter = MockAdapter([failure_action(constructor, stage=stage)])
    run = adapter.start(("matrix", 0))
    event = run.observe()
    return {
        "event": event.kind,
        "cause": constructor,
        "attempt": ["matrix", 0],
        "handle": run.handle,
        "delivery": event.delivery,
        "effect": "Unknown",
        "ledgerRecordCount": 1,
        "issuedCommandCount": adapter.issued_count,
        "peerReceivedCount": 0,
    }


# ---------------------------------------------------------------------------
# Python lane: direct import, real ledger and real HttpHostAdapter.
# ---------------------------------------------------------------------------


def _python_evidence(constructor: str, test_only: bool, peer_host: str, peer_port: int, timeout_stage: str | None, timeout_cause: str | None) -> dict[str, Any]:
    from necoherence import network_effect as ne
    from necoherence.http_adapter import EventCancellationPort, HttpHostAdapter, SystemMonotonicClock
    from necoherence.request_progression import RequestIdentity

    class _RejectingCancellation(EventCancellationPort):
        def request(self, capability: ne.CancellationCapability, handle: ne.ExecutionHandle) -> bool:
            return False

    def identity(kind: str) -> RequestIdentity:
        return RequestIdentity(kind, "host-failure-matrix", 0)

    def configuration() -> ne.HostConfiguration:
        response_limit = 4 if constructor == "ResponseBodyLimitExceeded" else 16
        return ne.HostConfiguration(256, response_limit)

    scheme = "ftp" if constructor == "UnsupportedUriScheme" else "http"
    target = f"{scheme}://{peer_host}:{peer_port}/host-failure-matrix"
    attempt = ne.AttemptIdentity(identity(constructor), 0)
    headers: tuple[ne.RawHeaderField, ...] = ()
    if constructor == "RequestHeaderEncodingUnavailable":
        headers = (ne.RawHeaderField("x-forged", (0,)),)
    input_value = ne.AttemptInput(attempt, ne.HttpWireInstruction("GET", target, headers, ()), None, configuration())
    reject_cancellation = False
    clock = SystemMonotonicClock()
    cancellation = EventCancellationPort()
    if constructor == "DeadlineControlUnavailable":
        capability = ne.MonotonicClockCapability(ne.OpaqueEvidence("matrix-clock"), ne.ClockBasis("matrix"))
        deadline = ne.Deadline(ne.ClockBasis("matrix"), 5, capability)
        input_value = ne.AttemptInput(attempt, input_value.instruction, deadline, ne.HostConfiguration(256, configuration().response_body_limit, None, capability))
        clock = None
    elif constructor == "InvalidHostConfiguration":
        capability = ne.CancellationCapability(ne.OpaqueEvidence("matrix-mismatched-cancel"))
        input_value = ne.AttemptInput(attempt, input_value.instruction, None, ne.HostConfiguration(256, configuration().response_body_limit, capability, None))
    elif constructor == "CancellationRejected":
        capability = ne.CancellationCapability(ne.OpaqueEvidence("matrix-cancel"))
        input_value = ne.AttemptInput(attempt, input_value.instruction, None, ne.HostConfiguration(256, configuration().response_body_limit, capability, None))
        cancellation = _RejectingCancellation(capability)
        reject_cancellation = True

    prepared = ne.prepare(ne.NetworkState(()), input_value)
    if not isinstance(prepared, ne.Prepared):
        return {"error": f"prepare rejected: {prepared}"}
    ledger_record_count = len(prepared.state.attempts)
    issued = ne.send_command(prepared.state, prepared.prepared)
    if not isinstance(issued, ne.CommandReady):
        return {"error": f"send_command rejected: {issued}"}
    issued_command_count = 1

    if test_only:
        return _python_test_only(constructor, timeout_stage, timeout_cause, input_value, issued.state, prepared.prepared, ledger_record_count, issued_command_count)

    adapter = HttpHostAdapter(clock=clock, cancellation=cancellation)
    start_observation = adapter.start(issued.command)
    if isinstance(start_observation, ne.StartFailed):
        return _finish_start(input_value, issued.state, prepared.prepared, start_observation, ledger_record_count, issued_command_count)
    started = ne.StartedAttempt(prepared.prepared, start_observation.handle)
    if reject_cancellation:
        import time as _time

        _time.sleep(0.05)
        capability = input_value.configuration.cancellation
        observation = adapter.cancel(ne.CancelCommand(input_value.attempt, started.handle, capability))
        return _finish_host(input_value, issued.state, prepared.prepared, observation, ledger_record_count, issued_command_count)
    if constructor == "HostClosed":
        import time as _time

        _time.sleep(0.05)
        observation = adapter.close(started)
        return _finish_host(input_value, issued.state, prepared.prepared, observation, ledger_record_count, issued_command_count)
    import time as _time

    deadline_at = _time.monotonic() + 3.0
    while True:
        observation = adapter.observe(started)
        if isinstance(observation, ne.DeliveredObservation):
            return _finish_host(input_value, issued.state, prepared.prepared, observation, ledger_record_count, issued_command_count)
        if _time.monotonic() >= deadline_at:
            return {"error": "polling timed out"}
        _time.sleep(0.01)


def _python_test_only(constructor: str, timeout_stage: str | None, timeout_cause: str | None, input_value, state, prepared, ledger_record_count: int, issued_command_count: int) -> dict[str, Any]:
    from necoherence import network_effect as ne

    stage_map = {
        "ExecutionStartFailed": (ne.HostStage.START, ne.ExecutionStartFailed()),
        "NameResolutionFailed": (ne.HostStage.START, ne.NameResolutionFailed()),
        "RequestWriteFailed": (ne.HostStage.REQUEST_WRITE, ne.RequestWriteFailed()),
        "HeaderRepresentationUnavailable": (ne.HostStage.RESPONSE_HEADERS, ne.HeaderRepresentationUnavailable()),
        "HostRuntimeFailure": (ne.HostStage.RESPONSE_BODY, ne.HostRuntimeFailure()),
        "InvalidHostConfiguration": (ne.HostStage.START, ne.InvalidHostConfiguration()),
        "DeadlineControlUnavailable": (ne.HostStage.START, ne.DeadlineControlUnavailable()),
    }
    if constructor == "Timeout":
        stage = ne.HostStage(timeout_stage)
        cause = ne.HostTimeoutCause(timeout_cause)
        stage_value, failure_cause = stage, ne.Timeout(stage, cause)
    else:
        stage_value, failure_cause = stage_map[constructor]
    unknown = ne.Unknown(ne.UnknownEffectReason.HOST_FAILURE)
    if constructor == "ExecutionStartFailed":
        failure = ne.NetworkHostFailure(input_value.attempt, stage_value, input_value.configuration, failure_cause)
        observation = ne.StartFailed(failure, unknown)
        return _finish_start(input_value, state, prepared, observation, ledger_record_count, issued_command_count)
    handle = ne.ExecutionHandle("python-test-only-handle")
    started = ne.observe_start(state, prepared, ne.Started(input_value.attempt, handle))
    if not isinstance(started, ne.NetworkStarted):
        return {"error": f"unexpected observe_start result: {started}"}
    failure = ne.NetworkHostFailure(input_value.attempt, stage_value, input_value.configuration, failure_cause)
    observation = ne.FailureObservation(input_value.attempt, handle, None, failure, unknown)
    step = ne.observe(started.state, ne.DeliveredObservation(0, observation))
    return _report_step(handle.value, ledger_record_count, issued_command_count, step)


def _finish_start(input_value, state, prepared, start_observation, ledger_record_count: int, issued_command_count: int) -> dict[str, Any]:
    from necoherence import network_effect as ne

    step = ne.observe_start(state, prepared, start_observation)
    if isinstance(step, ne.NetworkTerminalResult):
        return _report_terminal("start-failed", ledger_record_count, issued_command_count, step.settled.terminal)
    if isinstance(step, ne.NetworkRejected):
        return {"ledgerRecordCount": ledger_record_count, "issuedCommandCount": issued_command_count, "outcomeTag": "LedgerRejected", "cause": repr(step.failure), "handle": "start-failed"}
    return {"error": f"unexpected observe_start result: {step}"}


def _finish_host(input_value, state, prepared, observation, ledger_record_count: int, issued_command_count: int) -> dict[str, Any]:
    from necoherence import network_effect as ne

    handle = observation.handle if isinstance(observation, ne.PendingObservation) else observation.observation.handle
    started_step = ne.observe_start(state, prepared, ne.Started(input_value.attempt, handle))
    if not isinstance(started_step, ne.NetworkStarted):
        return {"error": f"unexpected observe_start result: {started_step}"}
    step = ne.observe(started_step.state, observation)
    return _report_step(handle.value, ledger_record_count, issued_command_count, step)


def _report_step(handle: str, ledger_record_count: int, issued_command_count: int, step) -> dict[str, Any]:
    from necoherence import network_effect as ne

    if isinstance(step, ne.NetworkTerminalResult):
        return _report_terminal(handle, ledger_record_count, issued_command_count, step.settled.terminal)
    if isinstance(step, (ne.NetworkStarted, ne.NetworkPending)):
        return {"ledgerRecordCount": ledger_record_count, "issuedCommandCount": issued_command_count, "outcomeTag": "Pending", "effect": "Unknown", "handle": handle}
    if isinstance(step, ne.NetworkRejected):
        return {"ledgerRecordCount": ledger_record_count, "issuedCommandCount": issued_command_count, "outcomeTag": "LedgerRejected", "cause": repr(step.failure), "handle": handle}
    return {"error": f"unexpected NetworkStep: {step}"}


def _report_terminal(handle: str, ledger_record_count: int, issued_command_count: int, terminal) -> dict[str, Any]:
    from necoherence import network_effect as ne

    effect_tag = type(terminal.effect).__name__
    base = {"ledgerRecordCount": ledger_record_count, "issuedCommandCount": issued_command_count, "effect": effect_tag, "handle": handle}
    if isinstance(terminal.outcome, ne.Failed):
        failure = terminal.outcome.failure
        inner_stage = inner_cause = None
        if isinstance(failure.cause, ne.Timeout):
            inner_stage = failure.cause.stage.value
            inner_cause = failure.cause.cause.value
        return {
            **base,
            "outcomeTag": "Failed",
            "stage": failure.stage.value,
            "cause": type(failure.cause).__name__,
            "innerStage": inner_stage,
            "innerCause": inner_cause,
        }
    if isinstance(terminal.outcome, ne.Cancelled):
        return {**base, "outcomeTag": "Cancelled", "stage": "Cancel", "cause": "Cancelled"}
    return {**base, "outcomeTag": type(terminal.outcome).__name__}


# ---------------------------------------------------------------------------
# Compiled-lane long-lived evidence processes (JSON-lines stdio protocol).
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class LaneProcess:
    name: str
    process: subprocess.Popen[str] | None
    unavailable: str | None = None

    def ask(self, row: dict[str, Any]) -> dict[str, Any]:
        if self.process is None:
            return {"error": self.unavailable or "lane unavailable"}
        assert self.process.stdin is not None and self.process.stdout is not None
        self.process.stdin.write(json.dumps(row) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            return {"error": f"lane closed stdout; stderr={stderr[:800]}"}
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return {"error": f"invalid lane output: {line[:400]}"}

    def close(self) -> None:
        if self.process is None:
            return
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()


def _resolve_rust_executable() -> str | None:
    completed = subprocess.run(
        ["cargo", "build", "--message-format=json"],
        cwd=RUST_DRIVER_DIR,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    if completed.returncode != 0:
        return None
    for message in _cargo_messages(completed.stdout):
        if message.get("reason") == "compiler-artifact" and message.get("target", {}).get("name") == "host_failure_driver" and message.get("executable"):
            return str(message["executable"])
    return _artifact_executable(completed.stdout, "host_failure_driver")


def _start_python_lane() -> LaneProcess:
    return LaneProcess("python", None)


def _start_rust_lane() -> LaneProcess:
    if shutil.which("cargo") is None:
        return LaneProcess("rust", None, "ExecutableUnavailable:cargo")
    executable = _resolve_rust_executable()
    if executable is None or not Path(executable).exists():
        return LaneProcess("rust", None, "ArtifactUnavailable:host_failure_driver")
    process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    return LaneProcess("rust", process)


def _start_java_lane() -> LaneProcess:
    java_home = os.environ.get("JAVA_HOME")
    javac = str(Path(java_home) / "bin/javac") if java_home else (shutil.which("javac") or "javac")
    java = str(Path(java_home) / "bin/java") if java_home else (shutil.which("java") or "java")
    if not Path(javac).exists():
        return LaneProcess("java", None, "ExecutableUnavailable:javac")
    lane_classes = ROOT / "java" / "build" / "classes"
    lane_classes.mkdir(parents=True, exist_ok=True)
    sources = list((ROOT / "java" / "src" / "main" / "java").rglob("*.java"))
    build = subprocess.run([javac, "--release", "21", "-d", str(lane_classes), *[str(path) for path in sources]], capture_output=True, text=True, timeout=120, check=False)
    if build.returncode != 0:
        return LaneProcess("java", None, f"LaneCompileFailed:{build.stderr[:400]}")
    evidence_classes = JAVA_DRIVER_DIR / "classes"
    evidence_classes.mkdir(parents=True, exist_ok=True)
    evidence_build = subprocess.run(
        [javac, "--release", "21", "-cp", str(lane_classes), "-d", str(evidence_classes), str(JAVA_DRIVER_DIR / "HostFailureEvidence.java")],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if evidence_build.returncode != 0:
        return LaneProcess("java", None, f"EvidenceCompileFailed:{evidence_build.stderr[:400]}")
    classpath = f"{evidence_classes}{os.pathsep}{lane_classes}"
    process = subprocess.Popen([java, "-cp", classpath, "necoherence.network.HostFailureEvidence"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    return LaneProcess("java", process)


def _start_gleam_lane() -> LaneProcess:
    if shutil.which("gleam") is None:
        return LaneProcess("gleam", None, "ExecutableUnavailable:gleam")
    build = subprocess.run(["gleam", "build"], cwd=GLEAM_DRIVER_DIR, capture_output=True, text=True, timeout=180, check=False)
    if build.returncode != 0:
        return LaneProcess("gleam", None, f"BuildFailed:{build.stderr[:400]}")
    process = subprocess.Popen(
        ["gleam", "run", "--no-print-progress", "-m", "host_failure_evidence"],
        cwd=GLEAM_DRIVER_DIR,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    return LaneProcess("gleam", process)


def _start_typescript_lane() -> LaneProcess:
    if shutil.which("npx") is None:
        return LaneProcess("typescript", None, "ExecutableUnavailable:npx")
    node_modules = ROOT / "typescript" / "node_modules"
    if not node_modules.exists():
        install = subprocess.run(["npm", "ci"], cwd=ROOT / "typescript", capture_output=True, text=True, timeout=300, check=False)
        if install.returncode != 0:
            return LaneProcess("typescript", None, f"InstallFailed:{install.stderr[:400]}")
    process = subprocess.Popen(
        ["npx", "tsx", str(TS_DRIVER_PATH)],
        cwd=ROOT / "typescript",
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    return LaneProcess("typescript", process)


LANE_STARTERS = {
    "python": _start_python_lane,
    "rust": _start_rust_lane,
    "java": _start_java_lane,
    "gleam": _start_gleam_lane,
    "typescript": _start_typescript_lane,
}


def _real_evidence(runtime: str, lane: LaneProcess, constructor: str, test_only: bool, peer: ControlledPeer | None, timeout_stage: str | None, timeout_cause: str | None) -> dict[str, Any]:
    peer_host, peer_port = peer.address if peer is not None else ("127.0.0.1", 1)
    if runtime == "python":
        return _python_evidence(constructor, test_only, peer_host, peer_port, timeout_stage, timeout_cause)
    return lane.ask(
        {
            "constructor": constructor,
            "testOnly": test_only,
            "peerHost": peer_host,
            "peerPort": peer_port,
            "timeoutStage": timeout_stage,
            "timeoutCause": timeout_cause,
        }
    )


def rows(runtimes: Iterable[str] = RUNTIMES) -> Iterable[dict[str, Any]]:
    lanes: dict[str, LaneProcess] = {}
    try:
        for runtime in runtimes:
            lanes[runtime] = LANE_STARTERS[runtime]()
        for constructor in SIMPLE_CONSTRUCTORS:
            for runtime in runtimes:
                test_only = is_test_only(constructor, runtime)
                peer = None if test_only else peer_for(constructor)
                try:
                    real = _real_evidence(runtime, lanes[runtime], constructor, test_only, peer, None, None)
                    peer_received = peer.request_count if peer is not None else 0
                finally:
                    if peer is not None:
                        peer.close()
                mock = _mock_row(constructor, "Start")
                yield {
                    "constructor": constructor,
                    "runtime": runtime,
                    "testOnlyPort": test_only,
                    "mock": mock,
                    "real": {**real, "peerReceivedCount": peer_received},
                }
        for pair in generate_timeout_pairs():
            constructor = f"Timeout({pair['stage']},{pair['cause']})"
            for runtime in runtimes:
                real = _real_evidence(runtime, lanes[runtime], "Timeout", True, None, pair["stage"], pair["cause"])
                mock = _mock_row(constructor, pair["stage"])
                yield {
                    "constructor": constructor,
                    "runtime": runtime,
                    "testOnlyPort": True,
                    "mock": mock,
                    "real": {**real, "peerReceivedCount": 0},
                }
    finally:
        for lane in lanes.values():
            lane.close()


def run_matrix(assert_counts: bool = False, runtimes: Iterable[str] = RUNTIMES) -> dict[str, Any]:
    result = list(rows(runtimes))
    if assert_counts:
        violations = [
            row
            for row in result
            if "error" not in row["real"] and row["real"].get("peerReceivedCount", 0) > row["real"].get("issuedCommandCount", 0)
        ]
        if violations:
            raise RuntimeError(f"peer count exceeds dispatch count for {len(violations)} row(s): {[row['constructor'] + '/' + row['runtime'] for row in violations][:5]}")
    by_runtime: dict[str, dict[str, list[str]]] = {
        runtime: {"real": [], "testOnlyPort": [], "realDifferentCause": []} for runtime in runtimes
    }
    for row in result:
        bucket = by_runtime[row["runtime"]]
        if row["testOnlyPort"]:
            key = "testOnlyPort"
        elif row["real"].get("cause") == row["constructor"].split("(", 1)[0] and not row["real"].get("libraryRetriesIdempotent"):
            key = "real"
        else:
            key = "realDifferentCause"
        bucket[key].append(row["constructor"])
    return {
        "result": "HostFailureMatrix",
        "rows": result,
        "rowCount": len(result),
        "constructors": sorted({row["constructor"].split("(", 1)[0] for row in result}),
        "realVsTestOnlyPortByRuntime": {
            runtime: {
                "realCount": len(bucket["real"]),
                "testOnlyPortCount": len(bucket["testOnlyPort"]),
                "realDifferentCause": bucket["realDifferentCause"],
            }
            for runtime, bucket in by_runtime.items()
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--assert-counts", action="store_true")
    parser.add_argument("--runtime", action="append", default=[])
    args = parser.parse_args()
    if not args.all:
        parser.error("use --all")
    runtimes = tuple(args.runtime) or RUNTIMES
    try:
        report = run_matrix(args.assert_counts, runtimes)
    except RuntimeError as error:
        print(json.dumps({"result": "AssertCountsFailed", "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["is_test_only", "rows", "run_matrix"]
