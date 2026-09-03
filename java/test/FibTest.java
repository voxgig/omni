// RUN: make test
// RUN-SOME: java -cp build FibTest basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// any host framework (JUnit included) reports it as a failure. This
// harness keeps `make test` dependency-free.

import com.voxgig.omni.Runner;
import com.voxgig.omni.Runner.OmniError;
import com.voxgig.omni.Runner.Provider;
import com.voxgig.omni.Runner.RunPack;
import com.voxgig.omni.Runner.Subject;
import com.voxgig.omni.Util;
import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class FibTest {

  private static String only = null;
  private static int passcount = 0;
  private static int failcount = 0;

  private FibTest() {}

  /** Find the shared spec directory by walking up from the class path. */
  static String specfile(String name) {
    File dir = new File(System.getProperty("user.dir"));

    for (int step = 0; step < 8 && null != dir; step++) {
      File cand = new File(new File(dir, "spec"), name);
      if (cand.exists()) {
        return cand.getAbsolutePath();
      }
      dir = dir.getParentFile();
    }

    throw new OmniError("omni: spec not found: " + name);
  }

  static final Subject FIB = args -> Fib.fib(args[0]);
  static final Subject FIBSEQ = args -> Fib.fibseq(args[0]);
  static final Subject FIBRANGE = args -> Fib.fibrange(args[0], args[1]);
  static final Subject FIBINFO = args -> Fib.fibinfo(args[0]);

  // A subject whose ordinary data happens to be the literal sentinel text.
  static final Subject FIBUNDEFLITERAL = args -> map("n", args[0], "a", "__UNDEF__");

  // The context-group subject: reports what the runner delivered - the
  // contextify mark and the attached client - as plain data, so the spec
  // can pin both with an ordinary `out` comparison in every port.
  static final Subject FIBCTX =
      args -> {
        Map<?, ?> ctx = (Map<?, ?>) args[0];
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("n", ctx.get("n"));
        out.put("val", Fib.fib(ctx.get("n")));
        out.put("mark", ctx.get("mark"));
        out.put("hasclient", null != ctx.get("client"));
        return out;
      };

  /**
   * The provider hosts the system under test. `shift` offsets the
   * Fibonacci index, so that a client-specific subject is observably
   * different. `contextify` marks the map, so the context group can prove
   * the hook ran.
   */
  /** Derive fib's error code from its message. */
  static String fiberrcode(String message) {
    if (message.contains("negative index")) {
      return "fib_negative";
    }
    if (message.contains("non-integer")) {
      return "fib_noninteger";
    }
    if (message.contains("not a number")) {
      return "fib_notanumber";
    }
    return "fib_unknown";
  }

  /**
   * The same provider, plus the errify hook: fib's errors gain a CODE.
   *
   * <p>A SECOND runner rather than a hook on fibprovider, so that the
   * {@code error} group keeps exercising the DEFAULT errify.
   */
  static Provider fibcodedprovider() {
    Provider provider = fibprovider(0);
    provider.errify =
        err -> {
          String message =
              err instanceof Throwable
                  ? String.valueOf(((Throwable) err).getMessage())
                  : String.valueOf(err);
          Map<String, Object> out = new LinkedHashMap<>();
          out.put("name", "Error");
          out.put("message", message);
          out.put("code", fiberrcode(message));
          return out;
        };
    return provider;
  }

  static Provider fibprovider(final double shift) {
    Map<String, Subject> subjects = new LinkedHashMap<>();
    subjects.put(
        "fib",
        args -> {
          if (Util.isnum(args[0])) {
            return Fib.fib(((Number) args[0]).doubleValue() + shift);
          }
          return Fib.fib(args[0]);
        });
    subjects.put("fibseq", FIBSEQ);
    subjects.put("fibrange", FIBRANGE);
    subjects.put("fibinfo", FIBINFO);

    Provider provider = new Provider();
    provider.subject = subjects::get;
    provider.client =
        options -> {
          double clientshift = 0;
          if (Util.ismap(options)) {
            Object raw = ((Map<?, ?>) options).get("shift");
            if (Util.isnum(raw)) {
              clientshift = ((Number) raw).doubleValue();
            }
          }
          return fibprovider(clientshift);
        };
    provider.contextify =
        val -> {
          if (!Util.ismap(val)) {
            return val;
          }
          @SuppressWarnings("unchecked")
          Map<String, Object> base = (Map<String, Object>) val;
          Map<String, Object> out = new LinkedHashMap<>(base);
          out.put("mark", "CTX");
          return out;
        };

    return provider;
  }

  interface Body {
    void run() throws Exception;
  }

  static void testcase(String name, Body body) {
    if (null != only && !name.equals(only)) {
      return;
    }

    try {
      body.run();
      passcount++;
      System.out.println("ok   - " + name);
    } catch (Throwable err) {
      failcount++;
      System.out.println("FAIL - " + name);
      System.out.println(err.getMessage());
    }
  }

  public static void main(String[] args) {
    if (0 < args.length) {
      only = args[0];
    }

    RunPack R = Runner.makeRunner(specfile("fib.json"), fibprovider(0)).runner("fib");
    RunPack RC = Runner.makeRunner(specfile("fib.json"), fibcodedprovider()).runner("fib");

    testcase("basic", () -> R.runset(R.set("basic"), FIB));
    testcase("seq", () -> R.runset(R.set("seq"), FIBSEQ));
    testcase("range", () -> R.runset(R.set("range"), FIBRANGE));
    testcase("info", () -> R.runset(R.set("info"), FIBINFO));
    testcase(
        "nulls", () -> R.runsetflags(R.set("nulls"), Runner.flags("null", false), FIBINFO));
    testcase("error", () -> R.runset(R.set("error"), FIB));
    testcase("errcode", () -> RC.runset(RC.set("errcode"), FIB));
    testcase("match", () -> R.runset(R.set("match"), FIB));
    testcase("matchinfo", () -> R.runset(R.set("matchinfo"), FIBINFO));
    testcase("client", () -> R.runset(R.set("client"), FIB));
    testcase("context", () -> R.runset(R.set("context"), FIBCTX));

    // The runner must fail when the subject is wrong - otherwise a green
    // suite means nothing.
    testcase("detects wrong result", () -> expectfail("wrongout", FIB));
    testcase("detects missing error", () -> expectfail("wrongerr", FIB));
    testcase("detects failed match", () -> expectfail("wrongmatch", FIB));
    testcase("detects absent key", () -> expectfail("missing", FIBINFO));
    testcase(
        "concrete leaf does not match missing key", () -> expectfail("matchabsent", FIBINFO));
    testcase("__UNDEF__ does not match present null", () -> expectfail("undefonnull", FIBINFO));
    testcase("__NULL__ does not match absent key", () -> expectfail("nullonabsent", FIBINFO));
    testcase(
        "an empty-string match leaf is not a wildcard", () -> expectfail("emptystr", FIBINFO));
    testcase(
        "__UNDEF__ does not match a literal \"__UNDEF__\" in the data",
        () -> expectfail("wrongundef", FIBUNDEFLITERAL));

    testcase("rejects an unsupported spec version", FibTest::rejectsUnsupportedVersion);
    testcase("rejects an unknown required capability", FibTest::rejectsUnknownCapability);
    testcase("rejects a malformed version block", FibTest::rejectsMalformedVersion);
    testcase(
        "rejects a null OMNI block, but accepts an absent one",
        FibTest::rejectsNullOmniAcceptsAbsent);
    testcase(
        "strict: an unknown entry field fails instead of passing vacuously",
        FibTest::strictUnknownField);
    testcase("strict: more than one of in, args, ctx fails", FibTest::strictMultipleArgSources);
    testcase("strict: err together with out fails", FibTest::strictErrWithOut);
    testcase(
        "strict: a null id fails even under null-normalisation", FibTest::strictNullId);
    testcase("strict: an empty set fails unless marked empty", FibTest::strictEmptySet);
    testcase("a legacy spec (no OMNI block) stays lenient", FibTest::legacyLenient);

    testcase("reports entry index and id", FibTest::checkmessage);

    testcase("deepequal: NaN equals NaN, structurally", FibTest::deepequalNaN);

    System.out.println("\n" + passcount + " passed, " + failcount + " failed");
    System.exit(0 == failcount ? 0 : 1);
  }

  static Map<String, Object> map(Object... pairs) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int index = 0; index + 1 < pairs.length; index += 2) {
      out.put(String.valueOf(pairs[index]), pairs[index + 1]);
    }
    return out;
  }

  static List<Object> list(Object... entries) {
    List<Object> out = new ArrayList<>();
    for (Object entry : entries) {
      out.add(entry);
    }
    return out;
  }

  static Object badspec() {
    return map(
        "fib",
        map(
            "wrongout",
            map("set", list(map("in", 5.0, "out", 5.0), map("in", 6.0, "out", 999.0))),
            "wrongerr",
            map("set", list(map("in", 1.0, "err", "never happens"))),
            "wrongmatch",
            map("set", list(map("in", 6.0, "match", map("out", 999.0)))),
            "missing",
            map("set", list(map("in", 6.0, "match", map("out", map("nope", "__EXISTS__"))))),
            // A concrete match leaf against a missing key must fail, not
            // substring-match the text "undefined".
            "matchabsent",
            map("set", list(map("in", 6.0, "match", map("out", map("nope", "fine"))))),
            // __UNDEF__ (absent) must not be satisfied by a present null.
            "undefonnull",
            map("set", list(map("in", 0.0, "match", map("out", map("prev", "__UNDEF__"))))),
            // __NULL__ (present null) must not be satisfied by an absent key.
            "nullonabsent",
            map("set", list(map("in", 6.0, "match", map("out", map("nope", "__NULL__"))))),
            // An empty-string match leaf must not substring-match anything.
            "emptystr",
            map("set", list(map("in", 6.0, "match", map("out", map("label", ""))))),
            // __UNDEF__ (absent) must not be satisfied by a subject returning
            // the literal string "__UNDEF__" as ordinary data.
            "wrongundef",
            map("set", list(map("in", 6.0, "match", map("out", map("a", "__UNDEF__")))))));
  }

  static void expectfail(String setname, Subject subject) {
    RunPack bad = Runner.makeRunner(badspec(), null).runner("fib");

    try {
      bad.runset(bad.set(setname), subject);
    } catch (OmniError err) {
      return;
    }

    throw new IllegalStateException("omni: expected OmniError for set: " + setname);
  }

  static void requirecontains(String message, String want) {
    if (!message.contains(want)) {
      throw new IllegalStateException("omni: message missing [" + want + "]: " + message);
    }
  }

  static void rejectsUnsupportedVersion() {
    Object spec = map("OMNI", map("version", 99.0), "fib", map("g", map("set", list())));
    try {
      Runner.makeRunner(spec, null);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "unsupported spec version");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for unsupported spec version");
  }

  static void rejectsUnknownCapability() {
    Object spec =
        map(
            "OMNI",
            map("version", 1.0, "requires", list("nosuchfeature")),
            "fib",
            map("g", map("set", list())));
    try {
      Runner.makeRunner(spec, null);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "unsupported capability");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for unknown capability");
  }

  static void rejectsMalformedVersion() {
    Object spec = map("OMNI", map("version", "one"), "fib", map("g", map("set", list())));
    try {
      Runner.makeRunner(spec, null);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "malformed OMNI");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for malformed version block");
  }

  static void requireRejectsWith(Object spec, String want) {
    try {
      Runner.makeRunner(spec, null);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), want);
      return;
    }
    throw new IllegalStateException("omni: expected OmniError containing [" + want + "]");
  }

  // A present-but-null block is malformed; only a genuinely absent OMNI
  // key is legacy. Ports that test definedness rather than presence
  // silently skip strict mode here, so both cases are pinned.
  static void rejectsNullOmniAcceptsAbsent() {
    requireRejectsWith(
        map("OMNI", null, "fib", map("g", map("set", list(map("in", 1.0, "out", 1.0))))),
        "malformed OMNI");

    requireRejectsWith(
        map(
            "OMNI",
            map("version", 1.0, "requires", null),
            "fib",
            map("g", map("set", list(map("in", 1.0, "out", 1.0))))),
        "malformed OMNI requires list");

    // A spec with no OMNI key at all is legacy, and must load fine.
    Runner.makeRunner(map("fib", map("g", map("set", list(map("in", 1.0, "out", 1.0))))), null);
  }

  static void strictUnknownField() {
    Object spec =
        map(
            "OMNI",
            map("version", 1.0),
            "fib",
            map("g", map("set", list(map("in", 6.0, "matches", map("out", 999.0))))));
    RunPack R = Runner.makeRunner(spec, null).runner("fib");
    try {
      R.runset(R.set("g"), FIBINFO);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "unknown entry field: matches");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for unknown entry field");
  }

  static void strictMultipleArgSources() {
    Object spec =
        map(
            "OMNI",
            map("version", 1.0),
            "fib",
            map("g", map("set", list(map("in", 5.0, "args", list(5.0), "out", 5.0)))));
    RunPack R = Runner.makeRunner(spec, null).runner("fib");
    try {
      R.runset(R.set("g"), FIB);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "more than one of in, args, ctx");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for multiple arg sources");
  }

  static void strictErrWithOut() {
    Object spec =
        map(
            "OMNI",
            map("version", 1.0),
            "fib",
            map("g", map("set", list(map("in", -1.0, "err", true, "out", 5.0)))));
    RunPack R = Runner.makeRunner(spec, null).runner("fib");
    try {
      R.runset(R.set("g"), FIB);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "both err and out");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for err with out");
  }

  // This is the case Fix 1 and the id half of Fix 2 both guard: without
  // checkset() validating the AUTHORED entries, null-normalisation would
  // rewrite `id: null` into the NULLMARK sentinel string before this rule
  // ever saw it, and a malformed strict entry would be accepted.
  static void strictNullId() {
    Object spec =
        map(
            "OMNI",
            map("version", 1.0),
            "fib",
            map("g", map("set", list(map("in", 1.0, "out", 1.0, "id", null)))));
    RunPack R = Runner.makeRunner(spec, null).runner("fib");
    try {
      R.runset(R.set("g"), FIB);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "entry id is not a string");
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for a null id");
  }

  static void strictEmptySet() {
    Object spec =
        map(
            "OMNI",
            map("version", 1.0),
            "fib",
            map(
                "g", map("set", list()),
                "h", map("set", list(), "empty", true)));
    RunPack R = Runner.makeRunner(spec, null).runner("fib");
    try {
      R.runset(R.set("g"), FIB);
    } catch (OmniError err) {
      requirecontains(err.getMessage(), "empty test set");
      R.runset(R.set("h"), FIB);
      return;
    }
    throw new IllegalStateException("omni: expected OmniError for empty set");
  }

  static void legacyLenient() {
    Object spec =
        map(
            "fib",
            map(
                "g",
                map(
                    "set",
                    list(map("in", 6.0, "matches", map("out", 999.0), "out", 8.0)))));
    RunPack R = Runner.makeRunner(spec, null).runner("fib");
    R.runset(R.set("g"), FIB);
  }

  static void require(boolean cond, String what) {
    if (!cond) {
      throw new IllegalStateException("omni: " + what);
    }
  }

  // deepequal is structural, not IEEE: two NaNs are equal, however they
  // were made. spec/fib.json cannot pin this - JSON has no NaN literal -
  // so it is pinned here.
  static void deepequalNaN() {
    // Two NaNs from two DIFFERENT expressions, boxed into two DIFFERENT
    // Double objects. Util.deepequal opens with an `a == b` identity
    // fast-path, so a test written with one shared NaN constant used
    // twice can pass while proving nothing.
    double zero = 0.0;
    Object n1 = Double.valueOf(zero / zero);
    Object n2 = Double.valueOf(Double.POSITIVE_INFINITY - Double.POSITIVE_INFINITY);

    require(Double.isNaN((Double) n1), "expected a NaN from 0.0/0.0");
    require(
        Double.isNaN((Double) n2), "expected a NaN from Infinity-Infinity");
    require(n1 != n2, "the two NaNs must not be the same object");

    require(Util.deepequal(n1, n2), "NaN must equal NaN");
    require(Util.deepequal(list(n1), list(n2)), "NaN must equal NaN inside a list");
    require(Util.deepequal(map("x", n1), map("x", n2)), "NaN must equal NaN inside a map");

    // Regressions: the NaN rule must not loosen anything else.
    require(Util.deepequal(1, 1.0), "an int must equal the same float");
    require(!Util.deepequal(n1, 1.0), "NaN must not equal a real number");
    require(!Util.deepequal(true, 1), "a bool is never a number");
    require(!Util.deepequal(1, 2), "1 must not equal 2");
  }

  static void checkmessage() {
    Object spec =
        map(
            "fib",
            map(
                "g",
                map("set", list(map("in", 1.0, "out", 1.0), map("id", "x#2", "in", 2.0, "out", 42.0)))));

    RunPack bad = Runner.makeRunner(spec, null).runner("fib");

    try {
      bad.runset(bad.set("g"), FIB);
    } catch (OmniError err) {
      String msg = err.getMessage();
      for (String want : new String[] {"fib[1] (x#2)", "expected: 42", "actual:   1"}) {
        if (!msg.contains(want)) {
          throw new IllegalStateException("omni: message missing [" + want + "]: " + msg);
        }
      }
      return;
    }

    throw new IllegalStateException("omni: expected OmniError");
  }
}
