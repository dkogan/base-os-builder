#!/bin/zsh

read -r -d '' usage <<EOF || true
Usage: $0                                               \
         [--deps] [--tarballs]                          \
         --flavors   'FLAVOR1 FLAVOR2 FLAVOR3 ...'      \
         [--release  DEBIAN_RELEASE]                    \
         [--aptopts  'APTOPT1 APTOPT2 APTOPT3 ...']     \
         [--aptrepos 'APTREPO1 APTREPO2 APTREPO3 ...']  \
         [--include  DEB_GLOB0,DEB_GLOB1 ...]           \
         EQUIVS_FILE

SYNOPSIS

  $0                                                            \
    --deps                                                      \
    --tarballs                                                  \
    --flavors 'dev board-arm64 cross-board-arm64'               \
    --release trixie                                            \
    --aptopts 'Acquire::Check-Date=false'                       \
    --aptrepos 'https://localserver/debian/frobnicator-trixie/' \
    frobnicator.equivs

  ...

  The frobnicator-deps-dev_...deb and frobnicator-deps-board-arm64_...deb and
  frobnicator-deps-cross-board-arm64_...deb are created from the
  fronicator.equivs. And for each one, a system image tarball is created, that
  includes the .deb and all of its dependencies.

DESCRIPTION

This script is used to manage dependencies for a project. Everything required
for a project is pulled in by a single PROJECT-deps-FLAVOR package, created with
"$0 --deps". Different flavors of this package define different use cases, such
as deployment, testing, development, cross-building, etc. The different use
cases are defined in the .equivs file.

--deps and/or --tarballs are required. If both are given, the tarball is
generated with the dependency .deb we just built. If --tarballs is given without
--deps, we download this dependency .deb from the local apt server, passed in
--aptrepos. It is possible to not have a local APT server at all. Without such a
server, any update will require a new image tarball to be built and copied. And
any custom packages will need to be given with --include, rather than simply be
available on the apt server.

The --flavors, --aptopts, --aptrepos options take whitespace-separated lists.
Each flavor has specific logic applied to its name:

- If a flavor string starts with "cross-", this is a cross-build FROM the
  native architecture we're building this on TO the architecture specified
  in the flavor string (see following point)

- If a flavor string ends with -xxx (or the whole string is a single xxx
  without -) AND xxx is one of the KNOWN_ARCHITECTURES, we're building for
  that architecture

Arguments:

  --deps: if given, we build the dependency package. At least one of --deps
  --tarballs must be given

  --tarballs: if given, we build the system image tarballs. At least one of
  --deps tarballs must be given

  --flavors: a whitespace-separated list of flavors to build. Required.

  --release: the Debian/Ubuntu release to target. Required if --tarballs. Unused
  without --tarballs

  --aptopts: a whitespace-separated list of APT option strings. Optional. Unused
  without tarballs

  --aptrepos: a whitespace-separated list of additional APT repos strings.
  Optional. Unused without --tarballs.

  --include: takes a comma-separated list (NOT a whitespace-separated list) of
  packages to include in the image tarball. Usually this isn't needed, and
  everything referenced in the .equivs file is available on the custom APT
  server. If we really don't want to have a custom APT, all the required
  packages can be given in this argument instead. This option is passed verbatim
  to mmdebstrap. See the manpage for that tool for details; there are a lot of
  them.

  EQUIVS_FILE: a required argument. The .equivs file used to define the
  dependencies. This follows the substitution rules defined above
EOF

DO_DEPS=0
DO_TARBALLS=0

# The parsing code to use getopt comes from
#   /usr/share/doc/util-linux/examples/getopt-example.bash
# I'm not an expert, but this sample makes things work
TEMP=$(getopt -o '' --long 'deps,tarballs,flavors:,release:,aptopts:,aptrepos:,include:' -n "$0" -- "$@")
[ $? -ne 0 ] && {
    echo '' > /dev/stderr
    echo $usage > /dev/stderr
    exit 1;
}

eval set -- "$TEMP"
unset TEMP

