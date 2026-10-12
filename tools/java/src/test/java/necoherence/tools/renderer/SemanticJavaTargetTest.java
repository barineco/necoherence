// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;

public final class SemanticJavaTargetTest {
    public static void main(String[] args) throws Exception {
        WireValue library = necoherence.semantic.SemanticLibraryFixture.library();
        var basis = TypeSignatures.basis(encodeWire(library), encodeWire(necoherence.semantic.SemanticLibraryFixture.entries));
        String exchange = encodeWire(SemanticSignatureTest.exchange(library, basis));
        var checked = TypeSignatures.admitGeneration(basis, exchange);
        for (var target : List.of(new Renderer.JavaTarget("class", "Recipe"), new Renderer.JavaTarget("example..app", "Recipe"), new Renderer.JavaTarget("neco.", "Recipe"), new Renderer.JavaTarget("1neco", "Recipe"), new Renderer.JavaTarget("example.app", "class"), new Renderer.JavaTarget("example.app", "1Recipe"), new Renderer.JavaTarget("example.app", ""))) {
            reject(Renderer.renderChecked(checked, target), "$target");
            reject(Renderer.render(basis, exchange, target), "$target");
        }
        reject(Renderer.renderChecked(checked, null), "$target");
        reject(Renderer.render(basis, exchange, null), "$target");
        reject(Renderer.renderChecked(checked, new Renderer.JavaTarget("example.app", "TypeProduct")), "$identifiers");
        reject(Renderer.renderChecked(checked, new Renderer.JavaTarget("example.app", "Goals")), "$identifiers");
        var target = new Renderer.JavaTarget("example.app.generated", "RecipeDeclarations");
        var result = Renderer.render(basis, exchange, target);
        if (!(result instanceof Renderer.Rendered rendered)) throw new AssertionError(result);
        GeneratedJavaTestSupport.assertMitOutput(rendered.source());
        Path temp = Files.createTempDirectory("semantic-java-target-");
        try {
            Path source = temp.resolve("RecipeDeclarations.java");
            Files.writeString(source, rendered.source());
            GeneratedJavaTestSupport.compile(temp, source);
            Path consumer = temp.resolve("Consumer.java");
            Files.writeString(consumer, """
                package example.app.consumer;
                import example.app.generated.RecipeDeclarations;
                public final class Consumer {
                    public static void main(String[] args) throws Exception {
                        if (!RecipeDeclarations.GENERATION_PACKAGE.equals("example.app.generated")) throw new AssertionError("package provenance");
                        if (!RecipeDeclarations.GENERATION_CLASS.equals("RecipeDeclarations")) throw new AssertionError("class provenance");
                        var value = RecipeDeclarations.TypeProduct.decode("{\\\"n\\\":1}");
                        if (!value.n().equals(java.math.BigInteger.ONE) || !value.encode().equals("{\\\"n\\\":1}")) throw new AssertionError(value.encode());
                    }
                }
                """);
            GeneratedJavaTestSupport.compile(temp, consumer);
            try (var loader = new URLClassLoader(new java.net.URL[]{temp.toUri().toURL()}, SemanticJavaTargetTest.class.getClassLoader())) {
                Class.forName("example.app.consumer.Consumer", true, loader).getMethod("main", String[].class).invoke(null, (Object)new String[0]);
            }
        } finally {
            try (var paths = Files.walk(temp)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
        System.out.println("Java target: named-package consumer compiled and executed; invalid targets and collisions rejected");
    }

    private static void reject(Renderer.RenderResult result, String path) {
        if (!(result instanceof Renderer.InvalidGeneration failure) || !failure.path().equals(path)) throw new AssertionError(result);
    }
}
