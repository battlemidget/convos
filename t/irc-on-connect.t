#!perl
use lib '.';
use t::Helper;
use Convos::Core;
use Mojo::IOLoop;

my $core       = Convos::Core->new;
my $user       = $core->user({email => 'superman@example.com'});
my $connection = $user->connection({name => 'localhost', protocol => 'irc'});

$connection->dialog({name => '#convos'});
$connection->dialog({name => 'private_ryan'});

my @on_connect_commands = ('/msg NickServ identify s3cret', '/msg superwoman you are too cool');
$connection->on_connect_commands([@on_connect_commands]);

t::Helper->irc_server_connect($connection);

t::Helper->irc_server_messages(
  qr{NICK}             => ['welcome.irc'],
  qr{PRIVMSG NickServ} => ['identify.irc'],
  qr{JOIN}             => ['join-convos.irc'],
  qr{ISON}             => ['ison.irc'],
  $connection, '_irc_event_rpl_ison',
);

is_deeply(
  t::Helper->irc_messages->map(sub { $_->{command} })->grep(sub { !/notice/ }),
  [qw(rpl_welcome privmsg join rpl_topic rpl_topicwhotime rpl_namreply rpl_endofnames rpl_ison)],
  'got correct events',
);

is_deeply($connection->on_connect_commands,
  [@on_connect_commands], 'on_connect_commands still has the same elements');

done_testing;
