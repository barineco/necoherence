// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import java.nio.file.*;
import java.net.URLClassLoader;
import java.util.*;

public final class SemanticSignatureCompositionTest {
    static WireValue generate(String scenario)throws Exception {
        var builder=new ProcessBuilder("cargo","run","--quiet","--manifest-path","comparison/declaration/signature_generator/Cargo.toml","--bin","signatures","--",scenario);
        builder.redirectError(ProcessBuilder.Redirect.INHERIT);
        Process process=builder.start();String text=new String(process.getInputStream().readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        if(process.waitFor()!=0)throw new AssertionError("signature scenario generation failed");
        return readJson(text);
    }
    static WireValue replace(WireValue value,String key,WireValue replacement){return TypeSignatures.replace(value,key,replacement);}
    public static void main(String[] args)throws Exception {
        WireValue unhandled=generate("no-handler");
        if(!Set.of("Unreachable","Unknown").contains(s(f(unhandled,"status"))))throw new AssertionError("unhandled external result composed");
        WireValue input=generate("composition");var expected=GenerationBasis.decode(encodeWire(f(input,"basis")));
        var checked=TypeSignatures.admitGeneration(expected,encodeWire(input));
        WireValue composition=f(input,"composition"),problem=f(composition,"problem"),derivation=f(composition,"derivation");
        WireValue noHandler=replace(problem,"signatures",arr(a(f(problem,"signatures")).stream().filter(v->tag(f(v,"form")).equals("Operation")).toList()));
        WireValue domain=f(noHandler,"invocation_domain");
        domain=replace(replace(domain,"sites",arr(a(f(domain,"sites")).stream().filter(v->s(f(v,"id")).equals("operation")).toList())),"permitted_transforms",arr(List.of()));
        noHandler=replace(noHandler,"invocation_domain",domain);
        WireValue plan=f(derivation,"plan"),root=f(plan,"root"),node=f(root,"node"),fields=payload(node);
        fields=replace(fields,"arms",arr(a(f(fields,"arms")).stream().filter(v->!s(a(v).get(0)).equals("refused")).toList()));
        root=replace(root,"node",SemanticValues.fields("Invoke",fields));
        plan=replace(plan,"root",root);
        WireValue witness=replace(f(derivation,"witness"),"input_snapshot",noHandler);
        derivation=replace(replace(derivation,"plan",plan),"witness",witness);
        WireValue broken=obj("problem",noHandler,"derivation",derivation);
        WireValue rebased=TypeSignatures.computeBasis(f(input,"signatures"),f(input,"entrypoints"),broken);
        WireValue invalid=replace(replace(input,"composition",broken),"basis",rebased);
        try {TypeSignatures.admitGeneration(GenerationBasis.decode(encodeWire(rebased)),encodeWire(invalid));throw new AssertionError("uncovered external branch admitted");}
        catch(GenerationFailure failure){System.out.println("uncovered external branch rejected: "+failure.path()+": "+failure.condition());}
        var rendered=Renderer.renderChecked(checked,new Renderer.JavaTarget("","CoveredSignatures"));
        if(!(rendered instanceof Renderer.Rendered generated))throw new AssertionError(rendered);
        GeneratedJavaTestSupport.assertMitOutput(generated.source());
        Path temp=Files.createTempDirectory("signature-composition-");
        try {
            Path file=temp.resolve("CoveredSignatures.java");Files.writeString(file,generated.source());GeneratedJavaTestSupport.compile(temp,file);
            Path consumer=temp.resolve("CoveredConsumer.java");Files.writeString(consumer,CONSUMER);GeneratedJavaTestSupport.compile(temp,consumer);
            try(var loader=new URLClassLoader(new java.net.URL[]{temp.toUri().toURL()},SemanticSignatureCompositionTest.class.getClassLoader())){
                try{Class.forName("CoveredConsumer",true,loader).getMethod("main",String[].class).invoke(null,(Object)new String[0]);}
                catch(java.lang.reflect.InvocationTargetException failure){throw new AssertionError(failure.getCause());}
            }
        }finally{try(var paths=Files.walk(temp)){for(Path path:paths.sorted(Comparator.reverseOrder()).toList())Files.delete(path);}}
        System.out.println("external branches: no handler="+s(f(unhandled,"status"))+"; complete proof admitted; generated completed failure consumed by handler, goal true, HTTP unissued");
    }
    static final String CONSUMER="""
        import java.util.*;
        import java.util.concurrent.atomic.AtomicInteger;
        import necoherence.network.*;
        import necoherence.semantic.SemanticValues.*;
        public final class CoveredConsumer {
          public static void main(String[] args)throws Exception {
            AtomicInteger handled=new AtomicInteger();
            HostAdapter adapter=new HostAdapter(){
              public NetworkEffect.StartObservation start(NetworkEffect.SendCommand command){throw new AssertionError("external completion issued HTTP");}
              public NetworkEffect.HostObservation observe(NetworkEffect.StartedAttempt started){throw new AssertionError("external completion observed HTTP");}
            };
            var providers=new CoveredSignatures.Providers(
              new CoveredSignatures.ExampleOperationHttpBinding(
                input->new CoveredSignatures.ExampleOperationCompleted(CoveredSignatures.ExampleOperationOutcomeRefused.of(Unit.VALUE)),
                settled->{throw new AssertionError("external completion decoded HTTP");},adapter),
              (input,before)->{if(input.reason()!=Unit.VALUE)throw new AssertionError("actual failure value required");handled.incrementAndGet();return CoveredSignatures.HandlerOutcomeHandled.of(true);});
            var result=CoveredSignatures.run(CoveredSignatures.InitialInputs.of(),providers,new NetworkEffect.NetworkState(List.of()));
            if(!(result instanceof CoveredSignatures.Succeeded success)||!success.goals().result()||handled.get()!=1||!success.snapshot().network().attempts().isEmpty())throw new AssertionError(result);
          }
        }
        """;
}
