package Convos::Core::Connection::Irc;
use Mojo::Base 'Convos::Core::Connection';

no warnings 'utf8';
use Convos::Util 'DEBUG';
use IRC::Utils ();
use Mojo::JSON;
use Mojo::Util qw(term_escape trim);
use Parse::IRC ();
use Time::HiRes 'time';

use constant DIALOG_SEARCH_INTERVAL => $ENV{CONVOS_DIALOG_SEARCH_INTERVAL} || 0.5;
use constant IS_TESTING             => $ENV{HARNESS_ACTIVE}                || 0;
use constant MAX_BULK_MESSAGE_SIZE  => $ENV{CONVOS_MAX_BULK_MESSAGE_SIZE}  || 3;
use constant MAX_MESSAGE_LENGTH     => $ENV{CONVOS_MAX_MESSAGE_LENGTH}     || 512;
use constant PERIDOC_INTERVAL       => $ENV{CONVOS_IRC_PERIDOC_INTERVAL}   || 60;

require Convos;
our $VERSION = Convos->VERSION;

my %CLASS_DATA;
my %CTCP_QUOTE = ("\012" => 'n', "\015" => 'r', "\0" => '0', "\cP" => "\cP");

sub _available_dialogs { $CLASS_DATA{dialogs}{$_[0]->url->host} ||= {} }

sub disconnect_p {
  my $self = shift;

  my $p = Mojo::Promise->new;
  $self->_write_p("QUIT :https://convos.by")->then(
    sub {
      $p->resolve;
    },
    sub {
      $self->{stream}->close if $self->{stream};
      Mojo::IOLoop->remove(delete $self->{stream_id}) if $self->{stream_id} and !$self->{stream};
      $p->resolve;
    }
  );

  return $p;
}

sub send_p {
  my ($self, $target, $message) = @_;

  $target  //= '';
  $message //= '';
  $message =~ s![\x00-\x09\x0b-\x1f]!!g;    # remove invalid characters
  $message = Mojo::Util::trim($message);    # required for kick, mode, ...

  return $self->_send_message_p($target, $message) unless $message =~ s!^/([A-Za-z]+)\s*!!;
  my $cmd = uc $1;

  return $self->_send_message_p($target, "\x{1}ACTION $message\x{1}") if $cmd eq 'ME';
  return $self->_send_message_p($target, $message) if $cmd eq 'SAY';
  return $self->_send_message_p(split /\s+/, $message, 2) if $cmd eq 'MSG';
  return $self->_send_query_p($message)                             if $cmd eq 'QUERY';
  return $self->_send_ison_p($message =~ /\w/ ? $message : $target) if $cmd eq 'ISON';
  return $self->_send_join_p($message)                              if $cmd eq 'JOIN';
  return $self->_send_kick_p($target, $message) if $cmd eq 'KICK';
  return $self->_send_list_p($message) if $cmd eq 'LIST';
  return $self->_send_mode_p($target, $message) if $cmd eq 'MODE';
  return $self->_send_part_p($message || $target) if $cmd eq 'CLOSE' or $cmd eq 'PART';
  return $self->_send_topic_p($target, $message) if $cmd eq 'TOPIC';
  return $self->_send_whois_p($message)            if $cmd eq 'WHOIS';
  return $self->_send_names_p($target)             if $cmd eq 'NAMES';
  return $self->_send_nick_p($message)             if $cmd eq 'NICK';
  return $self->set_wanted_state_p('connected')    if $cmd eq 'CONNECT';
  return $self->set_wanted_state_p('disconnected') if $cmd eq 'DISCONNECT';
  return $self->_send_message_p($target, "/$cmd $message");
}

sub _connect_args {
  my $self   = shift;
  my $url    = $self->url;
  my $params = $self->url->query;

  $self->_periodic_events;
  $url->port($params->param('tls') ? 6669 : 6667) unless $url->port;
  $params->param(user => 'convos')     unless $params->param('user');
  $params->param(nick => $self->_nick) unless $params->param('nick');
  $self->{myinfo}{nick} = $params->param('nick');

  return $self->SUPER::_connect_args;
}

