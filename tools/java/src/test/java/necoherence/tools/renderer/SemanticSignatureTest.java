// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticLibraryFixture.*;
import java.nio.file.*;
import java.net.URLClassLoader;
import java.util.*;

public final class SemanticSignatureTest {
    static WireValue exchange(WireValue library,GenerationBasis basis){return obj("schema",str("ncoh-checked-generation@4"),"basis",readJson(basis.encode()),"signatures",library,"composition",NIL,"entrypoints",entries);}
    static CheckedGeneration admit(WireValue library)throws Exception{var basis=TypeSignatures.basis(encodeWire(library),encodeWire(entries));return TypeSignatures.admitGeneration(basis,encodeWire(exchange(library,basis)));}
    static void equal(Object a,Object b){if(!Objects.equals(a,b))throw new AssertionError(a+" != "+b);}
    interface CheckedAction{void run()throws Exception;}
    static void invalid(CheckedAction action)throws Exception{try{action.run();throw new AssertionError("accepted invalid input");}catch(GenerationFailure expected){if(expected.condition().isEmpty())throw new AssertionError();}}
    public static void main(String[] args)throws Exception{
        WireValue library=library();var basis=TypeSignatures.basis(encodeWire(library),encodeWire(entries));var checked=admit(library);
        WireValue discriminatorValue=obj("n",num(java.math.BigInteger.ONE),"$type",str("example.value#main"));
        checked.valueContext().validate(checked.valueContext().index(str("product")),discriminatorValue);
        WireValue permuted=replace(replace(library,"nodes",arr(a(f(library,"nodes")).reversed())),"definitions",arr(a(f(library,"definitions")).reversed()));equal(basis.encode(),TypeSignatures.basis(encodeWire(permuted),encodeWire(entries)).encode());admit(permuted);
        WireValue metadata=replace(library,"annotations",arr(List.of(obj("target",variant("Library"),"key",str("description"),"value",toExact(str("changed"))))));WireValue before=readJson(basis.encode()),after=readJson(TypeSignatures.basis(encodeWire(metadata),encodeWire(entries)).encode());equal(f(before,"graph_sha256"),f(after,"graph_sha256"));equal(f(before,"provenance_sha256"),f(after,"provenance_sha256"));if(f(before,"metadata_sha256").equals(f(after,"metadata_sha256")))throw new AssertionError("metadata digest unchanged");invalid(()->TypeSignatures.admitGeneration(basis,encodeWire(exchange(metadata,basis))));
        invalid(()->admit(replace(library,"nodes",arr(List.of(a(f(library,"nodes")).get(0),a(f(library,"nodes")).get(0))))));
        invalid(()->admit(replace(library,"nodes",arr(List.of(a(f(library,"nodes")).get(1))))));
        invalid(()->TypeSignatures.admitGeneration(GenerationBasis.decode(encodeWire(replace(before,"graph_sha256",str("0".repeat(64))))),encodeWire(exchange(library,basis))));
        TypeSignatures.checkOperationSignature(encodeWire(library),"op",encodeWire(operation(true)));invalid(()->TypeSignatures.checkOperationSignature(encodeWire(library),"op",encodeWire(operation(false))));
        WireValue baseline=replace(library,"definitions",arr(List.of(a(f(library,"definitions")).get(0),replace(a(f(library,"definitions")).get(1),"shape",variant("Operation",operation(false))))));
        TypeSignatures.checkOperationSignature(encodeWire(baseline),"op",encodeWire(operation(true)));
        var rendered=Renderer.renderChecked(checked,new Renderer.JavaTarget("","GeneratedSignature"));if(!(rendered instanceof Renderer.Rendered generated))throw new AssertionError(rendered);
        GeneratedJavaTestSupport.assertMitOutput(generated.source());
        Path temp=Files.createTempDirectory("signature-smoke-");
        try {
            Path generatedFile=temp.resolve("GeneratedSignature.java");
            Files.writeString(generatedFile,generated.source());
            GeneratedJavaTestSupport.compile(temp,generatedFile);
            try(var loader=new URLClassLoader(new java.net.URL[]{temp.toUri().toURL()},SemanticSignatureTest.class.getClassLoader())) {
                Class<?> type=Class.forName("GeneratedSignature",true,loader);
                Map<?,?> codecs=(Map<?,?>)type.getField("CODECS").get(null);
                Object codec=codecs.get("product");
                Object decoder=codec.getClass().getMethod("decoder").invoke(codec),encoder=codec.getClass().getMethod("encoder").invoke(codec);
                Class<?> decoderInterface=Class.forName("GeneratedSignature$Decoder",true,loader),encoderInterface=Class.forName("GeneratedSignature$Encoder",true,loader);
                for(int n=-100;n<=100;n++) {
                    String wire="{\"n\":"+n+"}";
                    Object value=decoderInterface.getMethod("decode",String.class).invoke(decoder,wire);
                    equal(encoderInterface.getMethod("encode",Object.class).invoke(encoder,value),wire);
                }
                Object unionCodec=codecs.get("union"),unionDecoder=unionCodec.getClass().getMethod("decoder").invoke(unionCodec),unionEncoder=unionCodec.getClass().getMethod("encoder").invoke(unionCodec);
                for(int n=-100;n<=100;n++) {
                    String wire="{\"n\":"+n+",\"$type\":\"example.test.value#main\"}";
                    Object value=decoderInterface.getMethod("decode",String.class).invoke(unionDecoder,wire);
                    equal(encoderInterface.getMethod("encode",Object.class).invoke(unionEncoder,value),wire);
                }
                List<?> annotations=(List<?>)type.getField("ANNOTATIONS").get(null);
                equal(annotations,TypeSignatures.annotations(checked));
                Class<?> denied=Class.forName("GeneratedSignature$OpDenied",true,loader);
                Object failure=denied.getMethod("of",java.math.BigInteger.class).invoke(null,java.math.BigInteger.ONE);
                Class<?> result=Class.forName("GeneratedSignature$OpOutcome",true,loader),completed=Class.forName("GeneratedSignature$OpCompleted",true,loader);
                Object prepared=completed.getConstructor(result).newInstance(failure);
                Class<?> inputType=Class.forName("GeneratedSignature$OpOperationInput",true,loader),bindingType=Class.forName("GeneratedSignature$OpBinding",true,loader);
                Object input=inputType.getMethod("of").invoke(null);
                Object binding=java.lang.reflect.Proxy.newProxyInstance(loader,new Class<?>[]{bindingType},(proxy,method,arguments)->prepared);
                OwnerDecoder<Object> httpDecoder=settled->{throw new AssertionError("completed preparation decoded HTTP");};
                HostAdapter adapter=new HostAdapter() {
                    public necoherence.network.JavaHttpAdapter.StartResult start(necoherence.network.NetworkEffect.SendCommand command){throw new AssertionError("completed preparation issued HTTP");}
                    public necoherence.network.JavaHttpAdapter.PollResult observe(necoherence.network.NetworkEffect.StartedAttempt started){throw new AssertionError("completed preparation observed HTTP");}
                };
                Object started=type.getMethod("startOp",necoherence.network.NetworkEffect.NetworkState.class,inputType,bindingType,OwnerDecoder.class,HostAdapter.class)
                    .invoke(null,new necoherence.network.NetworkEffect.NetworkState(List.of()),input,binding,httpDecoder,adapter);
                equal(started.getClass().getMethod("outcome").invoke(started),failure);
                Object success=Class.forName("GeneratedSignature$OpOk",true,loader).getMethod("of",java.math.BigInteger.class).invoke(null,java.math.BigInteger.ONE);
                try {completed.getConstructor(result).newInstance(success);throw new AssertionError("success completed preparation accepted");}
                catch(java.lang.reflect.InvocationTargetException expected){if(!(expected.getCause() instanceof IllegalArgumentException))throw expected;}
            }
        } finally { try(var paths=Files.walk(temp)){for(Path path:paths.sorted(Comparator.reverseOrder()).toList())Files.delete(path);} }
        System.out.println("signature invariants: Invalid, Permutation, Orthogonality, 402 generated codec roundtrips; canonical_main_tag=false preserves #main union, true rejects; exact annotations, typed external preparation passed");
    }
}
