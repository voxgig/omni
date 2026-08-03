// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

package voxgig.omni

import scala.collection.immutable.ListMap

val NULLMARK = "__NULL__"    // Value is JSON null.
val UNDEFMARK = "__UNDEF__"  // Value is not present.
val EXISTSMARK = "__EXISTS__" // Value exists (not undefined).

object Util:

  /** Deep copy a JSON value (the value model is immutable). */
  def clone(value: Json): Json = value

  /** Read a value by path. Returns Absent when any step is missing. */
  def getpath(value: Json, path: List[String]): Json = path match
    case Nil => value
    case part :: rest =>
      val next = value match
        case Json.JList(entries) =>
          part.toIntOption.filter(index => 0 <= index && index < entries.length) match
            case Some(index) => entries(index)
            case None        => Json.Absent
        case Json.JMap(entries) => entries.getOrElse(part, Json.Absent)
        case _                  => Json.Absent

      if next.isabsent then Json.Absent else getpath(next, rest)

  /** Depth-first walk: children first, then the containing node. */
  def walk(value: Json, apply: (Json, List[String]) => Json, path: List[String] = List()): Json =
    val next = value match
      case Json.JList(entries) =>
        Json.JList(entries.zipWithIndex.map { (entry, index) =>
          walk(entry, apply, path :+ index.toString)
        })
      case Json.JMap(entries) =>
        Json.JMap(ListMap.from(entries.map { (key, entry) => (key, walk(entry, apply, path :+ key)) }))
      case other => other

    apply(next, path)

  /** Deep structural equality: numbers by value, bools never numbers. */
  def deepequal(a: Json, b: Json): Boolean = (a, b) match
    case (Json.Absent, Json.Absent)     => true
    case (Json.Null, Json.Null)         => true
    case (Json.Bool(x), Json.Bool(y))   => x == y
    case (Json.Num(x), Json.Num(y))     => x == y || (x.isNaN && y.isNaN)
    case (Json.Str(x), Json.Str(y))     => x == y
    case (Json.JList(x), Json.JList(y)) =>
      x.length == y.length && x.zip(y).forall((xe, ye) => deepequal(xe, ye))
    case (Json.JMap(x), Json.JMap(y)) =>
      x.size == y.size && x.forall((key, entry) => y.get(key).exists(deepequal(entry, _)))
    case _ => false

  /** Render a number the same way in every port: 5.0 prints as 5. */
  def numstr(value: Double): String =
    if value.isNaN || value.isInfinite then "null"
    else if value == value.toLong.toDouble && math.abs(value) < 9007199254740992.0 then
      value.toLong.toString
    else value.toString

  /** Render a string as a JSON string literal. */
  def quote(value: String): String =
    val out = StringBuilder("\"")

    for ch <- value do
      ch match
        case '"'  => out.append("\\\"")
        case '\\' => out.append("\\\\")
        case '\n' => out.append("\\n")
        case '\r' => out.append("\\r")
        case '\t' => out.append("\\t")
        case _ =>
          if ch < 0x20 then out.append("\\u%04x".format(ch.toInt))
          else out.append(ch)

    out.append('"').toString

  /** Compact JSON text with map keys sorted, identical in every port. */
  def jsonstr(value: Json): String = value match
    case Json.Absent         => "undefined"
    case Json.Null           => "null"
    case Json.Bool(flag)     => if flag then "true" else "false"
    case Json.Num(entry)     => numstr(entry)
    case Json.Str(text)      => quote(text)
    case Json.JList(entries) => "[" + entries.map(jsonstr).mkString(",") + "]"
    case Json.JMap(entries) =>
      "{" + entries.keys.toList.sorted.map(key => quote(key) + ":" + jsonstr(entries(key)))
        .mkString(",") + "}"

  /** Strings verbatim, everything else as compact JSON. */
  def stringify(value: Json): String = value match
    case Json.Str(text) => text
    case other          => jsonstr(other)

  /** Render a path as a dotted string. */
  def pathify(path: List[String]): String = path.mkString(".")
