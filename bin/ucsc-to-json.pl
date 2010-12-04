#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

#use IO::Uncompress::Gunzip qw($GunzipError);
use PerlIO::gzip;
use Getopt::Long;
use List::Util qw(min max);
use JSON 2;
use JsonGenerator;
use ExternalSorter;

my $trackdb = "trackDb";
my ($indir, $tracks, $arrowheadClass, $subfeatureClasses, $clientConfig, $db,
    $nclChunk, $compress);
my $outdir = "data";
my $cssClass = "basic";
my $sortMem = 1024 * 1024 * 512;
GetOptions("in=s" => \$indir,
           "out=s" => \$outdir,
           "track=s@" => \$tracks,
           "cssClass=s", \$cssClass,
           "arrowheadClass=s", \$arrowheadClass,
           "subfeatureClasses=s", \$subfeatureClasses,
           "clientConfig=s", \$clientConfig,
           "nclChunk=i" => \$nclChunk,
           "compress" => \$compress,
           "sortMem=i" =>\$sortMem);

die "please specify the directory with the database dumps using the --in parameter"
    unless defined($indir);

if (!defined($nclChunk)) {
    # default chunk size is 50KiB
    $nclChunk = 50000;
    # $nclChunk is the uncompressed size, so we can make it bigger if
    # we're compressing
    $nclChunk *= 2 if $compress;
}

my $trackRel = "tracks";
my $trackDir = "$outdir/$trackRel";
mkdir($outdir) unless (-d $outdir);
mkdir($trackDir) unless (-d $trackDir);

my %refSeqs =
    map {
        $_->{name} => $_
    } @{JsonGenerator::readJSON("$outdir/refSeqs.js", [], 1)};

# the jbrowse NCList code requires that "start" and "end" be
# the first and second fields in the array; @defaultHeaders and @srcMap
# are used to take the fields from the database and put them
# into the order specified by @defaultHeaders

my @defaultHeaders = ("start", "end", "strand", "name", "score", "itemRgb");
my %typeMaps =
    (
        "genePred" =>
            ["txStart", "txEnd", "strand", "name", "score", "itemRgb"],
        "bed" =>
            ["chromStart", "chromEnd", "strand", "name", "score", "itemRgb"]
        );

my @subfeatHeaders = ("start", "end", "strand", "type");

my %skipFields = ("bin" => 1,
                  "chrom" => 1,
                  "cdsStart" => 1,
                  "cdsEnd" => 1,
                  "exonCount" => 1,
                  "exonStarts" => 1,
                  "exonEnds" => 1,
                  "blockCount" => 1,
                  "blockSizes" => 1,
                  "blockStarts" => 1);

my %defaultStyle = ("class" => $cssClass);

