// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.function.BiPredicate;
import java.util.function.IntPredicate;
import necoherence.semantic.SemanticTypes.CalendarRule;
import necoherence.semantic.SemanticTypes.FormatRule;

/** Lexical and syntactic predicates of the format rules, one named function per Lean definition (`SemanticValidation`). */
final class SemanticFormatSyntax {
    private SemanticFormatSyntax() {}

    record CharSplit(List<Integer> before, Optional<List<Integer>> after) {}

    record CharPair(List<Integer> left, List<Integer> right) {}

    record TextPair(String left, String right) {}

    static List<Integer> toList(String text) {
        return text.codePoints().boxed().toList();
    }

    static String ofList(List<Integer> chars) {
        StringBuilder text = new StringBuilder();
        for (int c : chars) text.appendCodePoint(c);
        return text.toString();
    }

    static String toLower(String text) {
        StringBuilder lower = new StringBuilder();
        text.codePoints().forEach(c -> lower.appendCodePoint('A' <= c && c <= 'Z' ? c + ('a' - 'A') : c));
        return lower.toString();
    }

    static boolean asciiAlpha(int c) {
        return 'A' <= c && c <= 'Z' || 'a' <= c && c <= 'z';
    }

    static boolean asciiDigit(int c) {
        return '0' <= c && c <= '9';
    }

    static boolean asciiAlnum(int c) {
        return asciiAlpha(c) || asciiDigit(c);
    }

    static boolean asciiHex(int c) {
        return asciiDigit(c) || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F';
    }

    static boolean allChars(IntPredicate test, String text) {
        return text.codePoints().allMatch(test);
    }

    static boolean nonemptyChars(IntPredicate test, String text) {
        return !text.isEmpty() && allChars(test, text);
    }

    static CharSplit splitChar(int delimiter, List<Integer> text) {
        for (int i = 0; i < text.size(); i++) {
            if (text.get(i) == delimiter) {
                return new CharSplit(List.copyOf(text.subList(0, i)), Optional.of(List.copyOf(text.subList(i + 1, text.size()))));
            }
        }
        return new CharSplit(List.copyOf(text), Optional.empty());
    }

    static boolean uriUnreserved(int c) {
        return asciiAlnum(c) || "-._~".indexOf(c) >= 0;
    }

    static boolean uriSubdelim(int c) {
        return "!$&'()*+,;=".indexOf(c) >= 0;
    }

    static boolean uriChars(IntPredicate extra, List<Integer> text) {
        for (int i = 0; i < text.size(); i++) {
            int c = text.get(i);
            if (c == '%') {
                if (i + 2 >= text.size() || !asciiHex(text.get(i + 1)) || !asciiHex(text.get(i + 2))) return false;
                i += 2;
            } else if (!(uriUnreserved(c) || uriSubdelim(c) || extra.test(c))) {
                return false;
            }
        }
        return true;
    }

    static boolean ipv4(String text) {
        String[] parts = text.split("\\.", -1);
        return parts.length == 4 && Arrays.stream(parts).allMatch(part ->
                nonemptyChars(SemanticFormatSyntax::asciiDigit, part) && part.length() <= 3
                        && (part.equals("0") || !part.startsWith("0")) && Integer.parseInt(part) <= 255);
    }

    static Optional<Integer> ipv6GroupCount(List<String> parts) {
        if (parts.isEmpty()) return Optional.of(0);
        int count = 0;
        for (String part : parts.subList(0, parts.size() - 1)) {
            if (part.isEmpty() || part.codePointCount(0, part.length()) > 4 || !allChars(SemanticFormatSyntax::asciiHex, part)) {
                return Optional.empty();
            }
            count++;
        }
        String last = parts.get(parts.size() - 1);
        if (last.indexOf('.') >= 0) return ipv4(last) ? Optional.of(count + 2) : Optional.empty();
        boolean hexGroup = !last.isEmpty() && last.codePointCount(0, last.length()) <= 4 && allChars(SemanticFormatSyntax::asciiHex, last);
        return hexGroup ? Optional.of(count + 1) : Optional.empty();
    }

