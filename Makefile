all: deps
.PHONY: all

# These variables are REQUIRED in the environment or commandline:
#   PROJECT
#     The name of this project. Will be used in the name of the tarball and
#     dependency meta-package. We will look for a file named
#     ${PROJECT}-deps.equivs
#
#   DEBIAN_RELEASE
#     The Debian release used as the base of the OS image we build here.
#     Something like "trixie" is what we want
#
#   FLAVORS
#     Whitespace-separated list of the OS flavors to support. Rules applied to
#     each flavor name:
#
#     - If a flavor string starts with "cross-", this is a cross-build FROM the
#       native architecture we're building this on TO the architecture specified
#       in the flavor string (see following point)
#
#     - If a flavor string ends with -xxx (or the whole string is a single xxx
#       without -) AND xxx is one of the KNOWN_ARCHITECTURES, we're building for
#       that architecture
#
# These variables are OPTIONAL in the environment or commandline:
#   PUSH_TARBALLS_PATH
#     If defined, "make push-tarballs" will rsync all the tarballs we just built
#     to this path
#
#   DPUT_TARGET
#     If defined, "make push-deps" will dput all the packages we just built to
#     this dput target
#
#   APT_REPOS_EXTRA
#     A list of APT repos to use as package sources when building the image IN
#     ADDITION TO the base Debian APT server. These will all use [trusted=yes].
#     If omitted, we use the base Debian APT server only
#
#   APTOPT
#     A list of APT options to pass as --aptopt to mmdebstrap. Each
#     whitespace-separated token is treated as a separate option
VARIABLES_REQUIRED :=				\
  PROJECT					\
  DEBIAN_RELEASE				\
  FLAVORS

$(foreach v,$(VARIABLES_REQUIRED),$(if ${$v},,$(error '$v' MUST be defined in the environment or on the commandline)))




# From https://buildd.debian.org/
KNOWN_ARCHITECTURES :=	\
  amd64			\
  arm64			\
  armel			\
  armhf			\
  i386			\
  mips64el		\
  ppc64el		\
  riscv64		\
  s390x			\
  alpha			\
  hppa			\
  hurd-amd64		\
  hurd-i386		\
  loong64		\
  m68k			\
  powerpc		\
  ppc64			\
  sh4			\
  sparc64		\
  x32			\

ARCH_NATIVE := $(shell dpkg-architecture -q DEB_BUILD_ARCH)

# I create two sets of variables to tell me which architectures are which:
#
# - ARCH_HOST_$(flavor): the native architecture of the tarball/packages we're
#   building
#
# - ARCH_TARGET_$(flavor): this applies to cross-builds only: native builds get
#   an empty string. The target architecture of the tarball/packages we're
#   building
define setvar
$1 := $2
endef

define define_ARCH_variables
_tokens      := $$(subst -, ,$1)
_ntokens     := $$(words $$(_tokens))
_token_first := $$(word 1,$$(_tokens))
_token_last  := $$(word $$(_ntokens),$$(_tokens))

# the architecture in this string, or an empty string if there wasn't one
_arch  := $$(filter $$(KNOWN_ARCHITECTURES),$$(_token_last))

_cross := $$(filter cross,$$(_token_first))

$$(if $$(_cross),										\
  $$(if $$(_arch),										\
    $$(eval $$(call setvar,ARCH_HOST_$1,$$(ARCH_NATIVE)))					\
    $$(eval $$(call setvar,ARCH_TARGET_$1,$$(_arch)))						\
    ,												\
    $$(error "Cross-building flavor '$1' MUST have the target architecture as the last token"))	\
  ,												\
  $$(eval $$(call setvar,ARCH_HOST_$1,$$(or $$(_arch),$$(ARCH_NATIVE))))			\
)
endef
$(foreach f,$(FLAVORS),$(eval $(call define_ARCH_variables,$f)))

# for debugging:
# $(foreach v,$(.VARIABLES),$(if $(filter ARCH_%,$v),$(info $v = $($v))))


DEPS         := $(PROJECT)-deps
EQUIVS_FILE  := $(DEPS).equivs
VERSION      := $(shell < $(EQUIVS_FILE) awk '/^Version:/ {print $$2; exit}' )

