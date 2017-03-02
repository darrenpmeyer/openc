#!/usr/bin/env perl
require 5.000_000;
use strict; use warnings;
use constant DEBUG => $ENV{DEBUG} || 0;  # set 1 to enable debug logging

# core modules
use POSIX ':sys_wait_h';  # POSIX syswait constants, e.g. WNOHANG
use POSIX 'strftime';     # POSIX strftime function
use Symbol 'gensym';      # Allow creation of an anonymous filehandle
use IO::Select;           # select() calls on multiple handles
use IPC::Open3;           # open3() - interaction with child in/out/err
use Time::HiRes 'time','sleep'; # sub-second time() and sleep()
use Term::ANSIColor;      # color() and colored() for ANSI term support
use Term::ReadLine;       # readline() support
use File::Spec;           # OS-independent path manipulation

# non-core modules
use Getopt::Long;
use Term::ReadPassword;  # imports read_password() for quiet secret reading
# use Net::Ping;         # for future use -> verifies/watchdogs the connection

# global configuration
$Term::ReadPassword::USE_STARS = 1;
our @SUDO = ('sudo', '-S', '-p', '(sudo) password for %p: ');
our @RETURN; # for handlers to do inter-sub communication
our @CONF_PATH = (File::Spec->catdir($ENV{HOME}, '.openc'), $ENV{HOME});
our $LOG_OUT = 'stdout.log';
our $LOG_ERR = 'stderr.log';

# Below line enables Carp::Always, Data::Dumper, and Sub::Util for debugging
if (DEBUG) { eval 'require Carp::Always; Carp::Always->import(); use Data::Dumper; use Sub::Util "subname";'; }

# utility subs
sub timestamp() {
    return strftime('%Y-%m-%dT%H:%M:%S ', localtime(time()));
}


sub say(@) {
    # writing to STDERR with a utility; adds timestamps in DEBUG mode
    my $pre = "# ";
    DEBUG and $pre = timestamp() . $pre;
    print STDERR colored(
        ['bright_red'],
        $pre, @_, "\n"
        );
}


sub wrlog($@) {
    my ($fh) = shift @_;
    eval {
        for my $ch (@_) {
            print $fh $ch;
            if ($ch =~ /\n$/) { print $fh timestamp() }
        }
    };
    if ($@) {
        say "Error writing to log: $!"
    }
}

sub file_mode($) {
    # returns file mode as either an octal string or an array
    my ($file) = @_;
    my $rawmode = sprintf "%o", (stat($file))[2] &0777;
    DEBUG and say "Mode for '$file' is $rawmode";
    return wantarray ? split('',$rawmode) : $rawmode;
}


sub file_mode_max($$) {
    # determines if a file has a mode exceeding a max_mode
    # file_mode_max "filename", 0644  ;;  returns true iff filename's mode is less than 0644
    my ($file, $max_mode) = @_;
    my @mode = file_mode($file);
    my @max_mode = split('', sprintf("%03o", $max_mode));
    DEBUG and say "Mode: ", Dumper(\@mode), ' vs Max: ', Dumper(\@max_mode);
    foreach my $i (0..$#mode) {
        if ($mode[$i] > $max_mode[$i]) { return 0; }
    }

    return 1;
}

sub search_config_file {
    # returns the full path to a named file in the @CONF_PATH
    # e.g. search_config_path('.opencpw') might return '/etc/openc/.opencpw'
    # Always returns the FIRST MATCH; if more than one filename is provided, they are searched in order
    # and the first one to be found is returned
    foreach my $search_file (@_) {
        foreach my $search_dir (@CONF_PATH) {
            my $candidate = File::Spec->canonpath(File::Spec->catfile($search_dir, $search_file));
            DEBUG and say "Checking if $candidate exists";
            if (-f $candidate) { return $candidate }
        }
    }
}

sub get_secret {
    # abstraction to read a secret with a prompt (in case I don't always want to use Term::ReadPassword)
    my ($prompt) = @_;
    defined($prompt) or $prompt = 'Secret';  # default prompt setting
    return read_password($prompt.": ");
}


sub get_username {
    # abstraction to reliably get the current user's username
    getlogin || getpwuid($<)
}


