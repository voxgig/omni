# RUN: python3 -m unittest discover -s tests -k Ext
#
# The capability suite: spec/ext.json requires ctxargs, fn and wait, and
# every port that carries them runs it, beside the runner flag `all`.

import os
import re
import unittest

from voxgig_omni import CAPABILITIES, OmniError, makeRunner

try:
    from .fib import fib, fibinfo, fibrange, fibseq
except ImportError:
    from fib import fib, fibinfo, fibrange, fibseq


def specfile(name):
    directory = os.path.dirname(os.path.abspath(__file__))
    for _i in range(8):
        cand = os.path.join(directory, 'spec', name)
        if os.path.exists(cand):
            return cand
        directory = os.path.dirname(directory)
    raise FileNotFoundError('omni: spec not found: ' + name)


def fibprovider():
    subjects = {'fib': fib, 'fibseq': fibseq, 'fibrange': fibrange, 'fibinfo': fibinfo}
    return {
        'subject': lambda name: subjects.get(name),
        'contextify': lambda val: {**val, 'mark': 'CTX'},
    }


def fibshifted(ctx, start, end):
    """The ctxargs subject: the context comes first, and must arrive
    contextified with its client attached."""
    if ctx.get('mark') != 'CTX' or ctx.get('client') is None:
        raise ValueError('fib: context not delivered')
    return fibrange(start + ctx['shift'], end + ctx['shift'])


def runner(spec, name='fib'):
    return makeRunner(spec, fibprovider())(name)


def v1(requires, entries):
    return {'OMNI': {'version': 1, 'requires': requires}, 'fib': {'g': {'set': entries}}}


