// Omni: the shared multi-language test runner (Kotlin port).
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

package voxgig.omni

import java.io.File
import java.util.regex.Pattern
import java.util.regex.PatternSyntaxException

/** The function under test. Arguments arrive as JSON values. */
typealias Subject = (List<Json>) -> Json

/**
 * A test failure (or a malformed spec). Distinct from an exception thrown
 * by the subject under test, which is a candidate for an `err` expectation.
 */
class OmniError(message: String, val entry: Json = Json.Absent) : RuntimeException(message)

/** Run-time options for a set of test entries. */
data class Flags(val nulls: Boolean = true, val name: String? = null) {
    companion object {
        fun nonull(): Flags = Flags(nulls = false)
    }
}

/** The host of the system under test. Every hook is optional. */
class Provider(
    val subject: ((String) -> Subject?)? = null,
    val client: ((Json) -> Provider)? = null,
    val contextify: ((Json) -> Json)? = null,
    val inject: ((Json, Json) -> Json)? = null,
)

/** Load a spec: a path to a JSON file. */
fun loadspec(path: String): Json {
    val file = File(path)
    if (!file.exists()) {
        throw OmniError("omni: cannot read spec: $path")
    }
    return Json.parse(file.readText())
}

/** Find `primary.<name>`, then `<name>`, then the whole spec. */
fun resolvespec(name: String, alltests: Json): Json {
    if (name.isEmpty()) {
        return alltests
    }

    val primary = alltests.get("primary").get(name)
    if (!primary.isabsent) {
        return primary
    }

    val section = alltests.get(name)
    if (!section.isabsent) {
        return section
    }

    return alltests
}

/** Nulls (and absent values) become NULLMARK. Always a fresh copy. */
fun fixjson(val_: Json, donull: Boolean): Json {
    if (val_.isnone) {
        return if (donull) Json.str(NULLMARK) else Json.Null
    }

    if (val_ is Json.JList) {
        return Json.JList(val_.value.map { fixjson(it, donull) }.toMutableList())
    }

    if (val_ is Json.JMap) {
        val out = LinkedHashMap<String, Json>()
        for ((key, entry) in val_.value) {
            out[key] = fixjson(entry, donull)
        }
        return Json.JMap(out)
    }

    return val_
}

/** The JSON form of an error: always at least {name,message}. */
fun errify(err: Throwable): Json =
    Json.map(
        "name" to Json.str(err::class.simpleName ?: "Error"),
        "message" to Json.str(errmessage(err)),
    )

fun errmessage(err: Throwable): String = err.message ?: (err::class.simpleName ?: "Error")

/** Match one leaf: /regex/ or case-insensitive substring for strings. */
fun matchval(check: Json, base: Json): Boolean {
    if (deepequal(check, base)) {
        return true
    }

    val text = check.asstr
    if (null != text) {
        // An empty want would substring-match anything.
        if (text.isEmpty()) {
            return false
        }

        val basestr = stringify(base)

        if (2 < text.length && text.startsWith("/") && text.endsWith("/")) {
            return try {
                Pattern.compile(text.substring(1, text.length - 1)).matcher(basestr).find()
            } catch (err: PatternSyntaxException) {
                false
            }
        }

        return basestr.lowercase().contains(text.lowercase())
    }

    return deepequal(check, base)
}

/** Convert NULLMARK sentinels back into real nulls. */
fun nullmodifier(val_: Json): Json {
    val text = val_.asstr ?: return val_
    return if (NULLMARK == text) Json.Null else Json.str(text.replace(NULLMARK, "null"))
}

