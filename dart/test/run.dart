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
import 'dart:typed_data';

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
dynamic FIBCTX(List<dynamic> args) => fibctx(args[0]);

// A subject that returns the literal string "__UNDEF__" as ordinary data,
// so the negative suite can prove the sentinel is not satisfied by it.
dynamic FIBUNDEFLIT(List<dynamic> args) => {'a': '__UNDEF__', 'val': fib(args[0])};

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec can
// pin both with an ordinary `out` comparison in every port.
Map<String, dynamic> fibctx(dynamic ctx) {
  final ctxmap = ctx as Map;
  return {
    'n': ctxmap['n'],
    'val': fib(ctxmap['n']),
    'mark': ctxmap['mark'],
    'hasclient': null != ctxmap['client'],
  };
}

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
// `contextify` marks the map, so the context group can prove the hook ran.
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
    contextify: (val) {
      final out = Map<String, dynamic>.from(val as Map);
      out['mark'] = 'CTX';
      return out;
    },
  );
}

/// Derive fib's error code from its message.
String fiberrcode(String message) {
  if (message.contains('negative index')) return 'fib_negative';
  if (message.contains('non-integer')) return 'fib_noninteger';
  if (message.contains('not a number')) return 'fib_notanumber';
  return 'fib_unknown';
}

