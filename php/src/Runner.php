<?php

/**
 * Omni: the shared multi-language test runner.
 *
 * Port of the canonical TypeScript implementation
 * (typescript/src/Runner.ts). Behaviour must match, case for case.
 */

declare(strict_types=1);

namespace Voxgig\Omni;

require_once __DIR__ . '/Util.php';

/**
 * A test failure (or a malformed spec). Distinct from errors thrown by the
 * subject under test, which are candidates for an `err` expectation.
 */
class OmniError extends \Exception
{
    public $entry;

    public function __construct(string $message, $entry = null)
    {
        parent::__construct($message);
        $this->entry = $entry;
    }
}

final class Runner
{
    public const NULLMARK = Util::NULLMARK;
    public const UNDEFMARK = Util::UNDEFMARK;
    public const EXISTSMARK = Util::EXISTSMARK;

    /** Load a spec: a path to a JSON file, or an already-parsed value. */
    public static function loadspec($specref)
    {
        if (is_string($specref)) {
            $text = file_get_contents($specref);
            if (false === $text) {
                throw new OmniError('omni: cannot read spec: ' . $specref);
            }
            return json_decode($text, true, 512, JSON_THROW_ON_ERROR);
        }
        return $specref;
    }

    /** Find `primary.<name>`, then `<name>`, then the whole spec. */
    public static function resolvespec(?string $name, $alltests)
    {
        if (null === $name) {
            return $alltests;
        }

        $primary = Util::ismap($alltests) ? ($alltests['primary'] ?? null) : null;
        if (Util::ismap($primary) && null !== ($primary[$name] ?? null)) {
            return $primary[$name];
        }

        if (is_array($alltests) && null !== ($alltests[$name] ?? null)) {
            return $alltests[$name];
        }

        return $alltests;
    }

    /** Build the named clients declared by the spec's DEF.client block. */
    public static function resolveclients(array $provider, $spec, $store): array
    {
        $clients = [];

        $defclient = Util::ismap($spec) && Util::ismap($spec['DEF'] ?? null)
            ? ($spec['DEF']['client'] ?? null) : null;
        if (!Util::ismap($defclient)) {
            return $clients;
        }

        // A spec may define clients that a given test run never references.
        $clientmaker = $provider['client'] ?? null;
        if (null === $clientmaker) {
            return $clients;
        }

        foreach ($defclient as $clientname => $cdef) {
            $copts = Util::clone(
                (Util::ismap($cdef) && Util::ismap($cdef['test'] ?? null)
                    ? ($cdef['test']['options'] ?? null) : null) ?? []
            );

            $injector = $provider['inject'] ?? null;
            if (is_array($store) && null !== $injector) {
                $injector($copts, $store);
            }

            $clients[$clientname] = $clientmaker($copts);
        }

        return $clients;
    }

    public static function resolvesubject(?string $name, array $provider)
    {
        if (null === $name || null === ($provider['subject'] ?? null)) {
            return null;
        }
        return $provider['subject']($name) ?: null;
    }

    public static function resolveflags(?array $flags): array
    {
        $out = null === $flags ? [] : $flags;
        $out['null'] = !isset($out['null']) ? true : (bool) $out['null'];
        return $out;
    }

    /** An entry with no `out` expects a null (or absent) result. */
    public static function resolveentry(array $entry, array $flags): array
    {
        if (null === ($entry['out'] ?? null) && $flags['null']) {
            $entry['out'] = Util::NULLMARK;
        }
        return $entry;
    }

    public static function resolvetestpack(?string $name, array $entry, $subject, array $provider, array $clients): array
    {
        $testpack = ['client' => $provider, 'subject' => $subject];

        if (null !== ($entry['client'] ?? null)) {
            $client = $clients[$entry['client']] ?? null;
            if (null === $client) {
                throw new OmniError('omni: unknown client: ' . $entry['client'], $entry);
            }
            $testpack['client'] = $client;
            $testpack['subject'] = self::resolvesubject($name, $client) ?: $subject;
        }

        return $testpack;
    }

