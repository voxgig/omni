"""Omni: the shared multi-language test runner.

Port of the canonical TypeScript implementation
(typescript/src/Runner.ts). Behaviour must match, case for case.
"""

import json
import re
from typing import Any, Callable, Optional

from .util import (
    ABSENT,
    EXISTSMARK,
    NULLMARK,
    UNDEFMARK,
    clone,
    deepequal,
    getpath,
    islist,
    ismap,
    isnode,
    pathify,
    stringify,
    walk,
)


class OmniError(AssertionError):
    """A test failure (or a malformed spec).

    Distinct from errors raised by the subject under test, which are
    candidates for an `err` expectation.
    """

    def __init__(self, message: str, entry: Any = None):
        super().__init__(message)
        self.entry = entry


def loadspec(specref: Any) -> Any:
    """Load a spec: a path to a JSON file, or an already-parsed object."""
    if isinstance(specref, str):
        with open(specref, encoding='utf-8') as spechandle:
            return json.load(spechandle)
    return specref


def resolvespec(name: Optional[str], alltests: Any) -> Any:
    """Find `primary.<name>`, then `<name>`, then the whole spec."""
    if name is None:
        return alltests

    primary = alltests.get('primary') if ismap(alltests) else None
    if ismap(primary) and primary.get(name) is not None:
        return primary[name]

    if ismap(alltests) and alltests.get(name) is not None:
        return alltests[name]

    return alltests


def resolveclients(provider: Any, spec: Any, store: Any) -> dict:
    """Build the named clients declared by the spec's DEF.client block."""
    clients: dict = {}

    defclient = spec.get('DEF', {}).get('client') if ismap(spec) else None
    if not ismap(defclient):
        return clients

    # A spec may define clients that a given test run never references.
    clientmaker = provider.get('client')
    if clientmaker is None:
        return clients

    for clientname, cdef in defclient.items():
        copts = clone((cdef.get('test', {}).get('options') if ismap(cdef) else None) or {})

        injector = provider.get('inject')
        if ismap(store) and injector is not None:
            injector(copts, store)

        clients[clientname] = clientmaker(copts)

    return clients


def resolvesubject(name: Optional[str], provider: Any) -> Optional[Callable]:
    if name is None or provider.get('subject') is None:
        return None
    return provider['subject'](name) or None


def resolveflags(flags: Optional[dict]) -> dict:
    out = {} if flags is None else dict(flags)
    out['null'] = True if out.get('null') is None else bool(out['null'])
    return out


def resolveentry(entry: dict, flags: dict) -> dict:
    """An entry with no `out` expects a null (or absent) result."""
    if entry.get('out') is None and flags['null']:
        entry['out'] = NULLMARK
    return entry


def resolvetestpack(name, entry, subject, provider, clients) -> dict:
    testpack = {'client': provider, 'subject': subject}

    if entry.get('client') is not None:
        client = clients.get(entry['client'])
        if client is None:
            raise OmniError('omni: unknown client: ' + str(entry['client']), entry)
        testpack['client'] = client
        testpack['subject'] = resolvesubject(name, client) or subject

    return testpack


def resolveargs(entry: dict, testpack: dict, provider: Any) -> list:
    """Build the argument list: `ctx`, `args`, or `in`."""
    if 'ctx' in entry:
        args = [entry['ctx']]
    elif 'args' in entry:
        args = entry['args']
    else:
        args = [clone(entry.get('in'))]

    if ('ctx' in entry or 'args' in entry) and len(args) > 0:
        first = args[0]
        if ismap(first):
            first = clone(first)
            contextify = provider.get('contextify')
            if contextify is not None:
                first = contextify(first)
            args[0] = first
            entry['ctx'] = first
            if ismap(first):
                first['client'] = testpack['client']

    return args


def fixjson(val: Any, flags: Optional[dict] = None) -> Any:
    """Nulls become NULLMARK, errors become {name,message}. Always a copy."""
    donull = True if flags is None or flags.get('null') is None else bool(flags['null'])
    return fixjsonval(val, donull)


