# RUN: ruby test/test_fib.rb
# RUN-SOME: ruby test/test_fib.rb -n test_basic
#
# The Fibonacci conformance suite: every omni port runs this same set of
# groups, from the same spec/fib.json, against the same fib library.

require 'minitest/autorun'

require_relative '../lib/voxgig_omni'
require_relative 'fib'

# Find the shared spec directory by walking up from this file.
def specfile(name)
  dir = File.dirname(File.expand_path(__FILE__))
  8.times do
    cand = File.join(dir, 'spec', name)
    return cand if File.exist?(cand)

    dir = File.dirname(dir)
  end
  raise 'omni: spec not found: ' + name
end

# The provider hosts the system under test. `shift` offsets the Fibonacci
# index, so that a client-specific subject is observably different.
# `contextify` marks the map, so the context group can prove the hook ran.
def fibprovider(shift)
  subjects = {
    'fib' => ->(n) { Fib.fib(n.is_a?(Numeric) ? n + shift : n) },
    'fibseq' => ->(n) { Fib.fibseq(n) },
    'fibrange' => ->(s, e) { Fib.fibrange(s, e) },
    'fibinfo' => ->(n) { Fib.fibinfo(n) }
  }

  {
    subject: ->(name) { subjects[name] },
    client: ->(options) { fibprovider(options['shift'] || 0) },
    contextify: ->(val) { val.merge('mark' => 'CTX') }
  }
end

R = VoxgigOmni.make_runner(specfile('fib.json'), fibprovider(0)).call('fib')
SPEC = R[:spec]
RUNSET = R[:runset]
RUNSETFLAGS = R[:runsetflags]

FIB = ->(n) { Fib.fib(n) }
FIBSEQ = ->(n) { Fib.fibseq(n) }
FIBRANGE = ->(s, e) { Fib.fibrange(s, e) }
FIBINFO = ->(n) { Fib.fibinfo(n) }

# The context-group subject: reports what the runner delivered - the
# contextify mark and the attached client - as plain data, so the spec can
# pin both with an ordinary `out` comparison in every port.
FIBCTX = lambda do |ctx|
  {
    'n' => ctx['n'],
    'val' => Fib.fib(ctx['n']),
    'mark' => ctx['mark'],
    'hasclient' => !ctx['client'].nil?
  }
end

class TestFib < Minitest::Test
  def test_basic
    RUNSET.call(SPEC['basic'], FIB)
  end

  def test_seq
    RUNSET.call(SPEC['seq'], FIBSEQ)
  end

  def test_range
    RUNSET.call(SPEC['range'], FIBRANGE)
  end

  def test_info
    RUNSET.call(SPEC['info'], FIBINFO)
  end

  def test_nulls
    RUNSETFLAGS.call(SPEC['nulls'], { null: false }, FIBINFO)
  end

  def test_error
    RUNSET.call(SPEC['error'], FIB)
  end

  def test_match
    RUNSET.call(SPEC['match'], FIB)
  end

  def test_matchinfo
    RUNSET.call(SPEC['matchinfo'], FIBINFO)
  end

  def test_client
    RUNSET.call(SPEC['client'], FIB)
  end

  def test_context
    RUNSET.call(SPEC['context'], FIBCTX)
  end
end

# A subject that returns the UNDEFMARK sentinel string as ordinary data,
# to prove __UNDEF__ is only satisfied by a genuinely absent key.
FIBUNDEF = ->(_n) { { 'a' => '__UNDEF__' } }

BADSPEC = {
  'fib' => {
    'wrongout' => { 'set' => [{ 'in' => 5, 'out' => 5 }, { 'in' => 6, 'out' => 999 }] },
    'wrongerr' => { 'set' => [{ 'in' => 1, 'err' => 'never happens' }] },
    'wrongmatch' => { 'set' => [{ 'in' => 6, 'match' => { 'out' => 999 } }] },
    'missing' => { 'set' => [{ 'in' => 6, 'match' => { 'out' => { 'nope' => '__EXISTS__' } } }] },
    # A concrete match leaf against a missing key must fail, not
    # substring-match the stringified absent value.
    'matchabsent' => { 'set' => [{ 'in' => 6, 'match' => { 'out' => { 'nope' => 'fine' } } }] },
    # __UNDEF__ (absent) must not be satisfied by a present null.
    'undefonnull' => { 'set' => [{ 'in' => 0, 'match' => { 'out' => { 'prev' => '__UNDEF__' } } }] },
    # __NULL__ (present null) must not be satisfied by an absent key.
    'nullonabsent' => { 'set' => [{ 'in' => 6, 'match' => { 'out' => { 'nope' => '__NULL__' } } }] },
    # An empty-string match leaf is not a wildcard.
    'emptystr' => { 'set' => [{ 'in' => 6, 'match' => { 'out' => { 'label' => '' } } }] },
    # __UNDEF__ (absent) must not be satisfied by the literal string
    # "__UNDEF__" arriving as ordinary data: a sentinel that accepts its
    # own literal is not a sentinel.
    'wrongundef' => { 'set' => [{ 'in' => 6, 'match' => { 'out' => { 'a' => '__UNDEF__' } } }] }
  }
}.freeze

