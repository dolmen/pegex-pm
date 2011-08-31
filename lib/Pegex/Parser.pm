##
# name:      Pegex::Parser
# abstract:  Pegex Parser Runtime
# author:    Ingy döt Net <ingy@cpan.org>
# license:   perl
# copyright: 2010, 2011
# see:
# - Pegex::Grammar

# To Do:
#
# match() needs to be split into:
# - match() - api entry point
# - match_next() - dispatcher
# - match_rule() - rule matching
# position reversion needs refactoring

package Pegex::Parser;
use Pegex::Base -base;

# Parser, receiver and input objects/classes to use.
has 'grammar';
has 'receiver' => -init => 'require Pegex::AST; Pegex::AST->new()';
has 'input';

# Internal properties.
has 'position';
has 'match_groups';

# Debug the parsing of input.
has 'debug' => -init => '$self->debug_';

sub debug_ {
    exists($ENV{PERL_PEGEX_DEBUG}) ? $ENV{PERL_PEGEX_DEBUG} :
    defined($Pegex::Grammar::Debug) ? $Pegex::Grammar::Debug :
    0;
}

sub parse {
    my $self = shift;
    $self = $self->new unless ref $self;

    die "Usage: " . ref($self) . '->parse($input [, $start_rule]'
        unless 1 <= @_ and @_ <= 2;

    $self->input(shift); # XXX Change to Pegex::Input object

    $self->position(0);
    $self->match_groups([]);
    my $start_rule = shift || undef;

    my $receiver = $self->receiver or die;
    if (not ref $receiver) {
        eval "require $receiver";
        $self->receiver($receiver->new);
    }

    $start_rule ||= 
        $self->grammar->tree->{TOP}
            ? 'TOP'
            : $self->grammar->tree->{'+top'}
        or die "No starting rule for Pegex::Parser::parse";

    $self->receiver->__begin__()
        if $self->receiver->can("__begin__");

    $self->match($start_rule);
    if ($self->position < length($self->input)) {
        $self->throw_error("Parse document failed for some reason");
    }

    $self->receiver->__final__()
        if $self->receiver->can("__final__");

    # Parse was successful!
    return ($self->receiver->can('data') ? $self->receiver->data : 1);
}

sub match {
    my $self = shift;
    my $rule = shift or die "No rule passed to match";

    my $state = undef;
    if (not ref($rule) and $rule =~ /^\w+$/) {
        die "\n\n*** No grammar support for '$rule'\n\n"
            unless $self->grammar->tree->{$rule};
        $state = $rule;
        $rule = $self->grammar->tree->{$rule};
    }

    my $kind;
    my $times = '1';
    my $not = 0;
    my $has = 0;
    if (my $mod = $rule->{'+mod'}) {
        if ($mod eq '!') {
            $not = 1;
        }
        elsif ($mod eq '=') {
            $has = 1;
        }
        else {
            $times = $mod;
        }
    }
    if ($rule->{'.ref'}) {
        $rule = $rule->{'.ref'};
        $kind = 'rule';
    }
    elsif (defined $rule->{'.rgx'}) {
        $rule = $rule->{'.rgx'};
        $kind = 'regexp';
    }
    elsif ($rule->{'.all'}) {
        $rule = $rule->{'.all'};
        $kind = 'all';
    }
    elsif ($rule->{'.any'}) {
        $rule = $rule->{'.any'};
        $kind = 'any';
    }
    elsif ($rule->{'.err'}) {
        my $error = $rule->{'.err'};
        $self->throw_error($error);
    }
    else {
        WWW $rule;
        require Carp;
        Carp::confess("no support for $rule");
    }

    $self->callback("try", $state, $kind)
        if $state and not $not;

    my $position = $self->position;
    my $count = 0;
    my $method = ($kind eq 'rule') ? 'match' : "match_$kind";
    while ($self->$method($rule)) {
        $position = $self->position unless $not;
        $count++;
        last if $times eq '1' or $times eq '?';
    }
    if ($count and $times =~ /[\+\*]/) {
        $self->position($position);
    }
    my $result = (($count or $times =~ /^[\?\*]$/) ? 1 : 0) ^ $not;
    $self->position($position) unless $result;

    $self->callback(($result ? "got" : "not"), $state, $kind)
        if $state and not $not;

    return $result;
}

sub match_all {
    my $self = shift;
    my $list = shift;
    my $pos = $self->position;
    for my $elem (@$list) {
        $self->match($elem) or $self->position($pos) and return 0;
    }
    return 1;
}

sub match_any {
    my $self = shift;
    my $list = shift;
    for my $elem (@$list) {
        $self->match($elem) and return 1;
    }
    return 0;
}

sub match_regexp {
    my $self = shift;
    my $regexp = shift;

    pos($self->{input}) = $self->position;
    $self->{input} =~ /$regexp/g or return 0;
    {
        no strict 'refs';
        $self->match_groups([ map ${$_}, 1..$#+ ]);
    }
    $self->position(pos($self->{input}));

    return 1;
}

sub callback {
    my ($self, $adj, $state, $kind) = @_;
    my $callback = "${adj}_$state";
    my $got = $adj eq 'got';

    $self->trace($callback) if $self->debug;

    my $done = 0;
    if ($self->receiver->can($callback)) {
        $self->receiver->$callback(@{$self->match_groups});
        $done++;
    }
    $callback = "end_$state";
    if ($adj =~ /ot$/ and $self->receiver->can($callback)) {
        $self->receiver->$callback($got, @{$self->match_groups});
        $done++
    }
    return if $done;

    $callback = "__${adj}__";
    if ($self->receiver->can($callback)) {
        $self->receiver->$callback($state, $kind, $self->match_groups);
    }
    $callback = "__end__";
    if ($adj =~ /ot$/ and $self->receiver->can($callback)) {
        $self->receiver->$callback($got, $state, $kind, $self->match_groups);
    }
}

sub trace {
    my $self = shift;
    my $action = shift;
    my $indent = ($action =~ /^try_/) ? 1 : 0;
    $self->{indent} ||= 0;
    $self->{indent}-- unless $indent;
    print ' ' x $self->{indent};
    $self->{indent}++ if $indent;
    my $snippet = substr($self->input, $self->position);
    $snippet = substr($snippet, 0, 30) . "..." if length $snippet > 30;
    $snippet =~ s/\n/\\n/g;
    print sprintf("%-30s", $action) . ($indent ? " >$snippet<\n" : "\n");
}

sub throw_error {
    my $self = shift;
    my $msg = shift;
#     die $msg;
    my $line = @{[substr($self->input, 0, $self->position) =~ /(\n)/g]} + 1;
    my $context = substr($self->input, $self->position, 50);
    $context =~ s/\n/\\n/g;
    my $position = $self->position;
    die <<"...";
Error parsing Pegex document:
  msg: $msg
  line: $line
  context: "$context"
  position: $position
...
}

1;

=head1 SYNOPSIS

    use Pegex::Parser;

=head1 DESCRIPTION

This is the Pegex module that provides the parsing engine runtime. It has a
C<parse()> method that applies a grammar to a text that supposedly matches
that grammar. It also calls the callback methods of its Receiver object.

Generally this module is not used directly, but is called upon via a
L<Pegex::Grammar> object.