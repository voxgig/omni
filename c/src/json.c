/* The omni JSON value model, pool allocator, parser and printer.
 *
 * The omni runner must be able to test *any* library, and must add no
 * third-party dependencies, so it carries its own JSON support rather than
 * borrowing one or using the system under test.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "omni.h"

/* ---- pool ---------------------------------------------------------- */

typedef struct omni_block omni_block;

struct omni_block {
  void *ptr;
  omni_block *next;
};

struct omni_pool {
  omni_block *blocks;
};

omni_pool *omni_pool_new(void) {
  omni_pool *pool = (omni_pool *)calloc(1, sizeof(omni_pool));
  return pool;
}

void *omni_pool_alloc(omni_pool *pool, size_t size) {
  void *ptr = calloc(1, size);
  omni_block *block;

  if (NULL == ptr) {
    return NULL;
  }

  block = (omni_block *)calloc(1, sizeof(omni_block));
  if (NULL == block) {
    free(ptr);
    return NULL;
  }

  block->ptr = ptr;
  block->next = pool->blocks;
  pool->blocks = block;

  return ptr;
}

char *omni_pool_strdup(omni_pool *pool, const char *text) {
  size_t len;
  char *out;

  if (NULL == text) {
    text = "";
  }

  len = strlen(text);
  out = (char *)omni_pool_alloc(pool, len + 1);
  if (NULL == out) {
    return NULL;
  }

  memcpy(out, text, len);
  out[len] = '\0';

  return out;
}

void omni_pool_free(omni_pool *pool) {
  omni_block *block;

  if (NULL == pool) {
    return;
  }

  block = pool->blocks;
  while (NULL != block) {
    omni_block *next = block->next;
    free(block->ptr);
    free(block);
    block = next;
  }

  free(pool);
}

/* ---- values -------------------------------------------------------- */

static omni_json *omni_new(omni_pool *pool, omni_type type) {
  omni_json *val = (omni_json *)omni_pool_alloc(pool, sizeof(omni_json));
  if (NULL == val) {
    return NULL;
  }
  val->type = type;
  val->pool = pool;
  return val;
}

omni_json *omni_absent(omni_pool *pool) { return omni_new(pool, OMNI_ABSENT); }
omni_json *omni_null(omni_pool *pool) { return omni_new(pool, OMNI_NULL); }

omni_json *omni_bool(omni_pool *pool, int val) {
  omni_json *out = omni_new(pool, OMNI_BOOL);
  out->boolval = val ? 1 : 0;
  return out;
}

omni_json *omni_num(omni_pool *pool, double val) {
  omni_json *out = omni_new(pool, OMNI_NUM);
  out->numval = val;
  return out;
}

omni_json *omni_str(omni_pool *pool, const char *val) {
  omni_json *out = omni_new(pool, OMNI_STR);
  out->strval = omni_pool_strdup(pool, val);
  return out;
}

omni_json *omni_list(omni_pool *pool) { return omni_new(pool, OMNI_LIST); }
omni_json *omni_map(omni_pool *pool) { return omni_new(pool, OMNI_MAP); }

/* Pool-backed growth: the old array is kept (and freed with the pool). */
static void *omni_grow(omni_pool *pool, void *old, size_t entrysize, size_t used, size_t *cap) {
  size_t newcap = (0 == *cap) ? 8 : (*cap * 2);
  void *out = omni_pool_alloc(pool, entrysize * newcap);

  if (NULL == out) {
    return old;
  }

  if (NULL != old && 0 < used) {
    memcpy(out, old, entrysize * used);
  }

  *cap = newcap;
  return out;
}

void omni_list_push(omni_json *list, omni_json *val) {
  if (NULL == list || OMNI_LIST != list->type) {
    return;
  }

  if (list->listlen >= list->listcap) {
    list->list = (omni_json **)omni_grow(list->pool, list->list, sizeof(omni_json *),
                                         list->listlen, &list->listcap);
  }

  list->list[list->listlen++] = val;
}

