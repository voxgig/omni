<?php

/**
 * Drop-in replacement for the in-situ test runner in the voxgig/struct
 * repository (`php/tests/Runner.php`).
 *
 * struct's own runner and omni's runner implement the same spec format;
 * this class exposes omni behind struct's exact runner API, so the port
 * switches over by changing one require. Everything else - the corpus,
 * the SDK, the test files - is unchanged. This is the PHP peer of
 * javascript/compat/struct.js, python/voxgig_omni/compat/struct.py,
 * ruby/lib/voxgig_omni/compat/struct.rb and go/compat/struct.
 *
 * The shim never imports voxgig/struct. Everything it needs from the port
 * it reaches through the SDK client it is handed.
 */

declare(strict_types=1);

namespace Voxgig\Omni\Compat;

use Voxgig\Omni\Absent;
use Voxgig\Omni\Runner;
use Voxgig\Omni\Util;

require_once __DIR__ . '/../src/Runner.php';

final class Struct
{
    public const NULLMARK = Util::NULLMARK;
    public const UNDEFMARK = Util::UNDEFMARK;
    public const EXISTSMARK = Util::EXISTSMARK;

    /** Root of omni's PHP port, used to skip its own frames when resolving a caller-relative path. */
    private const OMNIDIR = __DIR__ . '/..';

    /** The entry keys that supply an argument list. An entry with none of them is implicit. */
    private const ARGKEYS = ['in', 'args', 'ctx'];

    /**
     * struct's makeRunner(testfile, client) signature, backed by omni.
     */
    public static function makeRunner(string $testfile, $client): callable
    {
        $specpath = self::abspath($testfile) ? $testfile : self::callerdir() . DIRECTORY_SEPARATOR . $testfile;

        $provider = self::structprovider($client);
        $sentinel = self::structundef($client);
        $runner = Runner::makeRunner($specpath, $provider);

        return function (?string $name = null, $store = null) use ($runner, $provider, $sentinel): array {
            $runpack = $runner($name, null === $store ? [] : $store);

            $omniflags = $runpack['runsetflags'];

            $runsetflags = function ($testspec, ?array $flags = [], $testsubject = null) use ($omniflags, $sentinel): void {
                $omniflags(
                    self::undefargs($testspec, $sentinel),
                    $flags ?? [],
                    self::wrapsubject($testsubject, $sentinel)
                );
            };

            $runset = function ($testspec, $testsubject = null) use ($runsetflags): void {
                $runsetflags($testspec, [], $testsubject);
            };

            return [
                'spec' => $runpack['spec'],
                'runset' => $runset,
                'runsetflags' => $runsetflags,
                'subject' => $runpack['subject'],
                'client' => $provider,
            ];
        };
    }

    /** Convert NULLMARK sentinels back into real nulls. struct's own signature. */
    public static function nullModifier($val, $key, array &$parent): void
    {
        Runner::nullmodifier($val, $key, $parent);
    }

    /**
     * Wrap a struct SDK client as an omni provider.
     */
    public static function structprovider($client): array
    {
        $provider = [];

        // struct resolves a subject off the utility, or off utility->struct.
        $provider['subject'] = function (string $name) use ($client) {
            $utility = self::utility($client);
            $found = self::lookup($utility, $name);

            if (null === $found) {
                $structutils = self::lookup($utility, 'struct');
                if (null !== $structutils) {
                    $found = self::lookup($structutils, $name);
                }
            }

            return self::wrapsubject($found, self::structundef($client));
        };

        // A DEF.client entry becomes another SDK instance.
        $provider['client'] = function ($options) use ($client) {
            return self::structprovider($client->test($options ?? []));
        };

        // struct's runner hands both the client AND the utility to the context;
        // omni's resolveargs only installs `client`, so `utility` is added here.
        $provider['contextify'] = function ($val) use ($client) {
            $utility = self::utility($client);

            $ctx = $val;
            $contextify = self::lookup($utility, 'contextify');
            if (null !== $contextify && is_callable($contextify)) {
                $ctx = $contextify($val);
            }

            if (is_array($ctx)) {
                $ctx['utility'] = $utility;
            }

            return $ctx;
        };

        // Client options may reference the runner store.
        $provider['inject'] = function (&$options, $store) use ($client) {
            $structutils = self::lookup(self::utility($client), 'struct');
            if (null === $structutils) {
                return $options;
            }
            return $structutils->inject($options, $store);
        };

        $provider['sdk'] = $client;

        return $provider;
    }

    /** The SDK's utility, however the client spells it. */
    private static function utility($client)
    {
        if (is_object($client) && method_exists($client, 'utility')) {
            return $client->utility();
        }
        if (is_array($client) && isset($client['sdk'])) {
            return self::utility($client['sdk']);
        }
        return null;
    }

    /**
     * Read `name` off a container the way struct's runner does, without
     * calling it. A property holding a closure IS the subject; a method
     * (including one reached through __call) is bound rather than invoked.
     */
    private static function lookup($container, string $name)
    {
        if (null === $container) {
            return null;
        }

        if (is_object($container)) {
            if (isset($container->{$name})) {
                return $container->{$name};
            }
            if (method_exists($container, $name) || method_exists($container, '__call')) {
                return [$container, $name];
            }
            return null;
        }

        if (is_array($container)) {
            return $container[$name] ?? null;
        }

        return null;
    }

    /**
     * struct's PHP port has no `undefined`, so it models absence with its own
     * `Struct::undef()` stdClass singleton, while omni models it with
     * `Voxgig\Omni\Absent`. Reached through the SDK, so the shim still never
     * imports struct.
     */
    public static function structundef($client)
    {
        $structutils = self::lookup(self::utility($client), 'struct');
        if (null === $structutils) {
            return null;
        }

        if (!is_object($structutils)) {
            return null;
        }

        try {
            $undef = $structutils->undef();
            return is_object($undef) ? $undef : null;
        } catch (\Throwable $err) {
            return null;
        }
    }

