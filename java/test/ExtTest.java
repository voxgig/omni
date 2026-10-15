// RUN: make test
// RUN-SOME: java -cp build ExtTest ctxargs
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

import com.voxgig.omni.Runner;
import com.voxgig.omni.Runner.OmniError;
import com.voxgig.omni.Runner.Provider;
import com.voxgig.omni.Runner.RunPack;
import com.voxgig.omni.Runner.Subject;
import com.voxgig.omni.Util;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

public final class ExtTest {

  private static String only = null;
  private static int passcount = 0;
  private static int failcount = 0;

  private ExtTest() {}

  static final Subject FIB = FibTest.FIB;

  // The ctxargs subject: the context comes first, and must arrive
  // contextified with its client attached.
  static final Subject FIBSHIFTED =
      args -> {
        Map<?, ?> ctx = (Map<?, ?>) args[0];
        if (!"CTX".equals(ctx.get("mark")) || null == ctx.get("client")) {
          throw new IllegalArgumentException("fib: context not delivered");
        }
        double shift = ((Number) ctx.get("shift")).doubleValue();
        return Fib.fibrange(
            ((Number) args[1]).doubleValue() + shift, ((Number) args[2]).doubleValue() + shift);
      };

  static Provider fibprovider() {
    Map<String, Subject> subjects = new LinkedHashMap<>();
    subjects.put("fib", FibTest.FIB);
    subjects.put("fibseq", FibTest.FIBSEQ);
    subjects.put("fibrange", FibTest.FIBRANGE);
    subjects.put("fibinfo", FibTest.FIBINFO);

    Provider provider = new Provider();
    provider.subject = subjects::get;
    provider.contextify =
        val -> {
          if (!Util.ismap(val)) {
            return val;
          }
          @SuppressWarnings("unchecked")
          Map<String, Object> out = new LinkedHashMap<>((Map<String, Object>) val);
          out.put("mark", "CTX");
          return out;
        };
    return provider;
  }

  static RunPack runner(Object spec) {
    return Runner.makeRunner(spec, fibprovider()).runner("fib");
  }

  static Map<String, Object> map(Object... pairs) {
    return FibTest.map(pairs);
  }

  static List<Object> list(Object... entries) {
    return FibTest.list(entries);
  }

  static Object v1(List<Object> requires, Object... set) {
    return map(
        "OMNI", map("version", 1.0, "requires", requires),
        "fib", map("g", map("set", list(set))));
  }

  static void refuses(FibTest.Body run, String pattern) throws Exception {
    try {
      run.run();
    } catch (OmniError err) {
      if (Pattern.compile(pattern, Pattern.DOTALL).matcher(err.getMessage()).find()) {
        return;
      }
      throw new IllegalStateException(
          "omni: expected an OmniError matching [" + pattern + "], got: " + err.getMessage());
    }
    throw new IllegalStateException("omni: expected an OmniError matching [" + pattern + "]");
  }

  static void raisinghook() throws Exception {
    Provider provider = new Provider();
    provider.subject = name -> FIB;
    provider.contextify =
        val -> {
          throw new IllegalStateException("contextify boom");
        };

    RunPack E =
        Runner.makeRunner(v1(list(), map("ctx", map("n", 6.0), "err", "contextify boom")), provider)
            .runner("fib");
    E.runset(E.set("g"), FIB);

    RunPack U =
        Runner.makeRunner(v1(list(), map("ctx", map("n", 6.0), "out", 8.0)), provider)
            .runner("fib");
    refuses(
        () -> U.runset(U.set("g"), FIB),
        "\\[0\\]: unexpected error\n\\s+actual:\\s+contextify boom");

    RunPack W =
        Runner.makeRunner(
                v1(
                    list("wait"),
                    map("ctx", map("n", 6.0), "out", 8.0, "wait", map("cause", "hook#1"))),
                provider)
            .runner("fib");
    W.runset(W.set("g"), FIB);

    Provider fnprovider = new Provider();
    fnprovider.subject =
        name -> {
          if ("boom".equals(name)) {
            throw new IllegalStateException("subject boom");
          }
          return FIB;
        };
    RunPack F =
        Runner.makeRunner(
                v1(list("fn"), map("fn", "boom", "in", 6.0, "err", "subject boom")), fnprovider)
            .runner("fib");
    F.runset(F.set("g"), FIB);
  }