void omni_map_set(omni_json *map, const char *key, omni_json *val) {
  size_t index;

  if (NULL == map || OMNI_MAP != map->type) {
    return;
  }

  for (index = 0; index < map->maplen; index++) {
    if (0 == strcmp(map->keys[index], key)) {
      map->vals[index] = val;
      return;
    }
  }

  if (map->maplen >= map->mapcap) {
    size_t keycap = map->mapcap;
    size_t valcap = map->mapcap;
    map->keys = (char **)omni_grow(map->pool, map->keys, sizeof(char *), map->maplen, &keycap);
    map->vals =
        (omni_json **)omni_grow(map->pool, map->vals, sizeof(omni_json *), map->maplen, &valcap);
    map->mapcap = keycap;
  }

  map->keys[map->maplen] = omni_pool_strdup(map->pool, key);
  map->vals[map->maplen] = val;
  map->maplen++;
}

omni_json *omni_map_get(const omni_json *map, const char *key) {
  size_t index;

  if (NULL == map || OMNI_MAP != map->type) {
    return NULL;
  }

  for (index = 0; index < map->maplen; index++) {
    if (0 == strcmp(map->keys[index], key)) {
      return map->vals[index];
    }
  }

  return omni_absent(map->pool);
}

int omni_map_has(const omni_json *map, const char *key) {
  size_t index;

  if (NULL == map || OMNI_MAP != map->type) {
    return 0;
  }

  for (index = 0; index < map->maplen; index++) {
    if (0 == strcmp(map->keys[index], key)) {
      return 1;
    }
  }

  return 0;
}

omni_json *omni_list_get(const omni_json *list, size_t index) {
  if (NULL == list || OMNI_LIST != list->type || index >= list->listlen) {
    return NULL;
  }
  return list->list[index];
}

int omni_ismap(const omni_json *val) { return NULL != val && OMNI_MAP == val->type; }
int omni_islist(const omni_json *val) { return NULL != val && OMNI_LIST == val->type; }
int omni_isnode(const omni_json *val) { return omni_ismap(val) || omni_islist(val); }
int omni_isabsent(const omni_json *val) { return NULL == val || OMNI_ABSENT == val->type; }
int omni_isnull(const omni_json *val) { return NULL != val && OMNI_NULL == val->type; }
int omni_isnone(const omni_json *val) { return omni_isabsent(val) || omni_isnull(val); }
int omni_isnum(const omni_json *val) { return NULL != val && OMNI_NUM == val->type; }
int omni_isstr(const omni_json *val) { return NULL != val && OMNI_STR == val->type; }

const char *omni_strval(const omni_json *val) {
  return omni_isstr(val) ? val->strval : NULL;
}

double omni_numval(const omni_json *val) { return omni_isnum(val) ? val->numval : 0.0; }

/* ---- text buffer --------------------------------------------------- */

typedef struct {
  omni_pool *pool;
  char *text;
  size_t len;
  size_t cap;
} omni_buf;

static void buf_init(omni_buf *buf, omni_pool *pool) {
  buf->pool = pool;
  buf->cap = 64;
  buf->len = 0;
  buf->text = (char *)omni_pool_alloc(pool, buf->cap);
  if (NULL != buf->text) {
    buf->text[0] = '\0';
  }
}

static void buf_add(omni_buf *buf, const char *text) {
  size_t len = strlen(text);

  if (buf->len + len + 1 > buf->cap) {
    size_t newcap = buf->cap;
    char *grown;
    while (buf->len + len + 1 > newcap) {
      newcap *= 2;
    }
    grown = (char *)omni_pool_alloc(buf->pool, newcap);
    if (NULL == grown) {
      return;
    }
    memcpy(grown, buf->text, buf->len);
    buf->text = grown;
    buf->cap = newcap;
  }

  memcpy(buf->text + buf->len, text, len);
  buf->len += len;
  buf->text[buf->len] = '\0';
}

static void buf_addchar(omni_buf *buf, char ch) {
  char text[2];
  text[0] = ch;
  text[1] = '\0';
  buf_add(buf, text);
}

/* ---- number and string rendering ----------------------------------- */

char *omni_numstr(omni_pool *pool, double val) {
  char text[64];

  if (val != val || val > 1e308 * 10 || val < -1e308 * 10) {
    return omni_pool_strdup(pool, "null");
  }

  if (val == floor(val) && fabs(val) < 9007199254740992.0) {
    snprintf(text, sizeof(text), "%.0f", val);
    /* "-0" is still zero. */
    if (0 == strcmp(text, "-0")) {
      return omni_pool_strdup(pool, "0");
    }
    return omni_pool_strdup(pool, text);
  }

  snprintf(text, sizeof(text), "%.17g", val);
  return omni_pool_strdup(pool, text);
}

