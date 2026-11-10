-- Limitty for Hyprland (hyprland.lua syntax).
-- Included by:  require("limitty")   (this file at ~/.config/hypr/limitty.lua)

-- The widget: small, floating, on every workspace, top-right, no focus stealing.
hl.window_rule({
  name = "limitty-widget",
  match = { title = "^Limitty$" },
  float = true,
  pin = true,
  move = { "monitor_w-window_w-16", "56" },
  no_initial_focus = true,
  border_size = 0,
  no_shadow = true,
  no_blur = true,
})

-- The Company window: a normal floating window.
hl.window_rule({
  name = "limitty-company",
  match = { title = "^Limitty Company$" },
  float = true,
  size = { 820, 760 },
  center = true,
})

-- Start with Hyprland.
hl.on("hyprland.start", function()
  hl.exec_cmd("limitty")
end)
