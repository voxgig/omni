# RUN: prove -Ilib -It t/
# RUN-SOME: perl -Ilib -It t/ext.t
#
# The capability suite: spec/ext.json requires ctxargs, fn and wait, and
# every port that carries them runs it, beside the runner flag `all`.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Test::More tests => 15;

use Voxgig::Omni::Runner qw(makeRunner CAPABILITIES);
use Fib qw(fib fibinfo fibrange fibseq);

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

sub fibprovider {
    my %subjects = (
        fib      => sub { fib( $_[0] ) },
        fibseq   => sub { fibseq( $_[0] ) },
        fibrange => sub { fibrange( $_[0], $_[1] ) },
        fibinfo  => sub { fibinfo( $_[0] ) },
    );

    return {
        subject    => sub { return $subjects{ $_[0] } },
        contextify => sub { return { %{ $_[0] }, mark => 'CTX' } },
    };
}

# The ctxargs subject: the context comes first, and must arrive
# contextified with its client attached.
my $FIBSHIFTED = sub {
    my ( $ctx, $start, $end ) = @_;
    die "fib: context not delivered\n"
      if !defined $ctx->{mark} || 'CTX' ne $ctx->{mark} || !defined $ctx->{client};
    return fibrange( $start + $ctx->{shift}, $end + $ctx->{shift} );
};

my $FIB = sub { fib( $_[0] ) };

sub runner {
    my ($spec) = @_;
    return makeRunner( $spec, fibprovider() )->('fib');
}

sub v1 {
    my ( $requires, $set ) = @_;
    return { OMNI => { version => 1, requires => $requires }, fib => { g => { set => $set } } };
}

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

sub refuses {
    my ( $name, $run, $pattern ) = @_;
    my $ok  = eval { $run->(); 1 };
    my $err = $ok ? '' : $@;
    ok( !$ok && Voxgig::Omni::Runner::is_omni_error($err) && "$err" =~ $pattern, $name )
      or diag( $ok ? 'the run passed' : "$err" );
}

subtest 'capabilities' => sub {
    plan tests => 3;
    for my $cap (qw(ctxargs fn wait)) {
        ok( ( grep { $_ eq $cap } @{ CAPABILITIES() } ), $cap );
    }
};

my $R = runner( specfile('ext.json') );

group( 'ctxargs', sub { $R->{runset}->( $R->{spec}{ctxargs}, $FIBSHIFTED ) } );
group( 'fn',      sub { $R->{runset}->( $R->{spec}{fn},      $FIB ) } );
group( 'wait',    sub { $R->{runset}->( $R->{spec}{wait},    $FIB ) } );

{
    my $W = runner( v1( ['wait'], [ { 'in' => 5, out => 5, wait => { cause => 'gone#1' } } ] ) );
    refuses( 'a waiting entry that passes fails the set',
        sub { $W->{runset}->( $W->{spec}{g}, $FIB ) }, qr/\[0\]: stale wait: gone#1/ );
}

{
    my $W = runner( v1( [], [ { id => 'a', 'in' => 6, out => 9 }, { 'in' => 7, out => 13 } ] ) );
    group( 'the wait flag holds an entry by id',
        sub { $W->{runsetflags}->( $W->{spec}{g}, { wait => { a => { cause => 'flag#1' } } }, $FIB ) } );
}

{
    my $W = runner( v1( [], [ { id => 'a', 'in' => 6, out => 8 } ] ) );
    refuses( 'the wait flag fails when its entry passes',
        sub { $W->{runsetflags}->( $W->{spec}{g}, { wait => { a => { cause => 'flag#1' } } }, $FIB ) },
        qr/stale wait: flag#1/ );
}

{
    my $W = runner( v1( [], [ { id => 'a', 'in' => 6, out => 8 } ] ) );
    refuses( 'the wait flag must name an entry',
        sub { $W->{runsetflags}->( $W->{spec}{g}, { wait => { zz => { cause => 'c' } } }, $FIB ) },
        qr/wait names no entry: zz/ );
}

{
    my $W = runner( v1( ['wait'], [ { 'in' => 6, out => 9, wait => {} } ] ) );
    refuses( 'a wait needs a cause',
        sub { $W->{runset}->( $W->{spec}{g}, $FIB ) }, qr/entry wait has no cause/ );
}

subtest 'wait and fn are unknown fields unless required' => sub {
    plan tests => 2;
    my $W = runner( v1( [], [ { 'in' => 6, out => 9, wait => { cause => 'c' } } ] ) );
    refuses( 'wait', sub { $W->{runset}->( $W->{spec}{g}, $FIB ) }, qr/unknown entry field: wait/ );
    my $F = runner( v1( [], [ { fn => 'fib', 'in' => 6, out => 8 } ] ) );
    refuses( 'fn', sub { $F->{runset}->( $F->{spec}{g}, $FIB ) }, qr/unknown entry field: fn/ );
};

{
    my $U = runner( v1( ['fn'], [ { fn => 'nope', 'in' => 6, out => 8 } ] ) );
    refuses( 'an unknown fn is a spec error',
        sub { $U->{runset}->( $U->{spec}{g}, $FIB ) }, qr/unknown fn: nope/ );
}

subtest 'ctx with args needs ctxargs, and never takes in' => sub {
    plan tests => 2;
    my $N = runner( v1( [], [ { ctx => { shift => 0 }, args => [ 0, 1 ], out => [ 0, 1 ] } ] ) );
    refuses( 'ctx with args', sub { $N->{runset}->( $N->{spec}{g}, $FIBSHIFTED ) },
        qr/more than one of in, args, ctx/ );
    my $I = runner( v1( ['ctxargs'], [ { 'in' => 1, ctx => { shift => 0 }, out => [0] } ] ) );
    refuses( 'in with ctx', sub { $I->{runset}->( $I->{spec}{g}, $FIBSHIFTED ) },
        qr/entry has in beside args or ctx/ );
};

{
    my $L = runner(
        { fib => { g => { set => [ { 'in' => 6, out => 8, fn => 'nope', wait => { cause => 'c' } } ] } } }
    );
    group( 'a legacy spec ignores fn and wait', sub { $L->{runset}->( $L->{spec}{g}, $FIB ) } );
}

subtest 'all reports every failure at once' => sub {
    plan tests => 2;
    my $A = runner( v1( [], [ { 'in' => 5, out => 6 }, { 'in' => 6, out => 8 }, { 'in' => 7, out => 14 } ] ) );
    refuses( 'all',
        sub { $A->{runsetflags}->( $A->{spec}{g}, { all => JSON::PP::true }, $FIB ) },
        qr/\Aomni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch/s );
    refuses( 'first failure alone',
        sub { $A->{runset}->( $A->{spec}{g}, $FIB ) }, qr/\Aomni: fib\[0\]: result mismatch/ );
};

# Booleans are not numbers: `all => 1` is not `true`, as in canonical.
{
    my $A = runner( v1( [], [ { 'in' => 5, out => 6 }, { 'in' => 7, out => 14 } ] ) );
    refuses( 'the all flag is a boolean, never a number',
        sub { $A->{runsetflags}->( $A->{spec}{g}, { all => 1 }, $FIB ) },
        qr/\Aomni: fib\[0\]: result mismatch/ );
}
