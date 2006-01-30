package Log::Statistics;
use warnings;
use strict;

# $Id: Statistics.pm 27 2006-01-30 00:02:11Z wu $
our $VERSION = sprintf "0.%03d", q$Revision: 27 $ =~ /(\d+)/g;

#
#_* Libraries
#
use YAML;
use Data::Dumper;
use IO::File;
use Date::Manip;

# logging
use Log::Log4perl qw(:resurrect :easy);
###l4p my $logger = get_logger( 'default' );

#
#_* new
#

sub new
{
    my ( $class, $data ) = @_;
    my $objref = ( { data => $data } );
    ###l4p $logger->info( "creating new object: $class" );
    bless $objref, $class;
    return $objref;
}

sub register_field {
    my ( $self, $name, $column ) = @_;

    unless ( defined( $name ) && defined( $column ) ) {
        ###l4p $logger->logconfess( "not enough arguments" );
        die "not enough arguments";
    }

    # provide an easy way to look up a column by field name
    ###l4p $logger->debug( "Adding index for field $name => $column" );
    $self->{'field_index'}->{ $name } = $column;

    return 1;
}

sub add_field {
    my ( $self, $column, $name, $threshold ) = @_;

    unless ( defined( $column ) && defined( $name ) ) {
        ###l4p $logger->logconfess( "not enough arguments" );
        die "not enough arguments";
    }

    ###l4p $logger->info( "adding field: $column -> $name" );
    ###l4p $logger->info( "threshold: $threshold" ) if $threshold;

    unless ( $name eq "duration" ) {
        push @{ $self->{'field_column'} }, $column;
        push @{ $self->{'field_name'} }, $name;

        my @thresholds;
        if ( $threshold ) {
            @thresholds = split /\|/, $threshold;
            unshift @thresholds, 0 unless $thresholds[0] eq "0";
            $self->{'threshold_index'}->{ $name } = \@thresholds;
        }
        push @{ $self->{'thresholds'} }, \@thresholds;

    }

    $self->register_field( $name, $column );
    return 1;
}

# specify to keep data for the intersection of field1 and field2.  For
# example, if name is transaction name and name2 is the location
# field, data will be kept about transaction breakdown per location.
sub add_group {
    my ( $self, $names, $threshold ) = @_;

    unless ( scalar( @$names ) > 1 ) {
        ###l4p $logger->logconfess( "not enough fields specified" );
        die "not enough fields specified";
    }

    my $group_name = join "-", @$names;

    # data field name
    push @{ $self->{'group'}->{'name'} }, $group_name;

    push @{ $self->{'group'}->{'names'} }, $names;

    my @group_columns;
    for my $name ( @$names ) {
        unless ( defined( $self->{'field_index'}->{ $name } ) ) {
            ###l4p $logger->logconfess( "error: no index found for field $name" );
            die "error: no index found for field $name";
        }
        push @group_columns, $self->{'field_index'}->{ $name };
    }

    # which columns to track
    push @{ $self->{'group'}->{'column'} }, \@group_columns;

    my @thresholds;
    if ( $threshold ) {
        @thresholds = split /\|/, $threshold;
        $self->{'threshold_index'}->{ $group_name } = \@thresholds;
    }
    push @{ $self->{'group'}->{'thresholds'} }, \@thresholds;

    return 1;
}

# add a regexp to parse the time field
sub add_time_regexp {
    my ( $self, $time_regexp ) = @_;
    $self->{'time_regexp'} = $time_regexp;
}

# add a custom regexp to split entire entry into fields
sub add_line_regexp {
    my ( $self, $line_regexp ) = @_;
    $self->{'line_regexp'} = $line_regexp;
}

sub parse_text {
    my ( $self, $text ) = @_;

    for my $line ( split /\n/, $text ) {
        $self->parse_line( $line );
    }

    return $self->{'data'};
}

sub save_data {
    my ( $self, $file ) = @_;
    ###l4p $logger->info( "Saving data to yaml file: $file" );

    unless ( $self->{'data'} ) {
        ###l4p $logger->logconfess( "No data specified" );
        die "No data to save";
    }
    unless ( $file ) {
        ###l4p $logger->logconfess( "No file specified" );
        die "No file specified";
    }

    YAML::DumpFile( $file, $self->{'data'} );
}

sub read_data {
    my ( $self, $file ) = @_;
    ###l4p $logger->info( "Reading yaml data from $file" );

    # Load
    $self->{'data'} = {
        %{ YAML::LoadFile( $file ) || {} },
    };
}

