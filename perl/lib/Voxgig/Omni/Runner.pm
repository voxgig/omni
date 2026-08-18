package Voxgig::Omni::Runner;

# Omni: the shared multi-language test runner.
#
# Port of the canonical TypeScript implementation
# (typescript/src/Runner.ts). Behaviour must match, case for case.

use strict;
use warnings;

use JSON::PP ();
use Scalar::Util qw(blessed reftype);

use Voxgig::Omni::Util qw(
  ABSENT NULLMARK UNDEFMARK EXISTSMARK
  clone deepequal getpath isabsent isbool islist ismap isnode isnum
  jsonstr pathify stringify walk
);

use Exporter 'import';
our @EXPORT_OK = qw(
  makeRunner loadspec resolvespec matchval match fixjson errify nullmodifier
  SPECVERSION CAPABILITIES
);

# The newest spec format version this runner understands. A spec with no
# OMNI block is version 0: the original, lenient format, frozen forever.
# Version 1 turns on strict entry validation (see checkentry).
use constant SPECVERSION => 1;

# Capability strings this runner supports beyond the version baseline. A
# spec's OMNI.requires list is checked against this: an unknown capability
# refuses the spec loudly at load time, instead of a lagging port silently
# mis-running it. (Empty today; future format features mint a string here.)
use constant CAPABILITIES => [];

# The complete set of fields an entry may carry. Under version 1 anything
# else is an error: an unrecognised key is almost always a typo'd
# assertion, and a typo'd assertion is a test that silently stopped
# testing.
use constant ENTRYFIELDS => [qw(in args ctx out err match client id doc)];

# A test failure (or a malformed spec). Distinct from errors thrown by the
# subject under test, which are candidates for an `err` expectation.
{
    package Voxgig::Omni::OmniError;
    use overload '""' => sub { $_[0]->{message} }, fallback => 1;

    sub new {
        my ( $class, $message, $entry ) = @_;
        return bless { message => $message, entry => $entry }, $class;
    }

    sub message { return $_[0]->{message} }
    sub entry   { return $_[0]->{entry} }
}

sub is_omni_error {
    my ($err) = @_;
    return ( blessed($err) && $err->isa('Voxgig::Omni::OmniError') ) ? 1 : 0;
}

# Load a spec: a path to a JSON file, or an already-parsed structure.
sub loadspec {
    my ($specref) = @_;

    if ( !ref $specref ) {
        open( my $handle, '<', $specref )
          or die Voxgig::Omni::OmniError->new( 'omni: cannot read spec: ' . $specref );
        local $/ = undef;
        my $text = <$handle>;
        close($handle);
        return JSON::PP->new->decode($text);
    }

    return $specref;
}

# Read the spec's format version from its optional top-level OMNI block,
# and refuse a spec this runner cannot faithfully run: a version newer
# than SPECVERSION, or a required capability not in CAPABILITIES.
sub resolveversion {
    my ($alltests) = @_;

    # JSON null decodes to undef, so `defined` cannot tell a null OMNI
    # block from an absent one - only `exists` can. A present-but-null
    # block is malformed, exactly as in canonical.
    return 0 if !ismap($alltests) || !exists $alltests->{OMNI};
    my $meta = $alltests->{OMNI};

    # Perl scalars are untyped: a JSON number is told apart from anything
    # else with isnum, and "integer" is int()-equality rather than typeof.
    if ( !ismap($meta)
        || !isnum( $meta->{version} )
        || 0 != ( $meta->{version} - int( $meta->{version} ) ) )
    {
        die Voxgig::Omni::OmniError->new('omni: malformed OMNI version block');
    }

    my $version = $meta->{version};

    if ( $version < 0 || SPECVERSION() < $version ) {
        die Voxgig::Omni::OmniError->new( 'omni: unsupported spec version: ' . $version );
    }

    if ( exists $meta->{requires} ) {
        my $requires = $meta->{requires};
        die Voxgig::Omni::OmniError->new('omni: malformed OMNI requires list')
          if !islist($requires);

        for my $cap (@$requires) {
            my $isstring = !ref($cap) && !isbool($cap);
            die Voxgig::Omni::OmniError->new(
                'omni: spec requires unsupported capability: ' . stringify($cap) )
              if !$isstring || !grep { $_ eq $cap } @{ CAPABILITIES() };
        }
    }

    return $version;
}

