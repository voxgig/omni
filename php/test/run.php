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
use Voxgig\Omni\Util;

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
 * `contextify` marks the map, so the context group can prove the hook ran.
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
        'contextify' => fn(array $val) => array_merge($val, ['mark' => 'CTX']),
    ];
}

/**
 * The context-group subject: reports what the runner delivered - the
 * contextify mark and the attached client - as plain data, so the spec can
 * pin both with an ordinary `out` comparison in every port.
 */
function fibctx(array $ctx): array
{
    return [
        'n' => $ctx['n'] ?? null,
        'val' => Fib::fib($ctx['n'] ?? null),
        'mark' => $ctx['mark'] ?? null,
        'hasclient' => null !== ($ctx['client'] ?? null),
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
$fibctxsubject = fn($ctx) => fibctx($ctx);

// Returns the sentinel spelling as ordinary data, to prove __UNDEF__ (absent)
// is not satisfied by a subject that literally returns "__UNDEF__".
$undefsubject = fn($n) => ['a' => '__UNDEF__'];

/** Derive fib's error code from its message. */
function fiberrcode(string $message): string
{
    if (str_contains($message, 'negative index')) { return 'fib_negative'; }
    if (str_contains($message, 'non-integer')) { return 'fib_noninteger'; }
    if (str_contains($message, 'not a number')) { return 'fib_notanumber'; }
    return 'fib_unknown';
}

/**
 * The same provider, plus the `errify` hook: fib's errors gain a CODE.
 *
 * A SECOND runner rather than a hook on `fibprovider`, so that the `error`
 * group keeps exercising the DEFAULT errify.
 */
function fibcodedprovider(): array
{
    return array_merge(fibprovider(0), [
        'errify' => function ($err): array {
            $message = $err instanceof \Throwable ? $err->getMessage() : (string) $err;
            return ['name' => 'Error', 'message' => $message, 'code' => fiberrcode($message)];
        },
    ]);
}

$R = (Runner::makeRunner(specfile('fib.json'), fibprovider(0)))('fib');
$RC = (Runner::makeRunner(specfile('fib.json'), fibcodedprovider()))('fib');
$spec = $R['spec'];
$runset = $R['runset'];
$runsetflags = $R['runsetflags'];

testcase('basic', fn() => $runset($spec['basic'], $fib));
testcase('seq', fn() => $runset($spec['seq'], $fibseq));
testcase('range', fn() => $runset($spec['range'], $fibrange));
testcase('info', fn() => $runset($spec['info'], $fibinfo));
testcase('nulls', fn() => $runsetflags($spec['nulls'], ['null' => false], $fibinfo));
testcase('error', fn() => $runset($spec['error'], $fib));
testcase('errcode', fn() => ($RC['runset'])($RC['spec']['errcode'], $fib));
testcase('match', fn() => $runset($spec['match'], $fib));
testcase('matchinfo', fn() => $runset($spec['matchinfo'], $fibinfo));
testcase('client', fn() => $runset($spec['client'], $fib));
testcase('context', fn() => $runset($spec['context'], $fibctxsubject));

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
const BADSPEC = [
    'fib' => [
        'wrongout' => ['set' => [['in' => 5, 'out' => 5], ['in' => 6, 'out' => 999]]],
        'wrongerr' => ['set' => [['in' => 1, 'err' => 'never happens']]],
        'wrongmatch' => ['set' => [['in' => 6, 'match' => ['out' => 999]]]],
        // __UNDEF__ asserts the key is absent, so it must not be satisfied
        // by a subject returning the literal string "__UNDEF__" as data.
        'wrongundef' => ['set' => [['in' => 6, 'match' => ['out' => ['a' => '__UNDEF__']]]]],
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
testcase('__UNDEF__ does not match the literal string "__UNDEF__"', fn() => expectfail('wrongundef', $undefsubject));
testcase('detects absent key', fn() => expectfail('missing', $fibinfo));
testcase('a concrete match leaf does not match a missing key', fn() => expectfail('matchabsent', $fibinfo));
testcase('__UNDEF__ does not match a present null', fn() => expectfail('undefonnull', $fibinfo));
testcase('__NULL__ does not match an absent key', fn() => expectfail('nullonabsent', $fibinfo));
testcase('an empty-string match leaf is not a wildcard', fn() => expectfail('emptystr', $fibinfo));

/** Expect makeRunner() itself to refuse the spec, message containing $want. */
function expectloaderror($spec, string $want): void
{
    try {
        Runner::makeRunner($spec);
    } catch (OmniError $err) {
        if (false === strpos($err->getMessage(), $want)) {
            throw new \RuntimeException('omni: message missing [' . $want . ']: ' . $err->getMessage());
        }
        return;
    }
    throw new \RuntimeException('omni: expected OmniError loading spec');
}

/** Expect one runset() call against $spec['fib'][$group] to fail, message containing $want. */
function expectrunerror($spec, string $group, callable $subject, string $want): void
{
    $bad = (Runner::makeRunner($spec))('fib');
    try {
        ($bad['runset'])($bad['spec'][$group], $subject);
    } catch (OmniError $err) {
        if (false === strpos($err->getMessage(), $want)) {
            throw new \RuntimeException('omni: message missing [' . $want . ']: ' . $err->getMessage());
        }
        return;
    }
    throw new \RuntimeException('omni: expected OmniError for set: ' . $group);
}

testcase('rejects an unsupported spec version', fn() => expectloaderror(
    ['OMNI' => ['version' => 99], 'fib' => ['g' => ['set' => []]]],
    'unsupported spec version'
));

testcase('rejects an unknown required capability', fn() => expectloaderror(
    ['OMNI' => ['version' => 1, 'requires' => ['nosuchfeature']], 'fib' => ['g' => ['set' => []]]],
    'unsupported capability'
));

testcase('rejects a malformed version block', fn() => expectloaderror(
    ['OMNI' => ['version' => 'one'], 'fib' => ['g' => ['set' => []]]],
    'malformed OMNI'
));

testcase('strict: an unknown entry field fails instead of passing vacuously', fn() => expectrunerror(
    ['OMNI' => ['version' => 1], 'fib' => ['g' => ['set' => [['in' => 6, 'matches' => ['out' => 999]]]]]],
    'g',
    $fibinfo,
    'unknown entry field: matches'
));

testcase('strict: more than one of in, args, ctx fails', fn() => expectrunerror(
    ['OMNI' => ['version' => 1], 'fib' => ['g' => ['set' => [['in' => 5, 'args' => [5], 'out' => 5]]]]],
    'g',
    $fib,
    'more than one of in, args, ctx'
));

testcase('strict: err together with out fails', fn() => expectrunerror(
    ['OMNI' => ['version' => 1], 'fib' => ['g' => ['set' => [['in' => -1, 'err' => true, 'out' => 5]]]]],
    'g',
    $fib,
    'both err and out'
));

testcase('strict: a null id fails even under null-normalisation', fn() => expectrunerror(
    ['OMNI' => ['version' => 1], 'fib' => ['g' => ['set' => [['in' => 1, 'out' => 1, 'id' => null]]]]],
    'g',
    $fib,
    'entry id is not a string'
));

testcase('strict: an empty set fails unless marked empty', function () use ($fib) {
    $bad = (Runner::makeRunner([
        'OMNI' => ['version' => 1],
        'fib' => ['g' => ['set' => []], 'h' => ['set' => [], 'empty' => true]],
    ]))('fib');

    try {
        ($bad['runset'])($bad['spec']['g'], $fib);
    } catch (OmniError $err) {
        if (false === strpos($err->getMessage(), 'empty test set')) {
            throw new \RuntimeException('omni: message missing [empty test set]: ' . $err->getMessage());
        }
        ($bad['runset'])($bad['spec']['h'], $fib);
        return;
    }
    throw new \RuntimeException('omni: expected OmniError for set: g');
});

testcase('a legacy spec (no OMNI block) stays lenient', function () use ($fib) {
    $legacy = (Runner::makeRunner([
        'fib' => ['g' => ['set' => [['in' => 6, 'matches' => ['out' => 999], 'out' => 8]]]],
    ]))('fib');
    ($legacy['runset'])($legacy['spec']['g'], $fib);
});

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

/**
 * deepequal is structural, not IEEE: NaN equals NaN. Nothing in spec/fib.json
 * can pin that - the spec is JSON, and JSON has no NaN literal - so it is
 * pinned here instead.
 *
 * The two NaNs MUST come from two different expressions. A test written with
 * one NaN on both sides can be answered by an identity or same-value
 * shortcut and prove nothing about the number branch of deepequal.
 */
function expectequal($a, $b, bool $want, string $what): void
{
    $got = Util::deepequal($a, $b);
    if ($got !== $want) {
        throw new \RuntimeException(
            'omni: deepequal(' . $what . '): expected ' . ($want ? 'true' : 'false')
            . ', actual ' . ($got ? 'true' : 'false')
        );
    }
}

$nan1 = fdiv(0.0, 0.0);
$nan2 = INF - INF;

testcase('deepequal: the two NaNs come from two different expressions', function () use ($nan1, $nan2) {
    if (!is_nan($nan1) || !is_nan($nan2)) {
        throw new \RuntimeException('omni: both values must be NaN');
    }
    // PHP floats are values, not objects, so there is no identity fast-path
    // for deepequal to take: plain === already separates these two NaNs, and
    // this pins that, so the assertions below can only pass structurally.
    if ($nan1 === $nan2) {
        throw new \RuntimeException('omni: the two NaNs must not compare identical');
    }
});

testcase('deepequal: NaN equals NaN', fn() => expectequal($nan1, $nan2, true, 'NaN, NaN'));
testcase('deepequal: NaN equals NaN inside a list', fn() => expectequal([$nan1], [$nan2], true, '[NaN], [NaN]'));
testcase('deepequal: NaN equals NaN inside a map', fn() => expectequal(['x' => $nan1], ['x' => $nan2], true, '{x:NaN}, {x:NaN}'));
testcase('deepequal: an integer equals the same float', fn() => expectequal(1, 1.0, true, '1, 1.0'));
testcase('deepequal: NaN does not equal a real number', fn() => expectequal($nan1, 1.0, false, 'NaN, 1.0'));
testcase('deepequal: a bool is never a number', fn() => expectequal(true, 1, false, 'true, 1'));
testcase('deepequal: different numbers are not equal', fn() => expectequal(1, 2, false, '1, 2'));


echo "\n$pass passed, $fail failed\n";
exit(0 === $fail ? 0 : 1);