sub _irc_event_ctcp_action {
  shift->_irc_event_privmsg(@_);
}

sub _irc_event_ctcp_ping {
  my ($self, $msg) = @_;
  my $ts   = $msg->{params}[1] or return;
  my $nick = IRC::Utils::parse_user($msg->{prefix});
  $self->_write(sprintf "NOTICE %s %s\r\n", $nick, $self->_make_ctcp_string("PING $ts"));
}

sub _irc_event_ctcp_time {
  my ($self, $msg) = @_;
  my $nick = IRC::Utils::parse_user($msg->{prefix});
  $self->_write(sprintf "NOTICE %s %s\r\n",
    $nick, $self->_make_ctcp_string(TIME => scalar localtime));
}

sub _irc_event_ctcp_version {
  my ($self, $msg) = @_;
  my $nick = IRC::Utils::parse_user($msg->{prefix});
  $self->_write(sprintf "NOTICE %s %s\r\n",
    $nick, $self->_make_ctcp_string("VERSION Convos $VERSION"));
}

sub _irc_event_err_cannotsendtochan {
  my ($self, $msg) = @_;
  $self->_notice("Cannot send to channel $msg->{params}[1].", type => 'error');
}

sub _irc_event_err_erroneusnickname {
  my ($self, $msg) = @_;
  my $nick = $msg->{params}[1] || 'unknown';
  $self->_notice("Invalid nickname $nick.", type => 'error');
}

sub _irc_event_err_nicknameinuse {
  my ($self, $msg) = @_;
  my $nick = $msg->{params}[1];

  # do not want to flod frontend with these messages
  $self->_notice("Nickname $nick is already in use.", type => 'error')
    unless $self->{err_nicknameinuse}{$nick}++;

  $self->{myinfo}{nick} = "${nick}_";
  $self->_write("NICK $self->{myinfo}{nick}\r\n");
}

sub _irc_event_err_unknowncommand {
  my ($self, $msg) = @_;
  $self->_notice("Unknown command: $msg->{params}[1]", type => 'error');
}

sub _irc_event_fallback {
  my ($self, $msg) = @_;
  shift @{$msg->{params}} if $self->_nick eq $msg->{params}[0];

  $self->emit(
    message => $self->messages,
    {
      from      => $msg->{prefix} ? +(IRC::Utils::parse_user($msg->{prefix}))[0] : $self->id,
      highlight => Mojo::JSON->false,
      message   => join(' ', @{$msg->{params}}),
      ts        => time,
      type      => 'notice',
    }
  );
}

sub _irc_event_join {
  my ($self, $msg) = @_;
  my ($nick, $user, $host) = IRC::Utils::parse_user($msg->{prefix});
  my $channel = $msg->{params}[0];

  if ($self->_is_current_nick($nick)) {
    my $dialog = $self->dialog({name => $channel, frozen => ''});
    $self->emit(state => frozen => $dialog->TO_JSON);
  }
  elsif (my $dialog = $self->get_dialog($channel)) {
    $self->emit(state => join => {dialog_id => $dialog->id, nick => $nick});
  }
}

sub _irc_event_kick {
  my ($self, $msg) = @_;
  my ($kicker) = IRC::Utils::parse_user($msg->{prefix});
  my $dialog   = $self->dialog({name => $msg->{params}[0]});
  my $nick     = $msg->{params}[1];
  my $reason   = $msg->{params}[2] || '';

  $self->emit(state => part =>
      {dialog_id => $dialog->id, kicker => $kicker, nick => $nick, message => $reason});
}

# :superman!superman@i.love.debian.org MODE superman :+i
# :superman!superman@i.love.debian.org MODE #convos superman :+o
# :hybrid8.debian.local MODE #no_such_room +nt
sub _irc_event_mode {
  my ($self, $msg) = @_;
  my ($from) = IRC::Utils::parse_user($msg->{prefix});
  my $dialog = $self->get_dialog({name => $msg->{params}[0]}) or return;
  my $mode = $msg->{params}[1] || '';
  my $nick = $msg->{params}[2] || '';

  $self->emit(
    state => mode => {dialog_id => $dialog->id, from => $from, mode => $mode, nick => $nick});
}