def fixjsonval(val: Any, donull: bool) -> Any:
    if val is None or val is ABSENT:
        return NULLMARK if donull else None

    if isinstance(val, BaseException):
        return errify(val)

    if islist(val):
        return [fixjsonval(entry, donull) for entry in val]

    if ismap(val):
        return {key: fixjsonval(subval, donull) for key, subval in val.items()}

    return val


def errify(err: Any) -> dict:
    """The JSON form of an error: always at least {name,message}."""
    if isinstance(err, BaseException):
        out = {key: val for key, val in vars(err).items() if not key.startswith('_')}
        out['name'] = type(err).__name__
        out['message'] = str(err)
        return out
    return {'name': 'Error', 'message': str(err)}


def errmessage(err: Any) -> str:
    return str(err)


def entryref(flags: dict, index: int, entry: Any) -> str:
    """The label of one entry, for failure messages."""
    label = flags.get('name') or 'set'
    entryid = ''
    if ismap(entry) and entry.get('id') is not None:
        entryid = ' (' + str(entry['id']) + ')'
    return '%s[%d]%s' % (label, index, entryid)


def fail(flags, index, entry, reason, expected=None, actual=None) -> OmniError:
    msg = 'omni: ' + entryref(flags, index, entry) + ': ' + reason
    if expected is not None:
        msg += '\n  expected: ' + expected
    if actual is not None:
        msg += '\n  actual:   ' + actual
    msg += '\n  entry:    ' + stringify(entrysummary(entry))
    return OmniError(msg, entry)


def entrysummary(entry: Any) -> Any:
    """The spec-defined part of an entry (drop runner bookkeeping)."""
    if not ismap(entry):
        return entry
    return {key: val for key, val in entry.items() if key not in ('res', 'thrown', 'ctx')}


def checkresult(flags: dict, index: int, entry: dict, args: list, res: Any) -> None:
    matched = False

    if entry.get('err') is not None:
        raise fail(
            flags,
            index,
            entry,
            'expected error did not occur',
            stringify(entry['err']),
            stringify(res),
        )

    if entry.get('match') is not None:
        match(
            flags,
            index,
            entry,
            entry['match'],
            {
                'in': entry.get('in'),
                'args': args,
                'out': entry.get('res'),
                'ctx': entry.get('ctx'),
            },
        )
        matched = True

    out = entry.get('out')

    if deepequal(res, out):
        return

    # NOTE: a match with no explicit out is a complete check on its own.
    if matched and (out == NULLMARK or out is None):
        return

    raise fail(flags, index, entry, 'result mismatch', stringify(out), stringify(res))


def handleerror(flags: dict, index: int, entry: dict, err: BaseException) -> None:
    entry['thrown'] = err

    entryerr = entry.get('err')

    if entryerr is not None:
        if entryerr is True or matchval(entryerr, errmessage(err)):
            if entry.get('match') is not None:
                match(
                    flags,
                    index,
                    entry,
                    entry['match'],
                    {
                        'in': entry.get('in'),
                        'out': entry.get('res'),
                        'ctx': entry.get('ctx'),
                        'err': errify(err),
                    },
                )
            return

        raise fail(flags, index, entry, 'error mismatch', stringify(entryerr), errmessage(err))

    raise fail(flags, index, entry, 'unexpected error', None, errmessage(err))


def match(flags: dict, index: int, entry: dict, check: Any, base: Any) -> None:
    """Check that every leaf of `check` is present, and matches, in `base`."""
    cbase = clone(base)

    def at(path):
        return '<root>' if len(path) == 0 else pathify(path)

    def apply(_key, val, _parent, path):
        # An empty container in the check is a structural placeholder: walk
        # visits no leaves inside {} or [], so it asserts nothing about the
        # base. (struct's corpus relies on this "map is here, contents
        # unchecked" behaviour, so omni stays a faithful drop-in.)
        if not isnode(val):
            baseval = getpath(cbase, path)

            if baseval is val:
                return val

            # Explicitly absent: satisfied only by a genuinely missing key,
            # never by a present null (the distinction the sentinels exist
            # to keep).
            if val == UNDEFMARK:
                if baseval is ABSENT:
                    return val
                raise fail(flags, index, entry, 'expected absent at ' + at(path),
                           'absent', stringify(baseval))

            # Explicitly null: satisfied only by a present null.
            if val == NULLMARK:
                if baseval is None or baseval == NULLMARK:
                    return val
                raise fail(flags, index, entry, 'expected null at ' + at(path),
                           'null', stringify(baseval))

            # Explicitly present: any present value, including null.
            if val == EXISTSMARK:
                if baseval is not ABSENT:
                    return val
                raise fail(flags, index, entry, 'expected present at ' + at(path),
                           'present', 'absent')

            # A concrete expectation never matches a missing key - a match leaf
            # against an absent value must fail, not substring-match "None".
            if baseval is ABSENT:
                raise fail(flags, index, entry, 'match failed at ' + at(path),
                           stringify(val), 'absent')

            if not matchval(val, baseval):
                raise fail(flags, index, entry, 'match failed at ' + at(path),
                           stringify(val), stringify(baseval))

        return val

    walk(clone(check), apply)


