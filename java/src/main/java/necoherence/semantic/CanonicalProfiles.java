// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

final class CanonicalProfiles {
    private CanonicalProfiles() {}

    static WireValue admit(WireValue expectedReference, List<WireValue> expectedSources,
            byte[] trustedBytes, byte[] inputBytes) throws GenerationFailure {
        Objects.requireNonNull(expectedReference, "expectedReference");
        Objects.requireNonNull(expectedSources, "expectedSources");
        Objects.requireNonNull(trustedBytes, "trustedBytes");
        Objects.requireNonNull(inputBytes, "inputBytes");
        require(Arrays.equals(trustedBytes, inputBytes), "$canonical", "trusted/input bytes mismatch");
        try {
            WireValue profile = canonical(readJson(utf8(inputBytes)), "ValueProfile", "$canonical.profile");
            WireValue reference = profileReference(expectedReference, "$expected");
            require(f(profile, "reference").equals(reference), "$canonical.profile.reference", "expected reference");
            List<WireValue> sources = new ArrayList<>();
            for (int i = 0; i < expectedSources.size(); i++)
                sources.add(sourceIdentity(expectedSources.get(i), "$expectedSources[" + i + "]"));
            require(a(f(profile, "source_refs")).equals(sources), "$canonical.profile.source_refs", "expected sources");
            TypeSignatures.checkProfile(profile);
            return profile;
        } catch (GenerationFailure failure) {
            throw failure;
        } catch (RuntimeException failure) {
            throw new GenerationFailure("$canonical", failure.getMessage() == null ? failure.getClass().getSimpleName() : failure.getMessage());
        }
    }

