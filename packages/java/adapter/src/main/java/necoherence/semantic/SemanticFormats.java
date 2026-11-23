// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import necoherence.semantic.SemanticTypes.*;

/** Format recognition over the typed rule, spanning the scalar values of the input (Lean `formatAcceptsFast`). */
final class SemanticFormats {
    private SemanticFormats() {}

    private static final long UNBOUNDED = Long.MAX_VALUE;

    private enum Kind { EMPTY, SEQUENCE, LITERAL, TEXT, NOT, CHOICE, OPTIONAL, LABELS, BOUNDED, DFA, LEAF }

    private static final class Node {
        final int id;
        final Kind kind;
        final FormatRule rule;
        final Node[] children;
        final long minimum;
        final long maximum;
        int[] literal;
        Dfa dfa;
        boolean rightFirst;

        Node(int id, Kind kind, FormatRule rule, Node[] children, long minimum, long maximum) {
            this.id = id;
            this.kind = kind;
            this.rule = rule;
            this.children = children;
            this.minimum = minimum;
            this.maximum = maximum;
        }
    }

    static final class Program {
        final List<Node> nodes = new ArrayList<>();
        final Node root;
        boolean countsBytes;

        Program(FormatRule rule) { root = compile(rule); }

        private Node add(Kind kind, FormatRule rule, Node[] children, long minimum, long maximum) {
            Node node = new Node(nodes.size(), kind, rule, children, minimum, maximum);
            nodes.add(node);
            return node;
        }

        private Node compile(FormatRule rule) {
            if (rule == null) return add(Kind.EMPTY, null, new Node[0], 0, 0);
            switch (rule) {
                case SequenceRule sequence -> {
                    Node[] parts = new Node[sequence.parts().size()];
                    for (int index = 0; index < parts.length; index++) parts[index] = compile(sequence.parts().get(index));
                    return sequence(parts, 0);
                }
                case LiteralRule literal -> {
                    int[] value = literal.value().codePoints().toArray();
                    Node node = add(Kind.LITERAL, rule, new Node[0], value.length, value.length);
                    node.literal = value;
                    return node;
                }
                case TextRule text -> { return add(Kind.TEXT, rule, new Node[0], 0, UNBOUNDED); }
                case NotRule not -> { return add(Kind.NOT, rule, new Node[] {compile(not.rule())}, 0, UNBOUNDED); }
                case ChoiceRule choice -> {
                    Node[] children = new Node[choice.rules().size()];
                    long minimum = UNBOUNDED, maximum = 0;
                    for (int index = 0; index < children.length; index++) {
                        children[index] = compile(choice.rules().get(index));
                        minimum = Math.min(minimum, children[index].minimum);
                        maximum = Math.max(maximum, children[index].maximum);
                    }
                    if (children.length == 0) { minimum = 0; maximum = UNBOUNDED; }
                    return add(Kind.CHOICE, rule, children, minimum, maximum);
                }
                case OptionalRule optional -> {
                    Node child = compile(optional.rule());
                    return add(Kind.OPTIONAL, rule, new Node[] {child}, 0, Math.max(0, child.maximum));
                }
                case LabelsRule labels -> {
                    Node child = compile(labels.rule());
                    return add(Kind.LABELS, rule, new Node[] {child}, 0, labels.totalMax().map(SemanticFormats::bound).orElse(UNBOUNDED));
                }
                case BoundedRule bounded -> {
                    Node child = compile(bounded.rule());
                    long maximum = bounded.unit() == StringLengthUnit.GRAPHEMES ? child.maximum
                            : Math.min(child.maximum, bound(bounded.maximum()));
                    if (bounded.unit() == StringLengthUnit.UTF8_BYTES) countsBytes = true;
                    return add(Kind.BOUNDED, rule, new Node[] {child}, child.minimum, maximum);
                }
                case AsciiDfaRule dfa -> {
                    Node node = add(Kind.DFA, rule, new Node[0], 0, UNBOUNDED);
                    node.dfa = new Dfa(dfa.spec());
                    return node;
                }
                case IdentifierRule identifier -> {
                    long minimum = Math.max(1, bound(identifier.minLength()));
                    long maximum = identifier.maxLength().map(SemanticFormats::bound).orElse(UNBOUNDED);
                    if (identifier.exactLength().isPresent()) {
                        long exact = bound(identifier.exactLength().get());
                        minimum = Math.max(minimum, exact);
                        maximum = Math.min(maximum, exact);
                    }
                    return add(Kind.LEAF, rule, new Node[0], minimum, maximum);
                }
                case AbsoluteUriRule uri -> {
                    return add(Kind.LEAF, rule, new Node[0], 0, uri.maxBytes().map(SemanticFormats::bound).orElse(UNBOUNDED));
                }
                default -> { return add(Kind.LEAF, rule, new Node[0], 0, UNBOUNDED); }
            }
        }

