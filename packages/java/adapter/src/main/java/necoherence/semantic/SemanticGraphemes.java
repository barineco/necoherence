// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import necoherence.semantic.SemanticTypes.CodepointRange;
import necoherence.semantic.SemanticTypes.GraphemeProperty;
import necoherence.semantic.SemanticTypes.GraphemeRange;
import necoherence.semantic.SemanticTypes.GraphemeRules;
import necoherence.semantic.SemanticTypes.IndicProperty;
import necoherence.semantic.SemanticTypes.IndicRange;

/** Extended grapheme cluster segmentation under the verified grapheme rules. */
public final class SemanticGraphemes {
    private SemanticGraphemes() {}

    record GraphemeState(int count, Optional<GraphemeProperty> previous, int regionalRun, boolean pictographicExtends,
            boolean previousZwjAfterPictographic, boolean indicConsonant, boolean indicLinker) {}

    static final GraphemeState INITIAL = new GraphemeState(0, Optional.empty(), 0, false, false, false, false);

    private static final GraphemeProperty[] GRAPHEME_PROPERTIES = GraphemeProperty.values();
    private static final IndicProperty[] INDIC_PROPERTIES = IndicProperty.values();
    private static final BigInteger LOWEST = BigInteger.ZERO;
    private static final BigInteger HIGHEST = BigInteger.valueOf(Character.MAX_CODE_POINT);

    /** Counts the extended grapheme clusters of the text. */
    public static int graphemeLength(GraphemeRules rules, String text) {
        return graphemeLength(new Table(Objects.requireNonNull(rules)), text);
    }

    static int graphemeLength(Table table, String text) {
        Cursor cursor = new Cursor(table);
        for (int at = 0; at < text.length(); ) {
            int point = text.codePointAt(at);
            cursor.step(point);
            at += Character.charCount(point);
        }
        return cursor.count;
    }

    static GraphemeState graphemeStep(GraphemeRules rules, GraphemeState state, int c) {
        Cursor cursor = new Cursor(new Table(rules));
        cursor.count = state.count();
        cursor.previous = state.previous().orElse(null);
        cursor.regionalRun = state.regionalRun();
        cursor.pictographicExtends = state.pictographicExtends();
        cursor.previousZwjAfterPictographic = state.previousZwjAfterPictographic();
        cursor.indicConsonant = state.indicConsonant();
        cursor.indicLinker = state.indicLinker();
        cursor.step(c);
        return new GraphemeState(cursor.count, Optional.ofNullable(cursor.previous), cursor.regionalRun,
                cursor.pictographicExtends, cursor.previousZwjAfterPictographic, cursor.indicConsonant, cursor.indicLinker);
    }

    static final class Cursor {
        private final Table table;
        int count;
        GraphemeProperty previous;
        int regionalRun;
        boolean pictographicExtends;
        boolean previousZwjAfterPictographic;
        boolean indicConsonant;
        boolean indicLinker;

        Cursor(Table table) { this.table = table; }

        boolean step(int c) {
            GraphemeProperty next = table.grapheme(c);
            IndicProperty indic = table.indic(c);
            boolean ep = table.pictographic(c);
            boolean breaks = breaks(next, indic, ep);
            if (breaks) count++;
            regionalRun = next == GraphemeProperty.REGIONAL_INDICATOR ? regionalRun + 1 : 0;
            previousZwjAfterPictographic = next == GraphemeProperty.ZWJ && pictographicExtends;
            pictographicExtends = ep || next == GraphemeProperty.EXTEND && pictographicExtends;
            boolean consonant = indicConsonant;
            indicConsonant = indic == IndicProperty.CONSONANT || (indic == IndicProperty.EXTEND || indic == IndicProperty.LINKER) && consonant;
            indicLinker = indic == IndicProperty.CONSONANT ? false
                    : indic == IndicProperty.LINKER ? consonant
                    : indic == IndicProperty.EXTEND && indicLinker;
            previous = next;
            return breaks;
        }

