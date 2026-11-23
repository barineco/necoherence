// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package ncohagent;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Counts the jump instructions (conditional and unconditional jumps, table and lookup switches) that the
 * classes under {@code necoherence/} execute. The count does not depend on the JIT compiler.
 */
public final class Agent {
    private Agent() {
    }

    public static void premain(String arguments, Instrumentation instrumentation) {
        String[] specs = arguments == null || arguments.isEmpty() ? new String[0] : arguments.split(",");
        String[] owners = new String[specs.length];
        String[] methodNames = new String[specs.length];
        String[] descriptors = new String[specs.length];
        for (int index = 0; index < specs.length; index++) {
            int colon = specs[index].indexOf(':');
            String head = colon < 0 ? specs[index] : specs[index].substring(0, colon);
            descriptors[index] = colon < 0 ? "" : specs[index].substring(colon + 1);
            int dot = head.lastIndexOf('.');
            owners[index] = head.substring(0, dot);
            methodNames[index] = head.substring(dot + 1);
        }
        Counter.names = specs;
        Counter.methods = new long[specs.length];
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String name, Class<?> redefined, ProtectionDomain domain, byte[] buffer) {
                if (name == null || !name.startsWith("necoherence/")) {
                    return null;
                }
                ClassReader reader = new ClassReader(buffer);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
                    @Override
                    public MethodVisitor visitMethod(int access, String method, String descriptor, String signature, String[] exceptions) {
                        MethodVisitor visitor = super.visitMethod(access, method, descriptor, signature, exceptions);
                        if ((access & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE)) != 0) {
                            return visitor;
                        }
                        int entry = -1;
                        for (int index = 0; index < specs.length; index++) {
                            if (owners[index].equals(name) && methodNames[index].equals(method) && descriptor.startsWith(descriptors[index])) {
                                entry = index;
                            }
                        }
                        int entryIndex = entry;
                        return new MethodVisitor(Opcodes.ASM9, visitor) {
                            @Override
                            public void visitCode() {
                                super.visitCode();
                                if (entryIndex >= 0) {
                                    super.visitFieldInsn(Opcodes.GETSTATIC, "ncohagent/Counter", "methods", "[J");
                                    super.visitLdcInsn(entryIndex);
                                    super.visitInsn(Opcodes.DUP2);
                                    super.visitInsn(Opcodes.LALOAD);
                                    super.visitInsn(Opcodes.LCONST_1);
                                    super.visitInsn(Opcodes.LADD);
                                    super.visitInsn(Opcodes.LASTORE);
                                }
                            }

                            private void count() {
                                super.visitFieldInsn(Opcodes.GETSTATIC, "ncohagent/Counter", "jumps", "J");
                                super.visitInsn(Opcodes.LCONST_1);
                                super.visitInsn(Opcodes.LADD);
                                super.visitFieldInsn(Opcodes.PUTSTATIC, "ncohagent/Counter", "jumps", "J");
                            }

                            @Override
                            public void visitJumpInsn(int opcode, Label label) {
                                count();
                                super.visitJumpInsn(opcode, label);
                            }

                            @Override
                            public void visitTableSwitchInsn(int min, int max, Label fallback, Label... labels) {
                                count();
                                super.visitTableSwitchInsn(min, max, fallback, labels);
                            }

                            @Override
                            public void visitLookupSwitchInsn(Label fallback, int[] keys, Label[] labels) {
                                count();
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
