// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.net.URLClassLoader;
import java.lang.reflect.InvocationTargetException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import javax.tools.ToolProvider;

public final class SemanticInvariantAdapter implements AutoCloseable {
    private WireValue cachedLibrary;
    private CheckedGeneration cachedGeneration;
    private final Map<WireValue, GeneratedCodec> generated = new HashMap<>();

    private record GeneratedCodec(Path directory, URLClassLoader loader, Class<?> type) {}

    private CheckedGeneration generation(WireValue library) throws GenerationFailure {
        if (library.equals(cachedLibrary)) return cachedGeneration;
        WireValue entries = arr(a(f(library, "definitions")).stream()
                .map(definition -> obj("identity", f(definition, "id"), "definition", f(definition, "id"))).toList());
        String libraryText = encodeWire(library);
        TypeSignatures.TypeSignatureLibrary.decode(libraryText);
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        WireValue exchange = obj("schema", str("ncoh-checked-generation@4"), "basis", basis.value,
                "signatures", library, "entrypoints", entries, "composition", NIL);
        CheckedGeneration checked = TypeSignatures.admitGeneration(basis, encodeWire(exchange));
        cachedLibrary = library;
        cachedGeneration = checked;
        return checked;
    }

    private static WireValue contract(WireValue input) {
        return obj("type_ref", f(input, "type_id"), "required", f(input, "required"), "nullable", f(input, "nullable"));
    }

    private static WireValue path(Context context, WireValue reference, WireValue value, ValueFailure failure) {
        List<WireValue> result = new ArrayList<>();
        for (String step : failure.path()) {
            WireValue shape = reference == null ? null : context.resolve(reference);
            while (shape != null && tag(shape).equals("TaggedUnion")) {
                int branchIndex=context.selectBranch(context.index(reference),value);
                reference=branchIndex<0?null:f(a(f(payload(shape),"branches")).get(branchIndex),"target");
                shape = reference == null ? null : context.resolve(reference);
            }
            if (shape != null && tag(shape).equals("Array") || value instanceof ArrayValue) {
                int index = Integer.parseInt(step);
                result.add(num(BigInteger.valueOf(index)));
                reference = shape != null && tag(shape).equals("Array") ? f(f(payload(shape), "item"),"type_ref") : null;
                value = value instanceof ArrayValue array && index < array.items().size() ? array.items().get(index) : null;
            } else {
                result.add(str(step));
                reference = null;
                if (shape != null && tag(shape).equals("Product"))
                    for (WireValue field : a(f(payload(shape), "fields")))
                        if (s(f(field, "wire_name")).equals(step)) reference = f(f(field, "slot"), "type_ref");
                value = value instanceof ObjectValue object ? object.get(step) : null;
            }
        }
        return arr(result);
    }

    private static WireValue condition(ValueFailure failure) {
        return str(failure.condition().replaceFirst(": ", ":"));
    }

    private static boolean accepts(Context context, WireValue contract, Slot<WireValue> slot) throws ValueFailure {
        try { context.validateContract(contract, slot); return true; }
        catch (ValueFailure failure) {
            if (failure.condition().startsWith("UndefinedMeaning:")) throw failure;
            return false;
        }
    }