# Strict entry validation, applied when the spec declares version 1 or
# later. The lenient format converts each of these mistakes into a silent
# pass or a dead field; here they fail with the entry named.
sub checkentry {
    my ( $flags, $index, $entry ) = @_;

    die fail( $flags, $index, $entry, 'entry is not a map' ) if !ismap($entry);

    for my $key ( keys %$entry ) {
        die fail( $flags, $index, $entry, 'unknown entry field: ' . $key )
          if !grep { $_ eq $key } @{ ENTRYFIELDS() };
    }

    my $argsources = grep { exists $entry->{$_} } qw(in args ctx);
    die fail( $flags, $index, $entry, 'entry has more than one of in, args, ctx' )
      if 1 < $argsources;

    die fail( $flags, $index, $entry, 'entry has both err and out' )
      if defined $entry->{err} && exists $entry->{out};

    die fail( $flags, $index, $entry, 'entry id is not a string' )
      if exists $entry->{id}
      && ( !defined $entry->{id} || ref( $entry->{id} ) || isbool( $entry->{id} ) );

    return;
}

# Validate a version-1 group up front, against the AUTHORED entries -
# null-normalisation would otherwise rewrite an authored null (e.g.
# id: null) into a sentinel string and hide it from validation. A
# malformed spec is a spec error, not a test result, so it fails before
# any subject runs.
sub checkset {
    my ( $flags, $testspec, $normalset ) = @_;

    my $origset =
      ( ismap($testspec) && islist( $testspec->{set} ) ) ? $testspec->{set} : $normalset;

    my $empty = ismap($testspec) ? $testspec->{empty} : undef;
    my $isemptyok = ( isbool($empty) && $empty ) ? 1 : 0;
    die Voxgig::Omni::OmniError->new( 'omni: empty test set: ' . $flags->{name} )
      if 0 == scalar(@$origset) && !$isemptyok;

    for my $index ( 0 .. $#$origset ) {
        checkentry( $flags, $index, $origset->[$index] );
    }

    return;
}

# Find `primary.<name>`, then `<name>`, then the whole spec.
sub resolvespec {
    my ( $name, $alltests ) = @_;

    return $alltests if !defined $name;

    my $primary = ismap($alltests) ? $alltests->{primary} : undef;
    return $primary->{$name} if ismap($primary) && defined $primary->{$name};

    return $alltests->{$name} if ismap($alltests) && defined $alltests->{$name};

    return $alltests;
}

# Build the named clients declared by the spec's DEF.client block.
sub resolveclients {
    my ( $provider, $spec, $store ) = @_;
    my %clients;

    my $defclient =
      ( ismap($spec) && ismap( $spec->{DEF} ) ) ? $spec->{DEF}{client} : undef;
    return \%clients if !ismap($defclient);

    # A spec may define clients that a given test run never references.
    my $clientmaker = $provider->{client};
    return \%clients if !defined $clientmaker;

    for my $clientname ( keys %$defclient ) {
        my $cdef = $defclient->{$clientname};
        my $copts =
          clone( ( ismap($cdef) && ismap( $cdef->{test} ) ? $cdef->{test}{options} : undef ) || {} );

        my $injector = $provider->{inject};
        $injector->( $copts, $store ) if ismap($store) && defined $injector;

        $clients{$clientname} = $clientmaker->($copts);
    }

    return \%clients;
}

sub resolvesubject {
    my ( $name, $provider ) = @_;
    return undef if !defined $name || !defined $provider->{subject};
    return $provider->{subject}->($name);
}

sub resolveflags {
    my ($flags) = @_;
    my %out = %{ $flags || {} };
    $out{null} = !defined $out{null} ? 1 : ( $out{null} ? 1 : 0 );
    return \%out;
}

