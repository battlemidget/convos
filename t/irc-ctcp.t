use lib '.';
use t::Helper;
use Mojo::IOLoop;
use Convos::Core;

my $core       = Convos::Core->new(backend => 'Convos::Core::Backend');
my $user       = $core->user({email => 'superman@example.com'});
my $connection = $user->connection({name => 'localhost', protocol => 'irc'});

t::Helper->irc_server_connect($connection);

t::Helper->irc_server_messages(
  qr{NICK} => ['welcome.irc'],
  qr{USER} => ":other_client!u2\@other.example.com PRIVMSG mojo_irc :\x{1}PING 1393007660\x{1}\r\n",
  $connection => '_irc_event_ctcp_ping',
  qr{:\x01PING \d+\x01} =>
    ":other_client!u2\@other.example.com PRIVMSG mojo_irc :\x{1}TIME\x{1}\r\n",
  $connection     => '_irc_event_ctcp_time',
  qr{:\x01TIME\s} => ":other_client!u2\@other.example.com PRIVMSG mojo_irc :\x{1}VERSION\x{1}\r\n",
  $connection     => '_irc_event_ctcp_version',
  qr{:\x01VERSION Convos \d+\.\d+\x01} =>
    ":other_client!u2\@other.example.com PRIVMSG superman :\x{1}ACTION msg1\x{1}\r\n",
  $connection => '_irc_event_ctcp_action',
);

done_testing;
