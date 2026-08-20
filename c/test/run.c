/* RUN: make test
 * RUN-SOME: ./build/omnitest basic
 *
 * The Fibonacci conformance suite: every omni port runs this same set of
 * groups, from the same spec/fib.json, against the same fib library.
 *
 * No third-party test framework: a failing omni check returns a message,
 * which this harness reports. Any host framework can do the same.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../src/omni.h"
#include "fib.h"

static omni_pool *POOL = NULL;
static const char *ONLY = NULL;
static int PASSCOUNT = 0;
static int FAILCOUNT = 0;

/* ---- subjects ------------------------------------------------------ */

typedef struct {
  double shift;
} fibdata;

static omni_result subject_fib(omni_subject *self, omni_json **args, size_t nargs) {
  fibdata *data = (fibdata *)self->data;
  const omni_json *val = 0 < nargs ? args[0] : NULL;

  if (NULL != data && 0 != data->shift && omni_isnum(val)) {
    val = omni_num(POOL, omni_numval(val) + data->shift);
  }

  return fib_fib(POOL, val);
}

static omni_result subject_fibseq(omni_subject *self, omni_json **args, size_t nargs) {
  (void)self;
  return fib_seq(POOL, 0 < nargs ? args[0] : NULL);
}

static omni_result subject_fibrange(omni_subject *self, omni_json **args, size_t nargs) {
  (void)self;
  return fib_range(POOL, 0 < nargs ? args[0] : NULL, 1 < nargs ? args[1] : NULL);
}

static omni_result subject_fibinfo(omni_subject *self, omni_json **args, size_t nargs) {
  (void)self;
  return fib_info(POOL, 0 < nargs ? args[0] : NULL);
}

/* The context-group subject: reports what the runner delivered - the
 * contextify mark and the attached client - as plain data, so the spec
 * can pin both with an ordinary `out` comparison. */
static omni_result subject_fibctx(omni_subject *self, omni_json **args, size_t nargs) {
  omni_json *ctx = 0 < nargs ? args[0] : NULL;
  omni_json *nval = omni_map_get(ctx, "n");
  omni_result out;
  long index = 0;

  (void)self;

  out.val = NULL;
  out.err = NULL;

  if (0 != fib_index(POOL, nval, &index, &out.err)) {
    return out;
  }

  out.val = omni_map(POOL);
  omni_map_set(out.val, "n", nval);
  omni_map_set(out.val, "val", omni_num(POOL, (double)fib_num(index)));
  omni_map_set(out.val, "mark", omni_map_get(ctx, "mark"));
  omni_map_set(out.val, "hasclient", omni_bool(POOL, omni_ismap(ctx) && NULL != ctx->client));

  return out;
}

/* Returns the sentinel text "__UNDEF__" as ordinary string data, so the
 * negative test can prove that a __UNDEF__ match leaf is not satisfied by
 * a subject that merely echoes the literal. */
static omni_result subject_undefliteral(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out;

  (void)self;
  (void)args;
  (void)nargs;

  out.err = NULL;
  out.val = omni_map(POOL);
  omni_map_set(out.val, "a", omni_str(POOL, OMNI_UNDEFMARK));

  return out;
}

static omni_subject *makesubject(omni_result (*call)(omni_subject *, omni_json **, size_t),
                                 void *data) {
  omni_subject *subject = (omni_subject *)omni_pool_alloc(POOL, sizeof(omni_subject));
  subject->call = call;
  subject->data = data;
  return subject;
}

/* ---- provider ------------------------------------------------------ */

static omni_provider *fibprovider(double shift);

static omni_subject *provider_subject(omni_provider *self, const char *name) {
  if (0 == strcmp(name, "fib")) {
    return makesubject(subject_fib, self->data);
  }
  if (0 == strcmp(name, "fibseq")) {
    return makesubject(subject_fibseq, NULL);
  }
  if (0 == strcmp(name, "fibrange")) {
    return makesubject(subject_fibrange, NULL);
  }
  if (0 == strcmp(name, "fibinfo")) {
    return makesubject(subject_fibinfo, NULL);
  }
  if (0 == strcmp(name, "fibctx")) {
    return makesubject(subject_fibctx, NULL);
  }
  return NULL;
}

