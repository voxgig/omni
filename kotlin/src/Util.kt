// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

package voxgig.omni

import kotlin.math.abs
import kotlin.math.truncate

const val NULLMARK = "__NULL__" // Value is JSON null.
const val UNDEFMARK = "__UNDEF__" // Value is not present.
const val EXISTSMARK = "__EXISTS__" // Value exists (not undefined).

/** Deep copy a JSON value. */
fun clone(val_: Json): Json = when (val_) {
    is Json.JList -> Json.JList(val_.value.map { clone(it) }.toMutableList())
    is Json.JMap -> {
        val out = LinkedHashMap<String, Json>()
        for ((key, entry) in val_.value) {
            out[key] = clone(entry)
        }
        Json.JMap(out)
    }
    else -> val_
}

/** Read a value by path. Returns Absent when any step is missing. */
fun getpath(val_: Json, path: List<String>): Json {
    var current = val_

    for (part in path) {
        current = when (current) {
            is Json.JList -> {
                val index = part.toIntOrNull()
                if (null == index || 0 > index || index >= current.value.size) {
                    return Json.Absent
                }
                current.value[index]
            }
            is Json.JMap -> current.value[part] ?: return Json.Absent
            else -> return Json.Absent
        }
    }

    return current
}

/** Depth-first walk: children first, then the containing node. */
fun walk(val_: Json, apply: (Json, List<String>) -> Json, path: List<String> = listOf()): Json {
    val next = when (val_) {
        is Json.JList -> Json.JList(
            val_.value.mapIndexed { index, entry -> walk(entry, apply, path + "$index") }.toMutableList()
        )
        is Json.JMap -> {
            val out = LinkedHashMap<String, Json>()
            for ((key, entry) in val_.value) {
                out[key] = walk(entry, apply, path + key)
            }
            Json.JMap(out)
        }
        else -> val_
    }

    return apply(next, path)
}

/** Deep structural equality: numbers by value, bools never numbers. */
fun deepequal(a: Json, b: Json): Boolean = when {
    a is Json.Absent && b is Json.Absent -> true
    a is Json.Null && b is Json.Null -> true
    a is Json.Bool && b is Json.Bool -> a.value == b.value
    a is Json.Num && b is Json.Num -> a.value == b.value || (a.value.isNaN() && b.value.isNaN())
    a is Json.Str && b is Json.Str -> a.value == b.value
    a is Json.JList && b is Json.JList ->
        a.value.size == b.value.size &&
            a.value.indices.all { deepequal(a.value[it], b.value[it]) }
    a is Json.JMap && b is Json.JMap ->
        a.value.size == b.value.size &&
            a.value.all { (key, entry) ->
                b.value.containsKey(key) && deepequal(entry, b.value[key]!!)
            }
    else -> false
}

/** Render a number the same way in every port: 5.0 prints as 5. */
fun numstr(val_: Double): String {
    if (val_.isNaN() || val_.isInfinite()) {
        return "null"
    }
    if (val_ == truncate(val_) && abs(val_) < 9007199254740992.0) {
        return val_.toLong().toString()
    }
    return val_.toString()
}

/** Render a string as a JSON string literal. */
fun quote(val_: String): String {
    val out = StringBuilder("\"")

    for (ch in val_) {
        when (ch) {
            '"' -> out.append("\\\"")
            '\\' -> out.append("\\\\")
            '\n' -> out.append("\\n")
            '\r' -> out.append("\\r")
            '\t' -> out.append("\\t")
            else ->
                if (0x20 > ch.code) {
                    out.append("\\u%04x".format(ch.code))
                } else {
                    out.append(ch)
                }
        }
    }

    return out.append('"').toString()
}

/** Compact JSON text with map keys sorted, identical in every port. */
fun jsonstr(val_: Json): String = when (val_) {
    is Json.Absent -> "undefined"
    is Json.Null -> "null"
    is Json.Bool -> if (val_.value) "true" else "false"
    is Json.Num -> numstr(val_.value)
    is Json.Str -> quote(val_.value)
    is Json.JList -> "[" + val_.value.joinToString(",") { jsonstr(it) } + "]"
    is Json.JMap ->
        "{" + val_.value.keys.sorted().joinToString(",") { quote(it) + ":" + jsonstr(val_.value[it]!!) } + "}"
}

/** Strings verbatim, everything else as compact JSON. */
fun stringify(val_: Json): String = (val_ as? Json.Str)?.value ?: jsonstr(val_)

/** Render a path as a dotted string. */
fun pathify(path: List<String>): String = path.joinToString(".")