    /** Build the argument list: `ctx`, `args`, or `in`. */
    public static function resolveargs(array &$entry, array $testpack, array $provider): array
    {
        if (array_key_exists('ctx', $entry)) {
            $args = [$entry['ctx']];
        } elseif (array_key_exists('args', $entry)) {
            $args = $entry['args'];
        } else {
            $args = [Util::clone($entry['in'] ?? null)];
        }

        if (array_key_exists('ctx', $entry) || array_key_exists('args', $entry)) {
            if (0 < count($args)) {
                $first = $args[0];
                if (Util::ismap($first)) {
                    $first = Util::clone($first);
                    $contextify = $provider['contextify'] ?? null;
                    if (null !== $contextify) {
                        $first = $contextify($first);
                    }
                    if (is_array($first)) {
                        $first['client'] = $testpack['client'];
                    }
                    $args[0] = $first;
                    $entry['ctx'] = $first;
                }
            }
        }

        return $args;
    }

    /** Nulls become NULLMARK, errors become {name,message}. Always a copy. */
    public static function fixjson($val, ?array $flags = null)
    {
        $donull = (null === $flags || !isset($flags['null'])) ? true : (bool) $flags['null'];
        return self::fixjsonval($val, $donull);
    }

    public static function fixjsonval($val, bool $donull)
    {
        if (null === $val || Util::isabsent($val)) {
            return $donull ? Util::NULLMARK : null;
        }

        if ($val instanceof \Throwable) {
            return self::errify($val);
        }

        if (is_array($val)) {
            $out = [];
            foreach ($val as $key => $subval) {
                $out[$key] = self::fixjsonval($subval, $donull);
            }
            return $out;
        }

        return $val;
    }

    /** The JSON form of an error: always at least {name,message}. */
    public static function errify($err): array
    {
        if ($err instanceof \Throwable) {
            return ['name' => (new \ReflectionClass($err))->getShortName(), 'message' => $err->getMessage()];
        }
        return ['name' => 'Error', 'message' => (string) $err];
    }

    public static function errmessage($err): string
    {
        return $err instanceof \Throwable ? $err->getMessage() : (string) $err;
    }

    /** The label of one entry, for failure messages. */
    public static function entryref(array $flags, int $index, $entry): string
    {
        $label = $flags['name'] ?? 'set';
        $entryid = (is_array($entry) && null !== ($entry['id'] ?? null))
            ? ' (' . $entry['id'] . ')' : '';
        return $label . '[' . $index . ']' . $entryid;
    }

    public static function fail(array $flags, int $index, $entry, string $reason, ?string $expected = null, ?string $actual = null): OmniError
    {
        $msg = 'omni: ' . self::entryref($flags, $index, $entry) . ': ' . $reason;
        if (null !== $expected) {
            $msg .= "\n  expected: " . $expected;
        }
        if (null !== $actual) {
            $msg .= "\n  actual:   " . $actual;
        }
        $msg .= "\n  entry:    " . Util::stringify(self::entrysummary($entry));
        return new OmniError($msg, $entry);
    }

    /** The spec-defined part of an entry (drop runner bookkeeping). */
    public static function entrysummary($entry)
    {
        if (!is_array($entry)) {
            return $entry;
        }
        $out = [];
        foreach ($entry as $key => $val) {
            if (!in_array($key, ['res', 'thrown', 'ctx'], true)) {
                $out[$key] = $val;
            }
        }
        return $out;
    }

    public static function checkresult(array $flags, int $index, array $entry, array $args, $res): void
    {
        $matched = false;

        if (null !== ($entry['err'] ?? null)) {
            throw self::fail(
                $flags,
                $index,
                $entry,
                'expected error did not occur',
                Util::stringify($entry['err']),
                Util::stringify($res)
            );
        }

        if (null !== ($entry['match'] ?? null)) {
            self::match($flags, $index, $entry, $entry['match'], [
                'in' => $entry['in'] ?? null,
                'args' => $args,
                'out' => $entry['res'] ?? null,
                'ctx' => $entry['ctx'] ?? null,
            ]);
            $matched = true;
        }

        $out = $entry['out'] ?? null;

        if (Util::deepequal($res, $out)) {
            return;
        }

        // NOTE: a match with no explicit out is a complete check on its own.
        if ($matched && (Util::NULLMARK === $out || null === $out)) {
            return;
        }

        throw self::fail($flags, $index, $entry, 'result mismatch', Util::stringify($out), Util::stringify($res));
    }

