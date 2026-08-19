/* Omni: the shared multi-language test runner (C port).
 *
 * Port of the canonical TypeScript implementation
 * (typescript/src/Runner.ts). Behaviour must match, case for case.
 */

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "omni.h"

struct omni_runner {
  omni_pool *pool;
  omni_json *alltests;
  omni_provider *provider;
  int specversion;
};

struct omni_runpack {
  omni_pool *pool;
  omni_json *spec;
  char *name;
  omni_provider *provider;
  omni_subject *subject;
  int specversion;

  char **clientnames;
  omni_provider **clients;
  size_t nclients;
};

omni_flags omni_flags_default(void) {
  omni_flags flags;
  flags.null = 1;
  flags.name = NULL;
  return flags;
}

omni_flags omni_flags_nonull(void) {
  omni_flags flags;
  flags.null = 0;
  flags.name = NULL;
  return flags;
}

/* ---- message building ---------------------------------------------- */

static char *omni_join(omni_pool *pool, const char *a, const char *b, const char *c,
                       const char *d) {
  size_t len = 1;
  char *out;

  len += NULL == a ? 0 : strlen(a);
  len += NULL == b ? 0 : strlen(b);
  len += NULL == c ? 0 : strlen(c);
  len += NULL == d ? 0 : strlen(d);

  out = (char *)omni_pool_alloc(pool, len);
  if (NULL == out) {
    return NULL;
  }
  out[0] = '\0';

  if (NULL != a) {
    strcat(out, a);
  }
  if (NULL != b) {
    strcat(out, b);
  }
  if (NULL != c) {
    strcat(out, c);
  }
  if (NULL != d) {
    strcat(out, d);
  }

  return out;
}

/* The spec-defined part of an entry (drop runner bookkeeping). */
static omni_json *omni_entrysummary(omni_pool *pool, const omni_json *entry) {
  omni_json *out;
  size_t index;

  if (!omni_ismap(entry)) {
    return omni_clone(pool, entry);
  }

  out = omni_map(pool);
  for (index = 0; index < entry->maplen; index++) {
    const char *key = entry->keys[index];
    if (0 != strcmp(key, "res") && 0 != strcmp(key, "thrown") && 0 != strcmp(key, "ctx")) {
      omni_map_set(out, key, omni_clone(pool, entry->vals[index]));
    }
  }

  return out;
}

/* The label of one entry, for failure messages. */
static char *omni_entryref(omni_pool *pool, omni_flags flags, size_t index,
                           const omni_json *entry) {
  char head[64];
  const omni_json *id = omni_map_get(entry, "id");
  const char *label = NULL == flags.name ? "set" : flags.name;

  snprintf(head, sizeof(head), "[%lu]", (unsigned long)index);

  if (omni_isabsent(id)) {
    return omni_join(pool, label, head, NULL, NULL);
  }

  return omni_join(pool, label, head, " (", omni_join(pool, omni_stringify(pool, id), ")", NULL, NULL));
}

static char *omni_fail(omni_pool *pool, omni_flags flags, size_t index, const omni_json *entry,
                       const char *reason, const char *expected, const char *actual) {
  char *msg = omni_join(pool, "omni: ", omni_entryref(pool, flags, index, entry), ": ", reason);

  if (NULL != expected) {
    msg = omni_join(pool, msg, "\n  expected: ", expected, NULL);
  }
  if (NULL != actual) {
    msg = omni_join(pool, msg, "\n  actual:   ", actual, NULL);
  }

  msg = omni_join(pool, msg, "\n  entry:    ",
                  omni_stringify(pool, omni_entrysummary(pool, entry)), NULL);

  return msg;
}

/* ---- format version (DOCS.md 2.7) ----------------------------------- */

const char *const OMNI_CAPABILITIES[] = {NULL};

static int omni_capability_known(const char *cap) {
  size_t index;
  for (index = 0; NULL != OMNI_CAPABILITIES[index]; index++) {
    if (0 == strcmp(OMNI_CAPABILITIES[index], cap)) {
      return 1;
    }
  }
  return 0;
}

/* Read the spec's format version from its optional top-level OMNI block,
 * and refuse a spec this runner cannot faithfully run: a version newer
 * than OMNI_SPECVERSION, or a required capability not in
 * OMNI_CAPABILITIES. Returns the version (0 with no OMNI block) on
 * success; returns -1 and sets *errout on failure. */
