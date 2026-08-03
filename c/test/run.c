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
  return NULL;
}

static omni_provider *provider_client(omni_provider *self, omni_json *options) {
  omni_json *shift = omni_map_get(options, "shift");
  (void)self;
  return fibprovider(omni_isnum(shift) ? omni_numval(shift) : 0);
}

/* The provider hosts the system under test. `shift` offsets the Fibonacci
 * index, so that a client-specific subject is observably different. */
static omni_provider *fibprovider(double shift) {
  omni_provider *provider = (omni_provider *)omni_pool_alloc(POOL, sizeof(omni_provider));
  fibdata *data = (fibdata *)omni_pool_alloc(POOL, sizeof(fibdata));

  data->shift = shift;

  provider->subject = provider_subject;
  provider->client = provider_client;
  provider->contextify = NULL;
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

  /* emptymatch: an empty container asserts an empty container, not
   * "anything". */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 6));
  {
    omni_json *check = omni_map(POOL);
    omni_map_set(check, "out", omni_map(POOL));
    omni_map_set(entry, "match", check);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(fibgroup, "emptymatch", group);

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

  expectfail("detects wrong result", "wrongout", makesubject(subject_fib, NULL));
  expectfail("detects missing error", "wrongerr", makesubject(subject_fib, NULL));
  expectfail("detects failed match", "wrongmatch", makesubject(subject_fib, NULL));
  expectfail("detects absent key", "missing", makesubject(subject_fibinfo, NULL));
  expectfail("a concrete match leaf does not match a missing key", "matchabsent",
             makesubject(subject_fibinfo, NULL));
  expectfail("__UNDEF__ does not match a present null", "undefonnull",
             makesubject(subject_fibinfo, NULL));
  expectfail("__NULL__ does not match an absent key", "nullonabsent",
             makesubject(subject_fibinfo, NULL));
  expectfail("an empty match container is not vacuous", "emptymatch",
             makesubject(subject_fibinfo, NULL));
  expectfail("an empty-string match leaf is not a wildcard", "emptystr",
             makesubject(subject_fibinfo, NULL));
  checkmessage();

  printf("\n%d passed, %d failed\n", PASSCOUNT, FAILCOUNT);

  omni_pool_free(POOL);

  return 0 == FAILCOUNT ? 0 : 1;
}