static void buf_quote(omni_buf *buf, const char *text) {
  size_t index;
  char escape[8];

  buf_addchar(buf, '"');

  for (index = 0; '\0' != text[index]; index++) {
    unsigned char ch = (unsigned char)text[index];
    switch (ch) {
      case '"':
        buf_add(buf, "\\\"");
        break;
      case '\\':
        buf_add(buf, "\\\\");
        break;
      case '\n':
        buf_add(buf, "\\n");
        break;
      case '\r':
        buf_add(buf, "\\r");
        break;
      case '\t':
        buf_add(buf, "\\t");
        break;
      default:
        if (0x20 > ch) {
          snprintf(escape, sizeof(escape), "\\u%04x", ch);
          buf_add(buf, escape);
        } else {
          buf_addchar(buf, (char)ch);
        }
    }
  }

  buf_addchar(buf, '"');
}

static void jsonstr_val(omni_buf *buf, const omni_json *val) {
  size_t index;
  size_t inner;

  if (omni_isabsent(val)) {
    buf_add(buf, "undefined");
    return;
  }

  switch (val->type) {
    case OMNI_NULL:
      buf_add(buf, "null");
      return;
    case OMNI_BOOL:
      buf_add(buf, val->boolval ? "true" : "false");
      return;
    case OMNI_NUM:
      buf_add(buf, omni_numstr(buf->pool, val->numval));
      return;
    case OMNI_STR:
      buf_quote(buf, val->strval);
      return;
    case OMNI_LIST:
      buf_addchar(buf, '[');
      for (index = 0; index < val->listlen; index++) {
        if (0 < index) {
          buf_addchar(buf, ',');
        }
        jsonstr_val(buf, val->list[index]);
      }
      buf_addchar(buf, ']');
      return;
    case OMNI_MAP: {
      /* Sorted keys, so messages are identical in every port. */
      size_t *order = (size_t *)omni_pool_alloc(buf->pool, sizeof(size_t) * (val->maplen + 1));
      for (index = 0; index < val->maplen; index++) {
        order[index] = index;
      }
      for (index = 1; index < val->maplen; index++) {
        size_t hold = order[index];
        inner = index;
        while (0 < inner && 0 < strcmp(val->keys[order[inner - 1]], val->keys[hold])) {
          order[inner] = order[inner - 1];
          inner--;
        }
        order[inner] = hold;
      }

      buf_addchar(buf, '{');
      for (index = 0; index < val->maplen; index++) {
        if (0 < index) {
          buf_addchar(buf, ',');
        }
        buf_quote(buf, val->keys[order[index]]);
        buf_addchar(buf, ':');
        jsonstr_val(buf, val->vals[order[index]]);
      }
      buf_addchar(buf, '}');
      return;
    }
    default:
      buf_add(buf, "undefined");
  }
}

char *omni_jsonstr(omni_pool *pool, const omni_json *val) {
  omni_buf buf;
  buf_init(&buf, pool);
  jsonstr_val(&buf, val);
  return buf.text;
}

char *omni_stringify(omni_pool *pool, const omni_json *val) {
  if (omni_isstr(val)) {
    return omni_pool_strdup(pool, val->strval);
  }
  return omni_jsonstr(pool, val);
}

/* ---- parser -------------------------------------------------------- */

/* Nesting bound: a value nested deeper than this fails the parse rather
 * than overflowing the C stack. */
#define OMNI_PARSE_MAXDEPTH 4096

typedef struct {
  omni_pool *pool;
  const char *text;
  size_t pos;
  size_t len;
  int depth;
  char *err;
} omni_parser;

static void parse_error(omni_parser *parser, const char *reason) {
  char text[128];
  if (NULL != parser->err) {
    return;
  }
  snprintf(text, sizeof(text), "omni: %s at %lu", reason, (unsigned long)parser->pos);
  parser->err = omni_pool_strdup(parser->pool, text);
}

static void parse_ws(omni_parser *parser) {
  while (parser->pos < parser->len) {
    char ch = parser->text[parser->pos];
    if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
      parser->pos++;
    } else {
      break;
    }
  }
}

static omni_json *parse_val(omni_parser *parser);