# :Superman12923!superman@i.love.debian.org NICK :Supermanx
sub _irc_event_nick {
  my ($self, $msg) = @_;
  my ($old_nick)  = IRC::Utils::parse_user($msg->{prefix});
  my $new_nick    = $msg->{params}[0];
  my $wanted_nick = $self->url->query->param('nick');

  if ($wanted_nick and $wanted_nick eq $new_nick) {
    delete $self->{err_nicknameinuse};    # allow warning on next nick change
  }

  if ($self->{myinfo}{nick} eq $old_nick) {
    $self->{myinfo}{nick} = $new_nick;
    $self->emit(state => me => $self->{myinfo});
  }
  else {
    $self->emit(state => nick_change => {new_nick => $new_nick, old_nick => $old_nick});
  }
}

sub _irc_event_part {
  my ($self, $msg) = @_;
  my ($nick, $user, $host) = IRC::Utils::parse_user($msg->{prefix});
  my $dialog = $self->get_dialog($msg->{params}[0]);
  my $reason = $msg->{params}[1] || '';

  if ($dialog and !$self->_is_current_nick($nick)) {
    $self->emit(state => part => {dialog_id => $dialog->id, nick => $nick, message => $reason});
  }
}

sub _irc_event_ping {
  my ($self, $msg) = @_;
  $self->_write("PONG $msg->{params}[0]\r\n");
}

# Do not care about the PING response
sub _irc_event_pong { }

sub _irc_event_notice {
  my ($self, $msg) = @_;

  # AUTH :*** Ident broken or disabled, to continue to connect you must type /QUOTE PASS 21105
  $self->_write("QUOTE PASS $1\r\n") if $msg->{params}[0] =~ m!Ident broken.*QUOTE PASS (\S+)!;

  $self->_irc_event_privmsg($msg);
}

sub _irc_event_privmsg {
  my ($self, $msg) = @_;
  my ($nick, $user, $host) = IRC::Utils::parse_user($msg->{prefix} || '');
  my ($from, $highlight, $target);

  my ($dialog_id, @message) = @{$msg->{params}};
  $message[0] = join ' ', @message;

  # http://www.mirc.com/colors.html
  $message[0] =~ s/\x03\d{0,15}(,\d{0,15})?//g;
  $message[0] =~ s/[\x00-\x1f]//g;

  if ($user) {
    $target   = $self->_is_current_nick($dialog_id) ? $nick : $dialog_id,
      $target = $self->get_dialog($target) || $self->dialog({name => $target});
    $from = $nick;
  }

  $target ||= $self->messages;
  $from   ||= $self->id;

  unless ($self->_is_current_nick($nick)) {
    $highlight = grep { $message[0] =~ /\b\Q$_\E\b/i } $self->_nick,
      @{$self->user->highlight_keywords};
  }

  $target->last_active(Mojo::Date->new->to_datetime);

  # server message or message without a dialog
  $self->emit(
    message => $target,
    {
      from      => $from,
      highlight => $highlight ? Mojo::JSON->true : Mojo::JSON->false,
      message   => $message[0],
      ts        => time,
      type      => _message_type($msg),
    }
  );
}

sub _irc_event_quit {
  my ($self, $msg) = @_;
  my ($nick, $user, $host) = IRC::Utils::parse_user($msg->{prefix});

  $self->emit(state => quit => {nick => $nick, message => join ' ', @{$msg->{params}}});
}

sub _irc_event_rpl_list {
  my ($self, $msg) = @_;
  my $dialog = {n_users => 0 + $msg->{params}[2], topic => $msg->{params}[3]};

  $dialog->{name}      = $msg->{params}[1];
  $dialog->{dialog_id} = lc $dialog->{name};
  $dialog->{topic} =~ s!^(\[\+[a-z]+\])\s?!!;    # remove mode from topic, such as [+nt]
  $self->_available_dialogs->{dialogs}{$dialog->{name}} = $dialog;
}

