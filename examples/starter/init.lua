-- Starter plugin for Halo — a tour of the core API in one working file.
--
-- Try it: copy this `starter/` folder into ~/.config/halo/plugins/ and reload
-- (halo reload), or declare it from your init.lua: halo.plugin("you/halo-starter").
-- Everything below is real and runnable; delete what you don't want.

-- ── Commands + keybinds ─────────────────────────────────────────────────────
-- A command palette built with halo.menu: each item carries its own action.
local function palette()
  halo.menu({
    { text = "split pane", desc = "vertical split",      action = function() halo.split() end },
    { text = "new tab",    desc = "new session",          action = function() halo.tab("new") end },
    { text = "clear",      desc = "clear the screen",     action = function() halo.send("clear\n") end },
    { text = "git status", desc = "run in this pane",      action = function() halo.send("git status\n") end },
  })
end
halo.command("palette", palette)          -- runnable as a Halo command
halo.bind("cmd+shift+p", palette)         -- and on a keybind

-- A prompt → run whatever you type; a confirm before something destructive.
halo.command("run", function()
  halo.prompt("command to run", "", function(text)
    if text ~= "" then halo.send(text .. "\n") end
  end)
end)
halo.command("reset", function()
  halo.confirm("Reset this pane?", function(yes)
    if yes then halo.send("clear && reset\n") end
  end)
end)

-- ── Events ──────────────────────────────────────────────────────────────────
-- React when the working directory changes (OSC 7): show it in the chrome.
halo.on("dir-changed", function(paneID)
  local a = halo.active()
  if a then halo.status("» " .. a.cwd) end
end)

-- React to a shell exiting on its own.
halo.on("session-exited", function(paneID)
  halo.notify("a shell exited")
end)

-- React to raw terminal OUTPUT, from EVERY live pane (chunk is raw bytes).
-- Here: flag the word "error" as it scrolls by. Comment this out if it's noisy.
halo.on("pane-output", function(paneID, chunk)
  if chunk:find("error", 1, true) then
    halo.notify("saw 'error' in a pane")
  end
end)

-- ── A live panel ─────────────────────────────────────────────────────────────
-- A small bottom-right panel with a clock + cwd, refreshed on a timer. Passing
-- the previous id updates it in place instead of stacking new panels.
local panelId
halo.timer(2, function()
  local a = halo.active()
  panelId = halo.panel({
    { text = os.date("%H:%M:%S"), color = "#7dcfff" },
    { text = a and a.cwd or "—",  color = "#9ece6a" },
    -- An editable field: type + Enter runs it in the active pane.
    { input = true, placeholder = "run…", action = function(t) halo.send(t .. "\n") end },
  }, { title = "starter", corner = "bottomright", width = 240, id = panelId })
end)
