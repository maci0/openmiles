.PHONY: all build test clean lint format

all: build

build:
	zig build

test:
	zig build test

lint:
	zig fmt --check .
	shellcheck scripts/*.sh

format:
	zig fmt .

clean:
	rm -rf zig-out .zig-cache