class TestExt(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.R = runner(specfile('ext.json'))

    def test_capabilities(self):
        for cap in ('ctxargs', 'fn', 'wait'):
            self.assertIn(cap, CAPABILITIES)

    def test_ctxargs(self):
        self.R['runset'](self.R['spec']['ctxargs'], fibshifted)

    def test_fn(self):
        self.R['runset'](self.R['spec']['fn'], fib)

    def test_wait(self):
        self.R['runset'](self.R['spec']['wait'], fib)


class TestExtRunner(unittest.TestCase):

    def refuses(self, run, pattern):
        with self.assertRaises(OmniError) as caught:
            run()
        self.assertRegex(str(caught.exception), re.compile(pattern, re.S))

    def test_waiting_entry_that_passes_fails(self):
        R = runner(v1(['wait'], [{'in': 5, 'out': 5, 'wait': {'cause': 'gone#1'}}]))
        self.refuses(lambda: R['runset'](R['spec']['g'], fib), r'\[0\]: stale wait: gone#1')

    def test_wait_flag_holds_by_id(self):
        R = runner(v1([], [{'id': 'a', 'in': 6, 'out': 9}, {'in': 7, 'out': 13}]))
        R['runsetflags'](R['spec']['g'], {'wait': {'a': {'cause': 'flag#1'}}}, fib)

    def test_wait_flag_fails_when_entry_passes(self):
        R = runner(v1([], [{'id': 'a', 'in': 6, 'out': 8}]))
        self.refuses(lambda: R['runsetflags'](R['spec']['g'], {'wait': {'a': {'cause': 'flag#1'}}}, fib),
                     r'stale wait: flag#1')

    def test_wait_flag_must_name_entry(self):
        R = runner(v1([], [{'id': 'a', 'in': 6, 'out': 8}]))
        self.refuses(lambda: R['runsetflags'](R['spec']['g'], {'wait': {'zz': {'cause': 'c'}}}, fib),
                     r'wait names no entry: zz')

    def test_wait_needs_cause(self):
        R = runner(v1(['wait'], [{'in': 6, 'out': 9, 'wait': {}}]))
        self.refuses(lambda: R['runset'](R['spec']['g'], fib), r'entry wait has no cause')

    def test_wait_and_fn_unknown_unless_required(self):
        W = runner(v1([], [{'in': 6, 'out': 9, 'wait': {'cause': 'c'}}]))
        self.refuses(lambda: W['runset'](W['spec']['g'], fib), r'unknown entry field: wait')
        F = runner(v1([], [{'fn': 'fib', 'in': 6, 'out': 8}]))
        self.refuses(lambda: F['runset'](F['spec']['g'], fib), r'unknown entry field: fn')

    def test_unknown_fn_is_spec_error(self):
        R = runner(v1(['fn'], [{'fn': 'nope', 'in': 6, 'out': 8}]))
        self.refuses(lambda: R['runset'](R['spec']['g'], fib), r'unknown fn: nope')

    def test_ctx_with_args_needs_ctxargs(self):
        N = runner(v1([], [{'ctx': {'shift': 0}, 'args': [0, 1], 'out': [0, 1]}]))
        self.refuses(lambda: N['runset'](N['spec']['g'], fibshifted), r'more than one of in, args, ctx')
        I = runner(v1(['ctxargs'], [{'in': 1, 'ctx': {'shift': 0}, 'out': [0]}]))
        self.refuses(lambda: I['runset'](I['spec']['g'], fibshifted), r'entry has in beside args or ctx')

    def test_legacy_spec_ignores_fn_and_wait(self):
        R = runner({'fib': {'g': {'set': [{'in': 6, 'out': 8, 'fn': 'nope', 'wait': {'cause': 'c'}}]}}})
        R['runset'](R['spec']['g'], fib)

    def test_raising_hook_is_entry_error(self):
        def boom(_val):
            raise ValueError('contextify boom')

        provider = {'subject': lambda _name: fib, 'contextify': boom}

        def run(spec):
            return makeRunner(spec, provider)('fib')

        E = run(v1([], [{'ctx': {'n': 6}, 'err': 'contextify boom'}]))
        E['runset'](E['spec']['g'], fib)
        U = run(v1([], [{'ctx': {'n': 6}, 'out': 8}]))
        self.refuses(lambda: U['runset'](U['spec']['g'], fib),
                     r'\[0\]: unexpected error\n\s+actual:\s+contextify boom')
        W = run(v1(['wait'], [{'ctx': {'n': 6}, 'out': 8, 'wait': {'cause': 'hook#1'}}]))
        W['runset'](W['spec']['g'], fib)

        def subject(name):
            if 'boom' == name:
                raise ValueError('subject boom')
            return fib

        F = makeRunner(v1(['fn'], [{'fn': 'boom', 'in': 6, 'err': 'subject boom'}]),
                       {'subject': subject})('fib')
        F['runset'](F['spec']['g'], fib)

    def test_waiting_entry_holds_prestart_hook_error(self):
        def subject(name):
            if 'boom' == name:
                raise ValueError('subject boom')
            return fib if 'fib' == name else None

        def run(spec):
            return makeRunner(spec, {'subject': subject})('fib')

        H = run(v1(['fn', 'wait'], [{'fn': 'boom', 'in': 6, 'out': 8, 'wait': {'cause': 'hook#2'}}]))
        H['runset'](H['spec']['g'], fib)
        S = run(v1(['fn', 'wait'], [{'fn': 'boom', 'in': 6, 'err': 'subject boom', 'wait': {'cause': 'hook#3'}}]))
        self.refuses(lambda: S['runset'](S['spec']['g'], fib), r'\[0\]: stale wait: hook#3')

    def test_fn_needs_no_default_subject(self):
        provider = {'subject': lambda name: fib if 'fibx' == name else None}

        def run(spec):
            return makeRunner(spec, provider)('fib')

        R = run(v1(['fn'], [{'fn': 'fibx', 'in': 6, 'out': 8}]))
        R['runset'](R['spec']['g'])
        N = run(v1(['fn'], [{'fn': 'fibx', 'in': 6, 'out': 8}, {'in': 6, 'out': 8}]))
        self.refuses(lambda: N['runset'](N['spec']['g']), r'^omni: no test subject for: fib$')
        L = run(v1([], [{'in': 6, 'out': 8}]))
        self.refuses(lambda: L['runset'](L['spec']['g']), r'^omni: no test subject for: fib$')

    def test_wait_found_by_own_id(self):
        R = runner(v1([], [{'id': 'constructor', 'in': 6, 'out': 8}, {'id': 'toString', 'in': 7, 'out': 13}]))
        R['runset'](R['spec']['g'], fib)
        R['runsetflags'](R['spec']['g'], {'wait': {}}, fib)

    def test_all_reports_every_failure(self):
        R = runner(v1([], [{'in': 5, 'out': 6}, {'in': 6, 'out': 8}, {'in': 7, 'out': 14}]))
        self.refuses(lambda: R['runsetflags'](R['spec']['g'], {'all': True}, fib),
                     r'^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch')
        self.refuses(lambda: R['runset'](R['spec']['g'], fib), r'^omni: fib\[0\]: result mismatch')


if __name__ == '__main__':
    unittest.main()
