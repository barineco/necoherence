// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

public final class SealedLeafSampleVectorsTest {
    private static Context context(WireValue profile, WireValue sealed) throws Exception {
        WireValue library = obj("schema", str("ncoh-type-signatures@1"),
                "identity", str("sealed-leaf-samples"), "revision", str("1"), "profile", profile,
                "sources", arr(List.of()), "provenance", arr(List.of()), "groups", arr(List.of()),
                "annotations", arr(List.of()), "nodes", arr(List.of(obj("id", str("value"), "shape", sealed))),
                "definitions", arr(List.of(obj("id", str("value"), "wire_identity", str("value"),
                        "shape", variant("Value", str("value"))))));
        WireValue entries = arr(List.of(obj("identity", str("value"), "definition", str("value"))));
        GenerationBasis basis = TypeSignatures.basis(encodeWire(library), encodeWire(entries));
        WireValue exchange = obj("schema", str("ncoh-checked-generation@4"), "basis", readJson(basis.encode()),
                "signatures", library, "composition", NIL, "entrypoints", entries);
        return TypeSignatures.admitGeneration(basis, encodeWire(exchange)).valueContext();
    }

    @TestFactory
    List<DynamicTest> sealedLeafSamplesMatchLean() throws Exception {
        WireValue vectors = readJson(Files.readString(Path.of("../comparison/declaration/sealed_leaf_sample_vectors.json")));
        assertEquals("sealed-leaf-sample-vectors@1", s(f(vectors, "schema")));
        List<WireValue> cases = a(f(vectors, "cases"));
        assertEquals(7, cases.size());
        List<DynamicTest> tests = new ArrayList<>();
        for (WireValue testCase : cases) {
            tests.add(DynamicTest.dynamicTest(s(f(testCase, "id")), () -> {
                Context context = context(f(vectors, "profile"), f(testCase, "sealed"));
                WireValue root = TypeSignatures.typeReference("value");
                List<WireValue> actual = sampleValueFuel(context, root, 2, 32).values();
                List<WireValue> expected = a(f(testCase, "expected"));
                assertEquals(expected.size(), actual.size());
                for (int index = 0; index < actual.size(); index++) {
                    context.validate(root, actual.get(index));
                    ObjectValue expectedObject = o(expected.get(index)), actualObject = o(actual.get(index));
                    assertEquals(expectedObject.members().size(), actualObject.members().size());
                    for (Member member : expectedObject.members())
                        assertEquals(member.value(), actualObject.get(member.key()), member.key());
                }
            }));
        }
        return tests;
    }
}