sub _irc_event_rpl_listend {
  my ($self, $msg) = @_;
  $self->_available_dialogs->{done} = Mojo::JSON->true;
}

# :hybrid8.debian.local 004 superman hybrid8.debian.local hybrid-1:8.2.0+dfsg.1-2 DFGHRSWabcdefgijklnopqrsuwxy bciklmnoprstveIMORS bkloveIh
sub _irc_event_rpl_myinfo {
  my ($self, $msg) = @_;
  my @keys = qw(nick real_host version available_user_modes available_channel_modes);
  my $i    = 0;

  $self->{myinfo}{$_} = $msg->{params}[$i++] // '' for @keys;
  $self->emit(state => me => $self->{myinfo});
}

# :hybrid8.debian.local 001 superman :Welcome to the debian Internet Relay Chat Network superman
sub _irc_event_rpl_welcome {
  my ($self, $msg) = @_;

  $self->_notice($msg->{params}[1]);    # Welcome to the debian Internet Relay Chat Network superman
  $self->{myinfo}{nick} = $msg->{params}[0];
  $self->emit(state => me => $self->{myinfo});

  my @commands = (
    (grep {/\S/} @{$self->on_connect_commands}),
    map {
          $_->is_private ? "/ISON $_->{name}"
        : $_->password   ? "/JOIN $_->{name} $_->{password}"
        : "/JOIN $_->{name}"
    } sort { $a->id cmp $b->id } @{$self->dialogs}
  );

  Scalar::Util::weaken($self);
  my $write;
  $write = sub {
    my $cmd = shift @commands;
    $self->send_p('', $cmd)->then($write) if $self and defined $cmd;
  };

  $self->$write;
}

# :superman!superman@i.love.debian.org TOPIC #convos :cool
sub _irc_event_topic {
  my ($self, $msg) = @_;
  my ($nick, $user, $host) = IRC::Utils::parse_user($msg->{prefix} || '');
  my $dialog = $self->dialog({name => $msg->{params}[0], topic => $msg->{params}[1]});

  $self->emit(state => topic => $dialog->TO_JSON)->save(sub { });

  return $self->_notice("Topic unset by $nick") unless $dialog->topic;
  return $self->_notice("$nick changed the topic to: " . $dialog->topic);
}

sub _is_current_nick { lc $_[0]->_nick eq lc $_[1] }

sub _make_ctcp_string {
  my $self = shift;
  local $_ = join ' ', @_;
  s/([\012\015\0\cP])/\cP$CTCP_QUOTE{$1}/g;
  s/\001/\\a/g;
  return ":\001${_}\001";
}

sub _make_invalid_target_p {
  my ($self, $target) = @_;

  # err_norecipient and err_notexttosend
  return Mojo::Promise->reject('Cannot send without target.') unless $target;
  return Mojo::Promise->reject('Cannot send message to target with spaces.') if $target =~ /\s/;
  return;
}

sub _make_ison_response {
  my ($self, $msg) = @_;    # No need to get ($res, $p) here

  my %lookup;
  for (values %{delete $self->{wait_for}{rpl_ison} || {}}) {
    my ($res, $p) = @$_;
    $lookup{$res->{nick}} = $p;
  }

  # Is online
  for my $nick (map {lc} split /\s+/, +($msg->{params}[1] || '')) {
    my $p = delete $lookup{$nick};
    next unless my $dialog = $self->get_dialog($nick);
    $self->emit(state => frozen => $dialog->frozen('')->TO_JSON);
    $p->resolve($dialog);
  }

  # Offline, as far as we can tell
  for my $nick (keys %lookup) {
    next unless my $dialog = $self->get_dialog(lc $nick);
    $self->emit(state => frozen => $dialog->frozen('User is offline.')->TO_JSON);
    $lookup{$nick}->resolve($dialog);
  }
}