    static boolean ipv6(String text) {
        List<String> pieces = List.of(text.split("::", -1));
        if (pieces.size() == 1) {
            return ipv6GroupCount(List.of(text.split(":", -1))).map(count -> count == 8).orElse(false);
        }
        if (pieces.size() == 2) {
            String before = pieces.get(0);
            String after = pieces.get(1);
            Optional<Integer> left = before.isEmpty() ? Optional.of(0) : ipv6GroupCount(List.of(before.split(":", -1)));
            Optional<Integer> right = after.isEmpty() ? Optional.of(0) : ipv6GroupCount(List.of(after.split(":", -1)));
            return left.isPresent() && right.isPresent() && left.get() + right.get() < 8 && before.indexOf('.') < 0;
        }
        return false;
    }

    static boolean ipLiteral(String text) {
        if (!text.startsWith("v") && !text.startsWith("V")) return ipv6(text);
        String[] parts = text.split("\\.", -1);
        String version = parts[0];
        String tail = String.join(".", Arrays.copyOfRange(parts, 1, parts.length));
        return nonemptyChars(SemanticFormatSyntax::asciiHex, version.substring(1))
                && nonemptyChars(c -> uriUnreserved(c) || uriSubdelim(c) || c == ':', tail);
    }

    static boolean uriHostPort(List<Integer> text) {
        if (!text.isEmpty() && text.get(0) == '[') {
            CharSplit split = splitChar(']', text.subList(1, text.size()));
            if (!ipLiteral(ofList(split.before()))) return false;
            if (split.after().isEmpty()) return false;
            List<Integer> after = split.after().get();
            if (after.isEmpty()) return true;
            return after.get(0) == ':' && after.subList(1, after.size()).stream().allMatch(SemanticFormatSyntax::asciiDigit);
        }
        CharSplit split = splitChar(':', text);
        return uriChars(c -> false, split.before())
                && (split.after().isEmpty() || split.after().get().stream().allMatch(SemanticFormatSyntax::asciiDigit));
    }

    static boolean uriAuthority(List<Integer> text) {
        CharSplit split = splitChar('@', text);
        if (split.after().isEmpty()) return uriHostPort(split.before());
        List<Integer> host = split.after().get();
        return uriChars(c -> c == ':', split.before()) && !host.contains((int) '@') && uriHostPort(host);
    }

    static boolean uriSyntax(String text) {
        CharSplit schemeSplit = splitChar(':', toList(text));
        List<Integer> scheme = schemeSplit.before();
        boolean schemeOk = !scheme.isEmpty() && asciiAlpha(scheme.get(0))
                && scheme.subList(1, scheme.size()).stream().allMatch(c -> asciiAlnum(c) || "+-.".indexOf(c) >= 0);
        if (!schemeOk || schemeSplit.after().isEmpty()) return false;
        CharSplit fragmentSplit = splitChar('#', schemeSplit.after().get());
        CharSplit querySplit = splitChar('?', fragmentSplit.before());
        IntPredicate pathExtra = c -> c == ':' || c == '@' || c == '/';
        IntPredicate queryExtra = c -> c == ':' || c == '@' || c == '/' || c == '?';
        List<Integer> hierarchy = querySplit.before();
        boolean pathOk;
        if (hierarchy.size() >= 2 && hierarchy.get(0) == '/' && hierarchy.get(1) == '/') {
            List<Integer> rest = hierarchy.subList(2, hierarchy.size());
            int authorityLength = 0;
            while (authorityLength < rest.size() && rest.get(authorityLength) != '/') authorityLength++;
            pathOk = uriAuthority(rest.subList(0, authorityLength)) && uriChars(pathExtra, rest.subList(authorityLength, rest.size()));
        } else {
            pathOk = uriChars(pathExtra, hierarchy);
        }
        return pathOk && querySplit.after().map(query -> uriChars(queryExtra, query)).orElse(true)
                && fragmentSplit.after().map(fragment -> uriChars(queryExtra, fragment)).orElse(true);
    }

    static boolean languageSubtag(int minimum, int maximum, String text) {
        int length = text.codePointCount(0, text.length());
        return minimum <= length && length <= maximum && allChars(SemanticFormatSyntax::asciiAlnum, text);
    }

