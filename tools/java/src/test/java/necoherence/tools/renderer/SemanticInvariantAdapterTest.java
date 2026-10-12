// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import necoherence.semantic.SemanticLibraryFixture;
import static necoherence.semantic.SemanticGeneration.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.ArrayList;

public final class SemanticInvariantAdapterTest {
    private static void assertEquals(Object expected, Object actual) {
        if (!java.util.Objects.equals(expected, actual)) throw new AssertionError("expected " + expected + ", observed " + actual);
    }
    private static void assertTrue(boolean condition) {
        if (!condition) throw new AssertionError("invariant failed");
    }
    public static void main(String[] args) throws Exception {
        signatureOriginsPreserveLocatorAndRejectSourceRefRows();
        adapterAdmitsOriginProfileAndObservesGraphemeRules();
        generatedCollectionsPreserveTypedFailurePaths();
        inclusionRefutationAddsTopLevelProductExtensionOnly();
        inclusionWitnessFromCandidatesPrecedesAbsentSlot();
        System.out.println("Origin profile: locator roundtrip, legacy source rejection and grapheme invariants passed");
    }
    private static WireValue library() throws Exception {
        WireValue profile = SemanticLibraryFixture.library(); profile=f(profile, "profile");
        WireValue reference=f(profile,"reference"); List<WireValue> sourceRefs=new ArrayList<>(), graphemeSources=new ArrayList<>();
        for(int i=0;i<6;i++){ WireValue source=obj("repository",str("owner"),"revision",str("1"),"path",str("source"+i),"content_digest",str(String.valueOf((char)('a'+i)).repeat(64))); sourceRefs.add(source); graphemeSources.add(obj("role",str("role"+i),"origin",obj("source",source,"locator",arr(List.of(str("root")))))); }
        WireValue properties=arr(List.of(obj("first",str("0"),"last",str("9"),"property",variant("Control"))));
        WireValue extended=arr(List.of(obj("first",str("169"),"last",str("169"))));
        WireValue indic=arr(List.of(obj("first",str("768"),"last",str("879"),"property",variant("Extend"))));
        WireValue grapheme=obj("reference",reference,"component",obj("unicode_version",str("16.0.0"),"uax29_revision",str("45"),"cluster_profile",str("test")),"table_sha256",str("e5343b68458affff3579b3453dda0053e283b94190412d673114a5d6080db48d"),"sources",arr(graphemeSources),"properties",properties,"extended_pictographic",extended,"indic_conjunct",indic);
        profile=TypeSignatures.replace(TypeSignatures.replace(profile,"source_refs",arr(sourceRefs)),"grapheme_rules",grapheme);
        return obj("schema", str("ncoh-type-signatures@1"), "identity", str("invariant-test"), "revision", str("1"),
                "profile", profile, "sources", arr(List.of()), "provenance", arr(List.of()), "groups", arr(List.of()),
                "annotations", arr(List.of()), "nodes", arr(List.of(obj("id", str("value"), "shape",
                variant("Boolean", obj("const_value", NIL, "default_value", NIL))))),
                "definitions", arr(List.of(obj("id", str("value"), "wire_identity", str("InvariantValue"),
                "shape", variant("Value", str("value"))))));
    }

    private static void signatureOriginsPreserveLocatorAndRejectSourceRefRows() throws Exception {
        WireValue library = library();
        WireValue profile = f(library, "profile"), rules = f(profile, "grapheme_rules");
        WireValue first = a(f(rules, "sources")).getFirst();
        WireValue origin = TypeSignatures.replace(f(first, "origin"), "locator", arr(List.of(str("資料"), str("property"))));
        WireValue rows = arr(a(f(rules, "sources")).stream().map(row -> row == first
                ? TypeSignatures.replace(row, "origin", origin) : row).toList());
        library = TypeSignatures.replace(library, "profile", TypeSignatures.replace(profile, "grapheme_rules",
                TypeSignatures.replace(rules, "sources", rows)));
        var decoded = TypeSignatures.TypeSignatureLibrary.decode(encodeWire(library));
        WireValue decodedOrigin = f(a(f(f(f(TypeSignatures.parseWire(decoded.encode()), "profile"), "grapheme_rules"), "sources")).getFirst(), "origin");
        assertEquals(origin, decodedOrigin);
        assertEquals(decoded.encode(), TypeSignatures.TypeSignatureLibrary.decode(decoded.encode()).encode());
        WireValue legacyRows = arr(a(rows).stream().map(row -> obj("role", f(row, "role"),
                "source", f(f(row, "origin"), "source"))).toList());
        WireValue legacy = TypeSignatures.replace(library, "profile", TypeSignatures.replace(f(library, "profile"),
                "grapheme_rules", TypeSignatures.replace(f(f(library, "profile"), "grapheme_rules"), "sources", legacyRows)));
        try {
            TypeSignatures.TypeSignatureLibrary.decode(encodeWire(legacy));
            throw new AssertionError("legacy grapheme source admitted");
        } catch (GenerationFailure expected) {
            assertTrue(!expected.condition().isEmpty());
        }
    }