# The runner must fail when the subject is wrong.
class TestRunner < Minitest::Test
  def expectfail(setname, subject, flags = {})
    bad = VoxgigOmni.make_runner(BADSPEC).call('fib')
    assert_raises(VoxgigOmni::OmniError) do
      bad[:runsetflags].call(bad[:spec][setname], flags, subject)
    end
  end

  def test_detects_wrong_result
    expectfail('wrongout', FIB)
  end

  def test_detects_missing_error
    expectfail('wrongerr', FIB)
  end

  def test_detects_failed_match
    expectfail('wrongmatch', FIB)
  end

  def test_detects_absent_key
    expectfail('missing', FIBINFO)
  end

  def test_concrete_match_leaf_does_not_match_missing_key
    expectfail('matchabsent', FIBINFO)
  end

  def test_undef_does_not_match_present_null
    expectfail('undefonnull', FIBINFO)
  end

  def test_undef_does_not_match_its_own_literal_as_data
    expectfail('wrongundef', FIBUNDEF)
  end

  def test_null_does_not_match_absent_key
    expectfail('nullonabsent', FIBINFO)
  end

  def test_empty_string_match_leaf_is_not_a_wildcard
    expectfail('emptystr', FIBINFO)
  end

  def test_rejects_an_unsupported_spec_version
    err = assert_raises(VoxgigOmni::OmniError) do
      VoxgigOmni.make_runner(
        { 'OMNI' => { 'version' => 99 }, 'fib' => { 'g' => { 'set' => [] } } }
      )
    end
    assert_includes err.message, 'unsupported spec version'
  end

  def test_rejects_an_unknown_required_capability
    err = assert_raises(VoxgigOmni::OmniError) do
      VoxgigOmni.make_runner(
        { 'OMNI' => { 'version' => 1, 'requires' => ['nosuchfeature'] },
          'fib' => { 'g' => { 'set' => [] } } }
      )
    end
    assert_includes err.message, 'unsupported capability'
  end

  def test_rejects_a_malformed_version_block
    err = assert_raises(VoxgigOmni::OmniError) do
      VoxgigOmni.make_runner(
        { 'OMNI' => { 'version' => 'one' }, 'fib' => { 'g' => { 'set' => [] } } }
      )
    end
    assert_includes err.message, 'malformed OMNI'
  end

  def test_strict_an_unknown_entry_field_fails_instead_of_passing_vacuously
    strict = VoxgigOmni.make_runner(
      { 'OMNI' => { 'version' => 1 },
        'fib' => { 'g' => { 'set' => [{ 'in' => 6, 'matches' => { 'out' => 999 } }] } } }
    ).call('fib')

    err = assert_raises(VoxgigOmni::OmniError) do
      strict[:runset].call(strict[:spec]['g'], FIBINFO)
    end
    assert_includes err.message, 'unknown entry field: matches'
  end

  def test_strict_more_than_one_of_in_args_ctx_fails
    strict = VoxgigOmni.make_runner(
      { 'OMNI' => { 'version' => 1 },
        'fib' => { 'g' => { 'set' => [{ 'in' => 5, 'args' => [5], 'out' => 5 }] } } }
    ).call('fib')

    err = assert_raises(VoxgigOmni::OmniError) do
      strict[:runset].call(strict[:spec]['g'], FIB)
    end
    assert_includes err.message, 'more than one of in, args, ctx'
  end

  def test_strict_err_together_with_out_fails
    strict = VoxgigOmni.make_runner(
      { 'OMNI' => { 'version' => 1 },
        'fib' => { 'g' => { 'set' => [{ 'in' => -1, 'err' => true, 'out' => 5 }] } } }
    ).call('fib')

    err = assert_raises(VoxgigOmni::OmniError) do
      strict[:runset].call(strict[:spec]['g'], FIB)
    end
    assert_includes err.message, 'both err and out'
  end

  def test_strict_a_null_id_fails_even_under_null_normalisation
    strict = VoxgigOmni.make_runner(
      { 'OMNI' => { 'version' => 1 },
        'fib' => { 'g' => { 'set' => [{ 'in' => 1, 'out' => 1, 'id' => nil }] } } }
    ).call('fib')

    err = assert_raises(VoxgigOmni::OmniError) do
      strict[:runset].call(strict[:spec]['g'], FIB)
    end
    assert_includes err.message, 'entry id is not a string'
  end

  def test_strict_an_empty_set_fails_unless_marked_empty
    strict = VoxgigOmni.make_runner(
      { 'OMNI' => { 'version' => 1 },
        'fib' => { 'g' => { 'set' => [] }, 'h' => { 'set' => [], 'empty' => true } } }
    ).call('fib')

    err = assert_raises(VoxgigOmni::OmniError) do
      strict[:runset].call(strict[:spec]['g'], FIB)
    end
    assert_includes err.message, 'empty test set'

    strict[:runset].call(strict[:spec]['h'], FIB)
  end

  def test_a_legacy_spec_no_omni_block_stays_lenient
    legacy = VoxgigOmni.make_runner(
      { 'fib' => { 'g' => { 'set' => [{ 'in' => 6, 'matches' => { 'out' => 999 }, 'out' => 8 }] } } }
    ).call('fib')

    legacy[:runset].call(legacy[:spec]['g'], FIB)
  end

  def test_reports_entry_index_and_id
    bad = VoxgigOmni.make_runner(
      { 'fib' => { 'g' => { 'set' => [{ 'in' => 1, 'out' => 1 },
                                      { 'id' => 'x#2', 'in' => 2, 'out' => 42 }] } } }
    ).call('fib')

    err = assert_raises(VoxgigOmni::OmniError) do
      bad[:runset].call(bad[:spec]['g'], FIB)
    end

    assert_includes err.message, 'fib[1] (x#2)'
    assert_includes err.message, 'expected: 42'
    assert_includes err.message, 'actual:   1'
  end
end
