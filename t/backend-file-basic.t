#!perl
use lib '.';
use t::Helper;
use Convos::Core::Backend::File;
use Convos::Core::User;

my $backend = Convos::Core::Backend::File->new(home => Mojo::File->new($ENV{CONVOS_HOME}));
my $user    = Convos::Core::User->new(email => 'jhthorsen@cpan.org');

my $users;
$backend->users_p->then(sub { $users = shift })->$wait_success('users_p');
is_deeply $users, [], 'no users';

my $saved;
$backend->save_object_p($user)->then(sub { $saved = shift })->$wait_success('save_object_p');
is $saved, $user, 'save_object_p';

my $connections;
$backend->connections_p($user)->then(sub { $connections = shift })->$wait_success('connections_p');
is_deeply $connections, [], 'no connections';

my $loaded;
$backend->load_object_p($user)->then(sub { $loaded = shift })->$wait_success('load_object_p');
is $saved, $user, 'load_object_p';

my $deleted;
$backend->delete_object_p($user)->then(sub { $deleted = shift })->$wait_success('delete_object_p');
is $deleted, $user, 'delete_object_p';

done_testing;
