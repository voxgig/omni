<?php

/**
 * The system under test: a tiny Fibonacci library.
 *
 * Every omni port ships this same library, with the same behaviour and the
 * same error messages, and tests it with the same spec file
 * (spec/fib.json).
 */

declare(strict_types=1);

namespace Voxgig\Omni\Test;

use Voxgig\Omni\Util;

require_once __DIR__ . '/../src/Util.php';

final class Fib
{
    /** Validate a Fibonacci index. The spec matches on these messages. */
    public static function fibindex($val): int
    {
        if (!Util::isnum($val)) {
            throw new \RuntimeException('fib: not a number: ' . Util::stringify($val));
        }

        if (0.0 !== fmod((float) $val, 1.0)) {
            throw new \RuntimeException('fib: non-integer index: ' . Util::stringify($val));
        }

        if ($val < 0) {
            throw new \RuntimeException('fib: negative index: ' . Util::stringify($val));
        }

        return (int) $val;
    }

    /** The nth Fibonacci number: fib(0)=0, fib(1)=1. */
    public static function fib($n): int
    {
        $index = self::fibindex($n);

        if (0 === $index) {
            return 0;
        }

        $prev = 0;
        $cur = 1;

        for ($i = 1; $i < $index; $i++) {
            $next = $prev + $cur;
            $prev = $cur;
            $cur = $next;
        }

        return $cur;
    }

    /** The first n Fibonacci numbers. */
    public static function fibseq($n): array
    {
        $count = self::fibindex($n);
        $out = [];
        for ($i = 0; $i < $count; $i++) {
            $out[] = self::fib($i);
        }
        return $out;
    }

    /** The Fibonacci numbers from index start to index end, inclusive. */
    public static function fibrange($start, $end): array
    {
        $from = self::fibindex($start);
        $to = self::fibindex($end);
        $out = [];
        for ($i = $from; $i <= $to; $i++) {
            $out[] = self::fib($i);
        }
        return $out;
    }

    /**
     * A description of the nth Fibonacci number. `prev` is null at index 0,
     * which exercises the runner's null handling.
     */
    public static function fibinfo($n): array
    {
        $index = self::fibindex($n);
        $val = self::fib($index);

        return [
            'n' => $index,
            'val' => $val,
            'even' => 0 === $val % 2,
            'prev' => 0 === $index ? null : self::fib($index - 1),
            'label' => 'fib(' . Util::stringify($index) . ')=' . Util::stringify($val),
        ];
    }
}