def matchval(check: Any, base: Any) -> bool:
    """Match one leaf: /regex/ or case-insensitive substring for strings."""
    if check is base:
        return True

    if deepequal(check, base):
        return True

    want = check
    if want == UNDEFMARK or want == NULLMARK:
        want = None

    if want is None:
        return base is None or base is ABSENT or base == NULLMARK

    if isinstance(want, str):
        # An empty want is not a wildcard: the empty string is a substring of
        # everything, so `match:{out:""}` (or `err:""`) would accept any value.
        if want == '':
            return base == ''

        basestr = stringify(base)

        rem = re.match(r'^/(.+)/$', want, re.DOTALL)
        if rem:
            return re.search(rem.group(1), basestr) is not None

        return want.lower() in basestr.lower()

    if callable(want):
        return True

    return deepequal(want, base)


def nullmodifier(val, key, parent, *_rest) -> None:
    """Convert NULLMARK sentinels back into real nulls."""
    if val == NULLMARK:
        parent[key] = None
    elif isinstance(val, str):
        parent[key] = val.replace(NULLMARK, 'null')


def makeRunner(specref: Any, provider: Any = None) -> Callable:
    """Make a runner for a spec file (or spec object) and a provider."""
    alltests = loadspec(specref)
    useprovider = provider or {}

    def runner(name: Optional[str] = None, store: Any = None) -> dict:
        spec = resolvespec(name, alltests)
        clients = resolveclients(useprovider, spec, {} if store is None else store)
        defsubject = resolvesubject(name, useprovider)

        def runsetflags(testspec: Any, flags: Optional[dict], testsubject: Callable = None) -> None:
            useflags = resolveflags(flags)
            useflags['name'] = useflags.get('name') or name or 'set'

            subject = testsubject or defsubject
            if subject is None:
                raise OmniError('omni: no test subject for: ' + str(useflags['name']))

            testspecmap = fixjson(testspec, useflags)

            if not ismap(testspecmap) or not islist(testspecmap.get('set')):
                raise OmniError('omni: test spec has no set: ' + str(useflags['name']))

            testset = testspecmap['set']

            for index, entry in enumerate(testset):
                try:
                    entry = resolveentry(entry, useflags)

                    testpack = resolvetestpack(name, entry, subject, useprovider, clients)
                    args = resolveargs(entry, testpack, useprovider)

                    res = testpack['subject'](*args)
                    res = fixjson(res, useflags)
                    entry['res'] = res

                    checkresult(useflags, index, entry, args, res)

                except OmniError:
                    raise
                except Exception as err:  # noqa: BLE001 - subject errors are data
                    handleerror(useflags, index, entry, err)

        def runset(testspec: Any, testsubject: Callable = None) -> None:
            return runsetflags(testspec, {}, testsubject)

        return {
            'spec': spec,
            'runset': runset,
            'runsetflags': runsetflags,
            'subject': defsubject,
            'client': useprovider,
        }

    return runner


__all__ = [
    'EXISTSMARK',
    'NULLMARK',
    'UNDEFMARK',
    'OmniError',
    'errify',
    'fixjson',
    'loadspec',
    'makeRunner',
    'match',
    'matchval',
    'nullmodifier',
    'resolvespec',
]
