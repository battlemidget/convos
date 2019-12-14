#!perl
use lib '.';
use t::Helper;
use Convos::Core;
use Convos::Core::Backend::File;
use List::Util 'sum';
use Time::HiRes 'time';

my $core = Convos::Core->new(backend => 'Convos::Core::Backend::File');
my $user;

note 'jhthorsen connections';
$user = $core->user({email => 'jhthorsen@cpan.org'});
$user->save_p->$wait_success('save_p');

# 1: localhost connects instantly
$user->connection({name => 'localhost', protocol => 'irc'})
  ->tap(sub { shift->url->parse('irc://localhost') })->save_p->$wait_success('save_p');

# 2: instant or queued
$user->connection({name => 'magnet', protocol => 'irc'})
  ->tap(sub { shift->url->parse('irc://irc.perl.org') })->save_p->$wait_success('save_p');
$user->connection({name => 'magnet2', protocol => 'irc'})
  ->tap(sub { shift->url->parse('irc://irc.perl.org') })->save_p->$wait_success('save_p');

note 'mramberg connections';
$user = $core->user({email => 'mramberg@cpan.org'});
$user->save_p->$wait_success('save_p');

# 0: will not be connected
my $conn_0 = $user->connection({name => 'localhost', protocol => 'Irc'});
$conn_0->url->parse('irc://127.0.0.1');
$conn_0->set_wanted_state_p('disconnected')->$wait_success('set_wanted_state_p');
$conn_0->save_p->$wait_success('save_p');

# 2: instant or queued
$user->connection({name => 'freenode', protocol => 'irc'})
  ->tap(sub { shift->url->parse('irc://chat.freenode.net:6697') })->save_p;
$user->connection({name => 'magnet', protocol => 'irc'})
  ->tap(sub { shift->url->parse('irc://irc.perl.org') })->save_p;

# ^^ total connections to connect
my $expected = 5;

note 'restart core';
$core = Convos::Core->new(backend => 'Convos::Core::Backend::File');

my %connect;
Mojo::Util::monkey_patch(
  'Convos::Core::Connection::Irc',
  connect => sub {
    my $host_port = $_[0]->url->host_port;
    $connect{$host_port}++;
    note "@{[time]} monkey_patch connect to $host_port\n" if $ENV{HARNESS_IS_VERBOSE};
    Mojo::IOLoop->stop if sum(values %connect) == $expected;
  }
);

$ENV{CONVOS_CONNECT_DELAY} //= 0.05;
$core->start for 0 .. 4;    # calling start() multiple times result in no-op
cmp_deeply $core->{connect_queue},
  {'chat.freenode.net' => [], 'irc.perl.org' => [(obj_isa('Convos::Core::Connection::Irc')) x 2],},
  'connect_queue';
is_deeply \%connect, {'chat.freenode.net:6697' => 1, 'irc.perl.org' => 1, 'localhost' => 1},
  'started connections, except disconnected';

Mojo::IOLoop->start;
is_deeply \%connect, {'chat.freenode.net:6697' => 1, 'irc.perl.org' => 3, 'localhost' => 1},
  'started duplicate connection delayed';

done_testing;