    static boolean languageExtensions(List<String> seen, List<String> parts) {
        List<String> singletons = new ArrayList<>(seen);
        int index = 0;
        while (index < parts.size()) {
            String singleton = parts.get(index);
            List<String> rest = parts.subList(index + 1, parts.size());
            if (singleton.equals("x")) return !rest.isEmpty() && rest.stream().allMatch(part -> languageSubtag(1, 8, part));
            if (singleton.codePointCount(0, singleton.length()) != 1 || !allChars(SemanticFormatSyntax::asciiAlnum, singleton)
                    || singletons.contains(singleton)) {
                return false;
            }
            int values = 0;
            while (values < rest.size() && languageSubtag(2, 8, rest.get(values))) values++;
            if (values == 0) return false;
            singletons.add(singleton);
            index += 1 + values;
        }
        return true;
    }

    static boolean languageVariants(List<String> seen, List<String> parts) {
        List<String> variants = new ArrayList<>(seen);
        for (int index = 0; index < parts.size(); index++) {
            String part = parts.get(index);
            boolean variant = languageSubtag(5, 8, part)
                    || (part.codePointCount(0, part.length()) == 4 && allChars(SemanticFormatSyntax::asciiAlnum, part)
                        && asciiDigit(part.codePointAt(0)));
            if (!variant) return languageExtensions(List.of(), parts.subList(index, parts.size()));
            if (variants.contains(part)) return false;
            variants.add(part);
        }
        return true;
    }

    static boolean languageSyntax(List<String> grandfathered, String text) {
        if (!SemanticValues.ascii(text)) return false;
        String lower = toLower(text);
        if (grandfathered.stream().anyMatch(entry -> toLower(entry).equals(lower))) return true;
        List<String> parts = List.of(lower.split("-", -1));
        if (parts.get(0).equals("x")) {
            return parts.size() > 1 && parts.subList(1, parts.size()).stream().allMatch(part -> languageSubtag(1, 8, part));
        }
        String primary = parts.get(0);
        if (!allChars(SemanticFormatSyntax::asciiAlpha, primary) || primary.length() < 2 || primary.length() > 8) return false;
        List<String> rest = parts.subList(1, parts.size());
        int extended = 0;
        if (primary.length() <= 3) {
            while (extended < 3 && extended < rest.size() && rest.get(extended).length() == 3
                    && allChars(SemanticFormatSyntax::asciiAlpha, rest.get(extended))) {
                extended++;
            }
        }
        List<String> afterExtended = rest.subList(extended, rest.size());
        List<String> afterScript = afterExtended;
        if (!afterExtended.isEmpty() && afterExtended.get(0).length() == 4 && allChars(SemanticFormatSyntax::asciiAlpha, afterExtended.get(0))) {
            afterScript = afterExtended.subList(1, afterExtended.size());
        }
        List<String> afterRegion = afterScript;
        if (!afterScript.isEmpty()) {
            String region = afterScript.get(0);
            if ((region.length() == 2 && allChars(SemanticFormatSyntax::asciiAlpha, region))
                    || (region.length() == 3 && allChars(SemanticFormatSyntax::asciiDigit, region))) {
                afterRegion = afterScript.subList(1, afterScript.size());
            }
        }
        return languageVariants(List.of(), afterRegion);
    }

    static Optional<Integer> digitsNat(List<Integer> chars) {
        if (chars.isEmpty() || !chars.stream().allMatch(SemanticFormatSyntax::asciiDigit)) return Optional.empty();
        return Optional.of(Integer.parseInt(ofList(chars)));
    }