sub get_groups {
    # enumerate groups (profiles) string from an openconnect stream
    my ($dump, $in) = @_;
    my $group_list_string = undef;
    # DEBUG and say $dump;
    if ($dump =~ /^GROUP:\s+\[(.*)\]/m ) {
        $group_list_string = $1;
        DEBUG and say "Group list: $group_list_string";
    }

    unless (defined $group_list_string) {
        die 'Unable to extract group list'
    }

    # extract group list and trim lead/trail whitespace
    my @group_list = split('\|', $group_list_string);
    if (defined $in) { print $in $group_list[0],"\n"; }
    @RETURN = @group_list;
    return @group_list;
}


sub stream {
    # handle running a command and interacting with its IO stream
    # call -> stream([command array], regex => \&sub)
    my ($ar_commands, $log, %handlers) = @_;
    my ($in, $out, $err, $pid);
    my ($stream_out, $stream_err, $reader, $start_time, $retries);
    my ($errlog, $outlog);

    # multiply these to get total time to wait for data entry and the like
    my $reader_timeout = 3;
    my $retry_limit = 7;

    # force $ar_commands to be an array ref
    ref($ar_commands) eq 'ARRAY' or $ar_commands = [ $ar_commands ];

    $err = gensym; # need to establish an anon handle for proper STDERR binding
    $pid = open3($in, $out, $err, @$ar_commands);
    DEBUG and say "Start '",join(' ',@$ar_commands),"' at $pid";

    $reader = IO::Select->new();
    $reader->add($out, $err);

    $stream_out = '';
    $stream_err = '';
    $retries = 0;
    $start_time = time;
    DEBUG and say "Start run";
    if ($log) {
        open $errlog, '>', $LOG_ERR or die "Can't write to $LOG_ERR: $!\n";
        open $outlog, '>', $LOG_OUT or die "Can't write to $LOG_OUT: $!\n";
        print $errlog timestamp();
        print $outlog timestamp();
        say "Recording logs to '$LOG_ERR' (err) and '$LOG_OUT' (out)";
    }
    STREAM_LOOP: while (waitpid($pid, WNOHANG) >= 0) {
        # while the PID is actually running, keep going
        my @handles = $reader->can_read($reader_timeout);

        # retry read, give up if too many tries
        unless (@handles) {
            DEBUG and say "Try $retries";
            $retries++;
            last STREAM_LOOP if $retries >= $retry_limit;
            next STREAM_LOOP;
        }

        for my $fh (@handles) {
            my $fno = fileno($fh);
            next unless ($fno == fileno($err) || $fno == fileno($out));
            my $ch = '';
            sysread($fh, $ch, 1);
            if ($fno == fileno($err)) {
                DEBUG and print STDERR colored(['blue'],$ch);
                $log and wrlog($errlog, $ch);
                $stream_err .= $ch;
            }
            elsif ($fno == fileno($out)) {
                DEBUG and print STDERR colored(['green'],$ch);
                $log and wrlog($outlog, $ch);
                $stream_out .= $ch;
            }

            my $matches = 0;
            for my $regex (keys %handlers) {
                for my $stream ($stream_out, $stream_err) {
                    if ($stream=~ $regex) {
                        DEBUG and say "Match '$regex'";
                        $matches++;
                        my $call = $handlers{$regex};
                        if (ref $call eq 'CODE') {
                            DEBUG and say "Calling ".subname($call);
                            $call->($stream, $in, $out, $err, $pid);
                        }
                        elsif ($call eq 'TERM') {
                            DEBUG and say "Stopping on request";
                            close $in;
                            close $out;
                            close $err;
                            last STREAM_LOOP;
                        }
                        elsif ($call =~ /^ERROR:(.*)/s) {
                            DEBUG and say "Error condition requested";
                            say "ERROR: $1";
                            close $in;
                            close $out;
                            close $err;
                            last STREAM_LOOP;
                        }
                        # TODO handle else case?
                    } #- end regex match
                } #- end for $stream
            } #- end for regex

            # reset streams if we called anything; keeps things from calling
            # twice without matching twice
            if ($matches) { $stream_out = ''; $stream_err = ''; }
        } #- file handle
    } #- STREAM_LOOP end

    if ($retries >= $retry_limit) {
        say "Retry limit ($retry_limit) exceeded, stopping stream";
        DEBUG and say "Close file handles";
        close $in;
        close $out;
        close $err;
        return 0;
    }

    waitpid($pid, 0);
    DEBUG and say "Finished run with exit $?";
}


