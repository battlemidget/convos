#!perl
use lib '.';
use t::Helper;
use Convos::Core::Backend::File;
use Convos::Core::User;

my $backend = Convos::Core::Backend::File->new(home => Mojo::File->new($ENV{CONVOS_HOME}));
my $user    = Convos::Core::User->new(email => 'jhthorsen@cpan.org');

my $users;
$backend->users_p->then(sub { $users = shift })->wait;
is_deeply $users, [], 'no users';

my $saved;
$backend->save_object_p($user)->then(sub { $saved = shift })->wait;
is $saved, $user, 'save_object_p';

my $connections;
$backend->connections_p($user)->then(sub { $connections = shift })->wait;
is_deeply $connections, [], 'no connections';

my $loaded;
$backend->load_object_p($user)->then(sub { $loaded = shift })->wait;
is $saved, $user, 'load_object_p';

my $deleted;
$backend->delete_object_p($user)->then(sub { $deleted = shift })->wait;
is $deleted, $user, 'delete_object_p';

done_testing;
