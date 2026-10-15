// RUN: make test
//
// The capability suite: the groups of spec/ext.json, which requires
// ctxargs, fn and wait, and the runner flag `all`.

package voxgig.omni.test

import java.util.regex.Pattern

import voxgig.omni.*

object Ext:

  import Main.{FIB, testcase}

  // The ctxargs subject: the context comes first, and must arrive
  // contextified with its client attached.
  val FIBSHIFTED: Subject = args =>
    val ctx = args.head
    if !ctx.get("mark").asstr.contains("CTX") || ctx.get("client").isnone then
      throw FibError("fib: context not delivered")
    val shift = ctx.get("shift").asnum.getOrElse(0.0)
    def shifted(value: Json): Json = value.asnum.fold(value)(num => Json.num(num + shift))
    Fib.fibrange(shifted(args(1)), shifted(args(2)))

  def runner(spec: Json): RunPack = Runner.makeRunner(spec, Main.fibprovider(0.0)).runner("fib")

  def refuses(pattern: String)(run: => Unit): Unit =
    try run
    catch
      case err: OmniError =>
        if !Pattern.compile(pattern).matcher(err.text).find() then
          throw IllegalStateException(s"omni: expected an OmniError matching [$pattern]: ${err.text}")
        return

    throw IllegalStateException(s"omni: expected an OmniError matching [$pattern]")

  def v1(requires: List[String], set: Json*): Json =
    Json.map(
      "OMNI" -> Json.map(
        "version" -> Json.num(1),
        "requires" -> Json.JList(requires.map(Json.str)),
      ),
      "fib" -> Json.map("g" -> Json.map("set" -> Json.list(set*))),
    )

  def waitflag(id: String, cause: String): Json =
    Json.map(id -> Json.map("cause" -> Json.str(cause)))

  def suite(): Unit =
    val R = Runner.makeRunner(Main.specfile("ext.json"), Main.fibprovider(0.0)).runner("fib")

    testcase("capabilities") {
      for cap <- List("ctxargs", "fn", "wait") do
        if !CAPABILITIES.contains(cap) then
          throw IllegalStateException(s"omni: missing capability: $cap")
    }

    testcase("ctxargs") { R.runset(R.set("ctxargs"), Some(FIBSHIFTED)) }
    testcase("fn") { R.runset(R.set("fn"), Some(FIB)) }
    testcase("wait") { R.runset(R.set("wait"), Some(FIB)) }

    testcase("a waiting entry that passes fails the set") {
      val W = runner(v1(List("wait"), Json.map(
        "in" -> Json.num(5), "out" -> Json.num(5),
        "wait" -> Json.map("cause" -> Json.str("gone#1")),
      )))
      refuses("""\[0\]: stale wait: gone#1""") { W.runset(W.set("g"), Some(FIB)) }
    }

    testcase("the wait flag holds an entry by id") {
      val W = runner(v1(List(),
        Json.map("id" -> Json.str("a"), "in" -> Json.num(6), "out" -> Json.num(9)),
        Json.map("in" -> Json.num(7), "out" -> Json.num(13)),
      ))
      W.runsetflags(W.set("g"), Flags(waits = waitflag("a", "flag#1")), Some(FIB))
    }

    testcase("the wait flag fails when its entry passes") {
      val W = runner(v1(List(),
        Json.map("id" -> Json.str("a"), "in" -> Json.num(6), "out" -> Json.num(8)),
      ))
      refuses("stale wait: flag#1") {
        W.runsetflags(W.set("g"), Flags(waits = waitflag("a", "flag#1")), Some(FIB))
      }
    }

    testcase("the wait flag must name an entry") {
      val W = runner(v1(List(),
        Json.map("id" -> Json.str("a"), "in" -> Json.num(6), "out" -> Json.num(8)),
      ))
      refuses("wait names no entry: zz") {
        W.runsetflags(W.set("g"), Flags(waits = waitflag("zz", "c")), Some(FIB))
      }
    }

    testcase("a wait needs a cause") {
      val W = runner(v1(List("wait"),
        Json.map("in" -> Json.num(6), "out" -> Json.num(9), "wait" -> Json.map()),
      ))
      refuses("entry wait has no cause") { W.runset(W.set("g"), Some(FIB)) }
    }

    testcase("wait and fn are unknown fields unless required") {
      val W = runner(v1(List(), Json.map(
        "in" -> Json.num(6), "out" -> Json.num(9),
        "wait" -> Json.map("cause" -> Json.str("c")),
      )))
      refuses("unknown entry field: wait") { W.runset(W.set("g"), Some(FIB)) }
      val F = runner(v1(List(),
        Json.map("fn" -> Json.str("fib"), "in" -> Json.num(6), "out" -> Json.num(8)),
      ))
      refuses("unknown entry field: fn") { F.runset(F.set("g"), Some(FIB)) }
    }

    testcase("an unknown fn is a spec error") {
      val F = runner(v1(List("fn"),
        Json.map("fn" -> Json.str("nope"), "in" -> Json.num(6), "out" -> Json.num(8)),
      ))
      refuses("unknown fn: nope") { F.runset(F.set("g"), Some(FIB)) }
    }

    testcase("ctx with args needs ctxargs, and never takes in") {
      val N = runner(v1(List(), Json.map(
        "ctx" -> Json.map("shift" -> Json.num(0)),
        "args" -> Json.list(Json.num(0), Json.num(1)),
        "out" -> Json.list(Json.num(0), Json.num(1)),
      )))
      refuses("more than one of in, args, ctx") { N.runset(N.set("g"), Some(FIBSHIFTED)) }
      val I = runner(v1(List("ctxargs"), Json.map(
        "in" -> Json.num(1),
        "ctx" -> Json.map("shift" -> Json.num(0)),
        "out" -> Json.list(Json.num(0)),
      )))
      refuses("entry has in beside args or ctx") { I.runset(I.set("g"), Some(FIBSHIFTED)) }
    }

    testcase("a legacy spec ignores fn and wait") {
      val L = runner(Json.map("fib" -> Json.map("g" -> Json.map("set" -> Json.list(
        Json.map(
          "in" -> Json.num(6), "out" -> Json.num(8), "fn" -> Json.str("nope"),
          "wait" -> Json.map("cause" -> Json.str("c")),
        ),
      )))))
      L.runset(L.set("g"), Some(FIB))
    }

    testcase("a raising hook is the entry's error, not the set's") {
      val provider = Provider(
        subject = Some(_ => Some(FIB)),
        contextify = Some(_ => throw RuntimeException("contextify boom")),
      )
      def run(spec: Json): RunPack = Runner.makeRunner(spec, provider).runner("fib")
      val E = run(v1(List(),
        Json.map("ctx" -> Json.map("n" -> Json.num(6)), "err" -> Json.str("contextify boom")),
      ))
      E.runset(E.set("g"), Some(FIB))
      val U = run(v1(List(),
        Json.map("ctx" -> Json.map("n" -> Json.num(6)), "out" -> Json.num(8)),
      ))
      refuses("""\[0\]: unexpected error\n\s+actual:\s+contextify boom""") {
        U.runset(U.set("g"), Some(FIB))
      }
      val W = run(v1(List("wait"), Json.map(
        "ctx" -> Json.map("n" -> Json.num(6)), "out" -> Json.num(8),
        "wait" -> Json.map("cause" -> Json.str("hook#1")),
      )))
      W.runset(W.set("g"), Some(FIB))
      val F = Runner.makeRunner(
        v1(List("fn"),
          Json.map("fn" -> Json.str("boom"), "in" -> Json.num(6), "err" -> Json.str("subject boom")),
        ),
        Provider(subject = Some { name =>
          if "boom" == name then throw RuntimeException("subject boom")
          Some(FIB)
        }),
      ).runner("fib")
      F.runset(F.set("g"), Some(FIB))
    }

    testcase("all reports every failure at once") {
      val A = runner(v1(List(),
        Json.map("in" -> Json.num(5), "out" -> Json.num(6)),
        Json.map("in" -> Json.num(6), "out" -> Json.num(8)),
        Json.map("in" -> Json.num(7), "out" -> Json.num(14)),
      ))
      refuses(
        """(?s)^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch""",
      ) {
        A.runsetflags(A.set("g"), Flags(all = true), Some(FIB))
      }
      refuses("""^omni: fib\[0\]: result mismatch""") { A.runset(A.set("g"), Some(FIB)) }
    }
