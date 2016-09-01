# openc - Helper for OpenConnect

`openc.pl` is a command-line helper to automate portions of making OpenConnect VPN connections. It has a lot of bugs, and should be considered **Alpha** status software. I use it daily, but it's very much *works on my machine*.

It is written in Perl because I hate you.

It's mostly interesting because it interacts with another command-line program using IO streams; see the `stream()` sub for details.

# Installation

You must install [OpenConnect](http://www.infradead.org/openconnect/), version 7.06 or higher. The `openconnect` binary must be in your PATH.

You must install the [`stoken` utility](http://stoken.sf.net), and `stoken` must be in your PATH. (Some token configs do not work with OpenConnect's libstoken support, the CLI always works so we use it instead). 

This requires Perl 5.23 or higher for security purposes, though older Perls may work.

If you're on a system where having that recent of a Perl is a problem (OS X, I'm looking at you), or if you want an isolated CPAN install, consider using [Perlbrew](https://perlbrew.pl) to install an isolated version, then change the `openc.pl` shebang to point to it.

Depending on your Perl distribution, you may need to the following CPAN modules:

* Getopt::Long
* Term::ReadPassword

If using Perlbrew, make sure you use its `cpan` when installing.

# First run

On first run for a given VPN server hostname, it prompts for setup before connecting:

    openc.pl vpn.server.host
    Enter username [ubuntu]: myuser

    You can connect using one of the following profiles::
      1. Split_Tunnel_(DEFAULT)
      2. From_Public_WiFi
      3. Contractor
    Choose default profile [1]:
    Using 'Split_Tunnel_(DEFAULT)' as default profile
    Connection password for myuser: *******************
    # Group: Split_Tunnel_(DEFAULT)
    Token code: ******
    # Sent password
    Connected! Ctrl-C to disconnect

From then on, you'll only be prompted for authentication on that server unless you provide certain command-line arguments

# Running

    openc.pl [args] vpn.server.host

    --profile    : alternate connection profile/group; if no name is provided,
                   presents a list of choices from the configuration file
    --password   : a path to a password -file- containing a connection password.
                   the mode must be less than or equal to 0600; if not specified,
                   will use ~/.opencpw
    --sudo       : use the connection password as your local sudo password
                   otherwise you'll be prompted for a sudo password
    --user       : connect as a different user than the one in the config file,
                   you must supply the name, you will not be prompted
    --rsa        : use an RSA soft token stored in ~/.stokenrc
    --log        : log openconnect STDERR to stderr.log and STDOUT to stdout.log

Configuration is in `~/.openc`

If you use `--password` or `--profile` without a parameter, you need to use `--` to indicate the end of the parameter line, like so:

    openc.pl --profile -- vpn.server.host

If you set the environment variable `DEBUG` to a True value (e.g. `1`), openc will be more verbose and add timestamps to each thing it writes to the console.

# Notes

This software is **alpha** and provided **without warranty of any kind, express or implied**. Use it at your own risk, since it has not been tested thoroughly and might cause issues.

# LICENSE (BSD 2-clause)

Copyright (c) 2015-2016, Darren P Meyer
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
