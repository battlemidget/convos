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
  qr{NICK} => ['welcome.irc'],
  $connection, '_irc_event_rpl_welcome',
  qr{PRIVMSG NickServ} => ['identify.irc'],
  $connection, '_irc_event_privmsg',
  qr{JOIN} => ['join-convos.irc'],
  $connection, '_irc_event_join', $connection, '_irc_event_rpl_topic', $connection,
  '_irc_event_rpl_topicwhotime', $connection, '_irc_event_rpl_namreply', $connection,
  '_irc_event_rpl_endofnames',
  qr{ISON} => ['ison.irc'],
  $connection, '_irc_event_rpl_ison',
);

is_deeply($connection->on_connect_commands,
  [@on_connect_commands], 'on_connect_commands still has the same elements');

done_testing;
