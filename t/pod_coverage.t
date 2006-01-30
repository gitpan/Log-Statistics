use Test::More;
use Data::Dumper;

eval "use Pod::Coverage";
if ( $@ ) {
    plan skip_all => "Pod::Coverage required for testing POD"
}
else {
    plan 'no_plan';
}

my $pc;

ok(
    $pc = Pod::Coverage->new(package => 'Log::Statistics'),
    "Creating new Pod::Coverage object"
);

my $coverage;

ok(
    $coverage = $pc->coverage(),
    "Invoking coverage()"
);

ok(
    $coverage == 1,
    "Checking Pod::Coverage"
) or print Dumper $pc->naked();


