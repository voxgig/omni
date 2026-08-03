package Fib;

# The system under test: a tiny Fibonacci library.
#
# Every omni port ships this same library, with the same behaviour and the
# same error messages, and tests it with the same spec file
# (spec/fib.json).

use strict;
use warnings;

use JSON::PP ();

use Voxgig::Omni::Util qw(isnum stringify);

use Exporter 'import';
our @EXPORT_OK = qw(fib fibindex fibinfo fibrange fibseq);

# Validate a Fibonacci index. The spec matches on these messages.
sub fibindex {
    my ($val) = @_;

    die "fib: not a number: " . stringify($val) . "\n" if !isnum($val);

    die "fib: non-integer index: " . stringify($val) . "\n" if 0 != ( $val - int($val) );

    die "fib: negative index: " . stringify($val) . "\n" if $val < 0;

    return int($val);
}

# The nth Fibonacci number: fib(0)=0, fib(1)=1.
sub fib {
    my ($n)   = @_;
    my $index = fibindex($n);

    return 0 if 0 == $index;

    my $prev = 0;
    my $cur  = 1;

    for my $i ( 1 .. $index - 1 ) {
        my $next = $prev + $cur;
        $prev = $cur;
        $cur  = $next;
    }

    return $cur;
}

# The first n Fibonacci numbers.
sub fibseq {
    my ($n) = @_;
    my $count = fibindex($n);
    return [ map { fib($_) } ( 0 .. $count - 1 ) ];
}

# The Fibonacci numbers from index start to index end, inclusive.
sub fibrange {
    my ( $start, $end ) = @_;
    my $from = fibindex($start);
    my $to   = fibindex($end);
    return [] if $to < $from;
    return [ map { fib($_) } ( $from .. $to ) ];
}

# A description of the nth Fibonacci number. `prev` is undef at index 0,
# which exercises the runner's null handling.
sub fibinfo {
    my ($n)   = @_;
    my $index = fibindex($n);
    my $val   = fib($index);

    return {
        n     => $index,
        val   => $val,
        even  => ( 0 == $val % 2 ) ? JSON::PP::true : JSON::PP::false,
        prev  => ( 0 == $index ) ? undef : fib( $index - 1 ),
        label => 'fib(' . stringify($index) . ')=' . stringify($val),
    };
}

1;
