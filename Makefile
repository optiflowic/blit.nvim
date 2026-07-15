DEPS_DIR := deps
MINI_NVIM := $(DEPS_DIR)/mini.nvim
MINI_NVIM_REF := v0.15.0

.PHONY: all
all: format-check lint test

$(MINI_NVIM):
	mkdir -p $(DEPS_DIR)
	git clone --depth 1 --branch $(MINI_NVIM_REF) https://github.com/echasnovski/mini.nvim $(MINI_NVIM)

.PHONY: test
test: $(MINI_NVIM)
	nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

.PHONY: format
format:
	stylua .

.PHONY: format-check
format-check:
	stylua --check .

.PHONY: lint
lint:
	selene .
