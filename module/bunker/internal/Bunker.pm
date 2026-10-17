package Bunker;

use strict;
use warnings;
use feature 'signatures';
use Exporter 'import';
use MIME::Base64 qw(encode_base64 decode_base64);
use File::BaseDir qw(xdg_cache_home);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);

our @EXPORT_OK = qw(
    cache_file_path
    load_codes
    save_codes
    decode_bunker_codes
    encode_bunker_codes
    random_bunker_code
    pretty_code
    code_length
    max_simultaneous
);

sub code_length() {
    return $ENV{BUNKER_CODE_LENGHT} // 3;
}

sub max_simultaneous() {
    return $ENV{BUNKER_CODE_MAX_SIMULTANIOUS} // 3;
}

sub cache_file_path() {
    my $dir = xdg_cache_home() . '/bunker';
    make_path($dir) unless -d $dir;
    return "$dir/bunker-codes";
}

# Lines look like:
#   1: ZXhhbXBsZQo=
# The number is an id, not a line number -- ids are reused (the
# smallest available integer is handed out each time), so they
# don't necessarily stay in numeric order as codes come and go.
# What *is* meaningful is file order: codes are only ever appended,
# so line order == age order, oldest first.
sub decode_bunker_codes($lines) {
    my @codes;
    for my $line (@$lines) {
        chomp $line;
        next unless length $line;
        next unless $line =~ /^\s*(\d+)\s*:\s*(\S+)\s*$/;
        my ($id, $b64) = ($1, $2);
        push @codes, { id => $id, code => decode_base64($b64) };
    }
    return \@codes;
}

sub encode_bunker_codes($codes) {
    my @lines;
    for my $entry (@$codes) {
        push @lines, sprintf("%d: %s\n", $entry->{id}, encode_base64($entry->{code}, ''));
    }
    return \@lines;
}

sub load_codes() {
    my $file = cache_file_path();
    return [] unless -e $file;
    my @lines = read_file($file);
    return decode_bunker_codes(\@lines);
}

sub save_codes($codes) {
    my $file  = cache_file_path();
    my $lines = encode_bunker_codes($codes);
    write_file($file, @$lines);
}

my @ALPHABET = ('A' .. 'Z', '0' .. '9');

sub random_bunker_code($seed) {
    # XXX
    # $seed is typically the result of perl's own rand() (a float in
    # [0, 1)), passed in from the caller. srand() truncates its
    # argument to an integer, so seeding it directly would collapse
    # every call to srand(0) -- scale it up first so the fractional
    # part actually matters.
    srand(int($seed * 1_000_000_000)) if defined $seed;
    my $len  = code_length();
    my $code = '';
    $code .= $ALPHABET[int(rand(scalar @ALPHABET))] for 1 .. $len;
    return $code;
}

sub pretty_code($id, $code) {
    my $dashed = join('-', unpack('(A3)*', $code));
    return "\e[35m###\e[0m: \e[1m${id}\e[0m|${dashed}";
}

1;
