# RUN: prove -Ilib -It t/
# RUN-SOME: perl -Ilib -It t/fib.t
#
# The Fibonacci conformance suite: every omni port runs this same set of
# groups, from the same spec/fib.json, against the same fib library.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Test::More tests => 29;

use Voxgig::Omni::Runner qw(makeRunner);
use Fib qw(fib fibinfo fibrange fibseq);

# Find the shared spec directory by walking up from this file.
sub specfile {
    my ($name) = @_;
    my $dir = dirname( File::Spec->rel2abs(__FILE__) );
    for ( 1 .. 8 ) {
        my $cand = File::Spec->catfile( $dir, 'spec', $name );
        return $cand if -e $cand;
        $dir = dirname($dir);
    }
    die "omni: spec not found: $name";
}

# The provider hosts the system under test. `shift` offsets the Fibonacci
# index, so that a client-specific subject is observably different.
# `contextify` marks the map, so the context group can prove the hook ran.
sub fibprovider {
    my ($shift) = @_;

    my %subjects = (
        fib      => sub { fib( Voxgig::Omni::Util::isnum( $_[0] ) ? $_[0] + $shift : $_[0] ) },
        fibseq   => sub { fibseq( $_[0] ) },
        fibrange => sub { fibrange( $_[0], $_[1] ) },
        fibinfo  => sub { fibinfo( $_[0] ) },
    );

    return {
        subject    => sub { return $subjects{ $_[0] } },
        client     => sub { return fibprovider( $_[0]->{shift} || 0 ) },
        contextify => sub { return { %{ $_[0] }, mark => 'CTX' } },
    };
}

my $FIB      = sub { fib( $_[0] ) };
my $FIBSEQ   = sub { fibseq( $_[0] ) };
my $FIBRANGE = sub { fibrange( $_[0], $_[1] ) };
my $FIBINFO  = sub { fibinfo( $_[0] ) };

# A subject that returns the literal string "__UNDEF__" as ordinary data,
# not as a sentinel - the runner must not treat it as "key absent".
my $FIBLITUNDEF = sub { return { a => '__UNDEF__' } };

# The context-group subject: reports what the runner delivered - the
# contextify mark and the attached client - as plain data, so the spec can
# pin both with an ordinary `out` comparison.
my $FIBCTX = sub {
    my ($ctx) = @_;
    return {
        n         => $ctx->{n},
        val       => fib( $ctx->{n} ),
        mark      => $ctx->{mark},
        hasclient => defined( $ctx->{client} ) ? JSON::PP::true : JSON::PP::false,
    };
};

my $R = makeRunner( specfile('fib.json'), fibprovider(0) )->('fib');

my $spec        = $R->{spec};
my $runset      = $R->{runset};
my $runsetflags = $R->{runsetflags};

# Run one group, reporting pass or fail through Test::More.
sub group {
    my ( $name, $body ) = @_;
    my $ok = eval { $body->(); 1 };
    if ($ok) {
        pass($name);
    }
    else {
        fail($name);
        diag("$@");
    }
}

group( 'basic',     sub { $runset->( $spec->{basic}, $FIB ) } );
group( 'seq',       sub { $runset->( $spec->{seq},   $FIBSEQ ) } );
group( 'range',     sub { $runset->( $spec->{range}, $FIBRANGE ) } );
group( 'info',      sub { $runset->( $spec->{info},  $FIBINFO ) } );
group( 'nulls',     sub { $runsetflags->( $spec->{nulls}, { null => 0 }, $FIBINFO ) } );
group( 'error',     sub { $runset->( $spec->{error},     $FIB ) } );
group( 'match',     sub { $runset->( $spec->{match},     $FIB ) } );
group( 'matchinfo', sub { $runset->( $spec->{matchinfo}, $FIBINFO ) } );
group( 'client',    sub { $runset->( $spec->{client},    $FIB ) } );
group( 'context',   sub { $runset->( $spec->{context},   $FIBCTX ) } );

# The runner must fail when the subject is wrong - otherwise a green suite
# means nothing.
my $BADSPEC = {
    fib => {
        wrongout   => { set => [ { 'in' => 5, out => 5 }, { 'in' => 6, out => 999 } ] },
        wrongerr   => { set => [ { 'in' => 1, err => 'never happens' } ] },
        wrongmatch => { set => [ { 'in' => 6, match => { out => 999 } } ] },
        missing    => { set => [ { 'in' => 6, match => { out => { nope => '__EXISTS__' } } } ] },

        # A concrete match leaf against a missing key must fail, not
        # substring-match the text "undefined".
        matchabsent => { set => [ { 'in' => 6, match => { out => { nope => 'fine' } } } ] },

        # __UNDEF__ (absent) must not be satisfied by a present null.
        undefonnull => { set => [ { 'in' => 0, match => { out => { prev => '__UNDEF__' } } } ] },

        # __NULL__ (present null) must not be satisfied by an absent key.
        nullonabsent => { set => [ { 'in' => 6, match => { out => { nope => '__NULL__' } } } ] },

        # An empty-string want is not a wildcard substring match.
        emptystr => { set => [ { 'in' => 6, match => { out => { label => '' } } } ] },

        # A subject returning the literal "__UNDEF__" as ordinary data must
        # not satisfy an assertion that the key is absent - a sentinel that
        # accepts its own literal is not a sentinel.
        wrongundef => { set => [ { 'in' => 1, match => { out => { a => '__UNDEF__' } } } ] },
    }
};