static omni_provider *provider_client(omni_provider *self, omni_json *options) {
  omni_json *shift = omni_map_get(options, "shift");
  (void)self;
  return fibprovider(omni_isnum(shift) ? omni_numval(shift) : 0);
}

/* Marks the map, so the context group can prove the hook ran. The map is
 * already a fresh copy by the time the runner calls this (see
 * omni_runsetflags), so mutating it in place is safe. */
static omni_json *provider_contextify(omni_provider *self, omni_json *val) {
  (void)self;
  omni_map_set(val, "mark", omni_str(POOL, "CTX"));
  return val;
}

/* The provider hosts the system under test. `shift` offsets the Fibonacci
 * index, so that a client-specific subject is observably different. */
static omni_provider *fibprovider(double shift) {
  omni_provider *provider = (omni_provider *)omni_pool_alloc(POOL, sizeof(omni_provider));
  fibdata *data = (fibdata *)omni_pool_alloc(POOL, sizeof(fibdata));

  data->shift = shift;

  provider->subject = provider_subject;
  provider->client = provider_client;
  provider->contextify = provider_contextify;
  provider->data = data;

  return provider;
}

/* ---- harness ------------------------------------------------------- */

static void report(const char *name, int failed, const char *message) {
  if (failed) {
    FAILCOUNT++;
    printf("FAIL - %s\n%s\n", name, NULL == message ? "" : message);
  } else {
    PASSCOUNT++;
    printf("ok   - %s\n", name);
  }
}

static int wanted(const char *name) { return NULL == ONLY || 0 == strcmp(ONLY, name); }

/* Find the shared spec directory by walking up from the working dir. */
static char *specfile(const char *name) {
  static char path[4200];
  char dir[4096];
  int step;

  if (NULL == getcwd(dir, sizeof(dir))) {
    return NULL;
  }

  for (step = 0; step < 8; step++) {
    FILE *probe;
    snprintf(path, sizeof(path), "%s/spec/%s", dir, name);
    probe = fopen(path, "rb");
    if (NULL != probe) {
      fclose(probe);
      return path;
    }

    {
      char *slash = strrchr(dir, '/');
      if (NULL == slash || dir == slash) {
        break;
      }
      *slash = '\0';
    }
  }

  return NULL;
}

static void rungroup(omni_runpack *pack, const char *name, omni_subject *subject,
                     omni_flags flags) {
  char *err = NULL;
  int failed;

  if (!wanted(name)) {
    return;
  }

  failed = omni_runsetflags(pack, omni_set(pack, name), flags, subject, &err);
  report(name, failed, err);
}

/* The runner must fail when the subject is wrong - otherwise a green
 * suite means nothing. */