        private Node sequence(Node[] parts, int start) {
            if (start == parts.length) return add(Kind.EMPTY, null, new Node[0], 0, 0);
            if (start == parts.length - 1) return parts[start];
            Node right = sequence(parts, start + 1);
            Node left = parts[start];
            Node node = add(Kind.SEQUENCE, null, new Node[] {left, right}, sum(left.minimum, right.minimum), sum(left.maximum, right.maximum));
            node.rightFirst = left.kind != Kind.LITERAL && (right.kind == Kind.LITERAL
                    || right.kind == Kind.SEQUENCE && right.children[0].kind == Kind.LITERAL);
            return node;
        }
    }

    private static long sum(long left, long right) {
        if (left < 0 || right < 0) return Math.min(left, right);
        return left > UNBOUNDED - right ? UNBOUNDED : left + right;
    }

    private static long bound(BigInteger value) {
        if (value.signum() < 0) return -1;
        return value.bitLength() > 62 ? UNBOUNDED : value.longValue();
    }

    private static final class Dfa {
        final int initial;
        final int[][] next;
        final boolean[] accepting;

        Dfa(DfaSpec spec) {
            Map<BigInteger, Integer> states = new HashMap<>();
            states.put(spec.initialState(), 0);
            for (DfaTransition transition : spec.transitions()) {
                states.putIfAbsent(transition.fromState(), states.size());
                states.putIfAbsent(transition.toState(), states.size());
            }
            initial = 0;
            next = new int[states.size()][128];
            for (int[] row : next) Arrays.fill(row, -1);
            BigInteger highest = BigInteger.valueOf(127);
            for (DfaTransition transition : spec.transitions()) {
                if (transition.first().compareTo(highest) > 0 || transition.last().signum() < 0) continue;
                int[] row = next[states.get(transition.fromState())];
                int target = states.get(transition.toState());
                int last = transition.last().min(highest).intValue();
                for (int c = transition.first().max(BigInteger.ZERO).intValue(); c <= last; c++) if (row[c] < 0) row[c] = target;
            }
            accepting = new boolean[states.size()];
            for (Map.Entry<BigInteger, Integer> state : states.entrySet())
                accepting[state.getValue()] = spec.acceptingStates().contains(state.getKey());
        }
    }

    private static final class Run {
        private final Program program;
        private final Optional<SemanticGraphemes.Table> graphemeRules;
        private final int[] chars;
        private final long width;
        private final long[] bytes;
        private final Memo[] memo;
        private final int[][] graphemeLimits;
        private final int[][] dfaReached;
        private final int[][] dfaStates;

        Run(Program program, Optional<SemanticGraphemes.Table> graphemeRules, String text) {
            this.program = program;
            this.graphemeRules = graphemeRules;
            this.chars = text.codePoints().toArray();
            this.width = chars.length + 1L;
            if (program.countsBytes) {
                bytes = new long[chars.length + 1];
                for (int index = 0; index < chars.length; index++) bytes[index + 1] = bytes[index] + utf8Width(chars[index]);
            } else bytes = null;
            memo = new Memo[program.nodes.size()];
            graphemeLimits = new int[program.nodes.size()][];
            dfaReached = new int[program.nodes.size()][];
            dfaStates = new int[program.nodes.size()][];
        }

