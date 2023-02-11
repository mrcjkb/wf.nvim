local util = require("wf.util")
local au = util.au
local rt = util.rt
local async = util.async
local ingect_deeply = util.ingect_deeply
local match_from_tail = util.match_from_tail
local fuzzy = require("wf.fuzzy")
local which = require("wf.which")
local output_obj_gen = require("wf.output").output_obj_gen
local static = require("wf.static")
local bmap = static.bmap
local row_offset = static.row_offset
local full_name = static.full_name
local augname_leave_check = static.augname_leave_check
local _g = static._g
local sign_group_prompt = static.sign_group_prompt
local cell = require("wf.cell")
local which_insert_map = require("wf.which_map").setup
local group = require("wf.group")
local core = require("wf.core").core
local setup = require("wf.setup").setup
local input = require("wf.input").input

-- FIXME: 起動時直後に入力した文字を適切に消化できてない
-- current windowをwhich_obj or fuzzy_objに移動しない状態でstartinsertに入っている.
-- この方法では呼び出し元のbufferが直後に入力した文字に書き換えられてしまう可能性がある。
-- これを防ぐため、vim.scheduleでstartinsertを囲んだが、
-- 今度は直後に入力した文字がnormalモードのコマンドとして、どこかのwindowで消化されてしまうことがわかった.
-- また、呼び出し元のbufferがイミュータブルになっている場合も考慮する必要がある。
-- TODO: これをどうにかする
-- 方法1: 起動時に文字一つを読み込むinputを起動する。この結果を
-- 方法2: insert modeに入るまでに呼び出し先へのあらゆる入力を禁止する。
--      - この方法はユーザの入力をブロックするので、ユーザは遅延を感じやすい.

-- 追記
-- ウィンドウ起動時にカーソルを移動することである程度早くなった。

-- if cursor not on the objects then quit wf.
local lg = vim.api.nvim_create_augroup(augname_leave_check, { clear = true })
local function leave_check(which_obj, fuzzy_obj, output_obj, del)
  pcall(
    au,
    lg,
    "WinEnter",
    vim.schedule_wrap(function()
      local current_win = vim.api.nvim_get_current_win()
      for _, obj in ipairs({ fuzzy_obj, which_obj, output_obj }) do
        if current_win == obj.win then
          leave_check(fuzzy_obj, which_obj, output_obj, del)
          return
        end
      end
      return del()
    end),
    { once = true }
  )
end

