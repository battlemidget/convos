#!perl
use lib '.';
use t::Helper;
use Convos::Core::Backend;

my $backend = Convos::Core::Backend->new;

my $connections;
$backend->connections_p->then(sub { $connections = shift })->wait;
is_deeply $connections, [], 'connections';

my $users;
$backend->users_p->then(sub { $users = shift })->wait;
is_deeply $users, [], 'users';

my $messages;
$backend->messages_p({}, {})->then(sub { $messages = shift })->wait;
is_deeply $messages, [], 'messages';

my $notifications;
$backend->notifications_p({}, {})->then(sub { $notifications = shift })->wait;
is_deeply $notifications, [], 'notifications';

my $user = bless {};
my $saved;
$backend->save_object_p($user)->then(sub { $saved = shift })->wait;
is $saved, $user, 'save_object_p';

my $loaded;
$backend->load_object_p($user)->then(sub { $loaded = shift })->wait;
is $saved, $user, 'load_object_p';

my $deleted;
$backend->delete_object_p($user)->then(sub { $deleted = shift })->wait;
is $deleted, $user, 'delete_object_p';

my $err;
$backend->handle_event_p('foo')->catch(sub { $err = shift })->wait;
is $err, 'No event handler for foo.', 'handle_event_p';

done_testing;