static int omni_resolveversion(omni_pool *pool, const omni_json *alltests, char **errout) {
  omni_json *meta = omni_map_get(alltests, "OMNI");
  omni_json *versionval;
  omni_json *requires;
  double rawversion;
  size_t index;

  if (omni_isabsent(meta)) {
    return 0;
  }

  if (!omni_ismap(meta)) {
    *errout = omni_pool_strdup(pool, "omni: malformed OMNI version block");
    return -1;
  }

  versionval = omni_map_get(meta, "version");
  if (!omni_isnum(versionval)) {
    *errout = omni_pool_strdup(pool, "omni: malformed OMNI version block");
    return -1;
  }

  rawversion = omni_numval(versionval);
  if (rawversion != floor(rawversion)) {
    *errout = omni_pool_strdup(pool, "omni: malformed OMNI version block");
    return -1;
  }

  if (0 > rawversion || OMNI_SPECVERSION < rawversion) {
    *errout = omni_join(pool, "omni: unsupported spec version: ", omni_numstr(pool, rawversion),
                        NULL, NULL);
    return -1;
  }

  requires = omni_map_get(meta, "requires");
  if (!omni_isabsent(requires)) {
    if (!omni_islist(requires)) {
      *errout = omni_pool_strdup(pool, "omni: malformed OMNI requires list");
      return -1;
    }

    for (index = 0; index < requires->listlen; index++) {
      omni_json *cap = requires->list[index];
      const char *capstr = omni_strval(cap);

      if (NULL == capstr || !omni_capability_known(capstr)) {
        *errout = omni_join(pool, "omni: spec requires unsupported capability: ",
                            omni_stringify(pool, cap), NULL, NULL);
        return -1;
      }
    }
  }

  return (int)rawversion;
}

/* The complete set of fields an entry may carry. Under version 1 anything
 * else is an error: an unrecognised key is almost always a typo'd
 * assertion, and a typo'd assertion is a test that silently stopped
 * testing. */
static const char *const omni_entryfields[] = {
    "in", "args", "ctx", "out", "err", "match", "client", "id", "doc", NULL};

static int omni_entryfield_known(const char *key) {
  size_t index;
  for (index = 0; NULL != omni_entryfields[index]; index++) {
    if (0 == strcmp(omni_entryfields[index], key)) {
      return 1;
    }
  }
  return 0;
}

/* Strict entry validation, applied when the spec declares version 1 or
 * later. The lenient format converts each of these mistakes into a
 * silent pass or a dead field; here they fail with the entry named. */
static int omni_checkentry(omni_pool *pool, omni_flags flags, size_t index, const omni_json *entry,
                           char **errout) {
  size_t at;
  int argsources = 0;
  omni_json *entryerr;
  omni_json *entryid;

  if (!omni_ismap(entry)) {
    *errout = omni_fail(pool, flags, index, entry, "entry is not a map", NULL, NULL);
    return 1;
  }

  for (at = 0; at < entry->maplen; at++) {
    if (!omni_entryfield_known(entry->keys[at])) {
      *errout = omni_fail(
          pool, flags, index, entry,
          omni_join(pool, "unknown entry field: ", entry->keys[at], NULL, NULL), NULL, NULL);
      return 1;
    }
  }

  if (omni_map_has(entry, "in")) {
    argsources++;
  }
  if (omni_map_has(entry, "args")) {
    argsources++;
  }
  if (omni_map_has(entry, "ctx")) {
    argsources++;
  }
  if (1 < argsources) {
    *errout = omni_fail(pool, flags, index, entry, "entry has more than one of in, args, ctx",
                        NULL, NULL);
    return 1;
  }

  entryerr = omni_map_get(entry, "err");
  if (!omni_isnone(entryerr) && omni_map_has(entry, "out")) {
    *errout = omni_fail(pool, flags, index, entry, "entry has both err and out", NULL, NULL);
    return 1;
  }

  /* Presence, not definedness: a genuinely absent id is fine (the runner
   * assigns none), but a present `id: null` is malformed - it must fail
   * here rather than being silently accepted as "no id". */
  entryid = omni_map_get(entry, "id");
  if (!omni_isabsent(entryid) && !omni_isstr(entryid)) {
    *errout = omni_fail(pool, flags, index, entry, "entry id is not a string", NULL, NULL);
    return 1;
  }

  return 0;
}