        boolean accepts(Node node, int start, int finish) {
            long span = finish - start;
            if (span < node.minimum || span > node.maximum) return false;
            switch (node.kind) {
                case EMPTY: return start == finish;
                case TEXT: return true;
                case LITERAL: return literal(node.literal, start);
                case DFA: return dfa(node, start, finish);
                default: break;
            }
            Memo known = memo[node.id];
            if (known == null) known = memo[node.id] = new Memo();
            long key = start * width + finish;
            int found = known.get(key);
            if (found >= 0) return found == 1;
            boolean accepted = decide(node, start, finish);
            known.put(key, accepted);
            return accepted;
        }

        private boolean literal(int[] value, int start) {
            for (int offset = 0; offset < value.length; offset++) if (chars[start + offset] != value[offset]) return false;
            return true;
        }

        private boolean decide(Node node, int start, int finish) {
            Node[] children = node.children;
            switch (node.kind) {
                case SEQUENCE: {
                    Node left = children[0], right = children[1];
                    long from = Math.max(start + left.minimum, right.maximum == UNBOUNDED ? start : finish - right.maximum);
                    long to = Math.min(left.maximum == UNBOUNDED ? finish : start + left.maximum, finish - right.minimum);
                    for (long split = Math.max(from, start); split <= Math.min(to, finish); split++) {
                        if (node.rightFirst ? accepts(right, (int) split, finish) && accepts(left, start, (int) split)
                                : accepts(left, start, (int) split) && accepts(right, (int) split, finish)) return true;
                    }
                    return false;
                }
                case NOT: return !accepts(children[0], start, finish);
                case CHOICE: {
                    for (Node child : children) if (accepts(child, start, finish)) return true;
                    return false;
                }
                case OPTIONAL: return start == finish || accepts(children[0], start, finish);
                case LABELS: return labels(node, start, finish);
                case BOUNDED: return within(node, start, finish) && accepts(children[0], start, finish);
                default: return SemanticFormats.formatAccepts(graphemeRules, node.rule, new String(chars, start, finish - start));
            }
        }

        private boolean labels(Node node, int start, int finish) {
            LabelsRule labels = (LabelsRule) node.rule;
            if (labels.separator().isEmpty()) return false;
            int[] separator = labels.separator().codePoints().toArray();
            List<int[]> pieces = new ArrayList<>();
            int label = start, position = start;
            while (position < finish) {
                if (finish - position >= separator.length && matches(separator, position)) {
                    pieces.add(new int[] {label, position});
                    position += separator.length;
                    label = position;
                } else position++;
            }
            pieces.add(new int[] {label, finish});
            BigInteger count = BigInteger.valueOf(pieces.size());
            if (count.compareTo(labels.minCount()) < 0) return false;
            if (labels.maxCount().isPresent() && count.compareTo(labels.maxCount().get()) > 0) return false;
            if (labels.totalMax().isPresent() && BigInteger.valueOf(finish - start).compareTo(labels.totalMax().get()) > 0) return false;
            for (int[] piece : pieces) if (!accepts(node.children[0], piece[0], piece[1])) return false;
            return true;
        }

        private boolean matches(int[] separator, int position) {
            for (int offset = 0; offset < separator.length; offset++) if (chars[position + offset] != separator[offset]) return false;
            return true;
        }

        private boolean within(Node node, int start, int finish) {
            BoundedRule bounded = (BoundedRule) node.rule;
            return switch (bounded.unit()) {
                case UTF8_BYTES -> BigInteger.valueOf(bytes[finish] - bytes[start]).compareTo(bounded.maximum()) <= 0;
                case UNICODE_SCALARS -> BigInteger.valueOf(finish - start).compareTo(bounded.maximum()) <= 0;
                case GRAPHEMES -> graphemeRules.isPresent() && finish <= graphemeLimit(node, bounded.maximum(), start);
            };
        }

