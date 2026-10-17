// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

public final class WrapperBase64VectorsTest {
    private static Context context(WireValue profile, WireValue graph) throws Exception {
        WireValue root = f(graph, "root");
        WireValue library = obj("schema", str("ncoh-type-signatures@1"),
                "identity", str("wrapper-base64"), "revision", str("1"), "profile", profile,
                "sources", arr(List.of()), "provenance", arr(List.of()), "groups", arr(List.of()),
                "annotations", arr(List.of()), "nodes", f(graph, "nodes"),
                "definitions", arr(List.of(obj("id", str("value"), "wire_identity", str("value"),
                        "shape", variant("Value", root)))));
        WireValue entries = arr(List.of(obj("identity", str("value"), "definition", str("value"))));
        GenerationBasis basis = TypeSignatures.basis(encodeWire(library), encodeWire(entries));
        WireValue exchange = obj("schema", str("ncoh-checked-generation@4"), "basis", readJson(basis.encode()),
                "signatures", library, "composition", NIL, "entrypoints", entries);
        return TypeSignatures.admitGeneration(basis, encodeWire(exchange)).valueContext();
    }

    private static WireValue condition(String condition) {
        int separator = condition.indexOf(": ");
        return separator < 0 ? variant(condition)
                : variant(condition.substring(0, separator), str(condition.substring(separator + 2)));
    }

    private static WireValue outcome(Context context, WireValue root, WireValue input) throws Exception {
        try {
            context.validate(root, input);
            return obj("accepted", new BooleanValue(true), "condition", NIL, "path", arr(List.of()));
        } catch (ValueFailure failure) {
            assertTrue(failure.obligations().isEmpty(), failure.getMessage());
            return obj("accepted", new BooleanValue(false), "condition", condition(failure.condition()),
                    "path", arr(failure.path()));
        }
    }

    @TestFactory
    List<DynamicTest> wrapperAndBase64ResultsMatchLean() throws Exception {
        WireValue vectors = readJson(Files.readString(Path.of("../comparison/declaration/wrapper_base64_vectors.json")));
        assertEquals("wrapper-base64-vectors@1", s(f(vectors, "schema")));
        List<WireValue> branches = a(f(vectors, "branches"));
        assertEquals(25, branches.size());
        Set<String> branchIds = new HashSet<>();
        List<DynamicTest> tests = new ArrayList<>();
        for (WireValue branch : branches) {
            String branchId = s(f(branch, "id"));
            assertTrue(branchIds.add(branchId), branchId);
            WireValue profile = f(f(vectors, "profiles"), s(f(branch, "profile")));
            WireValue graph = f(f(vectors, "type_graphs"), s(f(branch, "type_graph")));
            Context context = context(profile, graph);
            WireValue root = TypeSignatures.typeReference(s(f(graph, "root")));
            List<WireValue> cases = a(f(branch, "cases"));
            assertFalse(cases.isEmpty(), branchId);
            Set<String> caseIds = new HashSet<>();
            for (WireValue testCase : cases) {
                String caseId = s(f(testCase, "id"));
                assertTrue(caseIds.add(caseId), caseId);
                tests.add(DynamicTest.dynamicTest(caseId, () -> {
                    WireValue input = f(testCase, "input");
                    WireValue expected = f(testCase, "expected");
                    assertEquals(expected, outcome(context, root, input));
                    if (tag(context.resolve(root)).equals("Bytes")) {
                        if (b(f(expected, "accepted"))) {
                            Bytes decoded = context.decodeBytes(root, input);
                            String text = wrapDecode(profile, s(f(f(profile, "bytes_policy"), "wrapper")), input);
                            assertArrayEquals(Base64.getDecoder().decode(text.replace('-', '+').replace('_', '/')),
                                    decoded.value());
                            assertEquals(input, context.encodeBytes(decoded));
                        } else {
                            ValueFailure failure = assertThrows(ValueFailure.class, () -> context.decodeBytes(root, input));
                            assertEquals(f(expected, "condition"), condition(failure.condition()));
                            assertEquals(f(expected, "path"), arr(failure.path()));
                        }
                    }
                }));
            }
        }
        assertEquals(55, tests.size());
        return tests;
    }
}