/** What a runner returns for one named spec section. */
class RunPack(
    val spec: Json,
    val subject: Subject?,
    val client: Provider,
    private val clients: Map<String, Provider>,
    private val name: String,
) {
    /** A named group of the resolved spec. */
    fun set(setname: String): Json = spec.get(setname)

    /** Run one set of test entries. */
    fun runset(testspec: Json, testsubject: Subject? = null) {
        runsetflags(testspec, Flags(), testsubject)
    }

    /** Run one set of test entries with flags. */
    fun runsetflags(testspec: Json, flags: Flags, testsubject: Subject? = null) {
        val label = flags.name ?: if (name.isEmpty()) "set" else name

        val usesubject = testsubject ?: subject
            ?: throw OmniError("omni: no test subject for: $label")

        val testspecmap = fixjson(testspec, flags.nulls)
        val testset = testspecmap.get("set").aslist
            ?: throw OmniError("omni: test spec has no set: $label")

        for ((index, entry) in testset.withIndex()) {
            if (!entry.ismap) {
                throw OmniError("omni: $label[$index]: entry is not a map")
            }

            // An entry with no `out` expects a null (or absent) result.
            if (flags.nulls && entry.get("out").isnone) {
                entry.set("out", Json.str(NULLMARK))
            }

            var entrysubject = usesubject
            var entryclient = client

            val clientname = entry.get("client").asstr
            if (null != clientname) {
                val found = clients[clientname]
                    ?: throw OmniError("omni: unknown client: $clientname", entry)
                entryclient = found
                val clientsubject = found.subject?.invoke(name)
                if (null != clientsubject) {
                    entrysubject = clientsubject
                }
            }

            val args = resolveargs(entry, entryclient)

            val res: Json
            try {
                res = entrysubject(args)
            } catch (omnierr: OmniError) {
                throw omnierr
            } catch (err: Throwable) {
                handleerror(label, index, entry, err)
                continue
            }

            val fixed = fixjson(res, flags.nulls)
            entry.set("res", fixed)

            checkresult(label, index, entry, args, fixed)
        }
    }

    // Build the argument list: `ctx`, `args`, or `in`.
    private fun resolveargs(entry: Json, entryclient: Provider): List<Json> {
        val hasctx = entry.has("ctx")
        val hasargs = entry.has("args")

        val args: MutableList<Json> = when {
            hasctx -> mutableListOf(entry.get("ctx"))
            hasargs -> entry.get("args").aslist ?: mutableListOf(entry.get("args"))
            else -> mutableListOf(clone(entry.get("in")))
        }

        if ((hasctx || hasargs) && args.isNotEmpty() && args[0].ismap) {
            var first = clone(args[0])
            val contextify = client.contextify
            if (null != contextify) {
                first = contextify(first)
            }
            args[0] = first
            entry.set("ctx", first)
        }

        return args
    }

    private fun checkresult(label: String, index: Int, entry: Json, args: List<Json>, res: Json) {
        var matched = false

        val entryerr = entry.get("err")
        if (!entryerr.isnone) {
            throw fail(
                label, index, entry, "expected error did not occur",
                stringify(entryerr), stringify(res),
            )
        }

        val check = entry.get("match")
        if (!check.isnone) {
            val base = Json.map(
                "in" to entry.get("in"),
                "args" to Json.JList(args.toMutableList()),
                "out" to entry.get("res"),
                "ctx" to entry.get("ctx"),
            )
            matchcheck(label, index, entry, check, base)
            matched = true
        }

        val out = entry.get("out")

        if (deepequal(res, out)) {
            return
        }

        // NOTE: a match with no explicit out is a complete check on its own.
        if (matched && (out.isnone || NULLMARK == out.asstr)) {
            return
        }

        throw fail(label, index, entry, "result mismatch", stringify(out), stringify(res))
    }

    private fun handleerror(label: String, index: Int, entry: Json, err: Throwable) {
        val entryerr = entry.get("err")

        if (!entryerr.isnone) {
            val istrue = entryerr is Json.Bool && entryerr.value

            if (istrue || matchval(entryerr, Json.str(errmessage(err)))) {
                val check = entry.get("match")
                if (!check.isnone) {
                    val base = Json.map(
                        "in" to entry.get("in"),
                        "out" to entry.get("res"),
                        "ctx" to entry.get("ctx"),
                        "err" to errify(err),
                    )
                    matchcheck(label, index, entry, check, base)
                }
                return
            }

            throw fail(label, index, entry, "error mismatch", stringify(entryerr), errmessage(err))
        }

        throw fail(label, index, entry, "unexpected error", null, errmessage(err))
    }

    // Check that every leaf of `check` is present, and matches, in `base`.
    private fun matchcheck(
        label: String,
        index: Int,
        entry: Json,
        check: Json,
        base: Json,
        path: List<String> = listOf(),
    ) {
        val where = if (path.isEmpty()) "<root>" else pathify(path)

        if (check is Json.JList) {
            for ((at, subcheck) in check.value.withIndex()) {
                matchcheck(label, index, entry, subcheck, base, path + "$at")
            }
            return
        }

        if (check is Json.JMap) {
            for ((key, subcheck) in check.value) {
                matchcheck(label, index, entry, subcheck, base, path + key)
            }
            return
        }

        val baseval = getpath(base, path)

        if (deepequal(check, baseval)) {
            return
        }

        // Explicitly absent: satisfied only by a genuinely missing key, never
        // by a present null (the distinction the sentinels exist to keep).
        if (UNDEFMARK == check.asstr) {
            if (baseval.isabsent) {
                return
            }
            throw fail(
                label, index, entry, "expected absent at $where",
                "absent", stringify(baseval),
            )
        }

        // Explicitly null: satisfied only by a present null.
        if (NULLMARK == check.asstr) {
            if (baseval.isnull || NULLMARK == baseval.asstr) {
                return
            }
            throw fail(
                label, index, entry, "expected null at $where",
                "null", stringify(baseval),
            )
        }

        // Explicitly present: any present value, including null.
        if (EXISTSMARK == check.asstr) {
            if (!baseval.isabsent) {
                return
            }
            throw fail(
                label, index, entry, "expected present at $where",
                "present", "absent",
            )
        }

        // A concrete expectation never matches a missing key - a match leaf
        // against an absent value must fail, not substring-match "undefined".
        if (baseval.isabsent) {
            throw fail(
                label, index, entry, "match failed at $where",
                stringify(check), "absent",
            )
        }

        if (matchval(check, baseval)) {
            return
        }

        throw fail(
            label, index, entry, "match failed at $where",
            stringify(check), stringify(baseval),
        )
    }

    // The label of one entry, for failure messages.
    private fun entryref(label: String, index: Int, entry: Json): String {
        val id = entry.get("id")
        val idpart = if (id.isabsent) "" else " (${stringify(id)})"
        return "$label[$index]$idpart"
    }

    private fun fail(
        label: String,
        index: Int,
        entry: Json,
        reason: String,
        expected: String? = null,
        actual: String? = null,
    ): OmniError {
        val msg = StringBuilder("omni: ${entryref(label, index, entry)}: $reason")

        if (null != expected) {
            msg.append("\n  expected: $expected")
        }
        if (null != actual) {
            msg.append("\n  actual:   $actual")
        }

        val summary = LinkedHashMap<String, Json>()
        entry.asmap?.forEach { (key, value) ->
            if ("res" != key && "thrown" != key && "ctx" != key) {
                summary[key] = value
            }
        }
        msg.append("\n  entry:    ${stringify(Json.JMap(summary))}")

        return OmniError(msg.toString(), entry)
    }
}