static char *parse_rawstr(omni_parser *parser) {
  omni_buf buf;

  if (parser->pos >= parser->len || '"' != parser->text[parser->pos]) {
    parse_error(parser, "expected string");
    return NULL;
  }
  parser->pos++;

  buf_init(&buf, parser->pool);

  while (parser->pos < parser->len) {
    char ch = parser->text[parser->pos++];

    if ('"' == ch) {
      return buf.text;
    }

    if ('\\' != ch) {
      buf_addchar(&buf, ch);
      continue;
    }

    if (parser->pos >= parser->len) {
      break;
    }

    ch = parser->text[parser->pos++];
    switch (ch) {
      case '"':
        buf_addchar(&buf, '"');
        break;
      case '\\':
        buf_addchar(&buf, '\\');
        break;
      case '/':
        buf_addchar(&buf, '/');
        break;
      case 'b':
        buf_addchar(&buf, '\b');
        break;
      case 'f':
        buf_addchar(&buf, '\f');
        break;
      case 'n':
        buf_addchar(&buf, '\n');
        break;
      case 'r':
        buf_addchar(&buf, '\r');
        break;
      case 't':
        buf_addchar(&buf, '\t');
        break;
      case 'u': {
        unsigned int code = 0;
        int digit;
        if (parser->pos + 4 > parser->len) {
          parse_error(parser, "bad unicode escape");
          return NULL;
        }
        for (digit = 0; digit < 4; digit++) {
          char hex = parser->text[parser->pos++];
          code *= 16;
          if ('0' <= hex && '9' >= hex) {
            code += (unsigned int)(hex - '0');
          } else if ('a' <= hex && 'f' >= hex) {
            code += (unsigned int)(hex - 'a' + 10);
          } else if ('A' <= hex && 'F' >= hex) {
            code += (unsigned int)(hex - 'A' + 10);
          } else {
            parse_error(parser, "bad unicode escape");
            return NULL;
          }
        }
        /* UTF-8 encode the code point. */
        if (0x80 > code) {
          buf_addchar(&buf, (char)code);
        } else if (0x800 > code) {
          buf_addchar(&buf, (char)(0xC0 | (code >> 6)));
          buf_addchar(&buf, (char)(0x80 | (code & 0x3F)));
        } else {
          buf_addchar(&buf, (char)(0xE0 | (code >> 12)));
          buf_addchar(&buf, (char)(0x80 | ((code >> 6) & 0x3F)));
          buf_addchar(&buf, (char)(0x80 | (code & 0x3F)));
        }
        break;
      }
      default:
        parse_error(parser, "bad escape");
        return NULL;
    }
  }

  parse_error(parser, "unterminated string");
  return NULL;
}

static omni_json *parse_map(omni_parser *parser) {
  omni_json *out = omni_map(parser->pool);
  parser->pos++; /* { */

  parse_ws(parser);
  if (parser->pos < parser->len && '}' == parser->text[parser->pos]) {
    parser->pos++;
    return out;
  }

  for (;;) {
    char *key;
    omni_json *val;

    parse_ws(parser);
    key = parse_rawstr(parser);
    if (NULL == key) {
      return NULL;
    }

    parse_ws(parser);
    if (parser->pos >= parser->len || ':' != parser->text[parser->pos]) {
      parse_error(parser, "expected ':'");
      return NULL;
    }
    parser->pos++;

    parse_ws(parser);
    val = parse_val(parser);
    if (NULL == val) {
      return NULL;
    }
    omni_map_set(out, key, val);

    parse_ws(parser);
    if (parser->pos >= parser->len) {
      parse_error(parser, "unterminated object");
      return NULL;
    }
    if (',' == parser->text[parser->pos]) {
      parser->pos++;
      continue;
    }
    if ('}' == parser->text[parser->pos]) {
      parser->pos++;
      return out;
    }

    parse_error(parser, "expected ',' or '}'");
    return NULL;
  }
}

static omni_json *parse_list(omni_parser *parser) {
  omni_json *out = omni_list(parser->pool);
  parser->pos++; /* [ */

  parse_ws(parser);
  if (parser->pos < parser->len && ']' == parser->text[parser->pos]) {
    parser->pos++;
    return out;
  }

  for (;;) {
    omni_json *val;

    parse_ws(parser);
    val = parse_val(parser);
    if (NULL == val) {
      return NULL;
    }
    omni_list_push(out, val);

    parse_ws(parser);
    if (parser->pos >= parser->len) {
      parse_error(parser, "unterminated array");
      return NULL;
    }
    if (',' == parser->text[parser->pos]) {
      parser->pos++;
      continue;
    }
    if (']' == parser->text[parser->pos]) {
      parser->pos++;
      return out;
    }

    parse_error(parser, "expected ',' or ']'");
    return NULL;
  }
}