local function objs_setup(fuzzy_obj, which_obj, output_obj, caller_obj, choices_obj, callback)
  local objs = { fuzzy_obj, which_obj, output_obj }
  local del = function() -- deliminator of the whole process
    vim.schedule(function()
      vim.api.nvim_del_augroup_by_name(augname_leave_check)
      lg = vim.api.nvim_create_augroup(augname_leave_check, { clear = true })
    end)
    if caller_obj.mode ~= "i" and caller_obj.mode ~= "t" then
      vim.cmd("stopinsert")
    end

    vim.schedule(function()
      local cursor_valid, original_cursor = pcall(vim.api.nvim_win_get_cursor, caller_obj.win)
      if vim.api.nvim_win_is_valid(caller_obj.win) then
        vim.api.nvim_set_current_win(caller_obj.win)
        vim.api.nvim_win_set_cursor(caller_obj.win, { original_cursor[1], original_cursor[2] })
        -- pcall(vim.api.nvim_set_current_win, caller_obj.win)
        -- pcall(
        --     vim.api.nvim_win_set_cursor,
        --     caller_obj.win,
        --     { original_cursor[1], original_cursor[2] }
        --     )

        -- if
        --     cursor_valid
        --     and vim.api.nvim_get_mode().mode == "i"
        --     and caller_obj.mode ~= "i"
        -- then
        --     print("original cursor")
        --     print(vim.inspect(original_cursor))
        --     print("current cursor")
        --     print(vim.inspect(vim.api.nvim_win_get_cursor(0)))
        --     pcall(
        --         vim.api.nvim_win_set_cursor,
        --         caller_obj.win,
        --         { original_cursor[1], original_cursor[2] }
        --     )
        -- end
      end
      for _, o in ipairs(objs) do
        if vim.api.nvim_buf_is_valid(o.buf) then
          -- vim.api.nvim_set_current_win(o.win)
          vim.api.nvim_buf_delete(o.buf, { force = true })
        end
        if vim.api.nvim_win_is_valid(o.win) then
          vim.api.nvim_win_close(o.win, true)
        end
      end
    end)
  end

  for _, o in ipairs(objs) do
    au(_g, "BufWinLeave", function()
      del()
    end, { buffer = o.buf })
  end

  local to_which = function()
    vim.api.nvim_set_current_win(which_obj.win)
  end
  local to_fuzzy = function()
    vim.api.nvim_set_current_win(fuzzy_obj.win)
  end

  local which_key_list_operator = {
    escape = "<C-C>",
    toggle = "<C-T>",
  }
  for _, o in ipairs(objs) do
    bmap(o.buf, "n", "<esc>", del, "quit")
  end
  local inputs = { fuzzy_obj, which_obj }
  for _, o in ipairs(inputs) do
    bmap(o.buf, { "i", "n" }, which_key_list_operator.escape, del, "quit")
    bmap(o.buf, { "n" }, "m", "", "disable sign")
  end
  bmap(
    fuzzy_obj.buf,
    { "i", "n" },
    which_key_list_operator.toggle,
    to_which,
    "start which key mode"
  )
  bmap(
    which_obj.buf,
    { "i", "n" },
    which_key_list_operator.toggle,
    to_fuzzy,
    "start which key mode"
  )

  -- If `[` is mapped at buffer with `no wait`, sometimes `<C-[>` is ignored and neovim regard as `[`.
  -- So we need to map `<C-[>` to `<C-[>` at buffer with `no wait`.
  vim.api.nvim_buf_set_keymap(
    which_obj.buf,
    "i",
    "<C-[>",
    "<ESC>",
    { noremap = true, silent = true, desc = "Normal mode" }
  )

  local which_map_list = which_insert_map(
    which_obj.buf,
    { which_key_list_operator.toggle, which_key_list_operator.escape }
  )
  local select_ = function()
    local fuzzy_line = vim.api.nvim_buf_get_lines(fuzzy_obj.buf, 0, -1, true)[1]
    local which_line = vim.api.nvim_buf_get_lines(which_obj.buf, 0, -1, true)[1]
    local fuzzy_matched_obj = (function()
      if fuzzy_line == "" then
        return choices_obj
      else
        return vim.fn.matchfuzzy(choices_obj, fuzzy_line, { key = "text" })
      end
    end)()
    for _, match in ipairs(fuzzy_matched_obj) do
      if match.key == which_line then
        del()
        vim.schedule(function()
          callback(match.id, match.text)
        end)
      end
    end
  end
  bmap(which_obj.buf, { "n", "i" }, "<CR>", select_, "select matched which key")
  bmap(fuzzy_obj.buf, { "n", "i" }, "<CR>", select_, "select matched which key")
  return { del = del, which_map_list = which_map_list }
end

local function swap_win_pos(up, down, style)
  local height = 1
  local row = vim.o.lines - height - row_offset() - 1
  local wcnf = vim.api.nvim_win_get_config(up.win)
  vim.api.nvim_win_set_config(
    up.win,
    vim.fn.extend(wcnf, {
      row = row - style.input_win_row_offset,
      border = style.borderchars.center,
      title = { { up.name, up.name == " Which Key " and "WFTitleWhich" or "WFTitleFuzzy" } },
    })
  )
  local fcnf = vim.api.nvim_win_get_config(down.win)
  vim.api.nvim_win_set_config(
    down.win,
    vim.fn.extend(fcnf, {
      row = row,
      border = style.borderchars.bottom,
      title = { { down.name, "WFTitleFreeze" } },
    })
  )
  for _, o in ipairs({ up, down }) do
    vim.api.nvim_win_set_option(o.win, "foldcolumn", "1")
    vim.api.nvim_win_set_option(o.win, "signcolumn", "yes:2")
  end
end

