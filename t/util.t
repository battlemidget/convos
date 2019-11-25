use Test::More;
use Convos::Util 'require_module';

eval { require_module 'Foo::Bar' };
my $err = $@;
like $err, qr{You need to install Foo::Bar to use main:}, 'require_module failed message';
like $err, qr{perl ./script/cpanm .* Foo::Bar},           'require_module failed cpanm';

eval { require_module 'Convos::Util' };
ok !$@, 'require_module success';

done_testing;
