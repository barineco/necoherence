// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Objects;

public final class SemanticFormatTest {
    private static final String VALID_IDENTIFIER = "alpha-123";
    private static final List<String> IDENTIFIER_VALUES = List.of(VALID_IDENTIFIER, "beta", "", "-bad", "UPPER", "bad!", "reserved", "資料", "a".repeat(64));

    private static void equal(Object actual, Object expected) {
        if (!Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected);
    }
    private static void nullRejected(Runnable action, String parameter) {
        try {
            action.run();
            throw new AssertionError("accepted null " + parameter);
        } catch (NullPointerException expected) {
            equal(expected.getMessage(), parameter);
        }
    }
    private static void check(Context context, WireValue identifierType) throws Exception {
        equal(context.formatDefined("identifier"), true);
        equal(context.formatDefined("unknown-format"), false);
        equal(context.formatDefined("Identifier"), false);
        equal(context.formatDefined(""), false);
        equal(context.recognizeFormat("identifier", VALID_IDENTIFIER), true);
        equal(context.recognizeFormat("identifier", "bad!"), false);
        equal(context.recognizeFormat("unknown-format", VALID_IDENTIFIER), false);
        equal(context.recognizeFormat("unknown-format", "invalid"), false);
        for (String value : IDENTIFIER_VALUES) {
            boolean accepted;
            try {
                context.validate(identifierType, str(value));
                accepted = true;
            } catch (ValueFailure failure) {
                equal(failure.condition(), "Format: identifier");
                accepted = false;
            }
            equal(context.recognizeFormat("identifier", value), accepted);
            equal(context.recognizeFormat("identifier", value), accepted);
        }
        nullRejected(() -> context.formatDefined(null), "name");
        nullRejected(() -> context.recognizeFormat(null, VALID_IDENTIFIER), "name");
        nullRejected(() -> context.recognizeFormat("identifier", null), "value");
        nullRejected(() -> context.recognizeFormat("unknown-format", null), "value");
    }
    private static void signatures() throws Exception {
        WireValue old = TypeSignatures.parseWire(Files.readString(Path.of("typescript/tests/synthetic-profile.json")));
        WireValue profile = f(SemanticLibraryFixture.library(),"profile");
        WireValue identifier=a(f(old,"format_bindings")).stream().filter(row->s(f(row,"name")).equals("identifier")).findFirst().orElseThrow();
        List<WireValue> bindings=new java.util.ArrayList<>(a(f(profile,"format_bindings")));bindings.add(identifier);
        profile=TypeSignatures.replace(profile,"format_bindings",arr(bindings));
        WireValue shape = variant("String", obj("format", variant("Named",str("identifier")), "lengths", arr(List.of()),
                "wrapper", NIL, "const_value", NIL, "enum_values", NIL,
                "examples", arr(List.of()), "default_value", NIL));
        WireValue library = obj("schema", str("ncoh-type-signatures@1"), "identity", str("format-test"), "revision", str("1"),
                "profile", profile, "sources", arr(List.of()), "provenance", arr(List.of()), "groups", arr(List.of()),
                "annotations", arr(List.of()), "nodes", arr(List.of(obj("id", str("identifier-value"), "shape", shape))),
                "definitions", arr(List.of(obj("id", str("value"), "wire_identity", str("FormatValue"), "shape", variant("Value", str("identifier-value"))))));
        WireValue entries = arr(List.of(obj("identity", str("value"), "definition", str("value"))));
        GenerationBasis basis = TypeSignatures.basis(encodeWire(library), encodeWire(entries));
        WireValue exchange = obj("schema", str("ncoh-checked-generation@4"), "basis", readJson(basis.encode()),
                "signatures", library, "composition", NIL, "entrypoints", entries);
        Context context = TypeSignatures.admitGeneration(basis, encodeWire(exchange)).valueContext();
        for (WireValue binding : a(f(profile, "format_bindings"))) equal(context.formatDefined(s(f(binding, "name"))), true);
        check(context, TypeSignatures.typeReference("identifier-value"));
        List<WireValue> retained=a(f(profile,"format_bindings")).stream().filter(row->!s(f(row,"name")).equals("identifier")).toList();
        WireValue emptyLibrary = TypeSignatures.replace(library, "profile", TypeSignatures.replace(profile, "format_bindings", arr(retained)));
        emptyLibrary = TypeSignatures.replace(emptyLibrary, "nodes", arr(List.of(obj("id", str("identifier-value"), "shape", TypeSignatures.replace(shape, "value", TypeSignatures.replace(payload(shape), "format", NIL))))));
        GenerationBasis emptyBasis = TypeSignatures.basis(encodeWire(emptyLibrary), encodeWire(entries));
        WireValue emptyExchange = TypeSignatures.replace(TypeSignatures.replace(exchange, "basis", readJson(emptyBasis.encode())), "signatures", emptyLibrary);
        Context empty = TypeSignatures.admitGeneration(emptyBasis, encodeWire(emptyExchange)).valueContext();
        equal(empty.formatDefined("identifier"), false);
        equal(empty.recognizeFormat("identifier", VALID_IDENTIFIER), false);
    }
    private static WireValue literal(String text) { return variant("Literal", str(text)); }
    private static WireValue sequence(WireValue... parts) { return variant("Sequence", arr(List.of(parts))); }
    @org.junit.jupiter.api.Test void atprotoUriFormatAcceptsDidAuthorityAndRejectsMissingSchemeOrWhitespace() throws Exception {
        WireValue profile = TypeSignatures.parseWire(Files.readString(Path.of("../presets/atproto-data-model/profile.json")));
        WireValue rule = a(f(profile, "format_bindings")).stream()
                .filter(binding -> s(f(binding, "name")).equals("uri"))
                .map(binding -> f(binding, "rule"))
                .findFirst()
                .orElseThrow();
        equal(recognize(rule, "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self"), true);
        equal(recognize(rule, "https://example.com/has space"), false);
        equal(recognize(rule, "example.com/path"), false);
    }
    private static void sequenceGrouping() {
        WireValue first = variant("Choice", arr(List.of(literal(""), literal("a"))));
        WireValue second = variant("Optional", literal("😀"));
        WireValue third = literal("!");
        List<WireValue> rules = List.of(
                sequence(first, second, third),
                sequence(sequence(first, second), third),
                sequence(first, sequence(second, third)),
                sequence(sequence(), first, second, sequence(third), sequence()));
        for (String text : List.of("", "!", "a!", "😀!", "a😀!", "aa!", "😀a!", "a😀", "x!")) {
            for (WireValue rule : rules) equal(recognize(rule, text), List.of("!", "a!", "😀!", "a😀!").contains(text));
        }
        equal(recognize(sequence(), ""), true);
        equal(recognize(sequence(), "a"), false);
        WireValue negated = sequence(literal("["), variant("Not", sequence(literal("a"), literal("😀"))), literal("]"));
        equal(recognize(negated, "[]"), true);
        equal(recognize(negated, "[😀]"), true);
        equal(recognize(negated, "[a😀]"), false);
    }
    private static void sequenceLabelOffsets() {
        WireValue child = sequence(variant("Optional", literal("a")), literal("😀"));
        WireValue inner = obj("tag", str("Labels"), "fields", obj("separator", str("🔹"),
                "min_count", str("2"), "max_count", str("2"), "total_max", str("4"), "rule", child));
        WireValue rule = sequence(literal("["), inner, literal("]"));
        for (String text : List.of("[😀🔹a😀]", "[a😀🔹😀]")) equal(recognize(rule, text), true);
        for (String text : List.of("[😀🔹b😀]", "[😀🔹😀🔹😀]", "[a😀🔹a😀]")) equal(recognize(rule, text), false);
        WireValue bounded = obj("tag", str("Bounded"), "fields", obj("unit", variant("Utf8Bytes"),
                "maximum", str("15"), "rule", rule));
        equal(recognize(bounded, "[😀🔹a😀]"), true);
        bounded = TypeSignatures.replace(bounded, "fields", TypeSignatures.replace(f(bounded, "fields"), "maximum", str("14")));
        equal(recognize(bounded, "[😀🔹a😀]"), false);
    }
    @org.junit.jupiter.api.Test void sequenceGroupingPreservesConcatenation() { sequenceGrouping(); }
    @org.junit.jupiter.api.Test void sequenceLabelsPreserveScalarOffsets() { sequenceLabelOffsets(); }
    @org.junit.jupiter.api.Test void flatSequenceWith600PartsPreservesAcceptanceAndRejection() {
        WireValue[] parts = new WireValue[600];
        java.util.Arrays.fill(parts, literal(""));
        WireValue rule = sequence(parts);
        equal(recognize(rule, ""), true);
        equal(recognize(rule, "x"), false);
        WireValue[] extended = java.util.Arrays.copyOf(parts, 601);
        extended[600] = literal("x");
        WireValue suffix = sequence(extended);
        equal(recognize(suffix, "x"), true);
        equal(recognize(suffix, ""), false);
    }
    public static void main(String[] args) throws Exception {
        signatures();
        sequenceGrouping();
        sequenceLabelOffsets();
        System.out.println("public format API: @4 admitted profiles, identifier validation parity, unknown formats, binding scope, and null contracts passed");
    }
}
