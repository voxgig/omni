// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

using System;
using System.Collections.Generic;

namespace Voxgig.Omni.Test
{
    public static class Fib
    {
        /// <summary>Validate a Fibonacci index. The spec matches on these messages.</summary>
        public static long FibIndex(object val)
        {
            if (!Util.IsNum(val))
            {
                throw new ArgumentException("fib: not a number: " + Util.Stringify(val));
            }

            double num = Util.ToNum(val);

            if (num != Math.Truncate(num))
            {
                throw new ArgumentException("fib: non-integer index: " + Util.Stringify(val));
            }

            if (0 > num)
            {
                throw new ArgumentException("fib: negative index: " + Util.Stringify(val));
            }

            return (long)num;
        }

        /// <summary>The nth Fibonacci number: fib(0)=0, fib(1)=1.</summary>
        public static long FibNum(long index)
        {
            if (0 == index)
            {
                return 0;
            }

            long prev = 0;
            long cur = 1;

            for (long step = 1; step < index; step++)
            {
                long next = prev + cur;
                prev = cur;
                cur = next;
            }

            return cur;
        }

        public static object FibOf(object n) => FibNum(FibIndex(n));

        /// <summary>The first n Fibonacci numbers.</summary>
        public static object FibSeq(object n)
        {
            long count = FibIndex(n);
            var outlist = new List<object>();
            for (long index = 0; index < count; index++)
            {
                outlist.Add(FibNum(index));
            }
            return outlist;
        }

        /// <summary>The Fibonacci numbers from index start to index end, inclusive.</summary>
        public static object FibRange(object start, object end)
        {
            long from = FibIndex(start);
            long to = FibIndex(end);
            var outlist = new List<object>();
            for (long index = from; index <= to; index++)
            {
                outlist.Add(FibNum(index));
            }
            return outlist;
        }

        /// <summary>
        /// A description of the nth Fibonacci number. `prev` is null at index 0,
        /// which exercises the runner's null handling.
        /// </summary>
        public static object FibInfo(object n)
        {
            long index = FibIndex(n);
            long val = FibNum(index);

            return new Dictionary<string, object>
            {
                ["n"] = index,
                ["val"] = val,
                ["even"] = 0 == val % 2,
                ["prev"] = 0 == index ? null : (object)FibNum(index - 1),
                ["label"] = "fib(" + Util.NumStr(index) + ")=" + Util.NumStr(val),
            };
        }
    }
}
