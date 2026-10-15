// RUN: make test
// RUN-SOME: java -jar build/omnitest.jar 'ext wait'
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

package voxgig.omni.test

import voxgig.omni.CAPABILITIES
import voxgig.omni.Flags
import voxgig.omni.Json
import voxgig.omni.OmniError
import voxgig.omni.RunPack
import voxgig.omni.Subject
import voxgig.omni.makeRunner

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
val FIBSHIFTED: Subject = { args ->
    val ctx = args[0]
    if ("CTX" != ctx.get("mark").asstr || ctx.get("client").isnone) {
        throw FibError("fib: context not delivered")
    }
    val shift = ctx.get("shift").asnum ?: 0.0
    Fib.fibrange(shifted(args[1], shift), shifted(args[2], shift))
}

private fun shifted(index: Json, shift: Double): Json {
    val num = index.asnum ?: return index
    return Json.num(num + shift)
}

private fun extrunner(spec: Json): RunPack = makeRunner(spec, fibprovider(0.0)).runner("fib")

private fun v1(requires: String, set: String): Json =
    Json.parse("""{"OMNI":{"version":1,"requires":$requires},"fib":{"g":{"set":$set}}}""")

private fun refuses(pattern: String, run: () -> Unit) {
    try {
        run()
    } catch (err: OmniError) {
        val msg = err.message ?: ""
        if (!Regex(pattern).containsMatchIn(msg)) {
            throw IllegalStateException("omni: expected an OmniError matching [$pattern], got: $msg")
        }
        return
    }

    throw IllegalStateException("omni: expected an OmniError matching [$pattern]")
}

private fun waitflag(text: String): Flags = Flags(wait = Json.parse(text))

fun extsuite() {
    testcase("ext capabilities") {
        for (cap in listOf("ctxargs", "fn", "wait")) {
            if (cap !in CAPABILITIES) {
                throw IllegalStateException("omni: missing capability: $cap")
            }
        }
    }

    for ((group, subject) in listOf("ctxargs" to FIBSHIFTED, "fn" to FIB, "wait" to FIB)) {
        testcase("ext $group") {
            val R = makeRunner(specfile("ext.json"), fibprovider(0.0)).runner("fib")
            R.runset(R.set(group), subject)
        }
    }

    testcase("a waiting entry that passes fails the set") {
        val R = extrunner(v1("""["wait"]""", """[{"in":5,"out":5,"wait":{"cause":"gone#1"}}]"""))
        refuses("""\[0\]: stale wait: gone#1""") { R.runset(R.set("g"), FIB) }
    }

    testcase("the wait flag holds an entry by id") {
        val R = extrunner(v1("[]", """[{"id":"a","in":6,"out":9},{"in":7,"out":13}]"""))
        R.runsetflags(R.set("g"), waitflag("""{"a":{"cause":"flag#1"}}"""), FIB)
    }

    testcase("the wait flag fails when its entry passes") {
        val R = extrunner(v1("[]", """[{"id":"a","in":6,"out":8}]"""))
        refuses("stale wait: flag#1") {
            R.runsetflags(R.set("g"), waitflag("""{"a":{"cause":"flag#1"}}"""), FIB)
        }
    }

    testcase("the wait flag must name an entry") {
        val R = extrunner(v1("[]", """[{"id":"a","in":6,"out":8}]"""))
        refuses("wait names no entry: zz") {
            R.runsetflags(R.set("g"), waitflag("""{"zz":{"cause":"c"}}"""), FIB)
        }
    }

    testcase("a wait needs a cause") {
        val R = extrunner(v1("""["wait"]""", """[{"in":6,"out":9,"wait":{}}]"""))
        refuses("entry wait has no cause") { R.runset(R.set("g"), FIB) }
    }

    testcase("wait and fn are unknown fields unless required") {
        val W = extrunner(v1("[]", """[{"in":6,"out":9,"wait":{"cause":"c"}}]"""))
        refuses("unknown entry field: wait") { W.runset(W.set("g"), FIB) }
        val F = extrunner(v1("[]", """[{"fn":"fib","in":6,"out":8}]"""))
        refuses("unknown entry field: fn") { F.runset(F.set("g"), FIB) }
    }

    testcase("an unknown fn is a spec error") {
        val R = extrunner(v1("""["fn"]""", """[{"fn":"nope","in":6,"out":8}]"""))
        refuses("unknown fn: nope") { R.runset(R.set("g"), FIB) }
    }

    testcase("ctx with args needs ctxargs, and never takes in") {
        val N = extrunner(v1("[]", """[{"ctx":{"shift":0},"args":[0,1],"out":[0,1]}]"""))
        refuses("more than one of in, args, ctx") { N.runset(N.set("g"), FIBSHIFTED) }
        val I = extrunner(v1("""["ctxargs"]""", """[{"in":1,"ctx":{"shift":0},"out":[0]}]"""))
        refuses("entry has in beside args or ctx") { I.runset(I.set("g"), FIBSHIFTED) }
    }

    testcase("a legacy spec ignores fn and wait") {
        val R = extrunner(
            Json.parse("""{"fib":{"g":{"set":[{"in":6,"out":8,"fn":"nope","wait":{"cause":"c"}}]}}}"""),
        )
        R.runset(R.set("g"), FIB)
    }

    testcase("all reports every failure at once") {
        val R = extrunner(v1("[]", """[{"in":5,"out":6},{"in":6,"out":8},{"in":7,"out":14}]"""))
        refuses("""(?s)^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch""") {
            R.runsetflags(R.set("g"), Flags(all = true), FIB)
        }
        refuses("""^omni: fib\[0\]: result mismatch""") { R.runset(R.set("g"), FIB) }
    }
}
