SHELL := $(SHELL) -e

TOUCH     ?= touch
GO        ?= go
GIT       ?= git
DATE      ?= date
FIND      ?= find
ECHO      ?= echo
CAT       ?= cat
GREP      ?= grep
EGREP     ?= egrep
TRUE      ?= true
CURL      ?= curl
MKDIR     ?= mkdir
RM        ?= rm -f
MV        ?= mv
LN        ?= ln
DOCKER    ?= docker
GOVERALLS ?= goveralls
GODEP     ?= godep
PROTOC    ?= protoc
TAR       ?= tar
WHICH     ?= which
JQ        ?= jq
XARGS     ?= xargs
SED       ?= sed
AWK       ?= awk

METALINT           := gometalinter --cyclo-over=10 --deadline=10s -t
REPO_NAME          := $(notdir $(CURDIR))
SRC_DIR            := $(realpath $(CURDIR)/../..)
BASE_PKG           := jrubin.io/$(REPO_NAME)
EXCLUDE_DIRS       := ./vendor ./Godeps ./.git
GIT_COMMIT         := $(shell $(GIT) rev-parse --short HEAD 2>/dev/null)
DATE_TAG           := $(shell $(DATE) -u +%Y%m%d-%H%M%S)
BUILD_DATE         := $(shell $(DATE) -u +%Y-%m-%dT%H:%M:%S+00:00)
IMAGE_TAG          := $(DATE_TAG)-$(GIT_COMMIT)
FIRST_GOPATH       := $(firstword $(subst :, ,$(GOPATH)))

GOTEST             ?= $(GO) test # use "gt" if you want results cached for quicker testing
GO_LINTERS         ?= golint go\_vet # \_ is replaced with a space in the command
GO_VERSION         ?= 1.6.2
PUSH_TARGETS       ?= .push_production .push_develop
DOCKER_DIR         ?= Docker
DOCKERFILE         ?= $(DOCKER_DIR)/Dockerfile
DOCKER_IMAGE       ?= joshuarubin/$(REPO_NAME)
CI_SERVICE         ?= unknown
INSTALL_GO_BASEDIR ?= $(HOME)/.go
INSTALL_GOOS       ?= linux
INSTALL_GOARCH     ?= amd64
DIST_OS            ?= linux
DIST_ARCH          ?= amd64
WRAPPER            ?= wrapper

BUILD_DEPS += rsc.io/gt github.com/tools/godep github.com/axw/gocov/gocov github.com/mattn/goveralls

set_system_go_version = $(eval SYSTEM_GO_VERSION := $$(patsubst go%,%,$$(word 3,$$(shell $(GO) version 2>/dev/null))))
$(call set_system_go_version)

INSTALL_GOROOT      := $(INSTALL_GO_BASEDIR)/go$(GO_VERSION)
INSTALL_GO_BIN_DIR  := $(INSTALL_GOROOT)/bin
INSTALL_GO_DEPS     := $(if $(filter $(SYSTEM_GO_VERSION),$(GO_VERSION)),,$(INSTALL_GO_BIN_DIR)/go reset_system_go_version)
INSTALL_GO_FILE     := go$(GO_VERSION).$(INSTALL_GOOS)-$(INSTALL_GOARCH).tar.gz
INSTALL_GO_FULLFILE := $(INSTALL_GO_BASEDIR)/$(INSTALL_GO_FILE)
INSTALL_DEPS        := $(foreach os,$(DIST_OS),$(foreach arch,$(DIST_ARCH),.install-stamp-$(os)-$(arch)))

## if go needed to be installed, ensure that the installation completes before
## installing build dependencies
BUILD_DEPS_DEPS := $(if $(INSTALL_GO_DEPS),install_go)

ifeq ($(CIRCLECI),true)
	CI_SERVICE = circle-ci
	export GIT_BRANCH = $(CIRCLE_BRANCH)
endif

export GO15VENDOREXPERIMENT=1

# return test_string only if it does not contain any of the exclude_strings
#
# $(call exclude,test_string,exclude_strings
exclude = $(foreach 1,$1,$(if $(sort $(foreach 2,$2,$(if $(findstring $2,$1),$1))),,$1))

# GO_PKGS - a list of go packages excluding vendor
GO_PKGS := \
	$(strip \
	$(foreach pkg, \
		$(shell $(GO) list ./... 2>/dev/null), \
		$(call exclude,$(pkg),/vendor/)))

# PROFILES - a list of profile files to expect from the coverage test
# a profile file is simply .profile_$(pkg).out where $(pkg) is the go package
# name with each '/' replaced with '__'
PROFILES := \
	$(patsubst %,.profile_%.out, \
	$(subst /,__,$(GO_PKGS)))