    private static void adapterAdmitsOriginProfileAndObservesGraphemeRules() throws Exception {
        WireValue library = library();
        SemanticInvariantAdapter adapter = new SemanticInvariantAdapter();
        for (String text : List.of("", "a\u0308", "👩\u200d💻", "\r\n", "🇯🇵")) {
            WireValue result = adapter.evaluate(obj("id", str("grapheme"), "kind", str("grapheme"), "library", library,
                    "type_id", str("value"), "text", str(text)));
            List<WireValue> boundaries = a(f(result, "boundaries"));
            int count = n(f(result, "count")).intValueExact();
            assertEquals(Math.max(0, boundaries.size() - 1), count);
            if (text.isEmpty()) assertTrue(boundaries.isEmpty());
            else {
                assertEquals(0, n(boundaries.getFirst()).intValueExact());
                assertEquals(text.codePointCount(0, text.length()), n(boundaries.getLast()).intValueExact());
                for (int i = 1; i < boundaries.size(); i++)
                    assertTrue(n(boundaries.get(i - 1)).compareTo(n(boundaries.get(i))) < 0);
            }
        }
    }

    private static void generatedCollectionsPreserveTypedFailurePaths() throws Exception {
        WireValue base = library();
        WireValue truthNode=obj("id", str("truth"), "shape", variant("Boolean", obj("const_value", NIL, "default_value", NIL)));
        WireValue arrayValueNode=obj("id", str("array"), "shape", variant("Array",
                obj("item", obj("type_id",str("truth"),"nullable",new BooleanValue(false)), "min_length", NIL, "max_length", NIL)));
        WireValue productValueNode=obj("id", str("product"), "shape", variant("Product",
                obj("fields", arr(List.of(
                        obj("wire_name", str("field"), "slot", obj("type_id", str("truth"), "required", new BooleanValue(true), "nullable", new BooleanValue(false))),
                        obj("wire_name", str("0"), "slot", obj("type_id", str("truth"), "required", new BooleanValue(true), "nullable", new BooleanValue(false))))),
                        "extras",variant("Reject"))));
        WireValue nodes = arr(List.of(truthNode,arrayValueNode,productValueNode));
        WireValue definitions = arr(List.of(
                obj("id", str("array"), "wire_identity", str("ArrayValue"), "shape", variant("Value", str("array"))),
                obj("id", str("product"), "wire_identity", str("ProductValue"), "shape", variant("Value", str("product")))));
        WireValue library = TypeSignatures.replace(TypeSignatures.replace(base, "nodes", nodes), "definitions", definitions);
        try (SemanticInvariantAdapter adapter = new SemanticInvariantAdapter()) {
            WireValue array = adapter.evaluate(obj("id", str("array"), "kind", str("codec"), "library", library,
                    "type_id", str("array"), "value", arr(List.of(str("wrong")))));
            assertEquals(arr(List.of(num(java.math.BigInteger.ZERO))), f(array, "path"));
            WireValue product = adapter.evaluate(obj("id", str("product"), "kind", str("codec"), "library", library,
                    "type_id", str("product"), "value", obj("field", new BooleanValue(true), "0", str("wrong"))));
            assertEquals(arr(List.of(str("0"))), f(product, "path"));
            WireValue value = obj("field", new BooleanValue(true), "0", new BooleanValue(false));
            WireValue roundtrip = adapter.evaluate(obj("id", str("roundtrip"), "kind", str("codec"), "library", library,
                    "type_id", str("product"), "value", value));
            assertEquals(str("Accepted"), f(roundtrip, "status"));
            assertEquals(value, f(roundtrip, "encoded"));
        }
    }

