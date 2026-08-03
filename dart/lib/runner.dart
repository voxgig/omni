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

  const Provider({this.subject, this.client, this.contextify, this.inject});
}

/// Load a spec: a path to a JSON file.
dynamic loadspec(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw OmniError('omni: cannot read spec: $path');
  }
  return jsonDecode(file.readAsStringSync());
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
    return donull ? NULLMARK : null;
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

  RunPack(this.spec, this.subject, this._provider, this._clients, this._name)
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
      args = [clone(entry['in'])];
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
            'err': errify(err),
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
    // An empty container asserts structure the recursion would otherwise
    // skip: it visits no leaves inside {} or [], so `match:{out:{}}` used
    // to pass any result. Require the base at this path to be an equal
    // empty container. (The synthetic root wrapper is never empty, so
    // skip it.)
    final isemptynode =
        (check is List && check.isEmpty) || (check is Map && check.isEmpty);
    if (isemptynode && path.isNotEmpty) {
      final baseval = getpath(base, path);
      if (!deepequal(check, baseval)) {
        throw _fail(label, index, entry, 'match failed at ${_at(path)}',
            stringify(check), stringify(baseval));
      }
      return;
    }

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

    if (deepequal(check, baseval)) {
      return;
    }

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
  String _entryref(String label, int index, Map entry) {
    final id = entry['id'];
    final idpart = null == id ? '' : ' (${stringify(id)})';
    return '$label[$index]$idpart';
  }

  OmniError _fail(String label, int index, Map entry, String reason,
      [String? expected, String? actual]) {
    var msg = 'omni: ${_entryref(label, index, entry)}: $reason';

    if (null != expected) {
      msg += '\n  expected: $expected';
    }
    if (null != actual) {
      msg += '\n  actual:   $actual';
    }

    final summary = <String, dynamic>{};
    entry.forEach((key, val) {
      if ('res' != key && 'thrown' != key && 'ctx' != key) {
        summary['$key'] = val;
      }
    });
    msg += '\n  entry:    ${stringify(summary)}';

    return OmniError(msg, entry);
  }
}

/// A loaded spec plus its provider.
class Runner {
  final dynamic _alltests;
  final Provider _provider;

  Runner(this._alltests, this._provider);

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

    return RunPack(spec, subject, _provider, clients, name);
  }
}

/// Make a runner for a spec file path (or spec value) and a provider.
Runner makeRunner(dynamic specref, [Provider provider = const Provider()]) {
  final alltests = specref is String ? loadspec(specref) : specref;
  return Runner(alltests, provider);
}
