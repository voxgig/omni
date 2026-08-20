# Drop-in replacement for the in-situ test runner in the voxgig/struct
# repository (`python/tests/runner.py`).
#
# struct's own runner and omni's runner implement the same spec format;
# this module exposes omni behind struct's exact runner API, so a struct
# port switches over by changing one import:
#
#   -from runner import makeRunner, nullModifier
#   +from omni import makeRunner, nullModifier
#
# where `omni` is a small local-checkout resolver in the port's test
# directory. Everything else - the corpus, the SDK, the test file - is
# unchanged. This is the Python peer of javascript/compat/struct.js.

import inspect
import os
from typing import Any, Callable

from ..util import islist
from ..runner import (
    EXISTSMARK,
    NULLMARK,
    UNDEFMARK,
    makeRunner as omni_makeRunner,
    nullmodifier,
)

OMNIDIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def callerdir() -> str:
    """struct passes a test-file path relative to the module that loads the
    runner, so resolve it the same way: the first stack frame outside the
    omni package is the caller."""
    for frame in inspect.stack():
        filename = os.path.abspath(frame.filename)
        if not filename.startswith(OMNIDIR):
            return os.path.dirname(filename)
    return os.getcwd()


class Provider(dict):
    """An omni provider that is also attribute-addressable.

    omni reads a provider as a mapping (`provider.get('subject')`), while
    struct's test files reach through the returned client as an object
    (`client.utility().struct`). A dict subclass with attribute access
    satisfies both, so neither side has to change.
    """

    def __getattr__(self, name: str) -> Any:
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name) from None


def structprovider(sdk: Any) -> 'Provider':
    """Wrap a struct SDK client as an omni provider. The wrapper also
    forwards `utility()` and `tester()`, so test code that reaches through
    the returned client keeps working unchanged."""

    def subject(name: str):
        # struct resolves a subject from the utility, or from utility.struct.
        utility = sdk.utility()
        found = getattr(utility, name, None)
        if found is None:
            found = getattr(getattr(utility, 'struct', None), name, None)
        return found

    def client(options: Any):
        # A DEF.client entry becomes another SDK instance.
        return structprovider(sdk.tester(options))

    def contextify(val: Any):
        # struct's SDK supplies its own context wrapper.
        utility = sdk.utility()
        hook = getattr(utility, 'contextify', None)
        ctx = hook(val) if callable(hook) else val
        if ctx is not None and not isinstance(ctx, (str, int, float, bool)):
            try:
                ctx.utility = utility
            except AttributeError:
                pass
        return ctx

    def inject(options: Any, store: Any):
        # Client options may reference the runner store.
        structutils = getattr(sdk.utility(), 'struct', None)
        injector = getattr(structutils, 'inject', None)
        if callable(injector):
            return injector(options, store)
        return options

    return Provider({
        'subject': subject,
        'client': client,
        'contextify': contextify,
        'inject': inject,
        'utility': sdk.utility,
        'tester': sdk.tester,
        'sdk': sdk,
    })


def zeroargs(testspec: Any) -> Any:
    """Reproduce struct's python runner for the no-argument entries.

    struct's corpus has seventeen entries carrying no `in`, `args` or `ctx`.
    They mean "call the subject with no arguments": each sits beside an
    `in: null` sibling with a DIFFERENT expected result, and canonical
    JavaScript agrees - typify() is 1073741824 where typify(null) is 4194432.

    struct's own runners never agreed on that. python's resolve_args left
    `args` empty and so called with zero arguments; typescript, php and go
    passed one absent value; ruby passed its UNDEF sentinel; lua filtered
    the entries out entirely. omni's generic rule is the typescript one
    (DOCS 2.2: `args = [clone(entry.in)]`), which JavaScript cannot tell
    apart from a zero-argument call but python can.

    A compat shim exists to keep a port's behaviour identical across the
    swap, so this restores python's reading by rewriting those entries to
    an explicit empty `args` - in memory, for this port only. The corpus on
    disk is untouched, which matters: an authored `args: []` shortens the
    argument list, and that breaks the fixed-arity adapters (it panics
    omni/go and aborts omni/rust outright). Python is not one of those.

    The discrimination is made HERE, on the entry, rather than on the
    argument value, because under `{'null': False}` an authored `in: null`
    also arrives as None - indistinguishable from an absent `in` once the
    argument list has been built.

    The general fix is the absence model: spell the state as
    `in: '__UNDEF__'` and let each port map it to its own no-value. That
    needs the marker honoured in input position first, so it rides a spec
    version bump rather than this shim.
    """
    if not isinstance(testspec, dict) or not islist(testspec.get('set')):
        return testspec

    entries = testspec['set']
    if not any(
        isinstance(e, dict) and not ({'in', 'args', 'ctx'} & set(e.keys()))
        for e in entries
    ):
        return testspec

    patched = []
    for entry in entries:
        if isinstance(entry, dict) and not ({'in', 'args', 'ctx'} & set(entry.keys())):
            entry = dict(entry)
            entry['args'] = []
        patched.append(entry)

    testspec = dict(testspec)
    testspec['set'] = patched
    return testspec


def makeRunner(testfile: str, client: Any) -> Callable:
    """struct's makeRunner(testfile, client) signature, backed by omni."""
    specpath = (
        testfile
        if os.path.isabs(testfile)
        else os.path.join(callerdir(), testfile)
    )
    provider = structprovider(client)
    runner = omni_makeRunner(specpath, provider)

    def structrunner(name: str, store: Any = None) -> dict:
        runpack = runner(name, {} if store is None else store)
        omni_runset = runpack['runset']
        omni_runsetflags = runpack['runsetflags']

        def runset(testspec, testsubject=None):
            return omni_runset(zeroargs(testspec), testsubject)

        def runsetflags(testspec, flags=None, testsubject=None):
            return omni_runsetflags(zeroargs(testspec), flags, testsubject)

        return {
            'spec': runpack['spec'],
            'runset': runset,
            'runsetflags': runsetflags,
            'subject': runpack['subject'],
            'client': provider,
        }

    return structrunner


nullModifier = nullmodifier

__all__ = [
    'EXISTSMARK',
    'NULLMARK',
    'UNDEFMARK',
    'Provider',
    'makeRunner',
    'nullModifier',
    'structprovider',
]
