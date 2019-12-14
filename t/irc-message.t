#!perl

BEGIN {
  # To enable the long_message() test below
  $ENV{CONVOS_MAX_BULK_MESSAGE_SIZE} = 5;
}

use lib '.';
use t::Helper;
use Mojo::IOLoop;
use Convos::Core;
use Convos::Core::Backend::File;

my $core       = Convos::Core->new(backend => 'Convos::Core::Backend::File');
my $user       = $core->user({email => 'superman@example.com'});
my $connection = $user->connection({name => 'localhost', protocol => 'irc'});

t::Helper->irc_server_connect($connection);

t::Helper->irc_server_messages(
  qr{NICK}    => ['welcome.irc'],
  qr{USER}    => ":Supergirl!sg\@example.com PRIVMSG #convos :not a superdupersuperman?\r\n",
  $connection => '_irc_event_privmsg',
);

is $user->unread, 0, 'No unread messages';
like slurp_log('#convos'), qr{\Q<Supergirl> not a superdupersuperman?\E}m, 'normal message';

t::Helper->irc_server_messages(
  from_server => ":Supergirl!sg\@example.com PRIVMSG #convos :Hey SUPERMAN!\r\n",
  $connection => '_irc_event_privmsg',
);
like slurp_log('#convos'), qr{\Q<Supergirl> Hey SUPERMAN!\E}m, 'notification';

my $notifications;
$core->get_user('superman@example.com')->notifications_p({})->then(sub { $notifications = pop; })
  ->$wait_success('notifications');
ok delete $notifications->[0]{ts}, 'notifications has timestamp';
is $user->unread, 1, 'One unread messages';
is_deeply $notifications,
  [{
  connection_id => 'irc-localhost',
  dialog_id     => '#convos',
  from          => 'Supergirl',
  message       => 'Hey SUPERMAN!',
  type          => 'private'
  }],
  'notifications';

t::Helper->irc_server_messages(
  from_server => ":Supergirl!sg\@example.com PRIVMSG superman :does this work?!\r\n",
  $connection => '_irc_event_privmsg',
);
like slurp_log("supergirl"), qr{\Q<Supergirl> does this work?\E}m, 'private message';

t::Helper->irc_server_messages(
  from_server =>
    ":jhthorsen!jhthorsen\@example.com PRIVMSG #convos :\x{1}ACTION convos rocks!\x{1}\r\n",
  $connection => '_irc_event_ctcp_action',
);
like slurp_log('#convos'), qr{\Q* jhthorsen convos rocks\E}m, 'ctcp_action';

note 'test stripping away invalid characters in a message';
$connection->send_p('#convos' => "\n/me will be\a back\n")->$wait_success('send_p action');
like slurp_log('#convos'), qr{\Q* superman will be back\E}m, 'loopback ctcp_action';

$connection->send_p('#convos' => "some regular message")->$wait_success('send_p regular');
like slurp_log('#convos'), qr{\Q<superman> some regular message\E}m, 'loopback private';

t::Helper->irc_server_messages(
  from_server => ":Supergirl!sg\@example.com NOTICE superman :notice this?\r\n",
  $connection => '_irc_event_notice',
);
like slurp_log("supergirl"), qr{\Q-Supergirl- notice this?\E}m, 'irc_notice';

t::Helper->irc_server_messages(
  from_server => ":superduper!sd\@example.com PRIVMSG #convos foo-bar-baz, yes?\r\n",
  $connection => '_irc_event_privmsg',
);
like slurp_log('#convos'), qr{\Q<superduper> foo-bar-baz, yes?\E}m, 'superduper';

$connection->send_p('#convos' => join "\n", long_message(), long_message())
  ->$wait_success('send_p long x2');
like slurp_log('#convos'), qr{
  .*<superman>\sPhasellus.*rhoncus\r?\n
  .*<superman>\samet\.\r?\n
  .*<superman>\sPhasellus.*rhoncus\r?\n
  .*<superman>\samet\.\r?\n
}sx, 'split long message';

done_testing;

sub long_message {
  return join ' ', 'Phasellus imperdiet mollis nibh, ut venenatis sem fringilla ut.',
    'Maecenas nulla massa, pulvinar in scelerisque ut, commodo et purus.',
    'Nunc nec libero leo. Pellentesque habitant morbi tristique senectus et',
    'netus et malesuada fames ac turpis egestas. Sed fermentum erat quis dolor',
    'aliquam mattis. Donec sodales nisl sagittis nunc ultrices porta.',
    'Aenean id facilisis mauris. Vestibulum vulputate magna a libero semper facilisis.',
    'Cras vitae leo lacus. Curabitur blandit, massa et interdum egestas, diam mi rhoncus amet.';
}

sub slurp_log {
  my @date = split '-', Time::Piece->new->strftime('%Y-%m');
  Mojo::File->new(qw(local test-irc-message-t superman@example.com irc-localhost),
    @date, "$_[0].log")->slurp;
}
