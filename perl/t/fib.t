# RUN: prove -Ilib -It t/
# RUN-SOME: perl -Ilib -It t/fib.t
#
# The Fibonacci conformance suite: every omni port runs this same set of
# groups, from the same spec/fib.json, against the same fib library.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use Test::More tests => 19;

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
sub fibprovider {
    my ($shift) = @_;

    my %subjects = (
        fib      => sub { fib( Voxgig::Omni::Util::isnum( $_[0] ) ? $_[0] + $shift : $_[0] ) },
        fibseq   => sub { fibseq( $_[0] ) },
        fibrange => sub { fibrange( $_[0], $_[1] ) },
        fibinfo  => sub { fibinfo( $_[0] ) },
    );

    return {
        subject => sub { return $subjects{ $_[0] } },
        client  => sub { return fibprovider( $_[0]->{shift} || 0 ) },
    };
}

my $FIB      = sub { fib( $_[0] ) };
my $FIBSEQ   = sub { fibseq( $_[0] ) };
my $FIBRANGE = sub { fibrange( $_[0], $_[1] ) };
my $FIBINFO  = sub { fibinfo( $_[0] ) };

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

        # An empty container asserts an empty container, not "anything".
        emptymatch => { set => [ { 'in' => 6, match => { out => {} } } ] },

        # An empty-string want is not a wildcard substring match.
        emptystr => { set => [ { 'in' => 6, match => { out => { label => '' } } } ] },
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
ok( expectfail( 'emptymatch',   $FIBINFO ), 'an empty match container is not vacuous' );
ok( expectfail( 'emptystr',     $FIBINFO ), 'an empty-string match leaf is not a wildcard' );

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