  static void heldhook() throws Exception {
    Provider provider = new Provider();
    provider.subject =
        name -> {
          if ("boom".equals(name)) {
            throw new IllegalStateException("subject boom");
          }
          return "fib".equals(name) ? FIB : null;
        };

    RunPack H =
        Runner.makeRunner(
                v1(
                    list("fn", "wait"),
                    map("fn", "boom", "in", 6.0, "out", 8.0, "wait", map("cause", "hook#2"))),
                provider)
            .runner("fib");
    H.runset(H.set("g"), FIB);

    RunPack S =
        Runner.makeRunner(
                v1(
                    list("fn", "wait"),
                    map(
                        "fn", "boom", "in", 6.0, "err", "subject boom",
                        "wait", map("cause", "hook#3"))),
                provider)
            .runner("fib");
    refuses(() -> S.runset(S.set("g"), FIB), "\\[0\\]: stale wait: hook#3");
  }

  // runset takes the subject positionally, so null asks for the default.
  static void nodefault() throws Exception {
    Provider provider = new Provider();
    provider.subject = name -> "fibx".equals(name) ? FIB : null;

    RunPack R =
        Runner.makeRunner(v1(list("fn"), map("fn", "fibx", "in", 6.0, "out", 8.0)), provider)
            .runner("fib");
    R.runset(R.set("g"), null);

    RunPack N =
        Runner.makeRunner(
                v1(
                    list("fn"),
                    map("fn", "fibx", "in", 6.0, "out", 8.0),
                    map("in", 6.0, "out", 8.0)),
                provider)
            .runner("fib");
    refuses(() -> N.runset(N.set("g"), null), "^omni: no test subject for: fib$");

    RunPack L =
        Runner.makeRunner(v1(list(), map("in", 6.0, "out", 8.0)), provider).runner("fib");
    refuses(() -> L.runset(L.set("g"), null), "^omni: no test subject for: fib$");
  }