sub prompt {
    # user-interactive prompt for non-sensitive information, with a default
    # see get_secret for prompting for sensitive info
    my ($prompt, $default) = @_;
    if (defined $default) {
        $prompt = sprintf "%s [%s]", $prompt, $default;
    }
    my $term = Term::ReadLine->new($0."-prompt");
    print STDERR "$prompt: ";
    my $choice = $term->readline();
    if ($choice eq '' && defined $default) { $choice = $default; }
    return $choice;
}


sub choose {
    # prompt the user to choose from a list of options
    # call -> choose("The choices are", "Pick your favorite", ['a','b'], 'a')
    #    The choices are:
    #      1. a
    #      2. b
    #    Pick your favorite [a]:
    my ($lead, $prompt, $ar_options, $default) = @_;
    my $choice = 0;
    print STDERR "$lead:\n";
    for my $i (0..$#{$ar_options}) {
        printf STDERR " %2d. %s\n", ($i+1), $ar_options->[$i];
    }
    while ($choice < 1 || $choice > @$ar_options) {
        $choice = prompt($prompt, $default);

        # force numeric - block there to confine effects of 'no warnings'
        {
            no warnings 'numeric';
            $choice = 0+$choice;
        }

        next if $choice <= 0;
        DEBUG && say sprintf("Choice was %d: %s", $choice, $ar_options->[$choice-1]);
    }
    $choice--;
    wantarray ? ($ar_options->[$choice], $choice) : $choice;
}


# configuration
sub get_config_file {
    # Gets the configuration file
    # File::Spec->catfile($ENV{HOME},".openc");
    my $path = search_config_file('.openc', 'config');
    if ($path) { return $path; }
    else { 
        say "creating $CONF_PATH[0]";
        mkdir $CONF_PATH[0];
        return File::Spec->catfile($CONF_PATH[0], 'config')
    }
}


sub config_setup {
    # First-time setup
    my ($host, $user, $profile, $ar_sudo) = @_;
    defined($ar_sudo) or $ar_sudo = \@SUDO;

    my $term = Term::ReadLine->new($0.'-config');

    unless (defined($user)) {
        $user = get_username();
        print STDERR "Enter username [$user]: ";
        my $answer = $term->readline();
        if (defined($answer) && length($answer)) {
            $user = $answer;
        }
    }

    my @command = ('openconnect', '-u', $user, $host);
    my @groups;
    stream(
        \@command,
        0, # don't log
        qr'^GROUP:\s\[.*\]'m => \&get_groups,
        qr'^PASSCODE:'m => 'TERM',  # TERM is magic, terminates
        qr'^Failed to'm => 'ERROR:Can\'t connect'  # ERROR: is magic, terminates
    );
    @groups = @RETURN;
    DEBUG and say "Got group list\n -> ",join("\n -> ", @groups);

    # Get a group choice for default
    unless(@groups) {
        say "Unable to get group list, quitting.";
        exit 127;
    }

    ($profile) = choose(
        "\nYou can connect using one of the following profiles:",
        "Choose default profile",
        \@groups,
        1
    );
    DEBUG and say "SELECTED GROUP [$profile]";
    print STDERR "Using '$profile' as default profile\n";

   return ($host, $user, $profile, \@groups);
}


sub save_config {
    # save the current configuration to a file
    my ($config_file, %config) = @_;
    open my $cf, '>', $config_file or die "Can't write $config_file: $!\n";
    foreach my $host (sort keys %config) {
        my $group_string = join('|', @{ $config{$host}{groups} });
        my $config_string = join(
            '::',
            $host,
            $config{$host}{user},
            $config{$host}{profile},
            $group_string
        );
        DEBUG and say "Storing config: $config_string";
        print $cf $config_string,"\n";
    }
}