static omni_json *badspec(void) {
  omni_json *spec = omni_map(POOL);
  omni_json *fibgroup = omni_map(POOL);
  omni_json *group;
  omni_json *set;
  omni_json *entry;

  /* wrongout */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 5));
  omni_map_set(entry, "out", omni_num(POOL, 5));
  omni_list_push(set, entry);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  omni_map_set(entry, "out", omni_num(POOL, 999));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "wrongout", group);

  /* wrongerr */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 1));
  omni_map_set(entry, "err", omni_str(POOL, "never happens"));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "wrongerr", group);

  /* wrongmatch */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *check = omni_map(POOL);
    omni_map_set(check, "out", omni_num(POOL, 999));
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "wrongmatch", group);

  /* missing */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *inner = omni_map(POOL);
    omni_json *check = omni_map(POOL);
    omni_map_set(inner, "nope", omni_str(POOL, OMNI_EXISTSMARK));
    omni_map_set(check, "out", inner);
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "missing", group);

  /* matchabsent: a concrete match leaf against a missing key must fail,
   * not substring-match the text "undefined". */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *inner = omni_map(POOL);
    omni_json *check = omni_map(POOL);
    omni_map_set(inner, "nope", omni_str(POOL, "fine"));
    omni_map_set(check, "out", inner);
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "matchabsent", group);

  /* undefonnull: __UNDEF__ (absent) must not be satisfied by a present
   * null. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 0));
  {
    omni_json *inner = omni_map(POOL);
    omni_json *check = omni_map(POOL);
    omni_map_set(inner, "prev", omni_str(POOL, OMNI_UNDEFMARK));
    omni_map_set(check, "out", inner);
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "undefonnull", group);

  /* nullonabsent: __NULL__ (present null) must not be satisfied by an
   * absent key. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *inner = omni_map(POOL);
    omni_json *check = omni_map(POOL);
    omni_map_set(inner, "nope", omni_str(POOL, OMNI_NULLMARK));
    omni_map_set(check, "out", inner);
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "nullonabsent", group);

  /* emptystr: an empty-string want is a substring of everything, not a
   * wildcard. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *inner = omni_map(POOL);
    omni_json *check = omni_map(POOL);
    omni_map_set(inner, "label", omni_str(POOL, ""));
    omni_map_set(check, "out", inner);
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "emptystr", group);

  /* wrongundef: __UNDEF__ asserts the key is ABSENT, so a subject that
   * returns the literal string "__UNDEF__" as data must not satisfy it -
   * otherwise two mutually exclusive states pass one assertion. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *inner = omni_map(POOL);
    omni_json *check = omni_map(POOL);
    omni_map_set(inner, "a", omni_str(POOL, OMNI_UNDEFMARK));
    omni_map_set(check, "out", inner);
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "wrongundef", group);

  omni_map_set(spec, "fib", fibgroup);

  return spec;
}

static void expectfail(const char *label, const char *setname, omni_subject *subject) {
  char *err = NULL;
  omni_runner *runner;
  omni_runpack *pack;
  int failed;

  if (!wanted(label)) {
    return;
  }

  runner = omni_make_runner(POOL, NULL, badspec(), NULL, &err);
  pack = omni_runner_run(runner, "fib", NULL, &err);

  failed = omni_runset(pack, omni_set(pack, setname), subject, &err);

  report(label, !failed, "omni: expected a failure, got none");
}

/* ---- version and strict-entry negative tests ------------------------ */

/* omni_make_runner itself must refuse the spec; there is no pack to run
 * against. */
static void expectloadfail(const char *label, omni_json *spec, const char *wantsubstr) {
  char *err = NULL;
  omni_runner *runner;

  if (!wanted(label)) {
    return;
  }

  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);

  if (NULL != runner) {
    report(label, 1, "omni: expected make_runner to fail, got a runner");
    return;
  }

  if (NULL == err || NULL == strstr(err, wantsubstr)) {
    report(label, 1, err);
    return;
  }

  report(label, 0, NULL);
}

static omni_json *emptysetgroup(void) {
  omni_json *group = omni_map(POOL);
  omni_map_set(group, "set", omni_list(POOL));
  return group;
}

static void versionnegatives(void) {
  omni_json *spec;
  omni_json *meta;
  omni_json *fibgroup;

  /* unsupported spec version */
  spec = omni_map(POOL);
  meta = omni_map(POOL);
  omni_map_set(meta, "version", omni_num(POOL, 99));
  fibgroup = omni_map(POOL);
  omni_map_set(fibgroup, "g", emptysetgroup());
  omni_map_set(spec, "OMNI", meta);
  omni_map_set(spec, "fib", fibgroup);
  expectloadfail("rejects an unsupported spec version", spec, "unsupported spec version");

  /* unknown required capability */
  spec = omni_map(POOL);
  meta = omni_map(POOL);
  omni_map_set(meta, "version", omni_num(POOL, 1));
  {
    omni_json *requires = omni_list(POOL);
    omni_list_push(requires, omni_str(POOL, "nosuchfeature"));
    omni_map_set(meta, "requires", requires);
  }
  fibgroup = omni_map(POOL);
  omni_map_set(fibgroup, "g", emptysetgroup());
  omni_map_set(spec, "OMNI", meta);
  omni_map_set(spec, "fib", fibgroup);
  expectloadfail("rejects an unknown required capability", spec, "unsupported capability");

  /* malformed version block */
  spec = omni_map(POOL);
  meta = omni_map(POOL);
  omni_map_set(meta, "version", omni_str(POOL, "one"));
  fibgroup = omni_map(POOL);
  omni_map_set(fibgroup, "g", emptysetgroup());
  omni_map_set(spec, "OMNI", meta);
  omni_map_set(spec, "fib", fibgroup);
  expectloadfail("rejects a malformed version block", spec, "malformed OMNI");
}

