// The omni JSON value model, with a small in-tree parser.
//
// The omni runner must be able to test *any* library, and must add no
// third-party dependencies, so it carries its own JSON support rather than
// borrowing kotlinx.serialization, Gson or the system under test.

package voxgig.omni

/**
 * A JSON value. `Absent` is the marker for "no value at all", as distinct
 * from `Null`.
 */
sealed class Json {
    object Absent : Json()

    object Null : Json()

    data class Bool(val value: Boolean) : Json()

    data class Num(val value: Double) : Json()

    data class Str(val value: String) : Json()

    data class JList(val value: MutableList<Json>) : Json()

    data class JMap(val value: LinkedHashMap<String, Json>) : Json()

    val ismap: Boolean get() = this is JMap
    val islist: Boolean get() = this is JList
    val isnode: Boolean get() = ismap || islist
    val isabsent: Boolean get() = this is Absent
    val isnull: Boolean get() = this is Null
    val isnone: Boolean get() = isabsent || isnull
    val isnum: Boolean get() = this is Num
    val isstr: Boolean get() = this is Str
    val isbool: Boolean get() = this is Bool

    val asnum: Double? get() = (this as? Num)?.value
    val asstr: String? get() = (this as? Str)?.value
    val aslist: MutableList<Json>? get() = (this as? JList)?.value
    val asmap: LinkedHashMap<String, Json>? get() = (this as? JMap)?.value

    /** Read a map entry. Returns Absent when missing. */
    fun get(key: String): Json = (this as? JMap)?.value?.get(key) ?: Absent

    /** Is a map key present at all (even with a null value)? */
    fun has(key: String): Boolean = (this as? JMap)?.value?.containsKey(key) ?: false

    /** Set a map entry (no-op for non-maps). */
    fun set(key: String, entry: Json) {
        (this as? JMap)?.value?.put(key, entry)
    }

    fun push(entry: Json) {
        (this as? JList)?.value?.add(entry)
    }

    companion object {
        fun list(vararg entries: Json): Json = JList(entries.toMutableList())

        fun map(vararg entries: Pair<String, Json>): Json {
            val out = LinkedHashMap<String, Json>()
            for ((key, value) in entries) {
                out[key] = value
            }
            return JMap(out)
        }

        fun num(value: Number): Json = Num(value.toDouble())

        fun str(value: String): Json = Str(value)

        /** Parse JSON text into the omni value model. */
        fun parse(text: String): Json {
            val parser = Parser(text)
            parser.skipws()
            val val_ = parser.value()
            parser.skipws()
            if (!parser.done()) {
                throw OmniError("omni: trailing JSON content at ${parser.pos}")
            }
            return val_
        }
    }

    private class Parser(val text: String) {
        var pos = 0

        fun done(): Boolean = pos >= text.length

        fun skipws() {
            while (pos < text.length) {
                val ch = text[pos]
                if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
                    pos++
                } else {
                    break
                }
            }
        }

        fun value(): Json {
            if (done()) {
                throw OmniError("omni: unexpected end of JSON")
            }

            return when (text[pos]) {
                '{' -> map()
                '[' -> list()
                '"' -> Str(str())
                't' -> { word("true"); Bool(true) }
                'f' -> { word("false"); Bool(false) }
                'n' -> { word("null"); Null }
                else -> num()
            }
        }

        fun word(want: String) {
            if (!text.startsWith(want, pos)) {
                throw OmniError("omni: bad JSON literal at $pos")
            }
            pos += want.length
        }

        fun map(): Json {
            val out = LinkedHashMap<String, Json>()
            pos++ // {

            skipws()
            if (!done() && '}' == text[pos]) {
                pos++
                return JMap(out)
            }

            while (true) {
                skipws()
                val key = str()
                skipws()

                if (done() || ':' != text[pos]) {
                    throw OmniError("omni: expected ':' at $pos")
                }
                pos++

                skipws()
                out[key] = value()
                skipws()

                if (done()) {
                    throw OmniError("omni: unterminated JSON object")
                }
                if (',' == text[pos]) {
                    pos++
                    continue
                }
                if ('}' == text[pos]) {
                    pos++
                    return JMap(out)
                }
                throw OmniError("omni: expected ',' or '}' at $pos")
            }
        }

        fun list(): Json {
            val out = mutableListOf<Json>()
            pos++ // [

            skipws()
            if (!done() && ']' == text[pos]) {
                pos++
                return JList(out)
            }

            while (true) {
                skipws()
                out.add(value())
                skipws()

                if (done()) {
                    throw OmniError("omni: unterminated JSON array")
                }
                if (',' == text[pos]) {
                    pos++
                    continue
                }
                if (']' == text[pos]) {
                    pos++
                    return JList(out)
                }
                throw OmniError("omni: expected ',' or ']' at $pos")
            }
        }

        fun str(): String {
            if (done() || '"' != text[pos]) {
                throw OmniError("omni: expected string at $pos")
            }
            pos++

            val out = StringBuilder()

            while (pos < text.length) {
                val ch = text[pos++]

                if ('"' == ch) {
                    return out.toString()
                }

                if ('\\' != ch) {
                    out.append(ch)
                    continue
                }

                if (done()) {
                    break
                }

                when (val escape = text[pos++]) {
                    '"' -> out.append('"')
                    '\\' -> out.append('\\')
                    '/' -> out.append('/')
                    'b' -> out.append('\b')
                    'f' -> out.append('')
                    'n' -> out.append('\n')
                    'r' -> out.append('\r')
                    't' -> out.append('\t')
                    'u' -> {
                        if (pos + 4 > text.length) {
                            throw OmniError("omni: bad JSON unicode escape")
                        }
                        out.append(text.substring(pos, pos + 4).toInt(16).toChar())
                        pos += 4
                    }
                    else -> throw OmniError("omni: bad JSON escape [$escape] at $pos")
                }
            }

            throw OmniError("omni: unterminated JSON string")
        }

        fun num(): Json {
            val start = pos

            if (pos < text.length && ('-' == text[pos] || '+' == text[pos])) {
                pos++
            }

            while (pos < text.length) {
                val ch = text[pos]
                if (ch.isDigit() || '.' == ch || 'e' == ch || 'E' == ch || '-' == ch || '+' == ch) {
                    pos++
                } else {
                    break
                }
            }

            val span = text.substring(start, pos)
            return Num(span.toDoubleOrNull() ?: throw OmniError("omni: bad JSON number [$span] at $start"))
        }
    }
}
