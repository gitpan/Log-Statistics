use 5.008006;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Log::Statistics',
    VERSION_FROM      => 'lib/Log/Statistics.pm', # finds $VERSION
    EXE_FILES         => [ qw[ scripts/logstatsd ] ],
    PREREQ_PM         => {
        "YAML" => 0,
        "Date::Manip" => 0,
    }, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Log/Statistics.pm', # retrieve abstract from module
       AUTHOR         => 'VVu <VVu@geekfarm.org>') : ()),
);
