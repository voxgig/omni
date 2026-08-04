<?php

/**
 * RUN: php test/run.php
 * RUN-SOME: php test/run.php basic
 *
 * The Fibonacci conformance suite: every omni port runs this same set of
 * groups, from the same spec/fib.json, against the same fib library.
 *
 * No third-party test framework: a failing omni check throws OmniError, so
 * any host framework (PHPUnit included) reports it as a failure. This
 * harness keeps `make test` dependency-free.
 */

declare(strict_types=1);

namespace Voxgig\Omni\Test;

use Voxgig\Omni\OmniError;
use Voxgig\Omni\Runner;

require_once __DIR__ . '/../src/Runner.php';
require_once __DIR__ . '/Fib.php';

/** Find the shared spec directory by walking up from this file. */
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

/**
 * The provider hosts the system under test. `shift` offsets the Fibonacci
 * index, so that a client-specific subject is observably different.
 */
function fibprovider(int $shift): array
{
    $subjects = [
        'fib' => fn($n) => Fib::fib(is_int($n) || is_float($n) ? $n + $shift : $n),
        'fibseq' => fn($n) => Fib::fibseq($n),
        'fibrange' => fn($s, $e) => Fib::fibrange($s, $e),
        'fibinfo' => fn($n) => Fib::fibinfo($n),
    ];

    return [
        'subject' => fn(string $name) => $subjects[$name] ?? null,
        'client' => fn(array $options) => fibprovider((int) ($options['shift'] ?? 0)),
    ];
}

$only = $argv[1] ?? null;
$pass = 0;
$fail = 0;

/** Run one named test case, reporting pass or fail. */
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
$fibseq = fn($n) => Fib::fibseq($n);
$fibrange = fn($s, $e) => Fib::fibrange($s, $e);
$fibinfo = fn($n) => Fib::fibinfo($n);

$R = (Runner::makeRunner(specfile('fib.json'), fibprovider(0)))('fib');
$spec = $R['spec'];
$runset = $R['runset'];
$runsetflags = $R['runsetflags'];

testcase('basic', fn() => $runset($spec['basic'], $fib));
testcase('seq', fn() => $runset($spec['seq'], $fibseq));
testcase('range', fn() => $runset($spec['range'], $fibrange));
testcase('info', fn() => $runset($spec['info'], $fibinfo));
testcase('nulls', fn() => $runsetflags($spec['nulls'], ['null' => false], $fibinfo));
testcase('error', fn() => $runset($spec['error'], $fib));
testcase('match', fn() => $runset($spec['match'], $fib));
testcase('matchinfo', fn() => $runset($spec['matchinfo'], $fibinfo));
testcase('client', fn() => $runset($spec['client'], $fib));

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
const BADSPEC = [
    'fib' => [
        'wrongout' => ['set' => [['in' => 5, 'out' => 5], ['in' => 6, 'out' => 999]]],
        'wrongerr' => ['set' => [['in' => 1, 'err' => 'never happens']]],
        'wrongmatch' => ['set' => [['in' => 6, 'match' => ['out' => 999]]]],
        'missing' => ['set' => [['in' => 6, 'match' => ['out' => ['nope' => '__EXISTS__']]]]],
        // A concrete match leaf against a missing key must fail, not
        // substring-match the stringified absent value.
        'matchabsent' => ['set' => [['in' => 6, 'match' => ['out' => ['nope' => 'fine']]]]],
        // __UNDEF__ (absent) must not be satisfied by a present null.
        'undefonnull' => ['set' => [['in' => 0, 'match' => ['out' => ['prev' => '__UNDEF__']]]]],
        // __NULL__ (present null) must not be satisfied by an absent key.
        'nullonabsent' => ['set' => [['in' => 6, 'match' => ['out' => ['nope' => '__NULL__']]]]],
        // An empty-string match leaf is not a wildcard.
        'emptystr' => ['set' => [['in' => 6, 'match' => ['out' => ['label' => '']]]]],
    ],
];

function expectfail(string $setname, callable $subject): void
{
    $bad = (Runner::makeRunner(BADSPEC))('fib');
    try {
        ($bad['runset'])($bad['spec'][$setname], $subject);
    } catch (OmniError $err) {
        return;
    }
    throw new \RuntimeException('omni: expected OmniError for set: ' . $setname);
}

testcase('detects wrong result', fn() => expectfail('wrongout', $fib));
testcase('detects missing error', fn() => expectfail('wrongerr', $fib));
testcase('detects failed match', fn() => expectfail('wrongmatch', $fib));
testcase('detects absent key', fn() => expectfail('missing', $fibinfo));
testcase('a concrete match leaf does not match a missing key', fn() => expectfail('matchabsent', $fibinfo));
testcase('__UNDEF__ does not match a present null', fn() => expectfail('undefonnull', $fibinfo));
testcase('__NULL__ does not match an absent key', fn() => expectfail('nullonabsent', $fibinfo));
testcase('an empty-string match leaf is not a wildcard', fn() => expectfail('emptystr', $fibinfo));

testcase('reports entry index and id', function () use ($fib) {
    $bad = (Runner::makeRunner([
        'fib' => ['g' => ['set' => [
            ['in' => 1, 'out' => 1],
            ['id' => 'x#2', 'in' => 2, 'out' => 42],
        ]]],
    ]))('fib');

    try {
        ($bad['runset'])($bad['spec']['g'], $fib);
    } catch (OmniError $err) {
        $msg = $err->getMessage();
        foreach (['fib[1] (x#2)', 'expected: 42', 'actual:   1'] as $want) {
            if (false === strpos($msg, $want)) {
                throw new \RuntimeException('omni: message missing [' . $want . ']: ' . $msg);
            }
        }
        return;
    }
    throw new \RuntimeException('omni: expected OmniError');
});

echo "\n$pass passed, $fail failed\n";
exit(0 === $fail ? 0 : 1);
