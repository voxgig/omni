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

// The newest spec format version this runner understands. A spec with no
// OMNI block is version 0: the original, lenient format, frozen forever.
// Version 1 turns on strict entry validation (see checkentry).
val SPECVERSION: Int = 1

// Capability strings this runner supports beyond the version baseline. A
// spec's OMNI.requires list is checked against this: an unknown capability
// refuses the spec loudly at load time, instead of a lagging port silently
// mis-running it. (Empty today; future format features mint a string here.)
val CAPABILITIES: List[String] = List.empty[String]

// The complete set of fields an entry may carry. Under version 1 anything
// else is an error: an unrecognised key is almost always a typo'd
// assertion, and a typo'd assertion is a test that silently stopped
// testing.
private val ENTRYFIELDS =
  List("in", "args", "ctx", "out", "err", "match", "client", "id", "doc")

object Runner:

  /** Load a spec: a path to a JSON file. */
  def loadspec(path: String): Json =
    val file = Paths.get(path)
    if !Files.exists(file) then throw OmniError(s"omni: cannot read spec: $path")
    Json.parse(Files.readString(file))

  // Read the spec's format version from its optional top-level OMNI block,
  // and refuse a spec this runner cannot faithfully run: a version newer
  // than SPECVERSION, or a required capability not in CAPABILITIES. A
  // present-but-null OMNI block is malformed - only a genuinely absent key
  // means legacy version 0.
  def resolveversion(alltests: Json): Int =
    if !alltests.has("OMNI") then return 0

    val meta = alltests.get("OMNI")
    val version = meta.get("version").asnum

    if !meta.ismap || version.isEmpty || version.get != math.floor(version.get) then
      throw OmniError("omni: malformed OMNI version block")

    val versionval = version.get

    if versionval < 0 || SPECVERSION < versionval then
      throw OmniError(s"omni: unsupported spec version: ${numstr(versionval)}")

    if meta.has("requires") then
      val requires = meta.get("requires").aslist.getOrElse {
        throw OmniError("omni: malformed OMNI requires list")
      }
      for cap <- requires do
        cap.asstr match
          case Some(text) if CAPABILITIES.contains(text) => ()
          case _ =>
            throw OmniError(s"omni: spec requires unsupported capability: ${stringify(cap)}")

    versionval.toInt

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

    check.asstr match
      case Some(text) =>
        // An empty want would substring-match anything.
        if text.isEmpty then return false

        val basestr = stringify(base)

        if 2 < text.length && text.startsWith("/") && text.endsWith("/") then
          try Pattern.compile(text.substring(1, text.length - 1)).matcher(basestr).find()
          catch case NonFatal(_) => false
        else basestr.toLowerCase.contains(text.toLowerCase)

      case None => deepequal(check, base)

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

  // Resolved once, at construction (i.e. inside makeRunner) - fail fast on
  // a spec version this runner cannot faithfully run, before any set runs.
  private val specversion: Int = Runner.resolveversion(alltests)

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

    RunPack(spec, subject, provider, clients, name, specversion)

