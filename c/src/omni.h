/* Omni: the shared multi-language test runner (C port).
 *
 * A test spec is plain JSON. The same spec file drives the same tests in
 * every language that ships an omni port.
 *
 * Port of the canonical TypeScript implementation
 * (typescript/src/Runner.ts). Behaviour must match, case for case.
 *
 * C has no exceptions, so a failing check is reported through a return
 * code plus a message; a subject reports failure by setting `err`.
 *
 * Memory: every value is allocated from an omni_pool and freed in one go
 * by omni_pool_free. Nothing else needs to be freed by the caller.
 *
 * Standard C99 plus POSIX <regex.h>. No third-party dependencies.
 */

#ifndef VOXGIG_OMNI_H
#define VOXGIG_OMNI_H

#include <stddef.h>

#define OMNI_NULLMARK "__NULL__"     /* Value is JSON null. */
#define OMNI_UNDEFMARK "__UNDEF__"   /* Value is not present. */
#define OMNI_EXISTSMARK "__EXISTS__" /* Value exists (not undefined). */

typedef enum {
  OMNI_ABSENT = 0, /* No value at all (distinct from null). */
  OMNI_NULL,
  OMNI_BOOL,
  OMNI_NUM,
  OMNI_STR,
  OMNI_LIST,
  OMNI_MAP
} omni_type;

typedef struct omni_pool omni_pool;
typedef struct omni_json omni_json;
typedef struct omni_provider omni_provider;

struct omni_json {
  omni_type type;

  int boolval;
  double numval;
  char *strval;

  omni_json **list; /* OMNI_LIST */
  size_t listlen;
  size_t listcap;

  char **keys; /* OMNI_MAP, insertion ordered */
  omni_json **vals;
  size_t maplen;
  size_t mapcap;

  omni_pool *pool;

  /* The provider that owns a contextified ctx/args[0] map argument,
   * attached by the runner (see omni_runsetflags in runner.c) so a
   * subject can reach the client it was invoked through. NULL except on
   * that one map value; not part of the JSON value itself, so clone,
   * deepequal and stringify all ignore it. */
  omni_provider *client;
};

/* ---- pool ---- */

omni_pool *omni_pool_new(void);
void omni_pool_free(omni_pool *pool);
char *omni_pool_strdup(omni_pool *pool, const char *text);
void *omni_pool_alloc(omni_pool *pool, size_t size);

/* ---- values ---- */

omni_json *omni_absent(omni_pool *pool);
omni_json *omni_null(omni_pool *pool);
omni_json *omni_bool(omni_pool *pool, int val);
omni_json *omni_num(omni_pool *pool, double val);
omni_json *omni_str(omni_pool *pool, const char *val);
omni_json *omni_list(omni_pool *pool);
omni_json *omni_map(omni_pool *pool);

void omni_list_push(omni_json *list, omni_json *val);
void omni_map_set(omni_json *map, const char *key, omni_json *val);

/* Returns an OMNI_ABSENT value when the key or index is missing. */
omni_json *omni_map_get(const omni_json *map, const char *key);
omni_json *omni_list_get(const omni_json *list, size_t index);
int omni_map_has(const omni_json *map, const char *key);

int omni_ismap(const omni_json *val);
int omni_islist(const omni_json *val);
int omni_isnode(const omni_json *val);
int omni_isabsent(const omni_json *val);
int omni_isnull(const omni_json *val);
int omni_isnone(const omni_json *val); /* absent or null */
int omni_isnum(const omni_json *val);
int omni_isstr(const omni_json *val);

const char *omni_strval(const omni_json *val); /* NULL when not a string */
double omni_numval(const omni_json *val);      /* 0 when not a number */

/* ---- json text ---- */

/* Parse JSON text. Returns NULL and sets *errout (pool-owned) on failure. */
omni_json *omni_parse(omni_pool *pool, const char *text, char **errout);

/* Read a whole file into a pool-owned string. NULL on failure. */
char *omni_readfile(omni_pool *pool, const char *path);

/* Compact JSON with map keys sorted: identical text in every port. */
char *omni_jsonstr(omni_pool *pool, const omni_json *val);

/* Strings verbatim, everything else as compact JSON. */
char *omni_stringify(omni_pool *pool, const omni_json *val);

/* Render a number the same way in every port: 5.0 prints as 5. */
char *omni_numstr(omni_pool *pool, double val);

/* ---- util ---- */

omni_json *omni_clone(omni_pool *pool, const omni_json *val);
omni_json *omni_getpath(const omni_json *val, char **path, size_t pathlen);
int omni_deepequal(const omni_json *a, const omni_json *b);
char *omni_pathify(omni_pool *pool, char **path, size_t pathlen);