# An entry with no `out` expects a null (or absent) result.
sub resolveentry {
    my ( $entry, $flags ) = @_;
    $entry->{out} = NULLMARK if !defined $entry->{out} && $flags->{null};
    return $entry;
}

sub resolvetestpack {
    my ( $name, $entry, $subject, $provider, $clients ) = @_;
    my $testpack = { client => $provider, subject => $subject };

    if ( defined $entry->{client} ) {
        my $client = $clients->{ $entry->{client} };
        die Voxgig::Omni::OmniError->new( 'omni: unknown client: ' . $entry->{client}, $entry )
          if !defined $client;
        $testpack->{client}  = $client;
        $testpack->{subject} = resolvesubject( $name, $client ) || $subject;
    }

    return $testpack;
}

# Build the argument list: `ctx`, `args`, or `in`.
sub resolveargs {
    my ( $entry, $testpack, $provider ) = @_;
    my $args;

    if ( exists $entry->{ctx} ) {
        $args = [ $entry->{ctx} ];
    }
    elsif ( exists $entry->{args} ) {
        $args = $entry->{args};
    }
    else {
        $args = [ clone( $entry->{in} ) ];
    }

    if ( ( exists $entry->{ctx} || exists $entry->{args} ) && 0 < scalar(@$args) ) {
        my $first = $args->[0];
        if ( ismap($first) ) {
            $first = clone($first);
            my $contextify = $provider->{contextify};
            $first = $contextify->($first) if defined $contextify;
            $args->[0] = $first;
            $entry->{ctx} = $first;
            $first->{client} = $testpack->{client} if ismap($first);
        }
    }

    return $args;
}

# Nulls become NULLMARK, errors become {name,message}. Always a copy.
sub fixjson {
    my ( $val, $flags ) = @_;
    my $donull = ( !defined $flags || !defined $flags->{null} ) ? 1 : ( $flags->{null} ? 1 : 0 );
    return fixjsonval( $val, $donull );
}

sub fixjsonval {
    my ( $val, $donull ) = @_;

    if ( !defined $val || isabsent($val) ) {
        return $donull ? NULLMARK : undef;
    }

    return errify($val) if blessed($val) && $val->isa('Voxgig::Omni::OmniError');

    if ( islist($val) ) {
        return [ map { fixjsonval( $_, $donull ) } @$val ];
    }

    if ( ismap($val) ) {
        my %out;
        for my $key ( keys %$val ) {
            $out{$key} = fixjsonval( $val->{$key}, $donull );
        }
        return \%out;
    }

    return $val;
}

# The JSON form of an error: always at least {name,message}.
sub errify {
    my ($err) = @_;
    my $name = blessed($err) ? ref($err) : 'Error';
    return { name => $name, message => errmessage($err) };
}

# Perl's `die` decorates the message: `die "msg"` becomes "msg at FILE line
# N.\n", and `die "msg\n"` keeps the newline. Both are removed so that a
# message reads the same here as in every other port.
#
# Only that decoration is removed. A message whose own last character is a
# space keeps it - stripping trailing whitespace wholesale made Perl the one
# port where `err` could not pin such a message.
sub errmessage {
    my ($err) = @_;
    my $msg = "$err";
    $msg =~ s/ at \S+ line \d+\.?\n?$//;
    $msg =~ s/\n$//;
    return $msg;
}

# The label of one entry, for failure messages.
sub entryref {
    my ( $flags, $index, $entry ) = @_;
    my $label = $flags->{name} || 'set';
    my $entryid =
      ( ismap($entry) && defined $entry->{id} ) ? ' (' . $entry->{id} . ')' : '';
    return $label . '[' . $index . ']' . $entryid;
}

sub fail {
    my ( $flags, $index, $entry, $reason, $expected, $actual ) = @_;
    my $msg = 'omni: ' . entryref( $flags, $index, $entry ) . ': ' . $reason;
    $msg .= "\n  expected: " . $expected if defined $expected;
    $msg .= "\n  actual:   " . $actual   if defined $actual;
    $msg .= "\n  entry:    " . stringify( entrysummary($entry) );
    return Voxgig::Omni::OmniError->new( $msg, $entry );
}