sub _make_join_response {
  my ($self, $msg, $res, $p) = @_;

  if ($msg->{command} eq 'rpl_endofnames') {
    $res->{topic}    //= '';
    $res->{topic_by} //= '';
    $res->{users} ||= {};
    $p->resolve($res);
  }
  elsif ($msg->{command} eq 'rpl_namreply') {
    $res->{users} = {};
    for my $nick (sort { lc $a cmp lc $b } split /\s+/, $msg->{params}[3]) {
      $res->{users}{$nick} = $nick;    # TODO
    }
  }
  elsif ($msg->{command} eq 'rpl_topic') {
    $res->{topic} = $msg->{params}[2];
  }
  elsif ($msg->{command} eq 'rpl_topicwhotime') {
    $res->{topic_by} = $msg->{params}[2];
  }
  elsif ($msg->{command} eq 'err_linkchannel') {
    $p->reject(join ' ', @{$msg->{params}});    # TODO
  }
}

sub _make_kick_response {
  my ($self, $msg, $res, $p) = @_;
  warn Mojo::Util::dumper($msg);
  ...;
}

sub _make_names_response {
  my ($self, $msg, $res, $p) = @_;
  warn Mojo::Util::dumper($msg);
  ...;
}

sub _make_topic_response {
  my ($self, $msg, $res, $p) = @_;
  warn Mojo::Util::dumper($msg);
  ...;
}

sub _message_type {
  return 'private' if $_[0]->{command} =~ /privmsg/i;
  return 'action'  if $_[0]->{command} =~ /action/i;
  return 'notice';
}

sub _parse {
  state $parser = Parse::IRC->new(ctcp => 1);
  return $parser->parse($_[1]);
}

sub _periodic_events {
  my $self = shift;
  my $tid;

  Scalar::Util::weaken($self);
  $tid = $self->{periodic_tid} //= Mojo::IOLoop->recurring(
    PERIDOC_INTERVAL,
    sub {
      return shift->remove($tid) unless $self;

      # Try to get the nick you want
      my $nick = $self->url->query->param('nick');
      $self->_write("NICK $nick\r\n") if $nick and !$self->_is_current_nick($nick);

      # Keep the connection alive
      $self->_write("PING => $self->{myinfo}{real_host}\r\n") if $self->{myinfo}{real_host};
    }
  );
}

sub _send_ison_p {
  my ($self, $nick) = @_;
  $self->_write_and_wait_p([ISON => $nick], {nick => $nick}, rpl_ison => {}, '_make_ison_response');
}

sub _send_join_p {
  my ($self, $command) = @_;
  my ($dialog_id, $password) = (split(/\s/, ($command || ''), 2), '', '');

  return $self->_send_query_p($dialog_id)->then(sub {
    my $dialog = shift;
    return !$dialog->frozen ? $dialog : $self->_write_and_wait_p(
      [JOIN => $dialog_id], {dialog_id => lc $dialog_id},
      479                 => {1 => $dialog_id},    # Illegal channel name
      err_badchanmask     => {1 => $dialog_id},
      err_badchannelkey   => {1 => $dialog_id},
      err_bannedfromchan  => {1 => $dialog_id},
      err_channelisfull   => {1 => $dialog_id},
      err_inviteonlychan  => {1 => $dialog_id},
      err_linkchannel     => {1 => $dialog_id},
      err_nosuchchannel   => {1 => $dialog_id},
      err_toomanychannels => {1 => $dialog_id},
      err_toomanytargets  => {1 => $dialog_id},
      err_unavailresource => {1 => $dialog_id},
      rpl_endofnames      => {1 => $dialog_id},
      rpl_namreply        => {1 => $dialog_id},
      rpl_topic           => {2 => $dialog_id},
      rpl_topicwhotime    => {1 => $dialog_id},
      '_make_join_response',
    );
  });
}

sub _send_kick_p {
  my ($self, $target, $command) = @_;
  my ($nick, $reason) = split /\s/, $command, 2;

  return $self->_write_and_wait_p(
    [KICK => "$target $nick :$reason"], {},
    err_needmoreparams   => {},
    err_nosuchchannel    => {1 => $target},
    err_nosuchnick       => {1 => '$user'},
    err_badchanmask      => {1 => $target},
    err_chanoprivsneeded => {1 => $target},
    err_usernotinchannel => {1 => '$user'},
    err_notonchannel     => {1 => $target},
    kick                 => {0 => $target, 1 => '$user'},
    '_make_kick_response',
  );
}