local function fuzzy_setup(which_obj, fuzzy_obj, output_obj, choices_obj, groups_obj, opts, cursor)
  local winenter = function()
    vim.api.nvim_win_set_option(
      fuzzy_obj.win,
      "winhl",
      "Normal:WFFocus,FloatBorder:WFFloatBorderFocus"
    )
    vim.fn.sign_unplace(sign_group_prompt .. "fuzzyfreeze", { buffer = fuzzy_obj.buf })
    vim.fn.sign_place(
      0,
      sign_group_prompt .. "fuzzy",
      sign_group_prompt .. "fuzzy",
      fuzzy_obj.buf,
      { lnum = 1, priority = 10 }
    )
    -- vim.schedule(function()
    --     vim.api.nvim_win_set_option(fuzzy_obj.win, "foldcolumn", "1")
    --     vim.api.nvim_win_set_option(fuzzy_obj.win, "signcolumn", "yes:2")
    -- end)

    local wcnf = vim.api.nvim_win_get_config(output_obj.win)
    vim.api.nvim_win_set_config(
      output_obj.win,
      vim.fn.extend(wcnf, {
        title = (function()
          if opts.title ~= nil then
            return { { " " .. opts.title .. " ", "WFTitleOutputFuzzy" } }
          else
            return opts.style.borderchars.top[2]
          end
        end)(),
      })
    )

    core(choices_obj, groups_obj, which_obj, fuzzy_obj, output_obj, opts)
    -- run(core)(choices_obj, groups_obj, which_obj, fuzzy_obj, output_obj, opts)
    swap_win_pos(fuzzy_obj, which_obj, opts.style)
  end
  if cursor then
    vim.schedule(function()
      winenter()
      vim.fn.sign_place(
        0,
        sign_group_prompt .. "whichfreeze",
        sign_group_prompt .. "whichfreeze",
        which_obj.buf,
        { lnum = 1, priority = 10 }
      )
      local _, _ = pcall(function()
        require("cmp").setup.buffer({ enabled = false })
      end)
    end)
  end
  au(_g, { "TextChangedI", "TextChanged" }, function()
    core(choices_obj, groups_obj, which_obj, fuzzy_obj, output_obj, opts)
    -- run(core)(choices_obj, groups_obj, which_obj, fuzzy_obj, output_obj, opts)
  end, { buffer = fuzzy_obj.buf })
  au(_g, "WinEnter", winenter, { buffer = fuzzy_obj.buf })
  au(_g, "WinLeave", function()
    vim.fn.sign_unplace(sign_group_prompt .. "fuzzyfreeze", { buffer = fuzzy_obj.buf })
    vim.fn.sign_unplace(sign_group_prompt .. "fuzzy", { buffer = fuzzy_obj.buf })
    vim.fn.sign_place(
      0,
      sign_group_prompt .. "fuzzyfreeze",
      sign_group_prompt .. "fuzzyfreeze",
      fuzzy_obj.buf,
      { lnum = 1, priority = 10 }
    )
    vim.api.nvim_win_set_option(
      fuzzy_obj.win,
      "winhl",
      "Normal:WFComment,FloatBorder:WFFloatBorder"
    )
  end, { buffer = fuzzy_obj.buf })
end