/// The same provider, plus the `errify` hook: fib's errors gain a CODE.
///
/// A SECOND runner rather than a hook on `fibprovider`, so that the
/// `error` group keeps exercising the DEFAULT errify.
Provider fibcodedprovider() {
  final base = fibprovider(0);
  return Provider(
    subject: base.subject,
    client: base.client,
    contextify: base.contextify,
    inject: base.inject,
    errify: (err) {
      final message = errmessage(err);
      return {'name': 'Error', 'message': message, 'code': fiberrcode(message)};
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
    // A concrete match leaf against a missing key must fail, not
    // substring-match the text "undefined".
    'matchabsent': {
      'set': [
        {
          'in': 6,
          'match': {
            'out': {'nope': 'fine'}
          }
        },
      ]
    },
    // __UNDEF__ (absent) must not be satisfied by a present null.
    'undefonnull': {
      'set': [
        {
          'in': 0,
          'match': {
            'out': {'prev': '__UNDEF__'}
          }
        },
      ]
    },
    // __NULL__ (present null) must not be satisfied by an absent key.
    'nullonabsent': {
      'set': [
        {
          'in': 6,
          'match': {
            'out': {'nope': '__NULL__'}
          }
        },
      ]
    },
    // A subject returning the literal string "__UNDEF__" as ordinary data
    // must not satisfy __UNDEF__ (absent) - a sentinel that accepts its own
    // literal is not a sentinel.
    'wrongundef': {
      'set': [
        {
          'in': 6,
          'match': {
            'out': {'a': '__UNDEF__'}
          }
        },
      ]
    },
    // An empty-string leaf matches only an empty string, not "anything".
    'emptystr': {
      'set': [
        {
          'in': 6,
          'match': {
            'out': {'label': ''}
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

// A spec-level failure: makeRunner itself must refuse to load the spec.
void expectmakefail(dynamic spec, String contains) {
  try {
    makeRunner(spec);
  } on OmniError catch (err) {
    if (!err.message.contains(contains)) {
      throw StateError('omni: message missing [$contains]: ${err.message}');
    }
    return;
  }

  throw StateError('omni: expected OmniError containing [$contains]');
}

// A strict (version-1) entry failure: the spec loads, but the named group
// fails validation before the subject ever runs.
void expectstrictfail(Map<String, dynamic> group, String contains) {
  final spec = {
    'OMNI': {'version': 1},
    'fib': {'g': group},
  };
  final R = makeRunner(spec).runner('fib');

  try {
    R.runset(R.set('g'), FIB);
  } on OmniError catch (err) {
    if (!err.message.contains(contains)) {
      throw StateError('omni: message missing [$contains]: ${err.message}');
    }
    return;
  }

  throw StateError('omni: expected OmniError containing [$contains]');
}

void checknullomniblock() {
  // A present-but-null block is malformed; only a genuinely absent OMNI
  // key is legacy.
  expectmakefail({
    'OMNI': null,
    'fib': {
      'g': {
        'set': [
          {'in': 1, 'out': 1},
        ]
      }
    },
  }, 'malformed OMNI');

  expectmakefail({
    'OMNI': {'version': 1, 'requires': null},
    'fib': {
      'g': {
        'set': [
          {'in': 1, 'out': 1},
        ]
      }
    },
  }, 'malformed OMNI requires list');

  // Must not throw: no OMNI key at all is legacy.
  makeRunner({
    'fib': {
      'g': {
        'set': [
          {'in': 1, 'out': 1},
        ]
      }
    },
  });
}

void checkstrictemptyset() {
  final spec = {
    'OMNI': {'version': 1},
    'fib': {
      'g': {'set': []},
      'h': {
        'set': [],
        'empty': true,
      },
    },
  };
  final R = makeRunner(spec).runner('fib');

  var threw = false;
  try {
    R.runset(R.set('g'), FIB);
  } on OmniError catch (err) {
    threw = true;
    if (!err.message.contains('empty test set')) {
      throw StateError('omni: message missing [empty test set]: ${err.message}');
    }
  }
  if (!threw) {
    throw StateError('omni: expected OmniError for empty set');
  }

  // Must not throw: `empty: true` states the emptiness as fact.
  R.runset(R.set('h'), FIB);
}

void checklegacylenient() {
  final spec = {
    'fib': {
      'g': {
        'set': [
          {'in': 6, 'matches': {'out': 999}, 'out': 8},
        ]
      }
    },
  };
  final R = makeRunner(spec).runner('fib');
  R.runset(R.set('g'), FIB); // must not throw: no OMNI block, so lenient
}

void checkunsupportedversion() => expectmakefail({
      'OMNI': {'version': 99},
      'fib': {'g': {'set': []}},
    }, 'unsupported spec version');

void checkunknowncapability() => expectmakefail({
      'OMNI': {
        'version': 1,
        'requires': ['nosuchfeature'],
      },
      'fib': {'g': {'set': []}},
    }, 'unsupported capability');

void checkmalformedversion() => expectmakefail({
      'OMNI': {'version': 'one'},
      'fib': {'g': {'set': []}},
    }, 'malformed OMNI');

void checkunknownfield() => expectstrictfail({
      'set': [
        {'in': 6, 'matches': {'out': 999}},
      ]
    }, 'unknown entry field: matches');

void checkmultisource() => expectstrictfail({
      'set': [
        {'in': 5, 'args': [5], 'out': 5},
      ]
    }, 'more than one of in, args, ctx');

void checkerrandout() => expectstrictfail({
      'set': [
        {'in': -1, 'err': true, 'out': 5},
      ]
    }, 'both err and out');

void checknullid() => expectstrictfail({
      'set': [
        {'in': 1, 'out': 1, 'id': null},
      ]
    }, 'entry id is not a string');

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

// deepequal is structural, not IEEE: NaN equals NaN. Nothing in
// spec/fib.json can pin that - JSON has no NaN literal - so the contract
// is pinned here instead.
void expectequal(dynamic a, dynamic b, bool want, String what) {
  if (want != deepequal(a, b)) {
    throw StateError('omni: deepequal($what) should be $want');
  }
}

// A NaN carrying a payload bit: a different NaN from `0.0 / 0.0` right
// down to its bits. Dart's `identical` compares doubles bit for bit, so a
// pair of canonical NaNs is caught by the identity fast path at the top of
// deepequal and never reaches the NaN branch this test exists to pin.
double payloadnan() {
  final bits = ByteData(8);
  bits.setUint32(0, 0x7FF80000, Endian.big);
  bits.setUint32(4, 0x00000001, Endian.big);
  return bits.getFloat64(0, Endian.big);
}

void checknan() {
  final n1 = 0.0 / 0.0;
  final n2 = payloadnan();

  if (!n1.isNaN || !n2.isNaN) {
    throw StateError('omni: both values must be NaN');
  }

  // IEEE says a NaN equals nothing at all, itself included. deepequal
  // says otherwise, so prove that `==` is not what is saying it.
  if (n1 == n2) {
    throw StateError('omni: the two NaNs must not be IEEE-equal');
  }

  // Two NaNs, not one used twice. If this ever fails, Dart canonicalised
  // the payload away: build the second NaN some other way rather than
  // dropping the check, or the test proves nothing.
  if (identical(n1, n2)) {
    throw StateError('omni: the two NaNs must not be the same double');
  }

  expectequal(n1, n2, true, 'NaN, NaN');
  expectequal([n1], [n2], true, '[NaN], [NaN]');
  expectequal({'x': n1}, {'x': n2}, true, '{x:NaN}, {x:NaN}');

  // Regressions: the rest of the numeric rule the NaN branch sits in.
  expectequal(1, 1.0, true, '1, 1.0');
  expectequal(n1, 1.0, false, 'NaN, 1.0');
  expectequal(true, 1, false, 'true, 1');
  expectequal(1, 2, false, '1, 2');
}

void main(List<String> args) {
  if (args.isNotEmpty) {
    ONLY = args[0];
  }

  final R = makeRunner(specfile('fib.json'), fibprovider(0)).runner('fib');
  final RC = makeRunner(specfile('fib.json'), fibcodedprovider()).runner('fib');

  testcase('basic', () => R.runset(R.set('basic'), FIB));
  testcase('seq', () => R.runset(R.set('seq'), FIBSEQ));
  testcase('range', () => R.runset(R.set('range'), FIBRANGE));
  testcase('info', () => R.runset(R.set('info'), FIBINFO));
  testcase('nulls', () => R.runsetflags(R.set('nulls'), Flags.nonull, FIBINFO));
  testcase('error', () => R.runset(R.set('error'), FIB));
  testcase('errcode', () => RC.runset(RC.set('errcode'), FIB));
  testcase('match', () => R.runset(R.set('match'), FIB));
  testcase('matchinfo', () => R.runset(R.set('matchinfo'), FIBINFO));
  testcase('client', () => R.runset(R.set('client'), FIB));
  testcase('context', () => R.runset(R.set('context'), FIBCTX));

  testcase('detects wrong result', () => expectfail('wrongout', FIB));
  testcase('detects missing error', () => expectfail('wrongerr', FIB));
  testcase('detects failed match', () => expectfail('wrongmatch', FIB));
  testcase('detects absent key', () => expectfail('missing', FIBINFO));
  testcase('a concrete match leaf does not match a missing key',
      () => expectfail('matchabsent', FIBINFO));
  testcase('__UNDEF__ does not match a present null',
      () => expectfail('undefonnull', FIBINFO));
  testcase('__NULL__ does not match an absent key',
      () => expectfail('nullonabsent', FIBINFO));
  testcase('__UNDEF__ does not match its own literal string',
      () => expectfail('wrongundef', FIBUNDEFLIT));
  testcase('an empty-string match leaf is not a wildcard',
      () => expectfail('emptystr', FIBINFO));
  testcase('reports entry index and id', checkmessage);
  testcase('deepequal is structural: NaN equals NaN', checknan);

  testcase('rejects an unsupported spec version', checkunsupportedversion);
  testcase('rejects an unknown required capability', checkunknowncapability);
  testcase('rejects a malformed version block', checkmalformedversion);
  testcase('rejects a null OMNI block, but accepts an absent one', checknullomniblock);
  testcase(
      'strict: an unknown entry field fails instead of passing vacuously', checkunknownfield);
  testcase('strict: more than one of in, args, ctx fails', checkmultisource);
  testcase('strict: err together with out fails', checkerrandout);
  testcase('strict: a null id fails even under null-normalisation', checknullid);
  testcase('strict: an empty set fails unless marked empty', checkstrictemptyset);
  testcase('a legacy spec (no OMNI block) stays lenient', checklegacylenient);

  print('\n$passcount passed, $failcount failed');

  exit(0 == failcount ? 0 : 1);
}
