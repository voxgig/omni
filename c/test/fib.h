/* The system under test: a tiny Fibonacci library.
 *
 * Every omni port ships this same library, with the same behaviour and the
 * same error messages, and tests it with the same spec file
 * (spec/fib.json).
 */

#ifndef VOXGIG_OMNI_FIB_H
#define VOXGIG_OMNI_FIB_H

#include "../src/omni.h"

/* Validate a Fibonacci index. Returns 0 on success and sets *index;
 * returns 1 on failure and sets *err (pool-owned). */
int fib_index(omni_pool *pool, const omni_json *val, long *index, const char **err);

/* The nth Fibonacci number: fib(0)=0, fib(1)=1. */
long fib_num(long index);

omni_result fib_fib(omni_pool *pool, const omni_json *val);
omni_result fib_seq(omni_pool *pool, const omni_json *val);
omni_result fib_range(omni_pool *pool, const omni_json *start, const omni_json *end);
omni_result fib_info(omni_pool *pool, const omni_json *val);

#endif /* VOXGIG_OMNI_FIB_H */
