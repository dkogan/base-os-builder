#!/usr/bin/perl

# Processes the dependency file for each specific image flavor. Variables are
# passed to this script on the commandline. We can run
#
#   substitute-deps-file.pl x=5 y=22
#
# and then $x and $y will be available to use for evaluation in the <<<...>>> tags.
#
# The metapackage definition file contains several tags that are substituted
# with perl. Two flavors are supported:
#
# - <<<if .... >>>
#   The .... expression is evaluated; if true, the line this tag appears on is
#   kept; if false, the line is removed
#
# - <<<eval .... >>>
#   The .... expression is evaluated, and the whole <<<...>>> tag replaced with
#   the result
#
# Both of these tags must appear on a single line. The expressions in these tags
# are evaluated with perl. The following variables are available in those
# expressions:
#
# - $DEPS_PACKAGE_NAME
#
#   The name of dependency package being built
#
# - $ARCH_HOST
#
#   The architecture of the dependency package I'm creating
#
# - $ARCH_TARGET
#
#   The architecture of the binaries we're cross-building for. Empty string if
#   we're not cross-building
#
# - $ARCH_TARGET_SPEC
#
#   Convenience variable. ":$ARCH_TARGET" when making an image for
#   cross-building and "" when making a native image. Used for Depends:
#       libwhatever-dev<<<eval $:ARCH_TARGET>>>
#
# - $FLAVOR
#
#   The flavor being built


use strict;
use warnings;
use feature ':5.10';

# needed to support the dynamic variable definition and usage
no warnings 'once';
no strict 'refs';
no strict 'vars';

# parse all the a=5 b=7 strings on the commandline. I read these arguments into
# local perl variables
for my $kv (@ARGV)
{
    my ($k,$v) = $kv =~ /^(.+?)=(.*)/;

    # explicitly set the variable in the string $k to the value $v. This weird
    # syntax is needed to bypass the scoping rules
    *{$k} = \$v;
}

RECORD:
while(<STDIN>)
{
    while(/<<<(\S+)\s+(.*?)>>>/p)
    {
        my $expr = eval($2);
        if($1 eq "if") {
            if($expr) {
                $_ = ${^PREMATCH} . ${^POSTMATCH};
            } else {
                next RECORD;
            }
        } elsif($1 eq "eval") {
            $_ = ${^PREMATCH} . $expr . ${^POSTMATCH};
        }
        else
        {
            die("Unknown tag '<<<$1...>>>");
        }
    }

    print;
}