sub _send_list_p {
  my ($self, $extra) = @_;
  my $store = $self->_available_dialogs;
  my @found;

  return Mojo::Promise->reject('Cannot fetch dialogs when not connected.')
    if $self->state ne 'connected';

  # Refresh dialog list
  if ($extra =~ m!\brefresh\b! or !$store->{ts}) {
    $store->{dialogs} = {};
    $store->{done}    = Mojo::JSON->false;
    $store->{ts}      = time;
    $self->_write("LIST\r\n");
  }

  # Search for a specific channel - only works for cached channels
  # IMPORTANT! Make sure the filter cannot execute code inside the regex!
  if ($extra =~ m!/(\W?[\w-]+)/(\S*)!) {
    my ($filter, $re_modifiers, $by, @by_name, @by_topic) = ($1, $2);

    $re_modifiers = 'i' unless $re_modifiers;
    $by           = $re_modifiers =~ s!([nt])!! ? $1 : 'nt';    # name or topic
    $filter       = qr{(?$re_modifiers:$filter)} if $filter;    # (?i:foo_bar)

    for my $dialog (sort { $a->{name} cmp $b->{name} } values %{$store->{dialogs}}) {
      push @by_name,  $dialog and next if $dialog->{name} =~ $filter;
      push @by_topic, $dialog and next if $dialog->{topic} =~ $filter;
    }

    @found = ($by =~ /n/ ? @by_name : (), $by =~ /t/ ? @by_topic : ());
  }
  else {
    @found = sort { $b->{n_users} <=> $a->{n_users} } values %{$store->{dialogs}};
  }

  return Mojo::Promise->resolve({
    n_dialogs => int(keys %{$store->{dialogs}}),
    dialogs   => [splice @found, 0, 200],          # TODO: Figure out a good max result number
    done      => $store->{done},
    ts        => $store->{ts},
  });
}

