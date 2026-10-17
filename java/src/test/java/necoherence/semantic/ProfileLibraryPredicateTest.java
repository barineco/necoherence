// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import java.util.List;

public final class ProfileLibraryPredicateTest {
    private static final WireValue TRUE = new BooleanValue(true), FALSE = new BooleanValue(false);
    private static final WireValue REFERENCE = obj("identity",str("profile"),"revision",str("4"),"content_digest",str("a".repeat(64)));
    private static final WireValue SOURCE = obj("repository",str("synthetic"),"revision",str("1"),"path",str("types"),"content_digest",str("a".repeat(64)));
    private static WireValue ref(String name){return obj("source",SOURCE,"definition_name",str(name),"pointer",arr(List.of()));}
    private static WireValue slot(String id){return obj("type_id",str(id),"required",TRUE,"nullable",FALSE);}
    private static WireValue semanticSlot(String id){return obj("type_ref",ref(id),"required",TRUE,"nullable",FALSE);}
    private static WireValue stringSpec(WireValue format,WireValue wrapper,WireValue constant){return obj("format",format,"lengths",arr(List.of()),"wrapper",wrapper,"const_value",constant,"enum_values",NIL,"examples",arr(List.of()),"default_value",NIL);}
    private static WireValue integerSpec(WireValue domain,WireValue minimum,WireValue maximum){return obj("domain",domain,"minimum",minimum,"maximum",maximum,"const_value",NIL,"enum_values",NIL,"default_value",NIL);}
    private static WireValue node(String id,WireValue shape){return obj("id",str(id),"shape",shape);}
    private static WireValue field(String name,String target){return obj("wire_name",str(name),"slot",slot(target));}
    private static WireValue branch(String target,String wireTag,WireValue selector){return obj("target",str(target),"wire_tag",str(wireTag),"selector",selector);}
    private static WireValue product(WireValue fields,WireValue extras){return variant("Product",obj("fields",fields,"extras",extras));}
    private static WireValue union(WireValue branches){return variant("TaggedUnion",obj("branches",branches));}
    private static WireValue domain(){return obj("name",str("integer"),"reference",REFERENCE,"range",fields("Inclusive",obj("minimum",str("-1"),"maximum",str("1"))),"forms",arr(List.of(variant("Number"),variant("IntegralDecimal"),variant("DecimalString"))));}
    private static WireValue identifier(){return obj("name",str("identifier"),"reference",REFERENCE,"rule",fields("Identifier",obj("first_alphabet",str("ab"),"rest_alphabet",str("ab"),"exact_length",NIL,"min_length",str("1"),"max_length",str("4"),"forbidden",arr(List.of()))));}
    private static WireValue binding(String name,WireValue rule){return obj("name",str(name),"reference",REFERENCE,"rule",rule);}
    private static WireValue textLeaf(WireValue format,WireValue wrapper){return variant("String",stringSpec(format,wrapper,NIL));}
    private static WireValue sealedForm(){return obj("tag",str("sealed"),"fields",arr(List.of(obj("key",str("name"),"required",TRUE,"leaf",textLeaf(variant("Named",str("identifier")),str("text-wrapper"))),obj("key",str("count"),"required",FALSE,"leaf",variant("Integer",integerSpec(str("integer"),NIL,NIL))))),"extras",variant("Reject"));}
    private static WireValue graphemes(){return obj("reference",REFERENCE,"component",obj("unicode_version",str("16"),"uax29_revision",str("45"),"cluster_profile",str("extended")),"table_sha256",str("b".repeat(64)),"sources",arr(List.of()),"properties",arr(List.of(obj("first",str("0"),"last",str("1"),"property",variant("Other")))),"extended_pictographic",arr(List.of(obj("first",str("2"),"last",str("3")))),"indic_conjunct",arr(List.of(obj("first",str("4"),"last",str("5"),"property",variant("Other")))));}
    private static WireValue profile(){
        WireValue formats=arr(List.of(identifier(),binding("tag-format",variant("Choice",arr(List.of(variant("Literal",str("sealed")),variant("Literal",str("other")))))),binding("only-ok",variant("Literal",str("ok")))));
        WireValue wrappers=arr(List.of(obj("name",str("bytes-wrapper"),"key",str("bytes"),"payload",variant("Bytes")),obj("name",str("text-wrapper"),"key",str("text"),"payload",variant("Text",str("identifier")))));
        return obj("reference",REFERENCE,"source_refs",arr(List.of()),"integer_domains",arr(List.of(domain())),"default_integer_domain",str("integer"),"numbers",obj("decimals",TRUE),"grapheme_rules",graphemes(),"format_bindings",formats,"bytes_policy",obj("reference",REFERENCE,"padding_optional",TRUE,"alphabet",variant("Either"),"strict_pad_bits",TRUE,"wrapper",str("bytes-wrapper")),"wrappers",wrappers,"tag",obj("key",str("tag"),"format",str("tag-format"),"sealed",arr(List.of(sealedForm()))));
    }
    private static WireValue library(List<WireValue> nodes){return library(profile(),nodes);}
    private static WireValue library(WireValue profile,List<WireValue> nodes){return obj("schema",str("ncoh-type-signatures@1"),"identity",str("library"),"revision",str("4"),"profile",profile,"sources",arr(List.of(SOURCE)),"provenance",arr(List.of()),"groups",arr(List.of()),"annotations",arr(List.of()),"nodes",arr(nodes),"definitions",arr(List.of(obj("id",str("entry"),"wire_identity",str("entry"),"shape",variant("Value",str("unit"))))));}
    private static WireValue replace(WireValue value,String key,WireValue replacement){return TypeSignatures.replace(value,key,replacement);}
    private static void expectProfile(String id,WireValue invalid)throws Exception{try{TypeSignatures.checkProfile(invalid);throw new AssertionError(id+" accepted");}catch(GenerationFailure failure){if(!id.equals(failure.condition()))throw failure;if(failure.observed()==null)throw new AssertionError(id+" lacks observed");}}
    private static void expectLibrary(String id,WireValue invalid)throws Exception{try{TypeSignatures.checkLibrary(invalid);throw new AssertionError(id+" accepted");}catch(GenerationFailure failure){if(!id.equals(failure.condition()))throw new AssertionError(id+" observed "+failure.condition(),failure);if(failure.observed()==null)throw new AssertionError(id+" lacks observed");}}
    private static void profiles()throws Exception{
        WireValue p=profile(), formats=f(p,"format_bindings"), wrappers=f(p,"wrappers"), model=f(p,"tag"), bytes=f(p,"bytes_policy"), rules=f(p,"grapheme_rules");
        expectProfile("PR01",replace(p,"reference",replace(REFERENCE,"identity",str(""))));
        expectProfile("PR02",replace(p,"integer_domains",arr(List.of(domain(),domain()))));
        expectProfile("PR03",replace(p,"integer_domains",arr(List.of(replace(domain(),"range",fields("Inclusive",obj("minimum",str("2"),"maximum",str("1"))))))));
        expectProfile("PR04",replace(p,"integer_domains",arr(List.of(replace(domain(),"forms",arr(List.of()))))));
        expectProfile("PR05",replace(p,"default_integer_domain",str("missing")));
        expectProfile("PR06",replace(p,"format_bindings",arr(List.of(identifier(),identifier()))));
        WireValue badIdentifier=replace(identifier(),"rule",fields("Identifier",obj("first_alphabet",str(""),"rest_alphabet",str("ab"),"exact_length",NIL,"min_length",str("1"),"max_length",str("4"),"forbidden",arr(List.of()))));
        expectProfile("PR07",replace(p,"format_bindings",arr(List.of(badIdentifier))));
        WireValue bytesWrapper=a(wrappers).get(0), textWrapper=a(wrappers).get(1);
        expectProfile("PR08",replace(p,"wrappers",arr(List.of(bytesWrapper,replace(textWrapper,"key",str("bytes"))))));
        expectProfile("PR09",replace(p,"wrappers",arr(List.of(bytesWrapper,replace(textWrapper,"payload",variant("Text",str("missing")))))));
        expectProfile("PR10",replace(p,"bytes_policy",replace(bytes,"wrapper",str("text-wrapper"))));
        expectProfile("PR11",replace(p,"tag",replace(model,"key",str("text"))));
        expectProfile("PR12",replace(p,"tag",replace(model,"format",str("missing"))));
        expectProfile("PR13",replace(p,"tag",replace(model,"sealed",arr(List.of(sealedForm(),sealedForm())))));
        WireValue form=sealedForm(), fields=f(form,"fields");
        expectProfile("PR14",replace(p,"tag",replace(model,"sealed",arr(List.of(replace(form,"fields",arr(List.of(a(fields).get(0),a(fields).get(0)))))))));
        WireValue badCount=obj("key",str("count"),"required",FALSE,"leaf",variant("Integer",integerSpec(str("missing"),NIL,NIL)));
        expectProfile("PR15",replace(p,"tag",replace(model,"sealed",arr(List.of(replace(form,"fields",arr(List.of(a(fields).get(0),badCount))))))));
        expectProfile("PR16",replace(p,"grapheme_rules",replace(rules,"properties",arr(List.of(obj("first",str("2"),"last",str("1"),"property",variant("Other")))))));
        WireValue admissionProfile=replace(p,"reference",replace(REFERENCE,"identity",str("")));
        byte[] admissionBytes=encodeWire(admissionProfile).getBytes(java.nio.charset.StandardCharsets.UTF_8);
        try{TypeSignatures.admitCanonicalProfile(f(admissionProfile,"reference"),List.of(),admissionBytes,admissionBytes);throw new AssertionError("canonical PR01 accepted");}
        catch(GenerationFailure failure){if(!failure.condition().equals("PR01"))throw failure;}
        TypeSignatures.checkProfile(p);
    }
    private static void libraries()throws Exception{
        WireValue unit=node("unit",variant("Unit"));
        expectLibrary("LB01",library(List.of(unit,node("alias",fields("Alias",obj("target",str("missing")))))));
        expectLibrary("LB02",library(List.of(unit,node("product",product(arr(List.of(field("x","unit"),field("x","unit"))),variant("Reject"))))));
        expectLibrary("LB03",library(List.of(unit,node("product",product(arr(List.of(field("text","unit"))),variant("Reject"))))));
        expectLibrary("LB04",library(List.of(unit,node("union",union(arr(List.of(branch("unit","same",variant("Kind",variant("Null"))),branch("unit","same",variant("Kind",variant("Boolean"))))))))));
        expectLibrary("LB05",library(List.of(unit,node("union",union(arr(List.of(branch("unit","fallback",variant("Otherwise")),branch("unit","null",variant("Kind",variant("Null"))))))))));
        expectLibrary("LB06",library(List.of(unit,node("union",union(arr(List.of(branch("unit","",variant("Kind",variant("Null"))))))))));
        WireValue target=node("target",product(arr(List.of()),variant("Reject")));
        expectLibrary("LB07",library(List.of(unit,target,node("union",union(arr(List.of(branch("target","outside",variant("InternalTag")))))))));
        expectLibrary("LB08",library(List.of(unit,target,node("union",union(arr(List.of(branch("target","sealed",variant("InternalTag")))))))));
        WireValue member=variant("MemberShape",arr(List.of(obj("key",str("key"),"test",variant("Format",str("missing"))))));
        expectLibrary("LB09",library(List.of(unit,node("union",union(arr(List.of(branch("unit","member",member))))))));
        expectLibrary("LB10",library(List.of(unit,node("sealed-node",fields("Sealed",obj("tag",str("sealed"),"refinements",arr(List.of(obj("key",str("missing"),"leaf",textLeaf(NIL,NIL))))))))));
        expectLibrary("LB11",library(List.of(unit,node("union",union(arr(List.of(branch("unit","other",variant("InternalTag")))))))));
        expectLibrary("LB12",library(List.of(unit,node("product",product(arr(List.of()),fields("Allow",obj("key_format",variant("Named",str("missing")),"value",obj("type_id",str("unit"),"nullable",FALSE))))))));
        expectLibrary("LB13",library(List.of(unit,node("string",variant("String",stringSpec(NIL,str("missing"),NIL))))));
        expectLibrary("LB14",library(List.of(unit,node("integer",variant("Integer",integerSpec(NIL,str("2"),str("1")))))));
        WireValue lower=obj("mantissa",str("2"),"scale",str("0"),"exclusive",FALSE), upper=obj("mantissa",str("1"),"scale",str("0"),"exclusive",FALSE);
        expectLibrary("LB15",library(List.of(unit,node("decimal",variant("Decimal",obj("minimum",lower,"maximum",upper))))));
        expectLibrary("LB16",library(List.of(unit,node("array",variant("Array",obj("item",obj("type_id",str("unit"),"nullable",FALSE),"min_length",str("2"),"max_length",str("1")))))));
        WireValue tagValue=node("tag-value",variant("String",stringSpec(NIL,NIL,str("different"))));
        WireValue tagTarget=node("target",product(arr(List.of(field("tag","tag-value"))),variant("Reject")));
        expectLibrary("LB17",library(List.of(unit,tagValue,tagTarget,node("union",union(arr(List.of(branch("target","other",variant("InternalTag")))))))));
        expectLibrary("LB18",library(List.of(unit,node("union",union(arr(List.of(branch("unit","first",variant("Kind",variant("Null"))),branch("unit","second",variant("Kind",variant("Null"))))))))));
        expectLibrary("LB19",library(List.of(unit,node("string",variant("String",stringSpec(variant("Named",str("only-ok")),NIL,str("bad")))))));
        TypeSignatures.checkLibrary(library(List.of(unit)));
        WireValue tagProfile=TypeSignatures.replace(profile(),"tag",obj("key",str("$type"),"format",NIL,"sealed",arr(List.of())));
        List<WireValue> base=List.of(unit,node("tag-value",variant("String",stringSpec(NIL,NIL,NIL))),node("a",product(arr(List.of(field("$type","tag-value"))),variant("Reject"))),node("b",product(arr(List.of(field("$type","tag-value"))),variant("Reject"))));
        java.util.ArrayList<WireValue> distinct=new java.util.ArrayList<>(base);
        distinct.add(node("union",union(arr(List.of(branch("a","com.example.a",variant("InternalTag")),branch("b","com.example.b",variant("InternalTag")))))));
        TypeSignatures.checkLibrary(library(tagProfile,distinct));
        for(WireValue selector:List.of(variant("Kind",variant("Null")),variant("MemberShape",arr(List.of(obj("key",str("key"),"test",variant("Absent"))))))) {
            java.util.ArrayList<WireValue> duplicate=new java.util.ArrayList<>(base);
            duplicate.add(node("union",union(arr(List.of(branch("a","com.example.a",selector),branch("b","com.example.b",selector))))));
            expectLibrary("LB18",library(tagProfile,duplicate));
        }
    }
    private static void meaning(String id,WireValue p,WireValue shape)throws Exception{
        WireValue graph=obj("profile",p,"nodes",arr(List.of(obj("reference",TypeSignatures.typeReference("subject"),"shape",shape))));
        Context context=new Context(graph);
        try{context.validate(context.reference(0),NIL);throw new AssertionError(id+" accepted");}catch(ValueFailure failure){if(!id.equals(failure.condition()))throw new AssertionError(id+" observed "+failure.condition(),failure);if(failure.observed()==null)throw new AssertionError(id+" lacks observed");}
    }
    private static void meanings()throws Exception{
        WireValue p=profile();
        meaning("MO01",p,variant("String",stringSpec(variant("Named",str("missing")),NIL,NIL)));
        meaning("MO02",replace(p,"grapheme_rules",NIL),variant("String",replace(stringSpec(NIL,NIL,NIL),"lengths",arr(List.of(obj("unit",variant("Graphemes"),"minimum",str("1"),"maximum",NIL))))));
        meaning("MO03",replace(p,"bytes_policy",NIL),variant("Bytes",obj("minimum",NIL,"maximum",NIL)));
        meaning("MO04",p,variant("Integer",integerSpec(str("missing"),NIL,NIL)));
        meaning("MO05",p,variant("String",stringSpec(NIL,str("missing"),NIL)));
        meaning("MO06",p,variant("String",stringSpec(NIL,str("bytes-wrapper"),NIL)));
        meaning("MO07",p,fields("Sealed",obj("tag",str("missing"),"refinements",arr(List.of()))));
        meaning("MO08",replace(p,"numbers",obj("decimals",FALSE)),variant("Decimal",obj("minimum",NIL,"maximum",NIL)));
        meaning("MO09",p,variant("Integer",integerSpec(str("integer"),str("-2"),NIL)));
        meaning("MO10",p,fields("Opaque",obj("type_name",str("external"))));
        WireValue union=variant("TaggedUnion",obj("branches",arr(List.of(obj("target",TypeSignatures.typeReference("subject"),"wire_tag",str("other"),"selector",variant("InternalTag"),"origin",obj("source",SOURCE,"pointer",arr(List.of())))))));
        meaning("MO11",replace(p,"tag",NIL),union);
    }
    public static void main(String[] args)throws Exception{profiles();meanings();libraries();System.out.println("Java: PR01-16, MO01-11 and LB01-19 passed");}
}
