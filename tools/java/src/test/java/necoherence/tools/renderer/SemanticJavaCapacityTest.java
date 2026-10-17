// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import java.lang.reflect.InvocationTargetException;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public final class SemanticJavaCapacityTest {
    public static void main(String[] args) throws Exception {
        Path temporary = Files.createTempDirectory("semantic-java-capacity-");
        try {
            WireValue base = necoherence.semantic.SemanticLibraryFixture.library();
            WireValue stringShape = variant("String", obj("format", NIL, "lengths", arr(List.of()),
                    "wrapper", NIL, "const_value", NIL, "enum_values", NIL,
                    "examples", arr(List.of()), "default_value", NIL));
            var nodes = new ArrayList<WireValue>();
            var definitions = new ArrayList<WireValue>();
            var entries = new ArrayList<WireValue>();
            for (int i = 0; i < 1000; i++) {
                String stringId = "capacity.synthetic.string" + i;
                String productId = "capacity.synthetic.product" + i;
                WireValue required = obj("type_id", str(stringId), "required", new BooleanValue(true), "nullable", new BooleanValue(false));
                WireValue optional = obj("type_id", str(stringId), "required", new BooleanValue(false), "nullable", new BooleanValue(true));
                WireValue productShape = variant("Product", obj("fields", arr(List.of(
                        obj("wire_name", str("required"), "slot", required),
                        obj("wire_name", str("optional"), "slot", optional))), "extras", variant("Reject")));
                nodes.add(obj("id", str(stringId), "shape", stringShape));
                nodes.add(obj("id", str(productId), "shape", productShape));
                for (String id : List.of(stringId, productId)) {
                    definitions.add(obj("id", str(id), "wire_identity", str(id), "shape", variant("Value", str(id))));
                    entries.add(obj("identity", str(id), "definition", str(id)));
                }
            }
            WireValue library = TypeSignatures.replace(TypeSignatures.replace(TypeSignatures.replace(
                    TypeSignatures.replace(base, "groups", arr(List.of())), "annotations", arr(List.of())),
                    "nodes", arr(nodes)), "definitions", arr(definitions));
            var basis = TypeSignatures.basis(encodeWire(library), encodeWire(arr(entries)));
            WireValue exchange = obj("schema", str("ncoh-checked-generation@4"), "basis", TypeSignatures.parseWire(basis.encode()),
                    "signatures", library, "composition", NIL, "entrypoints", arr(entries));
            var result = Renderer.render(basis, encodeWire(exchange), new Renderer.JavaTarget("capacity.generated", "Library"));
            if (!(result instanceof Renderer.Rendered rendered)) throw new AssertionError(result);
            GeneratedJavaTestSupport.assertMitOutput(rendered.source());
            Path source = temporary.resolve("Library.java");
            Files.writeString(source, rendered.source());
            GeneratedJavaTestSupport.compile(temporary, source);
            Path consumer = temporary.resolve("Consumer.java");
            Files.writeString(consumer, CONSUMER);
            GeneratedJavaTestSupport.compile(temporary, consumer);
            try (var loader = new URLClassLoader(new java.net.URL[]{temporary.toUri().toURL()}, SemanticJavaCapacityTest.class.getClassLoader())) {
                try { Class.forName("capacity.consumer.Consumer", true, loader).getMethod("main", String[].class).invoke(null, (Object)new String[0]); }
                catch (InvocationTargetException failure) { throw new AssertionError(failure.getCause()); }
            }
        } finally {
            try (var paths = Files.walk(temporary)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
        System.out.println("Java capacity: 1000 String/Product pairs compiled, loaded, and preserved public codecs and metadata");
    }

    private static final String CONSUMER = """
        package capacity.consumer;
        import capacity.generated.Library;
        import static necoherence.semantic.SemanticValues.*;
        public final class Consumer {
            static <T> void roundTrip(Library.Codec<T> codec, String wire) throws Exception {
                if(!wire.equals(codec.encoder().encode(codec.decoder().decode(wire)))) throw new AssertionError("codec round trip");
            }
            public static void main(String[] args) throws Exception {
                if(Library.DECLARATIONS.size()!=2000 || Library.CODECS.size()!=2000 || Library.TYPE_NAMES.size()!=2000) throw new AssertionError("public metadata size");
                for(int i=0;i<1000;i++) {
                    String stringId="capacity.synthetic.string"+i;
                    String productId="capacity.synthetic.product"+i;
                    for(String id:java.util.List.of(stringId,productId)) {
                        if(!id.equals(((StringValue)((ObjectValue)Library.DECLARATIONS.get(id)).get("id")).value())) throw new AssertionError("declaration identity");
                    }
                    if(!"String".equals(Library.TYPE_NAMES.get(stringId))) throw new AssertionError("scalar type");
                    roundTrip(Library.CODECS.get(stringId),"\\\"value\\\"");
                    roundTrip(Library.CODECS.get(productId),"{\\\"required\\\":\\\"value\\\"}");
                    roundTrip(Library.CODECS.get(productId),"{\\\"required\\\":\\\"value\\\",\\\"optional\\\":null}");
                    roundTrip(Library.CODECS.get(productId),"{\\\"required\\\":\\\"value\\\",\\\"optional\\\":\\\"present\\\"}");
                }
                var first=Library.TypeCapacitySyntheticProduct0.decode("{\\\"required\\\":\\\"first\\\"}");
                if(!first.required().equals("first")) throw new AssertionError("native product field");
                try { Library.DECLARATIONS.clear(); throw new AssertionError("mutable declarations"); } catch(UnsupportedOperationException expected) {}
                try { Library.TYPE_NAMES.clear(); throw new AssertionError("mutable names"); } catch(UnsupportedOperationException expected) {}
                try { Library.CODECS.clear(); throw new AssertionError("mutable codecs"); } catch(UnsupportedOperationException expected) {}
            }
        }
        """;
}