    private WireValue inclusion(Context context, WireValue input) throws ValueFailure {
        WireValue id = f(input, "id"), source = contract(f(input, "source")), destination = contract(f(input, "destination"));
        boolean sourceRequired = b(f(source, "required")), sourceNullable = b(f(source, "nullable"));
        List<Slot<WireValue>> slots = new ArrayList<>();
        for (WireValue candidate : a(f(input, "candidates"))) slots.add(new Present<>(candidate));
        if (!sourceRequired) slots.add(new Absent<>());
        if (sourceNullable) slots.add(new NullSlot<>());
        List<WireValue> samples = new ArrayList<>();
        for (WireValue sample : inclusionSamples(context, f(source, "type_ref"), f(destination, "type_ref"), 10000).values()) if (!samples.contains(sample)) samples.add(sample);
        for (WireValue sample : samples) slots.add(new Present<>(sample));
        for (Slot<WireValue> slot : slots) {
            if (!accepts(context, source, slot)) continue;
            try { context.validateContract(destination, slot); }
            catch (ValueFailure failure) {
                WireValue witness = slot instanceof Present<WireValue> present ? obj("tag", str("Present"), "value", present.value()) : variant(slot instanceof Absent<WireValue> ? "Absent" : "Null");
                return obj("id", id, "classification", str("Incompatible"), "value", witness,
                        "path", path(context, f(destination, "type_ref"), slot instanceof Present<WireValue> present ? present.value() : NIL, failure), "condition", condition(failure));
            }
        }
        AssignabilityDecision decision=checkAssignable(context,source,destination,10000);
        if(decision instanceof Compatible)return obj("id",id,"classification",str("Compatible"));
        if(decision instanceof Incompatible rejected){
            Slot<WireValue> slot=rejected.value();ValueFailure failure=rejected.destinationFailure();
            WireValue witness=slot instanceof Present<WireValue> present?obj("tag",str("Present"),"value",present.value()):variant(slot instanceof Absent<WireValue>?"Absent":"Null");
            return obj("id",id,"classification",str("Incompatible"),"value",witness,
                    "path",path(context,f(destination,"type_ref"),slot instanceof Present<WireValue> present?present.value():NIL,failure),"condition",condition(failure));
        }
        return obj("id",id,"classification",str("Unknown"));
    }

    private WireValue projection(Context context, WireValue input) throws ValueFailure {
        WireValue id = f(input, "id"), destination = contract(f(input, "destination"));
        WireValue projected;
        try { projected = f(projectSlot(context, contract(f(input, "source")), a(f(input, "path")), List.of()), "destination"); }
        catch (GenerationFailure failure) {
            return obj("id", id, "status", str("Rejected"), "rejection", str(failure.condition().equals("field") ? "MissingField" : "WrongShape"));
        }
        for (WireValue candidate : a(f(input, "candidate_slots"))) {
            Slot<WireValue> slot = switch (tag(candidate)) {
                case "Absent" -> new Absent<>();
                case "Null" -> new NullSlot<>();
                case "Present" -> new Present<>(f(candidate, "value"));
                default -> throw new IllegalArgumentException("unsupported slot");
            };
            if (accepts(context, projected, slot) && !accepts(context, destination, slot))
                return obj("id", id, "status", str("Rejected"), "rejection", str("Incompatible"));
        }
        if (!(checkAssignable(context, projected, destination, 10000) instanceof Compatible))
            return obj("id", id, "status", str("Rejected"), "rejection", str("Unknown"));
        return obj("id", id, "status", str("Accepted"), "binding", obj("producer", f(input, "producer"),
                "path", arr(a(f(input, "path")).stream().map(step -> str(tag(step).toLowerCase() + ":" + s(payload(step)))).toList()),
                "compatibility", str("Compatible")));
    }

    private GeneratedCodec codec(WireValue library) throws Exception {
        GeneratedCodec cached = generated.get(library);
        if (cached != null) return cached;
        Renderer.RenderResult result = Renderer.renderChecked(generation(library), new Renderer.JavaTarget("", "GeneratedInvariant"));
        if (!(result instanceof Renderer.Rendered rendered)) throw new IllegalStateException(result.toString());
        Path directory = Files.createTempDirectory("semantic-invariant-java-");
        try {
            Path source = directory.resolve("GeneratedInvariant.java");
            Files.writeString(source, rendered.source());
            var compiler = ToolProvider.getSystemJavaCompiler();
            try (var files = compiler.getStandardFileManager(null, null, null)) {
                boolean success = compiler.getTask(null, files, null, List.of("--release", "21", "-cp", System.getProperty("java.class.path"), "-d", directory.toString()), null, files.getJavaFileObjects(source)).call();
                if (!success) throw new IllegalStateException("generated codec compilation failed");
            }
            URLClassLoader loader = new URLClassLoader(new java.net.URL[]{directory.toUri().toURL()}, getClass().getClassLoader());
            GeneratedCodec compiled = new GeneratedCodec(directory, loader, Class.forName("GeneratedInvariant", true, loader));
            generated.put(library, compiled);
            return compiled;
        } catch (Exception failure) {
            remove(directory);
            throw failure;
        }
    }