# The arguments now appear in a nice canonical order, and they are terminated by
# --
while {true} {
    case "$1" in
        '--deps')
            DO_DEPS=1
            shift
            continue
        ;;
        '--tarballs')
            DO_TARBALLS=1
            shift
            continue
        ;;

        '--flavors')
            FLAVORS=$2
            shift 2
            continue
        ;;


        '--release')
            DEBIAN_RELEASE=$2
            shift 2
            continue
        ;;

        '--aptopts')
            APTOPTS=$2
            shift 2
            continue
        ;;

        '--aptrepos')
            APT_REPOS_EXTRA=$2
            shift 2
            continue
        ;;

        '--include')
            INCLUDE=$2
            shift 2
            continue
        ;;

        '--')
            shift
            break
        ;;

        *)
            echo 'Internal error in argument parsing' >&2
            exit 1
        ;;
    esac
}

if (( $#* != 1 )) {
       echo "Exactly 1 non-option argument is required. Got $#* instead" > /dev/stderr
       echo '' > /dev/stderr
       echo $usage > /dev/stderr
       exit 1
}

if ((DO_DEPS + DO_TARBALLS == 0)) {
       echo "At least one of (--deps, --tarballs) MUST be given" > /dev/stderr
       echo '' > /dev/stderr
       echo $usage > /dev/stderr
       exit 1
}

if [[ -z "$FLAVORS" ]] {
       echo "--flavors is required" > /dev/stderr
       echo '' > /dev/stderr
       echo $usage > /dev/stderr
       exit 1
}


if ((DO_TARBALLS)) {
    if [[ -z "$DEBIAN_RELEASE" ]] {
           echo "--release is required if --tarballs is given" > /dev/stderr
           echo '' > /dev/stderr
           echo $usage > /dev/stderr
           exit 1
    }
}

EQUIVS_FILE=$*

# Option parsing done! No errors allowed from this point on
set -e

PROJECT=${EQUIVS_FILE:t:r}

FLAVORS=(${=FLAVORS})
APTOPTS=(${=APTOPTS})

# From https://buildd.debian.org/
KNOWN_ARCHITECTURES=(amd64          \
                     arm64          \
                     armel          \
                     armhf          \
                     i386           \
                     mips64el       \
                     ppc64el        \
                     riscv64        \
                     s390x          \
                     alpha          \
                     hppa           \
                     hurd-amd64     \
                     hurd-i386      \
                     loong64        \
                     m68k           \
                     powerpc        \
                     ppc64          \
                     sh4            \
                     sparc64        \
                     x32)

function IS_CROSS {
    flavor=$1
    [[ $flavor == cross-* ]]
}
function ARCH {
    flavor=$1

    # strip the leading .....-
    local arch=${flavor##*-}

    if (( ${KNOWN_ARCHITECTURES[(Ie)$arch]} )) {
        # found architecture; return it
        echo $arch
    }
    # The last token wasn't a known architecture. Return nothing
}
function ARCH_NATIVE {
    flavor=$1
    arch=$(ARCH $flavor)
    if {IS_CROSS $flavor} {

        if { [[ -n "$arch" ]] } {
            dpkg-architecture -q DEB_BUILD_ARCH
        } else {
            echo "Cross-building flavor '$flavor' MUST have the target architecture as the last token" > /dev/stderr
            exit 1
        }
    } else {
        if { [[ -n "$arch" ]] } {
            echo $arch;
        } else {
            dpkg-architecture -q DEB_BUILD_ARCH
        }
    }
}
function ARCH_TARGET {
    flavor=$1
    if {IS_CROSS $flavor} {
        arch=$(ARCH $flavor)

        if { [[ -n "$arch" ]] } {
            echo $arch
        } else {
            echo "Cross-building flavor '$flavor' MUST have the target architecture as the last token" > /dev/stderr
            exit 1
        }
    } else {
        # not cross-building. return ''
    }
}
function ARCH_TARGET_SPEC {
    flavor=$1
    arch_target=$(ARCH_TARGET $flavor)
    [[ -n "$arch_target" ]] && echo ":${arch_target}"
}
function MMDEBSTRAP_FLAGS {
    flavor=$1
    if {IS_CROSS $flavor} {
        echo                                                            \
          --architectures=$(ARCH_NATIVE $flavor),$(ARCH_TARGET $flavor)   \
          --include ca-certificates                                     \
          --include crossbuild-essential-$(ARCH_TARGET_$flavor)         \
          --include binfmt-support                                      \
          --include qemu-user-static
    } else {
        echo                                    \
          --architectures=$(ARCH_NATIVE $flavor)  \
          --include ca-certificates
    }
}
function APT_REPOS {

    APT_REPOS_BASE=(http://deb.debian.org/debian \
                    http://security.debian.org/debian-security)

    for r (${APT_REPOS_BASE}) {
        RELEASE_SUFFIX=''
        [[ $r == */debian-security ]] && RELEASE_SUFFIX="-security"

        for k (deb deb-src) {
            echo "$k $r ${DEBIAN_RELEASE}${RELEASE_SUFFIX} main contrib non-free non-free-firmware"
        }
    }

    for r (${APT_REPOS_EXTRA}) {
        for k (deb deb-src) {
            echo "$k [trusted=yes] $r ${DEBIAN_RELEASE} main"
        }
    }
}


if ((DO_DEPS)) {
    for flavor ($FLAVORS) {

        EQUIVS_FILE_SUBSTITUTED=/tmp/${EQUIVS_FILE:t:r}-$flavor.substituted.${EQUIVS_FILE:t:e}

        < $EQUIVS_FILE \
        ${0:A:h}/substitute-deps-file.pl \
            DEPS_PACKAGE_NAME=${PROJECT}-deps-${flavor} \
            ARCH_NATIVE=$(ARCH_NATIVE $flavor) \
            ARCH_TARGET=$(ARCH_TARGET $flavor) \
            ARCH_TARGET_SPEC=$(ARCH_TARGET_SPEC $flavor) \
            FLAVOR=$flavor \
        > $EQUIVS_FILE_SUBSTITUTED

        equivs-build \
           -a $(ARCH_NATIVE $flavor) \
           $EQUIVS_FILE_SUBSTITUTED
    }
}


if ((DO_TARBALLS)) {

    # --aptopt opt1 --aptopt opt2 ...
    APTOPTS=("--aptopt "${^APTOPTS})
    APTOPTS=(${=APTOPTS})

    VERSION=$(< $EQUIVS_FILE awk '/^Version:/ {print $2; exit}' )

    for flavor ($FLAVORS) {

        if ((DO_DEPS)) {     
            # --deps. We specify the package file on disk that we just built
            # We must specify this as a path (absolute or relative)
            # AND we must tell mmdebstrap to bind-mount the directory to make
            # this file finable inside the chroot
            INCLUDE_DEP=(--include ${PROJECT}-deps-${flavor}_${VERSION}_$(ARCH_NATIVE $flavor).deb(:A)
                         --hook-dir=/usr/share/mmdebstrap/hooks/file-mirror-automount)
        } else {
            # No --deps. We specify the package name
            INCLUDE_DEP_ARGS=(--include ${PROJECT}-deps-${flavor})
        }

        TARBALL_FILE=${PROJECT}-${flavor}_${VERSION}_$(ARCH_NATIVE $flavor).tar.gz

        # Needed to split the arguments on newlines and not words. This allows
        # arguments with whitespace in it, as is necessary with "deb" lines
        APT_REPOS_ARGS=("${(@f)$(APT_REPOS)}")

        cmd=(mmdebstrap                         \
             ${INCLUDE_DEP_ARGS}                \
             ${=INCLUDE:+--include $INCLUDE}    \
             $(MMDEBSTRAP_FLAGS $flavor)        \
             $APTOPTS                           \
             $DEBIAN_RELEASE                    \
             _$TARBALL_FILE                     \
             ${APT_REPOS_ARGS})

        if { $cmd } {
            mv _$TARBALL_FILE $TARBALL_FILE
        } else {
            echo "ERROR: mmdebstrap failed:\n$cmd" > /dev/stderr
            exit 1
        }
    }
}