/* Validate a version-1 group up front, against the AUTHORED entries (the
 * un-normalised `testspec`, not the fixjson-normalised `normalset`) -
 * otherwise null-normalisation would rewrite an authored null (e.g.
 * id: null) into the NULLMARK sentinel string and hide it from
 * validation entirely. A malformed spec is a spec error, not a test
 * result, so it is checked in full before any subject runs. Absorbs the
 * empty-set check too, since that also belongs to the authored group. */
static int omni_checkset(omni_pool *pool, omni_flags flags, const omni_json *testspec,
                         omni_json *normalset, char **errout) {
  omni_json *origsetraw = omni_map_get(testspec, "set");
  omni_json *origset = omni_islist(origsetraw) ? origsetraw : normalset;
  omni_json *emptyflag = omni_map_get(testspec, "empty");
  int marked = !omni_isabsent(emptyflag) && OMNI_BOOL == emptyflag->type && emptyflag->boolval;
  size_t index;

  if (0 == origset->listlen && !marked) {
    *errout = omni_join(pool, "omni: empty test set: ", flags.name, NULL, NULL);
    return 1;
  }

  for (index = 0; index < origset->listlen; index++) {
    if (0 != omni_checkentry(pool, flags, index, origset->list[index], errout)) {
      return 1;
    }
  }

  return 0;
}

/* ---- spec resolution ----------------------------------------------- */

omni_json *omni_resolvespec(const char *name, omni_json *alltests) {
  omni_json *primary;
  omni_json *section;

  if (NULL == name || '\0' == name[0]) {
    return alltests;
  }

  primary = omni_map_get(alltests, "primary");
  if (omni_ismap(primary)) {
    section = omni_map_get(primary, name);
    if (!omni_isabsent(section)) {
      return section;
    }
  }

  section = omni_map_get(alltests, name);
  if (!omni_isabsent(section)) {
    return section;
  }

  return alltests;
}

static omni_subject *omni_resolvesubject(const char *name, omni_provider *provider) {
  if (NULL == name || '\0' == name[0] || NULL == provider || NULL == provider->subject) {
    return NULL;
  }
  return provider->subject(provider, name);
}

/* ---- value normalisation ------------------------------------------- */

static omni_json *omni_fixjson(omni_pool *pool, const omni_json *val, int donull) {
  size_t index;

  if (omni_isabsent(val) || omni_isnull(val)) {
    return donull ? omni_str(pool, OMNI_NULLMARK) : omni_null(pool);
  }

  if (omni_islist(val)) {
    omni_json *out = omni_list(pool);
    for (index = 0; index < val->listlen; index++) {
      omni_list_push(out, omni_fixjson(pool, val->list[index], donull));
    }
    return out;
  }

  if (omni_ismap(val)) {
    omni_json *out = omni_map(pool);
    for (index = 0; index < val->maplen; index++) {
      omni_map_set(out, val->keys[index], omni_fixjson(pool, val->vals[index], donull));
    }
    return out;
  }

  return omni_clone(pool, val);
}

/* The JSON form of an error: always at least {name,message}. */
static omni_json *omni_errify(omni_pool *pool, const char *message) {
  omni_json *out = omni_map(pool);
  omni_map_set(out, "name", omni_str(pool, "Error"));
  omni_map_set(out, "message", omni_str(pool, NULL == message ? "" : message));
  return out;
}

/* ---- matching ------------------------------------------------------ */

static int omni_strcasefind(const char *haystack, const char *needle) {
  size_t hlen = strlen(haystack);
  size_t nlen = strlen(needle);
  size_t at;
  size_t index;

  if (0 == nlen) {
    return 1;
  }
  if (nlen > hlen) {
    return 0;
  }

  for (at = 0; at + nlen <= hlen; at++) {
    for (index = 0; index < nlen; index++) {
      int a = tolower((unsigned char)haystack[at + index]);
      int b = tolower((unsigned char)needle[index]);
      if (a != b) {
        break;
      }
    }
    if (index == nlen) {
      return 1;
    }
  }

  return 0;
}