sub config {
    # handles config; loads from file or runs config_setup
    my ($config_file, $host, $user, $profile, $ar_groups) = @_;
    my %config;
    my $updated = 0;
    defined($config_file) or $config_file = get_config_file();
    defined($host) or $host = '';
    DEBUG && say "Configuring for $host";
    if (-f $config_file) {
        # TODO this isn't right; should read and update if args were provided
        open my $cf, '<', $config_file or die "Can't read $config_file: $!\n";
        while (<$cf>) {
            my $line = $_;
            $line =~ s/^\s+|\s+$//g; # whitespace trim
            my ($h, $u, $p, $g);
            eval {
                ($h, $u, $p, $g) = split(/::/, $line);
            };
            if ($@) {
                # the line wasn't parseable
                next;
            }
            my @g = split(/\|/, $g);
            $h = lc($h);
            $u = lc($u);
            $config{$h} = { user=>$u, profile=>$p, groups=>[@g] };
            if ($h = lc $host) {
                $updated = 1;
                defined($user) and $config{$h}{user} = $user;
                defined($profile) and $config{$h}{profile} = $profile;
                defined($ar_groups) and $config{$h}{groups} = $ar_groups;
            }
        }
    }
    # If $host isn't in %config by now, run setup
    if (length $host && ! exists $config{$host}) {
        ($host, $user, $profile, $ar_groups) = config_setup($host, $user, $profile);
        $config{$host}{user} = $user;
        $config{$host}{profile} = $profile;
        $config{$host}{groups} = $ar_groups;
        $updated = 1;
    }


    if ($updated) { save_config($config_file, %config); }
    return %config;
}


sub profile_menu {
    # displays a choice of profiles to use, based on config
    my ($hr_config) = @_;
    my $term = Term::ReadLine->new($0.'-profile');
    ($hr_config->{profile}) = choose(
        "Available profiles",
        "Select one by number",
        $hr_config->{groups}
    );
    return $hr_config->{profile};
}


# connection handling
# TODO better handling for global abort
our $abort = 0;
sub hold_connection {
    # Holds valid connection open
    if ($abort) { return $abort; }  # Don't repeat warning for aborted conn
    my ($stream, $in, $out, $err, $pid) = @_;
    # my $abort = 0;
    print STDERR colored(['green'], "Connected! Ctrl-C to disconnect\n");

    local $SIG{INT} = sub { $abort = 1; };
    while (waitpid($pid, WNOHANG) >= 0) {
        last if $abort;
        sleep(2);
    }
    say "Disconnection requested";
    return $abort;
}


sub send_pin {
    # sends token PIN in RSA mode
    my ($in, $token_code) = @_;
    unless (defined $token_code) { $token_code = prompt("Token PIN"); }
    print $in $token_code, "\n";
    return undef; #important for default processing
}


sub send_tokencode {
    my ($in, $next) = @_;
    my $code = ($next ? `stoken --next` : `stoken`);
    $code =~ s/\s+//gsm;

    unless ($code =~ /^\d{4,10}$/) {  # Token codes should be 4-10 digits, dep on implementation
        say ("Didn't get a token code, got '$code' instead, bailing.");
        exit 1;
    }

    say("Got ".($next ? 'next' : '')."token code".(DEBUG ? ": $code" : ''));
    print $in $code, "\n";
    return undef;
}


sub openc {
    # core control for running openconnect
    my ($host, $hr_config, $use_connect_password_for_sudo, $use_rsa_token, $password, $log) = @_;
    my $user = $hr_config->{user};
    my $profile = $hr_config->{profile};
    my $token_code = '0000'; # Default, will try this first

    my @command = (@SUDO, 'openconnect', '-u', $user); #, '--authgroup', $profile);
    # if ($use_rsa_token) { push @command, '--token-mode=rsa'; }
    push @command, $host;

    DEBUG && say("connect command: ",join(' ', @command), "\n");

    # get password before connecting, if not provided; it won't change as fast as token code
    unless (defined $password) {
        $password = get_secret("Connection password for $user");
    }
    stream(
        \@command,
        $log,
        qr'^GROUP:\s\[.*\]'m => sub { my ($stream, $in) = @_; print $in $profile,"\n"; say("Group: $profile"); },
        qr'^PASSCODE:'m => sub {
            my ($stream, $in) = @_;
            if ($use_rsa_token) { send_tokencode($in, 0); }
            else { print $in prompt("Token code"),"\n"; } },
        qr'^Token Code:'m => sub {
            my ($stream, $in) = @_;
            if ($use_rsa_token) { send_tokencode($in, 1); } # send Next token code
            else { print $in prompt("Next token code"), "\n" } },
        qr'^PIN:'m => sub { my ($stream, $in) = @_; $token_code = send_pin($in, $token_code); say("Sent token PIN"); },
        qr'^Password:'m => sub { my ($stream, $in) = @_; print $in $password,"\n"; say("Sent password") },
        qr'^New Password:'m => sub {
            my ($stream, $in) = @_;
            print $in get_secret(colored(['yellow'],"--> Password change requested.\n")."Enter new password for $user"),"\n"; },
        qr'^Verify Password:'m => sub { my ($stream, $in) = @_; print $in get_secret("Enter same password again"),"\n"; },
        qr'\(sudo\) password for .+:'m => (
            $use_connect_password_for_sudo
            ? sub { my ($stream, $in) = @_; print $in $password,"\n"; say("Send sudo password"); }
            : sub { my ($stream, $in) = @_; print $in get_secret("Enter sudo password"), "\n"; }
        ),
        qr'^Connected (utun|tun)'m => \&hold_connection,
        qr'^Established DTLS connection'm => \&hold_connection,  # 7.06 and later
        qr'^Failed to con'm => 'ERROR:Can\'t connect',
        qr'^(Authentication failed\.)|(Login error.)'m => 'ERROR:Authentication failure',
    );
}