# The spec-defined part of an entry (drop runner bookkeeping).
sub entrysummary {
    my ($entry) = @_;
    return $entry if !ismap($entry);
    my %out;
    for my $key ( keys %$entry ) {
        $out{$key} = $entry->{$key} if $key ne 'res' && $key ne 'thrown' && $key ne 'ctx';
    }
    return \%out;
}

sub checkresult {
    my ( $flags, $index, $entry, $args, $res ) = @_;
    my $matched = 0;

    if ( defined $entry->{err} ) {
        die fail( $flags, $index, $entry, 'expected error did not occur',
            stringify( $entry->{err} ), stringify($res) );
    }

    if ( defined $entry->{match} ) {
        match(
            $flags, $index, $entry,
            $entry->{match},
            {
                'in'  => $entry->{in},
                args  => $args,
                out   => $entry->{res},
                ctx   => $entry->{ctx},
            }
        );
        $matched = 1;
    }

    my $out = $entry->{out};

    return if deepequal( $res, $out );

    # NOTE: a match with no explicit out is a complete check on its own.
    return if $matched && ( !defined $out || ( !ref($out) && $out eq NULLMARK ) );

    die fail( $flags, $index, $entry, 'result mismatch', stringify($out), stringify($res) );
}

sub handleerror {
    my ( $flags, $index, $entry, $err ) = @_;

    my $entryerr = $entry->{err};

    if ( defined $entryerr ) {
        my $istrue = ( JSON::PP::is_bool($entryerr) && $entryerr ) ? 1 : 0;
        if ( $istrue || matchval( $entryerr, errmessage($err) ) ) {
            if ( defined $entry->{match} ) {
                match(
                    $flags, $index, $entry,
                    $entry->{match},
                    {
                        'in' => $entry->{in},
                        out  => $entry->{res},
                        ctx  => $entry->{ctx},
                        err  => errify($err),
                    }
                );
            }
            return;
        }

        die fail( $flags, $index, $entry, 'error mismatch', stringify($entryerr),
            errmessage($err) );
    }

    die fail( $flags, $index, $entry, 'unexpected error', undef, errmessage($err) );
}

# Check that every leaf of `check` is present, and matches, in `base`.
sub match {
    my ( $flags, $index, $entry, $check, $base ) = @_;
    my $cbase = clone($base);

    my $apply = sub {
        my ( $_key, $val, $_parent, $path ) = @_;

        my $where = 0 == scalar(@$path) ? '<root>' : pathify($path);

        return $val if isnode($val);

        my $baseval = getpath( $cbase, $path );

        return $val if deepequal( $val, $baseval );

        my $isleafstr = !ref($val) && defined($val);

        # Explicitly absent: satisfied only by a genuinely missing key, never
        # by a present null (the distinction the sentinels exist to keep).
        if ( $isleafstr && $val eq UNDEFMARK ) {
            return $val if isabsent($baseval);
            die fail( $flags, $index, $entry, 'expected absent at ' . $where,
                'absent', stringify($baseval) );
        }

        # Explicitly null: satisfied only by a present null.
        if ( $isleafstr && $val eq NULLMARK ) {
            return $val
              if !defined($baseval)
              || ( !ref($baseval) && $baseval eq NULLMARK );
            die fail( $flags, $index, $entry, 'expected null at ' . $where,
                'null', stringify($baseval) );
        }

        # Explicitly present: any present value, including null.
        if ( $isleafstr && $val eq EXISTSMARK ) {
            return $val if !isabsent($baseval);
            die fail( $flags, $index, $entry, 'expected present at ' . $where,
                'present', 'absent' );
        }

        # A concrete expectation never matches a missing key - a match leaf
        # against an absent value must fail, not substring-match "undefined".
        if ( isabsent($baseval) ) {
            die fail( $flags, $index, $entry, 'match failed at ' . $where,
                stringify($val), 'absent' );
        }

        if ( !matchval( $val, $baseval ) ) {
            die fail( $flags, $index, $entry, 'match failed at ' . $where,
                stringify($val), stringify($baseval) );
        }

        return $val;
    };

    walk( clone($check), $apply );
}

