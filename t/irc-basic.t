#!perl
use lib '.';
use t::Helper;
use Convos::Core;
use Convos::Core::Backend::File;

my $core = Convos::Core->new(backend => 'Convos::Core::Backend::File');
my $user = $core->user({email => 'test.user@example.com'});
my $connection
  = $user->connection({name => 'localhost', protocol => 'irc', url => 'irc://127.0.0.1'});
my $settings_file
  = File::Spec->catfile($ENV{CONVOS_HOME}, qw(test.user@example.com irc-localhost connection.json));

is $connection->name, 'localhost', 'connection.name';
is $connection->user->email, 'test.user@example.com', 'user.email';

ok !-e $settings_file, 'no storage file';
$connection->save_p->$wait_success('save_p');
ok -e $settings_file, 'created storage file';

cmp_deeply(
  $connection->TO_JSON,
  {
    connection_id       => ignore(),
    me                  => {},
    name                => 'localhost',
    on_connect_commands => [],
    protocol            => 'irc',
    state               => 'queued',
    url                 => 'irc://127.0.0.1',
    wanted_state        => 'connected',
  },
  'TO_JSON'
);

my $err;
$connection->send_p('', 'whatever')->catch(sub { $err = shift })->$wait_success('send_p');
like $err, qr{without target}, 'send: without target';

$connection->send_p('#test_convos' => '0')->catch(sub { $err = shift })->$wait_success('send_p');
like $err, qr{Not connected}i, 'send: not connected';

is $connection->user, $user, 'user';
ok -e $settings_file, 'settings_file exists before remove_connection()';
$user->remove_connection_p($connection->id)->$wait_success('remove_connection_p');

ok !-e $settings_file, 'settings_file removed after remove_connection()';
ok !-e File::Basename::dirname($settings_file), 'all files removed';

done_testing;