    static boolean leapYear(int year) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }

    static int monthDays(int year, int month) {
        if (month == 2) return leapYear(year) ? 29 : 28;
        return List.of(4, 6, 9, 11).contains(month) ? 30 : 31;
    }

    static boolean timestampSyntax(CalendarRule rule, String text) {
        List<Integer> chars = toList(text);
        if (chars.size() < 20) return false;
        if (chars.get(4) != '-' || chars.get(7) != '-' || chars.get(10) != 'T' || chars.get(13) != ':' || chars.get(16) != ':') {
            return false;
        }
        Optional<Integer> year = digitsNat(chars.subList(0, 4));
        Optional<Integer> month = digitsNat(chars.subList(5, 7));
        Optional<Integer> day = digitsNat(chars.subList(8, 10));
        Optional<Integer> hour = digitsNat(chars.subList(11, 13));
        Optional<Integer> minute = digitsNat(chars.subList(14, 16));
        Optional<Integer> second = digitsNat(chars.subList(17, 19));
        if (year.isEmpty() || month.isEmpty() || day.isEmpty() || hour.isEmpty() || minute.isEmpty() || second.isEmpty()) return false;
        int y = year.get();
        int mo = month.get();
        int d = day.get();
        int h = hour.get();
        int mi = minute.get();
        int s = second.get();
        BigInteger yearValue = BigInteger.valueOf(y);
        if (yearValue.compareTo(rule.minimumYear()) < 0 || yearValue.compareTo(rule.maximumYear()) > 0 || mo < 1 || mo > 12
                || d < 1 || d > monthDays(y, mo) || h > 23 || mi > 59 || s > (rule.allowSecond60() ? 60 : 59)) {
            return false;
        }
        List<Integer> suffix = chars.subList(19, chars.size());
        List<Integer> timezone = suffix;
        if (!suffix.isEmpty() && suffix.get(0) == '.') {
            List<Integer> rest = suffix.subList(1, suffix.size());
            int fraction = 0;
            while (fraction < rest.size() && asciiDigit(rest.get(fraction))) fraction++;
            timezone = fraction == 0 ? List.of() : rest.subList(fraction, rest.size());
        }
        if (timezone.size() == 1 && timezone.get(0) == 'Z') return true;
        if (timezone.size() != 6 || timezone.get(3) != ':') return false;
        int sign = timezone.get(0);
        if (sign != '+' && sign != '-') return false;
        Optional<Integer> offsetHourValue = digitsNat(timezone.subList(1, 3));
        Optional<Integer> offsetMinuteValue = digitsNat(timezone.subList(4, 6));
        if (offsetHourValue.isEmpty() || offsetMinuteValue.isEmpty()) return false;
        int oh = offsetHourValue.get();
        int om = offsetMinuteValue.get();
        if (oh > 23 || om > 59 || (sign == '-' && oh == 0 && om == 0)) return false;
        if (rule.rejectUtcYearOutsideRange()) {
            int precedingDays = 0;
            for (int earlier = 1; earlier < mo; earlier++) precedingDays += monthDays(y, earlier);
            long localMinutes = (precedingDays + d - 1) * 1440L + h * 60L + mi;
            long offsetMinutes = oh * 60L + om;
            long utcMinutes = sign == '+' ? localMinutes - offsetMinutes : localMinutes + offsetMinutes;
            long yearMinutes = (leapYear(y) ? 366L : 365L) * 1440L;
            if (yearValue.equals(rule.minimumYear()) && utcMinutes < 0) return false;
            if (yearValue.equals(rule.maximumYear()) && utcMinutes >= yearMinutes) return false;
        }
        return true;
    }

    static List<CharPair> charSplits(List<Integer> chars) {
        List<CharPair> splits = new ArrayList<>();
        for (int at = 0; at <= chars.size(); at++) {
            splits.add(new CharPair(chars.subList(0, at), chars.subList(at, chars.size())));
        }
        return splits;
    }

    static List<TextPair> stringSplits(String text) {
        return charSplits(toList(text)).stream()
                .map(split -> new TextPair(ofList(split.left()), ofList(split.right())))
                .toList();
    }

    static boolean sequenceAcceptsWith(BiPredicate<FormatRule, String> accepts, List<FormatRule> rules, String text) {
        if (rules.isEmpty()) return text.isEmpty();
        FormatRule first = rules.get(0);
        List<FormatRule> rest = rules.subList(1, rules.size());
        return stringSplits(text).stream()
                .anyMatch(split -> accepts.test(first, split.left()) && sequenceAcceptsWith(accepts, rest, split.right()));
    }

    static List<List<Integer>> splitAtSeparator(List<Integer> separator, int fuel, List<Integer> text) {
        List<List<Integer>> labels = new ArrayList<>();
        List<Integer> label = new ArrayList<>();
        int position = 0;
        int remaining = fuel;
        while (remaining > 0 && position < text.size()) {
            if (text.size() - position >= separator.size()
                    && text.subList(position, position + separator.size()).equals(separator)) {
                labels.add(label);
                label = new ArrayList<>();
                position += separator.size();
            } else {
                label.add(text.get(position));
                position++;
            }
            remaining--;
        }
        label.addAll(text.subList(position, text.size()));
        labels.add(label);
        return labels;
    }

    static List<String> labelParts(String separator, String text) {
        List<Integer> chars = toList(text);
        return splitAtSeparator(toList(separator), chars.size(), chars).stream()
                .map(SemanticFormatSyntax::ofList)
                .toList();
    }
}
