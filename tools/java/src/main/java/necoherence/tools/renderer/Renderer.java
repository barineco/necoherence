// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Emits Java 21 concrete codecs and executable plans from admitted certificates. */
public final class Renderer {
    private Renderer() {}
    public sealed interface RenderResult permits Rendered, InvalidGeneration {}
    public record Rendered(String source) implements RenderResult {}
    public record InvalidGeneration(String path, String reason) implements RenderResult {}
    /** Selects the Java package (empty for the default package) and public class name. */
    public record JavaTarget(String packageName, String className) {}
    public static RenderResult render(SemanticGeneration.GenerationBasis basis, String exchange, JavaTarget target) {
        if (!validTarget(target)) return new InvalidGeneration("$target", "valid Java package and class name required");
        try { return renderChecked(TypeSignatures.admitGeneration(basis, exchange), target); }
        catch (SemanticGeneration.GenerationFailure failure) { return new InvalidGeneration(failure.path(), failure.condition()); }
    }
    public static RenderResult renderChecked(SemanticGeneration.CheckedGeneration checked, JavaTarget target) {
        if (!validTarget(target)) return new InvalidGeneration("$target", "valid Java package and class name required");
        if (checked == null) return new InvalidGeneration("$", "checked generation required");
        try { return new Rendered(new Emitter(checked, target).emit()); }
        catch (IllegalArgumentException failure) { return new InvalidGeneration("$identifiers", failure.getMessage()); }
    }
    private static final Set<String> KEYWORDS = Set.of("abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "record", "sealed", "permits", "yield", "var", "_");
    private static boolean validTarget(JavaTarget target) {
        if (target == null || target.packageName() == null || !validIdentifier(target.className())) return false;
        if (target.packageName().isEmpty()) return true;
        for (String part : target.packageName().split("\\.", -1)) if (!validIdentifier(part)) return false;
        return true;
    }
    private static boolean validIdentifier(String name) {
        return name != null && javax.lang.model.SourceVersion.isIdentifier(name) && !KEYWORDS.contains(name);
    }
    private static String identifier(String text) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' && !out.isEmpty() || c == '$' || c == '_') out.append(c);
            else out.append('_').append(Integer.toHexString(c)).append('_');
        }
        if (out.isEmpty()) out.append("value"); if (KEYWORDS.contains(out.toString())) out.insert(0, "field_"); return out.toString();
    }
    private static String prefix(String text) {
        StringBuilder out = new StringBuilder(); boolean first = true;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9')) { first = true; continue; }
            if (out.isEmpty() && c >= '0' && c <= '9') out.append('N'); out.append(first ? Character.toUpperCase(c) : c); first = false;
        }
        return out.isEmpty() ? "Value" : out.toString();
    }
    private static String fieldIdentifier(String text) {
        String name = identifier(text);
        return Set.of("extra", "wire", "encode", "decode", "decodeWithDefaults", "fromWire", "rawWire", "of", "validate", "outcomeId", "embeddingId", "_memberOrder").contains(name) ? "field_" + name : name;
    }
    private static String quote(String text) {
        StringBuilder out = new StringBuilder(); appendString(text, out); return out.toString();
    }
    private record Field(String wire, String name, String type, String read, String write, WireValue reference) {}
    private static final class Emitter {
        final SemanticGeneration.CheckedGeneration checked; final Context context; final WireValue input, problem;
        final JavaTarget target;
        final String runtimeName;
        final StringBuilder runtime = new StringBuilder();
        final StringBuilder out = new StringBuilder(); final Map<Integer, String> names = new HashMap<>();
        final Map<WireValue, Integer> contracts = new LinkedHashMap<>(); final Map<WireValue, String> functions = new LinkedHashMap<>();
        final Map<WireValue, Integer> producers = new LinkedHashMap<>(); final Map<WireValue, WireValue> producerContracts = new LinkedHashMap<>();
        final List<WireValue> trees = new ArrayList<>(); final Map<WireValue, Integer> treeIds = new HashMap<>(); final Set<String> reserved = new HashSet<>();
        int initializerId;
        String collection(StringBuilder owner, String type, String mutable, String freeze, List<String> statements) {
            String method = "_initialize" + initializerId++;
            List<String> calls = new ArrayList<>();
            for (int start = 0; start < statements.size(); start += 64) {
                String part = method + "Part" + calls.size();
                line(owner, "  private static void " + part + "(" + type + " value) {");
                for (int i = start; i < Math.min(start + 64, statements.size()); i++) line(owner, "    " + statements.get(i));
                line(owner, "  }");
                calls.add(part + "(value);");
            }
            int level = 0;
            while (calls.size() > 64) {
                List<String> parents = new ArrayList<>();
                for (int start = 0; start < calls.size(); start += 64) {
                    String part = method + "Level" + level + "Part" + parents.size();
                    line(owner, "  private static void " + part + "(" + type + " value) {");
                    for (int i = start; i < Math.min(start + 64, calls.size()); i++) line(owner, "    " + calls.get(i));
                    line(owner, "  }");
                    parents.add(part + "(value);");
                }
                calls = parents;
                level++;
            }
            line(owner, "  private static " + type + " " + method + "() { " + type + " value=" + mutable + ";");
            for (String call : calls) line(owner, "    " + call);
            line(owner, "    return " + freeze + "; }");
            return method + "()";
        }
        String map(StringBuilder owner, String key, String value, List<String> entries) {
            return collection(owner, "Map<" + key + "," + value + ">", "new HashMap<>()", "Map.copyOf(value)", entries);
        }
        String initialized(StringBuilder owner, String type, String expression) {
            String method = "_initialize" + initializerId++;
            line(owner, "  private static " + type + " " + method + "() { return " + expression + "; }");
            return method + "()";
        }
        Emitter(SemanticGeneration.CheckedGeneration checked, JavaTarget target) {
            this.target = target;
            this.checked = checked; context = checked.context; input = signatureInput(checked.input); problem = nil(f(input, "composition")) ? NIL : f(f(input, "composition"), "problem");
            reserved.addAll(List.of("InitialInputs", "Goals", "Providers", "Frame", "RunResult", "Succeeded", "Failed", "Pending", "Rejected", "Continuation", "ExecutionFailure", "InvalidValue", "InvalidProvider", "ProviderFailed", "NetworkFailed", "CertificateFailed", "InvalidContinuation", "FailureResult"));
            reserve(target.className());
            for (int type : checked.types) {
                String name = "Type" + prefix(s(f(context.reference(type), "definition_name"))); reserve(name); names.put(type, name);
            }
            for (WireValue provider : checked.providers) { String name = prefix(s(f(f(provider, "reference"), "identity"))); reserve(name + "Input"); reserve(name + "Outcome"); reserve(name + "Provider"); functions.put(f(provider, "reference"), name); for (WireValue port : a(f(provider, "inputs"))) port(f(port, "contract")); for (WireValue outcome : a(f(provider, "outcomes"))) for (WireValue output : a(f(outcome, "value_ports"))) port(f(output, "contract")); }
            for(WireValue definition:checked.definitions) if(tag(f(definition,"shape")).equals("Operation")) { WireValue op=payload(f(definition,"shape"));for(WireValue p:a(f(op,"inputs")))port(TypeSignatures.internalSlot(f(p,"contract")));for(WireValue outcome:a(f(op,"outcomes")))for(WireValue p:a(f(outcome,"value_ports")))port(TypeSignatures.internalSlot(f(p,"contract"))); }
            for (int type : checked.types) if (tag(context.shape(type)).equals("Product")) for (WireValue field : a(f(payload(context.shape(type)), "fields"))) port(f(field, "slot"));
            if (hasComposition()) {
                for (WireValue initial : a(f(problem, "initial_inputs"))) { port(f(initial, "contract")); producer(variant("Initial", f(initial, "id")), f(initial, "contract")); }
                for (WireValue output : a(f(f(problem, "goal"), "outputs"))) port(f(output, "contract")); for (WireValue failure : a(f(f(problem, "goal"), "failures"))) port(f(failure, "contract"));
                collect(f(f(f(f(input, "composition"), "derivation"), "plan"), "root"));
            }
            runtimeName = runtimeIdentifier();
            reserve(runtimeName);
        }
        String runtimeIdentifier() {
            Set<String> forbidden = new HashSet<>(reserved);
            forbidden.add(target.className());
            for (int type : checked.types) {
                if (tag(context.shape(type)).equals("Product")) {
                    for (WireValue field : a(f(payload(context.shape(type)), "fields"))) forbidden.add(fieldIdentifier(s(f(field, "wire_name"))));
                } else if (tag(context.shape(type)).equals("TaggedUnion")) {
                    for (int i = 0; i < a(f(payload(context.shape(type)), "branches")).size(); i++) forbidden.add(names.get(type) + "Branch" + i);
                }
            }
            for (WireValue provider : checked.providers) {
                String name = functions.get(f(provider, "reference"));
                operationNames(forbidden, name, provider);
                forbidden.add(providerField(provider));
                for (WireValue outcome : a(f(provider, "outcomes"))) forbidden.add(outcomeName(name, outcome));
            }
            for (WireValue definition : checked.definitions) {
                String name = prefix(s(f(definition, "id")));
                if (tag(f(definition, "shape")).equals("Operation")) operationNames(forbidden, name, payload(f(definition, "shape")));
                else if (tag(f(definition, "shape")).equals("Symbol")) forbidden.add(name + "Symbol");
            }
            if (hasComposition()) {
                portNames(forbidden, a(f(problem, "initial_inputs")));
                portNames(forbidden, a(f(f(problem, "goal"), "outputs")));
                for (WireValue failure : a(f(f(problem, "goal"), "failures"))) forbidden.add(prefix(s(f(failure, "id"))) + "Failure");
            }
            String name = "_Runtime";
            while (forbidden.contains(name)) name += "_";
            return name;
        }
        void operationNames(Set<String> forbidden, String name, WireValue operation) {
            for (String suffix : List.of("Input", "Outcome", "Provider", "HttpBinding", "OperationInput", "Preparation", "Ready", "Completed", "Binding", "Start", "Prepared", "Started")) forbidden.add(name + suffix);
            portNames(forbidden, a(f(operation, "inputs")));
            for (WireValue outcome : a(f(operation, "outcomes"))) {
                forbidden.add(name + prefix(s(f(outcome, "id"))));
                portNames(forbidden, a(f(outcome, "value_ports")));
            }
        }
        void portNames(Set<String> forbidden, List<WireValue> ports) {
            for (WireValue port : ports) forbidden.add(fieldIdentifier(s(f(port, "id"))));
        }
        String tagKey() { return context.tagKey(); }
        String typeRef(int type) { return runtimeName + ".CONTEXT.reference(" + type + ")"; }
        boolean hasComposition() { return !nil(f(input,"composition")); }
        void reserve(String name) { if (!reserved.add(name)) throw new IllegalArgumentException("Java identifier collision: " + name); }
        int port(WireValue contract) { return contracts.computeIfAbsent(contract, unused -> contracts.size()); }
        void producer(WireValue producer, WireValue contract) { if (!producers.containsKey(producer)) { producers.put(producer, producers.size()); producerContracts.put(producer, contract); } }
        int collect(WireValue tree) {
            if (treeIds.containsKey(tree)) return treeIds.get(tree); int id = trees.size(); treeIds.put(tree, id); trees.add(tree);
            WireValue node = f(tree, "node");
            if (tag(node).equals("Invoke")) {
                WireValue invocation = f(payload(node), "invocation"), signature = null; for (WireValue candidate : checked.providers) if (f(candidate, "reference").equals(f(invocation, "function"))) signature = candidate;
                if (signature != null) for (WireValue outcome : a(f(signature, "outcomes"))) for (WireValue output : a(f(outcome, "value_ports"))) producer(fields("InvocationOutcome", obj("site", f(invocation, "site"), "outcome", f(outcome, "id"), "port", f(output, "id"))), f(output, "contract"));
            }
            if (!tag(node).equals("Return")) for (WireValue arm : a(f(payload(node), "arms"))) collect(a(arm).get(1)); return id;
        }
        String storage(int type) {
            return switch (tag(context.shape(type))) {
                case "Boolean" -> "Boolean";
                case "Integer" -> "BigInteger";
                case "Decimal", "String" -> "String";
                case "Bytes" -> "Bytes";
                case "Unit" -> "Unit";
                case "Unknown" -> "WireValue";
                case "RawBody" -> "RawBody";
                case "Never" -> names.get(type);
                default -> { String name = names.get(type); if (name == null) throw new IllegalArgumentException("type outside admitted surface"); yield name; }
            };
        }
        String nativePort(WireValue contract) {
            String type = storage(context.index(f(contract, "type_ref"))); boolean required = b(f(contract, "required")), nullable = b(f(contract, "nullable"));
            return required ? nullable ? "Nullable<" + type + ">" : type : nullable ? "Slot<" + type + ">" : "Optional<" + type + ">";
        }
        void line(StringBuilder owner, String text) { owner.append(text).append('\n'); }
        void line(String text) { line(out, text); }
        void runtimeLine(String text) { line(runtime, text); }
        String emit() {
            line("// SPDX-License-Identifier: MIT");
            if (!target.packageName().isEmpty()) line("package " + target.packageName() + ";");
            line("import necoherence.semantic.TypeSignatures;");
            line("import java.math.BigInteger;"); line("import java.util.*;"); line("import necoherence.semantic.SemanticGeneration;"); line("import necoherence.semantic.SemanticGeneration.*;"); line("import necoherence.semantic.SemanticValues;"); line("import necoherence.semantic.SemanticValues.*;"); line("import necoherence.network.NetworkEffect;"); line("public final class " + target.className() + " {");
            line("  public static final String GENERATION_PACKAGE = " + quote(target.packageName()) + ";");
            line("  public static final String GENERATION_CLASS = " + quote(target.className()) + ";");
            line("  private " + target.className() + "() {}");
            runtimeLine("  private static final CheckedGeneration CHECKED = load();");
            runtimeLine("  private static final Context CONTEXT = " + runtimeName + ".CHECKED.valueContext();");
            runtimeLine("  private static CheckedGeneration load() { try { return TypeSignatures.admitGeneration(GenerationBasis.decode(basisText()), exchangeText()); } catch (GenerationFailure failure) { throw new ExceptionInInitializerError(failure); } }");
            embed(runtime, "basisText", checked.basis.encode()); embed(runtime, "exchangeText", encodeWire(checked.input)); helpers();
            for (int type : checked.types) type(type);
            for (Map.Entry<WireValue, Integer> entry : contracts.entrySet()) portCodec(entry.getKey(), entry.getValue());
            for (WireValue provider : checked.providers) provider(provider);
            signatureDefinitions(); if (hasComposition()) composition();
            line("  private static final class " + runtimeName + " {");
            out.append(runtime.toString().indent(2));
            line("  }");
            line("}"); return out.toString();
        }
        void embed(StringBuilder owner, String method, String text) {
            List<String> chunks = new ArrayList<>(); for (int start = 0; start < text.length();) { int end = Math.min(text.length(), start + 4000); if (end < text.length() && Character.isHighSurrogate(text.charAt(end - 1))) end--; chunks.add("value.append(" + quote(text.substring(start, end)) + ");"); start = end; }
            String initialized = collection(owner, "StringBuilder", "new StringBuilder(" + text.length() + ")", "value", chunks);
            line(owner, "  private static String " + method + "() { return " + initialized + ".toString(); }");
        }
        void helpers() {
            runtimeLine("  @FunctionalInterface private interface Writer<T> { WireValue write(T value) throws ValueFailure; }");
            runtimeLine("  private static <T> T nonNull(T value,WireValue reference,List<WireValue> path) throws ValueFailure { if(value==null) throw new ValueFailure(reference,path,\"NullNotAllowed\"); if(value instanceof String text) for(int i=0;i<text.length();i++){ char c=text.charAt(i); if(Character.isHighSurrogate(c)){ if(++i==text.length() || !Character.isLowSurrogate(text.charAt(i))) throw new ValueFailure(reference,path,\"InvalidUnicode\"); } else if(Character.isLowSurrogate(c)) throw new ValueFailure(reference,path,\"InvalidUnicode\"); } return value; }");
            runtimeLine("  private static WireValue parseWire(WireValue reference,String wire) throws ValueFailure { try { return SemanticGeneration.readJson(wire); } catch(RuntimeException error) { throw new ValueFailure(reference,List.of(),\"InvalidJson: \"+error.getMessage()); } }");
            runtimeLine("  private static <T> Slot<WireValue> wireSlot(Slot<T> value, Writer<T> writer) throws ValueFailure { if(value instanceof Absent<T>) return new Absent<>(); if(value instanceof NullSlot<T>) return new NullSlot<>(); return new Present<>(writer.write(((Present<T>)value).value())); }");
            runtimeLine("  private static Slot<WireValue> field(WireValue value) { return value == null ? new Absent<>() : value instanceof NullValue ? new NullSlot<>() : new Present<>(value); }");
            runtimeLine("  private static WireValue scalar(Slot<WireValue> value) { return ((Present<WireValue>)value).value(); }");
            String discriminatorKey = quote(tagKey());
            runtimeLine("  private static WireValue tagged(WireValue reference,WireValue value, String tag) throws ValueFailure { ObjectValue object=(ObjectValue)value; WireValue previous=object.get("+discriminatorKey+"); if(previous != null && !new StringValue(tag).equals(previous)) throw new ValueFailure(reference,List.of(SemanticValues.variant(\"Field\",new StringValue("+discriminatorKey+"))),\"InvalidTag\"); if(previous != null) return value; return SemanticValues.withMember("+discriminatorKey+",tag,value); }");
            runtimeLine("  private static void put(List<Member> fields,String key,Slot<WireValue> value) { if(value instanceof Present<WireValue> present) fields.add(new Member(key,present.value())); else if(value instanceof NullSlot<WireValue>) fields.add(new Member(key,new NullValue())); }");
            runtimeLine("  private static Map<String,WireValue> extras(ObjectValue value,Set<String> known) { Map<String,WireValue> result=new LinkedHashMap<>(); for(Member member:value.members()) if(!known.contains(member.key())) result.put(member.key(),member.value()); return result; }");
            runtimeLine("  private static Map<String,WireValue> copyExtra(Map<String,WireValue> value,Set<String> known,WireValue reference) throws ValueFailure { Map<String,WireValue> result=new LinkedHashMap<>(); for(var entry:nonNull(value,reference,List.of()).entrySet()){ List<WireValue> path=List.of(SemanticValues.variant(\"Field\",new StringValue(entry.getKey()))); if(known.contains(entry.getKey())) throw new ValueFailure(reference,path,\"UnexpectedField: known field in extra\"); result.put(entry.getKey(),nonNull(entry.getValue(),reference,path)); } return Collections.unmodifiableMap(result); }");
            runtimeLine("  private static WireValue bytesWire(Bytes value) { return " + runtimeName + ".CONTEXT.encodeBytes(value); }");
        }
        void codec(int type) {
            String kind = tag(context.shape(type)), nativeType = storage(type), read, write;
            if (kind.equals("Never")) {
                runtimeLine("  private static " + nativeType + " read" + type + "(WireValue value) throws ValueFailure { throw new ValueFailure(" + typeRef(type) + ",List.of(),\"Uninhabited\"); }");
                runtimeLine("  private static WireValue write" + type + "(" + nativeType + " value) throws ValueFailure { throw new ValueFailure(" + typeRef(type) + ",List.of(),\"Uninhabited\"); }");
                return;
            }
            switch (kind) {
                case "Boolean" -> { read = "((BooleanValue)value).value()"; write = "new BooleanValue(value)"; }
                case "Integer" -> { read = "new BigInteger(value instanceof StringValue text ? text.value() : ((IntegerValue)value).value().toString())"; write = "new IntegerValue(value)"; }
                case "Decimal" -> { read = "((DecimalValue)value).text()"; write = "new DecimalValue(value)"; }
                case "String" -> { read = runtimeName + ".CONTEXT.decodeText(" + typeRef(type) + ",value)"; write = runtimeName + ".CONTEXT.encodeText(" + typeRef(type) + ",value)"; }
                case "Bytes" -> { read = runtimeName + ".CONTEXT.decodeBytes(" + typeRef(type) + ",value)"; write = "bytesWire(value)"; }
                case "Unit" -> { read = "Unit.VALUE"; write = "new NullValue()"; }
                case "Unknown" -> { read = "value"; write = "value"; }
                case "RawBody" -> { read = "new RawBody(" + quote(s(f(payload(context.shape(type)), "encoding"))) + "," + runtimeName + ".CONTEXT.decodeBytes(" + typeRef(type) + ",value))"; write = "bytesWire(value.bytes())"; }
                default -> { read = names.get(type) + ".decoded(value)"; write = "value.rawWire()"; }
            }
            runtimeLine("  private static " + nativeType + " read" + type + "(WireValue value) throws ValueFailure { return " + read + "; }");
            runtimeLine("  private static WireValue write" + type + "(" + nativeType + " value) throws ValueFailure { nonNull(value," + typeRef(type) + ",List.of());" + (kind.equals("RawBody") ? " if(!value.encoding().equals(" + quote(s(f(payload(context.shape(type)), "encoding"))) + ")) throw new ValueFailure(" + typeRef(type) + ",List.of(),\"RawBody encoding\");" : "") + " return " + write + "; }");
        }
        void type(int type) {
            String kind = tag(context.shape(type));
            if (kind.equals("Product")) product(type);
            else if (kind.equals("TaggedUnion")) union(type);
            else if (kind.equals("Array")) array(type);
            else if (kind.equals("Sealed")) opaqueCarrier(type);
            else if (kind.equals("Never")) never(type);
            else scalarType(type);
            codec(type);
        }
        void scalarType(int type) {
            String name = names.get(type), kind = tag(context.shape(type));
            int target = kind.equals("Alias") ? context.index(f(payload(context.shape(type)), "target")) : type;
            String stored = storage(target);
            line("  public static final class " + name + " {"); line("    private final " + stored + " value;"); line("    private " + name + "(" + stored + " value) throws ValueFailure { this.value=" + runtimeName + ".nonNull(value," + typeRef(type) + ",List.of()); }");
            line("    public static " + name + " of(" + stored + " value) throws ValueFailure { " + name + " result=new " + name + "(value); " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",result.rawWire()); return result; }");
            String decode = kind.equals("Alias") ? runtimeName + ".read" + target + "(value)" : primitiveRead(type, "value");
            line("    private static " + name + " decoded(WireValue value) throws ValueFailure { return new " + name + "(" + decode + "); }");
            line("    public static " + name + " fromWire(WireValue value) throws ValueFailure { " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",value); return decoded(value); }");
            line("    public static " + name + " decode(String text) throws ValueFailure { return decoded(" + runtimeName + ".CONTEXT.decode(" + typeRef(type) + ",text)); }"); line("    public static " + name + " decodeWithDefaults(String text) throws ValueFailure { return decoded(" + runtimeName + ".CONTEXT.decodeWithDefaults(" + typeRef(type) + ",text).value()); }");
            line("    public " + stored + " value() { return value; }");
            String raw = kind.equals("Alias") ? runtimeName + ".write" + target + "(value)" : primitiveWrite(type, "value");
            line("    private WireValue rawWire() throws ValueFailure { return " + raw + "; }"); line("    public WireValue wire() throws ValueFailure { WireValue value=rawWire(); " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",value); return value; }"); line("    public String encode() throws ValueFailure { return SemanticValues.encodeWire(wire()); }"); line("  }");
        }
        String primitiveRead(int type, String value) {
            return switch (tag(context.shape(type))) { case "Boolean" -> "((BooleanValue)" + value + ").value()"; case "Integer" -> "new BigInteger(" + value + " instanceof StringValue text ? text.value() : ((IntegerValue)" + value + ").value().toString())"; case "Decimal" -> "((DecimalValue)" + value + ").text()"; case "String" -> runtimeName + ".CONTEXT.decodeText(" + typeRef(type) + "," + value + ")"; case "Bytes" -> runtimeName + ".CONTEXT.decodeBytes(" + typeRef(type) + "," + value + ")"; case "RawBody" -> "new RawBody(" + quote(s(f(payload(context.shape(type)), "encoding"))) + "," + runtimeName + ".CONTEXT.decodeBytes(" + typeRef(type) + "," + value + "))"; case "Unit" -> "Unit.VALUE"; default -> value; };
        }
        String primitiveWrite(int type, String value) {
            return switch (tag(context.shape(type))) { case "Boolean" -> "new BooleanValue(" + value + ")"; case "Integer" -> "new IntegerValue(" + value + ")"; case "Decimal" -> "new DecimalValue(" + value + ")"; case "String" -> runtimeName + ".CONTEXT.encodeText(" + typeRef(type) + "," + value + ")"; case "Bytes" -> runtimeName + ".bytesWire(" + value + ")"; case "RawBody" -> runtimeName + ".write" + type + "(" + value + ")"; case "Unit" -> "new NullValue()"; default -> value; };
        }
        void product(int type) {
            String name = names.get(type); List<Field> fields = new ArrayList<>(); Set<String> fieldNames = new HashSet<>(); List<WireValue> specs = a(f(payload(context.shape(type)), "fields"));
            for (WireValue field : specs) {
                String wire = s(f(field, "wire_name")), java = fieldIdentifier(wire); if (!fieldNames.add(java) || java.equals("extra")) throw new IllegalArgumentException("Java field collision: " + name + "." + java);
                int port = port(f(field, "slot")); fields.add(new Field(wire, java, nativePort(f(field, "slot")), runtimeName + ".readPort" + port + "(" + runtimeName + ".field(object.get(" + quote(wire) + ")))", runtimeName + ".wirePort" + port + "(" + java + ")", f(f(field, "slot"), "type_ref")));
            }
            fields.add(new Field("", "extra", "Map<String,WireValue>", runtimeName + ".extras(object,KNOWN)", "", context.reference(type)));
            line("  public static final class " + name + " {"); line("    private static final Set<String> KNOWN=Set.of(" + String.join(",", specs.stream().map(field -> quote(s(f(field, "wire_name")))).toList()) + ");");
            dataClass(name, fields, "      this.extra=Collections.unmodifiableMap(new LinkedHashMap<>(extra));", false, true);
            line("    public static " + name + " of(" + parameters(fields) + ") throws ValueFailure { extra=" + runtimeName + ".copyExtra(extra,KNOWN," + typeRef(type) + "); " + name + " result=new " + name + "(" + arguments(fields) + "); " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",result.rawWire()); return result; }");
            List<Field> known = fields.subList(0, fields.size() - 1);
            line("    public static " + name + " of(" + parameters(known) + ") throws ValueFailure { return of(" + arguments(known) + (known.isEmpty() ? "" : ",") + "Map.of()); }");
            line("    private static " + name + " decoded(WireValue value) throws ValueFailure { ObjectValue object=(ObjectValue)value; return new " + name + "(" + String.join(",", fields.stream().map(Field::read).toList()) + ",object.members().stream().map(Member::key).toList()); }");
            commonDecode(name, type);
            line("    private WireValue rawWire() throws ValueFailure { List<Member> fields=new ArrayList<>();"); for (Field field : known) line("      " + runtimeName + ".put(fields," + quote(field.wire()) + "," + field.write() + ");"); line("      for(var entry:extra.entrySet()) fields.add(new Member(entry.getKey(),entry.getValue())); return SemanticValues.orderedObject(fields,_memberOrder); }"); commonEncode(type); line("  }");
        }
        void dataClass(String name, List<Field> fields, String special, boolean validatePorts, boolean ordered) {
            for (Field field : fields) line("    private final " + field.type() + " " + field.name() + ";");
            if (ordered) {
                line("    private final List<String> _memberOrder;");
                line("    private " + name + "(" + parameters(fields) + ") throws ValueFailure { this(" + arguments(fields) + ",List.of()); }");
            }
            line("    private " + name + "(" + parameters(fields) + (ordered ? ",List<String> _memberOrder" : "") + ") throws ValueFailure {");
            for (Field field : fields) if (!field.name().equals("extra") || special.isEmpty()) line("      this." + field.name() + "=" + runtimeName + ".nonNull(" + field.name() + "," + wireText(field.reference()) + ",List.of(SemanticValues.variant(\"Field\",new StringValue(" + quote(field.wire()) + "))));");
            if (!special.isEmpty()) line(special);
            if (ordered) line("      this._memberOrder=List.copyOf(_memberOrder);");
            line("    }");
            for (Field field : fields) line("    public " + field.type() + " " + field.name() + "() { return " + field.name() + "; }");
            if (validatePorts) { line("    public void validate() throws ValueFailure {"); for (Field field : fields) line("      " + field.write() + ";"); line("    }"); }
        }
        String parameters(List<Field> fields) { return String.join(",", fields.stream().map(field -> field.type() + " " + field.name()).toList()); }
        String arguments(List<Field> fields) { return String.join(",", fields.stream().map(Field::name).toList()); }
        void commonDecode(String name, int type) {
            line("    public static " + name + " fromWire(WireValue value) throws ValueFailure { " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",value); return decoded(value); }"); line("    public static " + name + " decode(String text) throws ValueFailure { return decoded(" + runtimeName + ".CONTEXT.decode(" + typeRef(type) + ",text)); }"); line("    public static " + name + " decodeWithDefaults(String text) throws ValueFailure { return decoded(" + runtimeName + ".CONTEXT.decodeWithDefaults(" + typeRef(type) + ",text).value()); }");
        }
        void commonEncode(int type) { line("    public WireValue wire() throws ValueFailure { WireValue value=rawWire(); " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",value); return value; }"); line("    public String encode() throws ValueFailure { return SemanticValues.encodeWire(wire()); }"); }
        void opaqueCarrier(int type) {
            String name=names.get(type);
            line("  public static final class "+name+" { private final WireValue value; private "+name+"(WireValue value){this.value=value;} public static "+name+" fromWire(WireValue value) throws ValueFailure { " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",value); return new "+name+"(value); } private static "+name+" decoded(WireValue value){return new "+name+"(value);} public WireValue value(){return value;} private WireValue rawWire(){return value;} public String encode() throws ValueFailure { " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",value); return SemanticValues.encodeWire(value); } }");
        }
        void never(int type) {
            line("  public static final class "+names.get(type)+" { private "+names.get(type)+"() {} }");
        }
        void array(int type) {
            String name = names.get(type); WireValue itemContract=f(payload(context.shape(type)), "item"); int item = context.index(f(itemContract,"type_ref")); String itemType = storage(item);
            line("  public static final class " + name + " {"); line("    private final List<" + itemType + "> items;"); line("    private " + name + "(List<" + itemType + "> items) throws ValueFailure { " + runtimeName + ".nonNull(items," + typeRef(type) + ",List.of()); for(int i=0;i<items.size();i++) " + runtimeName + ".nonNull(items.get(i)," + typeRef(type) + ",List.of(SemanticValues.variant(\"Index\",new StringValue(Integer.toString(i))))); this.items=List.copyOf(items); }");
            line("    public static " + name + " of(List<" + itemType + "> items) throws ValueFailure { " + name + " result=new " + name + "(items); " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",result.rawWire()); return result; }");
            line("    private static " + name + " decoded(WireValue value) throws ValueFailure { List<" + itemType + "> items=new ArrayList<>(); for(WireValue item:((ArrayValue)value).items()) items.add(" + runtimeName + ".read" + item + "(item)); return new " + name + "(items); }"); commonDecode(name, type);
            line("    public List<" + itemType + "> items() { return items; }"); line("    private WireValue rawWire() throws ValueFailure { List<WireValue> values=new ArrayList<>(); for(" + itemType + " item:items) values.add(" + runtimeName + ".write" + item + "(item)); return new ArrayValue(values); }"); commonEncode(type); line("  }");
        }
        void union(int type) {
            String name = names.get(type); WireValue spec = payload(context.shape(type)); List<WireValue> branches = a(f(spec, "branches")); List<String> variants = new ArrayList<>();
            for (int i = 0; i < branches.size(); i++) { reserve(name + "Branch" + i); variants.add(name + "Branch" + i); }
            line("  public static abstract sealed class " + name + " permits " + String.join(",", variants) + " {"); line("    private " + name + "() {}"); line("    abstract WireValue rawWire() throws ValueFailure;");
            line("    private static " + name + " decoded(WireValue value) throws ValueFailure { switch(" + runtimeName + ".CONTEXT.selectBranch(" + typeRef(type) + ",value)) {");
            for (int i = 0; i < branches.size(); i++) line("      case " + i + ": return new " + name + "Branch" + i + "(" + runtimeName + ".read" + context.index(f(branches.get(i), "target")) + "(value));");
            line("      default: throw new ValueFailure(" + typeRef(type) + ",List.of(),\"NoBranchSelected\"); } }"); commonDecode(name, type); commonEncode(type); line("  }");
            for (int i = 0; i < branches.size(); i++) {
                WireValue branch = branches.get(i); int targetType = context.index(f(branch, "target")); String variant = name + "Branch" + i, javaType = storage(targetType);
                String encoded=tag(f(branch,"selector")).equals("InternalTag")?runtimeName + ".tagged("+typeRef(type)+"," + runtimeName + ".write"+targetType+"(value),"+quote(s(f(branch,"wire_tag")))+")":runtimeName + ".write"+targetType+"(value)";
                line("  public static final class " + variant + " extends " + name + " {"); line("    private final " + javaType + " value;"); line("    private " + variant + "(" + javaType + " value) throws ValueFailure { this.value=" + runtimeName + ".nonNull(value," + typeRef(type) + ",List.of()); }"); line("    public static " + variant + " of(" + javaType + " value) throws ValueFailure { " + variant + " result=new " + variant + "(value); " + runtimeName + ".CONTEXT.validate(" + typeRef(type) + ",result.rawWire()); return result; }"); line("    public " + javaType + " value() { return value; }"); line("    WireValue rawWire() throws ValueFailure { return "+encoded+"; }"); line("  }");
            }
        }
        void portCodec(WireValue contract, int id) {
            int type = context.index(f(contract, "type_ref")); String storage = storage(type), nativeType = nativePort(contract); boolean required = b(f(contract, "required")), nullable = b(f(contract, "nullable"));
            runtimeLine("  private static " + nativeType + " readPort" + id + "(Slot<WireValue> value) throws ValueFailure { " + runtimeName + ".CONTEXT.validateSlot(" + typeRef(type) + "," + required + "," + nullable + ",value);");
            if (required && !nullable) runtimeLine("    return read" + type + "(scalar(value));");
            else if (required) runtimeLine("    return value instanceof NullSlot<WireValue> ? new Null<>() : new NonNull<>(read" + type + "(scalar(value)));");
            else if (!nullable) runtimeLine("    return value instanceof Absent<WireValue> ? Optional.empty() : Optional.of(read" + type + "(scalar(value)));");
            else runtimeLine("    if(value instanceof Absent<WireValue>) return new Absent<>(); if(value instanceof NullSlot<WireValue>) return new NullSlot<>(); return new Present<>(read" + type + "(scalar(value)));"); runtimeLine("  }");
            runtimeLine("  private static Slot<WireValue> wirePort" + id + "(" + nativeType + " value) throws ValueFailure { nonNull(value," + typeRef(type) + ",List.of()); Slot<WireValue> result;");
            if (required && !nullable) runtimeLine("    result=new Present<>(write" + type + "(value));");
            else if (required) runtimeLine("    result=value instanceof Null<" + storage + "> ? new NullSlot<>() : new Present<>(write" + type + "(((NonNull<" + storage + ">)value).value()));");
            else if (!nullable) runtimeLine("    result=value.isEmpty() ? new Absent<>() : new Present<>(write" + type + "(value.get()));");
            else runtimeLine("    result=wireSlot(value," + runtimeName + "::write" + type + ");");
            runtimeLine("    " + runtimeName + ".CONTEXT.validateSlot(" + typeRef(type) + "," + required + "," + nullable + ",result); return result; }");
            runtimeLine("  private static Slot<" + storage + "> liftPort" + id + "(" + nativeType + " value) {");
            if (required && !nullable) runtimeLine("    return new Present<>(value);");
            else if (required) runtimeLine("    return value instanceof Null<" + storage + "> ? new NullSlot<>() : new Present<>(((NonNull<" + storage + ">)value).value());");
            else if (!nullable) runtimeLine("    return value.isEmpty() ? new Absent<>() : new Present<>(value.get());");
            else runtimeLine("    return value;"); runtimeLine("  }");
        }
        List<Field> portFields(List<WireValue> ports) {
            List<Field> result = new ArrayList<>(); Set<String> names = new HashSet<>();
            for (WireValue port : ports) {
                String name = fieldIdentifier(s(f(port, "id"))); if (!names.add(name)) throw new IllegalArgumentException("Java port identifier collision: " + name);
                int contract = port(f(port, "contract")); result.add(new Field(s(f(port, "id")), name, nativePort(f(port, "contract")), "", runtimeName + ".wirePort" + contract + "(" + name + ")", f(f(port, "contract"), "type_ref")));
            }
            return result;
        }
        void portClass(String name, List<WireValue> ports, String extension, String extraMethods) {
            List<Field> fields = portFields(ports); line("  public static final class " + name + extension + " {"); dataClass(name, fields, "", true, false);
            String local = "result";
            Set<String> fieldNames = new HashSet<>(); for (Field field : fields) fieldNames.add(field.name());
            while (fieldNames.contains(local)) local += "_";
            line("    public static " + name + " of(" + parameters(fields) + ") throws ValueFailure { " + name + " " + local + "=new " + name + "(" + arguments(fields) + "); " + local + ".validate(); return " + local + "; }");
            if (!extraMethods.isEmpty()) line(extraMethods); line("  }");
        }
        String providerField(WireValue signature) { String name = functions.get(f(signature, "reference")); return Character.toLowerCase(name.charAt(0)) + name.substring(1); }
        String outcomeName(String function, WireValue outcome) { return function + "Outcome" + prefix(s(f(outcome, "id"))); }
        void provider(WireValue signature) {
            String name = functions.get(f(signature, "reference")); List<WireValue> outcomes = a(f(signature, "outcomes"));
            portClass(name + "Input", a(f(signature, "inputs")), "", "");
            List<String> variants = new ArrayList<>(); for (WireValue outcome : outcomes) { String variant = outcomeName(name, outcome); reserve(variant); variants.add(variant); }
            line("  public sealed interface " + name + "Outcome permits " + String.join(",", variants) + " { String outcomeId(); void validate() throws ValueFailure; }");
            for (WireValue outcome : outcomes) portClass(outcomeName(name, outcome), a(f(outcome, "value_ports")), " implements " + name + "Outcome", "    public String outcomeId() { return " + quote(s(f(outcome, "id"))) + "; }");
            if (tag(f(signature, "effect")).equals("PureFunction")) {
                line("  @FunctionalInterface public interface " + name + "Provider { String SIGNATURE_ASSUMPTION=" + quote(s(f(signature, "assumption_ref"))) + "; " + name + "Outcome call(" + name + "Input input,ExecutionSnapshot before) throws Exception; }");
            } else {
                reserve(name + "HttpBinding");
                preparation(name,name+"Input",name+"Outcome",outcomes);
                line("  public record "+name+"HttpBinding("+name+"Binding prepare,OwnerDecoder<"+name+"Outcome> decoder,HostAdapter adapter) { public "+name+"HttpBinding {Objects.requireNonNull(prepare);Objects.requireNonNull(decoder);Objects.requireNonNull(adapter);} }");
            }
        }
        String list(StringBuilder owner, String type, List<String> items) {
            if (!type.equals("String")) items = items.stream().map(item -> initialized(owner, type, item)).toList();
            if (items.size() <= 64) return "List.of(" + String.join(",", items) + ")";
            return collection(owner, "List<" + type + ">", "new ArrayList<>()", "List.copyOf(value)", items.stream().map(item -> "value.add(" + item + ");").toList());
        }
        String stringsText(StringBuilder owner, WireValue values) { return list(owner, "String", a(values).stream().map(value -> quote(s(value))).toList()); }
        static WireValue signatureInput(WireValue input) { return !nil(f(input,"composition")) ? TypeSignatures.replace(input,"composition",TypeSignatures.internalComposition(f(input,"composition"))) : input; }
        void signatureDefinitions() {
            line("  @FunctionalInterface public interface Decoder<T> { T decode(String wire) throws ValueFailure; }");
            line("  @FunctionalInterface public interface Encoder<T> { String encode(T value) throws ValueFailure; }");
            line("  public record Codec<T>(Decoder<T> decoder,Decoder<T> defaultDecoder,Encoder<T> encoder) { public T decodeWithDefaults(String wire) throws ValueFailure { return defaultDecoder.decode(wire); } }");
            line("  public static final Map<String,String> TYPE_NAMES=" + map(out,"String","String",checked.types.stream().map(t->"value.put("+quote(s(f(context.reference(t),"definition_name")))+","+quote(storage(t))+");").toList()) + ";");
            line("  public static final Map<String,Codec<?>> CODECS=" + map(out,"String","Codec<?>",checked.types.stream().map(t->"value.put("+quote(s(f(context.reference(t),"definition_name")))+",new Codec<"+storage(t)+">(wire->" + runtimeName + ".read"+t+"(" + runtimeName + ".CONTEXT.decode("+typeRef(t)+",wire)),wire->" + runtimeName + ".read"+t+"(" + runtimeName + ".CONTEXT.decodeWithDefaults("+typeRef(t)+",wire).value()),item->{WireValue wire=" + runtimeName + ".write"+t+"(item);" + runtimeName + ".CONTEXT.validate("+typeRef(t)+",wire);return SemanticValues.encodeWire(wire);}));").toList()) + ";");
            line("  public static final List<WireValue> ANNOTATIONS=TypeSignatures.annotations(" + runtimeName + ".CHECKED);");
            line("  public static List<WireValue> annotations(WireValue target) { return TypeSignatures.annotations(" + runtimeName + ".CHECKED,target); }");
            line("  public static final Map<String,WireValue> DECLARATIONS=TypeSignatures.declarations(" + runtimeName + ".CHECKED);");
            for(WireValue definition:checked.definitions) {
                String name=prefix(s(f(definition,"id"))); WireValue shape=f(definition,"shape");
                if(tag(shape).equals("Symbol")) line("  public static final String "+name+"Symbol="+quote(s(payload(shape)))+";");
                if(tag(shape).equals("Operation")) signatureOperation(name,payload(shape));
            }
        }
        void signatureOperation(String name,WireValue operation) {
            reserve(name+"OperationInput");
            portClass(name+"OperationInput",a(f(operation,"inputs")).stream().map(p->obj("id",f(p,"id"),"contract",TypeSignatures.internalSlot(f(p,"contract")))).toList(),"","");
            List<String> variants=new ArrayList<>();
            for(WireValue outcome:a(f(operation,"outcomes"))) variants.add(name+prefix(s(f(outcome,"id"))));
            line("  public sealed interface "+name+"Outcome permits "+String.join(",",variants)+" { String outcomeId(); void validate() throws ValueFailure; }");
            for(int at=0;at<variants.size();at++) {
                WireValue outcome=a(f(operation,"outcomes")).get(at);String variant=variants.get(at);reserve(variant);
                portClass(variant,a(f(outcome,"value_ports")).stream().map(p->obj("id",f(p,"id"),"contract",TypeSignatures.internalSlot(f(p,"contract")))).toList()," implements "+name+"Outcome","    public String outcomeId(){return "+quote(s(f(outcome,"id")))+";}");
            }
            if(tag(f(operation,"effect")).equals("HttpRequestResponse")) {
                preparation(name,name+"OperationInput",name+"Outcome",a(f(operation,"outcomes")));
                line("  public sealed interface "+name+"Start permits "+name+"Prepared,"+name+"Started {}");
                line("  public record "+name+"Prepared("+name+"Outcome outcome) implements "+name+"Start {}");
                line("  public record "+name+"Started(HttpResult<"+name+"Outcome> result) implements "+name+"Start {}");
                line("  public static "+name+"Start start"+name+"(NetworkEffect.NetworkState state,"+name+"OperationInput input,"+name+"Binding binding,OwnerDecoder<"+name+"Outcome> decoder,HostAdapter adapter) throws Exception { input.validate(); "+name+"Preparation prepared=binding.prepare(input); if(prepared instanceof "+name+"Completed completed){completed.outcome().validate();return new "+name+"Prepared(completed.outcome());} "+name+"Ready ready=("+name+"Ready)prepared;return new "+name+"Started(SemanticValues.startHttp(state,ready.input(),value->value,settled->{"+name+"Outcome outcome=decoder.decode(settled);outcome.validate();return outcome;},adapter));}");
            }
        }
        void preparation(String name,String inputType,String outcomeType,List<WireValue> outcomes) {
            line("  public sealed interface "+name+"Preparation permits "+name+"Ready,"+name+"Completed {}");
            line("  public record "+name+"Ready(NetworkEffect.AttemptInput input) implements "+name+"Preparation {public "+name+"Ready {Objects.requireNonNull(input);}}");
            String permitted="Set.of("+String.join(",",outcomes.stream().filter(o->tag(f(o,"cause")).equals("ExternalCondition")).map(o->quote(s(f(o,"id")))).toList())+")";
            line("  public record "+name+"Completed("+outcomeType+" outcome) implements "+name+"Preparation {public "+name+"Completed {if(outcome==null||!"+permitted+".contains(outcome.outcomeId()))throw new IllegalArgumentException(\"declared external failure required\");}}");
            line("  @FunctionalInterface public interface "+name+"Binding { "+name+"Preparation prepare("+inputType+" input) throws Exception; }");
        }
        String wireText(WireValue value) { return "TypeSignatures.parseWire("+quote(encodeWire(value))+")"; }
        String frameWire(WireValue producer) {
            int type = context.index(f(producerContracts.get(producer), "type_ref")); return "wireSlot(frame.p" + producers.get(producer) + "," + runtimeName + "::write" + type + ")";
        }
        String inspected(WireValue value) {
            String result = frameWire(f(value, "producer"));
            for (WireValue step : a(f(value, "path"))) result = switch (tag(step)) { case "Field" -> "SemanticValues.projectField(" + result + "," + quote(s(payload(step))) + ")"; case "Index" -> "SemanticValues.projectIndex(" + result + ",new BigInteger(" + quote(s(payload(step))) + "))"; default -> "SemanticValues.projectVariant(" + result + "," + quote(s(payload(step))) + "," + quote(tagKey()) + ")"; };
            return result;
        }
        String bindingExpression(WireValue expression) {
            WireValue p = payload(expression); if (tag(expression).equals("Source")) return inspected(f(p, "value"));
            List<String> fields = new ArrayList<>(); for (WireValue tuple : a(f(p, "fields"))) fields.add("new BindingField(" + quote(s(a(tuple).get(0))) + "," + bindingExpression(a(tuple).get(1)) + ")");
            return "constructed(List.of(" + String.join(",", fields) + "))";
        }
        void composition() {
            List<WireValue> initialArguments = a(f(problem, "initial_inputs")).stream().filter(initial -> tag(f(initial, "source")).equals("Argument")).toList(); portClass("InitialInputs", initialArguments, "", ""); portClass("Goals", a(f(f(problem, "goal"), "outputs")), "", "");
            List<String> providers = new ArrayList<>(); Set<String> providerNames = new HashSet<>();
            for (WireValue signature : checked.providers) { String name = functions.get(f(signature, "reference")), field = providerField(signature); if (!providerNames.add(field)) throw new IllegalArgumentException("provider identifier collision"); providers.add(name + (tag(f(signature, "effect")).equals("PureFunction") ? "Provider " : "HttpBinding ") + field); }
            line("  public record Providers(" + String.join(",", providers) + ") { public Providers {"); for (WireValue signature : checked.providers) line("    Objects.requireNonNull(" + providerField(signature) + ");"); line("  } }");
            List<String> failures = new ArrayList<>(); for (WireValue embedding : a(f(f(problem, "goal"), "failures"))) { String name = prefix(s(f(embedding, "id"))) + "Failure"; reserve(name); failures.add(name); portClass(name, List.of(obj("id", str("value"), "contract", f(embedding, "contract"))), " implements FailureResult", "    public String embeddingId(){return " + quote(s(f(embedding, "id"))) + ";}"); }
            if (failures.isEmpty()) line("  public interface FailureResult { String embeddingId(); }");
            else line("  public sealed interface FailureResult permits " + String.join(",", failures) + " { String embeddingId(); }");
            line("  public sealed interface ExecutionFailure permits InvalidValue,InvalidProvider,ProviderFailed,NetworkFailed,CertificateFailed,InvalidContinuation,InvalidGuard {}");
            line("  public record InvalidValue(ValueFailure failure) implements ExecutionFailure {}"); line("  public record InvalidProvider(String function) implements ExecutionFailure {}"); line("  public record ProviderFailed(String function,Exception cause) implements ExecutionFailure {}"); line("  public record NetworkFailed(HttpFailure failure) implements ExecutionFailure {}"); line("  public record CertificateFailed(GenerationFailure failure) implements ExecutionFailure {}"); line("  public record InvalidContinuation(String reason) implements ExecutionFailure {}"); line("  public record InvalidGuard(String guard) implements ExecutionFailure {}");
            line("  public sealed interface RunResult permits Succeeded,Failed,Pending,Rejected {}"); line("  public record Succeeded(Goals goals,ExecutionSnapshot snapshot) implements RunResult {}"); line("  public record Failed(FailureResult failure,ExecutionSnapshot snapshot) implements RunResult {}"); line("  public record Pending(Continuation continuation,ExecutionSnapshot snapshot) implements RunResult {}"); line("  public record Rejected(ExecutionFailure failure,ExecutionSnapshot snapshot) implements RunResult {}");
            runtimeLine("  @FunctionalInterface private interface Resume { RunResult resume() throws ValueFailure,GenerationFailure; }");
            line("  public static final class Continuation { private final " + runtimeName + ".Resume continuation; private final Execution execution; private boolean resumed; private Continuation(" + runtimeName + ".Resume continuation,Execution execution){this.continuation=continuation;this.execution=execution;} public synchronized RunResult resume(){ try { if(resumed) return new Rejected(new InvalidContinuation(\"continuation already resumed\"),execution.snapshot()); resumed=true; return continuation.resume(); } catch(ValueFailure failure){return " + runtimeName + ".rejected(execution,new InvalidValue(failure));} catch(GenerationFailure failure){return " + runtimeName + ".rejected(execution,new CertificateFailed(failure));} } }");
            runtimeLine("  private static RunResult rejected(Execution execution,ExecutionFailure failure) { try { return new Rejected(failure,execution.snapshot()); } catch(GenerationFailure invalid){ throw new IllegalStateException(invalid); } }");
            runtimeLine("  private static final class Frame {"); for (Map.Entry<WireValue, Integer> producer : producers.entrySet()) runtimeLine("    Slot<" + storage(context.index(f(producerContracts.get(producer.getKey()), "type_ref"))) + "> p" + producer.getValue() + "=new Absent<>();"); runtimeLine("  }");
            runtimeLine("  private record BindingField(String name,Slot<WireValue> value) {}"); runtimeLine("  private static Slot<WireValue> constructed(List<BindingField> fields) { List<Member> members=new ArrayList<>(); for(BindingField field:fields) put(members,field.name(),field.value()); return new Present<>(new ObjectValue(members)); }");
            line("  public static RunResult run(InitialInputs input,Providers providers,NetworkEffect.NetworkState network) { return " + runtimeName + ".run(input,providers,network); }");
            runtimeLine("  private static RunResult run(InitialInputs input,Providers providers,NetworkEffect.NetworkState network) { Execution execution; try { execution=new Execution(CHECKED,network); } catch(GenerationFailure failure){ return new Rejected(new CertificateFailed(failure),new ExecutionSnapshot(List.of(),network)); } catch(ValueFailure failure){ return new Rejected(new InvalidValue(failure),new ExecutionSnapshot(List.of(),network)); } try { if(input==null) return rejected(execution,new InvalidProvider(\"initial inputs\")); if(providers==null) return rejected(execution,new InvalidProvider(\"providers\")); input.validate(); Frame frame=new Frame();");
            for (WireValue initial : a(f(problem, "initial_inputs"))) {
                WireValue producer = variant("Initial", f(initial, "id")); int contract = port(f(initial, "contract")); String value = tag(f(initial, "source")).equals("Argument") ? "input." + fieldIdentifier(s(f(initial, "id"))) + "()" : "readPort" + contract + "(" + runtimeName + ".CHECKED.suppliedValue(" + quote(s(f(initial, "id"))) + "))";
                runtimeLine("    frame.p" + producers.get(producer) + "=liftPort" + contract + "(" + value + ");");
            }
            runtimeLine("    return node0(frame,providers,execution); } catch(ValueFailure failure){return rejected(execution,new InvalidValue(failure));} catch(GenerationFailure failure){return rejected(execution,new CertificateFailed(failure));} }");
            for (int i = 0; i < trees.size(); i++) node(i, trees.get(i));
            List<String> entrypoints = List.of(quote(s(f(problem,"identity"))));
            line("  public static final List<String> COMPOSITION_ENTRYPOINTS=List.of(" + String.join(",", entrypoints) + ");");
        }
        void node(int id, WireValue tree) {
            WireValue node = f(tree, "node"), p = payload(node);
            runtimeLine("  private static RunResult node" + id + "(Frame frame,Providers providers,Execution execution) throws ValueFailure,GenerationFailure {");
            if (tag(node).equals("Return")) {
                if (tag(p).equals("Success")) {
                    List<String> outputs = new ArrayList<>(); for (WireValue goal : a(f(f(problem, "goal"), "outputs"))) { WireValue expression = bindingFor(payload(p), f(goal, "id")); outputs.add("readPort" + port(f(goal, "contract")) + "(" + bindingExpression(expression) + ")"); }
                    runtimeLine("    Goals goals=Goals.of(" + String.join(",", outputs) + "); execution.finish(" + quote(SemanticGeneration.returnKey(p)) + "); return new Succeeded(goals,execution.snapshot());");
                } else {
                    WireValue embedding = null; for (WireValue candidate : a(f(f(problem, "goal"), "failures"))) if (f(candidate, "id").equals(f(payload(p), "embedding"))) embedding = candidate;
                    String name = prefix(s(f(embedding, "id"))) + "Failure"; runtimeLine("    " + name + " failure=" + name + ".of(readPort" + port(f(embedding, "contract")) + "(" + bindingExpression(f(payload(p), "value")) + ")); execution.finish(" + quote(SemanticGeneration.returnKey(p)) + "); return new Failed(failure,execution.snapshot());");
                }
                runtimeLine("  }"); return;
            }
            if (tag(node).equals("Guard")) { guardNode(id, p); runtimeLine("  }"); return; }
            WireValue invocation = f(p, "invocation"), signature = null; for (WireValue candidate : checked.providers) if (f(candidate, "reference").equals(f(invocation, "function"))) signature = candidate;
            String name = functions.get(f(invocation, "function")); List<String> bindings = new ArrayList<>();
            for (WireValue port : a(f(signature, "inputs"))) bindings.add("readPort" + port(f(port, "contract")) + "(" + bindingExpression(bindingFor(f(invocation, "bindings"), f(port, "id"))) + ")");
            runtimeLine("    " + name + "Input request=" + name + "Input.of(" + String.join(",", bindings) + "); request.validate(); execution.checkInvocation(" + quote(SemanticGeneration.invocationKey(invocation)) + ");");
            if (tag(f(signature, "effect")).equals("PureFunction")) {
                runtimeLine("    ExecutionSnapshot before=execution.snapshot(); execution.commitInvocation(); " + name + "Outcome outcome; try { outcome=providers." + providerField(signature) + "().call(request,before); } catch(Exception failure){return rejected(execution,new ProviderFailed(" + quote(s(f(f(signature, "reference"), "identity"))) + ",failure));} return after" + id + "(frame,providers,execution,outcome);"); runtimeLine("  }");
            } else {
                runtimeLine("    "+name+"HttpBinding binding=providers."+providerField(signature)+"(); "+name+"Preparation prepared;try{prepared=binding.prepare().prepare(request);}catch(Exception failure){execution.releaseUnissued();return rejected(execution,new ProviderFailed("+quote(s(f(f(signature,"reference"),"identity")))+",failure));}");
                runtimeLine("    if(prepared instanceof "+name+"Completed completed){completed.outcome().validate();execution.commitInvocation();return after"+id+"(frame,providers,execution,completed.outcome());}");
                runtimeLine("    "+name+"Ready ready=("+name+"Ready)prepared;HttpResult<"+name+"Outcome> result=SemanticValues.startHttp(execution.network(),ready.input(),value->value,binding.decoder(),binding.adapter());return http"+id+"(frame,providers,execution,result,false);");
                runtimeLine("  }");
                runtimeLine("  private static RunResult http" + id + "(Frame frame,Providers providers,Execution execution,HttpResult<" + name + "Outcome> result,boolean committed) throws ValueFailure,GenerationFailure {");
                runtimeLine("    if(result instanceof HttpPending<" + name + "Outcome> pending){ execution.network(pending.continuation().state()); if(!committed) execution.commitInvocation(); return new Pending(new Continuation(()->http" + id + "(frame,providers,execution,pending.continuation().resume(),true),execution),execution.snapshot()); }");
                runtimeLine("    if(result instanceof HttpRejected<" + name + "Outcome> rejected){ execution.network(rejected.state()); if(!committed){if(rejected.commandIssued()) execution.commitInvocation(); else execution.releaseUnissued();} return rejected(execution,new NetworkFailed(rejected.failure())); }");
                runtimeLine("    HttpCompleted<" + name + "Outcome> completed=(HttpCompleted<" + name + "Outcome>)result; execution.network(completed.state()); if(!committed) execution.commitInvocation(); return after" + id + "(frame,providers,execution,completed.outcome()); }");
            }
            runtimeLine("  private static RunResult after" + id + "(Frame frame,Providers providers,Execution execution," + name + "Outcome outcome) throws ValueFailure,GenerationFailure {");
            runtimeLine("    if(outcome==null) return rejected(execution,new InvalidProvider(" + quote(s(f(f(signature, "reference"), "identity"))) + ")); outcome.validate();");
            for (WireValue arm : a(f(p, "arms"))) {
                WireValue declared = null; for (WireValue candidate : a(f(signature, "outcomes"))) if (f(candidate, "id").equals(a(arm).get(0))) declared = candidate;
                runtimeLine("    if(outcome instanceof " + outcomeName(name, declared) + " value){");
                for (WireValue port : a(f(declared, "value_ports"))) {
                    WireValue producer = fields("InvocationOutcome", obj("site", f(invocation, "site"), "outcome", f(declared, "id"), "port", f(port, "id")));
                    runtimeLine("      frame.p" + producers.get(producer) + "=liftPort" + port(f(port, "contract")) + "(value." + fieldIdentifier(s(f(port, "id"))) + "());");
                }
                runtimeLine("      execution.completeInvocation(" + quote(s(f(declared, "id"))) + "); return node" + treeIds.get(a(arm).get(1)) + "(frame,providers,execution); }");
            }
            runtimeLine("    return rejected(execution,new InvalidProvider(" + quote(s(f(f(signature, "reference"), "identity"))) + "));"); runtimeLine("  }");
        }
        WireValue bindingFor(WireValue bindings, WireValue port) { for (WireValue tuple : a(bindings)) if (a(tuple).get(0).equals(port)) return a(tuple).get(1); throw new IllegalArgumentException("checked binding missing"); }
        void guardNode(int id, WireValue node) {
            WireValue guard = null; for (WireValue candidate : a(f(f(problem, "invocation_domain"), "guards"))) if (f(candidate, "id").equals(f(node, "guard"))) guard = candidate;
            runtimeLine("    Slot<WireValue> inspected=" + inspected(f(node, "inspected")) + ";"); String kind = tag(f(guard, "kind"));
            if (kind.equals("Validate")) {
                WireValue contract = payload(f(guard, "kind")); runtimeLine("    boolean accepted; try{" + runtimeName + ".CONTEXT.validateSlot(" + context.index(f(contract, "type_ref")) + "," + b(f(contract, "required")) + "," + b(f(contract, "nullable")) + ",inspected);accepted=true;}catch(ValueFailure failure){accepted=false;}");
            } else if (kind.equals("Variants")) runtimeLine("    String discriminator=inspected instanceof Present<WireValue> present && present.value() instanceof ObjectValue object && object.get(" + quote(tagKey()) + ") instanceof StringValue tag ? tag.value() : \"\";");
            List<String> known = new ArrayList<>(); for (WireValue arm : a(f(node, "arms"))) if (tag(a(arm).get(0)).equals("Variant")) known.add(quote(s(payload(a(arm).get(0)))));
            for (WireValue arm : a(f(node, "arms"))) {
                WireValue choice = a(arm).get(0); String condition = switch (tag(choice)) {
                    case "Absent" -> "inspected instanceof Absent<WireValue>"; case "Null" -> "inspected instanceof NullSlot<WireValue>"; case "Present" -> "inspected instanceof Present<WireValue>"; case "Accepted" -> "accepted"; case "Rejected" -> "!accepted"; case "Variant" -> "discriminator.equals(" + quote(s(payload(choice))) + ")"; default -> "inspected instanceof Present<WireValue> && !Set.of(" + String.join(",", known) + ").contains(discriminator)";
                };
                runtimeLine("    if(" + condition + ") return node" + treeIds.get(a(arm).get(1)) + "(frame,providers,execution);");
            }
            runtimeLine("    return rejected(execution,new InvalidGuard(" + quote(s(f(guard, "id"))) + "));");
        }
    }
}