static int parse_word(omni_parser *parser, const char *word) {
  size_t len = strlen(word);
  if (parser->pos + len > parser->len ||
      0 != strncmp(parser->text + parser->pos, word, len)) {
    parse_error(parser, "bad literal");
    return 0;
  }
  parser->pos += len;
  return 1;
}

static omni_json *parse_num(omni_parser *parser) {
  size_t start = parser->pos;
  char text[64];
  char *end;
  size_t len;
  double val;

  if (parser->pos < parser->len &&
      ('-' == parser->text[parser->pos] || '+' == parser->text[parser->pos])) {
    parser->pos++;
  }

  while (parser->pos < parser->len) {
    char ch = parser->text[parser->pos];
    if (('0' <= ch && '9' >= ch) || '.' == ch || 'e' == ch || 'E' == ch || '-' == ch ||
        '+' == ch) {
      parser->pos++;
    } else {
      break;
    }
  }

  len = parser->pos - start;
  if (0 == len || len >= sizeof(text)) {
    parse_error(parser, "bad number");
    return NULL;
  }

  memcpy(text, parser->text + start, len);
  text[len] = '\0';

  /* The number must consume exactly the scanned run: `1-2` scans as one
   * token, strtod stops at the `-`, and the remainder is garbage, not a
   * number. Silently keeping the prefix would accept malformed JSON. */
  end = NULL;
  val = strtod(text, &end);
  if (end != text + len) {
    parse_error(parser, "bad number");
    return NULL;
  }

  return omni_num(parser->pool, val);
}

static omni_json *parse_val(omni_parser *parser) {
  char ch;

  if (parser->pos >= parser->len) {
    parse_error(parser, "unexpected end of JSON");
    return NULL;
  }

  ch = parser->text[parser->pos];

  if ('{' == ch || '[' == ch) {
    omni_json *out;

    if (OMNI_PARSE_MAXDEPTH <= parser->depth) {
      parse_error(parser, "too deeply nested");
      return NULL;
    }

    parser->depth++;
    out = '{' == ch ? parse_map(parser) : parse_list(parser);
    parser->depth--;
    return out;
  }
  if ('"' == ch) {
    char *text = parse_rawstr(parser);
    return NULL == text ? NULL : omni_str(parser->pool, text);
  }
  if ('t' == ch) {
    return parse_word(parser, "true") ? omni_bool(parser->pool, 1) : NULL;
  }
  if ('f' == ch) {
    return parse_word(parser, "false") ? omni_bool(parser->pool, 0) : NULL;
  }
  if ('n' == ch) {
    return parse_word(parser, "null") ? omni_null(parser->pool) : NULL;
  }

  return parse_num(parser);
}

omni_json *omni_parse(omni_pool *pool, const char *text, char **errout) {
  omni_parser parser;
  omni_json *val;

  parser.pool = pool;
  parser.text = text;
  parser.pos = 0;
  parser.len = strlen(text);
  parser.depth = 0;
  parser.err = NULL;

  parse_ws(&parser);
  val = parse_val(&parser);
  parse_ws(&parser);

  if (NULL != val && parser.pos < parser.len) {
    parse_error(&parser, "trailing content");
    val = NULL;
  }

  if (NULL != errout) {
    *errout = parser.err;
  }

  return val;
}

char *omni_readfile(omni_pool *pool, const char *path) {
  FILE *handle = fopen(path, "rb");
  char *text;
  long size;
  size_t got;

  if (NULL == handle) {
    return NULL;
  }

  if (0 != fseek(handle, 0, SEEK_END)) {
    fclose(handle);
    return NULL;
  }

  size = ftell(handle);
  if (0 > size) {
    fclose(handle);
    return NULL;
  }
  rewind(handle);

  text = (char *)omni_pool_alloc(pool, (size_t)size + 1);
  if (NULL == text) {
    fclose(handle);
    return NULL;
  }

  got = fread(text, 1, (size_t)size, handle);
  text[got] = '\0';
  fclose(handle);

  return text;
}
