// Omni: the shared multi-language test runner (Scala port).
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

package voxgig.omni

import java.nio.file.{Files, Paths}
import java.util.regex.Pattern
import scala.collection.immutable.ListMap
import scala.util.control.NonFatal

import Util.*

/** The function under test. Arguments arrive as JSON values; failure is
  * reported by throwing.
  */
type Subject = List[Json] => Json

/** A test failure (or a malformed spec). Distinct from an exception thrown
  * by the subject under test, which is a candidate for an `err` expectation.
  */
class OmniError(val text: String, val entry: Json = Json.Absent) extends RuntimeException(text)

/** Run-time options for a set of test entries. */
case class Flags(nulls: Boolean = true, name: Option[String] = None)

object Flags:
  def nonull(): Flags = Flags(nulls = false)

/** The host of the system under test. Every hook is optional. */
case class Provider(
    subject: Option[String => Option[Subject]] = None,
    client: Option[Json => Provider] = None,
    contextify: Option[Json => Json] = None,
    inject: Option[(Json, Json) => Json] = None,
)

object Runner:

  /** Load a spec: a path to a JSON file. */
  def loadspec(path: String): Json =
    val file = Paths.get(path)
    if !Files.exists(file) then throw OmniError(s"omni: cannot read spec: $path")
    Json.parse(Files.readString(file))

  /** Find `primary.<name>`, then `<name>`, then the whole spec. */
  def resolvespec(name: String, alltests: Json): Json =
    if name.isEmpty then return alltests

    val primary = alltests.get("primary").get(name)
    if !primary.isabsent then return primary

    val section = alltests.get(name)
    if !section.isabsent then return section

    alltests

  /** Nulls (and absent values) become NULLMARK. Always a fresh copy. */
  def fixjson(value: Json, donull: Boolean): Json =
    if value.isnone then (if donull then Json.str(NULLMARK) else Json.Null)
    else
      value match
        case Json.JList(entries) => Json.JList(entries.map(fixjson(_, donull)))
        case Json.JMap(entries) =>
          Json.JMap(ListMap.from(entries.map((key, entry) => (key, fixjson(entry, donull)))))
        case other => other

  /** The JSON form of an error: always at least {name,message}. */
  def errify(err: Throwable): Json =
    Json.map("name" -> Json.str(err.getClass.getSimpleName), "message" -> Json.str(errmessage(err)))

  def errmessage(err: Throwable): String =
    Option(err.getMessage).getOrElse(err.getClass.getSimpleName)

  /** Match one leaf: /regex/ or case-insensitive substring for strings. */
  def matchval(check: Json, base: Json): Boolean =
    if deepequal(check, base) then return true

    val want = check.asstr match
      case Some(text) if UNDEFMARK == text || NULLMARK == text => Json.Null
      case _                                                   => check

    if want.isnone then
      return base.isnone || base.asstr.contains(NULLMARK)

    want.asstr match
      case Some(text) =>
        val basestr = stringify(base)

        if 2 < text.length && text.startsWith("/") && text.endsWith("/") then
          try Pattern.compile(text.substring(1, text.length - 1)).matcher(basestr).find()
          catch case NonFatal(_) => false
        else basestr.toLowerCase.contains(text.toLowerCase)

      case None => deepequal(want, base)

  /** Convert NULLMARK sentinels back into real nulls. */
  def nullmodifier(value: Json): Json = value.asstr match
    case Some(NULLMARK) => Json.Null
    case Some(text)     => Json.str(text.replace(NULLMARK, "null"))
    case None           => value

  /** Make a runner for a spec file path and a provider. */
  def makeRunner(path: String, provider: Provider): RunnerPack =
    RunnerPack(loadspec(path), provider)

  /** Make a runner for an in-memory spec and a provider. */
  def makeRunner(spec: Json, provider: Provider = Provider()): RunnerPack =
    RunnerPack(spec, provider)

/** A loaded spec plus its provider. */
class RunnerPack(alltests: Json, provider: Provider):

  /** Resolve one named section of the spec. */
  def runner(name: String, store: Json = Json.Absent): RunPack =
    val spec = Runner.resolvespec(name, alltests)
    var clients = Map.empty[String, Provider]

    val defclient = spec.get("DEF").get("client").asmap

    // A spec may define clients that a given test run never references.
    (defclient, provider.client) match
      case (Some(entries), Some(clientmaker)) =>
        for (clientname, cdef) <- entries do
          var copts = cdef.get("test").get("options")
          if copts.isabsent then copts = Json.map()
          provider.inject.foreach { inject =>
            if store.ismap then copts = inject(copts, store)
          }
          clients = clients.updated(clientname, clientmaker(copts))
      case _ => ()

    val subject = if name.isEmpty then None else provider.subject.flatMap(_(name))

    RunPack(spec, subject, provider, clients, name)