sub _send_message_p {
  my ($self, $target, $message) = @_;

  my $invalid_target_p = $self->_make_invalid_target_p($target);
  return $invalid_target_p if $invalid_target_p;

  my @messages = $self->_split_message($message // '');
  return Mojo::Promise->reject('Cannot send empty message.') unless @messages;

  for (@messages) {
    $_ = $self->_parse(sprintf ':%s PRIVMSG %s :%s', $self->_nick, $target, $_);
    return Mojo::Promise->reject('Unable to construct PRIVMSG.') unless ref $_;
  }

  if (MAX_BULK_MESSAGE_SIZE <= @messages) {
    return $self->user->core->backend->handle_event_p(multiline_message => \$message)->then(sub {
      return $self->_send_message_p($target, shift->to_message);
    });
  }

  # Seems like there is no way to know if a message is delivered
  # Instead, there might be some errors occuring if the message had issues:
  # err_cannotsendtochan, err_nosuchnick, err_notoplevel, err_toomanytargets,
  # err_wildtoplevel, irc_rpl_away

  return Mojo::Promise->all(map { $self->_write_p($_->{raw_line}) } @messages)->then(sub {
    for my $msg (@messages) {
      $msg->{prefix} = sprintf '%s!%s@%s', $self->_nick, $self->url->query->param('user'),
        $self->url->host;
      $msg->{event} = lc $msg->{command};
      $self->_irc_event_privmsg($msg);
    }
    return {};
  });
}

sub _send_mode_p {
  my ($self, $target, $mode) = @_;

  my $res = {
    banlist    => [],
    exceptlist => [],
    invitelist => [],
    uniqopis   => [],
    mode       => $mode,
    params     => ''
  };

  return $self->_write_and_wait_p(
    [MODE => $target, $mode], {},
    err_chanoprivsneeded => {1 => $target},
    err_keyset           => {1 => $target},
    err_needmoreparams   => {1 => $target},
    err_nochanmodes      => {1 => $target},
    err_unknownmode      => {1 => $target},
    err_usernotinchannel => {1 => $target},
    mode                 => {0 => $target},
    rpl_endofbanlist     => {1 => $target},
    rpl_endofexceptlist  => {1 => $target},
    rpl_endofinvitelist  => {1 => $target},
    rpl_channelmodeis => {},    #sub { @$res{qw(mode params)} = @{$_[1]->{params}}[1, 2] },
    rpl_banlist       => {},    #sub { push @{$res->{banlist}}, $_[1]->{params}[1] },
    rpl_exceptlist    => {},    #sub { push @{$res->{exceptlist}}, $_[1]->{params}[1] },
    rpl_invitelist    => {},    #sub { push @{$res->{invitelist}}, $_[1]->{params}[1] },
    rpl_uniqopis      => {},    #sub { push @{$res->{uniqopis}}, $_[1]->{params}[1] },
    '_make_mode_response',
  );
}

sub _send_names_p {
  my ($self, $dialog_id) = @_;

  return Mojo::Promise->reject('Channel name is required') unless length $dialog_id;
  return $self->_write_and_wait_p(
    [NAMES => $dialog_id], {dialog_id => lc $dialog_id},
    err_toomanymatches => {1 => $dialog_id},
    rpl_endofnames     => {1 => $dialog_id},
    timeout            => 30,
    '_make_names_response',
  );
}

sub _send_nick_p {
  my ($self, $nick) = @_;
  $self->url->query->param(nick => $nick);
  return $self->_write("NICK $nick\r\n") if $self->{stream};
  return Mojo::Promise->resolve({});
}

sub _send_part_p {
  my ($self, $name) = @_;
  return Mojo::Promise->reject('Command missing arguments.') unless $name and $name =~ /\S/;

  my $dialog = $self->get_dialog($name);
  return $self->_remove_dialog($name)->save_p if $dialog and $dialog->is_private;
  return $self->_remove_dialog($name)->save_p if $self->state eq 'disconnected';
  return $self->_proxy(
    part_channel => $name,
    sub {
      my ($irc, $err) = @_;
      $self->_remove_dialog($name)->save_p;
    }
  );
}

sub _send_query_p {
  my ($self, $channel) = @_;
  my $p = Mojo::Promise->new;

  # Invalid input
  return $p->reject('Command missing arguments.') unless $channel and $channel =~ /\S/;

  # Already in the dialog
  ($channel) = split /\s/, $channel, 2;
  my $dialog = $self->get_dialog($channel);
  return $p->resolve($dialog) if $dialog and !$dialog->frozen;

  # New dialog. Note that it needs to be frozen, so join_channel will be issued
  $dialog ||= $self->dialog({name => $channel});
  $dialog->frozen('Not active in this room.') if !$dialog->is_private and !$dialog->frozen;
  return $p->resolve($dialog);
}

sub _send_topic_p {
  my ($self, $target, $topic) = @_;

  my $invalid_target_p = $self->_make_invalid_target_p($target);
  return $invalid_target_p if $invalid_target_p;

  $self->_write_and_wait_p(
    [TOPIC => $target, defined $topic ? (":$topic") : ()], {},
    err_chanoprivsneeded => {1 => $target},
    err_nochanmodes      => {1 => $target},
    err_notonchannel     => {1 => $target},
    rpl_notopic          => {1 => $target},
    rpl_topic => {1 => $target},    # :hybrid8.debian.local 332 superman #convos :get cool topic
    topic     => {0 => $target},    # set
    '_make_topic_response',
  );
}

sub _send_whois_p {
  my ($self, $nick) = @_;
  ...;
}

sub _split_message {
  my $self     = shift;
  my @messages = split /\r?\n/, shift;
  my $n        = 0;

  while ($n < @messages) {
    if (MAX_MESSAGE_LENGTH <= length $messages[$n]) {
      my @chunks = split /(\s)/, $messages[$n];
      $messages[$n] = '';
      while (@chunks) {
        my $chunk = shift @chunks;
        if (MAX_MESSAGE_LENGTH > length($messages[$n] . $chunk)) {
          $messages[$n] .= $chunk;
        }
        else {
          splice @messages, $n + 1, 0, join '', $chunk, @chunks;
        }
      }
    }

    $n++;
  }

  return map { trim $_ } @messages;
}

sub _stream {
  my ($self, $loop, $err, $stream) = @_;
  $self->SUPER::_stream($loop, $err, $stream);

  unless ($err) {
    my $url = $self->url;
    $self->_write(sprintf "PASS %s\r\n", $url->password) if length $url->password;
    $self->_write(sprintf "NICK %s\r\n", $self->_nick);
    $self->_write(sprintf "USER %s 0 * :%s\r\n", $url->query->param('user'), 'https://convos.by/');
  }
}

sub _stream_on_read {
  my ($self, $stream, $buf) = @_;
  $self->{buffer} .= Unicode::UTF8::decode_utf8($buf, sub {$buf});

CHUNK:
  while ($self->{buffer} =~ s/^([^\015\012]+)[\015\012]//m) {
    $self->_debug('>>> %s', term_escape $1) if DEBUG;
    my $msg = $self->_parse($1);
    next unless $msg->{command};

    $msg->{command} = IRC::Utils::numeric_to_name($msg->{command}) || $msg->{command}
      if $msg->{command} =~ /^\d+$/;
    $msg->{command} = lc $msg->{command};
    my $method = "_irc_event_$msg->{command}";
    $self->_debug('->%s(...)', $method) if DEBUG;

    $self->can($method) ? $self->$method($msg) : $self->_irc_event_fallback($msg);

  WAIT_FOR:
    for (values %{$self->{wait_for}{$msg->{command}} || {}}) {
      my ($res, $p, $rules, $make_response_method) = @$_;

      for my $k (keys %$rules) {
        my $v = $k =~ /^\d/ ? $msg->{params}[$k] : $msg->{$k};
        next WAIT_FOR unless lc $v eq lc $rules->{$k};
      }

      $self->$make_response_method($msg, $res, $p);
    }

    $self->emit(irc_message => $msg)->emit($method => $msg) if IS_TESTING;
  }
}

sub _write_and_wait_p {
  my $make_response_method = pop;
  my ($self, $write, $res, %events) = @_;

  my @names = keys %events;
  my $id    = ++$self->{wait_for_id};
  my $p     = Mojo::Promise->new;
  $self->{wait_for}{$_}{$id} = [$res, $p, $events{$_}, $make_response_method] for @names;

  return Mojo::Promise->race(
    Mojo::Promise->timeout($events{timeout} || 60),
    Mojo::Promise->all($p, $self->_write_p(@$write))
  )->finally(sub {
    delete $self->{wait_for}{$_}{$id} for @names;
  });
}

sub DESTROY {
  my $tid = $_[0]->{periodic_tid};
  Mojo::IOLoop->remove($tid) if $tid;
}

sub TO_JSON {
  my $self = shift;
  my $json = $self->SUPER::TO_JSON(@_);
  $json->{me} = $self->{myinfo} || {};
  $json;
}

1;

=encoding utf8

=head1 NAME

Convos::Core::Connection::Irc - IRC connection for Convos

=head1 DESCRIPTION

L<Convos::Core::Connection::Irc> is a connection class for L<Convos> which
allow you to communicate over the IRC protocol.

=head1 ATTRIBUTES

L<Convos::Core::Connection::Irc> inherits all attributes from L<Convos::Core::Connection>
and implements the following new ones.

=head1 METHODS

L<Convos::Core::Connection::Irc> inherits all methods from L<Convos::Core::Connection>
and implements the following new ones.

=head2 connect

See L<Convos::Core::Connection/connect>.

=head2 disconnect_p

See L<Convos::Core::Connection/disconnect_p>.

=head2 nick

  $self = $self->nick($nick => sub { my ($self, $err) = @_; });
  $self = $self->nick(sub { my ($self, $err, $nick) = @_; });
  $nick = $self->nick;

Used to set or get the nick for this connection. Setting this nick will change
L</nick> and try to change the nick on server if connected. Getting this nick
will retrieve the active nick on server if connected and fall back to returning
L</nick>.

=head2 send_p

See L<Convos::Core::Connection/send>.

=head1 SEE ALSO

L<Convos::Core>.

=cut
