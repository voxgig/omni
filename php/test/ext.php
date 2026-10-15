<?php

/**
 * RUN: php test/ext.php
 * RUN-SOME: php test/ext.php fn
 *
 * The capability suite: spec/ext.json requires ctxargs, fn and wait, and
 * every port that carries them runs it, beside the runner flag `all`.
 */

declare(strict_types=1);

namespace Voxgig\Omni\Test;

use Voxgig\Omni\OmniError;
use Voxgig\Omni\Runner;

require_once __DIR__ . '/../src/Runner.php';
require_once __DIR__ . '/Fib.php';

function specfile(string $name): string
{
    $dir = __DIR__;
    for ($i = 0; $i < 8; $i++) {
        $cand = $dir . '/spec/' . $name;
        if (file_exists($cand)) {
            return $cand;
        }
        $dir = dirname($dir);
    }
    throw new \RuntimeException('omni: spec not found: ' . $name);
}

function fibprovider(): array
{
    $subjects = [
        'fib' => fn($n) => Fib::fib($n),
        'fibseq' => fn($n) => Fib::fibseq($n),
        'fibrange' => fn($s, $e) => Fib::fibrange($s, $e),
        'fibinfo' => fn($n) => Fib::fibinfo($n),
    ];

    return [
        'subject' => fn(string $name) => $subjects[$name] ?? null,
        'contextify' => fn(array $val) => array_merge($val, ['mark' => 'CTX']),
    ];
}

/**
 * The ctxargs subject: the context comes first, and must arrive
 * contextified with its client attached.
 */
function fibshifted(array $ctx, $start, $end): array
{
    if ('CTX' !== ($ctx['mark'] ?? null) || null === ($ctx['client'] ?? null)) {
        throw new \RuntimeException('fib: context not delivered');
    }
    return Fib::fibrange($start + $ctx['shift'], $end + $ctx['shift']);
}

function runner($spec, string $name = 'fib'): array
{
    return (Runner::makeRunner($spec, fibprovider()))($name);
}

function v1(array $requires, array $set): array
{
    return ['OMNI' => ['version' => 1, 'requires' => $requires], 'fib' => ['g' => ['set' => $set]]];
}

function refuses(callable $run, string $pattern): void
{
    try {
        $run();
    } catch (OmniError $err) {
        if (1 !== preg_match($pattern, $err->getMessage())) {
            throw new \RuntimeException('omni: message does not match ' . $pattern . ': ' . $err->getMessage());
        }
        return;
    }
    throw new \RuntimeException('omni: expected OmniError matching ' . $pattern);
}

$only = $argv[1] ?? null;
$pass = 0;
$fail = 0;

function testcase(string $name, callable $body): void
{
    global $only, $pass, $fail;

    if (null !== $only && $name !== $only) {
        return;
    }

    try {
        $body();
        $pass++;
        echo "ok   - $name\n";
    } catch (\Throwable $err) {
        $fail++;
        echo "FAIL - $name\n" . $err->getMessage() . "\n";
    }
}

$fib = fn($n) => Fib::fib($n);
$fibshifted = fn($ctx, $start, $end) => fibshifted($ctx, $start, $end);

$R = runner(specfile('ext.json'));

testcase('capabilities', function () {
    foreach (['ctxargs', 'fn', 'wait'] as $cap) {
        if (!in_array($cap, Runner::CAPABILITIES, true)) {
            throw new \RuntimeException('omni: capability missing: ' . $cap);
        }
    }
});

testcase('ctxargs', fn() => ($R['runset'])($R['spec']['ctxargs'], $fibshifted));
testcase('fn', fn() => ($R['runset'])($R['spec']['fn'], $fib));
testcase('wait', fn() => ($R['runset'])($R['spec']['wait'], $fib));

testcase('a waiting entry that passes fails the set', function () use ($fib) {
    $R = runner(v1(['wait'], [['in' => 5, 'out' => 5, 'wait' => ['cause' => 'gone#1']]]));
    refuses(fn() => ($R['runset'])($R['spec']['g'], $fib), '/\[0\]: stale wait: gone#1/');
});

testcase('the wait flag holds an entry by id', function () use ($fib) {
    $R = runner(v1([], [['id' => 'a', 'in' => 6, 'out' => 9], ['in' => 7, 'out' => 13]]));
    ($R['runsetflags'])($R['spec']['g'], ['wait' => ['a' => ['cause' => 'flag#1']]], $fib);
});

testcase('the wait flag fails when its entry passes', function () use ($fib) {
    $R = runner(v1([], [['id' => 'a', 'in' => 6, 'out' => 8]]));
    refuses(
        fn() => ($R['runsetflags'])($R['spec']['g'], ['wait' => ['a' => ['cause' => 'flag#1']]], $fib),
        '/stale wait: flag#1/'
    );
});

testcase('the wait flag must name an entry', function () use ($fib) {
    $R = runner(v1([], [['id' => 'a', 'in' => 6, 'out' => 8]]));
    refuses(
        fn() => ($R['runsetflags'])($R['spec']['g'], ['wait' => ['zz' => ['cause' => 'c']]], $fib),
        '/wait names no entry: zz/'
    );
});

testcase('a wait needs a cause', function () use ($fib) {
    $R = runner(v1(['wait'], [['in' => 6, 'out' => 9, 'wait' => []]]));
    refuses(fn() => ($R['runset'])($R['spec']['g'], $fib), '/entry wait has no cause/');
});

testcase('wait and fn are unknown fields unless required', function () use ($fib) {
    $W = runner(v1([], [['in' => 6, 'out' => 9, 'wait' => ['cause' => 'c']]]));
    refuses(fn() => ($W['runset'])($W['spec']['g'], $fib), '/unknown entry field: wait/');
    $F = runner(v1([], [['fn' => 'fib', 'in' => 6, 'out' => 8]]));
    refuses(fn() => ($F['runset'])($F['spec']['g'], $fib), '/unknown entry field: fn/');
});

