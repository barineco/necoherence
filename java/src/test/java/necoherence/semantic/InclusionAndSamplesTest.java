// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;

public final class InclusionAndSamplesTest {
    private static final WireValue TRUE=new BooleanValue(true),FALSE=new BooleanValue(false);
    private static final WireValue REFERENCE=obj("identity",str("inclusion-and-samples"),"revision",str("1"),"content_digest",str("inclusion-and-samples"));
    private static WireValue domain(String name,List<WireValue> forms){return obj("name",str(name),"reference",REFERENCE,"range",fields("Inclusive",obj("minimum",str("0"),"maximum",str("10"))),"forms",arr(forms));}
    private static WireValue profile(){
        WireValue formats=arr(List.of(obj("name",str("all-text"),"reference",REFERENCE,"rule",variant("Text")),obj("name",str("not-a"),"reference",REFERENCE,"rule",variant("Not",variant("Literal",str("a")))),obj("name",str("key-x"),"reference",REFERENCE,"rule",variant("Literal",str("x")))));
        WireValue graphemes=obj("reference",REFERENCE,"component",obj("unicode_version",str("16"),"uax29_revision",str("45"),"cluster_profile",str("extended")),"table_sha256",str("b".repeat(64)),"sources",arr(List.of()),"properties",arr(List.of(obj("first",str("769"),"last",str("769"),"property",variant("Extend")))),"extended_pictographic",arr(List.of()),"indic_conjunct",arr(List.of()));
        WireValue sealed=obj("tag",str("sealed"),"fields",arr(List.of(
                obj("key",str("text"),"required",TRUE,"leaf",
                        variant("String",stringSpec(NIL,arr(List.of()),str("x"),NIL))),
                obj("key",str("count"),"required",TRUE,"leaf",
                        variant("Integer",integerSpec(str("zero-to-ten"),NIL,NIL,str("1"),NIL))))),
                "extras",variant("Reject"));
        return obj("reference",REFERENCE,"source_refs",arr(List.of()),"integer_domains",arr(List.of(domain("zero-to-ten",List.of(variant("Number"))),domain("forms",List.of(variant("Number"),variant("IntegralDecimal"),variant("DecimalString"))))),"default_integer_domain",str("zero-to-ten"),"numbers",obj("decimals",TRUE),"grapheme_rules",graphemes,"format_bindings",formats,"bytes_policy",obj("reference",REFERENCE,"padding_optional",TRUE,"alphabet",variant("Either"),"strict_pad_bits",TRUE,"wrapper",str("bytes")),"wrappers",arr(List.of(obj("name",str("bytes"),"key",str("bytes"),"payload",variant("Bytes")))),"tag",obj("key",str("tag"),"format",str("all-text"),"sealed",arr(List.of(sealed))));
    }
    private static WireValue stringSpec(WireValue format,WireValue lengths,WireValue constant,WireValue values){return obj("format",format,"lengths",lengths,"wrapper",NIL,"const_value",constant,"enum_values",values,"examples",arr(List.of()),"default_value",NIL);}
    private static WireValue integerSpec(WireValue domain,WireValue min,WireValue max,WireValue constant,WireValue values){return obj("domain",domain,"minimum",min,"maximum",max,"const_value",constant,"enum_values",values,"default_value",NIL);}
    private static WireValue node(String id,WireValue shape){return obj("reference",str(id),"shape",shape);}
    private static WireValue slot(String id){return obj("type_ref",str(id),"required",TRUE,"nullable",FALSE);}
    private static WireValue field(String name,String target,boolean required){return obj("wire_name",str(name),"slot",obj("type_ref",str(target),"required",new BooleanValue(required),"nullable",FALSE));}
    private static WireValue branch(String target,String tag,WireValue selector){return obj("target",str(target),"wire_tag",str(tag),"selector",selector,"origin",obj("source",str("test"),"pointer",arr(List.of())));}
    private static WireValue product(List<WireValue> fields,WireValue extras){return variant("Product",obj("fields",arr(fields),"extras",extras));}
    private static WireValue allow(WireValue key,String target){return fields("Allow",obj("key_format",key,"value",obj("type_ref",str(target),"nullable",FALSE)));}
    private static Context graph(WireValue... nodes){return new Context(obj("profile",profile(),"nodes",arr(List.of(nodes))));}
    private static WireValue basis(){
        WireValue digest=str("0".repeat(64));
        return obj("signature_schema",str("ncoh-type-signatures@1"),"library_identity",str("unit-library"),
                "library_revision",str("1"),"profile",REFERENCE,"graph_sha256",digest,
                "provenance_sha256",digest,"metadata_sha256",digest,"problem_sha256",NIL,
                "entrypoints_sha256",digest);
    }
    private static WireValue unitCertificate(WireValue basis,WireValue contract,String rule){
        WireValue shape=variant("Unit");
        WireValue pair=obj("source",contract,"destination",contract,"source_tag",NIL);
        WireValue entry=obj("pair",pair,"source_shape",shape,"destination_shape",shape,
                "rule",variant(rule),"children",arr(List.of()));
        return obj("basis",basis,"source",contract,"destination",contract,"root",str("0"),
                "empty_types",arr(List.of()),"pairs",arr(List.of(entry)));
    }
    private static void unitInclusionRule()throws Exception{
        Context context=graph(node("unit",variant("Unit")));WireValue contract=slot("unit"),basis=basis();
        WireValue certificate=canonical(unitCertificate(basis,contract,"Unit"),"InclusionCertificate","$test");
        verifyInclusion(context,basis,contract,contract,certificate);
        try{
            canonical(unitCertificate(basis,contract,"SameDefinedType"),"InclusionCertificate","$test");
            throw new AssertionError("SameDefinedType accepted");
        }catch(GenerationFailure failure){
            if(!(failure.wireFailure() instanceof UnknownTag unknown)
                    ||!unknown.tag().equals("SameDefinedType"))throw failure;
        }
    }
    private static boolean accepts(Context context,String type,WireValue value){try{context.validate(context.index(str(type)),value);return true;}catch(Exception failure){return false;}}
    private static void compatible(String name,Context context,String source,String destination){
        if(!(checkAssignable(context,slot(source),slot(destination),10000) instanceof Compatible))
            throw new AssertionError(name+" was not compatible");
    }
    private static void incompatible(String name,Context context,String source,String destination,WireValue expected)throws Exception{
        AssignabilityDecision decision=checkAssignable(context,slot(source),slot(destination),10000);
        if(!(decision instanceof Incompatible rejected))throw new AssertionError(name+" was not incompatible: "+decision);
        WireValue actual=rejected.value() instanceof Present<WireValue> present?present.value():NIL;
        if(!actual.equals(expected)||!accepts(context,source,expected)||accepts(context,destination,expected))
            throw new AssertionError(name+" witness invalid: expected="+expected+", actual="+actual);
    }
    private static WireValue text(WireValue format,WireValue lengths){return variant("String",stringSpec(format,lengths,NIL,NIL));}
    private static WireValue integer(String domain,WireValue min,WireValue max){return variant("Integer",integerSpec(str(domain),min,max,NIL,NIL));}
    private static void inclusion()throws Exception{
        Context c1=graph(node("text-string",text(variant("Named",str("all-text")),arr(List.of()))),node("not-a-string",text(variant("Named",str("not-a")),arr(List.of()))));
        compatible("C1",c1,"not-a-string","not-a-string");incompatible("I1",c1,"text-string","not-a-string",str("a"));
        WireValue any=node("any",variant("Unknown",variant("Any")));
        Context c2=graph(any,node("source",product(List.of(),allow(variant("Inline",variant("Literal",str("x"))),"any"))),node("destination",product(List.of(),allow(variant("Inline",variant("Text")),"any"))));
        compatible("C2",c2,"source","destination");
        Context order=graph(node("text",text(NIL,arr(List.of()))),node("integer",integer("zero-to-ten",NIL,NIL)),node("source",product(List.of(field("text","text",true),field("integer","integer",true)),variant("Reject"))),node("destination",product(List.of(field("integer","integer",true),field("text","text",true)),variant("Reject"))));
        compatible("P-order",order,"source","destination");
        Context sourceField=graph(node("integer",integer("zero-to-ten",NIL,NIL)),node("source",product(List.of(field("x","integer",true)),variant("Reject"))),node("destination",product(List.of(),allow(variant("Inline",variant("Literal",str("x"))),"integer"))));
        compatible("P-source-field",sourceField,"source","destination");
        Context extras=graph(node("nine",integer("zero-to-ten",str("0"),str("9"))),node("ten",integer("zero-to-ten",str("0"),str("10"))),node("source",product(List.of(),allow(variant("Inline",variant("Literal",str("x"))),"nine"))),node("destination",product(List.of(),allow(variant("Inline",variant("Literal",str("x"))),"ten"))));
        compatible("P-extras",extras,"source","destination");incompatible("P-extras-reverse",extras,"destination","source",obj("x",num(BigInteger.TEN)));
        Context optional=graph(node("nine",integer("zero-to-ten",str("0"),str("9"))),node("ten",integer("zero-to-ten",str("0"),str("10"))),node("source",product(List.of(),allow(NIL,"nine"))),node("destination",product(List.of(field("y","ten",false)),allow(NIL,"ten"))));
        compatible("P-extras-optional",optional,"source","destination");
        Context required=graph(node("nine",integer("zero-to-ten",str("0"),str("9"))),node("ten",integer("zero-to-ten",str("0"),str("10"))),node("source",product(List.of(),allow(NIL,"nine"))),node("destination",product(List.of(field("y","ten",true)),allow(NIL,"ten"))));
        incompatible("P-extras-required",required,"source","destination",obj());
        Context i2=graph(node("tag-x",variant("String",stringSpec(NIL,arr(List.of()),str("x"),NIL))),node("source",product(List.of(),variant("Reject"))),node("destination",product(List.of(field("tag","tag-x",false)),variant("Reject"))));
        incompatible("I2",i2,"source","destination",obj("tag",str("y")));
        WireValue payload=node("payload",product(List.of(),variant("Reject")));
        Context unions=graph(payload,node("c3-source",variant("TaggedUnion",obj("branches",arr(List.of(branch("payload","a",variant("InternalTag"))))))),node("c3-destination",variant("TaggedUnion",obj("branches",arr(List.of(branch("payload","a",variant("InternalTag")),branch("payload","b",variant("InternalTag"))))))),node("i3-source",variant("TaggedUnion",obj("branches",arr(List.of(branch("payload","a",variant("InternalTag")),branch("payload","b",variant("InternalTag"))))))),node("i3-destination",variant("TaggedUnion",obj("branches",arr(List.of(branch("payload","a",variant("InternalTag"))))))));
        compatible("C3",unions,"c3-source","c3-destination");incompatible("I3",unions,"i3-source","i3-destination",obj("tag",str("b")));
        Context ints=graph(node("nine",integer("zero-to-ten",str("0"),str("9"))),node("ten",integer("zero-to-ten",str("0"),str("10"))));compatible("C4",ints,"nine","ten");incompatible("I4",ints,"ten","nine",num(BigInteger.TEN));
        WireValue one=arr(List.of(obj("unit",variant("UnicodeScalars"),"minimum",NIL,"maximum",str("1")))),two=arr(List.of(obj("unit",variant("UnicodeScalars"),"minimum",NIL,"maximum",str("2"))));
        Context lengths=graph(node("one",text(NIL,one)),node("two",text(NIL,two)));compatible("C5",lengths,"one","two");incompatible("I5",lengths,"two","one",str("aa"));
        Context i6=graph(any,node("source",product(List.of(),allow(variant("Inline",variant("Literal",str("x"))),"any"))),node("destination",product(List.of(),variant("Reject"))));incompatible("I6",i6,"source","destination",obj("x",NIL));
        Context i7=graph(node("bytes",variant("Bytes",obj("minimum",NIL,"maximum",NIL))),node("ordinary",variant("Unknown",variant("OrdinaryObject"))));incompatible("I7",i7,"bytes","ordinary",obj("bytes",str("")));
    }
    private static void samples()throws Exception{
        WireValue selectorProduct=node("selector-product",product(List.of(field("shape","shape-text",false)),variant("Reject")));
        WireValue memberShape=variant("MemberShape",
                arr(List.of(obj("key",str("shape"),"test",variant("Format",str("all-text"))))));
        WireValue unionBranches=arr(List.of(
                branch("selector-product","internal",variant("InternalTag")),
                branch("selector-product","shape",memberShape),
                branch("kind-string","string",variant("Kind",variant("String"))),
                branch("otherwise-boolean","otherwise",variant("Otherwise"))));
        Context context=graph(
                node("bytes",variant("Bytes",obj("minimum",NIL,"maximum",NIL))),
                node("sealed",fields("Sealed",obj("tag",str("sealed"),"refinements",arr(List.of())))),
                node("shape-text",text(variant("Named",str("all-text")),arr(List.of()))),
                selectorProduct,
                node("kind-string",text(NIL,arr(List.of()))),
                node("otherwise-boolean",variant("Boolean",obj("const_value",NIL,"default_value",NIL))),
                node("union",variant("TaggedUnion",obj("branches",unionBranches))),
                node("forms",integer("forms",NIL,NIL)),
                node("utf8",text(NIL,arr(List.of(obj("unit",variant("Utf8Bytes"),"minimum",str("2"),"maximum",str("2")))))),
                node("scalar",text(NIL,arr(List.of(obj("unit",variant("UnicodeScalars"),"minimum",str("2"),"maximum",str("2")))))),
                node("grapheme",text(NIL,arr(List.of(obj("unit",variant("Graphemes"),"minimum",str("2"),"maximum",str("2")))))),
                node("any",variant("Unknown",variant("Any"))),
                node("extras",product(List.of(),allow(variant("Named",str("key-x")),"any"))));
        for(String type:List.of("bytes","sealed","union","forms","utf8","scalar","grapheme","extras")){SampleResult result=sampleValueFuel(context,str(type),context.nodes.size()+1,32);if(result.values().isEmpty())throw new AssertionError(type+" samples empty");for(WireValue value:result.values())if(!accepts(context,type,value))throw new AssertionError(type+" sample rejected: "+value);}
        List<WireValue> integerSamples=sampleValueFuel(context,str("forms"),20,32).values();if(!integerSamples.contains(num(BigInteger.ZERO))||!integerSamples.contains(new DecimalValue("0"))||!integerSamples.contains(str("0")))throw new AssertionError("integer forms");
        Context bound=graph(node("long",variant("String",stringSpec(NIL,arr(List.of()),str("aaaa"),NIL))));SampleResult omitted=sampleValueFuel(bound,str("long"),2,3);if(!omitted.values().isEmpty()||!omitted.sampleBound()||!omitted.possible())throw new AssertionError("sample bound");
        List<WireValue> fields=new ArrayList<>();for(String name:List.of("a","b","c","d"))fields.add(field(name,"flag",true));Context combinations=graph(node("flag",variant("Boolean",obj("const_value",NIL,"default_value",NIL))),node("four",product(fields,variant("Reject"))));if(!sampleValueFuel(combinations,str("four"),3,3).sampleBound()||sampleValueFuel(combinations,str("four"),4,4).values().isEmpty())throw new AssertionError("field combination bound");
    }
    public static void main(String[] args)throws Exception{unitInclusionRule();inclusion();samples();System.out.println("Java: inclusion wire rules, C1-C5, I1-I7, P rules and samples passed");}
}
