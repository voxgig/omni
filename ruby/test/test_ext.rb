# RUN: ruby test/test_ext.rb
#
# The capability suite: spec/ext.json requires ctxargs, fn and wait, and
# every port that carries them runs it, beside the runner flag `all`.

require 'minitest/autorun'

require_relative '../lib/voxgig_omni'
require_relative 'fib'

def extspecfile(name)
  dir = File.dirname(File.expand_path(__FILE__))
  8.times do
    cand = File.join(dir, 'spec', name)
    return cand if File.exist?(cand)

    dir = File.dirname(dir)
  end
  raise 'omni: spec not found: ' + name
end

def extprovider
  subjects = {
    'fib' => ->(n) { Fib.fib(n) },
    'fibseq' => ->(n) { Fib.fibseq(n) },
    'fibrange' => ->(s, e) { Fib.fibrange(s, e) },
    'fibinfo' => ->(n) { Fib.fibinfo(n) }
  }
  {
    subject: ->(name) { subjects[name] },
    contextify: ->(val) { val.merge('mark' => 'CTX') }
  }
end

# The ctxargs subject: the context comes first, and must arrive
# contextified with its client attached.
FIBSHIFTED = lambda do |ctx, start, finish|
  raise ArgumentError, 'fib: context not delivered' if ctx['mark'] != 'CTX' || ctx['client'].nil?

  Fib.fibrange(start + ctx['shift'], finish + ctx['shift'])
end

FIBSUBJECT = ->(n) { Fib.fib(n) }

def extrunner(spec)
  VoxgigOmni.make_runner(spec, extprovider).call('fib')
end

def v1(requires, entries)
  { 'OMNI' => { 'version' => 1, 'requires' => requires }, 'fib' => { 'g' => { 'set' => entries } } }
end

class TestExt < Minitest::Test
  def setup
    @r = extrunner(extspecfile('ext.json'))
  end

  def test_capabilities
    %w[ctxargs fn wait].each { |cap| assert_includes VoxgigOmni::CAPABILITIES, cap }
  end

  def test_ctxargs
    @r[:runset].call(@r[:spec]['ctxargs'], FIBSHIFTED)
  end

  def test_fn
    @r[:runset].call(@r[:spec]['fn'], FIBSUBJECT)
  end

  def test_wait
    @r[:runset].call(@r[:spec]['wait'], FIBSUBJECT)
  end
end

class TestExtRunner < Minitest::Test
  def refuses(pattern)
    err = assert_raises(VoxgigOmni::OmniError) { yield }
    assert_match Regexp.new(pattern, Regexp::MULTILINE), err.message
  end

  def test_waiting_entry_that_passes_fails
    r = extrunner(v1(['wait'], [{ 'in' => 5, 'out' => 5, 'wait' => { 'cause' => 'gone#1' } }]))
    refuses('\[0\]: stale wait: gone#1') { r[:runset].call(r[:spec]['g'], FIBSUBJECT) }
  end

  def test_wait_flag_holds_by_id
    r = extrunner(v1([], [{ 'id' => 'a', 'in' => 6, 'out' => 9 }, { 'in' => 7, 'out' => 13 }]))
    r[:runsetflags].call(r[:spec]['g'], { wait: { 'a' => { 'cause' => 'flag#1' } } }, FIBSUBJECT)
  end

  def test_wait_flag_fails_when_entry_passes
    r = extrunner(v1([], [{ 'id' => 'a', 'in' => 6, 'out' => 8 }]))
    refuses('stale wait: flag#1') do
      r[:runsetflags].call(r[:spec]['g'], { wait: { 'a' => { 'cause' => 'flag#1' } } }, FIBSUBJECT)
    end
  end

  def test_wait_flag_must_name_entry
    r = extrunner(v1([], [{ 'id' => 'a', 'in' => 6, 'out' => 8 }]))
    refuses('wait names no entry: zz') do
      r[:runsetflags].call(r[:spec]['g'], { wait: { 'zz' => { 'cause' => 'c' } } }, FIBSUBJECT)
    end
  end

  def test_wait_needs_cause
    r = extrunner(v1(['wait'], [{ 'in' => 6, 'out' => 9, 'wait' => {} }]))
    refuses('entry wait has no cause') { r[:runset].call(r[:spec]['g'], FIBSUBJECT) }
  end

  def test_wait_and_fn_unknown_unless_required
    w = extrunner(v1([], [{ 'in' => 6, 'out' => 9, 'wait' => { 'cause' => 'c' } }]))
    refuses('unknown entry field: wait') { w[:runset].call(w[:spec]['g'], FIBSUBJECT) }
    f = extrunner(v1([], [{ 'fn' => 'fib', 'in' => 6, 'out' => 8 }]))
    refuses('unknown entry field: fn') { f[:runset].call(f[:spec]['g'], FIBSUBJECT) }
  end

  def test_unknown_fn_is_spec_error
    r = extrunner(v1(['fn'], [{ 'fn' => 'nope', 'in' => 6, 'out' => 8 }]))
    refuses('unknown fn: nope') { r[:runset].call(r[:spec]['g'], FIBSUBJECT) }
  end

  def test_ctx_with_args_needs_ctxargs
    n = extrunner(v1([], [{ 'ctx' => { 'shift' => 0 }, 'args' => [0, 1], 'out' => [0, 1] }]))
    refuses('more than one of in, args, ctx') { n[:runset].call(n[:spec]['g'], FIBSHIFTED) }
    i = extrunner(v1(['ctxargs'], [{ 'in' => 1, 'ctx' => { 'shift' => 0 }, 'out' => [0] }]))
    refuses('entry has in beside args or ctx') { i[:runset].call(i[:spec]['g'], FIBSHIFTED) }
  end

  def test_legacy_spec_ignores_fn_and_wait
    r = extrunner({ 'fib' => { 'g' => { 'set' => [
      { 'in' => 6, 'out' => 8, 'fn' => 'nope', 'wait' => { 'cause' => 'c' } }
    ] } } })
    r[:runset].call(r[:spec]['g'], FIBSUBJECT)
  end

  def test_all_reports_every_failure
    r = extrunner(v1([], [{ 'in' => 5, 'out' => 6 }, { 'in' => 6, 'out' => 8 }, { 'in' => 7, 'out' => 14 }]))
    refuses('\Aomni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch') do
      r[:runsetflags].call(r[:spec]['g'], { all: true }, FIBSUBJECT)
    end
    refuses('\Aomni: fib\[0\]: result mismatch') { r[:runset].call(r[:spec]['g'], FIBSUBJECT) }
  end
end
