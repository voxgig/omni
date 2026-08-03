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

  /**
   * The provider hosts the system under test. `shift` offsets the
   * Fibonacci index, so that a client-specific subject is observably
   * different.
   */
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

    testcase("basic", () -> R.runset(R.set("basic"), FIB));
    testcase("seq", () -> R.runset(R.set("seq"), FIBSEQ));
    testcase("range", () -> R.runset(R.set("range"), FIBRANGE));
    testcase("info", () -> R.runset(R.set("info"), FIBINFO));
    testcase(
        "nulls", () -> R.runsetflags(R.set("nulls"), Runner.flags("null", false), FIBINFO));
    testcase("error", () -> R.runset(R.set("error"), FIB));
    testcase("match", () -> R.runset(R.set("match"), FIB));
    testcase("matchinfo", () -> R.runset(R.set("matchinfo"), FIBINFO));
    testcase("client", () -> R.runset(R.set("client"), FIB));

    // The runner must fail when the subject is wrong - otherwise a green
    // suite means nothing.
    testcase("detects wrong result", () -> expectfail("wrongout", FIB));
    testcase("detects missing error", () -> expectfail("wrongerr", FIB));
    testcase("detects failed match", () -> expectfail("wrongmatch", FIB));
    testcase("detects absent key", () -> expectfail("missing", FIBINFO));
    testcase("reports entry index and id", FibTest::checkmessage);

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
            map("set", list(map("in", 6.0, "match", map("out", map("nope", "__EXISTS__")))))));
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