int omni_matchval(omni_pool *pool, const omni_json *check, const omni_json *base) {
  const char *want;

  if (omni_deepequal(check, base)) {
    return 1;
  }

  want = omni_strval(check);

  if (NULL != want && (0 == strcmp(want, OMNI_UNDEFMARK) || 0 == strcmp(want, OMNI_NULLMARK))) {
    const char *basestr = omni_strval(base);
    return omni_isnone(base) || (NULL != basestr && 0 == strcmp(basestr, OMNI_NULLMARK));
  }

  if (omni_isnone(check)) {
    const char *basestr = omni_strval(base);
    return omni_isnone(base) || (NULL != basestr && 0 == strcmp(basestr, OMNI_NULLMARK));
  }

  if (NULL != want) {
    char *basestr = omni_stringify(pool, base);
    size_t wantlen = strlen(want);

    /* An empty want is a substring of everything, so it would match any
     * value. Require the base to be the empty string too. */
    if (0 == wantlen) {
      const char *bstr = omni_strval(base);
      return NULL != bstr && '\0' == bstr[0];
    }

    if (2 < wantlen && '/' == want[0] && '/' == want[wantlen - 1]) {
      char *pattern = omni_pool_strdup(pool, want + 1);
      pattern[wantlen - 2] = '\0';
      return omni_regex_find(pattern, basestr);
    }

    return omni_strcasefind(basestr, want);
  }

  return 0;
}

typedef struct {
  omni_pool *pool;
  omni_flags flags;
  size_t index;
  const omni_json *entry;
  const omni_json *base;
  char **errout;
} omni_matchctx;

static char *omni_matchat(omni_matchctx *ctx, char **path, size_t pathlen) {
  return 0 == pathlen ? omni_pool_strdup(ctx->pool, "<root>")
                      : omni_pathify(ctx->pool, path, pathlen);
}

static int omni_matchwalk(omni_matchctx *ctx, const omni_json *check, char **path,
                          size_t pathlen) {
  size_t at;
  char part[32];

  if (omni_islist(check)) {
    for (at = 0; at < check->listlen; at++) {
      snprintf(part, sizeof(part), "%lu", (unsigned long)at);
      path[pathlen] = omni_pool_strdup(ctx->pool, part);
      if (0 != omni_matchwalk(ctx, check->list[at], path, pathlen + 1)) {
        return 1;
      }
    }
    return 0;
  }

  if (omni_ismap(check)) {
    for (at = 0; at < check->maplen; at++) {
      path[pathlen] = check->keys[at];
      if (0 != omni_matchwalk(ctx, check->vals[at], path, pathlen + 1)) {
        return 1;
      }
    }
    return 0;
  }

  {
    const omni_json *baseval = omni_getpath(ctx->base, path, pathlen);
    const char *checkstr = omni_strval(check);
    const char *basestr = omni_strval(baseval);

    /* The sentinels are tested BEFORE the identity check below. Otherwise
     * a subject returning the literal string "__UNDEF__" satisfies an
     * assertion that the key is absent - two mutually exclusive states
     * passing one check. A sentinel that accepts its own literal is not a
     * sentinel. (NULLMARK still accepts NULLMARK: under the default null
     * flag a real null has already been normalised to it, so the two are
     * genuinely indistinguishable here - that one needs a raw-value
     * escape, not an ordering change.) */

    /* Explicitly absent: satisfied only by a genuinely missing key, never
     * by a present null (the distinction the sentinels exist to keep). */
    if (NULL != checkstr && 0 == strcmp(checkstr, OMNI_UNDEFMARK)) {
      if (omni_isabsent(baseval)) {
        return 0;
      }
      *ctx->errout = omni_fail(
          ctx->pool, ctx->flags, ctx->index, ctx->entry,
          omni_join(ctx->pool, "expected absent at ", omni_matchat(ctx, path, pathlen), NULL, NULL),
          "absent", omni_stringify(ctx->pool, baseval));
      return 1;
    }

    /* Explicitly null: satisfied only by a present null. */
    if (NULL != checkstr && 0 == strcmp(checkstr, OMNI_NULLMARK)) {
      if (omni_isnull(baseval) || (NULL != basestr && 0 == strcmp(basestr, OMNI_NULLMARK))) {
        return 0;
      }
      *ctx->errout = omni_fail(
          ctx->pool, ctx->flags, ctx->index, ctx->entry,
          omni_join(ctx->pool, "expected null at ", omni_matchat(ctx, path, pathlen), NULL, NULL),
          "null", omni_stringify(ctx->pool, baseval));
      return 1;
    }

    /* Explicitly present: any present value, including null. */
    if (NULL != checkstr && 0 == strcmp(checkstr, OMNI_EXISTSMARK)) {
      if (!omni_isabsent(baseval)) {
        return 0;
      }
      *ctx->errout = omni_fail(
          ctx->pool, ctx->flags, ctx->index, ctx->entry,
          omni_join(ctx->pool, "expected present at ", omni_matchat(ctx, path, pathlen), NULL, NULL),
          "present", "absent");
      return 1;
    }

    /* Identical values match. This sits below the sentinel branches on
     * purpose - see the note above. */
    if (omni_deepequal(check, baseval)) {
      return 0;
    }

    /* A concrete expectation never matches a missing key - a match leaf
     * against an absent value must fail, not substring-match "undefined". */
    if (omni_isabsent(baseval)) {
      *ctx->errout = omni_fail(
          ctx->pool, ctx->flags, ctx->index, ctx->entry,
          omni_join(ctx->pool, "match failed at ", omni_matchat(ctx, path, pathlen), NULL, NULL),
          omni_stringify(ctx->pool, check), "absent");
      return 1;
    }

    if (omni_matchval(ctx->pool, check, baseval)) {
      return 0;
    }

    *ctx->errout = omni_fail(
        ctx->pool, ctx->flags, ctx->index, ctx->entry,
        omni_join(ctx->pool, "match failed at ", omni_matchat(ctx, path, pathlen), NULL, NULL),
        omni_stringify(ctx->pool, check), omni_stringify(ctx->pool, baseval));
    return 1;
  }
}

