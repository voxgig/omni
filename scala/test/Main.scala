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

  /** The provider hosts the system under test. `shift` offsets the
    * Fibonacci index, so that a client-specific subject is observably
    * different.
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
        // An empty container asserts an empty container, not "anything".
        "emptymatch" -> Json.map(
          "set" -> Json.list(
            Json.map(
              "in" -> Json.num(6),
              "match" -> Json.map("out" -> Json.map()),
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

    testcase("detects wrong result") { expectfail("wrongout", FIB) }
    testcase("detects missing error") { expectfail("wrongerr", FIB) }
    testcase("detects failed match") { expectfail("wrongmatch", FIB) }
    testcase("detects absent key") { expectfail("missing", FIBINFO) }
    testcase("concrete leaf does not match missing key") { expectfail("matchabsent", FIBINFO) }
    testcase("__UNDEF__ does not match present null") { expectfail("undefonnull", FIBINFO) }
    testcase("__NULL__ does not match absent key") { expectfail("nullonabsent", FIBINFO) }
    testcase("empty match container is not vacuous") { expectfail("emptymatch", FIBINFO) }
    testcase("an empty-string match leaf is not a wildcard") { expectfail("emptystr", FIBINFO) }
    testcase("reports entry index and id") { checkmessage() }

    println(s"\n$passcount passed, $failcount failed")

    System.exit(if 0 == failcount then 0 else 1)