sub expectfail {
    my ( $setname, $subject ) = @_;
    my $bad = makeRunner($BADSPEC)->('fib');
    my $ok  = eval { $bad->{runset}->( $bad->{spec}{$setname}, $subject ); 1 };
    return ( !$ok && Voxgig::Omni::Runner::is_omni_error($@) ) ? 1 : 0;
}

ok( expectfail( 'wrongout',   $FIB ),     'detects wrong result' );
ok( expectfail( 'wrongerr',   $FIB ),     'detects missing error' );
ok( expectfail( 'wrongmatch', $FIB ),     'detects failed match' );
ok( expectfail( 'missing',    $FIBINFO ), 'detects absent key' );

ok( expectfail( 'matchabsent',  $FIBINFO ), 'a concrete match leaf does not match a missing key' );
ok( expectfail( 'undefonnull',  $FIBINFO ), '__UNDEF__ does not match a present null' );
ok( expectfail( 'nullonabsent', $FIBINFO ), '__NULL__ does not match an absent key' );
ok( expectfail( 'emptystr',     $FIBINFO ), 'an empty-string match leaf is not a wildcard' );
ok( expectfail( 'wrongundef',   $FIBLITUNDEF ),
    'the literal "__UNDEF__" as data does not satisfy __UNDEF__' );

# makeRunner refuses a spec version it cannot faithfully run before ever
# returning a runner - fail fast, at load time.
sub expectloadfail {
    my ( $specref, $pattern ) = @_;
    my $ok = eval { makeRunner($specref); 1 };
    return 0 if $ok;
    return ( Voxgig::Omni::Runner::is_omni_error($@) && "$@" =~ $pattern ) ? 1 : 0;
}

ok( expectloadfail( { OMNI => { version => 99 }, fib => { g => { set => [] } } },
        qr/unsupported spec version/ ),
    'rejects an unsupported spec version' );

ok( expectloadfail(
        { OMNI => { version => 1, requires => ['nosuchfeature'] }, fib => { g => { set => [] } } },
        qr/unsupported capability/
    ),
    'rejects an unknown required capability' );

ok( expectloadfail( { OMNI => { version => 'one' }, fib => { g => { set => [] } } },
        qr/malformed OMNI/ ),
    'rejects a malformed version block' );

# Strict (version 1) entry validation - each of these is a silent pass or a
# dead field under the legacy (no OMNI block) format.
sub expectstrictfail {
    my ( $specref, $groupname, $subject, $pattern ) = @_;
    my $strict = makeRunner($specref)->('fib');
    my $ok = eval { $strict->{runset}->( $strict->{spec}{$groupname}, $subject ); 1 };
    return 0 if $ok;
    return ( Voxgig::Omni::Runner::is_omni_error($@) && "$@" =~ $pattern ) ? 1 : 0;
}

ok( expectstrictfail(
        { OMNI => { version => 1 },
          fib => { g => { set => [ { 'in' => 6, matches => { out => 999 } } ] } } },
        'g', $FIBINFO, qr/unknown entry field: matches/
    ),
    'strict: an unknown entry field fails instead of passing vacuously' );

ok( expectstrictfail(
        { OMNI => { version => 1 },
          fib => { g => { set => [ { 'in' => 5, args => [5], out => 5 } ] } } },
        'g', $FIB, qr/more than one of in, args, ctx/
    ),
    'strict: more than one of in, args, ctx fails' );

ok( expectstrictfail(
        { OMNI => { version => 1 },
          fib => { g => { set => [ { 'in' => -1, err => 1, out => 5 } ] } } },
        'g', $FIB, qr/both err and out/
    ),
    'strict: err together with out fails' );

ok( expectstrictfail(
        { OMNI => { version => 1 },
          fib => { g => { set => [ { 'in' => 1, out => 1, id => undef } ] } } },
        'g', $FIB, qr/entry id is not a string/
    ),
    'strict: a null id fails even under null-normalisation' );

subtest 'strict: an empty set fails unless marked empty' => sub {
    plan tests => 2;

    my $strict = makeRunner(
        { OMNI => { version => 1 },
          fib => { g => { set => [] }, h => { set => [], empty => JSON::PP::true } } }
    )->('fib');

    my $ok  = eval { $strict->{runset}->( $strict->{spec}{g}, $FIB ); 1 };
    my $msg = $ok ? '' : "$@";
    like( $msg, qr/empty test set/, 'an unmarked empty set fails' );

    ok( ( eval { $strict->{runset}->( $strict->{spec}{h}, $FIB ); 1 } ? 1 : 0 ),
        'a set marked empty:true passes' );
};

ok( ( eval {
            my $legacy = makeRunner(
                { fib => { g => { set => [ { 'in' => 6, matches => { out => 999 }, out => 8 } ] } } }
            )->('fib');
            $legacy->{runset}->( $legacy->{spec}{g}, $FIB );
            1;
        } ? 1 : 0
    ),
    'a legacy spec (no OMNI block) stays lenient' );

subtest 'reports entry index and id' => sub {
    plan tests => 3;

    my $bad = makeRunner(
        { fib => { g => { set => [ { 'in' => 1, out => 1 }, { id => 'x#2', 'in' => 2, out => 42 } ] } } }
    )->('fib');

    my $ok = eval { $bad->{runset}->( $bad->{spec}{g}, $FIB ); 1 };
    my $msg = $ok ? '' : "$@";

    like( $msg, qr/\Qfib[1] (x#2)\E/, 'has entry ref' );
    like( $msg, qr/expected: 42/,     'has expected' );
    like( $msg, qr/actual:   1/,      'has actual' );
};
