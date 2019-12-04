#!perl
use lib '.';
use t::Helper;
use Convos::Core;
use Convos::Core::Backend::File;

my $core       = Convos::Core->new;
my $connection = $core->user({email => 'test.user@example.com'})
  ->connection({name => 'example', protocol => 'irc'});
my @state;

$connection->state(disconnected => '');
$connection->on(state => sub { push @state, $_[2]->{state} });
$connection->url->parse('irc://irc.example.com');

no warnings 'redefine';
my (@connect_args, @err, $stream);
local *Mojo::IOLoop::client = sub {
  my ($loop, $args, $cb) = @_;
  push @connect_args, $args;
  Mojo::IOLoop->next_tick(sub { $cb->($loop, shift @err, $stream) });
  return rand;
};

note 'reconnect on ssl error';
is $connection->url->query->param('tls'), undef, 'try tls first';

push @err,
  'SSL connect attempt failed error:140770FC:SSL routines:SSL23_GET_SERVER_HELLO:unknown protocol';
push @err, 'Something went wrong';
$connection->connect;
Mojo::IOLoop->one_tick until @state == 2;

is_deeply $connect_args[0],
  {address => 'irc.example.com', port => 6667, timeout => 20, tls => 1, tls_verify => 0x00},
  'connect args first';

is_deeply $connect_args[1], {address => 'irc.example.com', port => 6667, timeout => 20},
  'connect args second';

is $connection->url->query->param('tls'), 0, 'tls off after fail connect';
is_deeply \@state, [qw(queued disconnected)], 'queued => disconnected' or diag join ' ', @state;

note 'reconnect on missing ssl module';
push @err, 'IO::Socket::SSL 1.94+ required for TLS support';
$connection->url->query->remove('tls');
$connection->connect;
Mojo::IOLoop->one_tick until @state == 3;
is $connection->url->query->param('tls'), 0, 'tls off after missing module';
is_deeply \@state, [qw(queued disconnected queued)], 'queued because of connect_queue';

note 'successful connect';
$stream = Mojo::IOLoop::Stream->new;
Mojo::IOLoop->recurring(
  0.1 => sub {
    $core->_dequeue;
    Mojo::IOLoop->stop if @state == 4;
  }
);
cmp_deeply [values %{$core->{connect_queue}}], [[$connection]], 'connect_queue';
Mojo::IOLoop->start;
is_deeply \@state, [qw(queued disconnected queued connected)], 'connected';

done_testing;
