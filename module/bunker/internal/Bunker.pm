package Bunker;

# Shared code of the bunker module.
#
# Registry state:
#   codes      list literal of [id, code] pairs, oldest first,
#              e.g. [[2,'X7Q'],[1,'A0Z']]
#   paper      the [id, code] pair on the piece of paper that drifted by,
#              until somebody reads it
#   encounter  "true" while a door waits to be visited
use strict;
use warnings;
use feature 'signatures';
use Exporter 'import';
use Safe;
use Text::ParseWords qw(shellwords);

our @EXPORT_OK = qw(
    codes_load codes_save
    paper_load paper_save paper_clear
    encounter_active encounter_set encounter_clear
    max_concurrent code_size code_alphabet loot_table
    random_code pretty_code normalize_code
);

# -- Registry
# Exit status of termventure-get: 0 found, 1 not found, 2 registry unavailable.
sub reg_get($key) {
    open my $fh, '-|', 'termventure-get', 'bunker', $key
        or die "bunker: cannot run termventure-get: $!\n";
    my $value = do { local $/; <$fh> } // '';
    close $fh;
    my $status = $? >> 8;
    return undef if $status == 1;
    die "bunker: registry unavailable (is the daemon running?)\n" if $status;
    $value =~ s/\n\z//;
    return $value;
}

sub reg_set($key, $value) {
    system('termventure-set', 'bunker', $key, $value) == 0
        or die "bunker: cannot write '$key' to the registry\n";
}

# -- Literals
# Registry values are plain Perl literals, like the triggers.
# Codes are always quoted strings.
sub quote($text) {
    $text =~ s/([\\'])/\\$1/g;
    return "'$text'";
}

sub pair_literal($pair) {
    return sprintf '[%d,%s]', $pair->[0], quote($pair->[1]);
}

sub decode($text) {
    my $data = Safe->new->reval($text);
    return $@ ? undef : $data;
}

sub is_pair($pair) {
    return ref $pair eq 'ARRAY'
        && @$pair == 2
        && defined $pair->[0] && !ref $pair->[0] && $pair->[0] =~ /\A[1-9][0-9]*\z/
        && defined $pair->[1] && !ref $pair->[1] && length $pair->[1];
}

# -- Codes
sub codes_load() {
    my $text = reg_get('codes');
    return [] unless defined $text && length $text;

    my $list = decode($text);
    unless (ref $list eq 'ARRAY') {
        warn "bunker: ignoring malformed codes\n";
        return [];
    }
    return [ grep { is_pair($_) } @$list ];
}

sub codes_save($codes) {
    reg_set('codes', '[' . join(',', map { pair_literal($_) } @$codes) . ']');
}

# -- Paper
sub paper_load() {
    my $text = reg_get('paper');
    return undef unless defined $text && length $text;
    my $pair = decode($text);
    return is_pair($pair) ? $pair : undef;
}

sub paper_save($pair) {
    reg_set('paper', pair_literal($pair));
}

sub paper_clear() {
    reg_set('paper', '');
}

# -- Encounter
sub encounter_active() {
    return (reg_get('encounter') // '') eq 'true';
}

sub encounter_set() {
    reg_set('encounter', 'true');
}

sub encounter_clear() {
    reg_set('encounter', '');
}

# -- Configuration
# Anything missing or unusable falls back to the defaults of bunker.ini.
sub conf_uint($key, $min, $default) {
    my $value = reg_get($key);
    return defined $value && $value =~ /\A[0-9]+\z/ && $value >= $min
        ? $value + 0
        : $default;
}

sub max_concurrent() { return conf_uint('max-concurrent', 0, 3) }
sub code_size()      { return conf_uint('code-size',      1, 3) }

sub code_alphabet() {
    my $value = reg_get('code-alphabet') // '';
    $value =~ s/\A"(.*)"\z/$1/s;        # the ini quotes it
    return length $value ? $value : join '', 'A' .. 'Z', 0 .. 9;
}

sub loot_table() {
    my $value = reg_get('loot-table') // '';
    return ('echo', 'stone') unless $value =~ /\S/;

    my @words = shellwords($value);
    unless (@words) {
        warn "bunker: unusable loot-table '$value', using the default\n";
        return ('echo', 'stone');
    }
    return @words;
}

# -- Codes as text
sub random_code() {
    my @alphabet = split //, code_alphabet();
    return join '', map { $alphabet[int rand @alphabet] } 1 .. code_size();
}

sub pretty_code($id, $code) {
    my $dashed = join '-', unpack '(A3)*', $code;
    return "\e[35m###\e[0m: \e[1m${id}\e[0m|${dashed}";
}

# What a player types is compared with the code after this: dashes do not
# count and neither does case.
sub normalize_code($text) {
    $text =~ s/-//g;
    return uc $text;
}

1;
