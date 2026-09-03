// Omni: the shared multi-language test runner (Dart port).
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

import 'dart:convert';
import 'dart:io';

import 'util.dart';

/// The function under test. Arguments arrive as JSON values; failure is
/// reported by throwing.
typedef Subject = dynamic Function(List<dynamic> args);

/// A test failure (or a malformed spec). Distinct from an exception thrown
/// by the subject under test, which is a candidate for an `err`
/// expectation.
class OmniError implements Exception {
  final String message;
  final dynamic entry;

  OmniError(this.message, [this.entry]);

  @override
  String toString() => message;
}

/// Run-time options for a set of test entries.
class Flags {
  final bool nulls;
  final String? name;

  const Flags({this.nulls = true, this.name});

  static const Flags nonull = Flags(nulls: false);
}

/// The host of the system under test. Every hook is optional.
class Provider {
  final Subject? Function(String name)? subject;
  final Provider Function(dynamic options)? client;
  final dynamic Function(dynamic val)? contextify;
  final dynamic Function(dynamic options, dynamic store)? inject;

  /// Build the `match.err` base from the raised error, REPLACING [errify].
  /// A library whose errors carry a code can then assert on it with
  /// `match: {err: {code: 'x'}}` instead of pattern-matching prose.
  final dynamic Function(dynamic err)? errify;

  const Provider({
    this.subject,
    this.client,
    this.contextify,
    this.inject,
    this.errify,
  });
}

/// The newest spec format version this runner understands. A spec with no
/// OMNI block is version 0: the original, lenient format, frozen forever.
/// Version 1 turns on strict entry validation (see _checkentry).
const int SPECVERSION = 1;

/// Capability strings this runner supports beyond the version baseline. A
/// spec's OMNI.requires list is checked against this: an unknown capability
/// refuses the spec loudly at load time, instead of a lagging port silently
/// mis-running it. (Empty today; future format features mint a string here.)
const List<String> CAPABILITIES = [];

/// The complete set of fields an entry may carry. Under version 1 anything
/// else is an error: an unrecognised key is almost always a typo'd
/// assertion, and a typo'd assertion is a test that silently stopped
/// testing.
const List<String> _entryfields = [
  'in', 'args', 'ctx', 'out', 'err', 'match', 'client', 'id', 'doc',
];

/// Load a spec: a path to a JSON file.
dynamic loadspec(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw OmniError('omni: cannot read spec: $path');
  }
  return jsonDecode(file.readAsStringSync());
}

/// Read the spec's format version from its optional top-level OMNI block,
/// and refuse a spec this runner cannot faithfully run: a version newer
/// than SPECVERSION, or a required capability not in CAPABILITIES. Only a
/// genuinely absent OMNI key is legacy - a present `OMNI: null` is
/// malformed, not version 0.
int _resolveversion(dynamic alltests) {
  if (alltests is! Map || !alltests.containsKey('OMNI')) {
    return 0;
  }

  final meta = alltests['OMNI'];
  final version = meta is Map ? meta['version'] : null;

  var versionisint = false;
  if (isnum(version)) {
    final asnum = version as num;
    versionisint = asnum.toDouble() == asnum.toDouble().truncateToDouble();
  }

  if (meta is! Map || !versionisint) {
    throw OmniError('omni: malformed OMNI version block');
  }

  final versionval = (version as num).toInt();
  if (0 > versionval || SPECVERSION < versionval) {
    throw OmniError('omni: unsupported spec version: $versionval');
  }

  // A present `requires: null` is malformed, same as the OMNI block itself -
  // only a genuinely absent key skips the check.
  if (meta.containsKey('requires')) {
    final requires = meta['requires'];
    if (requires is! List) {
      throw OmniError('omni: malformed OMNI requires list');
    }
    for (final cap in requires) {
      if (cap is! String || !CAPABILITIES.contains(cap)) {
        throw OmniError('omni: spec requires unsupported capability: ${stringify(cap)}');
      }
    }
  }

  return versionval;
}