  static void testcase(String name, FibTest.Body body) {
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

    RunPack R = runner(FibTest.specfile("ext.json"));

    testcase(
        "capabilities",
        () -> {
          for (String cap : new String[] {"ctxargs", "fn", "wait"}) {
            FibTest.require(Runner.CAPABILITIES.contains(cap), "missing capability: " + cap);
          }
        });
    testcase("ctxargs", () -> R.runset(R.set("ctxargs"), FIBSHIFTED));
    testcase("fn", () -> R.runset(R.set("fn"), FIB));
    testcase("wait", () -> R.runset(R.set("wait"), FIB));

    testcase(
        "a waiting entry that passes fails the set",
        () -> {
          RunPack W =
              runner(v1(list("wait"), map("in", 5.0, "out", 5.0, "wait", map("cause", "gone#1"))));
          refuses(() -> W.runset(W.set("g"), FIB), "\\[0\\]: stale wait: gone#1");
        });

    testcase(
        "the wait flag holds an entry by id",
        () -> {
          RunPack W =
              runner(v1(list(), map("id", "a", "in", 6.0, "out", 9.0), map("in", 7.0, "out", 13.0)));
          W.runsetflags(W.set("g"), Runner.flags("wait", map("a", map("cause", "flag#1"))), FIB);
        });

    testcase(
        "the wait flag fails when its entry passes",
        () -> {
          RunPack W = runner(v1(list(), map("id", "a", "in", 6.0, "out", 8.0)));
          refuses(
              () ->
                  W.runsetflags(
                      W.set("g"), Runner.flags("wait", map("a", map("cause", "flag#1"))), FIB),
              "stale wait: flag#1");
        });

    testcase(
        "the wait flag must name an entry",
        () -> {
          RunPack W = runner(v1(list(), map("id", "a", "in", 6.0, "out", 8.0)));
          refuses(
              () ->
                  W.runsetflags(W.set("g"), Runner.flags("wait", map("zz", map("cause", "c"))), FIB),
              "wait names no entry: zz");
        });

    testcase(
        "a wait needs a cause",
        () -> {
          RunPack W = runner(v1(list("wait"), map("in", 6.0, "out", 9.0, "wait", map())));
          refuses(() -> W.runset(W.set("g"), FIB), "entry wait has no cause");
        });

    testcase(
        "wait and fn are unknown fields unless required",
        () -> {
          RunPack W = runner(v1(list(), map("in", 6.0, "out", 9.0, "wait", map("cause", "c"))));
          refuses(() -> W.runset(W.set("g"), FIB), "unknown entry field: wait");
          RunPack F = runner(v1(list(), map("fn", "fib", "in", 6.0, "out", 8.0)));
          refuses(() -> F.runset(F.set("g"), FIB), "unknown entry field: fn");
        });

    testcase(
        "an unknown fn is a spec error",
        () -> {
          RunPack F = runner(v1(list("fn"), map("fn", "nope", "in", 6.0, "out", 8.0)));
          refuses(() -> F.runset(F.set("g"), FIB), "unknown fn: nope");
        });

    testcase(
        "ctx with args needs ctxargs, and never takes in",
        () -> {
          RunPack N =
              runner(
                  v1(
                      list(),
                      map("ctx", map("shift", 0.0), "args", list(0.0, 1.0), "out", list(0.0, 1.0))));
          refuses(() -> N.runset(N.set("g"), FIBSHIFTED), "more than one of in, args, ctx");
          RunPack I =
              runner(v1(list("ctxargs"), map("in", 1.0, "ctx", map("shift", 0.0), "out", list(0.0))));
          refuses(() -> I.runset(I.set("g"), FIBSHIFTED), "entry has in beside args or ctx");
        });

    testcase(
        "a legacy spec ignores fn and wait",
        () -> {
          RunPack L =
              runner(
                  map(
                      "fib",
                      map(
                          "g",
                          map(
                              "set",
                              list(
                                  map("in", 6.0, "out", 8.0, "fn", "nope", "wait",
                                      map("cause", "c")))))));
          L.runset(L.set("g"), FIB);
        });

    testcase("a raising hook is the entry's error, not the set's", ExtTest::raisinghook);

    testcase(
        "a waiting entry holds a hook's error raised before the subject starts",
        ExtTest::heldhook);

    testcase("fn needs no default subject, but an entry without fn does", ExtTest::nodefault);

    testcase(
        "a wait is found by an id the entry owns, never an inherited one",
        () -> {
          RunPack W =
              runner(
                  v1(
                      list(),
                      map("id", "constructor", "in", 6.0, "out", 8.0),
                      map("id", "toString", "in", 7.0, "out", 13.0)));
          W.runset(W.set("g"), FIB);
          W.runsetflags(W.set("g"), Runner.flags("wait", map()), FIB);
        });

    testcase(
        "all reports every failure at once",
        () -> {
          RunPack A =
              runner(
                  v1(
                      list(),
                      map("in", 5.0, "out", 6.0),
                      map("in", 6.0, "out", 8.0),
                      map("in", 7.0, "out", 14.0)));
          refuses(
              () -> A.runsetflags(A.set("g"), Runner.flags("all", true), FIB),
              "^omni: fib: 2 of 3 entries failed\n.*fib\\[0\\]: result mismatch"
                  + ".*fib\\[2\\]: result mismatch");
          refuses(() -> A.runset(A.set("g"), FIB), "^omni: fib\\[0\\]: result mismatch");
        });

    System.out.println("\n" + passcount + " passed, " + failcount + " failed");
    System.exit(0 == failcount ? 0 : 1);
  }
}
