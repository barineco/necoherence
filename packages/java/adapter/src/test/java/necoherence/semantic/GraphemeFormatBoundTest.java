// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;
import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.semantic.SemanticTypes.BoundedRule;
import necoherence.semantic.SemanticTypes.GraphemeRules;
import necoherence.semantic.SemanticTypes.StringLengthUnit;
import necoherence.semantic.SemanticTypes.TextRule;
import org.junit.jupiter.api.Test;

final class GraphemeFormatBoundTest {
    private static final BoundedRule AT_MOST_ONE_GRAPHEME =
            new BoundedRule(StringLengthUnit.GRAPHEMES, BigInteger.ONE, new TextRule());

    private static GraphemeRules rulesWithCombiningAcute() {
        WireValue reference = obj("identity", str("profile"), "revision", str("4"), "content_digest", str("a".repeat(64)));
        WireValue rules = obj("reference", reference,
                "component", obj("unicode_version", str("16"), "uax29_revision", str("45"), "cluster_profile", str("extended")),
                "table_sha256", str("b".repeat(64)), "sources", arr(List.of()),
                "properties", arr(List.of(obj("first", str("0"), "last", str("1"), "property", variant("Other")),
                        obj("first", str("769"), "last", str("769"), "property", variant("Extend")))),
                "extended_pictographic", arr(List.of()), "indic_conjunct", arr(List.of()));
        return GraphemeWire.decode(rules, "$");
    }

    @Test void graphemeBoundWithoutGraphemeRulesRejectsEverySpelling() {
        assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), AT_MOST_ONE_GRAPHEME, "a"));
        assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), AT_MOST_ONE_GRAPHEME, "e\u0301"));
    }

    @Test void graphemeBoundCountsClustersUnderTheProfileRules() {
        assertTrue(SemanticValidation.formatAcceptsFast(Optional.of(rulesWithCombiningAcute()),
                AT_MOST_ONE_GRAPHEME, "e\u0301"));
        assertTrue(SemanticValidation.formatAcceptsFast(Optional.of(rulesWithCombiningAcute()),
                AT_MOST_ONE_GRAPHEME, "a"));
        assertFalse(SemanticValidation.formatAcceptsFast(Optional.of(rulesWithCombiningAcute()),
                AT_MOST_ONE_GRAPHEME, "ab"));
    }
}
