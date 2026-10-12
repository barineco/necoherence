// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

public final class SemanticGraphemeTest {
    private static void equal(Object actual, Object expected) {
        if (!Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected);
    }
    private static WireValue library(WireValue profile) {
        WireValue library = SemanticLibraryFixture.library();
        WireValue shape = variant("String", obj("format", NIL,
                "lengths", arr(List.of(obj("unit",variant("Graphemes"),"minimum",str("1"),"maximum",str("4")))),
                "wrapper",NIL,"const_value", NIL, "enum_values", NIL,
                "examples", arr(List.of()), "default_value", NIL));
        return TypeSignatures.replace(TypeSignatures.replace(TypeSignatures.replace(TypeSignatures.replace(
                TypeSignatures.replace(library, "profile", profile), "groups", arr(List.of())), "annotations", arr(List.of())),
                "nodes", arr(List.of(obj("id", str("text"), "shape", shape)))),
                "definitions", arr(List.of(obj("id", str("text"), "wire_identity", str("text"), "shape", variant("Value", str("text"))))));
    }
    private static SemanticGeneration.CheckedGeneration admit(WireValue profile) throws Exception {
        WireValue library = library(profile), entries = arr(List.of(obj("identity", str("text"), "definition", str("text"))));
        var basis = TypeSignatures.basis(encodeWire(library), encodeWire(entries));
        return TypeSignatures.admitGeneration(basis, encodeWire(obj("schema", str("ncoh-checked-generation@4"),
                "basis", TypeSignatures.parseWire(basis.encode()), "signatures", library, "composition", NIL, "entrypoints", entries)));
    }
    private static void rejectProfile(WireValue profile, String path) throws Exception {
        try { admit(profile); throw new AssertionError("accepted invalid profile"); }
        catch (SemanticGeneration.GenerationFailure failure) { equal(failure.path(), path); }
    }
    public static void main(String[] args) throws Exception {
        WireValue old = TypeSignatures.parseWire(Files.readString(Path.of("typescript/tests/synthetic-profile.json")));
        WireValue profile=TypeSignatures.replace(TypeSignatures.replace(f(SemanticLibraryFixture.library(),"profile"),
                "source_refs",f(old,"source_refs")),"grapheme_rules",f(old,"grapheme_rules"));
        GraphemeRules rules = admit(profile).valueContext().graphemeRules();
        equal(rules.component(), new GraphemeComponent("16.0.0", "45", "C1-1-default-extended-grapheme-cluster-no-tailoring"));
        WireValue unicode = f(profile, "grapheme_rules");
        equal(rules.tableSha256(), s(f(unicode, "table_sha256")));
        List<GraphemeSource> expectedSources = new ArrayList<>();
        for (WireValue row : a(f(unicode, "sources"))) {
            WireValue ref = f(f(row, "origin"), "source");
            expectedSources.add(new GraphemeSource(s(f(row, "role")), new SourceRef(s(f(ref, "repository")),
                    s(f(ref, "revision")), s(f(ref, "path")), s(f(ref, "content_digest")))));
        }
        equal(rules.sources(), expectedSources);
        equal(rules.sources().size(), 6);
        equal(graphemeBoundaries(rules, ""), List.of());
        equal(graphemeCount(rules, ""), 0);
        int cases = 0;
        for (String line : Files.readAllLines(Path.of("comparison/declaration/semantic_profile_data/GraphemeBreakTest.txt"))) {
            String body = line.split("#", 2)[0].trim();
            if (body.isEmpty()) continue;
            StringBuilder text = new StringBuilder();
            List<Integer> boundaries = new ArrayList<>();
            int offset = 0;
            for (String token : body.split("\\s+")) {
                if (token.equals("÷")) boundaries.add(offset);
                else if (!token.equals("×")) { text.appendCodePoint(Integer.parseInt(token, 16)); offset++; }
            }
            equal(graphemeBoundaries(rules, text.toString()), boundaries);
            equal(graphemeCount(rules, text.toString()), boundaries.size() - 1);
            cases++;
        }
        equal(cases, 1093);
        System.out.println("Unicode 16 official GraphemeBreakTest vectors: 1093 boundary/count cases passed; @4 metadata passed");
    }
}