        private int graphemeLimit(Node node, BigInteger maximum, int start) {
            int[] limits = graphemeLimits[node.id];
            if (limits == null) {
                limits = graphemeLimits[node.id] = new int[chars.length + 1];
                Arrays.fill(limits, -2);
            }
            if (limits[start] != -2) return limits[start];
            int limit;
            if (maximum.signum() < 0) limit = start - 1;
            else {
                long most = maximum.bitLength() > 31 ? Integer.MAX_VALUE : maximum.longValue();
                SemanticGraphemes.Cursor cursor = new SemanticGraphemes.Cursor(graphemeRules.get());
                limit = chars.length;
                for (int position = start; position < chars.length; position++) {
                    cursor.step(chars[position]);
                    if (cursor.count > most) { limit = position; break; }
                }
            }
            return limits[start] = limit;
        }

        private boolean dfa(Node node, int start, int finish) {
            Dfa dfa = node.dfa;
            int[] reached = dfaReached[node.id], states = dfaStates[node.id];
            if (reached == null) {
                reached = dfaReached[node.id] = new int[chars.length + 1];
                states = dfaStates[node.id] = new int[chars.length + 1];
                Arrays.fill(reached, -1);
            }
            int position = start, state = dfa.initial;
            if (reached[start] >= 0 && reached[start] <= finish) {
                position = reached[start];
                state = states[start];
            }
            for (; state >= 0 && position < finish; position++) {
                int c = chars[position];
                state = c >= 128 ? -1 : dfa.next[state][c];
            }
            if (position >= reached[start]) {
                reached[start] = position;
                states[start] = state;
            }
            return state >= 0 && dfa.accepting[state];
        }
    }

    private static final class Memo {
        private long[] keys = new long[16];
        private byte[] values = new byte[16];
        private int size;

        int get(long key) {
            int mask = keys.length - 1;
            for (int slot = mix(key) & mask; keys[slot] != 0; slot = (slot + 1) & mask)
                if (keys[slot] == key + 1) return values[slot];
            return -1;
        }

        void put(long key, boolean value) {
            if (2 * (size + 1) > keys.length) grow();
            insert(key + 1, (byte) (value ? 1 : 0));
            size++;
        }

        private void insert(long stored, byte value) {
            int mask = keys.length - 1;
            int slot = mix(stored - 1) & mask;
            while (keys[slot] != 0) slot = (slot + 1) & mask;
            keys[slot] = stored;
            values[slot] = value;
        }

        private void grow() {
            long[] oldKeys = keys;
            byte[] oldValues = values;
            keys = new long[oldKeys.length * 2];
            values = new byte[oldKeys.length * 2];
            for (int slot = 0; slot < oldKeys.length; slot++) if (oldKeys[slot] != 0) insert(oldKeys[slot], oldValues[slot]);
        }

        private static int mix(long key) {
            long mixed = key * 0x9E3779B97F4A7C15L;
            return (int) (mixed ^ (mixed >>> 32));
        }
    }

    private static int utf8Width(int c) {
        if (c < 0x80) return 1;
        if (c < 0x800) return 2;
        if (0xD800 <= c && c <= 0xDFFF) return 1;
        return c < 0x10000 ? 3 : 4;
    }

    static boolean accepts(Optional<SemanticTypes.GraphemeRules> graphemeRules, FormatRule rule, String text) {
        return accepts(graphemeRules.map(SemanticGraphemes.Table::new), new Program(rule), text);
    }

    static boolean accepts(Optional<SemanticGraphemes.Table> graphemeRules, Program program, String text) {
        Run run = new Run(program, graphemeRules, text);
        return run.accepts(program.root, 0, run.chars.length);
    }