/* A present-but-null block is malformed; only a genuinely absent OMNI
 * key is legacy. A port that tests definedness rather than presence
 * silently skips strict mode here, so both cases are pinned. */
static omni_json *onegroup(void) {
  omni_json *group = omni_map(POOL);
  omni_json *set = omni_list(POOL);
  omni_json *entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 1));
  omni_map_set(entry, "out", omni_num(POOL, 1));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  return group;
}

static void nullomninegative(void) {
  const char *label = "rejects a null OMNI block, but accepts an absent one";
  omni_json *spec;
  omni_json *meta;
  omni_json *fibgroup;
  char *err;
  omni_runner *runner;

  if (!wanted(label)) {
    return;
  }

  /* OMNI: null refuses with "malformed OMNI". */
  spec = omni_map(POOL);
  omni_map_set(spec, "OMNI", omni_null(POOL));
  fibgroup = omni_map(POOL);
  omni_map_set(fibgroup, "g", onegroup());
  omni_map_set(spec, "fib", fibgroup);

  err = NULL;
  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  if (NULL != runner || NULL == err || NULL == strstr(err, "malformed OMNI")) {
    report(label, 1, NULL == err ? "omni: expected malformed OMNI, got a runner" : err);
    return;
  }

  /* {version: 1, requires: null} refuses with "malformed OMNI requires
   * list". */
  spec = omni_map(POOL);
  meta = omni_map(POOL);
  omni_map_set(meta, "version", omni_num(POOL, 1));
  omni_map_set(meta, "requires", omni_null(POOL));
  omni_map_set(spec, "OMNI", meta);
  fibgroup = omni_map(POOL);
  omni_map_set(fibgroup, "g", onegroup());
  omni_map_set(spec, "fib", fibgroup);

  err = NULL;
  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  if (NULL != runner || NULL == err || NULL == strstr(err, "malformed OMNI requires list")) {
    report(label, 1, NULL == err ? "omni: expected malformed OMNI requires list, got a runner" : err);
    return;
  }

  /* A spec with no OMNI key at all loads fine. */
  spec = omni_map(POOL);
  fibgroup = omni_map(POOL);
  omni_map_set(fibgroup, "g", onegroup());
  omni_map_set(spec, "fib", fibgroup);

  err = NULL;
  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  if (NULL == runner) {
    report(label, 1, err);
    return;
  }

  report(label, 0, NULL);
}

/* A version-1 spec with one bad entry in group "g"; the runner must
 * refuse it at runset time with `wantsubstr` in the message. */
static void expectstrictfail(const char *label, omni_json *entry, const char *wantsubstr,
                             omni_subject *subject) {
  omni_json *spec = omni_map(POOL);
  omni_json *meta = omni_map(POOL);
  omni_json *fibgroup = omni_map(POOL);
  omni_json *group = omni_map(POOL);
  omni_json *set = omni_list(POOL);
  char *err = NULL;
  omni_runner *runner;
  omni_runpack *pack;
  int failed;

  if (!wanted(label)) {
    return;
  }

  omni_map_set(meta, "version", omni_num(POOL, 1));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "g", group);
  omni_map_set(spec, "OMNI", meta);
  omni_map_set(spec, "fib", fibgroup);

  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  pack = omni_runner_run(runner, "fib", NULL, &err);
  failed = omni_runset(pack, omni_set(pack, "g"), subject, &err);

  if (!failed) {
    report(label, 1, "omni: expected a failure, got none");
    return;
  }

  if (NULL == err || NULL == strstr(err, wantsubstr)) {
    report(label, 1, err);
    return;
  }

  report(label, 0, NULL);
}