    public static function handleerror(array $flags, int $index, array $entry, \Throwable $err): void
    {
        $entryerr = $entry['err'] ?? null;

        if (null !== $entryerr) {
            if (true === $entryerr || self::matchval($entryerr, self::errmessage($err))) {
                if (null !== ($entry['match'] ?? null)) {
                    self::match($flags, $index, $entry, $entry['match'], [
                        'in' => $entry['in'] ?? null,
                        'out' => $entry['res'] ?? null,
                        'ctx' => $entry['ctx'] ?? null,
                        'err' => self::errify($err),
                    ]);
                }
                return;
            }

            throw self::fail($flags, $index, $entry, 'error mismatch', Util::stringify($entryerr), self::errmessage($err));
        }

        throw self::fail($flags, $index, $entry, 'unexpected error', null, self::errmessage($err));
    }

    /** Check that every leaf of `check` is present, and matches, in `base`. */
    public static function match(array $flags, int $index, array $entry, $check, $base): void
    {
        $cbase = Util::clone($base);

        $at = function (array $path): string {
            return 0 === count($path) ? '<root>' : Util::pathify($path);
        };

        Util::walk(Util::clone($check), function ($_key, $val, $_parent, $path) use ($flags, $index, $entry, $cbase, $at) {
            // An empty container asserts structure that walk would otherwise
            // skip: it visits no leaves inside {} or [], so `match:{out:{}}`
            // used to pass any result. Require the base at this path to be an
            // equal empty container. (The synthetic root wrapper is never
            // empty, so skip it.)
            if (Util::isnode($val) && 0 < count($path) && self::isempty($val)) {
                $baseval = Util::getpath($cbase, $path);
                if (!Util::deepequal($val, $baseval)) {
                    throw self::fail($flags, $index, $entry, 'match failed at ' . $at($path), Util::stringify($val), Util::stringify($baseval));
                }
                return $val;
            }

            if (!Util::isnode($val)) {
                $baseval = Util::getpath($cbase, $path);

                if ($baseval === $val) {
                    return $val;
                }

                // Explicitly absent: satisfied only by a genuinely missing
                // key, never by a present null (the distinction the
                // sentinels exist to keep).
                if (Util::UNDEFMARK === $val) {
                    if (Util::isabsent($baseval)) {
                        return $val;
                    }
                    throw self::fail($flags, $index, $entry, 'expected absent at ' . $at($path), 'absent', Util::stringify($baseval));
                }

                // Explicitly null: satisfied only by a present null.
                if (Util::NULLMARK === $val) {
                    if (null === $baseval || Util::NULLMARK === $baseval) {
                        return $val;
                    }
                    throw self::fail($flags, $index, $entry, 'expected null at ' . $at($path), 'null', Util::stringify($baseval));
                }

                // Explicitly present: any present value, including null.
                if (Util::EXISTSMARK === $val) {
                    if (!Util::isabsent($baseval)) {
                        return $val;
                    }
                    throw self::fail($flags, $index, $entry, 'expected present at ' . $at($path), 'present', 'absent');
                }

                // A concrete expectation never matches a missing key - a
                // match leaf against an absent value must fail, not
                // substring-match the stringified absent value.
                if (Util::isabsent($baseval)) {
                    throw self::fail($flags, $index, $entry, 'match failed at ' . $at($path), Util::stringify($val), 'absent');
                }

                if (!self::matchval($val, $baseval)) {
                    throw self::fail($flags, $index, $entry, 'match failed at ' . $at($path), Util::stringify($val), Util::stringify($baseval));
                }
            }

            return $val;
        });
    }

