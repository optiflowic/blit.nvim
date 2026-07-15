local root = vim.fn.getcwd()

vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(root .. "/deps/mini.nvim")

require("mini.test").setup()
