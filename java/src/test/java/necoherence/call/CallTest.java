// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.call;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.util.List;
import necoherence.call.Call.CallResult;
import necoherence.call.Call.Request;
import org.junit.jupiter.api.Test;

/**
 * Tests translating python/tests/test_call.py.
 *
 * <p>Projection checks field-name presence on a {@link Request}, not the nominal {@code Req}
 * type: a value can satisfy {@code Req} at compile time while still lacking a required field
 * name in {@link Request#fields()}, exactly as the Python and Rust declarations model it.
 */
final class CallTest {

    interface GreetReq {
        String name();
    }

    record NameOnly(String name) implements GreetReq {
    }

    private static String greet(GreetReq req) {
        return "hello " + req.name();
    }

    @Test
    void ioOutputsWhenInputIsSatisfied() {
        Immediate<GreetReq, String> decl = Call.immediateOf("test.greet", List.of("name"), CallTest::greet);
        CallResult<String> result = Call.io(decl, new Request<>(new NameOnly("world"), List.of("name")));
        CallResult.Ok<String> ok = assertInstanceOf(CallResult.Ok.class, result);
        assertEquals("hello world", ok.value());
    }

    @Test
    void ioAcceptsExtraFieldsBeyondRequired() {
        Immediate<GreetReq, String> decl = Call.immediateOf("test.greet", List.of("name"), CallTest::greet);
        CallResult<String> result =
                Call.io(decl, new Request<>(new NameOnly("world"), List.of("name", "extra")));
        CallResult.Ok<String> ok = assertInstanceOf(CallResult.Ok.class, result);
        assertEquals("hello world", ok.value());
    }

    @Test
    void ioFailsWhenARequiredFieldNameIsAbsent() {
        Immediate<GreetReq, String> decl = Call.immediateOf("test.greet", List.of("name"), CallTest::greet);
        CallResult<String> result = Call.io(decl, new Request<>(new NameOnly("world"), List.of()));
        CallResult.Failed<String> failed = assertInstanceOf(CallResult.Failed.class, result);
        assertEquals("test.greet", failed.failure().declaration());
        assertEquals(List.of("name"), failed.failure().fields());
    }

    @Test
    void immediateOfRecordsIdentityAndRequired() {
        Immediate<GreetReq, String> decl = Call.immediateOf("test.greet", List.of("name"), CallTest::greet);
        assertEquals("test.greet", decl.identity());
        assertEquals(List.of("name"), decl.required());
    }

    @Test
    void issueCallsADeferredDeclarationAndReturnsItsSlot() {
        Deferred<GreetReq, String> stage =
                Call.deferredOf("test.stage", List.of("name"), req -> "staged:" + req.name());
        CallResult<String> result = Call.issue(stage, new Request<>(new NameOnly("x"), List.of("name")));
        CallResult.Ok<String> ok = assertInstanceOf(CallResult.Ok.class, result);
        assertEquals("staged:x", ok.value());
    }

    @Test
    void issueFailsWhenARequiredFieldNameIsAbsent() {
        Deferred<GreetReq, String> stage =
                Call.deferredOf("test.stage", List.of("name"), req -> "staged:" + req.name());
        CallResult<String> result = Call.issue(stage, new Request<>(new NameOnly("x"), List.of()));
        CallResult.Failed<String> failed = assertInstanceOf(CallResult.Failed.class, result);
        assertEquals("test.stage", failed.failure().declaration());
        assertEquals(List.of("name"), failed.failure().fields());
    }

    @Test
    void projectionFailedNamesTheDeclarationAndEveryMissingField() {
        ProjectionFailed failure = new ProjectionFailed("test.combine", List.of("a", "b"));
        assertEquals("test.combine", failure.declaration());
        assertEquals(List.of("a", "b"), failure.fields());
    }

    @Test
    void boundaryDiagnosisCarriesOutboundExpectationObserved() {
        BoundaryDiagnosis<String, List<String>, String> diagnosis =
                new BoundaryDiagnosis<>("q", List.of("Known"), "seen");
        assertEquals("q", diagnosis.outbound());
        assertEquals(List.of("Known"), diagnosis.expectation());
        assertEquals("seen", diagnosis.observed());
    }

    @Test
    void ioAndIssueAreDistinctAtTheTypeLevel() {
        // Immediate<Req, Prd> and Deferred<Req, Slot> are distinct nominal
        // types with no subtyping between them; io accepts only Immediate
        // and issue accepts only Deferred. There is no runtime assertion to
        // make here: passing a Deferred to io fails at compile time, the
        // same guarantee Rust and mypy --strict give.
        Immediate<GreetReq, String> imm = Call.immediateOf("test.greet", List.of("name"), CallTest::greet);
        Deferred<GreetReq, String> def =
                Call.deferredOf("test.stage", List.of("name"), req -> "staged:" + req.name());
        CallResult<String> ioResult = Call.io(imm, new Request<>(new NameOnly("world"), List.of("name")));
        CallResult<String> issueResult = Call.issue(def, new Request<>(new NameOnly("x"), List.of("name")));
        assertEquals("hello world", ((CallResult.Ok<String>) ioResult).value());
        assertEquals("staged:x", ((CallResult.Ok<String>) issueResult).value());
    }
}
