// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import java.nio.file.Path;
import javax.tools.ToolProvider;

final class GeneratedJavaTestSupport {
    private GeneratedJavaTestSupport() {}
    static void assertMitOutput(String source) {
        String[] lines = source.split("\n");
        if (lines.length == 0 || !lines[0].equals("// SPDX-License-" + "Identifier: MIT")) throw new AssertionError("generated output does not start with the MIT declaration");
        for (String line : lines) {
            if (line.startsWith("import ") && line.matches(".*(NecoherenceTools|necoherence_tools|necoherence-tools|necoherence\\.tools).*")) throw new AssertionError("generated output imports the tools: " + line);
        }
    }
    static void compile(Path output, Path source) {
        String classpath = System.getProperty("java.class.path") + java.io.File.pathSeparator + output;
        int status = ToolProvider.getSystemJavaCompiler().run(null, null, null, "--release", "21", "-cp", classpath, "-d", output.toString(), source.toString());
        if (status != 0) throw new AssertionError("compilation failed: " + source + " status=" + status);
    }
}
