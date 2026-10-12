// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.io.*;
import java.lang.reflect.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.*;
import necoherence.core.Nat;
import necoherence.progression.ExecutionHandle;

/** Newline-delimited JSON runner for the eight pure network-effect operations. */
public final class NetworkEffectRunner {
  private NetworkEffectRunner() {}
  private static final class Invalid extends Exception { Invalid(String m){super(m);} }
  private static final class P {
    final String x; int i; P(String x){this.x=x;}
    Object get() throws Invalid { ws(); if(i>=x.length())throw new Invalid("value required"); char c=x.charAt(i); if(c=='{')return obj();if(c=='[')return arr();if(c=='"')return str();if(x.startsWith("null",i)){i+=4;return null;}if(x.startsWith("true",i)){i+=4;return true;}if(x.startsWith("false",i)){i+=5;return false;}int b=i;while(i<x.length()&&(Character.isDigit(x.charAt(i))||x.charAt(i)=='-'))i++;if(b==i)throw new Invalid("value expected");try{return new BigInteger(x.substring(b,i));}catch(Exception e){throw new Invalid("number");}}
    Object parse() throws Invalid {Object v=get();ws();if(i!=x.length())throw new Invalid("trailing input");return v;}
    Map<String,Object> obj() throws Invalid {i++;Map<String,Object>m=new LinkedHashMap<>();ws();if(eat('}'))return m;for(;;){ws();String k=(String)str();need(':');m.put(k,get());ws();if(eat('}'))return m;need(',');}}
    List<Object> arr() throws Invalid {i++;List<Object>l=new ArrayList<>();ws();if(eat(']'))return l;for(;;){l.add(get());ws();if(eat(']'))return l;need(',');}}
    Object str() throws Invalid {need('"');StringBuilder b=new StringBuilder();while(i<x.length()){char c=x.charAt(i++);if(c=='"')return b.toString();if(c=='\\'){if(i>=x.length())throw new Invalid("escape");char e=x.charAt(i++);if(e=='u'){if(i+4>x.length())throw new Invalid("unicode");try{b.append((char)Integer.parseInt(x.substring(i,i+4),16));}catch(Exception z){throw new Invalid("unicode");}i+=4;}else b.append(switch(e){case'"','\\','/'->e;case'b'->'\b';case'f'->'\f';case'n'->'\n';case'r'->'\r';case't'->'\t';default->throw new Invalid("escape");});}else b.append(c);}throw new Invalid("string");}
    void ws(){while(i<x.length()&&Character.isWhitespace(x.charAt(i)))i++;}boolean eat(char c){if(i<x.length()&&x.charAt(i)==c){i++;return true;}return false;}void need(char c)throws Invalid{ws();if(!eat(c))throw new Invalid("expected "+c);}
  }
  private static Map<String,Object> map(Object... a){Map<String,Object>m=new LinkedHashMap<>();for(int i=0;i<a.length;i+=2)m.put((String)a[i],a[i+1]);return m;}
  private static Map<String,Object> obj(Object v)throws Invalid{if(!(v instanceof Map<?,?>))throw new Invalid("object required");return(Map<String,Object>)v;}
  private static Object req(Map<String,Object>m,String k)throws Invalid{if(!m.containsKey(k))throw new Invalid(k+" is required");return m.get(k);}
  private static String str(Object v)throws Invalid{if(!(v instanceof String))throw new Invalid("string required");return(String)v;}
  private static Object desurrogate(Object v){
    if(v instanceof String s){StringBuilder b=new StringBuilder(s.length());for(int i=0;i<s.length();i++){char c=s.charAt(i);b.append(c>=0xD800&&c<=0xDFFF?'\uFFFD':c);}return b.toString();}
    if(v instanceof List<?> l){List<Object>r=new ArrayList<>();for(Object z:l)r.add(desurrogate(z));return r;}
    if(v instanceof Map<?,?> m){Map<String,Object>r=new LinkedHashMap<>();for(Map.Entry<?,?> e:m.entrySet())r.put((String)e.getKey(),desurrogate(e.getValue()));return r;}
    return v;
  }
  private static Object dec(Object v,Type t)throws Exception {
    if(t instanceof Class<?> c){
      if(v==null && c.isPrimitive())throw new Invalid("null primitive");
      if(c==Object.class)return v;if(c==String.class)return str(v);if(c==Nat.class){if(!(v instanceof BigInteger b)||b.signum()<0)throw new Invalid("natural required");return Nat.fromTrusted(b);}
      if(c==int.class||c==Integer.class){if(!(v instanceof BigInteger b))throw new Invalid("integer required");return b.intValueExact();}
      if(c.isEnum())try{return Enum.valueOf((Class)c,v instanceof Map<?,?>?str(req(obj(v),"tag")):str(v));}catch(Exception e){throw new Invalid("enum value");}
      if(c==NetworkEffect.SourceSequence.class){if(v==null)return new NetworkEffect.SourceSequence.None();return new NetworkEffect.SourceSequence.Some((Nat)dec(v,Nat.class));}
      if(c.isSealed()){Map<String,Object>m=obj(v);String tag=str(req(m,"tag"));for(Class<?> p:c.getPermittedSubclasses())if(p.getSimpleName().equals(tag))return decRecord(m,p);throw new Invalid("unknown tag "+tag);}
      if(c.isRecord())return decRecord(obj(v),c);
      return v;
    }
    if(t instanceof ParameterizedType p){Type raw=p.getRawType();if(raw==Optional.class)return v==null?Optional.empty():Optional.of(dec(v,p.getActualTypeArguments()[0]));if(raw==List.class){List<Object>r=new ArrayList<>();for(Object z:(List<?>)v)r.add(dec(z,p.getActualTypeArguments()[0]));return r;}return dec(v,raw);}
    throw new Invalid("unsupported type");
  }
  private static Object decRecord(Map<String,Object>m,Class<?> c)throws Exception{
    RecordComponent[]cs=c.getRecordComponents();
    Object[]args=new Object[cs.length];
    for(int i=0;i<cs.length;i++){
      String n=cs[i].getName();
      if(NetworkEffect.AdapterObservation.class.isAssignableFrom(c)&&n.equals("source"))n="sourceSequence";
      if(c==NetworkEffect.AdapterObservation.DeadlineObservation.class&&n.equals("observed"))n="observedAt";
      if(c==NetworkEffect.NetworkOutcome.DeadlineExceeded.class&&n.equals("observed"))n="observedAt";
      if(c==NetworkEffect.RetryPermission.RetryDenied.class&&n.equals("attempt"))n="parent";
      args[i]=dec(req(m,n),cs[i].getGenericType());
    }
    for(Constructor<?> k:c.getDeclaredConstructors()){
      if(k.getParameterCount()==args.length){
        k.setAccessible(true);
        return k.newInstance(args);
      }
    }
    throw new Invalid("constructor unavailable");
  }
  private static Object enc(Object v) {
    if(v==null)return null;
    if(v instanceof Nat n)return new BigInteger(n.toString());
    if(v instanceof Optional<?> o)return o.map(NetworkEffectRunner::enc).orElse(null);
    if(v instanceof String||v instanceof Number||v instanceof Boolean)return v;
    if(v instanceof Enum<?> e) {
      if(e instanceof NetworkEffect.HeaderProvenance||e instanceof NetworkEffect.EffectWitnessSource
          ||e instanceof NetworkEffect.HostStage||e instanceof NetworkEffect.HostTimeoutCause
          ||e instanceof NetworkEffect.UnknownEffectReason)return map("tag",e.name());
      return e.name();
    }
    if(v instanceof NetworkEffect.SourceSequence.None)return null;
    if(v instanceof NetworkEffect.SourceSequence.Some s)return enc(s.ordinal());
    if(v instanceof List<?> l)return l.stream().map(NetworkEffectRunner::enc).toList();
    if(v.getClass().isRecord()) {
      Map<String,Object> m=new LinkedHashMap<>();
      if(v.getClass().getEnclosingClass()!=null&&v.getClass().getEnclosingClass().isSealed())m.put("tag",v.getClass().getSimpleName());
      for(RecordComponent c:v.getClass().getRecordComponents()) {
        String n=c.getName();
        if(v instanceof NetworkEffect.AdapterObservation&&n.equals("source"))n="sourceSequence";
        if(v instanceof NetworkEffect.AdapterObservation.DeadlineObservation&&n.equals("observed"))n="observedAt";
        if(v instanceof NetworkEffect.NetworkOutcome.DeadlineExceeded&&n.equals("observed"))n="observedAt";
        if(v instanceof NetworkEffect.NetworkFailure.DeadlineNotReached&&n.equals("observed"))n="observedAt";
        if(v instanceof NetworkEffect.NetworkFailure.ConflictingDelivery&&n.equals("oldObservation"))n="old";
        if(v instanceof NetworkEffect.NetworkFailure.ConflictingDelivery&&n.equals("newObservation"))n="fresh";
        if(v instanceof NetworkEffect.RetryPermission.RetryDenied&&n.equals("attempt"))n="parent";
        if(v instanceof NetworkEffect.NetworkFailure.RetryOrderViolation&&n.equals("parent"))n="expected";
        if(v instanceof NetworkEffect.NetworkFailure.RetryOrderViolation&&n.equals("next"))n="actual";
        try{m.put(n,enc(c.getAccessor().invoke(v)));}catch(Exception e){throw new IllegalStateException(e);}
      }
      return m;
    }
    return v;
  }
  private static Object run(Object raw)throws Exception {
    Map<String,Object> m=obj(raw);
    String op=str(req(m,"operation"));
    NetworkEffect.NetworkState state=(NetworkEffect.NetworkState)dec(req(m,"state"),NetworkEffect.NetworkState.class);
    return switch(op) {
      case "readNetworkState" -> NetworkEffect.readNetworkState(state);
      case "prepare" -> NetworkEffect.prepare(state,(NetworkEffect.AttemptInput)dec(req(m,"input"),NetworkEffect.AttemptInput.class));
      case "sendCommand" -> NetworkEffect.sendCommand(state,(NetworkEffect.PreparedAttempt)dec(req(m,"prepared"),NetworkEffect.PreparedAttempt.class));
      case "cancelCommand" -> NetworkEffect.cancelCommand(state,(NetworkEffect.StartedAttempt)dec(req(m,"started"),NetworkEffect.StartedAttempt.class));
      case "observeStart" -> NetworkEffect.observeStart(state,(NetworkEffect.PreparedAttempt)dec(req(m,"prepared"),NetworkEffect.PreparedAttempt.class),
          (NetworkEffect.StartObservation)dec(req(m,"observation"),NetworkEffect.StartObservation.class));
      case "observe" -> NetworkEffect.observe(state,(NetworkEffect.HostObservation)dec(req(m,"observation"),NetworkEffect.HostObservation.class));
      case "annotateEffect" -> NetworkEffect.annotateEffect(state,(NetworkEffect.EffectObservation)dec(req(m,"effect"),NetworkEffect.EffectObservation.class));
      case "retry" -> NetworkEffect.retry(state,(NetworkEffect.RetryRequest)dec(req(m,"request"),NetworkEffect.RetryRequest.class));
      default -> throw new Invalid("operation: unknown value "+op);
    };
  }
  private static Object output(Object r){
    if(r instanceof NetworkEffect.ReadStateStep.Read x)return map("result","Read","state",enc(x.state()));
    if(r instanceof NetworkEffect.ReadStateStep.Rejected x)return map("result","Rejected","state",enc(x.state()),"failure",enc(x.failure()));
    if(r instanceof NetworkEffect.PrepareStep.Prepared x)return map("result","Prepared","state",enc(x.state()),"prepared",enc(x.prepared()));
    if(r instanceof NetworkEffect.PrepareStep.Rejected x)return map("result","Rejected","state",enc(x.state()),"failure",enc(x.failure()));
    if(r instanceof NetworkEffect.CommandStep.CommandReady<?> x)return map("result","CommandReady","state",enc(x.state()),"command",enc(x.command()));
    if(r instanceof NetworkEffect.CommandStep.Rejected<?> x)return map("result","Rejected","state",enc(x.state()),"failure",enc(x.failure()));
    if(r instanceof NetworkEffect.StateStep.Applied x)return map("result","Applied","state",enc(x.state()));
    if(r instanceof NetworkEffect.StateStep.Rejected x)return map("result","Rejected","state",enc(x.state()),"failure",enc(x.failure()));
    if(r instanceof NetworkEffect.NetworkStep.Started x)return map("result","Started","state",enc(x.state()),"started",enc(x.started()));
    if(r instanceof NetworkEffect.NetworkStep.Pending x)return map("result","Pending","state",enc(x.state()),"started",enc(x.started()));
    if(r instanceof NetworkEffect.NetworkStep.Terminal x)return map("result","Terminal","state",enc(x.state()),"settled",enc(x.settled()));
    if(r instanceof NetworkEffect.NetworkStep.Late x)return map("result","Late","state",enc(x.state()),"settled",enc(x.settled()),"late",enc(x.late()));
    if(r instanceof NetworkEffect.NetworkStep.Duplicate x)return map("result","Duplicate","state",enc(x.state()),"attempt",enc(x.attempt()),"delivery",enc(x.delivery()));
    NetworkEffect.NetworkStep.Rejected x=(NetworkEffect.NetworkStep.Rejected)r;
    return map("result","Rejected","state",enc(x.state()),"failure",enc(x.failure()));
  }
  private static String quote(String s){
    StringBuilder b=new StringBuilder(s.length()+2).append('"');
    for(int i=0;i<s.length();i++){
      char c=s.charAt(i);
      switch(c){
        case '"'->b.append("\\\"");
        case '\\'->b.append("\\\\");
        case '\b'->b.append("\\b");
        case '\f'->b.append("\\f");
        case '\n'->b.append("\\n");
        case '\r'->b.append("\\r");
        case '\t'->b.append("\\t");
        default->{if(c<0x20)b.append("\\u00").append(Character.forDigit(c>>>4,16)).append(Character.forDigit(c&0xf,16));else b.append(c);}
      }
    }
    return b.append('"').toString();
  }
  private static String json(Object v){if(v==null)return"null";if(v instanceof String s)return quote(s);if(v instanceof Number||v instanceof Boolean)return v.toString();if(v instanceof List<?>l)return l.stream().map(NetworkEffectRunner::json).collect(java.util.stream.Collectors.joining(",","[","]"));Map<String,Object>m=(Map<String,Object>)v;return m.keySet().stream().sorted().map(k->quote(k)+":"+json(m.get(k))).collect(java.util.stream.Collectors.joining(",","{","}"));}
  private static String invoke(String line){try{return json(output(run(desurrogate(new P(line).parse()))));}catch(Exception e){return json(map("result","InvalidInvocation","error",e.getMessage()==null?"invalid invocation":e.getMessage()));}}
  public static void main(String[]args)throws Exception{try(BufferedReader r=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8))){String line;while((line=r.readLine())!=null)System.out.println(invoke(line));}}
}