foreach my $shortLabel (@$tracks) {
    my %trackdbCols = name2column_map($indir . "/" . $trackdb);
    my $shortLabelCol = $trackdbCols{shortLabel};
    my $trackRows = selectall($indir . "/" . $trackdb,
                              sub { $_[0]->[$shortLabelCol] eq $shortLabel });
    my $track = arrayref2hash($trackRows->[0], \%trackdbCols);
    my %trackSettings = (map {split(" ", $_, 2)} split("\n", $track->{settings}));
    $defaultStyle{subfeature_classes} = JSON::from_json($subfeatureClasses)
        if defined($subfeatureClasses);
    $defaultStyle{arrowheadClass} = $arrowheadClass if defined($arrowheadClass);
    $defaultStyle{clientConfig} = JSON::from_json($clientConfig)
        if defined($clientConfig);

    my @types = split(" ", $track->{type});
    my $type = $types[0];
    die "type $type not implemented" unless exists($typeMaps{$type});

    my %style = (
        %defaultStyle,
        "key" => $trackSettings{shortLabel}
    );

    my %fields = name2column_map($indir . "/" . $track->{tableName});

    my ($converter, $headers, $subfeatures) = makeConverter(\%fields, $type);

    my $color = sprintf("#%02x%02x%02x",
                        $track->{colorR},
                        $track->{colorG},
                        $track->{colorB});

    if ($subfeatures) {
        $style{subfeatureHeaders} = \@subfeatHeaders;
        $style{class} = "generic_parent";
        $style{clientConfig}->{featureCallback} = <<ENDJS;
function(feat, fields, div) {
    if (fields.type) {
        div.className = "basic";
        switch (feat[fields.type]) {
        case "CDS":
        case "thick":
            div.style.height = "10px";
            div.style.marginTop = "-3px";
            break;
        case "UTR":
        case "thin":
            div.style.height = "6px";
            div.style.marginTop = "-1px";
            break;
        }
        div.style.backgroundColor = "$color";
    }
}
ENDJS
    } else {
        $style{clientConfig} = {
            "featureCss" => "background-color: $color; height: 8px;",
            "histCss" => "background-color: $color;"
        };
    }

    my @nameList;
    my $chromCol = $fields{chrom};
    my $startCol = $fields{txStart} || $fields{chromStart};
    my $endCol = $fields{txEnd} || $fields{chromEnd};
    my $nameCol = $fields{name};
    my $compare = sub ($$) {
        $_[0]->[$chromCol] cmp $_[1]->[$chromCol]
            ||
        $_[0]->[$startCol] <=> $_[1]->[$startCol]
            ||
        $_[1]->[$endCol] <=> $_[0]->[$endCol]
    };

    my $sorter = ExternalSorter->new($compare, $sortMem);
    for_columns("$indir/" . $track->{tableName},
                sub { $sorter->add($_[0]) } );
    $sorter->finish();

    my $curChrom;
    my $jsonGen;
    while (1) {
        my $row = $sorter->get();
        if ((!defined($row))
                || (!defined($curChrom))
                    || ($curChrom ne $row->[$chromCol])) {
            if ($jsonGen && $jsonGen->hasFeatures && $refSeqs{$curChrom}) {
                print STDERR "working on $curChrom\n";
                $jsonGen->generateTrack();
            }

            if (defined($row)) {
                $curChrom = $row->[$chromCol];
                mkdir("$trackDir/" . $curChrom)
                    unless (-d "$trackDir/" . $curChrom);
                $jsonGen = JsonGenerator->new("$trackDir/$curChrom/"
                                              . $trackSettings{track},
                                              $trackRel, $nclChunk,
                                              $compress, $trackSettings{track},
                                              $curChrom,
                                              $refSeqs{$curChrom}->{start},
                                              $refSeqs{$curChrom}->{end},
                                              \%style, $headers,
                                              \@subfeatHeaders);
            } else {
                last;
            }
        }
        my $jsonRow = $converter->($row, \%fields, $type);
        $jsonGen->addFeature($jsonRow);
        if (defined $nameCol) {
            $jsonGen->addName([[$_[0]->[$nameCol]],
                               $trackSettings{track},
                               $_[0]->[$nameCol],
                               $_[0]->[$chromCol],
                               $jsonRow->[0],
                               $jsonRow->[1],
                               $_[0]->[$nameCol]]);
        }
    }

    my $ext = ($compress ? "jsonz" : "json");
    JsonGenerator::modifyJSFile("$outdir/trackInfo.js", "trackInfo",
        sub {
            my $origTrackList = shift;
            my @trackList = grep { exists($_->{'label'}) } @$origTrackList;
            my $i;
            for ($i = 0; $i <= $#trackList; $i++) {
                last if ($trackList[$i]->{'label'} eq $trackSettings{track});
            }
            $trackList[$i] =
                {
                    'label' => $trackSettings{track},
                    'key' => $style{"key"},
                    'url' => "$trackRel/{refseq}/"
                        . $trackSettings{track}
                            . "/trackData.$ext",
                    'type' => "FeatureTrack",
                };
            return \@trackList;
        });
}

