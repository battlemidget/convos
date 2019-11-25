#!perl
use lib '.';
use t::Helper;

plan skip_all => 'CONVOS_AUTH_LDAP_URL=...' unless $ENV{CONVOS_AUTH_LDAP_URL};

$ENV{CONVOS_PLUGINS} = 'Convos::Plugin::Auth::LDAP';
$ENV{CONVOS_BACKEND} = 'Convos::Core::Backend';
my $t = t::Helper->t;

$t->get_ok('/api/user')->status_is(401);

note 'ldap user';
$t->post_ok('/api/user/login', json => {email => 'superman@example.com', password => 'secret'})
  ->status_is(200)->json_is('/email', 'superman@example.com');

$t->get_ok('/api/user')->status_is(200);
$t->get_ok('/api/user/logout')->status_is(200);

note 'fallback to local user';
$t->app->core->user({email => 'superwoman@example.com'})->set_password('superduper');
$t->post_ok('/api/user/login',
  json => {email => 'superwoman@example.com', password => 'superduper'})->status_is(200)
  ->json_is('/email', 'superwoman@example.com');

done_testing;
