package Convos::Util;
use Mojo::Base 'Exporter';

use JSON::Validator::Error;
use Mojo::File;
use Mojo::Util 'monkey_patch';
use constant DEBUG => $ENV{CONVOS_DEBUG} || 0;

our @EXPORT_OK = qw(DEBUG E has_many pretty_connection_name spurt);

sub E {
  my ($msg, $path) = @_;
  $msg =~ s! at \S+.*!!s;
  $msg =~ s!:.*!.!s;
  return {errors => [JSON::Validator::Error->new($path, $msg)]};
}

sub has_many {
  my ($plural_accessor, $many_class, $constructor) = @_;
  my $class = caller;

  my $singular_accessor = $plural_accessor;
  $singular_accessor =~ s!s$!!;

  monkey_patch $class => $plural_accessor => sub {
    return [values %{$_[0]->{$plural_accessor} || {}}];
  };

  monkey_patch $class => "n_$plural_accessor" => sub {
    return int values %{$_[0]->{$plural_accessor} || {}};
  };

  monkey_patch $class => $singular_accessor => sub {
    my ($self, $attrs) = @_;
    my $id  = $many_class->id($attrs);
    my $obj = $self->{$plural_accessor}{$id} || $self->$constructor($attrs);
    map { $obj->{$_} = $attrs->{$_} } keys %$attrs if $self->{$plural_accessor}{$id};
    $self->{$plural_accessor}{$id} = $obj;
  };

  monkey_patch $class => "get_$singular_accessor" => sub {
    my ($self, $attrs) = @_;
    my $id = ref $attrs ? $attrs->{id} || $many_class->id($attrs) : $attrs;
    Carp::confess("Could not build 'id' for $class") unless defined $id;
    return $self->{$plural_accessor}{lc($id)};
  };

  my $remover = "remove_$singular_accessor";
  $class->can($remover) or monkey_patch $class => $remover => sub {
    my ($self, $attrs) = @_;
    my $id = lc(ref $attrs ? $attrs->{id} || $many_class->id($attrs) : $attrs);
    return delete $self->{$plural_accessor}{$id};
  };
}

sub pretty_connection_name {
  my $name = shift;

  return '' unless defined $name;
  return 'magnet' if $name =~ /\birc\.perl\.org\b/i;    # also match ssl.irc.perl.org
  return 'efnet'  if $name =~ /\befnet\b/i;

  $name = 'localhost' if $name eq '127.0.0.1';
  $name =~ s!^(irc|chat)\.!!;                           # remove common prefixes from server name
  $name =~ s!:\d+$!!;                                   # remove port
  $name =~ s!\.\w{2,3}$!!;                              # remove .com, .no, ...
  $name =~ s![\W_]+!-!g;                                # make pretty url
  $name;
}

sub spurt {
  my ($content, $path) = @_;
  Mojo::File->new("$path.tmp")->spurt($content);
  unlink $path or die "Can't delete old file: $path" if -e $path;
  rename "$path.tmp" => $path;
  return $content;
}

1;

=encoding utf8

=head1 NAME

Convos::Util - Utility functions

=head1 SYNOPSIS

  package Convos::Core::Core;
  use Convos::Util qw(DEBUG has_many);

=head1 DESCRIPTION

L<Convos::Util> is a utily module for L<Convos>.

=head1 FUNCTIONS

=head2 has_many

  has_many $attribute => $many_class_class => sub {
    my ($self, $attrs) = @_;
    return $many_class_class->new($attrs);
  };

Used to automatically define a create/update, get and list method to the
caller class. Example:

  has_many users => "Convos::Core::User" => sub {
    my ($self, $attrs) = @_;
    return Convos::Core::User->new($attrs);
  };

The definition above results in the following methods:

  # Create or update and existing Convos::Core::User object
  $user = $class->user(\%attrs);

  # Retrieve a Convos::Core::User object or undef()
  $user = $class->get_user($id);
  $user = $class->get_user(\%attrs);

  # Retrieve an array-ref of Convos::Core::User objects
  $users = $class->users;

  # Remove a user
  $user = $class->remove_user($id);
  $user = $class->remove_user(\%attrs);

=head2 pretty_connection_name

  $str = pretty_connection_name($hostname);

Will turn a given hostname into a nicer connection name.

=head2 spurt

  $bytes = spurt $bytes => $path;

Write all C<$bytes> at to a temp file, and then replace C<$path> with the temp
file. This is almost the same as L<Mojo::Util/spurt>, but will not truncate
existing files, if the disk is full.

=head1 SEE ALSO

L<Convos>.

=cut
