/* The system under test: a tiny Fibonacci library. */

#include <math.h>
#include <string.h>

#include "fib.h"

static const char *fib_err(omni_pool *pool, const char *reason, const omni_json *val) {
  char *stringified = omni_stringify(pool, val);
  size_t len = strlen(reason) + strlen(stringified) + 1;
  char *out = (char *)omni_pool_alloc(pool, len);

  if (NULL == out) {
    return reason;
  }

  out[0] = '\0';
  strcat(out, reason);
  strcat(out, stringified);

  return out;
}

int fib_index(omni_pool *pool, const omni_json *val, long *index, const char **err) {
  double num;

  if (!omni_isnum(val)) {
    *err = fib_err(pool, "fib: not a number: ", val);
    return 1;
  }

  num = omni_numval(val);

  if (num != floor(num)) {
    *err = fib_err(pool, "fib: non-integer index: ", val);
    return 1;
  }

  if (0 > num) {
    *err = fib_err(pool, "fib: negative index: ", val);
    return 1;
  }

  *index = (long)num;
  return 0;
}

long fib_num(long index) {
  long prev = 0;
  long cur = 1;
  long step;

  if (0 == index) {
    return 0;
  }

  for (step = 1; step < index; step++) {
    long next = prev + cur;
    prev = cur;
    cur = next;
  }

  return cur;
}

omni_result fib_fib(omni_pool *pool, const omni_json *val) {
  omni_result out;
  long index = 0;

  out.val = NULL;
  out.err = NULL;

  if (0 != fib_index(pool, val, &index, &out.err)) {
    return out;
  }

  out.val = omni_num(pool, (double)fib_num(index));
  return out;
}

omni_result fib_seq(omni_pool *pool, const omni_json *val) {
  omni_result out;
  long count = 0;
  long index;

  out.val = NULL;
  out.err = NULL;

  if (0 != fib_index(pool, val, &count, &out.err)) {
    return out;
  }

  out.val = omni_list(pool);
  for (index = 0; index < count; index++) {
    omni_list_push(out.val, omni_num(pool, (double)fib_num(index)));
  }

  return out;
}

omni_result fib_range(omni_pool *pool, const omni_json *start, const omni_json *end) {
  omni_result out;
  long from = 0;
  long to = 0;
  long index;

  out.val = NULL;
  out.err = NULL;

  if (0 != fib_index(pool, start, &from, &out.err)) {
    return out;
  }

  if (0 != fib_index(pool, end, &to, &out.err)) {
    return out;
  }

  out.val = omni_list(pool);
  for (index = from; index <= to; index++) {
    omni_list_push(out.val, omni_num(pool, (double)fib_num(index)));
  }

  return out;
}

omni_result fib_info(omni_pool *pool, const omni_json *val) {
  omni_result out;
  long index = 0;
  long num;
  char *label;
  char *numtext;
  char *indextext;
  size_t len;

  out.val = NULL;
  out.err = NULL;

  if (0 != fib_index(pool, val, &index, &out.err)) {
    return out;
  }

  num = fib_num(index);

  indextext = omni_numstr(pool, (double)index);
  numtext = omni_numstr(pool, (double)num);

  len = strlen(indextext) + strlen(numtext) + 8;
  label = (char *)omni_pool_alloc(pool, len);
  label[0] = '\0';
  strcat(label, "fib(");
  strcat(label, indextext);
  strcat(label, ")=");
  strcat(label, numtext);

  out.val = omni_map(pool);
  omni_map_set(out.val, "n", omni_num(pool, (double)index));
  omni_map_set(out.val, "val", omni_num(pool, (double)num));
  omni_map_set(out.val, "even", omni_bool(pool, 0 == num % 2));
  omni_map_set(out.val, "prev",
               0 == index ? omni_null(pool) : omni_num(pool, (double)fib_num(index - 1)));
  omni_map_set(out.val, "label", omni_str(pool, label));

  return out;
}