#define OMNI_MAXPATH 64

static int omni_match(omni_pool *pool, omni_flags flags, size_t index, const omni_json *entry,
                      const omni_json *check, const omni_json *base, char **errout) {
  omni_matchctx ctx;
  char *path[OMNI_MAXPATH];

  ctx.pool = pool;
  ctx.flags = flags;
  ctx.index = index;
  ctx.entry = entry;
  ctx.base = base;
  ctx.errout = errout;

  return omni_matchwalk(&ctx, check, path, 0);
}

/* ---- result checking ----------------------------------------------- */

static int omni_checkresult(omni_pool *pool, omni_flags flags, size_t index, omni_json *entry,
                            omni_json *args, omni_json *res, char **errout) {
  int matched = 0;
  omni_json *entryerr = omni_map_get(entry, "err");
  omni_json *check = omni_map_get(entry, "match");
  omni_json *out;

  if (!omni_isnone(entryerr)) {
    *errout = omni_fail(pool, flags, index, entry, "expected error did not occur",
                        omni_stringify(pool, entryerr), omni_stringify(pool, res));
    return 1;
  }

  if (!omni_isnone(check)) {
    omni_json *base = omni_map(pool);
    omni_map_set(base, "in", omni_map_get(entry, "in"));
    omni_map_set(base, "args", args);
    omni_map_set(base, "out", omni_map_get(entry, "res"));
    omni_map_set(base, "ctx", omni_map_get(entry, "ctx"));

    if (0 != omni_match(pool, flags, index, entry, check, base, errout)) {
      return 1;
    }
    matched = 1;
  }

  out = omni_map_get(entry, "out");

  if (omni_deepequal(res, out)) {
    return 0;
  }

  /* NOTE: a match with no explicit out is a complete check on its own. */
  if (matched) {
    const char *outstr = omni_strval(out);
    if (omni_isnone(out) || (NULL != outstr && 0 == strcmp(outstr, OMNI_NULLMARK))) {
      return 0;
    }
  }

  *errout = omni_fail(pool, flags, index, entry, "result mismatch", omni_stringify(pool, out),
                      omni_stringify(pool, res));
  return 1;
}

static int omni_handleerror(omni_pool *pool, omni_flags flags, size_t index, omni_json *entry,
                            const char *message, char **errout) {
  omni_json *entryerr = omni_map_get(entry, "err");
  omni_json *check;

  if (!omni_isnone(entryerr)) {
    int istrue = (NULL != entryerr && OMNI_BOOL == entryerr->type && entryerr->boolval);
    omni_json *msgval = omni_str(pool, message);

    if (istrue || omni_matchval(pool, entryerr, msgval)) {
      check = omni_map_get(entry, "match");
      if (!omni_isnone(check)) {
        omni_json *base = omni_map(pool);
        omni_map_set(base, "in", omni_map_get(entry, "in"));
        omni_map_set(base, "out", omni_map_get(entry, "res"));
        omni_map_set(base, "ctx", omni_map_get(entry, "ctx"));
        omni_map_set(base, "err", omni_errify(pool, message));
        return omni_match(pool, flags, index, entry, check, base, errout);
      }
      return 0;
    }

    *errout = omni_fail(pool, flags, index, entry, "error mismatch",
                        omni_stringify(pool, entryerr), message);
    return 1;
  }

  *errout = omni_fail(pool, flags, index, entry, "unexpected error", NULL, message);
  return 1;
}

