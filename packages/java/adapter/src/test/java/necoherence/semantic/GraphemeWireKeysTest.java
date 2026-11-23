// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.ArrayList;
import java.util.List;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

final class GraphemeWireKeysTest {
    private static final String DIGEST = "c".repeat(64);

    @Test void propertyRowWithAnExtraKeyIsAnUnknownFieldFailure() {
        WireValue row = with(propertyRow(), "note", str("x"));
        WireException failure = assertThrows(WireException.class,
                () -> GraphemeWire.decode(rules(List.of(row)), "$.grapheme_rules"));
        assertEquals(new UnknownField("$.grapheme_rules.properties[0].note", "note"), failure.failure());
    }

    @Test void propertyRowWithoutItsPropertyIsAMissingFieldFailure() {
        WireValue row = without(propertyRow(), "property");
        WireException failure = assertThrows(WireException.class,
                () -> GraphemeWire.decode(rules(List.of(row)), "$.grapheme_rules"));
        assertEquals(new Syntax("$.grapheme_rules.properties[0].property", "missing field"), failure.failure());
    }

    @Test void componentWithAnExtraKeyIsAnUnknownFieldFailure() {
        WireValue component = with(component(), "note", str("x"));
        WireException failure = assertThrows(WireException.class,
                () -> GraphemeWire.decode(replace(rules(List.of()), "component", component), "$.grapheme_rules"));
        assertEquals(new UnknownField("$.grapheme_rules.component.note", "note"), failure.failure());
    }

    @Test void sourceOriginWithAnExtraKeyIsAnUnknownFieldFailure() {
        WireValue source = obj("role", str("property"), "origin", with(origin(), "note", str("x")));
        WireException failure = assertThrows(WireException.class,
                () -> GraphemeWire.decode(replace(rules(List.of()), "sources", arr(List.of(source))), "$.grapheme_rules"));
        assertEquals(new UnknownField("$.grapheme_rules.sources[0].origin.note", "note"), failure.failure());
    }

    @Test void wellFormedRulesDecodeWithoutChange() {
        assertEquals(1, GraphemeWire.decode(rules(List.of(propertyRow())), "$.grapheme_rules").properties().size());
    }

    private static WireValue propertyRow() {
        return obj("first", str("0"), "last", str("10"), "property", variant("Other"));
    }

    private static WireValue component() {
        return obj("unicode_version", str("15.1"), "uax29_revision", str("1"), "cluster_profile", str("default"));
    }

    private static WireValue origin() {
        return obj("source", obj("repository", str("owner"), "revision", str("1"), "path", str("spec"),
                "content_digest", str(DIGEST)), "locator", arr(List.of(str("rules"))));
    }

    private static WireValue rules(List<WireValue> properties) {
        return obj("reference", obj("identity", str("grapheme"), "revision", str("1"), "content_digest", str(DIGEST)),
                "component", component(), "table_sha256", str(DIGEST),
                "sources", arr(List.of(obj("role", str("property"), "origin", origin()))),
                "properties", arr(properties), "extended_pictographic", arr(List.of()), "indic_conjunct", arr(List.of()));
    }

    private static WireValue with(WireValue value, String key, WireValue addition) {
        List<Member> members = new ArrayList<>(((ObjectValue) value).members());
        members.add(new Member(key, addition));
        return new ObjectValue(members);
    }

    private static WireValue without(WireValue value, String key) {
        return new ObjectValue(((ObjectValue) value).members().stream().filter(member -> !member.key().equals(key)).toList());
    }

    private static WireValue replace(WireValue value, String key, WireValue replacement) {
        return new ObjectValue(((ObjectValue) value).members().stream()
                .map(member -> member.key().equals(key) ? new Member(key, replacement) : member).toList());
    }
}