# Match one leaf: /regex/ or case-insensitive substring for strings.
sub matchval {
    my ( $check, $base ) = @_;

    return 1 if deepequal( $check, $base );

    my $want = $check;

    if ( !defined $want ) {
        return 1 if !defined $base || isabsent($base);
        return ( !ref($base) && $base eq NULLMARK ) ? 1 : 0;
    }

    return 1 if ref($want) eq 'CODE';

    if ( !ref($want) && !Voxgig::Omni::Util::isnum($want) ) {

        # An empty want would substring-match anything: reject it.
        return 0 if '' eq $want;

        my $basestr = stringify($base);

        if ( $want =~ m{^/(.+)/$}s ) {
            my $pattern = $1;
            return ( $basestr =~ /$pattern/ ) ? 1 : 0;
        }

        return ( index( lc($basestr), lc($want) ) >= 0 ) ? 1 : 0;
    }

    return deepequal( $want, $base );
}

# Convert NULLMARK sentinels back into real nulls.
sub nullmodifier {
    my ( $val, $key, $parent ) = @_;
    if ( !ref($val) && defined($val) && $val eq NULLMARK ) {
        if ( islist($parent) ) { $parent->[$key] = undef }
        else                   { $parent->{$key} = undef }
    }
    elsif ( !ref($val) && defined($val) ) {
        my $text = $val;
        $text =~ s/__NULL__/null/g;
        if ( islist($parent) ) { $parent->[$key] = $text }
        else                   { $parent->{$key} = $text }
    }
    return;
}

# Make a runner for a spec file (or spec structure) and a provider.
sub makeRunner {
    my ( $specref, $provider ) = @_;
    my $alltests    = loadspec($specref);
    my $specversion = resolveversion($alltests);
    my $useprovider = $provider || {};

    return sub {
        my ( $name, $store ) = @_;

        my $spec       = resolvespec( $name, $alltests );
        my $clients    = resolveclients( $useprovider, $spec, defined $store ? $store : {} );
        my $defsubject = resolvesubject( $name, $useprovider );

        my $runsetflags = sub {
            my ( $testspec, $flags, $testsubject ) = @_;

            my $useflags = resolveflags($flags);
            $useflags->{name} = $useflags->{name} || $name || 'set';

            my $subject = $testsubject || $defsubject;
            die Voxgig::Omni::OmniError->new( 'omni: no test subject for: ' . $useflags->{name} )
              if !defined $subject;

            my $testspecmap = fixjson( $testspec, $useflags );

            die Voxgig::Omni::OmniError->new( 'omni: test spec has no set: ' . $useflags->{name} )
              if !ismap($testspecmap) || !islist( $testspecmap->{set} );

            my $testset = $testspecmap->{set};

            checkset( $useflags, $testspec, $testset ) if 1 <= $specversion;

            for my $index ( 0 .. $#$testset ) {
                my $entry = $testset->[$index];

                my $ok = eval {
                    $entry = resolveentry( $entry, $useflags );

                    my $testpack = resolvetestpack( $name, $entry, $subject, $useprovider, $clients );
                    my $args = resolveargs( $entry, $testpack, $useprovider );

                    my $res = $testpack->{subject}->(@$args);
                    $res = fixjson( $res, $useflags );
                    $entry->{res} = $res;

                    checkresult( $useflags, $index, $entry, $args, $res );
                    1;
                };

                if ( !$ok ) {
                    my $err = $@;
                    die $err if is_omni_error($err);
                    handleerror( $useflags, $index, $entry, $err );
                }
            }

            return;
        };

        my $runset = sub {
            my ( $testspec, $testsubject ) = @_;
            return $runsetflags->( $testspec, {}, $testsubject );
        };

        return {
            spec        => $spec,
            runset      => $runset,
            runsetflags => $runsetflags,
            subject     => $defsubject,
            client      => $useprovider,
        };
    };
}

1;