/** What a runner returns for one named spec section. */
class RunPack(
    val spec: Json,
    val subject: Option[Subject],
    val client: Provider,
    clients: Map[String, Provider],
    name: String,
):

  /** A named group of the resolved spec. */
  def set(setname: String): Json = spec.get(setname)

  /** Run one set of test entries. */
  def runset(testspec: Json, testsubject: Option[Subject] = None): Unit =
    runsetflags(testspec, Flags(), testsubject)

  /** Run one set of test entries with flags. */
  def runsetflags(testspec: Json, flags: Flags, testsubject: Option[Subject] = None): Unit =
    val label = flags.name.getOrElse(if name.isEmpty then "set" else name)

    val usesubject = testsubject.orElse(subject).getOrElse {
      throw OmniError(s"omni: no test subject for: $label")
    }

    val testspecmap = Runner.fixjson(testspec, flags.nulls)
    val testset = testspecmap.get("set").aslist.getOrElse {
      throw OmniError(s"omni: test spec has no set: $label")
    }

    for (rawentry, index) <- testset.zipWithIndex do
      if !rawentry.ismap then
        throw OmniError(s"omni: $label[$index]: entry is not a map")

      var entry = rawentry

      // An entry with no `out` expects a null (or absent) result.
      if flags.nulls && entry.get("out").isnone then
        entry = entry.set("out", Json.str(NULLMARK))

      var entrysubject = usesubject

      entry.get("client").asstr.foreach { clientname =>
        val found = clients.getOrElse(
          clientname,
          throw OmniError(s"omni: unknown client: $clientname", entry),
        )
        found.subject.flatMap(_(name)).foreach { clientsubject =>
          entrysubject = clientsubject
        }
      }

      val (args, withctx) = resolveargs(entry)
      entry = withctx

      try
        val res = Runner.fixjson(entrysubject(args), flags.nulls)
        entry = entry.set("res", res)
        checkresult(label, index, entry, args, res)
      catch
        case omnierr: OmniError => throw omnierr
        case NonFatal(err)      => handleerror(label, index, entry, err)

  // Build the argument list: `ctx`, `args`, or `in`.
  private def resolveargs(entry: Json): (List[Json], Json) =
    val hasctx = entry.has("ctx")
    val hasargs = entry.has("args")

    var args =
      if hasctx then List(entry.get("ctx"))
      else if hasargs then entry.get("args").aslist.getOrElse(List(entry.get("args")))
      else List(entry.get("in"))

    var out = entry

    if (hasctx || hasargs) && args.nonEmpty && args.head.ismap then
      var first = args.head
      client.contextify.foreach { contextify => first = contextify(first) }
      args = first :: args.tail
      out = out.set("ctx", first)

    (args, out)

  private def checkresult(
      label: String,
      index: Int,
      entry: Json,
      args: List[Json],
      res: Json,
  ): Unit =
    var matched = false

    val entryerr = entry.get("err")
    if !entryerr.isnone then
      throw fail(
        label, index, entry, "expected error did not occur",
        Some(stringify(entryerr)), Some(stringify(res)),
      )

    val check = entry.get("match")
    if !check.isnone then
      val base = Json.map(
        "in" -> entry.get("in"),
        "args" -> Json.JList(args),
        "out" -> entry.get("res"),
        "ctx" -> entry.get("ctx"),
      )
      matchcheck(label, index, entry, check, base)
      matched = true

    val out = entry.get("out")

    if deepequal(res, out) then return

    // NOTE: a match with no explicit out is a complete check on its own.
    if matched && (out.isnone || out.asstr.contains(NULLMARK)) then return

    throw fail(label, index, entry, "result mismatch", Some(stringify(out)), Some(stringify(res)))

  private def handleerror(label: String, index: Int, entry: Json, err: Throwable): Unit =
    val entryerr = entry.get("err")

    if !entryerr.isnone then
      val istrue = entryerr match
        case Json.Bool(true) => true
        case _               => false

      if istrue || Runner.matchval(entryerr, Json.str(Runner.errmessage(err))) then
        val check = entry.get("match")
        if !check.isnone then
          val base = Json.map(
            "in" -> entry.get("in"),
            "out" -> entry.get("res"),
            "ctx" -> entry.get("ctx"),
            "err" -> Runner.errify(err),
          )
          matchcheck(label, index, entry, check, base)
        return

      throw fail(
        label, index, entry, "error mismatch",
        Some(stringify(entryerr)), Some(Runner.errmessage(err)),
      )

    throw fail(label, index, entry, "unexpected error", None, Some(Runner.errmessage(err)))

  // Check that every leaf of `check` is present, and matches, in `base`.
  private def matchcheck(
      label: String,
      index: Int,
      entry: Json,
      check: Json,
      base: Json,
      path: List[String] = List(),
  ): Unit =
    check match
      case Json.JList(entries) =>
        for (subcheck, at) <- entries.zipWithIndex do
          matchcheck(label, index, entry, subcheck, base, path :+ at.toString)

      case Json.JMap(entries) =>
        for (key, subcheck) <- entries do
          matchcheck(label, index, entry, subcheck, base, path :+ key)

      case leaf =>
        val baseval = getpath(base, path)

        val ok =
          deepequal(leaf, baseval)
            || (leaf.asstr.contains(UNDEFMARK) && baseval.isabsent)
            || (leaf.asstr.contains(EXISTSMARK) && !baseval.isnone)
            || Runner.matchval(leaf, baseval)

        if !ok then
          val where = if path.isEmpty then "<root>" else pathify(path)
          throw fail(
            label, index, entry, s"match failed at $where",
            Some(stringify(leaf)), Some(stringify(baseval)),
          )

  // The label of one entry, for failure messages.
  private def entryref(label: String, index: Int, entry: Json): String =
    val id = entry.get("id")
    val idpart = if id.isabsent then "" else s" (${stringify(id)})"
    s"$label[$index]$idpart"

  private def fail(
      label: String,
      index: Int,
      entry: Json,
      reason: String,
      expected: Option[String] = None,
      actual: Option[String] = None,
  ): OmniError =
    val msg = StringBuilder(s"omni: ${entryref(label, index, entry)}: $reason")

    expected.foreach(text => msg.append(s"\n  expected: $text"))
    actual.foreach(text => msg.append(s"\n  actual:   $text"))

    val summary = entry.asmap
      .map(entries => entries.filterNot((key, _) => Set("res", "thrown", "ctx").contains(key)))
      .getOrElse(ListMap.empty[String, Json])

    msg.append(s"\n  entry:    ${stringify(Json.JMap(summary))}")

    OmniError(msg.toString, entry)