        private boolean breaks(GraphemeProperty next, IndicProperty indic, boolean ep) {
            if (previous == null) return true;
            if (previous == GraphemeProperty.CR && next == GraphemeProperty.LF) return false;
            if (controlProperty(previous) || controlProperty(next)) return true;
            if (previous == GraphemeProperty.L && (next == GraphemeProperty.L || next == GraphemeProperty.V
                    || next == GraphemeProperty.LV || next == GraphemeProperty.LVT)) return false;
            if ((previous == GraphemeProperty.LV || previous == GraphemeProperty.V)
                    && (next == GraphemeProperty.V || next == GraphemeProperty.T)) return false;
            if ((previous == GraphemeProperty.LVT || previous == GraphemeProperty.T) && next == GraphemeProperty.T) return false;
            if (next == GraphemeProperty.EXTEND || next == GraphemeProperty.ZWJ || next == GraphemeProperty.SPACING_MARK) return false;
            if (previous == GraphemeProperty.PREPEND) return false;
            if (indic == IndicProperty.CONSONANT && indicConsonant && indicLinker) return false;
            if (ep && previous == GraphemeProperty.ZWJ && previousZwjAfterPictographic) return false;
            if (previous == GraphemeProperty.REGIONAL_INDICATOR && next == GraphemeProperty.REGIONAL_INDICATOR
                    && regionalRun % 2 == 1) return false;
            return true;
        }
    }

    static boolean controlProperty(GraphemeProperty property) {
        return property == GraphemeProperty.CR || property == GraphemeProperty.LF || property == GraphemeProperty.CONTROL;
    }

    static final class Table {
        private final Segments graphemes;
        private final Segments indic;
        private final Segments pictographic;

        Table(GraphemeRules rules) {
            List<GraphemeRange> properties = rules.properties();
            graphemes = new Segments(properties.size());
            for (GraphemeRange range : properties) graphemes.add(range.first(), range.last(), range.property().ordinal());
            graphemes.flatten();
            List<IndicRange> indicRows = rules.indicConjunct();
            indic = new Segments(indicRows.size());
            for (IndicRange range : indicRows) indic.add(range.first(), range.last(), range.property().ordinal());
            indic.flatten();
            List<CodepointRange> pictographicRows = rules.extendedPictographic();
            pictographic = new Segments(pictographicRows.size());
            for (CodepointRange range : pictographicRows) pictographic.add(range.first(), range.last(), 1);
            pictographic.flatten();
        }

        GraphemeProperty grapheme(int c) {
            int value = graphemes.lookup(c);
            return value < 0 ? GraphemeProperty.OTHER : GRAPHEME_PROPERTIES[value];
        }

        IndicProperty indic(int c) {
            int value = indic.lookup(c);
            return value < 0 ? IndicProperty.OTHER : INDIC_PROPERTIES[value];
        }

        boolean pictographic(int c) { return pictographic.lookup(c) >= 0; }
    }

    private static final class Segments {
        private int[] firsts;
        private int[] ends;
        private int[] values;
        private int rows;
        private int[] starts;
        private byte[] segmentValues;

        Segments(int capacity) {
            firsts = new int[capacity];
            ends = new int[capacity];
            values = new int[capacity];
        }

        void add(BigInteger first, BigInteger last, int value) {
            if (first.compareTo(last) > 0 || first.compareTo(HIGHEST) > 0 || last.compareTo(LOWEST) < 0) return;
            firsts[rows] = first.max(LOWEST).intValue();
            ends[rows] = last.min(HIGHEST).intValue() + 1;
            values[rows] = value;
            rows++;
        }

        void flatten() {
            int[] bounds = new int[rows * 2];
            for (int row = 0; row < rows; row++) {
                bounds[2 * row] = firsts[row];
                bounds[2 * row + 1] = ends[row];
            }
            Arrays.sort(bounds);
            int count = 0;
            for (int bound : bounds) if (count == 0 || bounds[count - 1] != bound) bounds[count++] = bound;
            starts = Arrays.copyOf(bounds, count);
            segmentValues = new byte[count];
            Arrays.fill(segmentValues, (byte) -1);
            int[] unpainted = new int[count + 1];
            for (int index = 0; index <= count; index++) unpainted[index] = index;
            for (int row = 0; row < rows; row++) {
                int end = Arrays.binarySearch(starts, ends[row]);
                for (int index = next(unpainted, Arrays.binarySearch(starts, firsts[row])); index < end;
                        index = next(unpainted, index + 1)) {
                    segmentValues[index] = (byte) values[row];
                    unpainted[index] = index + 1;
                }
            }
            firsts = ends = values = null;
        }

        private static int next(int[] unpainted, int index) {
            int root = index;
            while (unpainted[root] != root) root = unpainted[root];
            while (unpainted[index] != root) {
                int following = unpainted[index];
                unpainted[index] = root;
                index = following;
            }
            return root;
        }

        int lookup(int c) {
            int index = Arrays.binarySearch(starts, c);
            if (index < 0) index = -index - 2;
            return index < 0 ? -1 : segmentValues[index];
        }
    }
}
