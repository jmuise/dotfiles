return {
  "mikavilpas/yazi.nvim",
  event = "VeryLazy",
  keys = {
    { "<leader>fy", "<cmd>Yazi<cr>",        desc = "Open yazi (file)" },
    { "<leader>fY", "<cmd>Yazi cwd<cr>",    desc = "Open yazi (cwd)" },
    { "<leader>fz", "<cmd>Yazi toggle<cr>", desc = "Resume last yazi session" },
  },
  opts = {
    -- Open yazi instead of netrw when opening a directory
    open_for_directories = true,
  },
}
