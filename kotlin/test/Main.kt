// RUN: make test
// RUN-SOME: java -jar build/omnitest.jar basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// JUnit or kotlin.test reports it as a failure. This harness keeps
// `make test` dependency-free.

package voxgig.omni.test

import java.io.File
import kotlin.system.exitProcess
import voxgig.omni.Flags
import voxgig.omni.Json
import voxgig.omni.OmniError
import voxgig.omni.Provider
import voxgig.omni.RunPack
import voxgig.omni.Subject
import voxgig.omni.deepequal
import voxgig.omni.errmessage
import voxgig.omni.makeRunner

private var only: String? = null
private var passcount = 0
private var failcount = 0

/** Find the shared spec directory by walking up from the working dir. */
fun specfile(name: String): String {
    var dir: File? = File(System.getProperty("user.dir"))

    for (step in 0 until 8) {
        if (null == dir) {
            break
        }
        val cand = File(File(dir, "spec"), name)
        if (cand.exists()) {
            return cand.absolutePath
        }
        dir = dir.parentFile
    }

    throw OmniError("omni: spec not found: $name")
}

val FIB: Subject = { args -> Fib.fib(args[0]) }
val FIBSEQ: Subject = { args -> Fib.fibseq(args[0]) }
val FIBRANGE: Subject = { args -> Fib.fibrange(args[0], args[1]) }
val FIBINFO: Subject = { args -> Fib.fibinfo(args[0]) }

// A subject that returns the literal string "__UNDEF__" as ordinary data.
// The absent sentinel must reject it: a sentinel that accepts its own
// literal is not a sentinel.
val FIBUNDEFLITERAL: Subject = { _ -> Json.map("a" to Json.str("__UNDEF__")) }

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec can
// pin both with an ordinary `out` comparison in every port.
val FIBCTX: Subject = { args ->
    val ctx = args[0]
    Json.map(
        "n" to ctx.get("n"),
        "val" to Fib.fib(ctx.get("n")),
        "mark" to ctx.get("mark"),
        "hasclient" to Json.Bool(!ctx.get("client").isnone),
    )
}

/**
 * The provider hosts the system under test. `shift` offsets the Fibonacci
 * index, so that a client-specific subject is observably different.
 * `contextify` marks the map, so the context group can prove the hook ran.
 */
/** Derive fib's error code from its message. */
fun fiberrcode(message: String): String = when {
    message.contains("negative index") -> "fib_negative"
    message.contains("non-integer") -> "fib_noninteger"
    message.contains("not a number") -> "fib_notanumber"
    else -> "fib_unknown"
}

/**
 * The same provider, plus the errify hook: fib's errors gain a CODE.
 *
 * A SECOND runner rather than a hook on `fibprovider`, so that the
 * `error` group keeps exercising the DEFAULT errify.
 */
fun fibcodedprovider(): Provider {
    val base = fibprovider(0.0)
    return Provider(
        subject = base.subject,
        client = base.client,
        contextify = base.contextify,
        inject = base.inject,
        errify = { err ->
            val message = errmessage(err)
            Json.map(
                "name" to Json.str("Error"),
                "message" to Json.str(message),
                "code" to Json.str(fiberrcode(message)),
            )
        },
    )
}

fun fibprovider(shift: Double): Provider =
    Provider(
        subject = { name ->
            when (name) {
                "fib" -> { args ->
                    val num = args[0].asnum
                    if (null != num) Fib.fib(Json.num(num + shift)) else Fib.fib(args[0])
                }
                "fibseq" -> FIBSEQ
                "fibrange" -> FIBRANGE
                "fibinfo" -> FIBINFO
                else -> null
            }
        },
        client = { options -> fibprovider(options.get("shift").asnum ?: 0.0) },
        contextify = { val_ ->
            val out = LinkedHashMap<String, Json>()
            val_.asmap?.forEach { (key, value) -> out[key] = value }
            out["mark"] = Json.str("CTX")
            Json.JMap(out)
        },
    )