local function which_setup(
  which_obj,
  fuzzy_obj,
  output_obj,
  choices_obj,
  groups_obj,
  callback,
  obj_handlers,
  opts,
  cursor
)
  local winenter = function()
    vim.api.nvim_set_hl(0, "WFWhich", { link = "WFWhichOn" })

    vim.api.nvim_win_set_option(
      which_obj.win,
      "winhl",
      "Normal:WFFocus,FloatBorder:WFFloatBorderFocus"
    )
    vim.fn.sign_place(
      0,
      sign_group_prompt .. "which",
      sign_group_prompt .. "which",
      which_obj.buf,
      { lnum = 1, priority = 10 }
    )
    -- vim.schedule(function()
    --     vim.api.nvim_win_set_option(which_obj.win, "foldcolumn", "1")
    --     vim.api.nvim_win_set_option(which_obj.win, "signcolumn", "yes:2")
    -- end)
    local wcnf = vim.api.nvim_win_get_config(output_obj.win)
    vim.api.nvim_win_set_config(
      output_obj.win,
      vim.fn.extend(wcnf, {
        title = (function()
          if opts.title ~= nil then
            return { { " " .. opts.title .. " ", "WFTitleOutputWhich" } }
          else
            return opts.style.borderchars.top[2]
          end
        end)(),
      })
    )
    core(choices_obj, groups_obj, which_obj, fuzzy_obj, output_obj, opts)
    swap_win_pos(which_obj, fuzzy_obj, opts.style)
  end
  if cursor then
    vim.schedule(function()
      winenter()
      vim.fn.sign_place(
        0,
        sign_group_prompt .. "fuzzyfreeze",
        sign_group_prompt .. "fuzzyfreeze",
        fuzzy_obj.buf,
        { lnum = 1, priority = 10 }
      )
      local _, _ = pcall(function()
        require("cmp").setup.buffer({ enabled = false })
      end)
    end)
  end
  au(_g, "BufEnter", function()
    vim.fn.sign_unplace(sign_group_prompt .. "whichfreeze", { buffer = which_obj.buf })
    local _, _ = pcall(function()
      require("cmp").setup.buffer({ enabled = false })
    end)
  end, { buffer = which_obj.buf })
  au(_g, "WinLeave", function()
    vim.api.nvim_set_hl(0, "WFWhich", { link = "WFFreeze" })

    vim.fn.sign_unplace(sign_group_prompt .. "which", { buffer = which_obj.buf })
    vim.fn.sign_place(
      0,
      sign_group_prompt .. "whichfreeze",
      sign_group_prompt .. "whichfreeze",
      which_obj.buf,
      { lnum = 1, priority = 10 }
    )
    vim.api.nvim_win_set_option(
      which_obj.win,
      "winhl",
      "Normal:WFComment,FloatBorder:WFFloatBorder"
    )
  end, { buffer = which_obj.buf })
  au(_g, { "TextChangedI", "TextChanged" }, function()
    local id, text = core(choices_obj, groups_obj, which_obj, fuzzy_obj, output_obj, opts)
    if id ~= nil then
      obj_handlers.del()
      callback(id, text)
    end
  end, { buffer = which_obj.buf })
  au(_g, "WinEnter", winenter, { buffer = which_obj.buf })
  bmap(which_obj.buf, { "n", "i" }, "<CR>", function()
    local fuzzy_line = vim.api.nvim_buf_get_lines(fuzzy_obj.buf, 0, -1, true)[1]
    local which_line = vim.api.nvim_buf_get_lines(which_obj.buf, 0, -1, true)[1]
    local fuzzy_matched_obj = (function()
      if fuzzy_line == "" then
        return choices_obj
      else
        return vim.fn.matchfuzzy(choices_obj, fuzzy_line, { key = "text" })
      end
    end)()
    for _, match in ipairs(fuzzy_matched_obj) do
      if match.key == which_line then
        obj_handlers.del()
        callback(match.id)
      end
    end
  end, "match")
  bmap(which_obj.buf, { "i" }, "<C-H>", function()
    local pos = vim.api.nvim_win_get_cursor(which_obj.win)
    local line = vim.api.nvim_buf_get_lines(which_obj.buf, pos[1] - 1, pos[1], true)[1]
    local front = string.sub(line, 1, pos[2])
    local match = (function()
      for _, v in ipairs(obj_handlers.which_map_list) do
        if match_from_tail(front, v) then
          return v
        end
      end
      return nil
    end)()
    if match == nil then
      return rt("<C-H>")
    else
      return rt("<Plug>(wf-erase-word)")
    end
  end, "<C-h>", { expr = true })
  bmap(which_obj.buf, { "i" }, "<Plug>(wf-erase-word)", function()
    local pos = vim.api.nvim_win_get_cursor(which_obj.win)
    local line = vim.api.nvim_buf_get_lines(which_obj.buf, pos[1] - 1, pos[1], true)[1]
    local front = string.sub(line, 1, pos[2])
    local match = (function()
      for _, v in ipairs(obj_handlers.which_map_list) do
        if match_from_tail(front, v) then
          return v
        end
      end
      return nil
    end)()
    local back = string.sub(line, pos[2] + 1)
    local new_front = string.sub(front, 1, #front - #match)
    vim.fn.sign_unplace(sign_group_prompt .. "which", { buffer = which_obj.buf })
    vim.api.nvim_buf_set_lines(which_obj.buf, pos[1] - 1, pos[1], true, { new_front .. back })
    vim.api.nvim_win_set_cursor(which_obj.win, { pos[1], vim.fn.strwidth(new_front) })
    vim.fn.sign_place(
      0,
      sign_group_prompt .. "which",
      sign_group_prompt .. "which",
      which_obj.buf,
      { lnum = 1, priority = 10 }
    )
  end, "<C-h>")
end

-- core
local function _callback(
  caller_obj,
  fuzzy_obj,
  which_obj,
  output_obj,
  choices_obj,
  groups_obj,
  callback,
  opts
)
  local obj_handlers =
    objs_setup(fuzzy_obj, which_obj, output_obj, caller_obj, choices_obj, callback)
  which_setup(
    which_obj,
    fuzzy_obj,
    output_obj,
    choices_obj,
    groups_obj,
    callback,
    obj_handlers,
    opts,
    opts.selector == "which"
  )
  fuzzy_setup(
    which_obj,
    fuzzy_obj,
    output_obj,
    choices_obj,
    groups_obj,
    opts,
    opts.selector == "fuzzy"
  )

  -- vim.api.nvim_buf_set_lines(which_obj.buf, 0, -1, true, { opts.text_insert_in_advance })
  -- local c = vim.g[full_name .. "#char_insert_in_advance"]
  -- if c ~= nil then
  --     vim.api.nvim_buf_set_lines(fuzzy_obj.buf, 0, -1, true, { opts.text_insert_in_advance .. c })
  -- else
  --     vim.g[full_name .. "#text_insert_in_advance"] = opts.text_insert_in_advance
  --     vim.g[full_name .. "#which_obj_buf"] = which_obj.buf
  -- end
  -- if opts.selector == "fuzzy" then
  --     vim.api.nvim_set_current_win(fuzzy_obj.win)
  --     -- vim.schedule(function()
  --         -- vim.cmd("startinsert!")
  --     -- end)
  -- elseif opts.selector == "which" then
  --     vim.api.nvim_set_current_win(which_obj.win)
  --     -- vim.schedule(function()
  --         -- vim.cmd("startinsert!")
  --     -- end)
  -- else
  --     print("selector must be fuzzy or which")
  --     obj_handlers.del()
  --     return
  -- end
  if opts.selector ~= "fuzzy" and opts.selector ~= "which" then
    print("selector must be fuzzy or which")
    obj_handlers.del()
    return
  end
  leave_check(which_obj, fuzzy_obj, output_obj, obj_handlers.del)
  print("_callback")
  print(vim.inspect(vim.api.nvim_get_mode()))
end

local function setup_objs(choices_obj, callback, opts_)
  -- print(vim.fn.nr2char(vim.fn.getchar()))

  local _opts = vim.deepcopy(require("wf.config"))
  local opts = ingect_deeply(_opts, opts_ or vim.emptydict())

  vim.fn.sign_define(sign_group_prompt .. "fuzzy", {
    text = opts.style.icons.fuzzy_prompt,
    texthl = "WFFuzzyPrompt",
  })
  vim.fn.sign_define(sign_group_prompt .. "which", {
    text = opts.style.icons.which_prompt,
    texthl = "WFWhich",
  })
  vim.fn.sign_define(sign_group_prompt .. "fuzzyfreeze", {
    text = opts.style.icons.fuzzy_prompt,
    texthl = "WFFreeze",
  })
  vim.fn.sign_define(sign_group_prompt .. "whichfreeze", {
    text = opts.style.icons.which_prompt,
    texthl = "WFFreeze",
  })

  local caller_obj = (function()
    local win = vim.api.nvim_get_current_win()
    return {
      win = win,
      buf = vim.api.nvim_get_current_buf(),
      original_mode = vim.api.nvim_get_mode().mode,
      cursor = vim.api.nvim_win_get_cursor(win),
      mode = vim.api.nvim_get_mode().mode,
    }
  end)()

  -- key group_objをリストに格納
  local groups_obj = group.new(opts.key_group_dict)

  -- 表示用バッファを作成
  local output_obj = output_obj_gen(opts)

  -- -- 入力用バッファを作成
  local which_obj = which.input_obj_gen(opts, opts.selector == "which")
  local fuzzy_obj = fuzzy.input_obj_gen(opts, opts.selector == "fuzzy")
  vim.api.nvim_buf_set_lines(which_obj.buf, -2, -1, true, { opts.text_insert_in_advance })
  -- local autocommands = vim.api.nvim_get_autocmds({
  --     event = "InsertEnter",
  -- })
  -- print(vim.inspect(autocommands))
  vim.schedule(function()
    vim.cmd("startinsert!")
    -- print(vim.inspect(vim.api.nvim_get_mode()))
    -- vim.fn.feedkeys('A', 'n')
  end)

  -- async(_callback)(caller_obj, fuzzy_obj, which_obj, output_obj, choices_obj, groups_obj, callback, opts)
  _callback(caller_obj, fuzzy_obj, which_obj, output_obj, choices_obj, groups_obj, callback, opts)
end

local function select(items, opts, on_choice)
  vim.validate({
    items = { items, "table", false },
    on_choice = { on_choice, "function", false },
  })
  opts = opts or {}

  local cells = false
  local choices = (function()
    local metatable = getmetatable(items)
    if metatable ~= nil and metatable["__type"] == "cells" then
      cells = true
      return items
    else
      local choices = {}
      for i, val in pairs(items) do
        table.insert(choices, cell.new(i, tostring(i), val, "key"))
      end
      return choices
    end
  end)()

  local on_choice_wraped = async(vim.schedule_wrap(on_choice))
  local callback = vim.schedule_wrap(function(choice, text)
    if cells then
      on_choice_wraped(text, choice)
    elseif type(choice) == "string" and vim.fn.has_key(items, choice) then
      on_choice_wraped(items[choice], choice)
    elseif type(choice) == "number" and items[choice] ~= nil then
      on_choice_wraped(items[choice], choice)
    else
      print("invalid choice")
    end
  end)
  setup_objs(choices, callback, opts)
end

return { select = select, setup = setup }
