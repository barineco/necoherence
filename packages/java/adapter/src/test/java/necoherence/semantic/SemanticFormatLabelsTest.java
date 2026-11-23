// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.Random;
import necoherence.semantic.SemanticTypes.FormatRule;
import necoherence.semantic.SemanticTypes.LabelsRule;
import necoherence.semantic.SemanticTypes.LiteralRule;
import necoherence.semantic.SemanticTypes.TextRule;
import org.junit.jupiter.api.Test;

/** Checks the labels rule on long inputs on the main thread and against a reference linear split. */
class SemanticFormatLabelsTest {
    private static LabelsRule labels(String separator, BigInteger minimum, Optional<BigInteger> maximum,
            Optional<BigInteger> total, FormatRule rule) {
        return new LabelsRule(separator, minimum, maximum, total, rule);
    }

    private static LabelsRule labels(String separator, FormatRule rule) {
        return labels(separator, BigInteger.ZERO, Optional.empty(), Optional.empty(), rule);
    }

    private static List<String> parts(int count, String middle) {
        List<String> parts = new ArrayList<>(Collections.nCopies(count, "a"));
        if (!middle.isEmpty()) parts.set(count / 2, middle);
        return parts;
    }

    private static boolean linearLabelsAccept(LabelsRule labels, String text) {
        String delimiter = labels.separator();
        List<Integer> cuts = new ArrayList<>();
        int cursor = 0;
        for (int found = text.indexOf(delimiter); found >= 0; found = text.indexOf(delimiter, cursor)) {
            cuts.add(found);
            cursor = found + delimiter.length();
        }
        cuts.add(text.length());
        BigInteger count = BigInteger.valueOf(cuts.size());
        boolean admitted = count.compareTo(labels.minCount()) >= 0
                && labels.maxCount().map(maximum -> count.compareTo(maximum) <= 0).orElse(true)
                && labels.totalMax().map(maximum ->
                        BigInteger.valueOf(text.codePointCount(0, text.length())).compareTo(maximum) <= 0).orElse(true);
        if (!admitted) return false;
        int charCursor = 0;
        for (int cut : cuts) {
            if (!SemanticFormats.accepts(Optional.empty(), labels.rule(), text.substring(charCursor, cut))) return false;
            charCursor = cut + delimiter.length();
        }
        return true;
    }

    @Test void longLabelsAreAcceptedAndRejectedOnTheMainThread() {
        for (int length : new int[] {10_000, 100_000}) {
            int count = length / 2;
            String accepted = String.join(".", parts(count, ""));
            String rejected = String.join(".", parts(count, "b"));
            assertTrue(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".", new LiteralRule("a")), accepted));
            assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".", new LiteralRule("a")), rejected));
            assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".", new LiteralRule("a")),
                    accepted + "."));
            assertTrue(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".",
                    BigInteger.ZERO, Optional.of(BigInteger.valueOf(count)), Optional.empty(), new TextRule()), accepted));
            assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".",
                    BigInteger.ZERO, Optional.of(BigInteger.valueOf(count - 1)), Optional.empty(), new TextRule()), accepted));
        }
    }

    @Test void longSingleLabelIsCheckedAsOneLabel() {
        String text = "a".repeat(100_000);
        assertTrue(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".", new TextRule()), text));
        assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".", new LiteralRule("a")), text));
        assertFalse(SemanticValidation.formatAcceptsFast(Optional.empty(), labels(".",
                BigInteger.ZERO, Optional.empty(), Optional.of(BigInteger.valueOf(99_999)), new TextRule()), text));
    }

    @Test void splitAtSeparatorMatchesTheLeanRecursionOnSmallCases() {
        assertEquals(List.of("a", "", "b", ""), SemanticFormatSyntax.labelParts(".", "a..b."));
        assertEquals(List.of("x", "y", ""), SemanticFormatSyntax.labelParts("ab", "xabyab"));
        assertEquals(List.of(""), SemanticFormatSyntax.labelParts(".", ""));
        assertEquals(List.of("", "", "ab"), SemanticFormatSyntax.labelParts("", "ab"));
    }

    @Test void labelsAgreeWithReferenceLinearSplitOnRandomInputs() {
        Random random = new Random(20261104L);
        String[] separators = {".", ":", "::", "ab"};
        String alphabet = "ab.:";
        for (int trial = 0; trial < 3000; trial++) {
            StringBuilder builder = new StringBuilder();
            int length = random.nextInt(14);
            for (int i = 0; i < length; i++) builder.append(alphabet.charAt(random.nextInt(alphabet.length())));
            String text = builder.toString();
            String separator = separators[random.nextInt(separators.length)];
            FormatRule rule = switch (random.nextInt(3)) {
                case 0 -> new LiteralRule("a");
                case 1 -> new TextRule();
                default -> new LiteralRule("ab");
            };
            BigInteger minimum = BigInteger.valueOf(random.nextInt(4));
            Optional<BigInteger> maximum = random.nextBoolean()
                    ? Optional.of(BigInteger.valueOf(random.nextInt(5))) : Optional.empty();
            Optional<BigInteger> total = random.nextBoolean()
                    ? Optional.of(BigInteger.valueOf(random.nextInt(14))) : Optional.empty();
            LabelsRule rule2 = labels(separator, minimum, maximum, total, rule);
            assertEquals(linearLabelsAccept(rule2, text),
                    SemanticValidation.formatAcceptsFast(Optional.empty(), rule2, text),
                    () -> "separator=" + separator + " text=" + text);
        }
    }
}
