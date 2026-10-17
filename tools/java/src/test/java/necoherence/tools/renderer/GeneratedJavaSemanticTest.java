// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.URLClassLoader;
import java.util.Map;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.TypeSignatures;

public final class GeneratedJavaSemanticTest {
    private static WireValue stringSpec(WireValue wrapper) {
        return obj("format", NIL, "lengths", arr(List.of()), "wrapper", wrapper,
                "const_value", NIL, "enum_values", NIL, "examples", arr(List.of(str("sample"))),
                "default_value", NIL);
    }

    private static WireValue library() {
        WireValue library=necoherence.semantic.SemanticLibraryFixture.library();
        WireValue profile=f(library,"profile"), model=f(profile,"tag");
        WireValue wrapper=obj("name",str("wrapped"),"key",str("$wrapped"),"payload",variant("Text",NIL));
        WireValue field=obj("key",str("name"),"required",new BooleanValue(true),"leaf",variant("String",stringSpec(NIL)));
        WireValue form=obj("tag",str("sealed"),"fields",arr(List.of(field)),"extras",variant("Reject"));
        model=TypeSignatures.replace(model,"sealed",arr(List.of(form)));
        profile=TypeSignatures.replace(TypeSignatures.replace(TypeSignatures.replace(profile,"wrappers",arr(List.of(wrapper))),"tag",model),
                "numbers",obj("decimals",new BooleanValue(true)));
        WireValue wrapped=variant("String",stringSpec(str("wrapped")));
        WireValue decimal=variant("Decimal",obj("minimum",NIL,"maximum",NIL));
        WireValue sealed=fields("Sealed",obj("tag",str("sealed"),"refinements",arr(List.of())));
        WireValue never=variant("Never");
        WireValue product=variant("Product",obj("fields",arr(List.of(obj("wire_name",str("value"),"slot",obj("type_id",str("wrapped"),"required",new BooleanValue(true),"nullable",new BooleanValue(false))))),"extras",variant("Reject")));
        WireValue union=variant("TaggedUnion",obj("branches",arr(List.of(obj("target",str("sealed"),"wire_tag",str("sealed"),"selector",variant("InternalTag"))))));
        WireValue nodes=arr(List.of(
                obj("id",str("wrapped"),"shape",wrapped),obj("id",str("decimal"),"shape",decimal),
                obj("id",str("sealed"),"shape",sealed),obj("id",str("never"),"shape",never),
                obj("id",str("product"),"shape",product),obj("id",str("union"),"shape",union),
                obj("id",str("flag"),"shape",variant("Boolean",obj("const_value",NIL,"default_value",new BooleanValue(false)))),
                obj("id",str("defaults"),"shape",variant("Product",obj("fields",arr(List.of(
                        obj("wire_name",str("flag"),"slot",obj("type_id",str("flag"),"required",new BooleanValue(true),"nullable",new BooleanValue(false))),
                        obj("wire_name",str("seen"),"slot",obj("type_id",str("wrapped"),"required",new BooleanValue(false),"nullable",new BooleanValue(true))))),
                        "extras",fields("Allow",obj("key_format",NIL,"value",obj("type_id",str("any"),"nullable",new BooleanValue(false))))))),
                obj("id",str("any"),"shape",variant("Unknown",variant("Any")))));
        WireValue definitions=arr(List.of(
                obj("id",str("product"),"wire_identity",str("Product"),"shape",variant("Value",str("product"))),
                obj("id",str("union"),"wire_identity",str("Union"),"shape",variant("Value",str("union")))));
        library=TypeSignatures.replace(TypeSignatures.replace(library,"groups",arr(List.of())),"annotations",arr(List.of()));
        return TypeSignatures.replace(TypeSignatures.replace(TypeSignatures.replace(library,"profile",profile),"nodes",nodes),"definitions",definitions);
    }

