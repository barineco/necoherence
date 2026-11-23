// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import neco.quotient.Result;
import neco.quotient.encoding.Encoding;
import neco.quotient.encoding.EncodingFailure;
import neco.quotient.encoding.JsonValue;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticTypes.SemanticObligation;
import org.junit.jupiter.api.Test;

final class SemanticResidualRecordTest {
    private static final WireValue SOURCE = obj("repository", str("r"), "revision", str("1"), "path", str("p"),
            "content_digest", str("0".repeat(64)), "document_id", str("d"), "declared_revision", NIL);

    private static WireValue ref(String name) { return obj("source", SOURCE, "definition_name", str(name), "pointer", arr(List.of())); }

    private static SemanticObligation obligation(String name, WireValue reason) {
        return SemanticGraphWire.obligation(obj("type_ref", ref(name), "origin", obj("source", SOURCE, "pointer", arr(List.of())),
                "value_path", arr(List.of(variant("Field", str("a")), variant("Index", str("3")))),
                "profile", obj("identity", str("p"), "revision", str("1"), "content_digest", str("1".repeat(64))),
                "reason", reason), "$");
    }

    private static GenerationBasis basis() throws Exception {
        WireValue basis = obj("signature_schema", str("ncoh-type-signatures@1"), "library_identity", str("l"),
                "library_revision", str("4"),
                "profile", obj("identity", str("p"), "revision", str("1"), "content_digest", str("1".repeat(64))),
                "graph_sha256", str("1".repeat(64)), "provenance_sha256", str("2".repeat(64)),
                "metadata_sha256", str("3".repeat(64)), "problem_sha256", NIL, "observations_sha256", NIL,
                "entrypoints_sha256", str("6".repeat(64)));
        return GenerationBasis.ofInput(obj("basis", basis, "composition", NIL));
    }

    private static TypeRef typeRef() { return SemanticGraphWire.typeRef(ref("root"), "$"); }

    private static ExactJson.JsonValue value() {
        return new ExactJson.JsonObj(List.of(
                new ExactJson.JsonMember("count", new ExactJson.JsonNum(new BigInteger("12345678901234567890"))),
                new ExactJson.JsonMember("items", new ExactJson.JsonArr(List.of(
                        new ExactJson.JsonNum(BigInteger.valueOf(-7)),
                        new ExactJson.JsonObj(List.of(new ExactJson.JsonMember("inner", new ExactJson.JsonStr("x")))))))));
    }

    private static List<SemanticObligation> obligations() {
        return List.of(obligation("a", variant("OpaqueType", str("external"))),
                obligation("b", variant("MissingBytesPolicy")),
                obligation("c", variant("UnresolvedType")));
    }

    private static byte[] encode(List<SemanticObligation> items) throws Exception {
        Result<byte[], EncodingFailure> result = SemanticResidualRecord.encodeSemanticResidual(basis(), typeRef(), value(), items);
        return switch (result) {
            case Result.Accepted<byte[], EncodingFailure> accepted -> accepted.value();
            case Result.Rejected<byte[], EncodingFailure> failed -> throw new AssertionError(failed.error());
        };
    }

    private static JsonValue decode(byte[] bytes) {
        return switch (Encoding.decodeCanonical(bytes)) {
            case neco.quotient.encoding.Result.Accepted<JsonValue, EncodingFailure> accepted -> accepted.value();
            case neco.quotient.encoding.Result.Rejected<JsonValue, EncodingFailure> failed -> throw new AssertionError(failed.error());
        };
    }

    private static JsonValue field(JsonValue object, String key) {
        return ((JsonValue.Obj) object).fields().stream().filter(item -> item.key().equals(key)).findFirst().orElseThrow().value();
    }

    private static boolean containsNumber(JsonValue value) {
        return switch (value) {
            case JsonValue.Number unused -> true;
            case JsonValue.Arr array -> array.items().stream().anyMatch(SemanticResidualRecordTest::containsNumber);
            case JsonValue.Obj object -> object.fields().stream().anyMatch(item -> containsNumber(item.value()));
            default -> false;
        };
    }

    @Test void obligationOrderAndRepetitionDoNotChangeTheBytes() throws Exception {
        List<SemanticObligation> items = obligations();
        List<SemanticObligation> reversed = new ArrayList<>(items);
        java.util.Collections.reverse(reversed);
        List<SemanticObligation> repeated = new ArrayList<>(items);
        repeated.add(items.get(0));
        byte[] expected = encode(items);
        assertArrayEquals(expected, encode(reversed));
        assertArrayEquals(expected, encode(repeated));
    }

    @Test void decodedRecordHasFourFieldsAndTheDistinctObligations() throws Exception {
        List<SemanticObligation> repeated = new ArrayList<>(obligations());
        repeated.add(obligations().get(1));
        JsonValue record = decode(encode(repeated));
        assertEquals(List.of("basis", "input", "residuals", "schema"),
                ((JsonValue.Obj) record).fields().stream().map(JsonValue.Field::key).sorted().toList());
        assertEquals(new JsonValue.Text(SemanticResidualRecord.SCHEMA), field(record, "schema"));
        assertEquals(3, ((JsonValue.Arr) field(record, "residuals")).items().size());
    }

    @Test void valueFieldIsTaggedRecordsWithoutJsonNumbers() throws Exception {
        JsonValue record = decode(encode(obligations()));
        JsonValue value = field(field(record, "input"), "value");
        assertFalse(containsNumber(record));
        assertEquals(new JsonValue.Text("Object"), field(value, "tag"));
        JsonValue count = ((JsonValue.Arr) field(value, "members")).items().get(0);
        assertEquals(new JsonValue.Text("count"), field(count, "key"));
        assertEquals(new JsonValue.Obj(List.of(new JsonValue.Field("tag", new JsonValue.Text("Integer")),
                new JsonValue.Field("value", new JsonValue.Text("12345678901234567890")))), field(count, "value"));
        assertTrue(((JsonValue.Arr) field(value, "members")).items().stream()
                .anyMatch(member -> field(member, "key").equals(new JsonValue.Text("items"))));
    }
}
