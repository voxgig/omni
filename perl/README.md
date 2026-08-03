# omni - Perl

Perl port of the canonical TypeScript implementation. Core modules only.

```sh
prove -Ilib -It t/
```

## Use

```perl
use Voxgig::Omni::Runner qw(makeRunner);

my $provider = { subject => sub { $SUBJECTS{ $_[0] } } };

my $R = makeRunner( 'spec/fib.json', $provider )->('fib');

$R->{runset}->( $R->{spec}{basic}, $FIB );
$R->{runsetflags}->( $R->{spec}{nulls}, { null => 0 }, $FIBINFO );
```

A failing check dies with a `Voxgig::Omni::OmniError` object, which
`Test::More` reports through the enclosing test.

## Layout

| File | Contents |
|---|---|
| `lib/Voxgig/Omni/Runner.pm` | the runner |
| `lib/Voxgig/Omni/Util.pm` | clone, deep equality, path lookup, walk, stringify |
| `lib/Voxgig/Omni.pm` | the public API |
| `t/Fib.pm` | the system under test |
| `t/fib.t` | the shared conformance suite |

## Notes

- Core modules only: `JSON::PP`, `Scalar::Util`, `Test::More`.
- Perl scalars are untyped, so the string `"5"` and the number `5` cannot
  be told apart. Booleans are `JSON::PP::Boolean` objects, and a subject
  that returns a boolean must return `JSON::PP::true`/`false`.
- Absence is the `Voxgig::Omni::Absent` singleton; `undef` is a real null.
- Error messages are stripped of Perl's ` at FILE line N.` suffix before
  matching, so `err` expectations stay portable.
