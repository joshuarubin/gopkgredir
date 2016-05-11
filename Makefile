VERSION = 0.1.0

all: build

include .lib.mk

EXECUTABLE ?= $(REPO_NAME)
DOCKER_EXECUTABLE = $(DOCKER_DIR)/$(EXECUTABLE)
LDFLAGS := '-X main.name=$(EXECUTABLE) -X main.version=$(VERSION)'

build: $(EXECUTABLE)

$(EXECUTABLE): $(GO_FILES)
	go build -v -ldflags $(LDFLAGS) -o $(EXECUTABLE) $(BASE_PKG)

$(DOCKER_EXECUTABLE): $(GO_FILES)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -v -ldflags $(LDFLAGS) -o $(DOCKER_EXECUTABLE) $(BASE_PKG)

image: .image-stamp

.image-stamp: $(DOCKER_EXECUTABLE) $(DOCKERFILE)
	docker build -t $(DOCKER_IMAGE) Docker
	@touch .image-stamp

clean::
	rm -f \
		$(EXECUTABLE) \
		$(DOCKER_EXECUTABLE) \
		.image-stamp

.PHONY: all build image clean
