use Test::More tests => 1;

use Pegex;

my $grammar = "
phrase: !<one> <number> /<WS>*/ <things>
one: /1/
number: /<DIGIT>/
things: /blind mice/
";

eval { pegex($grammar)->parse("3 blind mice") }; $@
? fail $@
: pass "!<rule> works";