    /**
     * Normalise a result the way struct's own runner did, and translate its
     * absence sentinel into omni's.
     *
     * Two things happen here, and both are needed for the same reason - the
     * two runners disagree about what a PHP value means:
     *
     * 1. **Objects become maps.** struct's `fixJSON` ended in
     *    `json_decode(json_encode($fixed), true)`, so a `stdClass` result
     *    arrived at the comparison as an associative array. omni's `fixjson`
     *    walks arrays only and passes objects through untouched, because its
     *    own value model has no plain-object case. Left alone, struct's SDK
     *    returning `(object)['zed' => ...]` is compared against the corpus's
     *    `{"zed": ...}` map and fails - and the failure message is itself an
     *    "Object of class stdClass could not be converted to string" error,
     *    because stringify cannot render it.
     *
     * 2. **struct's no-value becomes omni's.** struct models absence with a
     *    `stdClass` singleton from `Struct::undef()`; omni models it with
     *    `Voxgig\Omni\Absent`. Translating here keeps the two absence models
     *    from meeting, and lets omni's `fixjson` turn it into NULLMARK.
     *
     * The sentinel is checked BEFORE the object walk, since it is itself a
     * `stdClass` and would otherwise be flattened into an empty map.
     * Throwables are left for omni's `errify`.
     */
    public static function structfix($val, $sentinel)
    {
        if (null !== $sentinel && $val === $sentinel) {
            return Absent::mark();
        }

        if (is_array($val)) {
            $out = [];
            foreach ($val as $key => $subval) {
                $out[$key] = self::structfix($subval, $sentinel);
            }
            return $out;
        }

        if (is_object($val) && !($val instanceof \Throwable) && !Util::isabsent($val)) {
            $out = [];
            foreach (get_object_vars($val) as $key => $subval) {
                $out[$key] = self::structfix($subval, $sentinel);
            }
            return $out;
        }

        return $val;
    }

    /** A subject whose result speaks omni's value model. */
    public static function wrapsubject($subject, $sentinel)
    {
        if (null === $subject || !is_callable($subject)) {
            return $subject;
        }

        return function (...$args) use ($subject, $sentinel) {
            return self::structfix($subject(...$args), $sentinel);
        };
    }

    /**
     * Reproduce struct's PHP reading for the no-argument entries.
     *
     * struct's corpus has seventeen entries carrying no `in`, `args` or `ctx`.
     * They mean "call the subject with no arguments": each sits beside an
     * `in: null` sibling, and in `minor/typify` that sibling expects a
     * different result - `typify()` is 1073741824 where `typify(null)` is
     * 4194432.
     *
     * PHP cannot spell that as zero arguments: its functions are not
     * variadic-defaulted, so `Struct::typify()` raises ArgumentCountError.
     * struct's PHP suite passes `Struct::undef()` instead, which typifies as
     * T_noval - the canonical reading. omni's generic rule is
     * `args = [clone(entry.in)]` (DOCS 2.2), and a missing `in` clones to
     * `null` in this port, which would collapse the two.
     *
     * So those entries are rewritten to an explicit `args` of one sentinel -
     * in memory, for this port only. The corpus on disk is untouched. The
     * sentinel is the one already resolved off the SDK by `structundef`, so
     * the shim still never imports struct; with no such constant the spec is
     * returned unchanged and the generic rule applies.
     *
     * The discrimination is made HERE, on the entry, rather than on the
     * argument value: once the argument list is built an authored `in: null`
     * is indistinguishable from an absent `in`.
     *
     * This is a compat measure, not the model - see register 4.12 and
     * doc/design/absence-model.md. The general fix is to spell the state as
     * `in: '__UNDEF__'` and let each port map it to its own no-value.
     */
    public static function undefargs($testspec, $sentinel)
    {
        if (null === $sentinel || !Util::ismap($testspec)) {
            return $testspec;
        }

        $set = $testspec['set'] ?? null;
        if (!Util::islist($set)) {
            return $testspec;
        }

        $found = false;
        foreach ($set as $entry) {
            if (self::noargs($entry)) {
                $found = true;
                break;
            }
        }
        if (!$found) {
            return $testspec;
        }

        $patched = [];
        foreach ($set as $entry) {
            if (self::noargs($entry)) {
                $entry['args'] = [$sentinel];
            }
            $patched[] = $entry;
        }

        $out = $testspec;
        $out['set'] = $patched;
        return $out;
    }

    /** An entry that supplies no argument list at all. */
    private static function noargs($entry): bool
    {
        if (!Util::ismap($entry)) {
            return false;
        }
        foreach (self::ARGKEYS as $key) {
            if (array_key_exists($key, $entry)) {
                return false;
            }
        }
        return true;
    }

    /** Windows drive letters count, so this is not just a leading separator. */
    private static function abspath(string $path): bool
    {
        return 1 === preg_match('/^(\/|[A-Za-z]:[\/\\\\])/', $path);
    }

    /**
     * struct passes a spec path relative to the file that loads the runner,
     * so resolve it the same way: the first stack frame outside omni is the
     * caller.
     */
    private static function callerdir(): string
    {
        $omnidir = realpath(self::OMNIDIR);

        foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS) as $frame) {
            $file = $frame['file'] ?? null;
            if (null === $file) {
                continue;
            }
            $full = realpath($file);
            if (false === $full) {
                continue;
            }
            if (false === $omnidir || !str_starts_with($full, $omnidir . DIRECTORY_SEPARATOR)) {
                return dirname($full);
            }
        }

        return getcwd() ?: '.';
    }
}
