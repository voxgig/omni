package Voxgig::Omni;

# voxgig omni - shared multi-language test runner.

use strict;
use warnings;

use Voxgig::Omni::Util;
use Voxgig::Omni::Runner;

use Exporter 'import';
our @EXPORT_OK = qw(makeRunner);

our $VERSION = '0.1.0';

sub makeRunner {
    my ( $specref, $provider ) = @_;
    return Voxgig::Omni::Runner::makeRunner( $specref, $provider );
}

1;
