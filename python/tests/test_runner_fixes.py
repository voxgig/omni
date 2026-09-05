# Regression pins for the runner fixes ported from the typescript
# reference (the "omni#54" set): a cyclic match base must not blow the
# stack, jsonstr must render a cycle as [Circular] (a DAG in full), and
# an error-shaped plain map raised by a subject must keep its message and
# fields. Each of these went red on the unfixed code.

import unittest

from voxgig_omni import OmniError, jsonstr, makeRunner, match


class TestRunnerFixes(unittest.TestCase):

    def test_match_reads_a_cyclic_base(self):
        base = {'name': 'ctx'}
        base['self'] = base  # a live client context reaches itself

        match({}, 0, {'id': 'cyc'}, {'name': 'ctx'}, base)

        with self.assertRaisesRegex(OmniError, 'match failed'):
            match({}, 0, {'id': 'cyc'}, {'name': 'wrong'}, base)

    def test_jsonstr_cycle_and_dag(self):
        cyc = {'a': 1}
        cyc['me'] = cyc
        self.assertIn('[Circular]', jsonstr(cyc))

        leaf = {'x': 1}
        dag = {'a': leaf, 'b': leaf}
        out = jsonstr(dag)
        self.assertNotIn('[Circular]', out)
        self.assertEqual(2, out.count('"x":1'))

    def test_error_shaped_map_keeps_message_and_fields(self):
        spec = {'primary': {'mapthrow': {'basic': {'set': [
            {'in': 1, 'err': 'refused politely',
             'match': {'err': {'code': 'polite'}}},
        ]}}}}

        class MapRefusal(Exception):
            pass

        def subject(_val=None):
            # Not an exception instance carrying attrs: an error-shaped
            # plain map, raised verbatim the way voxgig/sdkgen's generated
            # make_error rethrows a fixture's own error object.
            raise MapRefusal({'message': 'refused politely', 'code': 'polite'})

        # python cannot raise a bare dict, so the runner receives the
        # exception ARG when a port unwraps it - drive errify directly for
        # the map shape, and the runner for the string path.
        from voxgig_omni.runner import errify
        base = errify({'message': 'refused politely', 'code': 'polite'})
        self.assertEqual('refused politely', base.get('message'))
        self.assertEqual('polite', base.get('code'))

        run = makeRunner(spec)('mapthrow')

        def strsubject(_val=None):
            e = Exception('refused politely')
            e.code = 'polite'  # exception attrs survive into the err base
            raise e

        run['runset'](run['spec']['basic'], strsubject)


if __name__ == '__main__':
    unittest.main()
