// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package admissiononce;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.List;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class AdmissionAgent {
    private AdmissionAgent() {}

    public static final List<String> COMPONENTS = List.of("decode", "sha256", "checkLibrary", "graph", "preparation", "admit", "blocks", "basis", "composition", "wirePrepare");
    private static final List<List<String>> METHODS = List.of(
            List.of("necoherence/semantic/TypeSignatures.readJson", "necoherence/semantic/TypeSignatures.decodeExchange"),
            List.of("necoherence/semantic/SemanticGeneration.sha"),
            List.of("necoherence/semantic/TypeSignatures.checkLibrary"),
            List.of("necoherence/semantic/TypeSignatures.projections", "necoherence/semantic/TypeSignatures.internalShape"),
            List.of("necoherence/semantic/TypeSignatures.admitComposition", "necoherence/composition/SignatureCompositionWire.prepare"),
            List.of("neco/quotient/Checked.admit"),
            List.of("neco/quotient/application/Application.keyedBlocksOf"),
            List.of("necoherence/semantic/TypeSignatures.computeBasis"),
            List.of("necoherence/semantic/TypeSignatures.admitComposition"),
            List.of("necoherence/composition/SignatureCompositionWire.prepare"));

    static List<Integer> components(String owner, String method) {
        String key = owner + "." + method;
        List<Integer> indexes = new java.util.ArrayList<>();
        for (int index = 0; index < METHODS.size(); index++) if (METHODS.get(index).contains(key)) indexes.add(index);
        return indexes;
    }

    public static void premain(String arguments, Instrumentation instrumentation) {
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String name, Class<?> redefined, ProtectionDomain domain, byte[] bytes) {
                if (name == null || !(name.startsWith("necoherence/") || name.startsWith("neco/quotient/"))) return null;
                boolean jumps = name.startsWith("necoherence/");
                ClassReader reader = new ClassReader(bytes);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
                    @Override
                    public MethodVisitor visitMethod(int access, String method, String descriptor, String signature, String[] exceptions) {
                        List<Integer> indexes = components(name, method);
                        return new MethodVisitor(Opcodes.ASM9, super.visitMethod(access, method, descriptor, signature, exceptions)) {
                            @Override
                            public void visitCode() {
                                super.visitCode();
                                for (int index : indexes) {
                                    super.visitLdcInsn(index);
                                    super.visitMethodInsn(Opcodes.INVOKESTATIC, "admissiononce/AdmissionCounter", "call", "(I)V", false);
                                }
                            }

                            private void jump() {
                                if (jumps) super.visitMethodInsn(Opcodes.INVOKESTATIC, "admissiononce/AdmissionCounter", "jump", "()V", false);
                            }

                            @Override
                            public void visitJumpInsn(int opcode, Label label) {
                                jump();
                                super.visitJumpInsn(opcode, label);
                            }

                            @Override
                            public void visitTableSwitchInsn(int minimum, int maximum, Label fallback, Label... labels) {
                                jump();
                                super.visitTableSwitchInsn(minimum, maximum, fallback, labels);
                            }

                            @Override
                            public void visitLookupSwitchInsn(Label fallback, int[] keys, Label[] labels) {
                                jump();
                                super.visitLookupSwitchInsn(fallback, keys, labels);
                            }
                        };
                    }
                }, 0);
                return writer.toByteArray();
            }
        });
    }
}
