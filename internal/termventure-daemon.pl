#!/usr/bin/perl

use strict;
use warnings;
use feature 'signatures';
use Safe;
use FindBin qw($RealBin);
use Cwd qw(abs_path);
use IO::Select;
use IO::Socket::UNIX;
use DBI;
use Config::Tiny;
use Log::Dispatch;

our $config_file = "termventure.ini";
our $dirname     = abs_path("$RealBin/..");
our $sock_path   = "$RealBin/termventure.sock";
our $db_path     = "$RealBin/termventure.db";
our $log_path    = "$RealBin/termventure.log";

# state
our $config;
our @warnings;
our @modules;
our @triggers;

# identity of the socket we created
our $my_dev;
our $my_ino;

# SWP configuration
# The question we are answering to.
our $conf = "";

# -- Logging
my $log = Log::Dispatch->new(
    outputs => [[
        'File',
        min_level => 'debug',
        filename  => $log_path,
        mode      => 'append',
        newline   => 1,
        autoflush => 1,
    ]],
);

# -- Fish
# Responses are Fish scripts which are evaled.
# Both the protocol and fish eval expects a single line,
#  so semi-colons are mandatory.

# Quote a string for fish using single quotes
# Only \ and ' are special. A newline cannot live inside the quotes
# (it would break the line protocol), so it is spliced in as \n.
sub fq($str) {
    $str =~ s/([\\'])/\\$1/g;
    $str =~ s/\n/'\\n'/g;
    return "'$str'";
}

sub echo($msg) {
    return 'echo ' . fq($msg);
}

# Queue a warning; it is delivered with the next Push.
# The worker has no way to signal errors, so nothing here may die.
sub warn_fish($msg) {
    $log->warning($msg);
    push @warnings, 'echo ' . fq("termventure: $msg") . ' >&2';
}

sub take_warnings() {
    my @w = @warnings;
    @warnings = ();
    return @w;
}

# Build a Push line out of commands. Always valid fish, even when empty.
sub push_line(@cmds) {
    my $script = join '; ', grep { length } @cmds;
    $log->info($script);
    return '> ' . ($script || 'true') . "\n";
}

# Append every user-action/ to $PATH
sub make_path() {
    my @dirs = grep { -d } (
        "$dirname/user-action",
        map { "$dirname/module/$_/user-action" } @modules,
    );
    return '' unless @dirs;
    return 'set --global --export --append PATH ' . join ' ', map { fq($_) } @dirs;
}

# Append every internal/ to $TERMVENTURE_PATH
# $TERMVENTURE_PATH is temporarily appended to $PATH
#  before events are evaluated by the shell.
sub make_internal_path() {
    my @dirs = grep { -d } (
        "$dirname/internal",
        map { "$dirname/module/$_/internal" } @modules,
    );
    return '' unless @dirs;
    return 'set --global --export TERMVENTURE_PATH ' . join ' ', map { fq($_) } @dirs;
}

# -- Config
sub is_disabled($name) {
    return $name =~ /-disabled\z/;
}

# The trigger key is special, its handled by the daemon.
# The value is a hash, e.g.:
#
#    { "termimon-encounter" => 600 }
#              |                |
#          executable       fire odd
#
sub parse_triggers($module, $text) {
    # The leading + forces an anonymous hash instead of a block.
    # Prevents typo footguns, not actual safety.
    my $hash = Safe->new->reval("+$text");
    if ($@ || ref $hash ne 'HASH') {
        my $err = ($@ || 'not a hash literal') =~ s/\s+\z//r;
        warn_fish("module '$module': invalid trigger: $err");
        return;
    }

    my @found;
    for my $exe (sort keys %$hash) {
        my $odds = $hash->{$exe};
        unless (length $exe && defined $odds && !ref $odds
                && $odds =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/ && $odds > 0) {
            warn_fish("module '$module': invalid trigger entry '$exe'");
            next;
        }
        push @found, { module => $module, exe => $exe, odds => $odds };
    }
    return @found;
}

sub read_module_config($module) {
    # If it has any keys our config does not have, add it
    # Do not overwrite the central configuration
    my $file = "$dirname/module/$module/$module.ini";
    return unless -f $file;

    my $mod = Config::Tiny->read($file);
    unless ($mod) {
        warn_fish("cannot read $file: " . Config::Tiny->errstr);
        return;
    }

    for my $section (keys %$mod) {
        next if $section ne '_' && is_disabled($section);
        # keys outside any section belong to the module's own section
        my $target = $section eq '_' ? $module : $section;
        for my $key (keys %{ $mod->{$section} }) {
            $config->{$target}{$key} //= $mod->{$section}{$key};
        }
    }
}

sub load_config() {
    @modules  = ();
    @triggers = ();

    $config = Config::Tiny->read("$dirname/$config_file");
    unless ($config) {
        warn_fish("cannot read $config_file: " . Config::Tiny->errstr);
        $config = Config::Tiny->new;    # carry on with an empty config
    }

    delete $config->{$_} for grep { is_disabled($_) } keys %$config;

    for my $module (sort grep { $_ ne '_' } keys %$config) {
        if (-d "$dirname/module/$module") {
            push @modules, $module;
        } else {
            warn_fish("module '$module' does not exist in $dirname/module");
        }
    }

    read_module_config($_) for @modules;

    for my $module (@modules) {
        my $text = ($config->{$module} // {})->{trigger};
        push @triggers, parse_triggers($module, $text) if defined $text;
    }
}

# -- Registry
# A SQLite database tied to the lifetime of the daemon: created fresh on
# start-up, removed on exit. Modules reach it through termventure-get and
# termventure-set. It is a registry for module communication, not storage.
#
# Race resilience comes from SQLite itself: every write is a single atomic
# statement, WAL mode lets readers and a writer coexist, and the busy
# timeout makes concurrent writers queue instead of fail. Concurrent sets
# of the same key are last-write-wins, never a torn value.
sub remove_registry() {
    unlink map { "$db_path$_" } '', '-wal', '-shm';
}

sub init_registry() {
    remove_registry();

    my $old = umask 0077;               # owner only
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
    });
    umask $old;

    $dbh->sqlite_busy_timeout(5000);
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA synchronous = NORMAL');
    $dbh->do(<<'SQL');
CREATE TABLE registry (
    section TEXT NOT NULL,
    key     TEXT NOT NULL,
    value   TEXT NOT NULL,
    PRIMARY KEY (section, key)
) WITHOUT ROWID
SQL

    # Seed with the merged configuration, all or nothing.
    # Keys outside any section keep the section name "_".
    my $ins = $dbh->prepare('INSERT OR REPLACE INTO registry (section, key, value) VALUES (?, ?, ?)');
    $dbh->begin_work;
    for my $section (sort keys %$config) {
        for my $key (sort keys %{ $config->{$section} }) {
            $ins->execute($section, $key, $config->{$section}{$key});
        }
    }
    $dbh->commit;

    $dbh->disconnect;
}

# -- SWP
# NOTE:
# Everything is computed instantly, so we never answer with Pass.

sub on_bump() {
    # "a shared resource changed" - not used
}

sub respond() {
    if ($conf eq '') {
        return push_line(take_warnings(), roll_triggers());
    } elsif ($conf eq 'PATH') {
        return push_line(take_warnings(), make_path(), make_internal_path());
    }

    $log->error("Unknown conf state: $conf");
    return push_line(take_warnings());
}

sub handle($fh, $line) {
    my ($prefix, $payload) = $line =~ /\A(.)(?: (.*))?\z/s or return;
    $payload //= '';

    if    ($prefix eq '<') { on_bump() }
    elsif ($prefix eq '?') { $conf = $payload }
    elsif ($prefix eq '=') { syswrite $fh, respond() }
}

# -- Socket
# The registry is wiped on start-up, so a second daemon must never take
# over from a live one.
sub is_ours() {
    return 0 unless defined $my_ino;
    my @st = stat $sock_path or return 0;
    return $st[0] == $my_dev && $st[1] == $my_ino;
}

sub serve() {
    $SIG{PIPE} = 'IGNORE';
    $SIG{HUP}  = 'IGNORE'; # outlive the terminal that started us
    $SIG{TERM} = $SIG{INT} = sub { exit 0 };

    unlink $sock_path;                  # a new daemon always takes over

    my $old    = umask 0077;            # pushes get evaled: owner only
    my $server = IO::Socket::UNIX->new(Local => $sock_path, Listen => 16)
        or die "cannot listen on $sock_path: $!\n";
    umask $old;
    ($my_dev, $my_ino) = (stat $sock_path)[0, 1];

    my $sel = IO::Select->new($server);
    my %buf;

    while (1) {
        for my $fh ($sel->can_read(2)) {
            if ($fh == $server) {
                my $client = $server->accept or next;
                $client->blocking(0);
                $sel->add($client);
                $buf{$client} = '';
                next;
            }

            my $n = sysread $fh, my $chunk, 4096;
            if (defined $n && $n > 0) {
                $buf{$fh} .= $chunk;
                handle($fh, $1) while $buf{$fh} =~ s/\A([^\n]*)\n//;
            } elsif (defined $n || !$!{EAGAIN}) {   # EOF or real error
                $sel->remove($fh);
                delete $buf{$fh};
                close $fh;
            }
        }

        # superseded by a newer daemon
        exit 0 unless is_ours();
    }
}

END {
    # never delete a successor's files
    return unless is_ours();

    unlink $sock_path;
    remove_registry();
}

# ---
# Roll the dice for every trigger.
# The probability is 1/N, where N is the number defined by the config.
# The executable is only handed back.
# It may be interactive, so the shell has to run it.
sub roll_triggers() {
    my @hits = grep { rand($_->{odds}) < 1 } @triggers;
    $log->info("trigger: $_->{module}/$_->{exe} (1 in $_->{odds})") for @hits;
    return map { 'command ' . fq($_->{exe}) } @hits;
}

load_config();
eval { init_registry(); 1 } or do {
    my $err = $@ =~ s/\s+\z//r;
    warn_fish("cannot create registry: $err");
};
serve();
