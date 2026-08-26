// RUN: make test
// RUN-SOME: scala -cp build voxgig.omni.test.Main basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// ScalaTest or munit reports it as a failure. This harness keeps
// `make test` dependency-free.

package voxgig.omni.test

import java.io.File
import scala.util.control.NonFatal

import voxgig.omni.*

object Main:

  private var only: Option[String] = None
  private var passcount = 0
  private var failcount = 0

  /** Find the shared spec directory by walking up from the working dir. */
  def specfile(name: String): String =
    var dir = File(System.getProperty("user.dir"))
    var found: Option[String] = None
    var step = 0

    while found.isEmpty && step < 8 && null != dir do
      val cand = File(File(dir, "spec"), name)
      if cand.exists then found = Some(cand.getAbsolutePath)
      else dir = dir.getParentFile
      step += 1

    found.getOrElse(throw OmniError(s"omni: spec not found: $name"))

  val FIB: Subject = args => Fib.fib(args.head)
  val FIBSEQ: Subject = args => Fib.fibseq(args.head)
  val FIBRANGE: Subject = args => Fib.fibrange(args.head, args(1))
  val FIBINFO: Subject = args => Fib.fibinfo(args.head)

  // A subject that returns the sentinel's own literal text as ordinary
  // data. A __UNDEF__ match leaf asserts the key is absent, so it must not
  // be satisfied by a present value that merely spells the sentinel.
  val FIBUNDEF: Subject = _ => Json.map("a" -> Json.str("__UNDEF__"))

  // The context-group subject: reports what the runner delivered - the
  // contextify mark and the attached client - as plain data, so the spec
  // can pin both with an ordinary `out` comparison in every port.
  val FIBCTX: Subject = args =>
    val ctx = args.head
    Json.map(
      "n" -> ctx.get("n"),
      "val" -> Fib.fib(ctx.get("n")),
      "mark" -> ctx.get("mark"),
      "hasclient" -> Json.Bool(!ctx.get("client").isnone),
    )

  /** The provider hosts the system under test. `shift` offsets the
    * Fibonacci index, so that a client-specific subject is observably
    * different. `contextify` marks the map, so the context group can
    * prove the hook ran.
    */
  def fibprovider(shift: Double): Provider =
    Provider(
      subject = Some {
        case "fib" =>
          Some(args =>
            args.head.asnum match
              case Some(num) => Fib.fib(Json.num(num + shift))
              case None      => Fib.fib(args.head)
          )
        case "fibseq"   => Some(FIBSEQ)
        case "fibrange" => Some(FIBRANGE)
        case "fibinfo"  => Some(FIBINFO)
        case _          => None
      },
      client = Some(options => fibprovider(options.get("shift").asnum.getOrElse(0.0))),
      contextify = Some(value =>
        value.asmap match
          case Some(entries) => Json.JMap(entries.updated("mark", Json.str("CTX")))
          case None          => value
      ),
    )

  def testcase(name: String)(body: => Unit): Unit =
    if only.exists(_ != name) then return

    try
      body
      passcount += 1
      println(s"ok   - $name")
    catch
      case NonFatal(err) =>
        failcount += 1
        println(s"FAIL - $name")
        println(Runner.errmessage(err))

  // The runner must fail when the subject is wrong - otherwise a green
  // suite means nothing.
  def badspec(): Json =
    Json.map(
      "fib" -> Json.map(
        "wrongout" -> Json.map(
          "set" -> Json.list(
            Json.map("in" -> Json.num(5), "out" -> Json.num(5)),
            Json.map("in" -> Json.num(6), "out" -> Json.num(999)),
          )
        ),
        "wrongerr" -> Json.map(
          "set" -> Json.list(Json.map("in" -> Json.num(1), "err" -> Json.str("never happens")))
        ),
        "wrongmatch" -> Json.map(
          "set" -> Json.list(
            Json.map("in" -> Json.num(6), "match" -> Json.map("out" -> Json.num(999)))
          )
        ),
        "missing" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(6),
              "match" -> Json.map("out" -> Json.map("nope" -> Json.str("__EXISTS__"))),
            )
          )
        ),
        // A concrete match leaf against a missing key must fail, not
        // substring-match the text "undefined".
        "matchabsent" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(6),
              "match" -> Json.map("out" -> Json.map("nope" -> Json.str("fine"))),
            )
          )
        ),
        // __UNDEF__ (absent) must not be satisfied by a present null.
        "undefonnull" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(0),
              "match" -> Json.map("out" -> Json.map("prev" -> Json.str("__UNDEF__"))),
            )
          )
        ),
        // __NULL__ (present null) must not be satisfied by an absent key.
        "nullonabsent" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(6),
              "match" -> Json.map("out" -> Json.map("nope" -> Json.str("__NULL__"))),
            )
          )
        ),
        // __UNDEF__ (absent) must not be satisfied by the sentinel's own
        // literal text returned as ordinary data.
        "wrongundef" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(6),
              "match" -> Json.map("out" -> Json.map("a" -> Json.str("__UNDEF__"))),
            )
          )
        ),
        // An empty-string match leaf must not substring-match anything.
        "emptystr" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(6),
              "match" -> Json.map("out" -> Json.map("label" -> Json.str(""))),
            )
          )
        ),
      )
    )

  def expectfail(setname: String, subject: Subject): Unit =
    val bad = Runner.makeRunner(badspec()).runner("fib")

    try bad.runset(bad.set(setname), Some(subject))
    catch case _: OmniError => return

    throw IllegalStateException(s"omni: expected OmniError for set: $setname")

  // The runner must refuse a spec it cannot faithfully run, at load time,
  // before any set is executed.
  def expectmakerunnerfail(spec: Json, mustcontain: String): Unit =
    try Runner.makeRunner(spec)
    catch
      case err: OmniError =>
        if !err.text.contains(mustcontain) then
          throw IllegalStateException(s"omni: message missing [$mustcontain]: ${err.text}")
        return

    throw IllegalStateException(s"omni: expected OmniError containing: $mustcontain")

  // Strict (version-1) entry validation must name the entry's mistake.
  def expectrunsetfail(spec: Json, setname: String, subject: Subject, mustcontain: String): Unit =
    val r = Runner.makeRunner(spec).runner("fib")

    try r.runset(r.set(setname), Some(subject))
    catch
      case err: OmniError =>
        if !err.text.contains(mustcontain) then
          throw IllegalStateException(s"omni: message missing [$mustcontain]: ${err.text}")
        return

    throw IllegalStateException(s"omni: expected OmniError containing: $mustcontain")

  def checkmessage(): Unit =
    val spec = Json.map(
      "fib" -> Json.map(
        "g" -> Json.map(
          "set" -> Json.list(
            Json.map("in" -> Json.num(1), "out" -> Json.num(1)),
            Json.map("id" -> Json.str("x#2"), "in" -> Json.num(2), "out" -> Json.num(42)),
          )
        )
      )
    )

    val bad = Runner.makeRunner(spec).runner("fib")

    try bad.runset(bad.set("g"), Some(FIB))
    catch
      case err: OmniError =>
        for want <- List("fib[1] (x#2)", "expected: 42", "actual:   1") do
          if !err.text.contains(want) then
            throw IllegalStateException(s"omni: message missing [$want]: ${err.text}")
        return

    throw IllegalStateException("omni: expected OmniError")

  def checkequal(want: Boolean, a: Json, b: Json, what: String): Unit =
    if want != Util.deepequal(a, b) then
      throw IllegalStateException(s"omni: deepequal($what) should be $want")

  /** deepequal is structural, not IEEE: NaN equals NaN, at the top level
    * and inside nodes, so a subject that returns NaN can still be pinned
    * by a spec. spec/fib.json is the only suite, it is JSON, and JSON has
    * no NaN literal - so this is the only place the rule is checked.
    *
    * The two NaNs come from two *different* expressions and are two
    * different objects. Using one NaN constant twice would let an
    * identity fast-path pass the test while proving nothing.
    */
  def checknan(): Unit =
    val n1 = Json.num(Double.PositiveInfinity - Double.PositiveInfinity)
    val n2 = Json.num("NaN".toDouble)

    if !n1.asnum.exists(_.isNaN) || !n2.asnum.exists(_.isNaN) then
      throw IllegalStateException("omni: both values must be NaN")

    if n1.eq(n2) then throw IllegalStateException("omni: the two NaNs must be distinct objects")

    checkequal(true, n1, n2, "NaN, NaN")
    checkequal(true, Json.list(n1), Json.list(n2), "[NaN], [NaN]")
    checkequal(true, Json.map("x" -> n1), Json.map("x" -> n2), "{x:NaN}, {x:NaN}")

    // Regressions: the NaN rule must not loosen anything else.
    checkequal(true, Json.num(1), Json.num(1.0), "1, 1.0")
    checkequal(false, n1, Json.num(1.0), "NaN, 1.0")
    checkequal(false, Json.Bool(true), Json.num(1), "true, 1")
    checkequal(false, Json.num(1), Json.num(2), "1, 2")

  def main(args: Array[String]): Unit =
    if args.nonEmpty then only = Some(args(0))

    val R = Runner.makeRunner(specfile("fib.json"), fibprovider(0.0)).runner("fib")

    testcase("basic") { R.runset(R.set("basic"), Some(FIB)) }
    testcase("seq") { R.runset(R.set("seq"), Some(FIBSEQ)) }
    testcase("range") { R.runset(R.set("range"), Some(FIBRANGE)) }
    testcase("info") { R.runset(R.set("info"), Some(FIBINFO)) }
    testcase("nulls") { R.runsetflags(R.set("nulls"), Flags.nonull(), Some(FIBINFO)) }
    testcase("error") { R.runset(R.set("error"), Some(FIB)) }
    testcase("match") { R.runset(R.set("match"), Some(FIB)) }
    testcase("matchinfo") { R.runset(R.set("matchinfo"), Some(FIBINFO)) }
    testcase("client") { R.runset(R.set("client"), Some(FIB)) }
    testcase("context") { R.runset(R.set("context"), Some(FIBCTX)) }

    testcase("detects wrong result") { expectfail("wrongout", FIB) }
    testcase("detects missing error") { expectfail("wrongerr", FIB) }
    testcase("detects failed match") { expectfail("wrongmatch", FIB) }
    testcase("detects absent key") { expectfail("missing", FIBINFO) }
    testcase("concrete leaf does not match missing key") { expectfail("matchabsent", FIBINFO) }
    testcase("__UNDEF__ does not match present null") { expectfail("undefonnull", FIBINFO) }
    testcase("__NULL__ does not match absent key") { expectfail("nullonabsent", FIBINFO) }
    testcase("__UNDEF__ does not match its own literal") { expectfail("wrongundef", FIBUNDEF) }
    testcase("an empty-string match leaf is not a wildcard") { expectfail("emptystr", FIBINFO) }
    testcase("reports entry index and id") { checkmessage() }
    testcase("deepequal matches NaN with NaN, structurally") { checknan() }

    testcase("rejects an unsupported spec version") {
      expectmakerunnerfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.num(99)),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list())),
        ),
        "unsupported spec version",
      )
    }

    testcase("rejects an unknown required capability") {
      expectmakerunnerfail(
        Json.map(
          "OMNI" -> Json.map(
            "version" -> Json.num(1),
            "requires" -> Json.list(Json.str("nosuchfeature")),
          ),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list())),
        ),
        "unsupported capability",
      )
    }

    testcase("rejects a malformed version block") {
      expectmakerunnerfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.str("one")),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list())),
        ),
        "malformed OMNI",
      )
    }

    // A present-but-null block is malformed; only a genuinely absent OMNI
    // key is legacy. Ports that test definedness rather than presence
    // silently skip strict mode here, so both cases are pinned.
    testcase("rejects a null OMNI block, but accepts an absent one") {
      expectmakerunnerfail(
        Json.map(
          "OMNI" -> Json.Null,
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
            Json.map("in" -> Json.num(1), "out" -> Json.num(1)),
          ))),
        ),
        "malformed OMNI",
      )
      expectmakerunnerfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.num(1), "requires" -> Json.Null),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
            Json.map("in" -> Json.num(1), "out" -> Json.num(1)),
          ))),
        ),
        "malformed OMNI requires list",
      )
      Runner.makeRunner(
        Json.map("fib" -> Json.map("g" -> Json.map("set" -> Json.list(
          Json.map("in" -> Json.num(1), "out" -> Json.num(1)),
        )))),
      )
    }

    testcase("strict: an unknown entry field fails instead of passing vacuously") {
      expectrunsetfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.num(1)),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
            Json.map("in" -> Json.num(6), "matches" -> Json.map("out" -> Json.num(999))),
          ))),
        ),
        "g", FIBINFO, "unknown entry field: matches",
      )
    }

    testcase("strict: more than one of in, args, ctx fails") {
      expectrunsetfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.num(1)),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
            Json.map("in" -> Json.num(5), "args" -> Json.list(Json.num(5)), "out" -> Json.num(5)),
          ))),
        ),
        "g", FIB, "more than one of in, args, ctx",
      )
    }

    testcase("strict: err together with out fails") {
      expectrunsetfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.num(1)),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
            Json.map("in" -> Json.num(-1), "err" -> Json.Bool(true), "out" -> Json.num(5)),
          ))),
        ),
        "g", FIB, "both err and out",
      )
    }

    testcase("strict: a null id fails even under null-normalisation") {
      expectrunsetfail(
        Json.map(
          "OMNI" -> Json.map("version" -> Json.num(1)),
          "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
            Json.map("in" -> Json.num(1), "out" -> Json.num(1), "id" -> Json.Null),
          ))),
        ),
        "g", FIB, "entry id is not a string",
      )
    }

    testcase("strict: an empty set fails unless marked empty") {
      val spec = Json.map(
        "OMNI" -> Json.map("version" -> Json.num(1)),
        "fib" -> Json.map(
          "g" -> Json.map("set" -> Json.list()),
          "h" -> Json.map("set" -> Json.list(), "empty" -> Json.Bool(true)),
        ),
      )
      expectrunsetfail(spec, "g", FIB, "empty test set")
      val r = Runner.makeRunner(spec).runner("fib")
      r.runset(r.set("h"), Some(FIB))
    }

    testcase("a legacy spec (no OMNI block) stays lenient") {
      val spec = Json.map(
        "fib" -> Json.map("g" -> Json.map("set" -> Json.list(
          Json.map(
            "in" -> Json.num(6),
            "matches" -> Json.map("out" -> Json.num(999)),
            "out" -> Json.num(8),
          ),
        ))),
      )
      val r = Runner.makeRunner(spec).runner("fib")
      r.runset(r.set("g"), Some(FIB))
    }

    println(s"\n$passcount passed, $failcount failed")

    System.exit(if 0 == failcount then 0 else 1)