/// Find `primary.<name>`, then `<name>`, then the whole spec.
dynamic resolvespec(String name, dynamic alltests) {
  if (name.isEmpty) {
    return alltests;
  }

  if (alltests is Map) {
    final primary = alltests['primary'];
    if (primary is Map && null != primary[name]) {
      return primary[name];
    }

    if (null != alltests[name]) {
      return alltests[name];
    }
  }

  return alltests;
}

/// Nulls become NULLMARK. Always a fresh copy.
dynamic fixjson(dynamic val, bool donull) {
  if (null == val || isabsent(val)) {
    // Canonical returns the value UNCHANGED when donull is false
    // (typescript/src/Runner.ts): absent stays absent and null stays null.
    // Answering null for both collapsed two states the corpus distinguishes.
    // Same defect omni-lua and omni-rust carried (voxgig/omni#17, #23).
    return donull ? NULLMARK : val;
  }

  if (val is List) {
    return val.map<dynamic>((entry) => fixjson(entry, donull)).toList();
  }

  if (val is Map) {
    final out = <String, dynamic>{};
    val.forEach((key, subval) => out['$key'] = fixjson(subval, donull));
    return out;
  }

  return val;
}

/// The JSON form of an error: always at least {name,message}.
Map<String, dynamic> errify(dynamic err) {
  if (err is OmniError) {
    return {'name': 'OmniError', 'message': err.message};
  }
  return {'name': err.runtimeType.toString(), 'message': errmessage(err)};
}