    static boolean formatAccepts(Optional<SemanticGraphemes.Table> graphemeRules, FormatRule rule, String text) {
        return switch (rule) {
            case LiteralRule literal -> literal.value().equals(text);
            case SequenceRule sequence -> SemanticFormatSyntax.sequenceAcceptsWith(
                    (part, segment) -> formatAccepts(graphemeRules, part, segment), sequence.parts(), text);
            case OptionalRule optional -> formatAccepts(graphemeRules, optional.rule(), text) || text.isEmpty();
            case LabelsRule labels -> {
                if (labels.separator().isEmpty()) yield false;
                List<String> values = SemanticFormatSyntax.labelParts(labels.separator(), text);
                BigInteger count = BigInteger.valueOf(values.size());
                yield count.compareTo(labels.minCount()) >= 0
                        && labels.maxCount().map(maximum -> count.compareTo(maximum) <= 0).orElse(true)
                        && labels.totalMax().map(maximum -> BigInteger.valueOf(text.codePointCount(0, text.length())).compareTo(maximum) <= 0).orElse(true)
                        && values.stream().allMatch(value -> formatAccepts(graphemeRules, labels.rule(), value));
            }
            case BoundedRule bounded -> formatWithin(graphemeRules, bounded.unit(), bounded.maximum(), text)
                    && formatAccepts(graphemeRules, bounded.rule(), text);
            case AsciiDfaRule dfa -> dfaAccepts(dfa.spec(), text);
            case IdentifierRule identifier -> identifierAccepts(identifier, text);
            case TimestampRule timestamp -> SemanticFormatSyntax.timestampSyntax(timestamp.rule(), text);
            case AbsoluteUriRule uri -> uri.maxBytes()
                    .map(bound -> BigInteger.valueOf(SemanticValidation.utf8Length(text)).compareTo(bound) <= 0).orElse(true)
                    && SemanticFormatSyntax.uriSyntax(text);
            case LanguageTagRule language -> SemanticFormatSyntax.languageSyntax(language.grandfathered(), text);
            case ChoiceRule choice -> choice.rules().stream().anyMatch(child -> formatAccepts(graphemeRules, child, text));
            case TextRule textRule -> true;
            case NotRule not -> !formatAccepts(graphemeRules, not.rule(), text);
        };
    }

    static boolean formatWithin(Optional<SemanticGraphemes.Table> graphemeRules, StringLengthUnit unit, BigInteger maximum, String text) {
        return SemanticValidation.formatLength(graphemeRules, unit, text)
                .map(length -> BigInteger.valueOf(length).compareTo(maximum) <= 0).orElse(false);
    }

    private static boolean identifierAccepts(IdentifierRule rule, String text) {
        if (!SemanticValues.ascii(text) || text.isEmpty()) return false;
        BigInteger length = BigInteger.valueOf(text.length());
        if (length.compareTo(rule.minLength()) < 0) return false;
        if (rule.maxLength().isPresent() && length.compareTo(rule.maxLength().get()) > 0) return false;
        if (rule.exactLength().isPresent() && !length.equals(rule.exactLength().get())) return false;
        if (rule.forbidden().contains(text) || !rule.firstAlphabet().contains(text.substring(0, 1))) return false;
        for (int i = 1; i < text.length(); i++) if (rule.restAlphabet().indexOf(text.charAt(i)) < 0) return false;
        return true;
    }

    private static boolean dfaAccepts(DfaSpec spec, String text) {
        if (!SemanticValues.ascii(text)) return false;
        BigInteger state = spec.initialState();
        for (int i = 0; i < text.length(); i++) {
            BigInteger character = BigInteger.valueOf(text.charAt(i));
            BigInteger next = null;
            for (DfaTransition transition : spec.transitions()) {
                if (transition.fromState().equals(state) && character.compareTo(transition.first()) >= 0
                        && character.compareTo(transition.last()) <= 0) { next = transition.toState(); break; }
            }
            if (next == null) return false;
            state = next;
        }
        return spec.acceptingStates().contains(state);
    }
}
