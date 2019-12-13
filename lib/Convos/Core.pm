package Convos::Core;
use Mojo::Base -base;

use Convos::Core::Backend;
use Convos::Core::Settings;
use Convos::Core::User;
use Convos::Util qw(DEBUG has_many);
use Mojo::File;
use Mojo::URL;
use Mojo::Util 'trim';
use Mojolicious::Plugins;

has backend  => sub { Convos::Core::Backend->new };
has base_url => sub { Mojo::URL->new };
has home     => sub { Mojo::File->new(split '/', $ENV{CONVOS_HOME}); };

has settings => sub {
  my $self     = shift;
  my $settings = Convos::Core::Settings->new;
  Scalar::Util::weaken($settings->{core} = $self);
  return $settings;
};

sub connect {
  my ($self, $connection) = @_;
  my $host = $connection->url->host;

  $connection->state('queued', 'Connecting soon...');

  if ($host eq 'localhost') {
    $connection->connect;
  }
  elsif ($self->{connect_queue}{$host}) {
    push @{$self->{connect_queue}{$host}}, $connection;
  }
  else {
    $self->{connect_queue}{$host} = [];
    $connection->connect;
  }

  return $self;
}

sub get_user_by_public_id {
  my ($self, $public_id) = @_;
  return +(grep { $_->public_id eq $public_id } @{$self->users})[0];
}

sub new {
  my $self = shift->SUPER::new(@_);

  if ($self->{backend} and !ref $self->{backend}) {
    eval "require $self->{backend};1" or die $@;
    $self->{backend} = $self->{backend}->new(home => $self->home);
  }

  return $self;
}

sub start {
  my $self = shift;
  return $self if !@_ and $self->{started}++;

  # Want this method to be blocking to make sure everything is ready
  # before processing web requests.
  my ($first_user, $has_admin) = (undef, 0);
  $self->backend->users_p->then(sub {
    my $users = shift;

    my (@p, @users);
    for (@$users) {
      my $user = $self->user($_);
      $first_user ||= $user;
      $has_admin++ if $user->role(has => 'admin');
      push @p,     $self->backend->connections_p($user);
      push @users, $user;
    }

    return Mojo::Promise->all(Mojo::Promise->resolve(\@users), @p);
  })->then(sub {
    my ($users, @connections_for_users) = map { $_->[0] } @_;

    for my $connections (@connections_for_users) {
      my $user = shift @$users;

      for (@$connections) {
        my $connection = $user->connection($_);
        $self->connect($connection)
          if !$ENV{CONVOS_SKIP_CONNECT} and $connection->wanted_state eq 'connected';
      }
    }
  })->catch(sub {
    warn "start() FAILED $_[0]\n";
  })->wait;

  Scalar::Util::weaken($self);
  $self->{connect_tid}
    = Mojo::IOLoop->recurring($ENV{CONVOS_CONNECT_DELAY} || 4, sub { $self->_dequeue });

  # Upgrade the first registered user (back compat)
  $first_user->role(give => 'admin') if $first_user and !$has_admin;

  return $self;
}

has_many users => 'Convos::Core::User' => sub {
  my ($self, $attrs) = @_;
  $attrs->{email} = trim lc $attrs->{email} || '';
  my $user = Convos::Core::User->new($attrs);
  die "Invalid email $user->{email}. Need to match /.\@./." unless $user->email =~ /.\@./;
  Scalar::Util::weaken($user->{core} = $self);
  return $user;
};

sub web_url {
  my $self = shift;
  my $url  = Mojo::URL->new(shift);

  $url->base($self->base_url->clone)->base->userinfo(undef);
  my $base_path = $url->base->path;
  unshift @{$url->path->parts}, @{$base_path->parts};
  $base_path->parts([])->trailing_slash(0);

  return $url;
}

sub _dequeue {
  my $self = shift;

  for my $host (keys %{$self->{connect_queue} || {}}) {
    next unless my $connection = shift @{$self->{connect_queue}{$host}};
    $connection->connect if $connection->wanted_state eq 'connected';
  }
}

sub DESTROY {
  my $self = shift;
  Mojo::IOLoop->remove($self->{connect_tid}) if $self->{connect_tid};
}

1;

=encoding utf8

=head1 NAME

Convos::Core - Convos Models

=head1 DESCRIPTION

L<Convos::Core> is a class which is used to instantiate other core objects
with proper defaults.

=head1 SYNOPSIS

  use Convos::Core;
  use Convos::Core::Backend::File;
  my $core = Convos::Core->new(backend => Convos::Core::Backend::File->new);

=head1 OBJECT GRAPH

=over 2

=item * L<Convos::Core>

=over 2

=item * Has one L<Convos::Core::Backend> objects.

This object takes care of persisting data to disk.

=item * Has many L<Convos::Core::User> objects.

Represents a user of L<Convos>.

=over 2

=item * Has many L<Convos::Core::Connection> objects.

Represents a connection to a remote chat server, such as an
L<IRC|Convos::Core::Connection::Irc> server.

=over 2

=item * Has many L<Convos::Core::Dialog> objects.

This represents a dialog with zero or more users.

=back

=back

=back

=back

All the child objects have pointers back to the parent object.

=head1 ATTRIBUTES

L<Convos::Core> inherits all attributes from L<Mojo::Base> and implements
the following new ones.

=head2 backend

  $obj = $self->backend;

Holds a L<Convos::Core::Backend> object.

=head2 base_url

  $url = $self->base_url;

Holds a L<Mojo::URL> object that holds the public location of this Convos
instance.

=head2 home

  $obj = $self->home;
  $self = $self->home(Mojo::File->new($ENV{CONVOS_HOME});

Holds a L<Mojo::File> object pointing to where Convos store data.

=head1 METHODS

L<Convos::Core> inherits all methods from L<Mojo::Base> and implements
the following new ones.

=head2 connect

  $self->connect($connection);

This method will call L<Convos::Core::Connection/connect> either at once
or add the connection to a queue which will connect after an interval.

The reason for queuing connections is to prevent flooding the server.

Note: Connections to "localhost" will not be delayed, unless the first connect
fails.

C<$cb> is optional, but will be passed on to
L<Convos::Core::Connection/connect> if defined.

=head2 get_user

  $user = $self->get_user(\%attrs);
  $user = $self->get_user($email);

Returns a L<Convos::Core::User> object or undef.

=head2 get_user_by_public_id

  $user = $self->get_user_by_public_id($id);

Returns a L<Convos::Core::User> object or undef.

=head2 new

  $self = Convos::Core->new(%attrs);
  $self = Convos::Core->new(\%attrs);

Object constructor. Builds L</backend> if a classname is provided.

=head2 start

  $self = $self->start;

Will start the backend. This means finding all users and start connections
if state is not "disconnected".

=head2 user

  $user = $self->user(\%attrs);

Returns a new L<Convos::Core::User> object or updates an existing object.

=head2 users

  $users = $self->users;

Returns an array-ref of of L<Convos::Core::User> objects.

=head2 web_url

  $url = $self->web_url($url);

Takes a path, or complete URL, merges it with L</base_url> and returns a new
L<Mojo::URL> object. Note that you need to call L</to_abs> on that object
for an absolute URL.

=head1 SEE ALSO

L<Convos>.

=cut