String errmessage(dynamic err) {
  if (err is OmniError) {
    return err.message;
  }
  if (err is ArgumentError) {
    return '${err.message}';
  }
  if (err is Exception) {
    final text = err.toString();
    // Dart prefixes its built-in exceptions; the spec matches on messages.
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
  return '$err';
}

/// Convert NULLMARK sentinels back into real nulls.
dynamic nullmodifier(dynamic val, List<String> path) {
  if (val is String) {
    return NULLMARK == val ? null : val.replaceAll(NULLMARK, 'null');
  }
  return val;
}

/// Match one leaf: /regex/ or case-insensitive substring for strings.
bool matchval(dynamic check, dynamic base) {
  if (deepequal(check, base)) {
    return true;
  }

  dynamic want = check;
  if (UNDEFMARK == want || NULLMARK == want) {
    want = null;
  }

  if (null == want) {
    return null == base || isabsent(base) || NULLMARK == base;
  }

  if (want is String) {
    // An empty want is not a wildcard: it matches only an empty string.
    if (want.isEmpty) {
      return '' == base;
    }

    final basestr = stringify(base);

    if (2 < want.length && want.startsWith('/') && want.endsWith('/')) {
      try {
        return RegExp(want.substring(1, want.length - 1)).hasMatch(basestr);
      } on FormatException {
        return false;
      }
    }

    return basestr.toLowerCase().contains(want.toLowerCase());
  }

  return deepequal(want, base);
}

/// What a runner returns for one named spec section.
class RunPack {
  final dynamic spec;
  final Subject? subject;
  final Provider client;

  final Provider _provider;
  final Map<String, Provider> _clients;
  final String _name;
  final int _specversion;

  RunPack(this.spec, this.subject, this._provider, this._clients, this._name,
      this._specversion)
      : client = _provider;

  /// A named group of the resolved spec.
  dynamic set(String name) => spec is Map ? spec[name] : null;

  /// Run one set of test entries.
  void runset(dynamic testspec, [Subject? testsubject]) {
    runsetflags(testspec, const Flags(), testsubject);
  }

  /// Run one set of test entries with flags.
  void runsetflags(dynamic testspec, Flags flags, [Subject? testsubject]) {
    final label = flags.name ?? (_name.isEmpty ? 'set' : _name);

    final usesubject = testsubject ?? subject;
    if (null == usesubject) {
      throw OmniError('omni: no test subject for: $label');
    }

    final testspecmap = fixjson(testspec, flags.nulls);
    if (testspecmap is! Map || testspecmap['set'] is! List) {
      throw OmniError('omni: test spec has no set: $label');
    }

    final testset = testspecmap['set'] as List;

    // Validate the AUTHORED group up front, against the un-normalised
    // entries: null-normalisation above would otherwise rewrite an
    // authored null (e.g. id: null) into a sentinel string and hide it
    // from validation. A malformed spec is a spec error, not a test
    // result, so it fails before any subject runs.
    if (1 <= _specversion) {
      _checkset(label, testspec, testset);
    }

    for (var index = 0; index < testset.length; index++) {
      final entry = testset[index];

      if (entry is! Map) {
        throw OmniError('omni: $label[$index]: entry is not a map');
      }

      // An entry with no `out` expects a null (or absent) result.
      if (flags.nulls && null == entry['out']) {
        entry['out'] = NULLMARK;
      }

      var entrysubject = usesubject;
      var entryclient = _provider;

      final clientname = entry['client'];
      if (clientname is String) {
        final found = _clients[clientname];
        if (null == found) {
          throw OmniError('omni: unknown client: $clientname', entry);
        }
        entryclient = found;
        final clientsubject = found.subject?.call(_name);
        if (null != clientsubject) {
          entrysubject = clientsubject;
        }
      }

      final args = _resolveargs(entry, entryclient);

      dynamic res;
      try {
        res = entrysubject(args);
      } on OmniError {
        rethrow;
      } catch (err) {
        _handleerror(label, index, entry, err);
        continue;
      }

      res = fixjson(res, flags.nulls);
      entry['res'] = res;

      _checkresult(label, index, entry, args, res);
    }
  }

  // Validate a version-1 group up front, against the AUTHORED entries -
  // `normalset` (post-fixjson) is only the fallback for a group whose
  // original has no usable set.
  void _checkset(String label, dynamic testspec, List normalset) {
    final origset = (testspec is Map && testspec['set'] is List)
        ? testspec['set'] as List
        : normalset;

    final markedempty = testspec is Map && true == testspec['empty'];
    if (origset.isEmpty && !markedempty) {
      throw OmniError('omni: empty test set: $label');
    }

    for (var index = 0; index < origset.length; index++) {
      _checkentry(label, index, origset[index]);
    }
  }

  // Strict entry validation, applied when the spec declares version 1 or
  // later. The lenient format converts each of these mistakes into a
  // silent pass or a dead field; here they fail with the entry named.
  void _checkentry(String label, int index, dynamic entry) {
    if (entry is! Map) {
      throw _fail(label, index, entry, 'entry is not a map');
    }

    for (final key in entry.keys) {
      final keystr = '$key';
      if (!_entryfields.contains(keystr)) {
        throw _fail(label, index, entry, 'unknown entry field: $keystr');
      }
    }

    var argsources = 0;
    for (final key in ['in', 'args', 'ctx']) {
      if (entry.containsKey(key)) {
        argsources++;
      }
    }
    if (1 < argsources) {
      throw _fail(label, index, entry, 'entry has more than one of in, args, ctx');
    }

    if (null != entry['err'] && entry.containsKey('out')) {
      throw _fail(label, index, entry, 'entry has both err and out');
    }

    // Presence, not definedness: an authored `id: null` must fail, while
    // an absent id is simply unset.
    if (entry.containsKey('id') && entry['id'] is! String) {
      throw _fail(label, index, entry, 'entry id is not a string');
    }
  }

  // Build the argument list: `ctx`, `args`, or `in`.
  List<dynamic> _resolveargs(Map entry, Provider client) {
    List<dynamic> args;

    final hasctx = entry.containsKey('ctx');
    final hasargs = entry.containsKey('args');

    if (hasctx) {
      args = [entry['ctx']];
    } else if (hasargs) {
      final rawargs = entry['args'];
      args = rawargs is List ? List<dynamic>.from(rawargs) : [rawargs];
    } else {
      // ABSENT, not null, when the entry supplies no `in`: Dart's `entry['in']`
      // answers null for a missing key and for an authored `in: null` alike,
      // and the corpus distinguishes them - struct's `minor/typify` has both
      // `{in: null, out: <T_null>}` and `{out: <T_noval>}` (register 4.12).
      // The typed ports get this for free because their map read returns their
      // own absent marker; the dynamic ones have to say it (as canonical does).
      args = [clone(entry.containsKey('in') ? entry['in'] : ABSENT)];
    }

    if ((hasctx || hasargs) && args.isNotEmpty && ismap(args[0])) {
      var first = clone(args[0]);
      if (null != _provider.contextify) {
        first = _provider.contextify!(first);
      }
      if (first is Map) {
        first['client'] = client;
      }
      args[0] = first;
      entry['ctx'] = first;
    }

    return args;
  }

  void _checkresult(String label, int index, Map entry, List<dynamic> args, dynamic res) {
    var matched = false;

    if (null != entry['err']) {
      throw _fail(label, index, entry, 'expected error did not occur',
          stringify(entry['err']), stringify(res));
    }

    if (null != entry['match']) {
      _match(label, index, entry, entry['match'], {
        'in': entry['in'],
        'args': args,
        'out': entry['res'],
        'ctx': entry['ctx'],
      });
      matched = true;
    }

    final out = entry['out'];

    if (deepequal(res, out)) {
      return;
    }

    // NOTE: a match with no explicit out is a complete check on its own.
    if (matched && (NULLMARK == out || null == out)) {
      return;
    }

    throw _fail(label, index, entry, 'result mismatch', stringify(out), stringify(res));
  }

  /// The error base a `match.err` sees: the provider's own, when it has one.
  dynamic _errbase(dynamic err) {
    final hook = _provider.errify;
    return null != hook ? hook(err) : errify(err);
  }

  void _handleerror(String label, int index, Map entry, dynamic err) {
    final entryerr = entry['err'];

    if (null != entryerr) {
      final istrue = true == entryerr;

      if (istrue || matchval(entryerr, errmessage(err))) {
        if (null != entry['match']) {
          _match(label, index, entry, entry['match'], {
            'in': entry['in'],
            'out': entry['res'],
            'ctx': entry['ctx'],
            'err': _errbase(err),
          });
        }
        return;
      }

      throw _fail(label, index, entry, 'error mismatch', stringify(entryerr), errmessage(err));
    }

    throw _fail(label, index, entry, 'unexpected error', null, errmessage(err));
  }

  // Check that every leaf of `check` is present, and matches, in `base`.
  void _match(String label, int index, Map entry, dynamic check, dynamic base,
      [List<String> path = const []]) {
    if (check is List) {
      for (var at = 0; at < check.length; at++) {
        _match(label, index, entry, check[at], base, [...path, '$at']);
      }
      return;
    }

    if (check is Map) {
      check.forEach((key, subcheck) {
        _match(label, index, entry, subcheck, base, [...path, '$key']);
      });
      return;
    }

    final baseval = getpath(base, path);

    // The sentinels are tested BEFORE the identity check below. Otherwise
    // a subject returning the literal string "__UNDEF__" satisfies an
    // assertion that the key is absent - two mutually exclusive states
    // passing one check. A sentinel that accepts its own literal is not a
    // sentinel. (NULLMARK still accepts NULLMARK: under the default null
    // flag a real null has already been normalised to it, so the two are
    // genuinely indistinguishable here - that one needs a raw-value
    // escape, not an ordering change.)

    // Explicitly absent: satisfied only by a genuinely missing key, never
    // by a present null (the distinction the sentinels exist to keep).
    if (UNDEFMARK == check) {
      if (isabsent(baseval)) {
        return;
      }
      throw _fail(label, index, entry, 'expected absent at ${_at(path)}',
          'absent', stringify(baseval));
    }

    // Explicitly null: satisfied only by a present null.
    if (NULLMARK == check) {
      if (null == baseval || NULLMARK == baseval) {
        return;
      }
      throw _fail(label, index, entry, 'expected null at ${_at(path)}',
          'null', stringify(baseval));
    }

    // Explicitly present: any present value, including null.
    if (EXISTSMARK == check) {
      if (!isabsent(baseval)) {
        return;
      }
      throw _fail(label, index, entry, 'expected present at ${_at(path)}',
          'present', 'absent');
    }

    // Identical values match. This sits below the sentinel branches on
    // purpose - see the note above.
    if (deepequal(check, baseval)) {
      return;
    }

    // A concrete expectation never matches a missing key - a match leaf
    // against an absent value must fail, not substring-match "undefined".
    if (isabsent(baseval)) {
      throw _fail(label, index, entry, 'match failed at ${_at(path)}',
          stringify(check), 'absent');
    }

    if (matchval(check, baseval)) {
      return;
    }

    throw _fail(label, index, entry, 'match failed at ${_at(path)}',
        stringify(check), stringify(baseval));
  }

  String _at(List<String> path) => path.isEmpty ? '<root>' : pathify(path);

  // The label of one entry, for failure messages.
  String _entryref(String label, int index, dynamic entry) {
    final id = entry is Map ? entry['id'] : null;
    final idpart = null == id ? '' : ' (${stringify(id)})';
    return '$label[$index]$idpart';
  }

  // `entry` may not be a map - checkentry calls this for an entry that
  // failed exactly that check - so the summary below degrades to the raw
  // value instead of assuming map access.
  OmniError _fail(String label, int index, dynamic entry, String reason,
      [String? expected, String? actual]) {
    var msg = 'omni: ${_entryref(label, index, entry)}: $reason';

    if (null != expected) {
      msg += '\n  expected: $expected';
    }
    if (null != actual) {
      msg += '\n  actual:   $actual';
    }

    dynamic summary = entry;
    if (entry is Map) {
      final out = <String, dynamic>{};
      entry.forEach((key, val) {
        if ('res' != key && 'thrown' != key && 'ctx' != key) {
          out['$key'] = val;
        }
      });
      summary = out;
    }
    msg += '\n  entry:    ${stringify(summary)}';

    return OmniError(msg, entry);
  }
}

/// A loaded spec plus its provider.
class Runner {
  final dynamic _alltests;
  final Provider _provider;
  final int _specversion;

  Runner(this._alltests, this._provider, this._specversion);

  /// Resolve one named section of the spec.
  RunPack runner(String name, [dynamic store]) {
    final spec = resolvespec(name, _alltests);
    final clients = <String, Provider>{};

    final defclient = (spec is Map && spec['DEF'] is Map) ? spec['DEF']['client'] : null;

    // A spec may define clients that a given test run never references.
    if (defclient is Map && null != _provider.client) {
      defclient.forEach((clientname, cdef) {
        var copts = (cdef is Map && cdef['test'] is Map) ? cdef['test']['options'] : null;
        copts ??= <String, dynamic>{};

        if (null != _provider.inject && ismap(store)) {
          copts = _provider.inject!(copts, store);
        }

        clients['$clientname'] = _provider.client!(copts);
      });
    }

    final subject = _provider.subject?.call(name);

    return RunPack(spec, subject, _provider, clients, name, _specversion);
  }
}

/// Make a runner for a spec file path (or spec value) and a provider.
/// The spec's format version is resolved immediately - a version the
/// runner cannot faithfully run fails here, at load time, not on the
/// first `runset` call.
Runner makeRunner(dynamic specref, [Provider provider = const Provider()]) {
  final alltests = specref is String ? loadspec(specref) : specref;
  final specversion = _resolveversion(alltests);
  return Runner(alltests, provider, specversion);
}
