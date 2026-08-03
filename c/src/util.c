/* Omni internal JSON utilities: clone, path lookup, deep equality, and
 * the regex bridge.
 *
 * Self-contained by design: the omni runner must be able to test *any*
 * library, including libraries that provide these same operations.
 */

#include <ctype.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "omni.h"

omni_json *omni_clone(omni_pool *pool, const omni_json *val) {
  size_t index;

  if (NULL == val) {
    return NULL;
  }

  switch (val->type) {
    case OMNI_ABSENT:
      return omni_absent(pool);
    case OMNI_NULL:
      return omni_null(pool);
    case OMNI_BOOL:
      return omni_bool(pool, val->boolval);
    case OMNI_NUM:
      return omni_num(pool, val->numval);
    case OMNI_STR:
      return omni_str(pool, val->strval);
    case OMNI_LIST: {
      omni_json *out = omni_list(pool);
      for (index = 0; index < val->listlen; index++) {
        omni_list_push(out, omni_clone(pool, val->list[index]));
      }
      return out;
    }
    case OMNI_MAP: {
      omni_json *out = omni_map(pool);
      for (index = 0; index < val->maplen; index++) {
        omni_map_set(out, val->keys[index], omni_clone(pool, val->vals[index]));
      }
      return out;
    }
    default:
      return omni_absent(pool);
  }
}

/* Read a value by path. Returns an absent value when a step is missing. */
omni_json *omni_getpath(const omni_json *val, char **path, size_t pathlen) {
  const omni_json *current = val;
  size_t step;

  for (step = 0; step < pathlen; step++) {
    const char *part = path[step];

    if (omni_islist(current)) {
      char *end = NULL;
      long index = strtol(part, &end, 10);
      if (NULL == end || '\0' != *end || 0 > index || (size_t)index >= current->listlen) {
        return NULL;
      }
      current = current->list[index];
      continue;
    }

    if (omni_ismap(current)) {
      if (!omni_map_has(current, part)) {
        return NULL;
      }
      current = omni_map_get(current, part);
      continue;
    }

    return NULL;
  }

  return (omni_json *)current;
}

int omni_deepequal(const omni_json *a, const omni_json *b) {
  size_t index;

  if (a == b) {
    return 1;
  }

  if (NULL == a || NULL == b) {
    return omni_isabsent(a) && omni_isabsent(b);
  }

  if (a->type != b->type) {
    return 0;
  }

  switch (a->type) {
    case OMNI_ABSENT:
    case OMNI_NULL:
      return 1;
    case OMNI_BOOL:
      return (0 != a->boolval) == (0 != b->boolval);
    case OMNI_NUM:
      return a->numval == b->numval || (a->numval != a->numval && b->numval != b->numval);
    case OMNI_STR:
      return 0 == strcmp(a->strval, b->strval);
    case OMNI_LIST:
      if (a->listlen != b->listlen) {
        return 0;
      }
      for (index = 0; index < a->listlen; index++) {
        if (!omni_deepequal(a->list[index], b->list[index])) {
          return 0;
        }
      }
      return 1;
    case OMNI_MAP:
      if (a->maplen != b->maplen) {
        return 0;
      }
      for (index = 0; index < a->maplen; index++) {
        if (!omni_map_has(b, a->keys[index])) {
          return 0;
        }
        if (!omni_deepequal(a->vals[index], omni_map_get(b, a->keys[index]))) {
          return 0;
        }
      }
      return 1;
    default:
      return 0;
  }
}

#define OMNI_WALKMAX 64

static omni_json *omni_walkdown(omni_pool *pool, const omni_json *val, omni_apply apply,
                                void *data, char **path, size_t pathlen) {
  omni_json *next;
  size_t index;
  char part[32];

  if (omni_islist(val)) {
    next = omni_list(pool);
    for (index = 0; index < val->listlen; index++) {
      if (pathlen < OMNI_WALKMAX) {
        snprintf(part, sizeof(part), "%lu", (unsigned long)index);
        path[pathlen] = omni_pool_strdup(pool, part);
      }
      omni_list_push(next,
                     omni_walkdown(pool, val->list[index], apply, data, path, pathlen + 1));
    }
  } else if (omni_ismap(val)) {
    next = omni_map(pool);
    for (index = 0; index < val->maplen; index++) {
      if (pathlen < OMNI_WALKMAX) {
        path[pathlen] = val->keys[index];
      }
      omni_map_set(next, val->keys[index],
                   omni_walkdown(pool, val->vals[index], apply, data, path, pathlen + 1));
    }
  } else {
    next = omni_clone(pool, val);
  }

  return apply(data, pool, next, path, pathlen);
}