fun testcase(name: String, body: () -> Unit) {
    val filter = only
    if (null != filter && name != filter) {
        return
    }

    try {
        body()
        passcount++
        println("ok   - $name")
    } catch (err: Throwable) {
        failcount++
        println("FAIL - $name")
        println(errmessage(err))
    }
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
fun badspec(): Json =
    Json.map(
        "fib" to Json.map(
            "wrongout" to Json.map(
                "set" to Json.list(
                    Json.map("in" to Json.num(5), "out" to Json.num(5)),
                    Json.map("in" to Json.num(6), "out" to Json.num(999)),
                ),
            ),
            "wrongerr" to Json.map(
                "set" to Json.list(
                    Json.map("in" to Json.num(1), "err" to Json.str("never happens")),
                ),
            ),
            "wrongmatch" to Json.map(
                "set" to Json.list(
                    Json.map("in" to Json.num(6), "match" to Json.map("out" to Json.num(999))),
                ),
            ),
            "missing" to Json.map(
                "set" to Json.list(
                    Json.map(
                        "in" to Json.num(6),
                        "match" to Json.map("out" to Json.map("nope" to Json.str("__EXISTS__"))),
                    ),
                ),
            ),
            // A concrete match leaf against a missing key must fail, not
            // substring-match the text "undefined".
            "matchabsent" to Json.map(
                "set" to Json.list(
                    Json.map(
                        "in" to Json.num(6),
                        "match" to Json.map("out" to Json.map("nope" to Json.str("fine"))),
                    ),
                ),
            ),
            // __UNDEF__ (absent) must not be satisfied by a present null.
            "undefonnull" to Json.map(
                "set" to Json.list(
                    Json.map(
                        "in" to Json.num(0),
                        "match" to Json.map("out" to Json.map("prev" to Json.str("__UNDEF__"))),
                    ),
                ),
            ),
            // A subject returning the literal "__UNDEF__" as data must not
            // satisfy an assertion that the key is absent.
            "wrongundef" to Json.map(
                "set" to Json.list(
                    Json.map(
                        "in" to Json.num(6),
                        "match" to Json.map("out" to Json.map("a" to Json.str("__UNDEF__"))),
                    ),
                ),
            ),
            // __NULL__ (present null) must not be satisfied by an absent key.
            "nullonabsent" to Json.map(
                "set" to Json.list(
                    Json.map(
                        "in" to Json.num(6),
                        "match" to Json.map("out" to Json.map("nope" to Json.str("__NULL__"))),
                    ),
                ),
            ),
            // An empty-string match leaf must not substring-match anything.
            "emptystr" to Json.map(
                "set" to Json.list(
                    Json.map(
                        "in" to Json.num(6),
                        "match" to Json.map("out" to Json.map("label" to Json.str(""))),
                    ),
                ),
            ),
        ),
    )

fun expectfail(setname: String, subject: Subject) {
    val bad = makeRunner(badspec()).runner("fib")

    try {
        bad.runset(bad.set(setname), subject)
    } catch (err: OmniError) {
        return
    }

    throw IllegalStateException("omni: expected OmniError for set: $setname")
}

// The runner must refuse a spec it cannot faithfully run, at load time,
// before any set is executed.
fun expectmakerunnerfail(spec: Json, mustcontain: String) {
    try {
        makeRunner(spec)
    } catch (err: OmniError) {
        val msg = err.message ?: ""
        if (!msg.contains(mustcontain)) {
            throw IllegalStateException("omni: message missing [$mustcontain]: $msg")
        }
        return
    }

    throw IllegalStateException("omni: expected OmniError containing: $mustcontain")
}

// Strict (version-1) entry validation must name the entry's mistake.
fun expectrunsetfail(spec: Json, setname: String, subject: Subject, mustcontain: String) {
    val r = makeRunner(spec).runner("fib")

    try {
        r.runset(r.set(setname), subject)
    } catch (err: OmniError) {
        val msg = err.message ?: ""
        if (!msg.contains(mustcontain)) {
            throw IllegalStateException("omni: message missing [$mustcontain]: $msg")
        }
        return
    }

    throw IllegalStateException("omni: expected OmniError containing: $mustcontain")
}

fun checkmessage() {
    val spec = Json.map(
        "fib" to Json.map(
            "g" to Json.map(
                "set" to Json.list(
                    Json.map("in" to Json.num(1), "out" to Json.num(1)),
                    Json.map("id" to Json.str("x#2"), "in" to Json.num(2), "out" to Json.num(42)),
                ),
            ),
        ),
    )

    val bad = makeRunner(spec).runner("fib")

    try {
        bad.runset(bad.set("g"), FIB)
    } catch (err: OmniError) {
        val msg = err.message ?: ""
        for (want in listOf("fib[1] (x#2)", "expected: 42", "actual:   1")) {
            if (!msg.contains(want)) {
                throw IllegalStateException("omni: message missing [$want]: $msg")
            }
        }
        return
    }

    throw IllegalStateException("omni: expected OmniError")
}

fun checkequal(want: Boolean, a: Json, b: Json, what: String) {
    if (want != deepequal(a, b)) {
        throw IllegalStateException("omni: deepequal($what) should be $want")
    }
}

/**
 * deepequal is structural, not IEEE: NaN equals NaN, at the top level and
 * inside nodes, so a subject that returns NaN can still be pinned by a
 * spec. spec/fib.json is the only suite, it is JSON, and JSON has no NaN
 * literal - so this is the only place the rule is checked.
 *
 * The two NaNs come from two *different* expressions and are two
 * different objects. Using one NaN constant twice would let an identity
 * fast-path pass the test while proving nothing.
 */
fun checknan() {
    val n1 = Json.num(Double.POSITIVE_INFINITY - Double.POSITIVE_INFINITY)
    val n2 = Json.num("NaN".toDouble())

    val d1 = n1.asnum ?: 0.0
    val d2 = n2.asnum ?: 0.0
    if (!d1.isNaN() || !d2.isNaN()) {
        throw IllegalStateException("omni: both values must be NaN")
    }

    if (n1 === n2) {
        throw IllegalStateException("omni: the two NaNs must be distinct objects")
    }

    checkequal(true, n1, n2, "NaN, NaN")
    checkequal(true, Json.list(n1), Json.list(n2), "[NaN], [NaN]")
    checkequal(true, Json.map("x" to n1), Json.map("x" to n2), "{x:NaN}, {x:NaN}")

    // Regressions: the NaN rule must not loosen anything else.
    checkequal(true, Json.num(1), Json.num(1.0), "1, 1.0")
    checkequal(false, n1, Json.num(1.0), "NaN, 1.0")
    checkequal(false, Json.Bool(true), Json.num(1), "true, 1")
    checkequal(false, Json.num(1), Json.num(2), "1, 2")
}

fun main(args: Array<String>) {
    if (args.isNotEmpty()) {
        only = args[0]
    }

    val R: RunPack = makeRunner(specfile("fib.json"), fibprovider(0.0)).runner("fib")
    val RC: RunPack = makeRunner(specfile("fib.json"), fibcodedprovider()).runner("fib")

    testcase("basic") { R.runset(R.set("basic"), FIB) }
    testcase("seq") { R.runset(R.set("seq"), FIBSEQ) }
    testcase("range") { R.runset(R.set("range"), FIBRANGE) }
    testcase("info") { R.runset(R.set("info"), FIBINFO) }
    testcase("nulls") { R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO) }
    testcase("error") { R.runset(R.set("error"), FIB) }
    testcase("errcode") { RC.runset(RC.set("errcode"), FIB) }
    testcase("match") { R.runset(R.set("match"), FIB) }
    testcase("matchinfo") { R.runset(R.set("matchinfo"), FIBINFO) }
    testcase("client") { R.runset(R.set("client"), FIB) }
    testcase("context") { R.runset(R.set("context"), FIBCTX) }

    testcase("detects wrong result") { expectfail("wrongout", FIB) }
    testcase("detects missing error") { expectfail("wrongerr", FIB) }
    testcase("detects failed match") { expectfail("wrongmatch", FIB) }
    testcase("detects absent key") { expectfail("missing", FIBINFO) }
    testcase("concrete leaf does not match missing key") { expectfail("matchabsent", FIBINFO) }
    testcase("__UNDEF__ does not match present null") { expectfail("undefonnull", FIBINFO) }
    testcase("__NULL__ does not match absent key") { expectfail("nullonabsent", FIBINFO) }
    testcase("__UNDEF__ does not match its own literal") {
        expectfail("wrongundef", FIBUNDEFLITERAL)
    }
    testcase("an empty-string match leaf is not a wildcard") { expectfail("emptystr", FIBINFO) }
    testcase("reports entry index and id") { checkmessage() }
    testcase("deepequal matches NaN with NaN, structurally") { checknan() }

    testcase("rejects an unsupported spec version") {
        expectmakerunnerfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.num(99)),
                "fib" to Json.map("g" to Json.map("set" to Json.list())),
            ),
            "unsupported spec version",
        )
    }

    testcase("rejects an unknown required capability") {
        expectmakerunnerfail(
            Json.map(
                "OMNI" to Json.map(
                    "version" to Json.num(1),
                    "requires" to Json.list(Json.str("nosuchfeature")),
                ),
                "fib" to Json.map("g" to Json.map("set" to Json.list())),
            ),
            "unsupported capability",
        )
    }

    testcase("rejects a malformed version block") {
        expectmakerunnerfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.str("one")),
                "fib" to Json.map("g" to Json.map("set" to Json.list())),
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
                "OMNI" to Json.Null,
                "fib" to Json.map("g" to Json.map("set" to Json.list(
                    Json.map("in" to Json.num(1), "out" to Json.num(1)),
                ))),
            ),
            "malformed OMNI",
        )
        expectmakerunnerfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.num(1), "requires" to Json.Null),
                "fib" to Json.map("g" to Json.map("set" to Json.list(
                    Json.map("in" to Json.num(1), "out" to Json.num(1)),
                ))),
            ),
            "malformed OMNI requires list",
        )
        makeRunner(
            Json.map("fib" to Json.map("g" to Json.map("set" to Json.list(
                Json.map("in" to Json.num(1), "out" to Json.num(1)),
            )))),
        )
    }

    testcase("strict: an unknown entry field fails instead of passing vacuously") {
        expectrunsetfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.num(1)),
                "fib" to Json.map("g" to Json.map("set" to Json.list(
                    Json.map("in" to Json.num(6), "matches" to Json.map("out" to Json.num(999))),
                ))),
            ),
            "g", FIBINFO, "unknown entry field: matches",
        )
    }

    testcase("strict: more than one of in, args, ctx fails") {
        expectrunsetfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.num(1)),
                "fib" to Json.map("g" to Json.map("set" to Json.list(
                    Json.map("in" to Json.num(5), "args" to Json.list(Json.num(5)), "out" to Json.num(5)),
                ))),
            ),
            "g", FIB, "more than one of in, args, ctx",
        )
    }

    testcase("strict: err together with out fails") {
        expectrunsetfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.num(1)),
                "fib" to Json.map("g" to Json.map("set" to Json.list(
                    Json.map("in" to Json.num(-1), "err" to Json.Bool(true), "out" to Json.num(5)),
                ))),
            ),
            "g", FIB, "both err and out",
        )
    }

    testcase("strict: a null id fails even under null-normalisation") {
        expectrunsetfail(
            Json.map(
                "OMNI" to Json.map("version" to Json.num(1)),
                "fib" to Json.map("g" to Json.map("set" to Json.list(
                    Json.map("in" to Json.num(1), "out" to Json.num(1), "id" to Json.Null),
                ))),
            ),
            "g", FIB, "entry id is not a string",
        )
    }

    testcase("strict: an empty set fails unless marked empty") {
        val spec = Json.map(
            "OMNI" to Json.map("version" to Json.num(1)),
            "fib" to Json.map(
                "g" to Json.map("set" to Json.list()),
                "h" to Json.map("set" to Json.list(), "empty" to Json.Bool(true)),
            ),
        )
        expectrunsetfail(spec, "g", FIB, "empty test set")
        val r = makeRunner(spec).runner("fib")
        r.runset(r.set("h"), FIB)
    }

    testcase("a legacy spec (no OMNI block) stays lenient") {
        val spec = Json.map(
            "fib" to Json.map("g" to Json.map("set" to Json.list(
                Json.map(
                    "in" to Json.num(6),
                    "matches" to Json.map("out" to Json.num(999)),
                    "out" to Json.num(8),
                ),
            ))),
        )
        val r = makeRunner(spec).runner("fib")
        r.runset(r.set("g"), FIB)
    }

    println("\n$passcount passed, $failcount failed")

    exitProcess(if (0 == failcount) 0 else 1)
}