define rules_build_deps
$$(DEPS)-$1.substituted.equivs: $$(EQUIVS_FILE)
	< $$< ./substitute-deps-file.pl DEPS_PACKAGE_NAME=$(DEPS)-$1 \
                                        ARCH_HOST=$${ARCH_HOST_$1} \
                                        ARCH_TARGET=$${ARCH_TARGET_$1} \
                                        ARCH_TARGET_SPEC=$$(if $${ARCH_TARGET_$1},:$${ARCH_TARGET_$1}) \
                                        FLAVOR=$1 \
	> $$@

%-$1_$$(VERSION)_$$(ARCH_HOST_$1).changes %-$1_$$(VERSION)_$$(ARCH_HOST_$1).deb: %-$1.substituted.equivs
	equivs-build -a $$(ARCH_HOST_$1) $$<

endef
$(foreach f,$(FLAVORS),$(eval $(call rules_build_deps,$f)))


CHANGES_ALL := $(foreach f,$(FLAVORS),$(DEPS)-$f_$(VERSION)_$(ARCH_HOST_$f).changes)

deps: $(CHANGES_ALL)
.PHONY: deps

ifneq ($(DPUT_TARGET),)
push-deps: $(CHANGES_ALL)
	if git status --porcelain -s --untracked-files=no | grep -q .; then	\
	  echo "========== git tree not clean. Commit your changes =========="; false;\
	else									\
	  true;									\
	fi
	git tag v$(VERSION)
	git push origin master
	git push origin --tags
	dput $(DPUT_TARGET) $^
.PHONY: push-deps
endif

# Several configuration options are given:
#
# - We tell apt to not worry about https certs
#
# - We tell apt to use our local package cache for speed
#
# - We tell apt to not look at the date. Important because our rovers don't have
#   clock batteries
#
# - We remove the statoverrides for chrony. These require users and groups that
#   won't exist in the chroot in a fresh tarball: these are usually made when
#   the package is installed, and the users, groups are generally inherited from
#   the parent system anyway. Removing the statoverrides makes apt work (it's
#   broken otherwise). And since we do everything as root anyway, it doesn't
#   break anything
COMMA := ,

# we give different flags for cross-building
define mmdebstrap_flags
$(if $(ARCH_TARGET_$1),						\
  --architectures=$(ARCH_HOST_$1)$(COMMA)$(ARCH_TARGET_$1)	\
  --include ca-certificates					\
  --include crossbuild-essential-$(ARCH_TARGET_$1)		\
  --include binfmt-support					\
  --include qemu-user-static					\
,								\
  --architectures=$(ARCH_HOST_$1))
endef

APT_REPOS := http://deb.debian.org/debian

define rules_build_tarballs
$$(PROJECT)-$1_$$(VERSION)_$$(ARCH_HOST_$1).tar.gz: $$(DEPS)-$1_$$(VERSION)_$$(ARCH_HOST_$1).deb
	mmdebstrap				\
	  --include $$(DEPS)-$1			\
          $$(call mmdebstrap_flags,$1)		\
	  $$(foreach o,$$(APTOPT),--aptopt $$o)	\
	  $$(DEBIAN_RELEASE)			\
	  _$$@                                  \
	  $$(foreach r,$$(APT_REPOS), $$(foreach k,deb deb-src, "$$k $$r $$(DEBIAN_RELEASE) main contrib non-free non-free-firmware")) \
	  $$(foreach r,$$(APT_REPOS_EXTRA), $$(foreach k,deb deb-src, "$$k [trusted=yes] $$r $$(DEBIAN_RELEASE) main contrib non-free non-free-firmware")) && \
	mv _$$@ $$@
tarball-$1: $$(PROJECT)-$1_$$(VERSION)_$$(ARCH_HOST_$1).tar.gz
.PHONY: tarball-$1
endef

$(foreach f,$(FLAVORS),$(eval $(call rules_build_tarballs,$f)))

TARBALLS_ALL := $(foreach f,$(FLAVORS),$(PROJECT)-$f_$(VERSION)_$(ARCH_HOST_$f).tar.gz)

tarballs: $(TARBALLS_ALL)
.PHONY: tarballs

ifneq ($(PUSH_TARBALLS_PATH),)
push-tarballs: $(TARBALLS_ALL)
	rsync -av $^ $(PUSH_TARBALLS_PATH)
.PHONY: push-tarballs
endif

clean:
	rm -rf *.deb *.buildinfo *.changes *.upload *.substituted.equivs _*.gz
.PHONY: clean