    private static WireValue textNode() {
        return obj("id", str("text"), "shape", variant("String", obj("format", NIL, "lengths", arr(List.of()),
                "wrapper", NIL, "const_value", NIL, "enum_values", NIL,
                "examples", arr(List.of()), "default_value", NIL)));
    }
    private static WireValue fieldOf(String name, String type, boolean required) {
        return obj("wire_name", str(name), "slot", obj("type_id", str(type), "required", new BooleanValue(required), "nullable", new BooleanValue(false)));
    }
    private static WireValue productNode(String id, WireValue... fields) {
        return obj("id", str(id), "shape", variant("Product", obj("fields", arr(List.of(fields)),"extras",fields("Allow",obj("key_format",NIL,"value",obj("type_id",str("text"),"nullable",new BooleanValue(true)))))));
    }
    private static WireValue arrayNode(String id, String item) {
        return obj("id", str(id), "shape", variant("Array", obj("item", obj("type_id",str(item),"nullable",new BooleanValue(false)), "min_length", NIL, "max_length", NIL)));
    }
    private static WireValue inclusionOf(SemanticInvariantAdapter adapter, WireValue base, List<WireValue> nodes) throws Exception {
        WireValue library = TypeSignatures.replace(TypeSignatures.replace(base, "nodes", arr(nodes)), "definitions",
                arr(List.of(obj("id", str("destination"), "wire_identity", str("InclusionDestination"), "shape", variant("Value", str("destination"))))));
        WireValue source = obj("type_id", str("source"), "required", new BooleanValue(true), "nullable", new BooleanValue(false));
        WireValue destination = obj("type_id", str("destination"), "required", new BooleanValue(true), "nullable", new BooleanValue(false));
        return adapter.evaluate(obj("id", str("inclusion"), "kind", str("inclusion"), "library", library,
                "source", source, "destination", destination, "candidates", arr(List.of())));
    }
    private static void inclusionRefutationAddsTopLevelProductExtensionOnly() throws Exception {
        WireValue base = library();
        try (SemanticInvariantAdapter adapter = new SemanticInvariantAdapter()) {
            WireValue top = inclusionOf(adapter, base, List.of(textNode(),
                    productNode("source", fieldOf("a", "text", true)),
                    productNode("destination", fieldOf("a", "text", true), fieldOf("b", "text", false))));
            assertEquals(str("Incompatible"), f(top, "classification"));
            assertEquals(obj("tag", str("Present"), "value", obj("b", NIL, "a", str("x"))), f(top, "value"));
            assertEquals(arr(List.of(str("b"))), f(top, "path"));
            assertEquals(str("NullNotAllowed"), f(top, "condition"));
            List<WireValue> inner = List.of(textNode(),
                    productNode("inner_source", fieldOf("x", "text", true)),
                    productNode("inner_destination", fieldOf("x", "text", true), fieldOf("y", "text", false)));
            List<WireValue> nested = new ArrayList<>(inner);
            nested.add(productNode("source", fieldOf("inner", "inner_source", true)));
            nested.add(productNode("destination", fieldOf("inner", "inner_destination", true)));
            assertEquals(str("Unknown"), f(inclusionOf(adapter, base, nested), "classification"));
            List<WireValue> items = new ArrayList<>(inner);
            items.add(arrayNode("source", "inner_source"));
            items.add(arrayNode("destination", "inner_destination"));
            assertEquals(str("Unknown"), f(inclusionOf(adapter, base, items), "classification"));
        }
    }
    private static void inclusionWitnessFromCandidatesPrecedesAbsentSlot() throws Exception {
        WireValue base = library();
        WireValue enumerated = obj("id", str("destination"), "shape", variant("String", obj("format", NIL, "lengths", arr(List.of()),
                "wrapper", NIL, "const_value", NIL, "enum_values", arr(List.of(str("y"))),
                "examples", arr(List.of()), "default_value", NIL)));
        WireValue plain = obj("id", str("source"), "shape", f(textNode(), "shape"));
        WireValue library = TypeSignatures.replace(TypeSignatures.replace(base, "nodes", arr(List.of(plain, enumerated))), "definitions",
                arr(List.of(obj("id", str("destination"), "wire_identity", str("InclusionDestination"), "shape", variant("Value", str("destination"))))));
        WireValue source = obj("type_id", str("source"), "required", new BooleanValue(false), "nullable", new BooleanValue(false));
        WireValue destination = obj("type_id", str("destination"), "required", new BooleanValue(true), "nullable", new BooleanValue(false));
        try (SemanticInvariantAdapter adapter = new SemanticInvariantAdapter()) {
            WireValue result = adapter.evaluate(obj("id", str("candidate_before_absent"), "kind", str("inclusion"), "library", library,
                    "source", source, "destination", destination, "candidates", arr(List.of(str("x")))));
            assertEquals(str("Incompatible"), f(result, "classification"));
            assertEquals(obj("tag", str("Present"), "value", str("x")), f(result, "value"));
        }
    }
}
