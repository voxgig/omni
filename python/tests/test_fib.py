# RUN: python3 -m unittest discover -s tests
# RUN-SOME: python3 -m unittest discover -s tests -k basic
#
# The Fibonacci conformance suite: every omni port runs this same set of
# groups, from the same spec/fib.json, against the same fib library.

import os
import unittest

from voxgig_omni import OmniError, deepequal, makeRunner

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
    is observably different. `contextify` marks the map, so the context
    group can prove the hook ran.
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
        'contextify': lambda val: {**val, 'mark': 'CTX'},
    }


def fibctx(ctx):
    """The context-group subject: reports what the runner delivered - the
    contextify mark and the attached client - as plain data, so the spec
    can pin both with an ordinary `out` comparison in every port.
    """
    return {
        'n': ctx['n'],
        'val': fib(ctx['n']),
        'mark': ctx.get('mark'),
        'hasclient': ctx.get('client') is not None,
    }


def fibundefliteral(_n):
    """A subject that returns the sentinel's own literal as ordinary data.

    `__UNDEF__` here is a plain string result, not a missing key, so a
    `match` of `__UNDEF__` (which asserts absence) must fail against it.
    """
    return {'a': '__UNDEF__'}


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

    def test_context(self):
        runset(spec['context'], fibctx)


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
        # An empty-string match leaf is not a wildcard.
        'emptystr': {'set': [{'in': 6, 'match': {'out': {'label': ''}}}]},
        # __UNDEF__ (absent) must not be satisfied by a subject returning
        # the literal string "__UNDEF__" as ordinary data.
        'wrongundef': {'set': [{'in': 6, 'match': {'out': {'a': '__UNDEF__'}}}]},
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

    def test_undef_does_not_match_the_literal_undef_string(self):
        self.expectfail('wrongundef', fibundefliteral)

    def test_null_does_not_match_absent_key(self):
        self.expectfail('nullonabsent', fibinfo)

    def test_empty_string_match_leaf_is_not_a_wildcard(self):
        self.expectfail('emptystr', fibinfo)

    def test_rejects_an_unsupported_spec_version(self):
        with self.assertRaises(OmniError) as caught:
            makeRunner({'OMNI': {'version': 99}, 'fib': {'g': {'set': []}}})
        self.assertIn('unsupported spec version', str(caught.exception))

    def test_rejects_an_unknown_required_capability(self):
        with self.assertRaises(OmniError) as caught:
            makeRunner(
                {'OMNI': {'version': 1, 'requires': ['nosuchfeature']}, 'fib': {'g': {'set': []}}}
            )
        self.assertIn('unsupported capability', str(caught.exception))

    def test_rejects_a_malformed_version_block(self):
        with self.assertRaises(OmniError) as caught:
            makeRunner({'OMNI': {'version': 'one'}, 'fib': {'g': {'set': []}}})
        self.assertIn('malformed OMNI', str(caught.exception))

    def test_strict_an_unknown_entry_field_fails_instead_of_passing_vacuously(self):
        bad = makeRunner(
            {'OMNI': {'version': 1}, 'fib': {'g': {'set': [{'in': 6, 'matches': {'out': 999}}]}}}
        )('fib')
        with self.assertRaises(OmniError) as caught:
            bad['runset'](bad['spec']['g'], fibinfo)
        self.assertIn('unknown entry field: matches', str(caught.exception))

    def test_strict_more_than_one_of_in_args_ctx_fails(self):
        bad = makeRunner(
            {'OMNI': {'version': 1}, 'fib': {'g': {'set': [{'in': 5, 'args': [5], 'out': 5}]}}}
        )('fib')
        with self.assertRaises(OmniError) as caught:
            bad['runset'](bad['spec']['g'], fib)
        self.assertIn('more than one of in, args, ctx', str(caught.exception))

    def test_strict_err_together_with_out_fails(self):
        bad = makeRunner(
            {'OMNI': {'version': 1}, 'fib': {'g': {'set': [{'in': -1, 'err': True, 'out': 5}]}}}
        )('fib')
        with self.assertRaises(OmniError) as caught:
            bad['runset'](bad['spec']['g'], fib)
        self.assertIn('both err and out', str(caught.exception))

    def test_strict_a_null_id_fails_even_under_null_normalisation(self):
        runner = makeRunner({
            'OMNI': {'version': 1},
            'fib': {'g': {'set': [{'in': 1, 'out': 1, 'id': None}]}},
        })
        R = runner('fib')
        with self.assertRaises(OmniError) as ctx:
            R['runset'](R['spec']['g'], fib)
        self.assertIn('entry id is not a string', str(ctx.exception))

    def test_strict_an_empty_set_fails_unless_marked_empty(self):
        bad = makeRunner(
            {'OMNI': {'version': 1}, 'fib': {'g': {'set': []}, 'h': {'set': [], 'empty': True}}}
        )('fib')
        with self.assertRaises(OmniError) as caught:
            bad['runset'](bad['spec']['g'], fib)
        self.assertIn('empty test set', str(caught.exception))
        bad['runset'](bad['spec']['h'], fib)

    def test_a_legacy_spec_no_omni_block_stays_lenient(self):
        bad = makeRunner({'fib': {'g': {'set': [{'in': 6, 'matches': {'out': 999}, 'out': 8}]}}})(
            'fib'
        )
        bad['runset'](bad['spec']['g'], fib)

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


# Two distinct NaNs, from two DIFFERENT expressions. Reusing a single NaN
# object twice can be caught by the `a is b` fast path at the top of
# deepequal, so such a test would pass while proving nothing about the NaN
# branch. (0.0 / 0.0 is not usable here: Python raises ZeroDivisionError.)
NAN1 = float('nan')
NAN2 = float('inf') - float('inf')


class TestDeepEqual(unittest.TestCase):
    """deepequal is structural, not IEEE: NaN equals NaN, everywhere.

    The conformance suite cannot reach this - spec/fib.json is JSON, and
    JSON has no NaN literal - so it is pinned here directly.
    """

    def test_the_two_nans_are_distinct_objects(self):
        self.assertNotEqual(NAN1, NAN1)
        self.assertNotEqual(NAN2, NAN2)
        # If someone later "simplifies" these to one shared constant, the
        # identity fast path would answer for deepequal and the tests below
        # would stop testing anything. Fail loudly instead.
        self.assertIsNot(NAN1, NAN2)

    def test_nan_equals_nan(self):
        self.assertTrue(deepequal(NAN1, NAN2))

    def test_nan_equals_nan_in_a_list(self):
        self.assertTrue(deepequal([NAN1], [NAN2]))

    def test_nan_equals_nan_in_a_map(self):
        self.assertTrue(deepequal({'x': NAN1}, {'x': NAN2}))

    def test_nan_equality_does_not_loosen_the_ordinary_comparisons(self):
        self.assertTrue(deepequal(1, 1.0))
        self.assertFalse(deepequal(NAN1, 1.0))
        self.assertFalse(deepequal(True, 1))
        self.assertFalse(deepequal(1, 2))


if __name__ == '__main__':
    unittest.main()