    private WireValue roundtrip(WireValue input) throws Exception {
        GeneratedCodec compiled = codec(f(input, "library"));
        Map<?, ?> codecs = (Map<?, ?>) compiled.type().getField("CODECS").get(null);
        Object codec = codecs.get(s(f(input, "type_id")));
        Object decoder = codec.getClass().getMethod("decoder").invoke(codec);
        Object encoder = codec.getClass().getMethod("encoder").invoke(codec);
        Class<?> decoderInterface = Class.forName("GeneratedInvariant$Decoder", true, compiled.loader());
        Class<?> encoderInterface = Class.forName("GeneratedInvariant$Encoder", true, compiled.loader());
        try {
            Object value = decoderInterface.getMethod("decode", String.class).invoke(decoder, encodeWire(f(input, "value")));
            String encoded = (String) encoderInterface.getMethod("encode", Object.class).invoke(encoder, value);
            return obj("id", f(input, "id"), "status", str("Accepted"), "encoded", TypeSignatures.parseWire(encoded));
        } catch (InvocationTargetException failure) {
            if (failure.getCause() instanceof ValueFailure rejected)
                return obj("id", f(input, "id"), "status", str("Rejected"), "path",
                        path(generation(f(input, "library")).valueContext(), f(input, "type_id"), f(input, "value"), rejected), "condition", condition(rejected));
            throw failure;
        }
    }
    private WireValue libraryInvariant(WireValue input) throws Exception {
        CheckedGeneration before = generation(f(input, "library")), after = generation(f(input, "changed_library"));
        String beforeStatus = valueStatus(before.valueContext(), input), afterStatus = valueStatus(after.valueContext(), input);
        return obj("id", f(input, "id"),
                "graph_equal", new BooleanValue(f(before.basis.value, "graph_sha256").equals(f(after.basis.value, "graph_sha256"))),
                "provenance_equal", new BooleanValue(f(before.basis.value, "provenance_sha256").equals(f(after.basis.value, "provenance_sha256"))),
                "metadata_equal", new BooleanValue(f(before.basis.value, "metadata_sha256").equals(f(after.basis.value, "metadata_sha256"))),
                "before", str(beforeStatus), "after", str(afterStatus));
    }

    private static WireValue declarationFailure(WireValue id, GenerationFailure failure) {
        String predicate = failure.condition();
        String location = predicate.startsWith("PR") ? "profile" : "library";
        return obj("id", id, "status", str("Rejected"), "predicate", str(predicate),
                "path", arr(List.of(str(location))));
    }

    private static WireValue samples(Context context, WireValue input) {
        int maximum = n(f(input, "max_sample_length")).intValueExact();
        int fuel = n(f(input, "max_type_obligations")).intValueExact();
        int boundedFuel = Math.min(fuel, a(f(f(input, "library"), "nodes")).size() + 1);
        SampleResult result = sampleValueFuel(context, f(input, "type_id"), boundedFuel, maximum);
        boolean accepted = true;
        int type = context.index(f(input, "type_id"));
        for (WireValue value : result.values()) {
            try { context.validate(type, value); }
            catch (ValueFailure failure) { accepted = false; break; }
        }
        return obj("id", f(input, "id"), "status", str(accepted ? "Accepted" : "Rejected"),
                "sample_bound", new BooleanValue(result.sampleBound()),
                "sample_count", num(BigInteger.valueOf(result.values().size())));
    }

