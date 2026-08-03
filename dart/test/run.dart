// RUN: dart run test/run.dart
// RUN-SOME: dart run test/run.dart basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// `package:test` reports it as a failure. This harness keeps `make test`
// dependency-free.

import 'dart:io';

import '../lib/omni.dart';
import 'fib.dart';

String? ONLY;
int passcount = 0;
int failcount = 0;

// Find the shared spec directory by walking up from the working directory.
String specfile(String name) {
  var dir = Directory.current.absolute.path;

  for (var step = 0; step < 8; step++) {
    final cand = '$dir/spec/$name';
    if (File(cand).existsSync()) {
      return cand;
    }
    final parent = Directory(dir).parent.path;
    if (parent == dir) {
      break;
    }
    dir = parent;
  }

  throw OmniError('omni: spec not found: $name');
}

dynamic FIB(List<dynamic> args) => fib(args[0]);
dynamic FIBSEQ(List<dynamic> args) => fibseq(args[0]);
dynamic FIBRANGE(List<dynamic> args) => fibrange(args[0], args[1]);
dynamic FIBINFO(List<dynamic> args) => fibinfo(args[0]);

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
Provider fibprovider(num shift) {
  final subjects = <String, Subject>{
    'fib': (args) => isnum(args[0]) ? fib((args[0] as num) + shift) : fib(args[0]),
    'fibseq': FIBSEQ,
    'fibrange': FIBRANGE,
    'fibinfo': FIBINFO,
  };

  return Provider(
    subject: (name) => subjects[name],
    client: (options) {
      final shiftval = ismap(options) ? options['shift'] : null;
      return fibprovider(isnum(shiftval) ? shiftval as num : 0);
    },
  );
}

void testcase(String name, void Function() body) {
  if (null != ONLY && name != ONLY) {
    return;
  }

  try {
    body();
    passcount++;
    print('ok   - $name');
  } catch (err) {
    failcount++;
    print('FAIL - $name');
    print('$err');
  }
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
final Map<String, dynamic> BADSPEC = {
  'fib': {
    'wrongout': {
      'set': [
        {'in': 5, 'out': 5},
        {'in': 6, 'out': 999},
      ]
    },
    'wrongerr': {
      'set': [
        {'in': 1, 'err': 'never happens'},
      ]
    },
    'wrongmatch': {
      'set': [
        {
          'in': 6,
          'match': {'out': 999}
        },
      ]
    },
    'missing': {
      'set': [
        {
          'in': 6,
          'match': {
            'out': {'nope': '__EXISTS__'}
          }
        },
      ]
    },
  }
};

void expectfail(String setname, Subject subject) {
  final bad = makeRunner(clone(BADSPEC)).runner('fib');

  try {
    bad.runset(bad.set(setname), subject);
  } on OmniError {
    return;
  }

  throw StateError('omni: expected OmniError for set: $setname');
}

void checkmessage() {
  final spec = {
    'fib': {
      'g': {
        'set': [
          {'in': 1, 'out': 1},
          {'id': 'x#2', 'in': 2, 'out': 42},
        ]
      }
    }
  };

  final bad = makeRunner(spec).runner('fib');

  try {
    bad.runset(bad.set('g'), FIB);
  } on OmniError catch (err) {
    for (final want in ['fib[1] (x#2)', 'expected: 42', 'actual:   1']) {
      if (!err.message.contains(want)) {
        throw StateError('omni: message missing [$want]: ${err.message}');
      }
    }
    return;
  }

  throw StateError('omni: expected OmniError');
}

void main(List<String> args) {
  if (args.isNotEmpty) {
    ONLY = args[0];
  }

  final R = makeRunner(specfile('fib.json'), fibprovider(0)).runner('fib');

  testcase('basic', () => R.runset(R.set('basic'), FIB));
  testcase('seq', () => R.runset(R.set('seq'), FIBSEQ));
  testcase('range', () => R.runset(R.set('range'), FIBRANGE));
  testcase('info', () => R.runset(R.set('info'), FIBINFO));
  testcase('nulls', () => R.runsetflags(R.set('nulls'), Flags.nonull, FIBINFO));
  testcase('error', () => R.runset(R.set('error'), FIB));
  testcase('match', () => R.runset(R.set('match'), FIB));
  testcase('matchinfo', () => R.runset(R.set('matchinfo'), FIBINFO));
  testcase('client', () => R.runset(R.set('client'), FIB));

  testcase('detects wrong result', () => expectfail('wrongout', FIB));
  testcase('detects missing error', () => expectfail('wrongerr', FIB));
  testcase('detects failed match', () => expectfail('wrongmatch', FIB));
  testcase('detects absent key', () => expectfail('missing', FIBINFO));
  testcase('reports entry index and id', checkmessage);

  print('\n$passcount passed, $failcount failed');

  exit(0 == failcount ? 0 : 1);
}
