/* Omni: the shared multi-language test runner (C port).
 *
 * Port of the canonical TypeScript implementation
 * (typescript/src/Runner.ts). Behaviour must match, case for case.
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "omni.h"

struct omni_runner {
  omni_pool *pool;
  omni_json *alltests;
  omni_provider *provider;
};

struct omni_runpack {
  omni_pool *pool;
  omni_json *spec;
  char *name;
  omni_provider *provider;
  omni_subject *subject;

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

  /* An empty container asserts structure that the traversal would
   * otherwise skip: it has no leaves, so `match:{out:{}}` used to pass
   * any result. Require the base at this path to be an equal empty
   * container. (The synthetic root wrapper is never empty, so skip it.) */
  if (0 < pathlen && ((omni_islist(check) && 0 == check->listlen) ||
                      (omni_ismap(check) && 0 == check->maplen))) {
    const omni_json *baseval = omni_getpath(ctx->base, path, pathlen);
    if (!omni_deepequal(check, baseval)) {
      *ctx->errout = omni_fail(
          ctx->pool, ctx->flags, ctx->index, ctx->entry,
          omni_join(ctx->pool, "match failed at ", omni_matchat(ctx, path, pathlen), NULL, NULL),
          omni_stringify(ctx->pool, check), omni_stringify(ctx->pool, baseval));
      return 1;
    }
    return 0;
  }

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

    if (omni_deepequal(check, baseval)) {
      return 0;
    }

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

  runner = (omni_runner *)omni_pool_alloc(pool, sizeof(omni_runner));
  runner->pool = pool;
  runner->alltests = alltests;
  runner->provider = provider;

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

  for (index = 0; index < testset->listlen; index++) {
    omni_json *entry = testset->list[index];
    omni_json *args = omni_list(pool);
    omni_subject *entrysubject = usesubject;
    omni_json *clientname;
    omni_json *rawargs;
    omni_result result;
    size_t at;

    if (!omni_ismap(entry)) {
      char head[64];
      snprintf(head, sizeof(head), "[%lu]: entry is not a map", (unsigned long)index);
      *errout = omni_join(pool, "omni: ", flags.name, head, NULL);
      return 1;
    }

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
