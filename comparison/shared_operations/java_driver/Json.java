// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.comparison;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON value model and parser/writer for the stdin inspection adapter.
 *
 * <p>Inspection-only: no public runtime API depends on this class.
 */
public sealed interface Json permits Json.JNull, Json.JBool, Json.JStr, Json.JNum, Json.JArr, Json.JObj {

    record JNull() implements Json {
    }

    record JBool(boolean value) implements Json {
    }

    record JStr(String value) implements Json {
    }

    /** A JSON number, stored as its raw decimal text so no precision is lost. */
    record JNum(String raw) implements Json {
    }

    record JArr(List<Json> items) implements Json {
    }

    record JObj(Map<String, Json> fields) implements Json {
    }

    Json NULL = new JNull();

    static Json str(String s) {
        return new JStr(s);
    }

    static Json bool(boolean b) {
        return new JBool(b);
    }

    static Json arr(List<Json> items) {
        return new JArr(items);
    }

    static Json obj(Object... kv) {
        LinkedHashMap<String, Json> fields = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) {
            fields.put((String) kv[i], (Json) kv[i + 1]);
        }
        return new JObj(fields);
    }

    static JsonObjBuilder objBuilder() {
        return new JsonObjBuilder();
    }

    final class JsonObjBuilder {
        private final LinkedHashMap<String, Json> fields = new LinkedHashMap<>();

        public JsonObjBuilder put(String key, Json value) {
            fields.put(key, value);
            return this;
        }

        public JObj build() {
            return new JObj(fields);
        }
    }

    /** Thrown for any JSON syntax failure. */
    final class JsonSyntaxException extends RuntimeException {
        public JsonSyntaxException(String message) {
            super(message);
        }
    }

    static Json parse(String text) {
        Parser p = new Parser(text);
        p.skipWhitespace();
        Json value = p.parseValue();
        p.skipWhitespace();
        if (!p.atEnd()) {
            throw new JsonSyntaxException("trailing content after JSON value");
        }
        return value;
    }

    final class Parser {
        private final String text;
        private int pos;

        Parser(String text) {
            this.text = text;
            this.pos = 0;
        }

        boolean atEnd() {
            return pos >= text.length();
        }

        void skipWhitespace() {
            while (pos < text.length() && Character.isWhitespace(text.charAt(pos))) {
                pos++;
            }
        }

        char peek() {
            if (pos >= text.length()) {
                throw new JsonSyntaxException("unexpected end of input");
            }
            return text.charAt(pos);
        }

        void expect(char c) {
            if (atEnd() || text.charAt(pos) != c) {
                throw new JsonSyntaxException("expected '" + c + "' at position " + pos);
            }
            pos++;
        }

        Json parseValue() {
            skipWhitespace();
            char c = peek();
            return switch (c) {
                case '{' -> parseObject();
                case '[' -> parseArray();
                case '"' -> new JStr(parseString());
                case 't', 'f' -> parseBool();
                case 'n' -> parseNull();
                default -> parseNumber();
            };
        }

        Json parseObject() {
            expect('{');
            LinkedHashMap<String, Json> fields = new LinkedHashMap<>();
            skipWhitespace();
            if (!atEnd() && peek() == '}') {
                pos++;
                return new JObj(fields);
            }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                expect(':');
                Json value = parseValue();
                fields.put(key, value);
                skipWhitespace();
                if (!atEnd() && peek() == ',') {
                    pos++;
                    continue;
                }
                expect('}');
                break;
            }
            return new JObj(fields);
        }

        Json parseArray() {
            expect('[');
            List<Json> items = new ArrayList<>();
            skipWhitespace();
            if (!atEnd() && peek() == ']') {
                pos++;
                return new JArr(items);
            }
            while (true) {
                Json value = parseValue();
                items.add(value);
                skipWhitespace();
                if (!atEnd() && peek() == ',') {
                    pos++;
                    continue;
                }
                expect(']');
                break;
            }
            return new JArr(items);
        }

        String parseString() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (true) {
                if (atEnd()) {
                    throw new JsonSyntaxException("unterminated string");
                }
                char c = text.charAt(pos++);
                if (c == '"') {
                    break;
                }
                if (c == '\\') {
                    if (atEnd()) {
                        throw new JsonSyntaxException("unterminated escape");
                    }
                    char esc = text.charAt(pos++);
                    switch (esc) {
                        case '"' -> sb.append('"');
                        case '\\' -> sb.append('\\');
                        case '/' -> sb.append('/');
                        case 'b' -> sb.append('\b');
                        case 'f' -> sb.append('\f');
                        case 'n' -> sb.append('\n');
                        case 'r' -> sb.append('\r');
                        case 't' -> sb.append('\t');
                        case 'u' -> {
                            if (pos + 4 > text.length()) {
                                throw new JsonSyntaxException("invalid unicode escape");
                            }
                            String hex = text.substring(pos, pos + 4);
                            pos += 4;
                            sb.append((char) Integer.parseInt(hex, 16));
                        }
                        default -> throw new JsonSyntaxException("invalid escape: \\" + esc);
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        Json parseBool() {
            if (text.startsWith("true", pos)) {
                pos += 4;
                return new JBool(true);
            }
            if (text.startsWith("false", pos)) {
                pos += 5;
                return new JBool(false);
            }
            throw new JsonSyntaxException("invalid boolean token at position " + pos);
        }

        Json parseNull() {
            if (text.startsWith("null", pos)) {
                pos += 4;
                return new JNull();
            }
            throw new JsonSyntaxException("invalid null token at position " + pos);
        }

        Json parseNumber() {
            int start = pos;
            if (!atEnd() && peek() == '-') {
                pos++;
            }
            if (atEnd() || !Character.isDigit(peek())) {
                throw new JsonSyntaxException("invalid number at position " + pos);
            }
            while (!atEnd() && Character.isDigit(peek())) {
                pos++;
            }
            if (!atEnd() && peek() == '.') {
                pos++;
                while (!atEnd() && Character.isDigit(peek())) {
                    pos++;
                }
            }
            if (!atEnd() && (peek() == 'e' || peek() == 'E')) {
                pos++;
                if (!atEnd() && (peek() == '+' || peek() == '-')) {
                    pos++;
                }
                while (!atEnd() && Character.isDigit(peek())) {
                    pos++;
                }
            }
            return new JNum(text.substring(start, pos));
        }
    }

    static String compress(Json j) {
        StringBuilder sb = new StringBuilder();
        write(j, sb);
        return sb.toString();
    }

    private static void write(Json j, StringBuilder sb) {
        switch (j) {
            case JNull ignored -> sb.append("null");
            case JBool b -> sb.append(b.value());
            case JStr s -> writeString(s.value(), sb);
            case JNum n -> sb.append(n.raw());
            case JArr a -> {
                sb.append('[');
                boolean first = true;
                for (Json item : a.items()) {
                    if (!first) {
                        sb.append(',');
                    }
                    first = false;
                    write(item, sb);
                }
                sb.append(']');
            }
            case JObj o -> {
                sb.append('{');
                boolean first = true;
                for (Map.Entry<String, Json> entry : o.fields().entrySet()) {
                    if (!first) {
                        sb.append(',');
                    }
                    first = false;
                    writeString(entry.getKey(), sb);
                    sb.append(':');
                    write(entry.getValue(), sb);
                }
                sb.append('}');
            }
        }
    }

    private static void writeString(String s, StringBuilder sb) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        sb.append('"');
    }
}