# ALL_DIRS - a list of directories, recursive, from $(CURDIR) excluding
# anything containing any of $(EXCLUDE_DIRS)
ALL_DIRS := \
	$(patsubst ./%, %, \
	$(sort \
	$(foreach dir, \
		$(shell $(FIND) . -type d), \
		$(call exclude,$(dir),$(EXCLUDE_DIRS)))))

# get all files in $(ALL_DIRS) that have the given extension
#
# $(call find-files-with-extension,$(extension))
find-files-with-extension = \
	$(strip \
	$(patsubst ./%, %, \
	$(foreach dir, \
		$(ALL_DIRS), \
		$(wildcard $(dir)/*.$1))))

# GO_FILES - a list of all .go files in any directory in $(ALL_DIRS)
GO_FILES := $(call find-files-with-extension,go)

# PROTO_FILES - a list of all .proto files in any directory in $(ALL_DIRS)
PROTO_FILES := $(call find-files-with-extension,proto)

# PROTO_DIRS - a list of all directories that have .proto files in them
PROTO_DIRS := \
	$(strip \
	$(patsubst %/, %, \
	$(sort \
	$(dir \
	$(PROTO_FILES)))))

define \n


endef

go_generate    = cd $(1) && $(GO) generate
is_defined     = $(if $(sort $(foreach 1,$1,$(if $(value $1),,0))),,1)
check_defined  = $(foreach 1,$1,$(if $(value $1),, $(error $1 is undefined)))
check_notequal = $(if $(filter $(value $1),$2),$(error $1 is $2))
check_equal    = $(if $(filter $(value $1),$2),,$(error $$($1) ($(value $1)) isn’t $2))
file_exists    = $(if $(wildcard $1),$1)
check_installed = $(if $(shell $(WHICH) $1),,$(error $1 is not installed))

## required for the proto target to evaluate its dependencies, $$(PROTO_DEPS)
.SECONDEXPANSION:

lint:
	$(foreach pkg, $(GO_PKGS), $(foreach cmd, $(GO_LINTERS), $(subst \_, , $(cmd)) $(pkg) | $(EGREP) -v '\.pb\.go:|/bindata\.go:' || $(TRUE)${\n}))

metalint:
	$(foreach pkg, $(GO_PKGS), $(METALINT) $(SRC_DIR)/$(pkg) | $(EGREP) -v '\.pb\.go:|/bindata\.go:' || $(TRUE)${\n})

test: $(GO_FILES)
	$(GOTEST) -race $(GO_PKGS)

profiles: $(PROFILES)

$(PROFILES): %: $(GO_FILES)
	@$(TOUCH) $@
	$(GOTEST) -coverprofile=$@ $(patsubst .profile_%.out,%,$(subst __,/,$@))

.profile: $(PROFILES)
	@$(ECHO) "mode: set" > .profile
	@$(foreach profile, $(PROFILES), $(CAT) $(profile) | $(EGREP) -v "mode: set|\.pb\.go:|/bindata\.go:" >> .profile || $(TRUE);)

coverage: .profile

coveralls: .coveralls-stamp

.coveralls-stamp: .profile
	$(call check_defined,CI_SERVICE COVERALLS_REPO_TOKEN)
	$(GOVERALLS) -v -coverprofile=.profile -service $(CI_SERVICE) -repotoken $(COVERALLS_REPO_TOKEN) || $(TRUE)
	@$(TOUCH) .coveralls-stamp

save:
	$(RM) -r ./Godeps ./vendor
	GOOS=linux GOARCH=amd64 $(GODEP) save ./...

clean::
	$(RM) $(PROFILES) ./.profile ./.coveralls-stamp ./.install-stamp $(INSTALL_DEPS)

define PROTO_template
$(1)_PB_FILES = $(patsubst $(1)/%.proto,$(1)/%.pb.go,$(wildcard $(1)/*.proto))
PROTO_DEPS += $$($(1)_PB_FILES)
$$($(1)_PB_FILES): $(1)/%.pb.go: $(1)/%.proto
	cd ../.. && $(PROTOC) --go_out=plugins=grpc:. $(patsubst %,zvelo.io/$(notdir $(CURDIR))/%,$(wildcard $(1)/*.proto))
endef

$(foreach dir,$(PROTO_DIRS),$(eval $(call PROTO_template,$(dir))))

proto: $$(PROTO_DEPS)

$(INSTALL_GO_FULLFILE):
	@$(MKDIR) -p $(INSTALL_GO_BASEDIR)
	$(CURL) -s https://storage.googleapis.com/golang/$(INSTALL_GO_FILE) -o $(INSTALL_GO_FULLFILE)

reset_system_go_version: $(INSTALL_GO_BIN_DIR)/go
	$(call set_system_go_version)
	$(call check_equal,SYSTEM_GO_VERSION,$(GO_VERSION))

$(INSTALL_GO_BIN_DIR)/go: $(INSTALL_GO_FULLFILE)
	$(TAR) -C $(INSTALL_GO_BASEDIR) -zxf $(INSTALL_GO_FULLFILE)
	$(MV) $(INSTALL_GO_BASEDIR)/go $(INSTALL_GOROOT)
	@$(ECHO) go is installed at: `$(WHICH) go`
	@$(GO) version
	@$(ECHO) GOPATH=$(GOPATH)
	@$(TOUCH) $(INSTALL_GO_BIN_DIR)/go

install_go: $(INSTALL_GO_DEPS)

touch_proto:
	$(TOUCH) $(PROTO_DEPS)

install:: .install-stamp $(INSTALL_DEPS)

.install-stamp: $(GO_FILES)
	$(GO) install -v ./... || $(TRUE)
	@$(TOUCH) .install-stamp

$(INSTALL_DEPS): %: $(GO_FILES)
	CGO_ENABLED=0 GOOS=$(word 3,$(subst -, ,$@)) GOARCH=$(word 4,$(subst -, ,$@)) $(GO) install -v ./... || $(TRUE)
	@$(TOUCH) $@

.push_image: .image-stamp
	$(DOCKER) tag $(DOCKER_IMAGE):latest $(DOCKER_IMAGE):$(IMAGE_TAG)
	$(DOCKER) push $(DOCKER_IMAGE):$(IMAGE_TAG)
	@$(TOUCH) .push_image

$(PUSH_TARGETS): .push_%: .image-stamp
	$(call check_defined,VERSION)

	$(if $(filter $*,production), \
		$(DOCKER) push $(DOCKER_IMAGE):latest${\n} \
		$(DOCKER) tag $(DOCKER_IMAGE):latest $(DOCKER_IMAGE):v$(VERSION)${\n} \
		$(DOCKER) push $(DOCKER_IMAGE):v$(VERSION)${\n} \
	)

	$(DOCKER) tag $(DOCKER_IMAGE):latest $(DOCKER_IMAGE):$*
	$(DOCKER) push $(DOCKER_IMAGE):$*

	$(DOCKER) tag $(DOCKER_IMAGE):latest $(DOCKER_IMAGE):$*-$(DATE_TAG)
	$(DOCKER) push $(DOCKER_IMAGE):$*-$(DATE_TAG)

	@$(TOUCH) $@

fix_circle:
	$(call check_equal,CIRCLECI,true)

	$(RM) -r $(HOME)/.go_workspace/src/jrubin.io/$(REPO_NAME)
	$(MKDIR) -p $(HOME)/.go_workspace/src/jrubin.io/
	$(MV) $(HOME)/$(REPO_NAME) $(HOME)/.go_workspace/src/jrubin.io/
	$(LN) -s $(HOME)/.go_workspace/src/jrubin.io/$(REPO_NAME) $(HOME)/$(REPO_NAME)

go_bin_exists        = $(call file_exists,$(FIRST_GOPATH)/bin/$(notdir $1))
go_bin_not_installed = $(if $(call go_bin_exists,$1),,$1)
go_deps_to_install  := $(strip $(foreach dep,$(BUILD_DEPS),$(call go_bin_not_installed,$(dep))))

docker_login:
ifeq ($(call is_defined,DOCKER_EMAIL DOCKER_USER DOCKER_PASS),1)
	$(DOCKER) login -e "$(DOCKER_EMAIL)" -u "$(DOCKER_USER)" -p "$(DOCKER_PASS)"
endif

build_deps: $(BUILD_DEPS_DEPS)
	$(if $(go_deps_to_install),$(GO) get -v $(go_deps_to_install))

circle_deps: docker_login build_deps

version:
	$(call check_defined,VERSION)
	@$(ECHO) $(VERSION)

$(WRAPPER):
	$(call check_defined,GITHUB_API_TOKEN)
	$(call check_installed,$(JQ))
	$(CURL) -sH"Authorization: token $(GITHUB_API_TOKEN)" https://api.github.com/repos/zvelo/wrapper/releases/latest \
			| $(JQ) '.assets | .[] | select(.name == "wrapper_linux_amd64") | .url' \
			| $(XARGS) $(CURL) -siH"Authorization: token $(GITHUB_API_TOKEN)" -H"Accept: application/octet-stream" \
			| $(GREP) -i '^location: ' \
			| $(SED) 's/\r//' \
			| $(AWK) '{print $$2}' \
			| $(XARGS) $(CURL) -so $(WRAPPER)

get_wrapper: $(WRAPPER)

.PHONY: lint metalint test profiles coverage coveralls save clean proto install_go touch_proto install fix_circle docker_login build_deps circle_deps version get_wrapper