    private static Object invoke(Object target,String name,Object... arguments)throws Exception {
        Method method=java.util.Arrays.stream(target.getClass().getMethods()).filter(candidate->candidate.getName().equals(name)).findFirst().orElseThrow();
        method.setAccessible(true);
        try{return method.invoke(target,arguments);}catch(InvocationTargetException failure){
            if(failure.getCause() instanceof Exception cause)throw cause;
            throw failure;
        }
    }
    private static void generatedRoundtrip(Path directory,String type,WireValue value)throws Exception {
        try(URLClassLoader loader=new URLClassLoader(new java.net.URL[]{directory.toUri().toURL()},GeneratedJavaSemanticTest.class.getClassLoader())){
            Class<?> generated=loader.loadClass("RepresentativeGenerated");
            Map<?,?> codecs=(Map<?,?>)generated.getField("CODECS").get(null);
            Object codec=codecs.get(type);
            if(codec==null)throw new AssertionError("missing codec "+type);
            Object decoded=invoke(invoke(codec,"decoder"),"decode",encodeWire(value));
            String encoded=(String)invoke(invoke(codec,"encoder"),"encode",decoded);
            if(!encoded.equals(encodeWire(value)))throw new AssertionError(type+" generated roundtrip");
        }
    }
    public static void main(String[] args) throws Exception {
        WireValue library=library();
        TypeSignatures.checkProfile(f(library,"profile"));
        TypeSignatures.checkLibrary(library);
        String canonical=encodeWire(library);
        if(!canonical.equals(TypeSignatures.TypeSignatureLibrary.decode(canonical).encode()))throw new AssertionError("library roundtrip");
        WireValue entries=arr(List.of(obj("identity",str("entry"),"definition",str("product"))));
        GenerationBasis basis=TypeSignatures.basis(canonical,encodeWire(entries));
        WireValue exchange=obj("schema",str("ncoh-checked-generation@4"),"basis",basis.value,"signatures",library,"composition",NIL,"entrypoints",entries);
        CheckedGeneration checked=TypeSignatures.admitGeneration(basis,encodeWire(exchange));
        try {
            TypeSignatures.admitGeneration(basis,encodeWire(TypeSignatures.replace(exchange,"schema",str("ncoh-checked-generation@3"))));
            throw new AssertionError("old schema accepted");
        } catch (GenerationFailure failure) {
            if (!(failure.wireFailure() instanceof UnsupportedSchema)) throw failure;
        }
        WireValue invalidReference=TypeSignatures.replace(f(f(library,"profile"),"reference"),"identity",str(""));
        WireValue invalidProfile=TypeSignatures.replace(f(library,"profile"),"reference",invalidReference);
        WireValue invalidLibrary=TypeSignatures.replace(library,"profile",invalidProfile);
        GenerationBasis invalidBasis=TypeSignatures.basis(encodeWire(invalidLibrary),encodeWire(entries));
        WireValue invalidExchange=obj("schema",str("ncoh-checked-generation@4"),"basis",invalidBasis.value,
                "signatures",invalidLibrary,"composition",NIL,"entrypoints",entries);
        try{TypeSignatures.admitGeneration(invalidBasis,encodeWire(invalidExchange));throw new AssertionError("admit accepted PR01");}
        catch(GenerationFailure failure){if(!failure.condition().equals("PR01"))throw failure;}
        Renderer.RenderResult invalidRender=Renderer.render(invalidBasis,encodeWire(invalidExchange),new Renderer.JavaTarget("","Invalid"));
        if(!(invalidRender instanceof Renderer.InvalidGeneration invalid)||!invalid.reason().equals("PR01"))
            throw new AssertionError("renderer accepted PR01");
        var context=checked.valueContext();
        context.validate(TypeSignatures.typeReference("wrapped"),obj("$wrapped",str("text")));
        context.validate(TypeSignatures.typeReference("decimal"),new DecimalValue("1.25"));
        context.validate(TypeSignatures.typeReference("sealed"),obj("$type",str("sealed"),"name",str("x")));
        try { context.validate(TypeSignatures.typeReference("never"),NIL); throw new AssertionError("never accepted"); }
        catch (ValueFailure failure) { if(!failure.condition().equals("InvalidDataModel"))throw failure; }
        SampleResult samples=sampleValueFuel(context,TypeSignatures.typeReference("product"),8);
        if(samples.values().isEmpty()||!samples.possible())throw new AssertionError("product samples");
        WireValue neverContract=obj("type_ref",TypeSignatures.typeReference("never"),"required",new BooleanValue(true),"nullable",new BooleanValue(false));
        WireValue wrappedContract=obj("type_ref",TypeSignatures.typeReference("wrapped"),"required",new BooleanValue(true),"nullable",new BooleanValue(false));
        if(!(checkAssignable(context,neverContract,wrappedContract,64) instanceof Compatible))throw new AssertionError("never inclusion");
        Renderer.RenderResult result=Renderer.renderChecked(checked,new Renderer.JavaTarget("","RepresentativeGenerated"));
        if(!(result instanceof Renderer.Rendered rendered))throw new AssertionError(result);
        Path directory=Files.createTempDirectory("representative-java-");
        try {
            Path source=directory.resolve("RepresentativeGenerated.java");Files.writeString(source,rendered.source());
            GeneratedJavaTestSupport.compile(directory,source);
            WireValue wrapped=obj("$wrapped",str("text"));
            WireValue sealed=obj("$type",str("sealed"),"name",str("x"));
            generatedRoundtrip(directory,"wrapped",wrapped);
            generatedRoundtrip(directory,"decimal",new DecimalValue("1.25"));
            generatedRoundtrip(directory,"sealed",sealed);
            generatedRoundtrip(directory,"union",sealed);
            generatedRoundtrip(directory,"product",obj("value",wrapped));
            try{generatedRoundtrip(directory,"never",NIL);throw new AssertionError("never generated codec accepted a value");}
            catch(ValueFailure expected){if(!expected.condition().equals("InvalidDataModel"))throw expected;}
            try(URLClassLoader loader=new URLClassLoader(new java.net.URL[]{directory.toUri().toURL()},GeneratedJavaSemanticTest.class.getClassLoader())){
                Class<?> generated=loader.loadClass("RepresentativeGenerated");
                Object codecDefaults=((Map<?,?>)generated.getField("CODECS").get(null)).get("defaults");
                try{invoke(invoke(codecDefaults,"decoder"),"decode","{}");throw new AssertionError("strict defaults decode");}
                catch(ValueFailure expected){if(!expected.condition().equals("MissingRequired"))throw expected;}
                Object defaulted=invoke(codecDefaults,"decodeWithDefaults","{}");
                if(!Boolean.FALSE.equals(invoke(defaulted,"flag")))throw new AssertionError("defaulted declared slot");
                if(!"{\"flag\":false}".equals(invoke(invoke(codecDefaults,"encoder"),"encode",defaulted)))throw new AssertionError("defaulted wire");
                Class<?> defaultsType=loader.loadClass("RepresentativeGenerated$TypeDefaults");
                Object classDefaulted=defaultsType.getMethod("decodeWithDefaults",String.class).invoke(null,"{}");
                if(!Boolean.FALSE.equals(invoke(classDefaulted,"flag")))throw new AssertionError("default class slot");
                String retained="{\"2\":false,\"seen\":null,\"1\":0}", orderedWire=retained.substring(0,retained.length()-1)+",\"flag\":false}";
                Object ordered=invoke(codecDefaults,"decodeWithDefaults",retained);
                if(!Boolean.FALSE.equals(invoke(ordered,"flag")) || !(invoke(ordered,"seen") instanceof NullSlot<?>))throw new AssertionError("ordered declared slots");
                Map<?,?> extra=(Map<?,?>)invoke(ordered,"extra");
                if(!new BooleanValue(false).equals(extra.get("2")) || !num(java.math.BigInteger.ZERO).equals(extra.get("1")))throw new AssertionError("ordered extra slots");
                if(!orderedWire.equals(invoke(invoke(codecDefaults,"encoder"),"encode",ordered)))throw new AssertionError("ordered generated codec wire");
                Object orderedClass=defaultsType.getMethod("decodeWithDefaults",String.class).invoke(null,retained);
                if(!orderedWire.equals(invoke(orderedClass,"encode")))throw new AssertionError("ordered generated class wire");
                String neverName=(String)((Map<?,?>)generated.getField("TYPE_NAMES").get(null)).get("never");
                Class<?> neverType=loader.loadClass("RepresentativeGenerated$"+neverName);
                if(java.util.Arrays.stream(neverType.getDeclaredConstructors()).anyMatch(constructor->java.lang.reflect.Modifier.isPublic(constructor.getModifiers())))
                    throw new AssertionError("never carrier has an accessible constructor");
                var constructor=neverType.getDeclaredConstructor();constructor.setAccessible(true);
                Object codec=((Map<?,?>)generated.getField("CODECS").get(null)).get("never");
                try{invoke(invoke(codec,"encoder"),"encode",constructor.newInstance());throw new AssertionError("never generated codec encoded a value");}
                catch(ValueFailure expected){if(!expected.condition().equals("Uninhabited"))throw expected;}
            }
        } finally { try(var paths=Files.walk(directory)){for(Path path:paths.sorted(Comparator.reverseOrder()).toList())Files.delete(path);} }
        System.out.println("Java: @4, typed failures, values, inclusion, samples and generated carriers passed");
    }
}