/* ---- runner -------------------------------------------------------- */

omni_json *omni_loadspec(omni_pool *pool, const char *path, char **errout) {
  char *text;
  char *parseerr = NULL;
  omni_json *alltests;

  if (NULL != errout) {
    *errout = NULL;
  }

  text = omni_readfile(pool, path);
  if (NULL == text) {
    if (NULL != errout) {
      *errout = omni_join(pool, "omni: cannot read spec: ", path, NULL, NULL);
    }
    return NULL;
  }

  alltests = omni_parse(pool, text, &parseerr);
  if (NULL == alltests && NULL != errout) {
    *errout = omni_join(pool, "omni: cannot parse spec: ", path, ": ", parseerr);
  }

  return alltests;
}

omni_runner *omni_make_runner(omni_pool *pool, const char *path, omni_json *spec,
                              omni_provider *provider, char **errout) {
  omni_runner *runner;
  omni_json *alltests = spec;
  int specversion;

  if (NULL != errout) {
    *errout = NULL;
  }

  if (NULL == alltests) {
    if (NULL == path) {
      if (NULL != errout) {
        *errout = omni_pool_strdup(pool, "omni: no spec given");
      }
      return NULL;
    }

    alltests = omni_loadspec(pool, path, errout);
    if (NULL == alltests) {
      return NULL;
    }
  }

  /* Fail fast: a spec this runner cannot faithfully run is refused before
   * any test group runs, not partway through the first one. */
  specversion = omni_resolveversion(pool, alltests, errout);
  if (0 > specversion) {
    return NULL;
  }

  runner = (omni_runner *)omni_pool_alloc(pool, sizeof(omni_runner));
  runner->pool = pool;
  runner->alltests = alltests;
  runner->provider = provider;
  runner->specversion = specversion;

  return runner;
}

omni_runpack *omni_runner_run(omni_runner *runner, const char *name, omni_json *store,
                              char **errout) {
  omni_runpack *pack;
  omni_json *defclient;

  (void)store;

  if (NULL != errout) {
    *errout = NULL;
  }

  pack = (omni_runpack *)omni_pool_alloc(runner->pool, sizeof(omni_runpack));
  pack->pool = runner->pool;
  pack->name = omni_pool_strdup(runner->pool, NULL == name ? "" : name);
  pack->spec = omni_resolvespec(name, runner->alltests);
  pack->provider = runner->provider;
  pack->subject = omni_resolvesubject(name, runner->provider);
  pack->specversion = runner->specversion;

  /* Build the named clients declared by the spec's DEF.client block. A
   * spec may define clients that a given test run never references. */
  defclient = omni_map_get(omni_map_get(pack->spec, "DEF"), "client");

  if (omni_ismap(defclient) && NULL != runner->provider && NULL != runner->provider->client) {
    size_t index;

    pack->nclients = defclient->maplen;
    pack->clientnames = (char **)omni_pool_alloc(runner->pool, sizeof(char *) * (pack->nclients + 1));
    pack->clients =
        (omni_provider **)omni_pool_alloc(runner->pool, sizeof(omni_provider *) * (pack->nclients + 1));

    for (index = 0; index < defclient->maplen; index++) {
      omni_json *cdef = defclient->vals[index];
      omni_json *copts = omni_map_get(omni_map_get(cdef, "test"), "options");

      if (omni_isabsent(copts)) {
        copts = omni_map(runner->pool);
      }

      pack->clientnames[index] = defclient->keys[index];
      pack->clients[index] = runner->provider->client(runner->provider, copts);
    }
  }

  return pack;
}

omni_json *omni_spec(omni_runpack *pack) { return pack->spec; }

omni_json *omni_set(omni_runpack *pack, const char *name) {
  return omni_map_get(pack->spec, name);
}

