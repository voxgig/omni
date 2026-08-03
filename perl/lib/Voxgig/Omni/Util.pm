package Voxgig::Omni::Util;

# Omni internal JSON utilities.
#
# This module is deliberately self-contained: the omni runner must be able
# to test *any* library, including libraries that provide these same
# operations, so it can never borrow them from the system under test.
# Core modules only, by design.
#
# NOTE: Perl scalars are untyped, so a JSON string that looks like a number
# ("5") cannot be told apart from the number 5. This is the one place where
# the Perl port cannot distinguish two spec values that other ports can.

use strict;
use warnings;

use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);

use Exporter 'import';

our @EXPORT_OK = qw(
  ABSENT NULLMARK UNDEFMARK EXISTSMARK
  clone deepequal getpath isabsent isbool islist ismap isnode isnum
  jsonstr numstr pathify stringify walk
);

use constant NULLMARK   => '__NULL__';      # Value is JSON null.
use constant UNDEFMARK  => '__UNDEF__';     # Value is not present.
use constant EXISTSMARK => '__EXISTS__';    # Value exists (not undefined).

# Perl has undef for null, so absence needs its own marker.
{
    package Voxgig::Omni::Absent;
    use overload '""' => sub { 'ABSENT' }, 'bool' => sub { 0 }, fallback => 1;
    my $instance;
    sub mark { $instance ||= bless {}, __PACKAGE__; return $instance }
}

sub ABSENT { return Voxgig::Omni::Absent::mark() }

sub isabsent { my ($val) = @_; return blessed($val) && $val->isa('Voxgig::Omni::Absent') ? 1 : 0 }

# A map (JSON object)?
sub ismap { my ($val) = @_; return ref($val) eq 'HASH' ? 1 : 0 }

# A list (JSON array)?
sub islist { my ($val) = @_; return ref($val) eq 'ARRAY' ? 1 : 0 }

# A container (map or list)?
sub isnode { my ($val) = @_; return ismap($val) || islist($val) }

# A JSON boolean?
sub isbool { my ($val) = @_; return JSON::PP::is_bool($val) ? 1 : 0 }

# A JSON number? Booleans and references are not numbers.
sub isnum {
    my ($val) = @_;
    return 0 if !defined $val;
    return 0 if ref $val;
    return looks_like_number($val) ? 1 : 0;
}

# Deep copy a JSON value. Other values pass through by reference.
sub clone {
    my ($val) = @_;

    if ( islist($val) ) {
        return [ map { clone($_) } @$val ];
    }

    if ( ismap($val) ) {
        my %out;
        for my $key ( keys %$val ) {
            $out{$key} = clone( $val->{$key} );
        }
        return \%out;
    }

    return $val;
}

# Read a value by path. Returns ABSENT when any step is missing.
sub getpath {
    my ( $val, $path ) = @_;
    my $current = $val;

    for my $part (@$path) {
        if ( islist($current) ) {
            return ABSENT() if !looks_like_number($part);
            my $index = int($part);
            return ABSENT() if $index < 0 || $index >= scalar(@$current);
            $current = $current->[$index];
        }
        elsif ( ismap($current) ) {
            my $key = "$part";
            return ABSENT() if !exists $current->{$key};
            $current = $current->{$key};
        }
        else {
            return ABSENT();
        }
    }

    return $current;
}

# Depth-first walk: children first, then the containing node.
sub walk {
    my ( $val, $apply, $key, $parent, $path ) = @_;
    my $curpath = $path || [];

    if ( isnode($val) ) {
        if ( islist($val) ) {
            for my $index ( 0 .. $#$val ) {
                $val->[$index] =
                  walk( $val->[$index], $apply, $index, $val, [ @$curpath, $index ] );
            }
        }
        else {
            for my $childkey ( keys %$val ) {
                $val->{$childkey} =
                  walk( $val->{$childkey}, $apply, $childkey, $val, [ @$curpath, $childkey ] );
            }
        }
    }

    return $apply->( $key, $val, $parent, $curpath );
}

# Deep structural equality: numbers by value, bools never numbers.
sub deepequal {
    my ( $a, $b ) = @_;

    if ( isbool($a) || isbool($b) ) {
        return ( isbool($a) && isbool($b) && ( $a ? 1 : 0 ) == ( $b ? 1 : 0 ) ) ? 1 : 0;
    }

    if ( isabsent($a) || isabsent($b) ) {
        return ( isabsent($a) && isabsent($b) ) ? 1 : 0;
    }

    if ( !defined $a || !defined $b ) {
        return ( !defined $a && !defined $b ) ? 1 : 0;
    }

    if ( islist($a) && islist($b) ) {
        return 0 if scalar(@$a) != scalar(@$b);
        for my $index ( 0 .. $#$a ) {
            return 0 if !deepequal( $a->[$index], $b->[$index] );
        }
        return 1;
    }

    if ( ismap($a) && ismap($b) ) {
        return 0 if scalar( keys %$a ) != scalar( keys %$b );
        for my $key ( keys %$a ) {
            return 0 if !exists $b->{$key};
            return 0 if !deepequal( $a->{$key}, $b->{$key} );
        }
        return 1;
    }

    return 0 if ref($a) ne ref($b);

    if ( isnum($a) && isnum($b) ) {
        return ( $a == $b ) ? 1 : 0;
    }

    return ( "$a" eq "$b" ) ? 1 : 0;
}

# Render a number the same way in every port: 5.0 prints as 5.
sub numstr {
    my ($val) = @_;
    my $num = 0 + $val;
    if ( $num == int($num) && abs($num) < 2**53 ) {
        return sprintf( '%d', $num );
    }
    my $out = sprintf( '%.17g', $num );
    return $out;
}

sub quote {
    my ($val) = @_;
    my $text = defined $val ? "$val" : '';
    my $out  = '"';
    for my $char ( split //, $text ) {
        if    ( $char eq '"' )  { $out .= '\\"' }
        elsif ( $char eq "\\" ) { $out .= '\\\\' }
        elsif ( $char eq "\n" ) { $out .= '\\n' }
        elsif ( $char eq "\r" ) { $out .= '\\r' }
        elsif ( $char eq "\t" ) { $out .= '\\t' }
        elsif ( ord($char) < 0x20 ) { $out .= sprintf( '\\u%04x', ord($char) ) }
        else                        { $out .= $char }
    }
    return $out . '"';
}

# Compact JSON text with map keys sorted, identical in every port.
sub jsonstr {
    my ($val) = @_;

    return 'undefined' if isabsent($val);
    return 'null'      if !defined $val;
    return ( $val ? 'true' : 'false' ) if isbool($val);

    if ( islist($val) ) {
        return '[' . join( ',', map { jsonstr($_) } @$val ) . ']';
    }

    if ( ismap($val) ) {
        return '{'
          . join( ',', map { quote($_) . ':' . jsonstr( $val->{$_} ) } sort keys %$val ) . '}';
    }

    return '[Function]' if ref($val) eq 'CODE';

    return numstr($val) if isnum($val);

    return quote($val);
}

# Strings verbatim, everything else as compact JSON.
sub stringify {
    my ($val) = @_;
    return jsonstr($val) if isabsent($val) || !defined $val || ref($val) || isnum($val);
    return "$val";
}

# Render a path as a dotted string.
sub pathify {
    my ($path) = @_;
    return join( '.', map { "$_" } @{ $path || [] } );
}

1;
