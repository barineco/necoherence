// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import java.util.*;

public final class SemanticLibraryFixture {
    private SemanticLibraryFixture() {}
    public static WireValue entries=arr(List.of(obj("identity",str("entry"),"definition",str("op")),obj("identity",str("value"),"definition",str("data"))));
    public static WireValue source=obj("repository",str("owner"),"revision",str("1"),"path",str("spec"),"content_digest",str("a".repeat(64)));
    public static WireValue origin=obj("source",source,"locator",arr(List.of(str("rules"))));
    public static WireValue slot(String type){return obj("type_id",str(type),"required",new BooleanValue(true),"nullable",new BooleanValue(false));}
    public static WireValue outcome(String id,boolean external){return obj("id",str(id),"form",variant(external?"DeclaredFailure":"Success"),"cause",fields(external?"ExternalCondition":"ValueContract",obj(external?"specification":"origin",origin)),"value_ports",arr(List.of(obj("id",str("value"),"contract",slot("number")))),"produced_resources",arr(List.of()));}
    public static WireValue operation(boolean external){return obj("effect",variant("HttpRequestResponse"),"inputs",arr(List.of()),"outcomes",arr(external?List.of(outcome("ok",false),outcome("denied",true)):List.of(outcome("ok",false))));}
    public static WireValue library(){
        WireValue reference=obj("identity",str("generic-values"),"revision",str("2"),"content_digest",str("b".repeat(64)));
        WireValue domain=obj("name",str("default"),"reference",reference,"range",variant("Unbounded"),"forms",arr(List.of(variant("Number"))));
        WireValue labelRule=fields("Identifier",obj("first_alphabet",str("abcdefghijklmnopqrstuvwxyz"),"rest_alphabet",str("abcdefghijklmnopqrstuvwxyz0123456789-"),"exact_length",NIL,"min_length",str("1"),"max_length",str("63"),"forbidden",arr(List.of())));
        WireValue tagFormat=variant("Text");
        WireValue profile=obj("reference",reference,"source_refs",arr(List.of()),"integer_domains",arr(List.of(domain)),"default_integer_domain",str("default"),"numbers",obj("decimals",new BooleanValue(false)),"grapheme_rules",NIL,"format_bindings",arr(List.of(obj("name",str("tag"),"reference",reference,"rule",tagFormat))),"bytes_policy",NIL,"wrappers",arr(List.of()),"tag",obj("key",str("$type"),"format",str("tag"),"sealed",arr(List.of())));
        WireValue groups=arr(List.of(obj("id",str("group"),"members",arr(List.of(str("data"),str("op"))))));
        WireValue annotations=arr(List.of(obj("target",variant("Library"),"key",str("description"),"value",toExact(obj("number",num(new java.math.BigInteger("123456789012345678901234567890")),"text",str("資料"))))));
        List<WireValue> annotationRows=new ArrayList<>(a(annotations));
        for(WireValue target:List.of(variant("Group",str("group")),variant("Definition",str("data")),variant("Type",str("number")),fields("Outcome",obj("definition",str("op"),"outcome",str("denied")))))
            annotationRows.add(obj("target",target,"key",str("description"),"value",toExact(obj("decimal",new DecimalValue("1.2300"),"missing",NIL,"unicode",str("資料")))));
        annotations=arr(annotationRows);
        WireValue integer=variant("Integer",obj("domain",str("default"),"minimum",str("-100"),"maximum",str("100"),"const_value",NIL,"enum_values",NIL,"default_value",NIL));
        WireValue tagString=variant("String",obj("format",variant("Named",str("tag")),"lengths",arr(List.of()),"wrapper",NIL,"const_value",NIL,"enum_values",NIL,"examples",arr(List.of()),"default_value",NIL));
        WireValue product=variant("Product",obj("fields",arr(List.of(obj("wire_name",str("n"),"slot",slot("number")),obj("wire_name",str("$type"),"slot",obj("type_id",str("tag"),"required",new BooleanValue(false),"nullable",new BooleanValue(false))))),"extras",variant("Reject")));
        WireValue union=variant("TaggedUnion",obj("branches",arr(List.of(obj("target",str("product"),"wire_tag",str("example.test.value#main"),"selector",variant("InternalTag"))))));
        WireValue nodes=arr(List.of(obj("id",str("number"),"shape",integer),obj("id",str("tag"),"shape",tagString),obj("id",str("product"),"shape",product),obj("id",str("union"),"shape",union)));
        WireValue definitions=arr(List.of(obj("id",str("data"),"wire_identity",str("public.data"),"shape",variant("Value",str("product"))),obj("id",str("op"),"wire_identity",str("public.operation"),"shape",variant("Operation",operation(true)))));
        return obj("schema",str("ncoh-type-signatures@1"),"identity",str("test"),"revision",str("1"),"profile",profile,"sources",arr(List.of(source)),"provenance",arr(List.of()),"groups",groups,"annotations",annotations,"nodes",nodes,"definitions",definitions);
    }
    public static WireValue replace(WireValue object,String key,WireValue value){return TypeSignatures.replace(object,key,value);}
}