sub calcSizes {
    my ($starts, $ends) = @_;
    return undef unless (defined($starts) && defined($ends));
    return [map($ends->[$_] - $starts->[$_], 0..$#$starts)];
}

sub abs2rel {
    my ($start, $starts) = @_;
    return [map($_ - $start, @$starts)];
}

sub indexHash {
    my @list = @_;
    my %result;
    for (my $i = 0; $i <= $#list; $i++) {
        $result{$list[$i]} = $i;
    }
    return \%result;
}

sub maybeIndex {
    my ($ary, $index) = @_;
    return (defined $index) ? $ary->[$index] : undef;
}

sub splitNums {
    my ($ary, $index) = @_;
    return [] unless defined $index;
    return [map(int, split(",", $ary->[$index]))];
}

sub makeConverter {
    # $orig_fields should be a reference to a hash where
    # the keys are names of columns in the source, and the values
    # are the positions of those columns

    # returns a sub that converts a row from the source
    # into an array ready for adding to a JsonGenerator,
    # and a reference to an array of header strings that
    # describe the arrays returned by the sub
    my ($orig_fields, $type) = @_;
    my %fields = (%$orig_fields);
    my @headers;
    my $srcMap = $typeMaps{$type};
    my @indexMap;
    # map pre-defined fields
    for (my $i = 0; $i <= $#defaultHeaders; $i++) {
        last if $i > $#{$srcMap};
        my $srcName = $srcMap->[$i];
        if (exists($fields{$srcName})) {
            push @headers, $defaultHeaders[$i];
            push @indexMap, $fields{$srcName};
            delete $fields{$srcName};
        }
    }
    # map remaining fields
    foreach my $f (keys %fields) {
        next if $skipFields{$f};
        push @headers, $f;
        push @indexMap, $fields{$f};
    }

    my $destIndices = indexHash(@headers);
    my $strandIndex = $destIndices->{strand};

    my $extraProcessing;
    my $subfeatures;
    if (exists($fields{thickStart})) {
        push @headers, "subfeatures";
        my $subIndex = $#headers;
        $subfeatures = 1;
        $extraProcessing = sub {
            my ($dest, $src) = @_;
            $dest->[$subIndex] =
                makeSubfeatures(maybeIndex($dest, $strandIndex),
                                $dest->[0], $dest->[1],
                                maybeIndex($src, $fields{blockCount}),
                                splitNums($src, $fields{chromStarts}),
                                splitNums($src, $fields{blockSizes}),
                                maybeIndex($src, $fields{thickStart}),
                                maybeIndex($src, $fields{thickEnd}),
                                "thin", "thick");
        }
    } elsif (exists($fields{cdsStart})) {
        push @headers, "subfeatures";
        my $subIndex = $#headers;
        $subfeatures = 1;
        $extraProcessing = sub {
            my ($dest, $src) = @_;
            $dest->[$subIndex] =
                makeSubfeatures(maybeIndex($dest, $strandIndex),
                                $dest->[0], $dest->[1],
                                maybeIndex($src, $fields{exonCount}),
                                abs2rel($dest->[0], splitNums($src, $fields{exonStarts})),
                                calcSizes(splitNums($src, $fields{exonStarts}),
                                          splitNums($src, $fields{exonEnds})),
                                maybeIndex($src, $fields{cdsStart}),
                                maybeIndex($src, $fields{cdsEnd}),
                                "UTR", "CDS");
        }
    } else {
        $subfeatures = 0;
        $extraProcessing = sub {};
    }

    my $converter = sub {
        my ($row) = @_;
        # copy fields that we're keeping into the array that we're keeping
        my $result = [@{$row}[@indexMap]];
        # make sure start/end are numeric
        $result->[0] = int($result->[0]);
        $result->[1] = int($result->[1]);
        if (defined $strandIndex) {
            $result->[$strandIndex] =
                defined($result->[$strandIndex]) ?
                    ($result->[$strandIndex] eq '+' ? 1 : -1) : 0;
        }
        $extraProcessing->($result, $row);
        return $result;
    };

    return $converter, \@headers, $subfeatures;
}

sub makeSubfeatures {
    my ($strand, $start, $end,
        $block_count, $offset_list, $length_list,
        $thick_start, $thick_end,
        $thin_type, $thick_type) = @_;

    my @subfeatures;

    $thick_start = int($thick_start);
    $thick_end = int($thick_end);

    my $parent_strand = $strand ? ($strand eq '+' ? 1 : -1) : 0;

    if ($block_count > 0) {
        if (($block_count != ($#$length_list + 1))
                || ($block_count != ($#$offset_list + 1)) ) {
            warn "expected $block_count blocks, got " . ($#$length_list + 1) . " lengths and " . ($#$offset_list + 1) . " offsets for feature at $start .. $end";
        } else {
            for (my $i = 0; $i < $block_count; $i++) {
                #block start and end, in absolute (sequence rather than feature)
                #coords.  These are still in interbase.
                my $abs_block_start = int($start) + int($offset_list->[$i]);
                my $abs_block_end = $abs_block_start + int($length_list->[$i]);

                #add a thin subfeature if this block extends
                # left of the thick zone
                if ($abs_block_start < $thick_start) {
                    push @subfeatures, [$abs_block_start,
                                        min($thick_start, $abs_block_end),
                                        $parent_strand,
                                        $thin_type];
                }

                #add a thick subfeature if this block overlaps the thick zone
                if (($abs_block_start < $thick_end)
                        && ($abs_block_end > $thick_start)) {
                    push @subfeatures, [max($thick_start, $abs_block_start),
                                        min($thick_end, $abs_block_end),
                                        $parent_strand,
                                        $thick_type];
                }

                #add a thin subfeature if this block extends
                #right of the thick zone
                if ($abs_block_end > $thick_end) {
                    push @subfeatures, [max($abs_block_start, $thick_end),
                                        $abs_block_end,
                                        $parent_strand,
                                        $thin_type];
                }
            }
        }
    } else {
        push @subfeatures, [$thick_start,
                            $thick_end,
                            $parent_strand,
                            $thick_type];
    }
    return \@subfeatures;
}

# processes a table to find all the rows for which $filter returns true.
# returns a list of arrayrefs, where each arrayref represents a row.
sub selectall {
    my ($table, $filter) = @_;
    my @result;
    for_columns($table, sub { push @result, $_[0] if ($filter->($_[0])) });
    return \@result;
}

# converts an array ref of values and a hash ref with field name->index mappings
# into a hash of name->value mappings
sub arrayref2hash {
    my ($aref, $fields) = @_;
    my %result;
    foreach my $key (keys %$fields) {
        $result{$key} = $aref->[$fields->{$key}];
    }
    return \%result;
}

# subroutine to crudely parse a .sql table description file and return a map from column names to column indices
sub name2column_map {
    my ($table) = @_;
    my $sqlfile = "$table.sql";

    my @cols;
    local *SQL;
    local $_;
    open SQL, "<$sqlfile" or die "$sqlfile: $!";
    while (<SQL>) { last if /CREATE TABLE/ }
    while (<SQL>) {
	last if /^\)/;
	if (/^\s*\`(\S+)\`/) { push @cols, $1 }
    }
    close SQL;

    return map (($cols[$_] => $_), 0..$#cols);
}

# subroutine to crudely parse a .txt.gz table dump, and, for each row,
# apply a given subroutine to a array ref that holds the values for the
# columns of that row
sub for_columns {
    my ($table, $func) = @_;

    # my $gzip = new IO::Uncompress::Gunzip "$table.txt.gz"
    #     or die "gunzip failed: $GunzipError\n";
    my $gzip;
    open $gzip, "<:gzip", "$table.txt.gz"
        or die "failed to open $table.txt.gz: $!\n";

    my $lines = 0;
    my $row = "";
    while (<$gzip>) {
	chomp;
	if (/\\$/) {
	    chop;
	    $row .= "$_\n";
	} else {
	    $row .= $_;
	    my @data = split /\t/, $row; # deal with escaped tabs in data?  what are the escaping rules?
	    &$func (\@data);
	    $row = "";
	}
	if (++$lines % 50000 == 0) { warn "(processed $lines lines)\n" }
    }
    $gzip->close()
        or die "couldn't close $table.txt.gz: $!\n";
}
