// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import java.lang.reflect.InvocationTargetException;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;

public final class SemanticJavaSizeTest {
    public static void main(String[] args) throws Exception {
        Path temporary = Files.createTempDirectory("semantic-java-size-");
        try {
            WireValue base = necoherence.semantic.SemanticLibraryFixture.library();
            WireValue shape = variant("String", obj("format", NIL, "lengths", arr(java.util.List.of()),
                    "wrapper", NIL, "const_value", NIL, "enum_values", NIL,
                    "examples", arr(java.util.List.of()), "default_value", NIL));
            var nodes = new java.util.ArrayList<WireValue>();
            var definitions = new java.util.ArrayList<WireValue>();
            var entries = new java.util.ArrayList<WireValue>();
            for (int i = 0; i < 1000; i++) {
                String id = "example.synthetic.size" + i;
                nodes.add(obj("id", str(id), "shape", shape));
                definitions.add(obj("id", str(id), "wire_identity", str(id), "shape", variant("Value", str(id))));
                entries.add(obj("identity", str(id), "definition", str(id)));
            }
            WireValue library = TypeSignatures.replace(TypeSignatures.replace(TypeSignatures.replace(
                    TypeSignatures.replace(base, "groups", arr(java.util.List.of())), "annotations", arr(java.util.List.of())),
                    "nodes", arr(nodes)), "definitions", arr(definitions));
            var basis = TypeSignatures.basis(encodeWire(library), encodeWire(arr(entries)));
            WireValue exchange = obj("schema", str("ncoh-checked-generation@4"), "basis", TypeSignatures.parseWire(basis.encode()),
                    "signatures", library, "composition", NIL, "entrypoints", arr(entries));
            var result = Renderer.render(basis, encodeWire(exchange), new Renderer.JavaTarget("size.generated", "Library"));
            if (!(result instanceof Renderer.Rendered rendered)) throw new AssertionError(result);
            GeneratedJavaTestSupport.assertMitOutput(rendered.source());
            Path source = temporary.resolve("Library.java");
            Files.writeString(source, rendered.source());
            GeneratedJavaTestSupport.compile(temporary, source);
            Path consumer = temporary.resolve("Consumer.java");
            Files.writeString(consumer, CONSUMER);
            GeneratedJavaTestSupport.compile(temporary, consumer);
            try (var loader = new URLClassLoader(new java.net.URL[]{temporary.toUri().toURL()}, SemanticJavaSizeTest.class.getClassLoader())) {
                try { Class.forName("size.consumer.Consumer", true, loader).getMethod("main", String[].class).invoke(null, (Object)new String[0]); }
                catch (InvocationTargetException failure) { throw new AssertionError(failure.getCause()); }
            }
        } finally {
            try (var paths = Files.walk(temporary)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
        System.out.println("large Java declaration library: compile, load, public metadata and codecs passed");
    }

    private static final String CONSUMER = """
        package size.consumer;
        import size.generated.Library;
        public final class Consumer {
            static <T> void roundTrip(Library.Codec<T> codec) throws Exception {
                String wire="\\\"large library\\\"";
                if(!wire.equals(codec.encoder().encode(codec.decoder().decode(wire)))) throw new AssertionError("codec round trip");
            }
            public static void main(String[] args) throws Exception {
                if(Library.DECLARATIONS.size()!=1000 || Library.CODECS.size()!=1000 || Library.TYPE_NAMES.size()!=1000) throw new AssertionError("public surface size");
                for(int i=0;i<1000;i++) {
                    String identity="example.synthetic.size"+i;
                    var declaration=Library.DECLARATIONS.get(identity);
                    if(!identity.equals(((necoherence.semantic.SemanticValues.StringValue)((necoherence.semantic.SemanticValues.ObjectValue)declaration).get("id")).value())) throw new AssertionError("definition identity");
                    if(!"String".equals(Library.TYPE_NAMES.get(identity))) throw new AssertionError("native type");
                    roundTrip(Library.CODECS.get(identity));
                }
                try { Library.DECLARATIONS.clear(); throw new AssertionError("mutable declarations"); } catch(UnsupportedOperationException expected) {}
                try { Library.TYPE_NAMES.clear(); throw new AssertionError("mutable names"); } catch(UnsupportedOperationException expected) {}
                try { Library.CODECS.clear(); throw new AssertionError("mutable codecs"); } catch(UnsupportedOperationException expected) {}
            }
        }
        """;
}