sub parse_line {
    my ( $self, $line ) = @_;
    return unless $line;
    return if $line =~ m|^\#|;
    $line =~ s|\s+$||;
    $line =~ s|^\s+||;

    my @values;

    if ( $self->{'line_regexp'} ) {
        $line =~ m|$self->{'line_regexp'}|;
        @values = ( $1, $2, $3, $4, $5, $6, $7, $8, $9 );
    }
    else {
        @values = split /\s*,\s*/, $line;
    }
    return unless scalar @values;

    my $duration = $self->{'field_index'}->{'duration'} ? $values[ $self->{'field_index'}->{'duration'} ] : undef;

    # for each line, total counters are incremented
    $self->{'data'}->{'total'}->{'duration'} += $duration if $duration;
    $self->{'data'}->{'total'}->{'count'} ++;

    if ( $self->{'time_regexp'} && $self->{'field_index'}->{'time'} ) {
        if ( $values[ $self->{'field_index'}->{'time'} ] ) {
            $values[ $self->{'field_index'}->{'time'} ] =~ s|^.*(?:$self->{'time_regexp'}).*$|$1|;
        }
        else {
            ###l4p $logger->debug( "no time in entry: $line" );
            return;
        }
    }

    # for each column being parsed, collect summary data
    for my $index ( 0 .. $#{ $self->{'field_column'} } ) {

        # get the name of this field
        my $name = $self->{'field_name'}->[$index];
        my $value = $values[ $self->{'field_index'}->{$name} ] || "null";

        # increment counters for this name/value pair
        $self->{'data'}->{'fields'}->{ $name }->{ $value }->{'count'}++;

        if ( $duration ) {

            $self->{'data'}->{'fields'}->{ $name }->{ $value }->{'duration'} += $duration;

          THRESHOLD:
            for my $threshold_idx ( reverse( 0 .. $#{ (@{$self->{'thresholds'}})[$index] } ) ) {
                my $threshold = $self->{'thresholds'}->[$index]->[$threshold_idx];
                if ( $duration > $threshold ) {
                    #print "dur:$duration th:$threshold\n";
                    $self->{'data'}->{'fields'}->{ $self->{'field_name'}->[$index] }->
                        { $values[ $self->{'field_column'}->[$index] ] }->{"th_$threshold_idx"}++;
                    last THRESHOLD;
                }
            }
        }
    }

    # for each group, collect summary data
    if ( $self->{'group'} ) {
        for my $index ( 0 .. $#{ $self->{'group'}->{'name'} } ) {

            my $name = (@{$self->{'group'}->{'name'}})[$index];
            my @names = @{ (@{$self->{'group'}->{'names'}})[$index] };

            my @group_values;
            unless ( defined ( $self->{'data'}->{ 'groups' }->{ $name } ) ) {
                $self->{'data'}->{ 'groups' }->{ $name } = {};
            }

            # walk down the data structure moving the pointer along.
            # must be done since the depth of the hash depends on the
            # number of fields in the group
            my $group_pointer = $self->{'data'}->{ 'groups' }->{ $name };
            for my $name_idx ( 0 .. $#names ) {
                my $value_idx = $self->{'group'}->{'column'}->[$index]->[ $name_idx ];
                my $value = $values[ $value_idx  ] || "null";
                push @group_values, $value;
                unless ( defined( $group_pointer->{ $value } ) ) {
                    $group_pointer->{ $value } = {};
                }
                $group_pointer = $group_pointer->{ $value };
            }
            my ( $value1, $value2 ) = @group_values;

            $group_pointer->{'count'} += 1;

            if ( $duration ) {
                $group_pointer->{'duration'} += $duration;

              THRESHOLD:
                for my $threshold_idx ( reverse( 0 .. $#{ $self->{'group'}->{'thresholds'}->[$index] } ) ) {
                    my $threshold = $self->{'group'}->{'thresholds'}->[$index]->[$threshold_idx];
                    if ( $duration > $threshold ) {
                        $group_pointer->{"th_$threshold_idx"}++;
                        last THRESHOLD;
                    }
                }
            }
        }
    }
}

#
#__* date parsing fu
#

# since date parsing is expensive, dates are cached
sub get_utime_from_string
{
  my ( $self, $string ) = @_;

  if ( $self->{'date_cache'}->{ $string } )
  {
    return $self->{'date_cache'}->{ $string };
  }

  my $date = &UnixDate(ParseDate($string),"%s");

  $self->{'date_cache'}->{ $string } = $date;

  return $date;

}



1;

__END__



=head1 NAME

Log::Statistics - near-real-time statistics from log files


=head1 SYNOPSIS

    use Log::Statistics;

    my $log = Log::Statistics->new();

    # field 3 in the log contains the duration.  registering a
    # duration field causes duration information to be added to all
    # summary data.
    $log->register_field( "duration", 2 );

    # field 1 in the log contains transaction name.  add this field to
    # the list of fields for which a summary report will be generated
    $log->add_field( "transaction", 0 );

    # field 2 in the log contains the log status entry (e.g. 404).
    # don't generate a report on this field, but add it to the list of
    # defined fields.
    $log->register_field( "status", 1 );

    # collect data about transaction and status grouped together.
    # this will result in a break-down of all transactions by status.
    # note this is different than all statuses by transaction.
    $log->add_group( [ "transaction", "status" ] );

    # add a regular expression to capture the year, month, day, hour,
    # and minute from the time field.
    my $time_regexp = ^(\d{4}-\d{2}-\d{2}\s\d{2}\:\d{2})
    $log->add_time_regexp( $time_regexp );

    # track overall response times per minute.  time is in field 6 in
    # the log
    $log->add_field( "time", 5 );

    # parse data in the log file
    $log->parse_text( $log_entries );

=head1 DESCRIPTION

Log::Statistics is a module for collecting summary data from a log file.
For examples of what can be done with Log::Statistics, see the code and
documentation in scripts/logstatsd.  logstatsd contains a prototype
implementation of several features which will eventually be migrated
from scripts/logstatsd.

The basic usage is to begin by creating a new Log::Statistics object.
Next, register each field name that you want to collect data about,
indicating which column that data is in.  Next, add fields or groups
of fields for which you wish to collect statistics.  Finally, use
parse_text to add multiple entries or parse_line to a single entry.

This module is alpha quality code, and is still under development.  A
number of the features currently implemented in logstatsd will
eventually find their way back here.


=head1 SUBROUTINES/METHODS

=over 4

=item $log->new()

Create a new Log::Statistics object.

=item $log->register_field( $name, $column )

Define a field in the log, and indicate the column in which the field
exists.  Once a field has been registered, it can be used again later
with add_group or add_field without having to re-specify the column
number.

Registering a field does not automatically include the field in the
report, except for the duration field.  When a duration field has been
defined, all data collected will contain information about durations.

=item $log->add_field( $column, $name, [ $threshold1, $threshold2, ... ] )

Collect summary data about the specified field.  The column can be
undef if the field has previously been registered using
register_field().

For each field added to the report, summary data will be collected for
each unique entry in the field.  So for example, if a transaction
field is added, then summary data will be collected about each unique
transaction found in the log (e.g. the number of hits, total response
times, etc).

Thresholds will only be honored if a duration field has been defined
in the log (see THRESHOLDS below).

=item $log->add_group( [ $field1, $field, ...], [$threshold1, $threshold2, ... ]

Collect summary data about two or more fields grouped together.  The
columns must have previously been defined either by using add_field or
else register_field.

For each group added to the report summary data will be collected for
each unique combination of entries in the fields.  For example, if a
group is defined with "transaction" and "status", then summary
information will be collected about each transaction broken down by
the transaction status.

Note that a group for "transaction","status" is slightly different
from "status","transaction".  The former builds a data structure for
each transaction that contains a hash with the summary data for each
status.  The latter builds a data structure for each status that
contains a hash with the summary data for each transaction.  Dumping
the two data structure to xml using XML::Simple will result in
different output.  For more readable output, it is generally
recommended that you use the field which has the least number of
possible unique values first.

Thresholds will only be honored if a duration field has been defined
in the log (see THRESHOLDS below).

=item $log->add_time_regexp( $regexp )

Define a regular expression which can be used to parse the time field.
The regular expression should capture time to the resolution at which
data should be collected.  If you are parsing a log with many days
data, you may want to generate a report which summarized by each day.
On the other hand, if your log contains many transactions over a short
time period, you might want to break down the summary by activity per
second.

=item $log->add_line_regexp( $regexp )

Define a regular expression which can be used to parse the entire log
entry and divide it up into a series of fields.

=item $log->parse_text( $text )

Generate summary data about the log entries contained in $text.

If no fields or groups have been defined, only overall total data will
be collected.

=item $log->parse_line( $line )

Similar to parse_text, except that only a single log entry is passed.

=item $log->save_data( $file )

Save the data collected to the specified file.  Data will be stored in
the YAML format.

=item $log->read_data( $file )

Load the data collected from the specified store file.  Data can been
stored using save_data.

=item $log->get_utime_from_string

Given a plain text date string from a log, convert it to unix time.  A
cache is built up in RAM of the previously seen time strings to reduce
the overhead of using Date::Manip.

=back

=head1 DEPENDENCIES

YAML - back end storage for log summary data

Date::Manip - for converting log times to unix time.


=head1 SEE ALSO

http://www.geekfarm.org/twiki/bin/view/Main/LogStatistics


=head1 BUGS AND LIMITATIONS

There are no known bugs in this module. Please report problems to
VVu@geekfarm.org

Patches are welcome.


=head1 AUTHOR

VVu@geekfarm.org



=head1 LICENCE AND COPYRIGHT

Copyright (c) 2005, VVu@geekfarm.org
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

- Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

- Neither the name of the geekfarm.org nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.