    private static String utf8(byte[] bytes) throws GenerationFailure {
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException failure) {
            throw new GenerationFailure("$canonical", "UTF-8 JSON");
        }
    }

    private static WireValue profileReference(WireValue value, String path) throws GenerationFailure {
        exact(value, path, Set.of("identity", "revision", "content_digest"));
        text(f(value, "identity"), path + ".identity");
        text(f(value, "revision"), path + ".revision");
        text(f(value, "content_digest"), path + ".content_digest");
        return value;
    }

    private static WireValue sourceIdentity(WireValue value, String path) throws GenerationFailure {
        exact(value, path, Set.of("repository", "revision", "path", "content_digest"));
        for (String field : List.of("repository", "revision", "path", "content_digest")) text(f(value, field), path + "." + field);
        return value;
    }

    private static void checkBasis(WireValue basis, WireValue reference, List<WireValue> sources) throws GenerationFailure {
        exact(basis, "$.basis", Set.of("identity", "revision", "sources"));
        require(s(f(basis, "identity")).equals(s(f(reference, "identity")))
                && s(f(basis, "revision")).equals(s(f(reference, "revision"))), "$.basis", "expected profile identity and revision");
        List<WireValue> actual = array(f(basis, "sources"), "$.basis.sources");
        require(actual.size() == sources.size(), "$.basis.sources", "expected sources");
        for (int i = 0; i < actual.size(); i++) {
            WireValue row = actual.get(i), expected = sources.get(i);
            String path = "$.basis.sources[" + i + "]";
            exact(row, path, Set.of("repository", "revision", "path", "sha256"));
            require(s(f(row, "repository")).equals(s(f(expected, "repository")))
                    && s(f(row, "revision")).equals(s(f(expected, "revision")))
                    && s(f(row, "path")).equals(s(f(expected, "path")))
                    && s(f(row, "sha256")).equals(s(f(expected, "content_digest"))), path, "expected source identity");
        }
    }

    private static WireValue decodeGrapheme(WireValue value, WireValue reference, List<WireValue> expectedSources) throws GenerationFailure {
        exact(value, "$.grapheme", Set.of("version", "properties", "extended_pictographic", "indic_conjunct", "uax29_revision",
                "profile", "ranges", "sources", "table_sha256"));
        BigInteger uax29Revision = integer(f(value, "uax29_revision"), "$.grapheme.uax29_revision");
        require(s(f(value, "version")).equals("16.0.0") && uax29Revision.equals(BigInteger.valueOf(45))
                && s(f(value, "profile")).equals("C1-1-default-extended-grapheme-cluster-no-tailoring")
                && s(f(value, "ranges")).equals("inclusive Unicode scalar values represented as integers"), "$.grapheme", "Unicode 16.0 UAX #29 revision 45 profile");
        Map<String, WireValue> byPath = new LinkedHashMap<>();
        for (WireValue source : expectedSources) byPath.put(s(f(source, "path")), source);
        Set<String> roles = Set.of("grapheme_break_property", "emoji_data", "derived_core_properties", "grapheme_break_test", "license", "uax29");
        List<WireValue> typedSources = new ArrayList<>();
        Set<String> foundRoles = new java.util.HashSet<>();
        for (WireValue row : array(f(value, "sources"), "$.grapheme.sources")) {
            exact(row, "$.grapheme.sources[]", Set.of("role", "path"));
            String role = s(f(row, "role")), sourcePath = s(f(row, "path"));
            require(roles.contains(role) && foundRoles.add(role), "$.grapheme.sources", "six unique Unicode source roles");
            WireValue source = byPath.get(sourcePath);
            require(source != null, "$.grapheme.sources", "source path in expected sources");
            typedSources.add(obj("role", str(role), "origin", obj("source", source, "locator", arr(List.of()))));
        }
        require(foundRoles.equals(roles), "$.grapheme.sources", "six unique Unicode source roles");
        WireValue properties = ranges(f(value, "properties"), true, false, "$.grapheme.properties");
        WireValue extendedPictographic = ranges(f(value, "extended_pictographic"), false, false, "$.grapheme.extended_pictographic");
        WireValue indicConjunct = ranges(f(value, "indic_conjunct"), true, true, "$.grapheme.indic_conjunct");
        WireValue table = obj("extended_pictographic", f(value, "extended_pictographic"),
                "indic_conjunct", f(value, "indic_conjunct"), "properties", f(value, "properties"));
        require(TypeSignatures.hash(table).equals(s(f(value, "table_sha256"))), "$.grapheme.table_sha256", "grapheme table digest mismatch");
        return obj("reference", reference,
                "component", obj("unicode_version", f(value, "version"), "uax29_revision", str(uax29Revision.toString()), "cluster_profile", f(value, "profile")),
                "table_sha256", f(value, "table_sha256"), "sources", arr(typedSources),
                "properties", properties, "extended_pictographic", extendedPictographic,
                "indic_conjunct", indicConjunct);
    }

    private static WireValue ranges(WireValue value, boolean withProperty, boolean indic, String path) throws GenerationFailure {
        List<WireValue> result = new ArrayList<>();
        BigInteger previous = BigInteger.valueOf(-1);
        List<WireValue> rows = array(value, path);
        for (int i = 0; i < rows.size(); i++) {
            String rowPath = path + "[" + i + "]";
            List<WireValue> tuple = array(rows.get(i), rowPath);
            require(tuple.size() == (withProperty ? 3 : 2), rowPath, "exact range tuple");
            BigInteger first = integer(tuple.get(0), rowPath + "[0]"), last = integer(tuple.get(1), rowPath + "[1]");
            require(first.signum() >= 0 && first.compareTo(previous) > 0 && first.compareTo(last) <= 0
                    && last.compareTo(BigInteger.valueOf(0x10ffff)) <= 0
                    && !(first.compareTo(BigInteger.valueOf(0xdfff)) <= 0 && last.compareTo(BigInteger.valueOf(0xd800)) >= 0), rowPath, "sorted disjoint Unicode scalar range");
            previous = last;
            if (withProperty) result.add(obj("first", str(first.toString()), "last", str(last.toString()),
                    "property", variant(property(s(tuple.get(2)), indic, rowPath + "[2]"))));
            else result.add(obj("first", str(first.toString()), "last", str(last.toString())));
        }
        return arr(result);
    }

    private static String property(String name, boolean indic, String path) throws GenerationFailure {
        Map<String, String> properties = indic
                ? Map.of("None", "Other", "Consonant", "Consonant", "Extend", "Extend", "Linker", "Linker")
                : Map.ofEntries(Map.entry("Other", "Other"), Map.entry("CR", "Cr"), Map.entry("LF", "Lf"), Map.entry("Control", "Control"),
                        Map.entry("Extend", "Extend"), Map.entry("ZWJ", "Zwj"), Map.entry("Regional_Indicator", "RegionalIndicator"),
                        Map.entry("Prepend", "Prepend"), Map.entry("SpacingMark", "SpacingMark"), Map.entry("L", "L"), Map.entry("V", "V"),
                        Map.entry("T", "T"), Map.entry("LV", "Lv"), Map.entry("LVT", "Lvt"));
        String result = properties.get(name);
        require(result != null, path, indic ? "InCB property" : "GCB property");
        return result;
    }

    private static void exact(WireValue value, String path, Set<String> keys) throws GenerationFailure {
        require(value instanceof ObjectValue, path, "object");
        require(o(value).members().size() == keys.size(), path, "closed exact record fields");
        for (Member member : o(value).members()) require(keys.contains(member.key()), path + "." + member.key(), "known field");
        for (String key : keys) require(o(value).get(key) != null, path + "." + key, "required field");
    }

    private static void text(WireValue value, String path) throws GenerationFailure { require(value instanceof StringValue, path, "string"); }
    private static List<WireValue> array(WireValue value, String path) throws GenerationFailure {
        require(value instanceof ArrayValue, path, "array");
        return a(value);
    }
    private static BigInteger integer(WireValue value, String path) throws GenerationFailure {
        require(value instanceof IntegerValue, path, "integer");
        return n(value);
    }
}