/** What a runner returns for one named spec section. */
class RunPack(
    val spec: Json,
    val subject: Option[Subject],
    val client: Provider,
    clients: Map[String, Provider],
    name: String,
    specversion: Int,
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

    // Validated against the AUTHORED group (testspec, not testspecmap) -
    // null-normalisation above would otherwise hide an authored null from
    // checkentry. A malformed spec fails here, before any subject runs.
    if 1 <= specversion then
      checkset(label, testspec, testset)

    for (rawentry, index) <- testset.zipWithIndex do
      if !rawentry.ismap then
        throw OmniError(s"omni: $label[$index]: entry is not a map")

      var entry = rawentry

      // An entry with no `out` expects a null (or absent) result.
      if flags.nulls && entry.get("out").isnone then
        entry = entry.set("out", Json.str(NULLMARK))

      var entrysubject = usesubject
      var entryclient = client

      entry.get("client").asstr.foreach { clientname =>
        val found = clients.getOrElse(
          clientname,
          throw OmniError(s"omni: unknown client: $clientname", entry),
        )
        entryclient = found
        found.subject.flatMap(_(name)).foreach { clientsubject =>
          entrysubject = clientsubject
        }
      }

      val (args, withctx) = resolveargs(entry, entryclient)
      entry = withctx

      try
        val res = Runner.fixjson(entrysubject(args), flags.nulls)
        entry = entry.set("res", res)
        checkresult(label, index, entry, args, res)
      catch
        case omnierr: OmniError => throw omnierr
        case NonFatal(err)      => handleerror(label, index, entry, err)

  // Build the argument list: `ctx`, `args`, or `in`. `entryclient` is the
  // provider resolved for this entry (the root provider, or its own
  // `client:` override) - always set by the time this runs.
  private def resolveargs(entry: Json, entryclient: Provider): (List[Json], Json) =
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

      // The resolved client is a live Provider (closures over the system
      // under test), and this port's Json is a closed value model with no
      // host-object variant to hold one - so canonical's
      // `first.client = testpack.client` becomes presence, not identity:
      // enough for a subject to prove the runner attached a client at
      // all. `entryclient` is always set by the caller, so the marker is
      // unconditional once we get here.
      if first.ismap then first = first.set("client", Json.Bool(true))

      args = first :: args.tail
      out = out.set("ctx", first)

    (args, out)

  // Validate a version-1 group up front, against the AUTHORED entries -
  // null-normalisation would otherwise rewrite an authored null (e.g.
  // id: null) into a sentinel string and hide it from validation. A
  // malformed spec is a spec error, not a test result, so it fails before
  // any subject runs.
  private def checkset(label: String, testspec: Json, normalset: List[Json]): Unit =
    val origset = testspec.get("set").aslist.getOrElse(normalset)

    val markedempty = testspec.get("empty") match
      case Json.Bool(true) => true
      case _               => false

    if origset.isEmpty && !markedempty then
      throw OmniError(s"omni: empty test set: $label")

    for (entry, index) <- origset.zipWithIndex do
      checkentry(label, index, entry)

  // Strict entry validation, applied when the spec declares version 1 or
  // later. The lenient format converts each of these mistakes into a
  // silent pass or a dead field; here they fail with the entry named.
  private def checkentry(label: String, index: Int, entry: Json): Unit =
    if !entry.ismap then throw fail(label, index, entry, "entry is not a map")

    for key <- entry.asmap.get.keys do
      if !ENTRYFIELDS.contains(key) then
        throw fail(label, index, entry, s"unknown entry field: $key")

    val argsources = List("in", "args", "ctx").count(entry.has)
    if 1 < argsources then
      throw fail(label, index, entry, "entry has more than one of in, args, ctx")

    if !entry.get("err").isnone && entry.has("out") then
      throw fail(label, index, entry, "entry has both err and out")

    if entry.has("id") && entry.get("id").asstr.isEmpty then
      throw fail(label, index, entry, "entry id is not a string")

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
    val where = if path.isEmpty then "<root>" else pathify(path)

    check match
      case Json.JList(entries) =>
        for (subcheck, at) <- entries.zipWithIndex do
          matchcheck(label, index, entry, subcheck, base, path :+ at.toString)

      case Json.JMap(entries) =>
        for (key, subcheck) <- entries do
          matchcheck(label, index, entry, subcheck, base, path :+ key)

      case leaf =>
        val baseval = getpath(base, path)

        if deepequal(leaf, baseval) then ()

        // Explicitly absent: satisfied only by a genuinely missing key,
        // never by a present null (the distinction the sentinels exist to
        // keep).
        else if leaf.asstr.contains(UNDEFMARK) then
          if !baseval.isabsent then
            throw fail(
              label, index, entry, s"expected absent at $where",
              Some("absent"), Some(stringify(baseval)),
            )

        // Explicitly null: satisfied only by a present null.
        else if leaf.asstr.contains(NULLMARK) then
          if !(baseval.isnull || baseval.asstr.contains(NULLMARK)) then
            throw fail(
              label, index, entry, s"expected null at $where",
              Some("null"), Some(stringify(baseval)),
            )

        // Explicitly present: any present value, including null.
        else if leaf.asstr.contains(EXISTSMARK) then
          if baseval.isabsent then
            throw fail(
              label, index, entry, s"expected present at $where",
              Some("present"), Some("absent"),
            )

        // A concrete expectation never matches a missing key - a match leaf
        // against an absent value must fail, not substring-match
        // "undefined".
        else if baseval.isabsent then
          throw fail(
            label, index, entry, s"match failed at $where",
            Some(stringify(leaf)), Some("absent"),
          )

        else if !Runner.matchval(leaf, baseval) then
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