int omni_runset(omni_runpack *pack, omni_json *testspec, omni_subject *subject, char **errout) {
  return omni_runsetflags(pack, testspec, omni_flags_default(), subject, errout);
}

int omni_runsetflags(omni_runpack *pack, omni_json *testspec, omni_flags flags,
                     omni_subject *subject, char **errout) {
  omni_pool *pool = pack->pool;
  omni_json *testspecmap;
  omni_json *testset;
  omni_subject *usesubject = NULL == subject ? pack->subject : subject;
  size_t index;

  if (NULL != errout) {
    *errout = NULL;
  }

  if (NULL == flags.name) {
    flags.name = ('\0' == pack->name[0]) ? "set" : pack->name;
  }

  if (NULL == usesubject) {
    *errout = omni_join(pool, "omni: no test subject for: ", flags.name, NULL, NULL);
    return 1;
  }

  testspecmap = omni_fixjson(pool, testspec, flags.null);
  testset = omni_map_get(testspecmap, "set");

  if (!omni_islist(testset)) {
    *errout = omni_join(pool, "omni: test spec has no set: ", flags.name, NULL, NULL);
    return 1;
  }

  /* Validate the AUTHORED group up front, against testspec (pre-fixjson),
   * not testset (post-fixjson) - see omni_checkset. Absorbs the
   * empty-set check: a vacuously green group proves nothing, so version
   * 1 makes an empty set an error unless the group is marked empty. */
  if (1 <= pack->specversion) {
    if (0 != omni_checkset(pool, flags, testspec, testset, errout)) {
      return 1;
    }
  }

  for (index = 0; index < testset->listlen; index++) {
    omni_json *entry = testset->list[index];
    omni_json *args = omni_list(pool);
    omni_subject *entrysubject = usesubject;
    omni_provider *entryprovider = pack->provider;
    omni_json *clientname;
    omni_json *rawargs;
    omni_result result;
    size_t at;

    /* An entry with no `out` expects a null (or absent) result. */
    if (flags.null && omni_isnone(omni_map_get(entry, "out"))) {
      omni_map_set(entry, "out", omni_str(pool, OMNI_NULLMARK));
    }

    clientname = omni_map_get(entry, "client");
    if (omni_isstr(clientname)) {
      omni_provider *client = NULL;
      for (at = 0; at < pack->nclients; at++) {
        if (0 == strcmp(pack->clientnames[at], omni_strval(clientname))) {
          client = pack->clients[at];
          break;
        }
      }

      if (NULL == client) {
        *errout = omni_join(pool, "omni: unknown client: ", omni_strval(clientname), NULL, NULL);
        return 1;
      }

      entryprovider = client;
      {
        omni_subject *clientsubject = omni_resolvesubject(pack->name, client);
        if (NULL != clientsubject) {
          entrysubject = clientsubject;
        }
      }
    }

    /* Build the argument list: `ctx`, `args`, or `in`. */
    rawargs = omni_map_get(entry, "args");
    if (omni_map_has(entry, "ctx")) {
      omni_list_push(args, omni_map_get(entry, "ctx"));
    } else if (omni_islist(rawargs)) {
      for (at = 0; at < rawargs->listlen; at++) {
        omni_list_push(args, rawargs->list[at]);
      }
    } else {
      omni_list_push(args, omni_clone(pool, omni_map_get(entry, "in")));
    }

    if ((omni_map_has(entry, "ctx") || omni_map_has(entry, "args")) && 0 < args->listlen &&
        omni_ismap(args->list[0])) {
      omni_json *first = omni_clone(pool, args->list[0]);
      if (NULL != pack->provider && NULL != pack->provider->contextify) {
        first = pack->provider->contextify(pack->provider, first);
      }
      args->list[0] = first;
      omni_map_set(entry, "ctx", first);

      /* So a subject can reach the client it was invoked through. */
      if (omni_ismap(first)) {
        first->client = entryprovider;
      }
    }

    result = entrysubject->call(entrysubject, args->list, args->listlen);

    if (NULL != result.err) {
      if (0 != omni_handleerror(pool, flags, index, entry, result.err, errout)) {
        return 1;
      }
      continue;
    }

    {
      omni_json *res = omni_fixjson(pool, result.val, flags.null);
      omni_map_set(entry, "res", res);

      if (0 != omni_checkresult(pool, flags, index, entry, args, res, errout)) {
        return 1;
      }
    }
  }

  return 0;
}
