// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;
import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

/** The first unknown member is the first in code point order, as in the Lean object order. */
final class WireKeyOrderTest {
    private static final String BMP = "\uFF5E";
    private static final String SUPPLEMENTARY = new String(Character.toChars(0x1F600));

    private static WireValue unknownMembers() {
        return obj(SUPPLEMENTARY, NIL, BMP, NIL);
    }

    @Test void keysReportsTheFirstUnknownMemberInCodePointOrder() {
        WireException failure = assertThrows(WireException.class, () -> keys(unknownMembers(), "$", List.of("a")));
        assertEquals(new UnknownField("$." + BMP, BMP), failure.failure());
    }

    @Test void canonicalReaderKeysReportTheFirstUnknownMemberInCodePointOrder() {
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> SemanticGeneration.closedKeys(unknownMembers(), "$", List.of("a")));
        assertEquals(new UnknownField("$." + BMP, BMP), failure.wireFailure());
    }

    @Test void graphemeRulesKeysReportTheFirstUnknownMemberInCodePointOrder() {
        WireException failure = assertThrows(WireException.class, () -> GraphemeWire.decode(unknownMembers(), "$.grapheme_rules"));
        assertEquals(new UnknownField("$.grapheme_rules." + BMP, BMP), failure.failure());
    }
}