static void strictnegatives(void) {
  omni_json *entry;

  /* an unknown entry field fails instead of passing vacuously */
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *check = omni_map(POOL);
    omni_map_set(check, "out", omni_num(POOL, 999));
    omni_map_set(entry, "matches", check);
  }
  expectstrictfail("strict: an unknown entry field fails instead of passing vacuously", entry,
                   "unknown entry field: matches", makesubject(subject_fibinfo, NULL));

  /* more than one of in, args, ctx */
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 5));
  {
    omni_json *args = omni_list(POOL);
    omni_list_push(args, omni_num(POOL, 5));
    omni_map_set(entry, "args", args);
  }
  omni_map_set(entry, "out", omni_num(POOL, 5));
  expectstrictfail("strict: more than one of in, args, ctx fails", entry,
                   "more than one of in, args, ctx", makesubject(subject_fib, NULL));

  /* err together with out */
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, -1));
  omni_map_set(entry, "err", omni_bool(POOL, 1));
  omni_map_set(entry, "out", omni_num(POOL, 5));
  expectstrictfail("strict: err together with out fails", entry, "both err and out",
                   makesubject(subject_fib, NULL));

  /* a null id fails even under null-normalisation: checkset must
   * validate the AUTHORED entry (real null), not the fixjson-normalised
   * one (which would have turned the null into the NULLMARK string and
   * hidden it from the "is a string" check). */
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 1));
  omni_map_set(entry, "out", omni_num(POOL, 1));
  omni_map_set(entry, "id", omni_null(POOL));
  expectstrictfail("strict: a null id fails even under null-normalisation", entry,
                   "entry id is not a string", makesubject(subject_fib, NULL));
}

static void emptysetnegative(void) {
  const char *label = "strict: an empty set fails unless marked empty";
  omni_json *spec = omni_map(POOL);
  omni_json *meta = omni_map(POOL);
  omni_json *fibgroup = omni_map(POOL);
  omni_json *g = emptysetgroup();
  omni_json *h = emptysetgroup();
  char *err = NULL;
  omni_runner *runner;
  omni_runpack *pack;
  int failed;

  if (!wanted(label)) {
    return;
  }

  omni_map_set(meta, "version", omni_num(POOL, 1));
  omni_map_set(h, "empty", omni_bool(POOL, 1));
  omni_map_set(fibgroup, "g", g);
  omni_map_set(fibgroup, "h", h);
  omni_map_set(spec, "OMNI", meta);
  omni_map_set(spec, "fib", fibgroup);

  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  pack = omni_runner_run(runner, "fib", NULL, &err);

  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "g"), makesubject(subject_fib, NULL), &err);
  if (!failed || NULL == err || NULL == strstr(err, "empty test set")) {
    report(label, 1, NULL == err ? "omni: expected a failure, got none" : err);
    return;
  }

  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "h"), makesubject(subject_fib, NULL), &err);
  if (failed) {
    report(label, 1, err);
    return;
  }

  report(label, 0, NULL);
}

static void legacylenient(void) {
  const char *label = "a legacy spec (no OMNI block) stays lenient";
  omni_json *spec = omni_map(POOL);
  omni_json *fibgroup = omni_map(POOL);
  omni_json *group = omni_map(POOL);
  omni_json *set = omni_list(POOL);
  omni_json *entry = omni_map(POOL);
  char *err = NULL;
  omni_runner *runner;
  omni_runpack *pack;
  int failed;

  if (!wanted(label)) {
    return;
  }

  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *check = omni_map(POOL);
    omni_map_set(check, "out", omni_num(POOL, 999));
    omni_map_set(entry, "matches", check);
  }
  omni_map_set(entry, "out", omni_num(POOL, 8));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "g", group);
  omni_map_set(spec, "fib", fibgroup);

  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  pack = omni_runner_run(runner, "fib", NULL, &err);

  failed = omni_runset(pack, omni_set(pack, "g"), makesubject(subject_fib, NULL), &err);
  report(label, failed, err);
}