/* The callback of a walk. Return the (possibly replaced) value. */
typedef omni_json *(*omni_apply)(void *data, omni_pool *pool, const omni_json *val, char **path,
                                 size_t pathlen);

/* Depth-first walk: children first, then the containing node. */
omni_json *omni_walk(omni_pool *pool, const omni_json *val, omni_apply apply, void *data);

/* An omni_apply that converts NULLMARK sentinels back into real nulls. */
omni_json *omni_nullmodifier(void *data, omni_pool *pool, const omni_json *val, char **path,
                             size_t pathlen);

/* Is `pattern` found anywhere in `text`? PCRE-style \d \w \s are
 * translated to POSIX classes before compiling. */
int omni_regex_find(const char *pattern, const char *text);

/* ---- runner ---- */

/* A spec may declare its format version in a top-level OMNI block. No
 * block means version 0: the original, lenient format, frozen forever.
 * Version 1 turns on strict entry validation (see omni_checkentry in
 * runner.c). SPECVERSION is the newest version this runner understands. */
#define OMNI_SPECVERSION 1

/* Capability strings this runner supports beyond the version baseline. A
 * spec's OMNI.requires list is checked against this: an unknown
 * capability refuses the spec loudly at load time, instead of a lagging
 * port silently mis-running it. NULL-terminated; empty today - future
 * format features mint a string here. */
extern const char *const OMNI_CAPABILITIES[];

typedef struct omni_result {
  omni_json *val;  /* the subject's return value */
  const char *err; /* NULL, or the error message */
} omni_result;

typedef struct omni_subject omni_subject;

struct omni_subject {
  omni_result (*call)(omni_subject *self, omni_json **args, size_t nargs);
  void *data;
};

typedef struct omni_provider omni_provider;

struct omni_provider {
  /* Resolve a test subject by name. NULL when unknown. */
  omni_subject *(*subject)(omni_provider *self, const char *name);
  /* Build a sub-provider from a DEF.client entry's options. */
  omni_provider *(*client)(omni_provider *self, omni_json *options);
  /* Wrap a map argument as a call context. */
  omni_json *(*contextify)(omni_provider *self, omni_json *val);
  void *data;
  /* Build the `match.err` base from the failure, REPLACING omni_errify.
   *
   * C reports a subject failure as its message and nothing else
   * (`omni_result.err`), so a library whose errors carry a code has no
   * other way to put one in the base. The hook receives that message and
   * returns the base, letting a spec assert `match: {err: {code: "x"}}`
   * instead of pattern-matching prose. NULL for the default.
   *
   * LAST, AFTER `data`, AND THAT POSITION IS THE POINT. A consumer may
   * aggregate-initialize this struct positionally — `{subject, client,
   * contextify, mydata}` — and inserting a member before `data` would
   * silently bind that consumer's data pointer to a FUNCTION POINTER
   * while leaving `data` null. The first error to match would then call
   * through it. Appending is the only position that leaves existing
   * initializers meaning what they meant. */
  omni_json *(*errify)(omni_provider *self, omni_pool *pool, const char *message);
};

typedef struct omni_flags {
  int null;         /* Convert JSON nulls to NULLMARK (default 1). */
  const char *name; /* Label used in failure messages. */
} omni_flags;

omni_flags omni_flags_default(void);
omni_flags omni_flags_nonull(void);

typedef struct omni_runner omni_runner;
typedef struct omni_runpack omni_runpack;

/* Load a spec from a JSON file. NULL on failure, with *errout set. */
omni_json *omni_loadspec(omni_pool *pool, const char *path, char **errout);

/* Find `primary.<name>`, then `<name>`, then the whole spec. */
omni_json *omni_resolvespec(const char *name, omni_json *alltests);

/* Make a runner. Exactly one of `path` and `spec` must be given.
 * Returns NULL and sets *errout on failure. */
omni_runner *omni_make_runner(omni_pool *pool, const char *path, omni_json *spec,
                              omni_provider *provider, char **errout);

/* Resolve one named section of the spec. */
omni_runpack *omni_runner_run(omni_runner *runner, const char *name, omni_json *store,
                              char **errout);

/* The resolved spec, and one named group of it. */
omni_json *omni_spec(omni_runpack *pack);
omni_json *omni_set(omni_runpack *pack, const char *name);

/* Run a set of test entries. Returns 0 on success; on failure returns 1
 * and sets *errout to a pool-owned message. */
int omni_runset(omni_runpack *pack, omni_json *testspec, omni_subject *subject, char **errout);
int omni_runsetflags(omni_runpack *pack, omni_json *testspec, omni_flags flags,
                     omni_subject *subject, char **errout);

/* Match one leaf value: /regex/ or case-insensitive substring. */
int omni_matchval(omni_pool *pool, const omni_json *check, const omni_json *base);

#endif /* VOXGIG_OMNI_H */