# main
sub main {
    # command_line handling and core control
    my $alt_profile = undef;
    my $alt_user = undef;
    my $use_connect_password_for_sudo = 0;  # this isn't working yet!
    my $use_rsa_token = 0;
    my $use_password_file = undef;  # path to connection password file
    my $connect_password = undef;
    my $log = 0;

    GetOptions(
        'profile:s' => \$alt_profile,
        'user=s' => \$alt_user,
        'sudo' => \$use_connect_password_for_sudo, #future
        'rsa!' => \$use_rsa_token,
        'password:s' => \$use_password_file,
        'log!' => \$log,
    );

    # TODO refuse to run if there's already an openconnect up
    # TODO option to kill running openconnect?

    if (defined $use_password_file) {
        if ($use_password_file eq "") {
            # $use_password_file = File::Spec->catfile($ENV{HOME}, '.opencpw');
            $use_password_file = search_config_file('.opencpw','password');
        }
        DEBUG and say "Getting password from file '$use_password_file'";
        eval {
            unless (-f $use_password_file) { die "File not found"; }
            unless (file_mode_max $use_password_file, 0600) { die "File mode is greater than 0600"; }
            open my $PWF, '<', $use_password_file or die "Failed reading password file: $!";
            $connect_password = <$PWF>;
            chomp($connect_password);
            close $PWF;
            DEBUG and say "Loaded password OK, is '$connect_password'";
            say "Using password from '$use_password_file' to connect";
        };
        if ($@) {
            chomp($@);
            say "Cannot use '$use_password_file' ($@), switching to interactive";
            $use_password_file = undef;
        }
    }

    DEBUG and defined($alt_profile) and say "Profile $alt_profile";
    if (!@ARGV) {
        # no host, let's try to load config and see what happens.
        my $cfile = get_config_file();
        if (-f $cfile) {
            # yay, we have a config file that actually exists!
            my %config = config($cfile);
            if (scalar keys %config == 1) {
                my ($host) = keys %config;
                say "Automatically picked $host for this connection";
                local $| = 1;
                print "\c[];$host\a";
                openc($host, $config{$host}, $use_connect_password_for_sudo, $use_rsa_token, $connect_password, $log);
            }
            else {
                say "Multiple configs, you have to specify a host name";
                exit 127;
            }
        }
        else {
            say "No configuration file; you must specify a host name";
            exit 127;
        }
    }

    while (@ARGV) {
        my $connect_host = shift @ARGV;
        my %config = config(get_config_file(), $connect_host);
        DEBUG and say Dumper(\%config);
        if (
            ! defined $config{$connect_host}
            || ! defined $config{$connect_host}{user}
            || ! defined $config{$connect_host}{profile})
        {
            say "Couldn't get config for '$connect_host";
            exit 127;
        }

        if (defined $alt_user) {
            say "Using $alt_user as username for this session only.";
            $config{$connect_host}{user} = $alt_user;
        }
        if (defined $alt_profile) {
            if (length $alt_profile) {
                say "Using $alt_profile as profile for this session only.";
                $config{$connect_host}{profile} = $alt_profile;
            }
            else {
                profile_menu($config{$connect_host});
                say "Using $config{$connect_host}{profile} as profile for this session only.";
                DEBUG and say Dumper(\%config);
            }
        }

        local $| = 1;
        print "\c[];$connect_host\a";
        openc($connect_host, $config{$connect_host}, $use_connect_password_for_sudo, $use_rsa_token, $connect_password, $log);
    }
}


main();