/** A loaded spec plus its provider. */
class Runner(private val alltests: Json, private val provider: Provider) {
    /** Resolve one named section of the spec. */
    fun runner(name: String, store: Json = Json.Absent): RunPack {
        val spec = resolvespec(name, alltests)
        val clients = mutableMapOf<String, Provider>()

        val defclient = spec.get("DEF").get("client").asmap
        val clientmaker = provider.client

        // A spec may define clients that a given test run never references.
        if (null != defclient && null != clientmaker) {
            for ((clientname, cdef) in defclient) {
                var copts = cdef.get("test").get("options")
                if (copts.isabsent) {
                    copts = Json.map()
                }
                val inject = provider.inject
                if (null != inject && store.ismap) {
                    copts = inject(copts, store)
                }
                clients[clientname] = clientmaker(copts)
            }
        }

        val subject = if (name.isEmpty()) null else provider.subject?.invoke(name)

        return RunPack(spec, subject, provider, clients, name)
    }
}

/** Make a runner for a spec file path and a provider. */
fun makeRunner(path: String, provider: Provider = Provider()): Runner =
    Runner(loadspec(path), provider)

/** Make a runner for an in-memory spec and a provider. */
fun makeRunner(spec: Json, provider: Provider = Provider()): Runner = Runner(spec, provider)