testcase('an unknown fn is a spec error', function () use ($fib) {
    $R = runner(v1(['fn'], [['fn' => 'nope', 'in' => 6, 'out' => 8]]));
    refuses(fn() => ($R['runset'])($R['spec']['g'], $fib), '/unknown fn: nope/');
});

testcase('ctx with args needs ctxargs, and never takes in', function () use ($fibshifted) {
    $N = runner(v1([], [['ctx' => ['shift' => 0], 'args' => [0, 1], 'out' => [0, 1]]]));
    refuses(fn() => ($N['runset'])($N['spec']['g'], $fibshifted), '/more than one of in, args, ctx/');
    $I = runner(v1(['ctxargs'], [['in' => 1, 'ctx' => ['shift' => 0], 'out' => [0]]]));
    refuses(fn() => ($I['runset'])($I['spec']['g'], $fibshifted), '/entry has in beside args or ctx/');
});

testcase('a legacy spec ignores fn and wait', function () use ($fib) {
    $R = runner(['fib' => ['g' => ['set' => [['in' => 6, 'out' => 8, 'fn' => 'nope', 'wait' => ['cause' => 'c']]]]]]);
    ($R['runset'])($R['spec']['g'], $fib);
});

testcase('a raising hook is the entry\'s error, not the set\'s', function () use ($fib) {
    $provider = [
        'subject' => fn($name) => $fib,
        'contextify' => function (array $val) {
            throw new \RuntimeException('contextify boom');
        },
    ];
    $run = fn($spec) => (Runner::makeRunner($spec, $provider))('fib');
    $E = $run(v1([], [['ctx' => ['n' => 6], 'err' => 'contextify boom']]));
    ($E['runset'])($E['spec']['g'], $fib);
    $U = $run(v1([], [['ctx' => ['n' => 6], 'out' => 8]]));
    refuses(fn() => ($U['runset'])($U['spec']['g'], $fib), '/\[0\]: unexpected error\n\s+actual:\s+contextify boom/');
    $W = $run(v1(['wait'], [['ctx' => ['n' => 6], 'out' => 8, 'wait' => ['cause' => 'hook#1']]]));
    ($W['runset'])($W['spec']['g'], $fib);
    $F = (Runner::makeRunner(v1(['fn'], [['fn' => 'boom', 'in' => 6, 'err' => 'subject boom']]), [
        'subject' => function (string $name) use ($fib) {
            if ('boom' === $name) {
                throw new \RuntimeException('subject boom');
            }
            return $fib;
        },
    ]))('fib');
    ($F['runset'])($F['spec']['g'], $fib);
});

testcase('a waiting entry holds a hook\'s error raised before the subject starts', function () use ($fib) {
    $provider = [
        'subject' => function (string $name) use ($fib) {
            if ('boom' === $name) {
                throw new \RuntimeException('subject boom');
            }
            return 'fib' === $name ? $fib : null;
        },
    ];
    $run = fn($spec) => (Runner::makeRunner($spec, $provider))('fib');
    $H = $run(v1(['fn', 'wait'], [['fn' => 'boom', 'in' => 6, 'out' => 8, 'wait' => ['cause' => 'hook#2']]]));
    ($H['runset'])($H['spec']['g'], $fib);
    $S = $run(v1(['fn', 'wait'], [['fn' => 'boom', 'in' => 6, 'err' => 'subject boom', 'wait' => ['cause' => 'hook#3']]]));
    refuses(fn() => ($S['runset'])($S['spec']['g'], $fib), '/\[0\]: stale wait: hook#3/');
});

testcase('fn needs no default subject, but an entry without fn does', function () use ($fib) {
    $provider = ['subject' => fn(string $name) => 'fibx' === $name ? $fib : null];
    $R = (Runner::makeRunner(v1(['fn'], [['fn' => 'fibx', 'in' => 6, 'out' => 8]]), $provider))('fib');
    ($R['runset'])($R['spec']['g']);
    $N = (Runner::makeRunner(v1(['fn'], [['fn' => 'fibx', 'in' => 6, 'out' => 8], ['in' => 6, 'out' => 8]]), $provider))('fib');
    refuses(fn() => ($N['runset'])($N['spec']['g']), '/^omni: no test subject for: fib$/D');
    $L = (Runner::makeRunner(v1([], [['in' => 6, 'out' => 8]]), $provider))('fib');
    refuses(fn() => ($L['runset'])($L['spec']['g']), '/^omni: no test subject for: fib$/D');
});

testcase('a wait is found by an id the entry owns, never an inherited one', function () use ($fib) {
    $R = runner(v1([], [['id' => 'constructor', 'in' => 6, 'out' => 8], ['id' => 'toString', 'in' => 7, 'out' => 13]]));
    ($R['runset'])($R['spec']['g'], $fib);
    ($R['runsetflags'])($R['spec']['g'], ['wait' => []], $fib);
});

testcase('all reports every failure at once', function () use ($fib) {
    $R = runner(v1([], [['in' => 5, 'out' => 6], ['in' => 6, 'out' => 8], ['in' => 7, 'out' => 14]]));
    refuses(
        fn() => ($R['runsetflags'])($R['spec']['g'], ['all' => true], $fib),
        '/^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch/s'
    );
    refuses(fn() => ($R['runset'])($R['spec']['g'], $fib), '/^omni: fib\[0\]: result mismatch/');
});


echo "\n$pass passed, $fail failed\n";
exit(0 === $fail ? 0 : 1);
