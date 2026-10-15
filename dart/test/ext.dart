// RUN: dart run test/ext.dart
// RUN-SOME: dart run test/ext.dart fn
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

import 'dart:io';

import '../lib/omni.dart';
import 'fib.dart';
import 'run.dart'
    show FIB, FIBINFO, FIBRANGE, FIBSEQ, ONLY, failcount, passcount, specfile, testcase;

Provider extprovider() {
  final subjects = <String, Subject>{
    'fib': FIB,
    'fibseq': FIBSEQ,
    'fibrange': FIBRANGE,
    'fibinfo': FIBINFO,
  };

  return Provider(
    subject: (name) => subjects[name],
    contextify: (val) => {...(val as Map), 'mark': 'CTX'},
  );
}

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
dynamic FIBSHIFTED(List<dynamic> args) {
  final ctx = args[0] as Map;
  if ('CTX' != ctx['mark'] || null == ctx['client']) {
    throw Exception('fib: context not delivered');
  }
  final shift = ctx['shift'] as num;
  return fibrange((args[1] as num) + shift, (args[2] as num) + shift);
}

RunPack extrunner(dynamic spec, [String name = 'fib']) =>
    makeRunner(spec, extprovider()).runner(name);

void refuses(void Function() run, String pattern) {
  try {
    run();
  } on OmniError catch (err) {
    if (!RegExp(pattern).hasMatch(err.message)) {
      throw StateError('omni: message does not match [$pattern]: ${err.message}');
    }
    return;
  }

  throw StateError('omni: expected OmniError matching [$pattern]');
}

Map<String, dynamic> v1(List<String> requires, List<dynamic> set) => {
      'OMNI': {'version': 1, 'requires': requires},
      'fib': {
        'g': {'set': set},
      },
    };

void extsuite() {
  final R = extrunner(specfile('ext.json'));

  testcase('capabilities', () {
    for (final cap in ['ctxargs', 'fn', 'wait']) {
      if (!CAPABILITIES.contains(cap)) {
        throw StateError('omni: missing capability: $cap');
      }
    }
  });

  testcase('ctxargs', () => R.runset(R.set('ctxargs'), FIBSHIFTED));
  testcase('fn', () => R.runset(R.set('fn'), FIB));
  testcase('wait', () => R.runset(R.set('wait'), FIB));
}

