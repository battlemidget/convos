package Convos::Plugin::Auth::LDAP;
use Mojo::Base 'Convos::Plugin::Auth';

use Convos::Util 'require_module';

has _ldap_options => undef;
has _ldap_url     => undef;
has _reactor      => sub { Mojo::IOLoop->singleton->reactor };

sub register {
  my ($self, $app, $config) = @_;

  # Allow ldap url with options: ldaps://ldap.example.com?debug=1&timeout=10
  my $ldap_url = Mojo::URL->new($ENV{CONVOS_AUTH_LDAP_URL} || 'ldap://localhost:389');
  $self->_ldap_options($ldap_url->query->to_hash);
  $self->_ldap_options->{timeout} ||= 10;
  $self->_ldap_url($ldap_url->query(Mojo::Parameters->new));

  # Make sure Net::LDAP is installed
  require_module('Net::LDAP');

  $app->helper('auth.login' => sub { $self->_login(@_) });
}

sub _bind_params {
  my ($self, $params) = @_;

  # Convert "user@example.com" into (uid => "user", domain => "example", tld => "com");
  my %dn;
  @dn{qw(uid domain)} = split '@', $params->{email};
  $dn{tld} = $dn{domain} =~ s!\.(\w+)$!! ? $1 : '';

  # Place email values into the DN string
  my $dn = $ENV{CONVOS_AUTH_LDAP_DN};
  $dn ||= $dn{tld} ? 'UID=%uid,DC=%domain,DC=%tld' : 'UID=%uid,DC=%domain';
  $dn =~ s!%(domain|tld|uid)!{$dn{$1} || ''}!ge;

  return ($dn, password => $params->{password});
}

sub _ldap {
  my $self = shift;

  my $ldap = Net::LDAP->new($self->_ldap_url->to_unsafe_string, %{$self->_ldap_options}, async => 1)
    or die "Could not create Net::LDAP object: $@";

  # Make the operation non-blocking together with "async => 1" above
  $self->_reactor->io($ldap->socket, sub { $ldap->process });

  return $ldap;
}

sub _login {
  my ($self, $c, $params, $cb) = @_;
  my $core = $c->app->core;
  my ($ldap, $user);

  Mojo::IOLoop->delay(
    sub {
      my ($delay) = @_;
      $ldap = $self->_ldap;
      $ldap->bind($self->_bind_params($params), callback => $delay->begin(0));
    },
    sub {
      my ($delay, $ldap_msg) = @_;

      # Clean up LDAP connection
      $self->_disconnect($ldap);
      $ldap = undef;

      # Try to fallback to local user on error
      $user = $core->get_user($params);
      if ($ldap_msg->code) {
        return $c->$cb('', $user) if $user and $user->validate_password($params->{password});
        return $c->$cb($ldap_msg->error, $user);
      }

      # All good if user exists
      return $c->$cb('', $user) if $user;

      # Create new user, since authenticated in LDAP
      $user = $core->user($params);
      $user->set_password($params->{password});
      $user->save($delay->begin);
    },
    sub {
      my ($delay, $err) = @_;
      $c->$cb($err, $user);
    },
  )->catch(sub {
    $self->_disconnect($ldap);
    $cb->$cb(pop);
  });

  return $c->render_later;
}

sub _disconnect {
  my $self = shift;
  my $ldap = shift or return;
  $self->_reactor->remove($ldap->socket);
  $ldap->disconnect;
}

1;

=encoding utf8

=head1 NAME

Convos::Plugin::Auth::LDAP - Convos plugin for logging in users from LDAP

=head1 SYNOPSIS

  $ CONVOS_PLUGINS=Convos::Plugin::Auth::LDAP \
    CONVOS_AUTH_LDAP_URL="dap://localhost:389" \
    CONVOS_AUTH_LDAP_DN="UID=%uid,DC=%domain,DC=%tld" \
    ./script/convos daemon

=head1 DESCRIPTION

L<Convos::Plugin::Auth::LDAP> allows convos to register and login users from
an LDAP database.

=head1 ENVIRONMENT VARIABLES

=head2 CONVOS_AUTH_LDAP_DN

C<CONVOS_AUTH_LDAP_DN> defaults to "UID=%uid,DC=%domain,DC=%tld" (EXPERIMENTAL),
but can be set to any value you like. The important parts of the variables is
"%uid", "%domain" and "%tld", which will be extracted from the email address of
the user. Example:

  CONVOS_AUTH_LDAP_DN = "UID=%uid,DC=%domain,DC=%tld"
  email = "superwoman@example.com"
  dn = "UID=superwoman,DC=example,DC=com"

=head2 CONVOS_AUTH_LDAP_URL

The URL to the LDAP server. Default is "ldap://localhost:389". (EXPERIMENTAL)

=head1 METHODS

=head2 register

Used to register this plugin in the L<Convos> application.

=head1 SEE ALSO

L<Convos::Plugin::Auth> and L<Convos>.

=cut