static void checkmessage(void) {
  const char *label = "reports entry index and id";
  omni_json *spec = omni_map(POOL);
  omni_json *fibgroup = omni_map(POOL);
  omni_json *group = omni_map(POOL);
  omni_json *set = omni_list(POOL);
  omni_json *entry;
  omni_runner *runner;
  omni_runpack *pack;
  char *err = NULL;
  int failed;
  size_t index;
  const char *wants[3];

  if (!wanted(label)) {
    return;
  }

  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 1));
  omni_map_set(entry, "out", omni_num(POOL, 1));
  omni_list_push(set, entry);

  entry = omni_map(POOL);
  omni_map_set(entry, "id", omni_str(POOL, "x#2"));
  omni_map_set(entry, "in", omni_num(POOL, 2));
  omni_map_set(entry, "out", omni_num(POOL, 42));
  omni_list_push(set, entry);

  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "g", group);
  omni_map_set(spec, "fib", fibgroup);

  runner = omni_make_runner(POOL, NULL, spec, NULL, &err);
  pack = omni_runner_run(runner, "fib", NULL, &err);

  failed = omni_runset(pack, omni_set(pack, "g"), makesubject(subject_fib, NULL), &err);

  if (!failed || NULL == err) {
    report(label, 1, "omni: expected a failure, got none");
    return;
  }

  wants[0] = "fib[1] (x#2)";
  wants[1] = "expected: 42";
  wants[2] = "actual:   1";

  for (index = 0; index < 3; index++) {
    if (NULL == strstr(err, wants[index])) {
      report(label, 1, err);
      return;
    }
  }

  report(label, 0, NULL);
}

int main(int argc, char **argv) {
  char *path;
  char *err = NULL;
  omni_runner *runner;
  omni_runpack *pack;

  POOL = omni_pool_new();

  if (1 < argc) {
    ONLY = argv[1];
  }

  path = specfile("fib.json");
  if (NULL == path) {
    printf("omni: spec not found: fib.json\n");
    omni_pool_free(POOL);
    return 1;
  }

  runner = omni_make_runner(POOL, path, NULL, fibprovider(0), &err);
  if (NULL == runner) {
    printf("%s\n", err);
    omni_pool_free(POOL);
    return 1;
  }

  pack = omni_runner_run(runner, "fib", NULL, &err);

  rungroup(pack, "basic", makesubject(subject_fib, NULL), omni_flags_default());
  rungroup(pack, "seq", makesubject(subject_fibseq, NULL), omni_flags_default());
  rungroup(pack, "range", makesubject(subject_fibrange, NULL), omni_flags_default());
  rungroup(pack, "info", makesubject(subject_fibinfo, NULL), omni_flags_default());
  rungroup(pack, "nulls", makesubject(subject_fibinfo, NULL), omni_flags_nonull());
  rungroup(pack, "error", makesubject(subject_fib, NULL), omni_flags_default());
  rungroup(pack, "match", makesubject(subject_fib, NULL), omni_flags_default());
  rungroup(pack, "matchinfo", makesubject(subject_fibinfo, NULL), omni_flags_default());
  rungroup(pack, "client", makesubject(subject_fib, NULL), omni_flags_default());
  rungroup(pack, "context", makesubject(subject_fibctx, NULL), omni_flags_default());

  expectfail("detects wrong result", "wrongout", makesubject(subject_fib, NULL));
  expectfail("detects missing error", "wrongerr", makesubject(subject_fib, NULL));
  expectfail("detects failed match", "wrongmatch", makesubject(subject_fib, NULL));
  expectfail("detects absent key", "missing", makesubject(subject_fibinfo, NULL));
  expectfail("a concrete match leaf does not match a missing key", "matchabsent",
             makesubject(subject_fibinfo, NULL));
  expectfail("__UNDEF__ does not match its own literal", "wrongundef",
             makesubject(subject_undefliteral, NULL));
  expectfail("__UNDEF__ does not match a present null", "undefonnull",
             makesubject(subject_fibinfo, NULL));
  expectfail("__NULL__ does not match an absent key", "nullonabsent",
             makesubject(subject_fibinfo, NULL));
  expectfail("an empty-string match leaf is not a wildcard", "emptystr",
             makesubject(subject_fibinfo, NULL));

  versionnegatives();
  nullomninegative();
  strictnegatives();
  emptysetnegative();
  legacylenient();
  checkmessage();

  printf("\n%d passed, %d failed\n", PASSCOUNT, FAILCOUNT);

  omni_pool_free(POOL);

  return 0 == FAILCOUNT ? 0 : 1;
}