void extrunnersuite() {
  testcase('a waiting entry that passes fails the set', () {
    final R = extrunner(v1(['wait'], [
      {'in': 5, 'out': 5, 'wait': {'cause': 'gone#1'}},
    ]));
    refuses(() => R.runset(R.set('g'), FIB), r'\[0\]: stale wait: gone#1');
  });

  testcase('the wait flag holds an entry by id', () {
    final R = extrunner(v1([], [
      {'id': 'a', 'in': 6, 'out': 9},
      {'in': 7, 'out': 13},
    ]));
    final flags = Flags(wait: {'a': {'cause': 'flag#1'}});
    R.runsetflags(R.set('g'), flags, FIB);
  });

  testcase('the wait flag fails when its entry passes', () {
    final R = extrunner(v1([], [
      {'id': 'a', 'in': 6, 'out': 8},
    ]));
    final flags = Flags(wait: {'a': {'cause': 'flag#1'}});
    refuses(() => R.runsetflags(R.set('g'), flags, FIB), r'stale wait: flag#1');
  });

  testcase('the wait flag must name an entry', () {
    final R = extrunner(v1([], [
      {'id': 'a', 'in': 6, 'out': 8},
    ]));
    final flags = Flags(wait: {'zz': {'cause': 'c'}});
    refuses(() => R.runsetflags(R.set('g'), flags, FIB), r'wait names no entry: zz');
  });

  testcase('a wait needs a cause', () {
    final R = extrunner(v1(['wait'], [
      {'in': 6, 'out': 9, 'wait': {}},
    ]));
    refuses(() => R.runset(R.set('g'), FIB), r'entry wait has no cause');
  });

  testcase('wait and fn are unknown fields unless required', () {
    final W = extrunner(v1([], [
      {'in': 6, 'out': 9, 'wait': {'cause': 'c'}},
    ]));
    refuses(() => W.runset(W.set('g'), FIB), r'unknown entry field: wait');
    final F = extrunner(v1([], [
      {'fn': 'fib', 'in': 6, 'out': 8},
    ]));
    refuses(() => F.runset(F.set('g'), FIB), r'unknown entry field: fn');
  });

  testcase('an unknown fn is a spec error', () {
    final R = extrunner(v1(['fn'], [
      {'fn': 'nope', 'in': 6, 'out': 8},
    ]));
    refuses(() => R.runset(R.set('g'), FIB), r'unknown fn: nope');
  });

  testcase('ctx with args needs ctxargs, and never takes in', () {
    final N = extrunner(v1([], [
      {'ctx': {'shift': 0}, 'args': [0, 1], 'out': [0, 1]},
    ]));
    refuses(() => N.runset(N.set('g'), FIBSHIFTED), r'more than one of in, args, ctx');
    final I = extrunner(v1(['ctxargs'], [
      {'in': 1, 'ctx': {'shift': 0}, 'out': [0]},
    ]));
    refuses(() => I.runset(I.set('g'), FIBSHIFTED), r'entry has in beside args or ctx');
  });

  testcase('a legacy spec ignores fn and wait', () {
    final R = extrunner({
      'fib': {
        'g': {
          'set': [
            {'in': 6, 'out': 8, 'fn': 'nope', 'wait': {'cause': 'c'}},
          ]
        }
      }
    });
    R.runset(R.set('g'), FIB);
  });

  testcase('a raising hook is the entry\'s error, not the set\'s', () {
    final provider = Provider(
      subject: (name) => FIB,
      contextify: (val) => throw Exception('contextify boom'),
    );
    RunPack run(dynamic spec) => makeRunner(spec, provider).runner('fib');
    final E = run(v1([], [
      {'ctx': {'n': 6}, 'err': 'contextify boom'},
    ]));
    E.runset(E.set('g'), FIB);
    final U = run(v1([], [
      {'ctx': {'n': 6}, 'out': 8},
    ]));
    refuses(() => U.runset(U.set('g'), FIB),
        r'\[0\]: unexpected error\n\s+actual:\s+contextify boom');
    final W = run(v1(['wait'], [
      {'ctx': {'n': 6}, 'out': 8, 'wait': {'cause': 'hook#1'}},
    ]));
    W.runset(W.set('g'), FIB);
    final F = makeRunner(
        v1(['fn'], [
          {'fn': 'boom', 'in': 6, 'err': 'subject boom'},
        ]),
        Provider(subject: (name) {
          if ('boom' == name) {
            throw Exception('subject boom');
          }
          return FIB;
        })).runner('fib');
    F.runset(F.set('g'), FIB);
  });

  testcase('a waiting entry holds a hook\'s error raised before the subject starts', () {
    final provider = Provider(subject: (name) {
      if ('boom' == name) {
        throw Exception('subject boom');
      }
      return 'fib' == name ? FIB : null;
    });
    RunPack run(dynamic spec) => makeRunner(spec, provider).runner('fib');
    final H = run(v1(['fn', 'wait'], [
      {'fn': 'boom', 'in': 6, 'out': 8, 'wait': {'cause': 'hook#2'}},
    ]));
    H.runset(H.set('g'), FIB);
    final S = run(v1(['fn', 'wait'], [
      {'fn': 'boom', 'in': 6, 'err': 'subject boom', 'wait': {'cause': 'hook#3'}},
    ]));
    refuses(() => S.runset(S.set('g'), FIB), r'\[0\]: stale wait: hook#3');
  });

  testcase('fn needs no default subject, but an entry without fn does', () {
    final provider = Provider(subject: (name) => 'fibx' == name ? FIB : null);
    final R = makeRunner(
        v1(['fn'], [
          {'fn': 'fibx', 'in': 6, 'out': 8},
        ]),
        provider).runner('fib');
    R.runset(R.set('g'));
    final N = makeRunner(
        v1(['fn'], [
          {'fn': 'fibx', 'in': 6, 'out': 8},
          {'in': 6, 'out': 8},
        ]),
        provider).runner('fib');
    refuses(() => N.runset(N.set('g')), r'^omni: no test subject for: fib$');
    final L = makeRunner(
        v1([], [
          {'in': 6, 'out': 8},
        ]),
        provider).runner('fib');
    refuses(() => L.runset(L.set('g')), r'^omni: no test subject for: fib$');
  });

  testcase('a wait is found by an id the entry owns, never an inherited one', () {
    final R = extrunner(v1([], [
      {'id': 'constructor', 'in': 6, 'out': 8},
      {'id': 'toString', 'in': 7, 'out': 13},
    ]));
    R.runset(R.set('g'), FIB);
    R.runsetflags(R.set('g'), const Flags(wait: {}), FIB);
  });

  testcase('all reports every failure at once', () {
    final R = extrunner(v1([], [
      {'in': 5, 'out': 6},
      {'in': 6, 'out': 8},
      {'in': 7, 'out': 14},
    ]));
    refuses(
        () => R.runsetflags(R.set('g'), const Flags(all: true), FIB),
        r'^omni: fib: 2 of 3 entries failed\n[\s\S]*fib\[0\]: result mismatch'
        r'[\s\S]*fib\[2\]: result mismatch');
    refuses(() => R.runset(R.set('g'), FIB), r'^omni: fib\[0\]: result mismatch');
  });
}

void main(List<String> args) {
  if (args.isNotEmpty) {
    ONLY = args[0];
  }

  extsuite();
  extrunnersuite();

  print('\n$passcount passed, $failcount failed');

  exit(0 == failcount ? 0 : 1);
}