    private static String valueStatus(Context context, WireValue input) {
        try { context.validate(context.index(f(input, "type_id")), f(input, "value")); return "Accepted"; }
        catch (ValueFailure failure) { return "Rejected"; }
    }


    WireValue evaluate(WireValue input) throws Exception {
        WireValue id = f(input, "id");
        String kind = s(f(input, "kind"));
        if (kind.equals("wire")) {
            WireValue value = f(input, "value");
            GenerationBasis basis = GenerationBasis.decode(encodeWire(f(value, "basis")));
            CheckedGeneration checked = TypeSignatures.admitGeneration(basis, encodeWire(value));
            return obj("id", id, "status", str("Accepted"), "encoded", checked.input);
        }
        if (kind.equals("construction_witness")) {
            try {
                GenerationBasis basis = GenerationBasis.decode(encodeWire(f(input, "expected_basis")));
                TypeSignatures.admitGeneration(basis, encodeWire(f(input, "exchange")));
                return obj("id", id, "status", str("Accepted"));
            } catch (GenerationFailure failure) {
                return obj("id", id, "status", str("Rejected"), "rejection", str("Witness"));
            }
        }
        if (kind.equals("codec")) return roundtrip(input);
        if (kind.equals("library_invariant")) return libraryInvariant(input);
        Context context;
        try {
            context = generation(f(input, "library")).valueContext();
        } catch (GenerationFailure failure) {
            if (kind.equals("profile_admission")) return declarationFailure(id, failure);
            if (kind.equals("value") && failure.condition().startsWith("UndefinedMeaning"))
                return obj("id", id, "status", str("Unresolved"));
            throw failure;
        }
        if (kind.equals("profile_admission")) return obj("id", id, "status", str("Accepted"));
        return switch (kind) {
            case "inclusion" -> inclusion(context, input);
            case "samples" -> samples(context, input);
            case "projection" -> projection(context, input);
            case "value" -> {
                int type = context.index(f(input, "type_id"));
                WireValue value = f(input, "value");
                try {
                    context.validate(type, value);
                    WireValue decoded = context.decode(type, encodeWire(value));
                    if (!decoded.equals(value)) throw new IllegalStateException("roundtrip changed value");
                    yield obj("id", id, "status", str("Accepted"));
                } catch (ValueFailure failure) {
                    if (failure.condition().startsWith("UndefinedMeaning")) yield obj("id", id, "status", str("Unresolved"));
                    yield obj("id", id, "status", str("Rejected"),
                            "type_ref", failure.typeRef(),
                            "path", path(context, f(input, "type_id"), value, failure),
                            "condition", condition(failure), "trace", arr(failure.referenceTrace()));
                }
            }
            case "grapheme" -> {
                GraphemeRules rules = context.graphemeRules();
                String text = s(f(input, "text"));
                yield obj("id", id, "boundaries", arr(SemanticValues.graphemeBoundaries(rules, text).stream()
                        .map(offset -> num(BigInteger.valueOf(offset))).toList()),
                        "count", num(BigInteger.valueOf(SemanticValues.graphemeCount(rules, text))));
            }
            default -> throw new IllegalArgumentException("unsupported invariant kind: " + kind);
        };
    }

    private static void remove(Path directory) throws Exception {
        try (var paths = Files.walk(directory)) {
            for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
        }
    }

    public void close() throws Exception {
        for (GeneratedCodec codec : generated.values()) {
            codec.loader().close();
            remove(codec.directory());
        }
    }

    public static void main(String[] args) throws Exception {
        try (SemanticInvariantAdapter adapter = new SemanticInvariantAdapter();
                BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
                PrintWriter output = new PrintWriter(System.out, true, StandardCharsets.UTF_8)) {
            String line;
            while ((line = input.readLine()) != null) {
                output.println(encodeWire(adapter.evaluate(TypeSignatures.parseWire(line))));
            }
        }
    }
}
