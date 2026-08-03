// Omni: the shared multi-language test runner.
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

package com.voxgig.omni;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.regex.Pattern;

public final class Runner {

  public static final String NULLMARK = Util.NULLMARK;
  public static final String UNDEFMARK = Util.UNDEFMARK;
  public static final String EXISTSMARK = Util.EXISTSMARK;

  private Runner() {}

  /** The function under test. Arguments arrive as JSON values. */
  public interface Subject {
    Object call(Object... args) throws Exception;
  }

  /** A test failure (or a malformed spec). */
  public static class OmniError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public final transient Object entry;

    public OmniError(String message) {
      this(message, null);
    }

    public OmniError(String message, Object entry) {
      super(message);
      this.entry = entry;
    }
  }

  /** The host of the system under test. Every hook is optional. */
  public static class Provider {
    /** Resolve a test subject by name. */
    public Function<String, Subject> subject;

    /** Build a sub-provider from a DEF.client entry's options. */
    public Function<Object, Provider> client;

    /** Wrap a map argument as a call context. */
    public Function<Object, Object> contextify;

    /** Resolve references in client options against the store. */
    public BiFunction<Object, Object, Object> inject;
  }

  /** Run-time options for a set of test entries. */
  public static Map<String, Object> flags(Object... pairs) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int index = 0; index + 1 < pairs.length; index += 2) {
      out.put(String.valueOf(pairs[index]), pairs[index + 1]);
    }
    return out;
  }

  /** What a runner returns for one named spec section. */
  public static final class RunPack {
    public final Object spec;
    public final Subject subject;
    public final Provider client;

    private final String name;
    private final Provider provider;
    private final Map<String, Provider> clients;

    RunPack(
        Object spec,
        Subject subject,
        Provider provider,
        Map<String, Provider> clients,
        String name) {
      this.spec = spec;
      this.subject = subject;
      this.client = provider;
      this.provider = provider;
      this.clients = clients;
      this.name = name;
    }

    /** A named group of the resolved spec. */
    @SuppressWarnings("unchecked")
    public Object set(String setname) {
      if (Util.ismap(spec)) {
        return ((Map<String, Object>) spec).get(setname);
      }
      return null;
    }

    /** Run one set of test entries. */
    public void runset(Object testspec, Subject testsubject) {
      runsetflags(testspec, new LinkedHashMap<>(), testsubject);
    }

    /** Run one set of test entries with flags. */
    @SuppressWarnings("unchecked")
    public void runsetflags(Object testspec, Map<String, Object> useflags, Subject testsubject) {
      Map<String, Object> flags = resolveflags(useflags);
      if (null == flags.get("name")) {
        flags.put("name", null == name || name.isEmpty() ? "set" : name);
      }

      Subject subject = null != testsubject ? testsubject : this.subject;
      if (null == subject) {
        throw new OmniError("omni: no test subject for: " + flags.get("name"));
      }

      Object testspecmap = fixjson(testspec, flags);
      if (!Util.ismap(testspecmap)
          || !Util.islist(((Map<String, Object>) testspecmap).get("set"))) {
        throw new OmniError("omni: test spec has no set: " + flags.get("name"));
      }

      List<Object> testset = (List<Object>) ((Map<String, Object>) testspecmap).get("set");

      for (int index = 0; index < testset.size(); index++) {
        Object rawentry = testset.get(index);
        if (!Util.ismap(rawentry)) {
          throw new OmniError("omni: " + flags.get("name") + "[" + index + "]: entry is not a map");
        }

        Map<String, Object> entry = resolveentry((Map<String, Object>) rawentry, flags);

        Subject entrysubject = subject;
        Provider entryclient = provider;

        Object clientname = entry.get("client");
        if (null != clientname) {
          Provider found = clients.get(String.valueOf(clientname));
          if (null == found) {
            throw new OmniError("omni: unknown client: " + clientname, entry);
          }
          entryclient = found;
          Subject clientsubject = resolvesubject(name, found);
          if (null != clientsubject) {
            entrysubject = clientsubject;
          }
        }

        Object[] args = resolveargs(entry, entryclient, provider);

        Object res;
        try {
          res = entrysubject.call(args);
        } catch (OmniError omnierr) {
          throw omnierr;
        } catch (Throwable err) {
          handleerror(flags, index, entry, err);
          continue;
        }

        res = fixjson(res, flags);
        entry.put("res", res);

        checkresult(flags, index, entry, args, res);
      }
    }
  }

  /** Resolves one named section of a spec. */
  public static final class RunnerPack {
    private final Object alltests;
    private final Provider provider;

    RunnerPack(Object alltests, Provider provider) {
      this.alltests = alltests;
      this.provider = provider;
    }

    public RunPack runner(String name) {
      return runner(name, null);
    }

    public RunPack runner(String name, Object store) {
      Object spec = resolvespec(name, alltests);
      Map<String, Provider> clients = resolveclients(provider, spec, store);
      Subject subject = resolvesubject(name, provider);
      return new RunPack(spec, subject, provider, clients, name);
    }
  }

  /** Make a runner for a spec file path (or spec value) and a provider. */
  public static RunnerPack makeRunner(Object specref, Provider provider) {
    Object alltests = loadspec(specref);
    return new RunnerPack(alltests, null == provider ? new Provider() : provider);
  }

  /** Load a spec: a path to a JSON file, or an already-parsed value. */
  public static Object loadspec(Object specref) {
    if (specref instanceof String) {
      try {
        String text = new String(Files.readAllBytes(Paths.get((String) specref)), StandardCharsets.UTF_8);
        return Json.parse(text);
      } catch (IOException err) {
        throw new OmniError("omni: cannot read spec: " + specref);
      }
    }
    return specref;
  }

  /** Find `primary.<name>`, then `<name>`, then the whole spec. */
  @SuppressWarnings("unchecked")
  public static Object resolvespec(String name, Object alltests) {
    if (null == name || name.isEmpty()) {
      return alltests;
    }

    if (Util.ismap(alltests)) {
      Map<String, Object> allmap = (Map<String, Object>) alltests;

      Object primary = allmap.get("primary");
      if (Util.ismap(primary)) {
        Object section = ((Map<String, Object>) primary).get(name);
        if (null != section) {
          return section;
        }
      }

      Object section = allmap.get(name);
      if (null != section) {
        return section;
      }
    }

    return alltests;
  }

  /** Build the named clients declared by the spec's DEF.client block. */
  @SuppressWarnings("unchecked")
  static Map<String, Provider> resolveclients(Provider provider, Object spec, Object store) {
    Map<String, Provider> clients = new HashMap<>();

    if (!Util.ismap(spec)) {
      return clients;
    }

    Object def = ((Map<String, Object>) spec).get("DEF");
    if (!Util.ismap(def)) {
      return clients;
    }

    Object defclient = ((Map<String, Object>) def).get("client");
    if (!Util.ismap(defclient)) {
      return clients;
    }

    // A spec may define clients that a given test run never references.
    if (null == provider.client) {
      return clients;
    }

    for (Map.Entry<String, Object> entry : ((Map<String, Object>) defclient).entrySet()) {
      Object copts = new LinkedHashMap<String, Object>();
      Object cdef = entry.getValue();
      if (Util.ismap(cdef)) {
        Object ctest = ((Map<String, Object>) cdef).get("test");
        if (Util.ismap(ctest)) {
          Object options = ((Map<String, Object>) ctest).get("options");
          if (null != options) {
            copts = Util.clone(options);
          }
        }
      }

      if (null != provider.inject && Util.ismap(store)) {
        provider.inject.apply(copts, store);
      }

      clients.put(entry.getKey(), provider.client.apply(copts));
    }

    return clients;
  }

  static Subject resolvesubject(String name, Provider provider) {
    if (null == name || name.isEmpty() || null == provider || null == provider.subject) {
      return null;
    }
    return provider.subject.apply(name);
  }

  static Map<String, Object> resolveflags(Map<String, Object> flags) {
    Map<String, Object> out = new LinkedHashMap<>();
    if (null != flags) {
      out.putAll(flags);
    }
    if (null == out.get("null")) {
      out.put("null", Boolean.TRUE);
    }
    return out;
  }

  static boolean flagbool(Map<String, Object> flags, String name) {
    Object val = flags.get(name);
    return val instanceof Boolean && (Boolean) val;
  }

  /** An entry with no `out` expects a null (or absent) result. */
  static Map<String, Object> resolveentry(Map<String, Object> entry, Map<String, Object> flags) {
    if (null == entry.get("out") && flagbool(flags, "null")) {
      entry.put("out", NULLMARK);
    }
    return entry;
  }

  /** Build the argument list: `ctx`, `args`, or `in`. */
  @SuppressWarnings("unchecked")
  static Object[] resolveargs(Map<String, Object> entry, Provider client, Provider provider) {
    Object[] args;

    boolean hasctx = entry.containsKey("ctx");
    boolean hasargs = entry.containsKey("args");

    if (hasctx) {
      args = new Object[] {entry.get("ctx")};
    } else if (hasargs) {
      Object rawargs = entry.get("args");
      if (Util.islist(rawargs)) {
        args = ((List<Object>) rawargs).toArray();
      } else {
        args = new Object[] {rawargs};
      }
    } else {
      args = new Object[] {Util.clone(entry.get("in"))};
    }

    if ((hasctx || hasargs) && 0 < args.length && Util.ismap(args[0])) {
      Object first = Util.clone(args[0]);
      if (null != provider.contextify) {
        first = provider.contextify.apply(first);
      }
      if (Util.ismap(first)) {
        ((Map<String, Object>) first).put("client", client);
      }
      args[0] = first;
      entry.put("ctx", first);
    }

    return args;
  }

  /** Nulls become NULLMARK, errors become {name,message}. Always a copy. */
  public static Object fixjson(Object val, Map<String, Object> flags) {
    boolean donull = null == flags || null == flags.get("null") || flagbool(flags, "null");
    return fixjsonval(val, donull);
  }

  @SuppressWarnings("unchecked")
  static Object fixjsonval(Object val, boolean donull) {
    if (null == val || Util.isabsent(val)) {
      return donull ? NULLMARK : null;
    }

    if (val instanceof Throwable) {
      return errify(val);
    }

    if (Util.islist(val)) {
      List<Object> out = new ArrayList<>();
      for (Object entry : (List<Object>) val) {
        out.add(fixjsonval(entry, donull));
      }
      return out;
    }

    if (Util.ismap(val)) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : ((Map<String, Object>) val).entrySet()) {
        out.put(entry.getKey(), fixjsonval(entry.getValue(), donull));
      }
      return out;
    }

    return val;
  }

  /** The JSON form of an error: always at least {name,message}. */
  public static Map<String, Object> errify(Object err) {
    Map<String, Object> out = new LinkedHashMap<>();
    if (err instanceof Throwable) {
      out.put("name", err.getClass().getSimpleName());
      out.put("message", errmessage((Throwable) err));
    } else {
      out.put("name", "Error");
      out.put("message", String.valueOf(err));
    }
    return out;
  }

  static String errmessage(Throwable err) {
    String message = err.getMessage();
    return null == message ? err.getClass().getSimpleName() : message;
  }

  /** The label of one entry, for failure messages. */
  static String entryref(Map<String, Object> flags, int index, Map<String, Object> entry) {
    Object label = flags.get("name");
    Object id = null == entry ? null : entry.get("id");
    String idpart = null == id ? "" : " (" + Util.stringify(id) + ")";
    return (null == label ? "set" : String.valueOf(label)) + "[" + index + "]" + idpart;
  }

  static OmniError fail(
      Map<String, Object> flags,
      int index,
      Map<String, Object> entry,
      String reason,
      String expected,
      String actual) {

    StringBuilder msg = new StringBuilder();
    msg.append("omni: ").append(entryref(flags, index, entry)).append(": ").append(reason);
    if (null != expected) {
      msg.append("\n  expected: ").append(expected);
    }
    if (null != actual) {
      msg.append("\n  actual:   ").append(actual);
    }
    msg.append("\n  entry:    ").append(Util.stringify(entrysummary(entry)));

    return new OmniError(msg.toString(), entry);
  }

  /** The spec-defined part of an entry (drop runner bookkeeping). */
  static Object entrysummary(Map<String, Object> entry) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map.Entry<String, Object> field : entry.entrySet()) {
      String key = field.getKey();
      if (!"res".equals(key) && !"thrown".equals(key) && !"ctx".equals(key)) {
        out.put(key, field.getValue());
      }
    }
    return out;
  }

  static void checkresult(
      Map<String, Object> flags, int index, Map<String, Object> entry, Object[] args, Object res) {

    boolean matched = false;

    Object entryerr = entry.get("err");
    if (null != entryerr) {
      throw fail(
          flags,
          index,
          entry,
          "expected error did not occur",
          Util.stringify(entryerr),
          Util.stringify(res));
    }

    Object check = entry.get("match");
    if (null != check) {
      Map<String, Object> base = new LinkedHashMap<>();
      base.put("in", entry.get("in"));
      base.put("args", new ArrayList<>(java.util.Arrays.asList(args)));
      base.put("out", entry.get("res"));
      base.put("ctx", entry.get("ctx"));
      match(flags, index, entry, check, base);
      matched = true;
    }

    Object out = entry.get("out");

    if (Util.deepequal(res, out)) {
      return;
    }

    // NOTE: a match with no explicit out is a complete check on its own.
    if (matched && (NULLMARK.equals(out) || null == out)) {
      return;
    }

    throw fail(flags, index, entry, "result mismatch", Util.stringify(out), Util.stringify(res));
  }

  static void handleerror(
      Map<String, Object> flags, int index, Map<String, Object> entry, Throwable err) {

    Object entryerr = entry.get("err");

    if (null != entryerr) {
      boolean istrue = entryerr instanceof Boolean && (Boolean) entryerr;

      if (istrue || matchval(entryerr, errmessage(err))) {
        Object check = entry.get("match");
        if (null != check) {
          Map<String, Object> base = new LinkedHashMap<>();
          base.put("in", entry.get("in"));
          base.put("out", entry.get("res"));
          base.put("ctx", entry.get("ctx"));
          base.put("err", errify(err));
          match(flags, index, entry, check, base);
        }
        return;
      }

      throw fail(
          flags, index, entry, "error mismatch", Util.stringify(entryerr), errmessage(err));
    }

    throw fail(flags, index, entry, "unexpected error", null, errmessage(err));
  }

  /** Check that every leaf of `check` is present, and matches, in `base`. */
  public static void match(
      Map<String, Object> flags, int index, Map<String, Object> entry, Object check, Object base) {

    Object cbase = Util.clone(base);

    Util.walk(
        Util.clone(check),
        (key, val, parent, path) -> {
          if (Util.isnode(val)) {
            return val;
          }

          Object baseval = Util.getpath(cbase, path);

          if (Util.deepequal(val, baseval)) {
            return val;
          }

          // Explicitly absent.
          if (UNDEFMARK.equals(val) && Util.isabsent(baseval)) {
            return val;
          }

          // Explicitly present.
          if (EXISTSMARK.equals(val) && !Util.isabsent(baseval) && null != baseval) {
            return val;
          }

          if (!matchval(val, baseval)) {
            throw fail(
                flags,
                index,
                entry,
                "match failed at " + (path.isEmpty() ? "<root>" : Util.pathify(path)),
                Util.stringify(val),
                Util.stringify(baseval));
          }

          return val;
        });
  }

  /** Match one leaf: /regex/ or case-insensitive substring for strings. */
  public static boolean matchval(Object check, Object base) {
    if (Util.deepequal(check, base)) {
      return true;
    }

    Object want = check;
    if (UNDEFMARK.equals(want) || NULLMARK.equals(want)) {
      want = null;
    }

    if (null == want) {
      return null == base || Util.isabsent(base) || NULLMARK.equals(base);
    }

    if (want instanceof String) {
      String text = (String) want;
      String basestr = Util.stringify(base);

      if (2 < text.length() && text.startsWith("/") && text.endsWith("/")) {
        String pattern = text.substring(1, text.length() - 1);
        try {
          return Pattern.compile(pattern).matcher(basestr).find();
        } catch (RuntimeException err) {
          return false;
        }
      }

      return basestr.toLowerCase().contains(text.toLowerCase());
    }

    return Util.deepequal(want, base);
  }

  /** Convert NULLMARK sentinels back into real nulls. */
  @SuppressWarnings("unchecked")
  public static Object nullmodifier(Object key, Object val, Object parent, List<Object> path) {
    if (val instanceof String) {
      String text = (String) val;
      if (NULLMARK.equals(text)) {
        return null;
      }
      return text.replace(NULLMARK, "null");
    }
    return val;
  }
}
