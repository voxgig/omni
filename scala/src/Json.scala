// The omni JSON value model, with a small in-tree parser.
//
// The omni runner must be able to test *any* library, and must add no
// third-party dependencies, so it carries its own JSON support rather than
// borrowing circe, upickle or the system under test.

package voxgig.omni

import scala.collection.immutable.ListMap

/** A JSON value. `Absent` is the marker for "no value at all", as distinct
  * from `Null`.
  */
enum Json:
  case Absent
  case Null
  case Bool(value: Boolean)
  case Num(value: Double)
  case Str(value: String)
  case JList(value: List[Json])
  case JMap(value: ListMap[String, Json])

  def ismap: Boolean = this match
    case JMap(_) => true
    case _       => false

  def islist: Boolean = this match
    case JList(_) => true
    case _        => false

  def isnode: Boolean = ismap || islist

  def isabsent: Boolean = this match
    case Absent => true
    case _      => false

  def isnull: Boolean = this match
    case Null => true
    case _    => false

  def isnone: Boolean = isabsent || isnull

  def isnum: Boolean = this match
    case Num(_) => true
    case _      => false

  def isstr: Boolean = this match
    case Str(_) => true
    case _      => false

  def asnum: Option[Double] = this match
    case Num(value) => Some(value)
    case _          => None

  def asstr: Option[String] = this match
    case Str(value) => Some(value)
    case _          => None

  def aslist: Option[List[Json]] = this match
    case JList(value) => Some(value)
    case _            => None

  def asmap: Option[ListMap[String, Json]] = this match
    case JMap(value) => Some(value)
    case _           => None

  /** Read a map entry. Returns Absent when missing. */
  def get(key: String): Json = this match
    case JMap(value) => value.getOrElse(key, Absent)
    case _           => Absent

  /** Is a map key present at all (even with a null value)? */
  def has(key: String): Boolean = this match
    case JMap(value) => value.contains(key)
    case _           => false

  /** A copy of this map with one entry set. */
  def set(key: String, entry: Json): Json = this match
    case JMap(value) => JMap(value.updated(key, entry))
    case other       => other

object Json:
  def map(entries: (String, Json)*): Json = JMap(ListMap.from(entries))

  def list(entries: Json*): Json = JList(entries.toList)

  def num(value: Double): Json = Num(value)

  def str(value: String): Json = Str(value)

  /** Parse JSON text into the omni value model. */
  def parse(text: String): Json =
    val parser = Parser(text)
    parser.skipws()
    val value = parser.value()
    parser.skipws()
    if !parser.done then throw OmniError(s"omni: trailing JSON content at ${parser.pos}")
    value

  private class Parser(val text: String):
    var pos: Int = 0

    def done: Boolean = pos >= text.length

    def skipws(): Unit =
      while !done && (text(pos) == ' ' || text(pos) == '\t' || text(pos) == '\n' || text(pos) == '\r')
      do pos += 1

    def value(): Json =
      if done then throw OmniError("omni: unexpected end of JSON")

      text(pos) match
        case '{' => mapval()
        case '[' => listval()
        case '"' => Json.Str(strval())
        case 't' => word("true"); Json.Bool(true)
        case 'f' => word("false"); Json.Bool(false)
        case 'n' => word("null"); Json.Null
        case _   => numval()

    def word(want: String): Unit =
      if !text.startsWith(want, pos) then throw OmniError(s"omni: bad JSON literal at $pos")
      pos += want.length

    def mapval(): Json =
      var out = ListMap.empty[String, Json]
      pos += 1 // {

      skipws()
      if !done && text(pos) == '}' then
        pos += 1
        return Json.JMap(out)

      var running = true
      while running do
        skipws()
        val key = strval()
        skipws()

        if done || text(pos) != ':' then throw OmniError(s"omni: expected ':' at $pos")
        pos += 1

        skipws()
        out = out.updated(key, value())
        skipws()

        if done then throw OmniError("omni: unterminated JSON object")
        if text(pos) == ',' then pos += 1
        else if text(pos) == '}' then
          pos += 1
          running = false
        else throw OmniError(s"omni: expected ',' or '}' at $pos")

      Json.JMap(out)

    def listval(): Json =
      val out = scala.collection.mutable.ListBuffer.empty[Json]
      pos += 1 // [

      skipws()
      if !done && text(pos) == ']' then
        pos += 1
        return Json.JList(out.toList)

      var running = true
      while running do
        skipws()
        out += value()
        skipws()

        if done then throw OmniError("omni: unterminated JSON array")
        if text(pos) == ',' then pos += 1
        else if text(pos) == ']' then
          pos += 1
          running = false
        else throw OmniError(s"omni: expected ',' or ']' at $pos")

      Json.JList(out.toList)

    def strval(): String =
      if done || text(pos) != '"' then throw OmniError(s"omni: expected string at $pos")
      pos += 1

      val out = StringBuilder()

      while !done do
        val ch = text(pos)
        pos += 1

        if ch == '"' then return out.toString

        if ch != '\\' then out.append(ch)
        else
          if done then throw OmniError("omni: unterminated JSON string")
          val escape = text(pos)
          pos += 1
          escape match
            case '"'  => out.append('"')
            case '\\' => out.append('\\')
            case '/'  => out.append('/')
            case 'b'  => out.append('\b')
            case 'f'  => out.append('\f')
            case 'n'  => out.append('\n')
            case 'r'  => out.append('\r')
            case 't'  => out.append('\t')
            case 'u' =>
              if pos + 4 > text.length then throw OmniError("omni: bad JSON unicode escape")
              out.append(Integer.parseInt(text.substring(pos, pos + 4), 16).toChar)
              pos += 4
            case other => throw OmniError(s"omni: bad JSON escape [$other] at $pos")

      throw OmniError("omni: unterminated JSON string")

    def numval(): Json =
      val start = pos

      if !done && (text(pos) == '-' || text(pos) == '+') then pos += 1

      while !done && (text(pos).isDigit || text(pos) == '.' || text(pos) == 'e' ||
          text(pos) == 'E' || text(pos) == '-' || text(pos) == '+')
      do pos += 1

      val span = text.substring(start, pos)
      span.toDoubleOption match
        case Some(value) => Json.Num(value)
        case None        => throw OmniError(s"omni: bad JSON number [$span] at $start")