    /** Is this container empty? */
    public static function isempty($val): bool
    {
        return 0 === count($val);
    }

    /** Match one leaf: /regex/ or case-insensitive substring for strings. */
    public static function matchval($check, $base): bool
    {
        if (Util::deepequal($check, $base)) {
            return true;
        }

        $want = $check;
        if (Util::UNDEFMARK === $want || Util::NULLMARK === $want) {
            $want = null;
        }

        if (null === $want) {
            return null === $base || Util::isabsent($base) || Util::NULLMARK === $base;
        }

        if (is_string($want)) {
            // An empty want is not a wildcard: the empty string is a substring
            // of everything, so `match:{out:""}` (or `err:""`) would accept any
            // value.
            if ('' === $want) {
                return '' === $base;
            }

            $basestr = Util::stringify($base);

            if (1 === preg_match('#^/(.+)/$#s', $want, $rem)) {
                return 1 === preg_match('#' . str_replace('#', '\\#', $rem[1]) . '#', $basestr);
            }

            return false !== stripos($basestr, $want);
        }

        if (is_callable($want)) {
            return true;
        }

        return Util::deepequal($want, $base);
    }

    /** Convert NULLMARK sentinels back into real nulls. */
    public static function nullmodifier($val, $key, &$parent): void
    {
        if (Util::NULLMARK === $val) {
            $parent[$key] = null;
        } elseif (is_string($val)) {
            $parent[$key] = str_replace(Util::NULLMARK, 'null', $val);
        }
    }

    /**
     * Make a runner for a spec file (or spec value) and a provider.
     *
     * Returns a callable: (?string $name, $store) => array with keys
     * spec, runset, runsetflags, subject, client.
     */
    public static function makeRunner($specref, ?array $provider = null): callable
    {
        $alltests = self::loadspec($specref);
        $useprovider = $provider ?? [];

        return function (?string $name = null, $store = null) use ($alltests, $useprovider): array {
            $spec = self::resolvespec($name, $alltests);
            $clients = self::resolveclients($useprovider, $spec, null === $store ? [] : $store);
            $defsubject = self::resolvesubject($name, $useprovider);

            $runsetflags = function ($testspec, ?array $flags, $testsubject = null) use ($name, $useprovider, $clients, $defsubject): void {
                $useflags = self::resolveflags($flags);
                $useflags['name'] = $useflags['name'] ?? ($name ?? 'set');

                $subject = $testsubject ?: $defsubject;
                if (null === $subject) {
                    throw new OmniError('omni: no test subject for: ' . $useflags['name']);
                }

                $testspecmap = self::fixjson($testspec, $useflags);

                if (!Util::ismap($testspecmap) || !Util::islist($testspecmap['set'] ?? null)) {
                    throw new OmniError('omni: test spec has no set: ' . $useflags['name']);
                }

                $testset = $testspecmap['set'];

                foreach ($testset as $index => $entry) {
                    try {
                        $entry = self::resolveentry($entry, $useflags);

                        $testpack = self::resolvetestpack($name, $entry, $subject, $useprovider, $clients);
                        $args = self::resolveargs($entry, $testpack, $useprovider);

                        $res = ($testpack['subject'])(...$args);
                        $res = self::fixjson($res, $useflags);
                        $entry['res'] = $res;

                        self::checkresult($useflags, $index, $entry, $args, $res);
                    } catch (OmniError $omnierr) {
                        throw $omnierr;
                    } catch (\Throwable $err) {
                        self::handleerror($useflags, $index, $entry, $err);
                    }
                }
            };

            $runset = function ($testspec, $testsubject = null) use ($runsetflags): void {
                $runsetflags($testspec, [], $testsubject);
            };

            return [
                'spec' => $spec,
                'runset' => $runset,
                'runsetflags' => $runsetflags,
                'subject' => $defsubject,
                'client' => $useprovider,
            ];
        };
    }
}
