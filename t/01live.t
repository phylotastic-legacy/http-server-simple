# -*- perl -*-

use Socket;
use Test::More tests => 34;
use strict;

# This script assumes that `localhost' will resolve to a local IP
# address that may be bound to,

my $PORT = 40000 + int(rand(10000));


use HTTP::Server::Simple;

package SlowServer;
# This test class just waits a while before it starts
# accepting connections. This makes sure that CPAN #28122 is fixed:
# background() shouldn't return prematurely.

use base qw(HTTP::Server::Simple::CGI);
sub setup_listener {
    my $self = shift;
    $self->SUPER::setup_listener();
    sleep 2;
}
1;
package main;

my $DEBUG = 1 if @ARGV;

my @pids    = ();
my @classes = (qw(HTTP::Server::Simple SlowServer));
for my $class (@classes) {
    run_server_tests($class, AF_INET);
    run_server_tests($class, AF_INET6);
    $PORT++; # don't reuse the port incase your bogus os doesn't release in time
}


for my $fam ( AF_INET, AF_INET6 ) {
    my $s=HTTP::Server::Simple::CGI->new($PORT, $fam);
    is($fam, $s->family(), 'family OK');
    $s->host("localhost");
    my $pid=$s->background();
    diag("started server PID='$pid'") if ($ENV{'TEST_VERBOSE'});
    like($pid, '/^-?\d+$/', 'pid is numeric');
    select(undef,undef,undef,0.2); # wait a sec
    my $content=fetch($fam, "GET / HTTP/1.1", "");
    like($content, '/Congratulations/', "Returns a page");

    eval {
	like(fetch($fam, "GET a bogus request"), 
	     '/bad request/i',
	     "knows what a request isn't");
    };
    fail("got exception in client: $@") if $@;

    like(fetch($fam, "GET / HTTP/1.1", ""), '/Congratulations/',
	 "HTTP/1.1 request");

    like(fetch($fam, "GET /"), '/Congratulations/',
	 "HTTP/0.9 request");

    is(kill(9,$pid),1,'Signaled 1 process successfully');
}

is( kill( 9, $_ ), 1, "Killed PID: $_" ) for @pids;

# this function may look excessive, but hopefully will be very useful
# in identifying common problems
sub fetch {
    my $family = shift;
    my $hostname = "localhost";
    my $port = $PORT;
    my $message = join "", map { "$_\015\012" } @_;
    my $timeout = 5;
    my $response;
    my $proto = getprotobyname('tcp') || die "getprotobyname: $!";
    my $socktype = SOCK_STREAM;

    eval {
        local $SIG{ALRM} = sub { die "early exit - SIGALRM caught" };
        alarm $timeout*2; #twice longer than timeout used later by select()  

        my $paddr;
        my ($err, @res) = Socket::getaddrinfo($hostname, $port, { family => $family,
                                                                  socktype => $socktype,
                                                                  protocol => $proto });
        die "getaddrinfo: $err"
          if ($err);
        while ($a = shift(@res)) {
          next unless ($family == $a->{'family'});
          next unless ($proto == $a->{'protocol'});
          next unless ($socktype == $a->{'socktype'});

          $paddr = $a->{'addr'};
          last
        }
        socket(SOCK, $family, $socktype, $proto) || die "socket: $!";
        connect(SOCK, $paddr) || die "connect: $!";
        (send SOCK, $message, 0) || die "send: $!";

        my $rvec = '';
        vec($rvec, fileno(SOCK), 1) = 1;
        die "vec(): $!" unless $rvec;

        $response = '';
        for (;;) {
            my $r = select($rvec, undef, undef, $timeout);
            die "select: timeout - no data to read from server" unless ($r > 0);
            my $l = sysread(SOCK, $response, 1024, length($response));
            die "sysread: $!" unless defined($l);
            last if ($l == 0);
        }
        $response =~ s/\015\012/\n/g; 
        (close SOCK) || die "close(): $!";
        alarm 0;
    };
    if ($@) {
      	return "[ERROR] $@";
    }
    else {
        return $response;
    }
}

sub run_server_tests {
    my $class = shift;
    my $fam = shift;
    my $s = $class->new($PORT, $fam);
    is($s->family(), $fam, 'constructor set family properly');
    is($s->port(),$PORT,"Constructor set port correctly");

    my $pid=$s->background();
    select(undef,undef,undef,0.2); # wait a sec

    like($pid, '/^-?\d+$/', 'pid is numeric');

    my $content=fetch($fam, "GET / HTTP/1.1", "");

    like($content, '/Congratulations/', "Returns a page");
    push @pids, $pid;
}
