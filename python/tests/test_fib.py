# RUN: python3 -m unittest discover -s tests
# RUN-SOME: python3 -m unittest discover -s tests -k basic
#
# The Fibonacci conformance suite: every omni port runs this same set of
# groups, from the same spec/fib.json, against the same fib library.

import os
import unittest

from voxgig_omni import OmniError, makeRunner

try:
    from .fib import fib, fibinfo, fibrange, fibseq
except ImportError:
    from fib import fib, fibinfo, fibrange, fibseq


def specfile(name):
    """Find the shared spec directory by walking up from this file."""
    directory = os.path.dirname(os.path.abspath(__file__))
    for _i in range(8):
        cand = os.path.join(directory, 'spec', name)
        if os.path.exists(cand):
            return cand
        directory = os.path.dirname(directory)
    raise FileNotFoundError('omni: spec not found: ' + name)


def fibprovider(shift):
    """The provider hosts the system under test.

    `shift` offsets the Fibonacci index, so that a client-specific subject
    is observably different.
    """
    subjects = {
        'fib': lambda n: fib(n + shift if isinstance(n, (int, float)) else n),
        'fibseq': fibseq,
        'fibrange': fibrange,
        'fibinfo': fibinfo,
    }

    return {
        'subject': lambda name: subjects.get(name),
        'client': lambda options: fibprovider(options.get('shift') or 0),
    }


runner = makeRunner(specfile('fib.json'), fibprovider(0))
R = runner('fib')

spec = R['spec']
runset = R['runset']
runsetflags = R['runsetflags']


class TestFib(unittest.TestCase):

    def test_basic(self):
        runset(spec['basic'], fib)

    def test_seq(self):
        runset(spec['seq'], fibseq)

    def test_range(self):
        runset(spec['range'], fibrange)

    def test_info(self):
        runset(spec['info'], fibinfo)

    def test_nulls(self):
        runsetflags(spec['nulls'], {'null': False}, fibinfo)

    def test_error(self):
        runset(spec['error'], fib)

    def test_match(self):
        runset(spec['match'], fib)

    def test_matchinfo(self):
        runset(spec['matchinfo'], fibinfo)

    def test_client(self):
        runset(spec['client'], fib)


BADSPEC = {
    'fib': {
        'wrongout': {'set': [{'in': 5, 'out': 5}, {'in': 6, 'out': 999}]},
        'wrongerr': {'set': [{'in': 1, 'err': 'never happens'}]},
        'wrongmatch': {'set': [{'in': 6, 'match': {'out': 999}}]},
        'missing': {'set': [{'in': 6, 'match': {'out': {'nope': '__EXISTS__'}}}]},
        # A concrete match leaf against a missing key must fail, not
        # substring-match the stringified absent value.
        'matchabsent': {'set': [{'in': 6, 'match': {'out': {'nope': 'fine'}}}]},
        # __UNDEF__ (absent) must not be satisfied by a present null.
        'undefonnull': {'set': [{'in': 0, 'match': {'out': {'prev': '__UNDEF__'}}}]},
        # __NULL__ (present null) must not be satisfied by an absent key.
        'nullonabsent': {'set': [{'in': 6, 'match': {'out': {'nope': '__NULL__'}}}]},
        # An empty container asserts an empty container, not "anything".
        'emptymatch': {'set': [{'in': 6, 'match': {'out': {}}}]},
        # An empty-string match leaf is not a wildcard.
        'emptystr': {'set': [{'in': 6, 'match': {'out': {'label': ''}}}]},
    }
}


class TestRunner(unittest.TestCase):
    """The runner must fail when the subject is wrong."""

    def expectfail(self, setname, subject, flags=None):
        bad = makeRunner(BADSPEC)('fib')
        with self.assertRaises(OmniError):
            bad['runsetflags'](bad['spec'][setname], flags or {}, subject)

    def test_detects_wrong_result(self):
        self.expectfail('wrongout', fib)

    def test_detects_missing_error(self):
        self.expectfail('wrongerr', fib)

    def test_detects_failed_match(self):
        self.expectfail('wrongmatch', fib)

    def test_detects_absent_key(self):
        self.expectfail('missing', fibinfo)

    def test_concrete_match_leaf_does_not_match_missing_key(self):
        self.expectfail('matchabsent', fibinfo)

    def test_undef_does_not_match_present_null(self):
        self.expectfail('undefonnull', fibinfo)

    def test_null_does_not_match_absent_key(self):
        self.expectfail('nullonabsent', fibinfo)

    def test_empty_match_container_is_not_vacuous(self):
        self.expectfail('emptymatch', fibinfo)

    def test_empty_string_match_leaf_is_not_a_wildcard(self):
        self.expectfail('emptystr', fibinfo)

    def test_reports_entry_index_and_id(self):
        bad = makeRunner(
            {'fib': {'g': {'set': [{'in': 1, 'out': 1}, {'id': 'x#2', 'in': 2, 'out': 42}]}}}
        )('fib')

        with self.assertRaises(OmniError) as caught:
            bad['runset'](bad['spec']['g'], fib)

        msg = str(caught.exception)
        self.assertIn('fib[1] (x#2)', msg)
        self.assertIn('expected: 42', msg)
        self.assertIn('actual:   1', msg)


if __name__ == '__main__':
    unittest.main()
