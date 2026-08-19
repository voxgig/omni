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
        return {
            'spec': runpack['spec'],
            'runset': runpack['runset'],
            'runsetflags': runpack['runsetflags'],
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