omni_json *omni_walk(omni_pool *pool, const omni_json *val, omni_apply apply, void *data) {
  char *path[OMNI_WALKMAX + 2];
  return omni_walkdown(pool, val, apply, data, path, 0);
}

omni_json *omni_nullmodifier(void *data, omni_pool *pool, const omni_json *val, char **path,
                             size_t pathlen) {
  const char *text = omni_strval(val);

  (void)data;
  (void)path;
  (void)pathlen;

  if (NULL == text) {
    return (omni_json *)val;
  }

  if (0 == strcmp(text, OMNI_NULLMARK)) {
    return omni_null(pool);
  }

  /* Replace every embedded NULLMARK with the word `null`. */
  {
    const char *mark = OMNI_NULLMARK;
    size_t marklen = strlen(mark);
    const char *at = strstr(text, mark);
    char *out;
    size_t outlen;
    const char *scan;
    char *write;

    if (NULL == at) {
      return (omni_json *)val;
    }

    outlen = strlen(text) + 1;
    out = (char *)omni_pool_alloc(pool, outlen);
    if (NULL == out) {
      return (omni_json *)val;
    }

    scan = text;
    write = out;
    while (NULL != (at = strstr(scan, mark))) {
      memcpy(write, scan, (size_t)(at - scan));
      write += (at - scan);
      memcpy(write, "null", 4);
      write += 4;
      scan = at + marklen;
    }
    strcpy(write, scan);

    return omni_str(pool, out);
  }
}

char *omni_pathify(omni_pool *pool, char **path, size_t pathlen) {
  size_t total = 1;
  size_t step;
  char *out;

  for (step = 0; step < pathlen; step++) {
    total += strlen(path[step]) + 1;
  }

  out = (char *)omni_pool_alloc(pool, total);
  if (NULL == out) {
    return NULL;
  }
  out[0] = '\0';

  for (step = 0; step < pathlen; step++) {
    if (0 < step) {
      strcat(out, ".");
    }
    strcat(out, path[step]);
  }

  return out;
}

/* Translate the common PCRE escapes to POSIX ERE classes, so that a spec
 * written for any port compiles here too.
 *
 * NOTE: the C port uses POSIX <regex.h>; a pattern that needs a feature
 * outside POSIX ERE (lookaround, lazy quantifiers) will not compile, and
 * omni_regex_find then reports no match.
 */
static char *omni_regex_posix(const char *pattern) {
  size_t len = strlen(pattern);
  size_t cap = len * 12 + 2;
  char *out = (char *)calloc(1, cap);
  size_t index = 0;
  size_t at = 0;

  if (NULL == out) {
    return NULL;
  }

  while (index < len) {
    char ch = pattern[index];

    if ('\\' == ch && index + 1 < len) {
      char next = pattern[index + 1];
      const char *sub = NULL;

      switch (next) {
        case 'd':
          sub = "[0-9]";
          break;
        case 'D':
          sub = "[^0-9]";
          break;
        case 'w':
          sub = "[A-Za-z0-9_]";
          break;
        case 'W':
          sub = "[^A-Za-z0-9_]";
          break;
        case 's':
          sub = "[ \t\n\r\f\v]";
          break;
        case 'S':
          sub = "[^ \t\n\r\f\v]";
          break;
        default:
          sub = NULL;
      }

      if (NULL != sub) {
        size_t sublen = strlen(sub);
        memcpy(out + at, sub, sublen);
        at += sublen;
        index += 2;
        continue;
      }

      out[at++] = ch;
      out[at++] = next;
      index += 2;
      continue;
    }

    out[at++] = ch;
    index++;
  }

  out[at] = '\0';
  return out;
}

int omni_regex_find(const char *pattern, const char *text) {
  regex_t compiled;
  char *posix;
  int found;

  if (NULL == pattern || NULL == text) {
    return 0;
  }

  posix = omni_regex_posix(pattern);
  if (NULL == posix) {
    return 0;
  }

  if (0 != regcomp(&compiled, posix, REG_EXTENDED | REG_NOSUB)) {
    free(posix);
    return 0;
  }

  found = (0 == regexec(&compiled, text, 0, NULL, 0));

  regfree(&compiled);
  free(posix);

  return found;
}
