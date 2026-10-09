-- Hyprcachy-owned controller, configured through hl.plugin.window_session.config.
local M = { status = "not started", restoring = false, fullscreen_layouts = {} }
local header = "hyprcachy-window-session-v8\n"
local function quote(s)
	assert(type(s) == "string" and not s:find("\0", 1, true), "Invalid command argument")
	return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end
local function unhex(s)
	assert(#s % 2 == 0 and not s:find("[^0-9a-f]"), "Invalid saved text")
	return (s:gsub("..", function(c)
		return string.char(tonumber(c, 16))
	end))
end
local function validate_command(command)
	assert(type(command) == "table", "Invalid saved command")
	local size = 0
	for _, key in ipairs({ "exe", "cwd" }) do
		local value = command[key]
		assert(type(value) == "string" and value:sub(1, 1) == "/" and not value:find("\0", 1, true), "Invalid command path")
		size = size + #value
	end
	assert(not command.exe:find("=", 1, true), "Unsupported executable path")
	local argv = command.argv
	assert(type(argv) == "table" and #argv >= 1 and #argv <= 256, "Invalid command arguments")
	for key, arg in pairs(argv) do
		assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #argv, "Invalid command argument index")
		assert(type(arg) == "string" and not arg:find("\0", 1, true), "Invalid command argument")
		size = size + #arg + 1
	end
	for i = 1, #argv do
		assert(type(argv[i]) == "string", "Missing command argument")
	end
	assert(argv[1] ~= "" and size <= 65536, "Command is empty or exceeds 64 KiB")
end
local file_worker = hl.plugin.window_session.file_worker == true
local function file_task(operation, ...)
	assert(coroutine.isyieldable(), "File work requires the asynchronous session controller")
	local id = assert(hl.plugin.window_session.file_submit(operation, ...))
	local result = table.pack(coroutine.yield(id))
	assert(result[1], result[2])
	return table.unpack(result, 2, result.n)
end
local function read(file)
	if not file_worker then return file_task("read", file) end
	local f, err, code = io.open(file, "r")
	if not f then
		if code == 2 then
			return nil
		end
		error(err)
	end
	local value = f:read(524289) or ""
	f:close()
	assert(#value <= 524288, "Session file is too large")
	return value
end
local function write(file, text)
	if not file_worker then return file_task("write", file, text) end
	local f = assert(io.open(file .. ".tmp", "w"))
	local ok, err = f:write(text)
	local closed, close_err = f:close()
	assert(ok and closed, err or close_err)
	assert(os.rename(file .. ".tmp", file))
end
local function valid_identity(value)
	if type(value) ~= "string" or #value ~= 129 then return false end
	local session, name = value:match("^([0-9a-f]+)/([0-9a-f]*)$")
	return session ~= nil and #session == 64 and #name == 64
end
local function identity(window)
	local current, restored, managed = hl.plugin.window_session.identity(tostring(window.stable_id))
	assert(type(managed) == "boolean", restored or "Cannot read protocol window identity")
	assert(current == nil or valid_identity(current), "Invalid live protocol identity")
	assert(restored == nil or valid_identity(restored), "Invalid live restore identity")
	return current, restored, managed
end
local function state_dir()
	return (os.getenv("XDG_STATE_HOME") or assert(os.getenv("HOME")) .. "/.local/state") .. "/hyprcachy/window-session"
end
local function fingerprint(window)
	-- Non-cryptographic matching hint, not encryption. Never save plaintext titles.
	local value = 2166136261
	for c in (window.initial_title or window.title or ""):gmatch(".") do
		value = ((value ~ c:byte()) * 16777619) & 0xffffffff
	end
	return string.format("%08x", value)
end
local function class(window)
	return window.initial_class and window.initial_class ~= "" and window.initial_class or window.class
end
local function eligible(window, ignored)
	return window.mapped
		and not window.hidden
		and not window.group
		and window.workspace
		and not window.workspace.special
		and window.monitor
		and class(window)
		and class(window) ~= ""
		and not ignored[class(window)]
end
local function bounds(monitor)
	local w, h = monitor.width, monitor.height
	if monitor.transform % 2 == 1 then
		w, h = h, w
	end
	local r = monitor.reserved
	return monitor.x + r.left,
		monitor.y + r.top,
		math.max(1, w / monitor.scale - r.left - r.right),
		math.max(1, h / monitor.scale - r.top - r.bottom)
end
function M.snapshot(windows, ignored)
	local records, ids, slots = {}, {}, {}
	for _, window in ipairs(windows) do
		if eligible(window, ignored) then
			local x, y, w, h = bounds(window.monitor)
			local current, _, managed = identity(window)
			assert(not managed or current, "Protocol session is inactive; snapshot not saved")
			records[#records + 1] = {
				identity = current,
				class = class(window),
				title = fingerprint(window),
				workspace = window.workspace.config_name,
				monitor = window.monitor.name,
				floating = window.floating,
				pinned = window.pinned or window.pin_fullscreened,
				rx = (window.at.x - x) / w,
				ry = (window.at.y - y) / h,
				rw = window.size.x / w,
				rh = window.size.y / h,
				fullscreen = window.fullscreen,
				client = window.fullscreen_client,
			}
			ids[#ids + 1] = tostring(window.stable_id)
			slots[tostring(window.stable_id)] = tostring(#records)
		end
	end
	table.sort(ids)
	return records, table.concat(ids, ","), slots
end
local function return_tag(tags, origin)
	local prefix, found = "dotfiles-fullscreen-return:", false
	for _, tag in ipairs(tags or {}) do
		if tag:sub(1, #prefix) == prefix then
			local workspace, monitor = tag:sub(#prefix + 1):match("^([0-9a-f]+):([0-9a-f]+)$")
			if found or workspace ~= hex(origin) or not monitor or #monitor % 2 ~= 0
				or unhex(monitor):find("\0", 1, true) then return false end
			found = true
		end
	end
	return found
end
local function validate_fullscreen(origin, layout, records, trees)
	assert(not origin:find("\0", 1, true) and ((origin:match("^%d+$") and tonumber(origin) > 0)
		or origin:match("^name:.+")), "Invalid fullscreen origin")
	assert(hl.plugin.window_session.validate(layout.tree))
	if layout.expected ~= "" then assert(hl.plugin.window_session.validate(layout.expected)) end
	assert(layout.expected == (trees[origin] or ""), "Fullscreen baseline differs from saved workspace")
	assert(next(layout.away), "Missing fullscreen away windows")
	local leaves, home = {}, {}
	for slot in layout.tree:gmatch("L(%d+)") do
		local record = records[tonumber(slot)]
		assert(record and tostring(tonumber(slot)) == slot and not record.floating and not record.pinned
			and not record.tiled_fallback and not leaves[slot], "Invalid fullscreen tree binding")
		if layout.away[slot] then
			assert(record.workspace ~= origin and (record.fullscreen & 2) ~= 0
				and record.ext and return_tag(record.ext.tags, origin), "Invalid fullscreen away binding")
		else
			assert(record.workspace == origin, "Invalid fullscreen home binding")
			home[slot] = true
		end
		leaves[slot] = true
	end
	for slot, value in pairs(layout.away) do
		assert(leaves[slot] and value == true, "Unknown fullscreen away slot")
	end
	for slot in layout.expected:gmatch("L(%d+)") do
		assert(home[slot], "Invalid fullscreen remaining tree")
		home[slot] = nil
	end
	assert(not next(home), "Incomplete fullscreen remaining tree")
end
local function validate_fullscreens(fullscreen, records, trees)
	local members = {}
	for origin, layout in pairs(fullscreen) do
		validate_fullscreen(origin, layout, records, trees)
		for slot in layout.tree:gmatch("L(%d+)") do
			assert(not members[slot], "Window belongs to multiple fullscreen baselines")
			members[slot] = true
		end
	end
end
function M.fullscreen_tree(origin)
	local workspace = hl.get_workspace(origin)
	if not workspace or #hl.get_windows({ workspace = workspace, mapped = true, floating = false }) == 0 then
		return ""
	end
	return hl.plugin.window_session.capture(workspace.id)
end
function M.capture_fullscreen(records, slots, trees, windows)
	local saved, live = {}, {}
	for _, window in ipairs(windows) do live[tostring(window.stable_id)] = true end
	for origin, layout in pairs(M.fullscreen_layouts) do
		if layout.tree and M.fullscreen_tree(origin) ~= layout.expected then layout.tree = nil end
		if layout.tree then
			local complete = true
			for id in layout.tree:gmatch("L(%d+)") do
				if live[id] and not slots[id] then complete = false end -- Never silently drop ignored live members.
			end
			if complete then
				local candidate = {
					tree = assert(hl.plugin.window_session.remap(layout.tree, slots)),
					expected = layout.expected == "" and "" or assert(hl.plugin.window_session.remap(layout.expected, slots)),
					away = {},
				}
				for id in pairs(layout.away) do
					if slots[id] then candidate.away[slots[id]] = true end
				end
				-- Pending exits/ignored members cannot form a restorable baseline; ordinary state still saves.
				if pcall(validate_fullscreen, origin, candidate, records, trees) then saved[origin] = candidate end
			end
		end
	end
	if not pcall(validate_fullscreens, saved, records, trees) then return {} end
	return saved
end
function M.restore_fullscreen(saved, bindings, live)
	M.fullscreen_layouts = {}
	local failed = {}
	for origin, layout in pairs(saved) do
		local complete, away = true, {}
		for slot in layout.tree:gmatch("L(%d+)") do
			local id = bindings[slot]
			local window = id and live[id]
			if not window or not window.mapped or window.hidden or window.floating or window.group
				or window.pinned or window.pin_fullscreened or not window.workspace or window.workspace.special then
				complete = false
			elseif layout.away[slot] then
				if window.workspace.config_name == origin or (window.fullscreen & 2) == 0
					or not return_tag(window.tags, origin) then complete = false end
				away[id] = true
			elseif window.workspace.config_name ~= origin then
				complete = false
			end
		end
		if complete then
			local expected = layout.expected == "" and "" or assert(hl.plugin.window_session.remap(layout.expected, bindings))
			if M.fullscreen_tree(origin) == expected then
				M.fullscreen_layouts[origin] = {
					tree = assert(hl.plugin.window_session.remap(layout.tree, bindings)), expected = expected, away = away,
				}
			else complete = false end
		end
		if not complete then failed[#failed + 1] = origin end
	end
	return failed
end
function M.capture(ignored, launch, desktops)
	local windows = hl.get_windows()
	local records, topology, slots = M.snapshot(windows, ignored)
	local trees, seen, commands = {}, {}, {}
	M.capture_errors = {}
	for _, window in ipairs(windows) do
		local slot, app = slots[tostring(window.stable_id)], class(window)
		if slot then
			local state, err = hl.plugin.window_session.capture_state(tostring(window.stable_id))
			if state then
				local r = records[tonumber(slot)]
				r.state, r.ext = state.data, state
				if r.floating and state.normal then
					r.rx, r.ry, r.rw, r.rh = table.unpack(state.normal)
				end
			else
				M.capture_errors[#M.capture_errors + 1] = app .. " state: " .. tostring(err)
			end
		end
		if slot and launch[app] == nil and not desktops[app:lower()] then
			commands[#commands + 1] = { slot = slot, pid = window.pid, id = tostring(window.stable_id), app = app }
		end
		local ws = window.workspace
		if eligible(window, ignored) and not window.floating and not seen[ws.config_name] then
			seen[ws.config_name] = true
			local tree, err = hl.plugin.window_session.capture(ws.id)
			if tree then
				local complete = true
				tree = tree:gsub("L(%d+)", function(id)
					if not slots[id] then
						complete = false
						return "L" .. id
					end
					return "L" .. slots[id]
				end)
				if complete then
					trees[ws.config_name] = tree
				else
					err = "Tree includes ignored/hidden windows"
				end
			end
			if err then
				M.capture_errors[#M.capture_errors + 1] = ws.config_name .. ": " .. err
			end
		end
	end
	local fullscreen = M.capture_fullscreen(records, slots, trees, windows)
	if #commands > 0 then
		-- Capture live layout atomically before yielding; the worker sees only copied PID requests.
		local results = file_task("commands", commands)
		local live = {}
		for _, window in ipairs(hl.get_windows()) do live[tostring(window.stable_id)] = window.pid end
		for i, request in ipairs(commands) do
			assert(live[request.id] == request.pid, "Window closed during command capture; snapshot not saved")
			records[tonumber(request.slot)].command = results[i].command
			if results[i].error then
				M.capture_errors[#M.capture_errors + 1] = request.app .. " command: " .. results[i].error
			end
		end
	end
	return records, topology, trees, windows, fullscreen
end
function M.encode(records, trees, fullscreen)
	if not file_worker then return file_task("encode", records, trees, fullscreen) end
	validate_fullscreens(fullscreen or {}, records, trees or {})
	local lines, identities = { header }, {}
	for slot, r in ipairs(records) do
		lines[#lines + 1] = table.concat({
			hex(r.class),
			r.title,
			hex(r.workspace),
			hex(r.monitor),
			r.floating and "1" or "0",
			r.rx,
			r.ry,
			r.rw,
			r.rh,
			r.fullscreen,
			r.client,
			r.pinned and "1" or "0",
		}, "\t") .. "\n"
		assert(r.state, "Window state capture failed: " .. r.class .. "; snapshot not saved")
		lines[#lines + 1] = "S\t" .. slot .. "\t" .. hex(r.state) .. "\n"
		if r.identity then
			assert(valid_identity(r.identity) and not identities[r.identity], "Duplicate/invalid protocol identity")
			identities[r.identity] = true
			lines[#lines + 1] = "I\t" .. slot .. "\t" .. r.identity .. "\n"
		end
		if r.command then
			validate_command(r.command)
			local fields = { "C", tostring(slot), hex(r.command.exe), hex(r.command.cwd) }
			for _, arg in ipairs(r.command.argv) do
				fields[#fields + 1] = hex(arg)
			end
			lines[#lines + 1] = table.concat(fields, "\t") .. "\n"
		end
	end
	local names = {}
	for name in pairs(trees or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		lines[#lines + 1] = "T\t" .. hex(name) .. "\t" .. trees[name] .. "\n"
	end
	names = {}
	for origin in pairs(fullscreen or {}) do names[#names + 1] = origin end
	table.sort(names)
	for _, origin in ipairs(names) do
		local layout, away = fullscreen[origin], {}
		for slot in pairs(layout.away) do away[#away + 1] = slot end
		table.sort(away)
		lines[#lines + 1] = table.concat({
			"F", hex(origin), layout.tree, layout.expected, table.concat(away, ","),
		}, "\t") .. "\n"
	end
	local text = table.concat(lines)
	assert(#text <= 524288, "Session snapshot exceeds size limit")
	return text
end
function M.decode(text)
	if not file_worker then return file_task("decode", text) end
	if text == nil then
		return {}, {}, {}
	end
	assert(
		text:sub(1, #header) == header,
		"Incompatible session snapshot; leaving it untouched. Start with a fresh snapshot."
	)
	local records, trees, fullscreen, identities = {}, {}, {}, {}
	for line in text:sub(#header + 1):gmatch("[^\n]+") do
		local f = {}
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do
			f[#f + 1] = field
		end
		if f[1] == "I" then
			assert(#f == 3 and f[2]:match("^[1-9]%d*$") and valid_identity(f[3]), "Invalid protocol identity record")
			local record = records[tonumber(f[2])]
			assert(record and not record.identity and not identities[f[3]], "Duplicate/unknown protocol window")
			record.identity, identities[f[3]] = f[3], true
		elseif f[1] == "C" then
			assert(#f >= 5 and #f <= 260 and f[2]:match("^[1-9]%d*$"), "Invalid saved command record")
			local record = records[tonumber(f[2])]
			assert(record and not record.command, "Duplicate/unknown command window")
			local command = { exe = unhex(f[3]), cwd = unhex(f[4]), argv = {} }
			for i = 5, #f do
				command.argv[#command.argv + 1] = unhex(f[i])
			end
			validate_command(command)
			record.command = command
		elseif f[1] == "S" then
			assert(#f == 3 and f[2]:match("^[1-9]%d*$"), "Invalid saved window state")
			local record = records[tonumber(f[2])]
			assert(record and not record.state, "Duplicate/unknown state window")
			record.state = unhex(f[3])
			record.ext = assert(hl.plugin.window_session.inspect_state(record.state))
		elseif f[1] == "F" then
			assert(#f == 5 and #f[3] <= 32768 and #f[4] <= 32768, "Invalid fullscreen layout record")
			local origin, away = unhex(f[2]), {}
			assert(not fullscreen[origin], "Duplicate fullscreen origin")
			for slot in (f[5] .. ","):gmatch("([^,]*),") do
				assert(slot:match("^[1-9]%d*$") and not away[slot], "Invalid fullscreen away slot")
				away[slot] = true
			end
			fullscreen[origin] = { tree = f[3], expected = f[4], away = away }
		elseif f[1] == "T" then
			assert(#f == 3 and #f[3] <= 32768 and not f[3]:find("[^LHV0-9.e+%- ]"), "Invalid saved tree")
			local name = unhex(f[2])
			assert(name ~= "" and not trees[name], "Duplicate/invalid tree workspace")
			trees[name] = f[3]
		else
			assert(
				#f == 12
					and f[2]:match("^%x%x%x%x%x%x%x%x$")
					and (f[5] == "0" or f[5] == "1")
					and (f[12] == "0" or f[12] == "1"),
				"Invalid saved window"
			)
			local r = {
				class = unhex(f[1]),
				title = f[2],
				workspace = unhex(f[3]),
				monitor = unhex(f[4]),
				floating = f[5] == "1",
				pinned = f[12] == "1",
			}
			assert(not r.pinned or r.floating, "Pinned windows must be floating")
			assert(r.class ~= "" and r.monitor ~= "", "Invalid saved identity")
			assert(
				(r.workspace:match("^%d+$") and tonumber(r.workspace) > 0) or r.workspace:match("^name:.+"),
				"Invalid saved workspace"
			)
			for i, key in ipairs({ "rx", "ry", "rw", "rh", "fullscreen", "client" }) do
				local n = tonumber(f[i + 5])
				assert(n and n == n and math.abs(n) < math.huge, "Invalid saved number")
				r[key] = n
			end
			assert(
				r.rw > 0
					and r.rh > 0
					and r.fullscreen % 1 == 0
					and r.fullscreen >= 0
					and r.fullscreen <= 3
					and r.client % 1 == 0
					and r.client >= 0
					and r.client <= 3,
				"Invalid saved geometry/state"
			)
			r.slot = tostring(#records + 1)
			records[#records + 1] = r
		end
	end
	for name, tree in pairs(trees) do
		local seen = {}
		for slot in tree:gmatch("L(%d+)") do
			local record = records[tonumber(slot)]
			assert(
				record and record.slot == slot and record.workspace == name and not record.floating and not seen[slot],
				"Invalid saved tree window binding"
			)
			seen[slot] = true
		end
	end
	for _, record in ipairs(records) do
		assert(record.state, "Missing saved window state")
		if record.floating and record.fullscreen ~= 0 and not record.ext.normal then
			-- Preserve fullscreen, but use tiling underneath when the old floating position is unknown.
			record.floating, record.pinned, record.tiled_fallback = false, false, true
		end
	end
	validate_fullscreens(fullscreen, records, trees)
	return records, trees, fullscreen
end
function M.pair(records, windows, used, fallback, in_place)
	local pairs, matched, identities = {}, {}, {}
	for _, window in ipairs(windows) do
		local current, restored, managed = identity(window)
		-- Startup uses restore lineage. Reload recovery can also refer to a
		-- checkpoint taken under the current capture identity.
		identities[window] = { key = restored or current, current = in_place and current or nil, managed = managed }
	end
	for pass = 1, fallback and 3 or 2 do
		for i, record in ipairs(records) do
			if not matched[i] then
				for _, window in ipairs(windows) do
					if
						not used[tostring(window.stable_id)]
						and ((pass == 1 and record.identity
								and (identities[window].key == record.identity or identities[window].current == record.identity))
							or (pass > 1 and not record.identity and not identities[window].managed
								and class(window) == record.class
								and (pass == 3 or fingerprint(window) == record.title)))
					then
						pairs[#pairs + 1] = { record, window }
						used[tostring(window.stable_id)], matched[i] = true, true
						break
					end
				end
			end
		end
	end
	local remaining = {}
	for i, record in ipairs(records) do
		if not matched[i] then
			remaining[#remaining + 1] = record
		end
	end
	return pairs, remaining
end
local function dispatch(action)
	-- Dispatcher objects require hl.dispatch on the main Lua state, not this coroutine.
	local ok, result = coroutine.yield("dispatch", action)
	assert(ok, result)
	assert(result and result.ok, result and result.error or "Hyprland refused restoration")
end
function M.place(r, window)
	local monitor = hl.get_monitor(r.monitor) or hl.get_active_monitor() or hl.get_monitors()[1]
	assert(monitor, "No monitor available")
	local dsp = hl.dsp
	assert(hl.plugin.window_session.apply_state(tostring(window.stable_id), r.state, true))
	if window.fullscreen ~= 0 or window.fullscreen_client ~= 0 then
		dispatch(dsp.window.fullscreen_state({ window = window, internal = 0, client = 0, action = "set" }))
	end
	-- Unpin before workspace/floating changes; Hyprland only pins floating windows.
	if window.pinned then
		dispatch(dsp.window.pin({ window = window, action = "disable" }))
	end
	dispatch(dsp.window.move({ window = window, workspace = r.workspace, follow = false }))
	local workspace = hl.get_workspace(r.workspace)
	if workspace and (not workspace.monitor or workspace.monitor.name ~= monitor.name) then
		dispatch(dsp.workspace.move({ workspace = workspace, monitor = monitor }))
	end
	dispatch(dsp.window.float({ window = window, action = r.floating and "enable" or "disable" }))
	if r.floating then
		local x, y, w, h = bounds(monitor)
		local width, height =
			math.max(1, math.floor(math.min(r.rw, 1) * w)), math.max(1, math.floor(math.min(r.rh, 1) * h))
		dispatch(dsp.window.resize({ window = window, x = width, y = height, relative = false }))
		dispatch(dsp.window.move({
			window = window,
			x = x + math.max(0, math.min(r.rx * w, w - width)),
			y = y + math.max(0, math.min(r.ry * h, h - height)),
			relative = false,
		}))
	end
	assert(hl.plugin.window_session.apply_state(tostring(window.stable_id), r.state, false))
	if r.pinned then
		dispatch(dsp.window.pin({ window = window, action = "enable" }))
	end
end
local function roots(home_variable, fallback, dirs_variable, dirs_default, suffix)
	local result = { (os.getenv(home_variable) or os.getenv("HOME") .. fallback) .. suffix }
	for dir in (os.getenv(dirs_variable) or dirs_default):gmatch("[^:]+") do
		result[#result + 1] = dir .. suffix
	end
	return result
end
function M.desktops(autostart)
	if not file_worker then return file_task("desktops", autostart) end
	local dirs = autostart and roots("XDG_CONFIG_HOME", "/.config", "XDG_CONFIG_DIRS", "/etc/xdg", "/autostart")
		or roots("XDG_DATA_HOME", "/.local/share", "XDG_DATA_DIRS", "/usr/local/share:/usr/share", "/applications")
	local matches, seen = {}, {}
	-- Native filesystem calls avoid racing Hyprland\'s child-process reaper.
	for _, dir in ipairs(dirs) do
		local files = assert(hl.plugin.window_session.desktop_files(dir))
		for _, file in ipairs(files) do
			local id = file:sub(#dir + 2):gsub("/", "-")
			if not seen[id] then
				seen[id] = true
				local ok, text = pcall(read, file)
				local fields, active = {}, false
				for line in (ok and text or ""):gmatch("[^\r\n]+") do
					if line:match("^%[") then
						active = line == "[Desktop Entry]"
					end
					if active then
						local key, value = line:match("^([%w-]+)=(.*)$")
						if key then
							fields[key] = value
						end
					end
				end
				if
					fields.Type == "Application"
					and fields.Hidden ~= "true"
					and (not autostart or fields["X-GNOME-Autostart-enabled"] ~= "false")
				then
					for _, key in ipairs({ id:sub(1, -9):lower(), (fields.StartupWMClass or ""):lower() }) do
						if key ~= "" then
							if matches[key] == nil or matches[key] == id or autostart then
								matches[key] = id
							else
								matches[key] = false
							end
						end
					end
				end
			end
		end
	end
	return matches
end
function M.command(app, overrides, desktops, captured)
	local value = overrides[app]
	if value == false then
		return nil
	end
	if value == nil then
		value = desktops[app:lower()]
	end
	local args
	if value then
		args = type(value) == "string" and { value } or value
	elseif captured then
		validate_command(captured)
		-- env preserves argv[0] and cwd without evaluating captured text as shell code.
		args = { "/usr/bin/env", "--chdir=" .. captured.cwd, "--argv0=" .. captured.argv[1], "--", captured.exe }
		for i = 2, #captured.argv do
			args[#args + 1] = captured.argv[i]
		end
	else
		return nil
	end
	local command = { "uwsm app -t service --" }
	for _, arg in ipairs(args) do
		if not value then
			-- systemd services expand dollars after shell parsing; keep captured bytes literal.
			arg = arg:gsub("%$", "$$")
		end
		command[#command + 1] = quote(arg)
	end
	return table.concat(command, " ")
end
function M.validate_options(options)
	assert(type(options) == "table", "Session options must be a table")
	local timing = { launch_delay = 20, restore_timeout = 80, stability_delay = 15 }
	for key in pairs(options) do
		assert(key == "launch" or key == "ignore" or key == "enabled" or timing[key] ~= nil, "Unknown session option")
	end
	for key, default in pairs(timing) do
		local value = options[key]
		if value == nil then
			value = default
		end
		assert(
			type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0,
			key .. " must be a finite non-negative whole number of seconds"
		)
		timing[key] = value
	end
	assert(timing.restore_timeout > timing.launch_delay, "restore_timeout must exceed launch_delay")
	assert(options.enabled == nil or type(options.enabled) == "boolean", "enabled must be boolean")
	local launch, ignore = options.launch or {}, options.ignore or {}
	assert(type(launch) == "table" and type(ignore) == "table", "launch and ignore must be tables")
	for app, value in pairs(launch) do
		assert(type(app) == "string", "Launch keys must be window classes")
		if type(value) == "string" then
			assert(value:match("^[%w_.-]+%.desktop$"), "Expected desktop entry ID")
		elseif type(value) == "table" then
			assert(#value > 0, "Empty launch command")
			for key, arg in pairs(value) do
				assert(
					type(key) == "number"
						and key % 1 == 0
						and key >= 1
						and key <= #value
						and type(arg) == "string"
						and arg ~= ""
						and not arg:find("\0", 1, true),
					"Invalid launch argument"
				)
			end
		else
			assert(value == false, "Launch override must be a desktop ID, argv table, or false")
		end
	end
	local ignored = {}
	for _, app in ipairs(ignore) do
		assert(type(app) == "string", "Invalid ignore entry")
		ignored[app] = true
	end
	return launch, ignored, timing
end
function M.configure(options)
	assert(not hyprcachy_window_session, "Call hl.plugin.window_session.config once per configuration reload")
	M.validate_options(options)
	hyprcachy_window_session = M
	M.status = "disabled (opt-in)"
	if options.enabled ~= true then
		return
	end
	assert(type(hl.plugin.window_session.file_submit) == "function", "Restart Hyprland to load the file worker")
	-- Publish from the startup config reload, before READY/exec-once, not a deferred timer.
	assert(hl.plugin.window_session.protocol_start(state_dir(), options.ignore or {}))
	M.status, M.restoring = "preparing session files", true
	M.task = coroutine.create(function()
		local c = M.start(options)
		for _, name in ipairs({ "save", "cycle", "restore_cycle" }) do
			local action = M[name]
			M[name] = function()
				assert(not M.task and not M.shutting_down, "Session operation is busy; retry when idle")
				if name == "save" then assert(not c.cycling, "Wait for the cycle to finish")
				elseif name == "cycle" then assert(c.finished and not c.stopping and not c.cycling, "Wait for recording before cycling")
				else assert(c.stopping or (c.finished and not c.cycling), "A restore or close operation is still active") end
				local previous, label = M.status, "preparing " .. name
				M.status, M.operation = label, name
				M.task = coroutine.create(function()
					action()
					if M.status == label then M.status = previous end
				end)
				return label
			end
		end
	end)
	local ticks = 0
	local function advance()
		if M.shutting_down then return end
		ticks = ticks + 1
		local c = M.controller
		if not M.task then
			if not c or c.stopping or ticks < 50 then return end
			ticks = 0
			M.task = coroutine.create(c.tick)
		end
		local result
		if M.waiting then
			local ready = table.pack(hl.plugin.window_session.file_poll(M.waiting))
			assert(ready[1] ~= nil, ready[2])
			if not ready[1] then return end
			M.waiting = nil
			result = table.pack(coroutine.resume(M.task, table.unpack(ready, 2, ready.n)))
		else
			result = table.pack(coroutine.resume(M.task))
		end
		while result[1] and result[2] == "dispatch" do
			result = table.pack(coroutine.resume(M.task, pcall(hl.dispatch, result[3])))
		end
		assert(result[1], result[2])
		if coroutine.status(M.task) == "dead" then M.task, M.operation = nil, nil
		else M.waiting = assert(result[2], "Session coroutine yielded without a file task") end
	end
	-- Resume completed file work and dispatch requested actions; no clock-budget retries or blocking waits.
	-- Register callbacks on Hyprland's main Lua state, never from a coroutine.
	M.timer = hl.timer(function()
		local ok, message = pcall(advance)
		if not ok then
			M.task, M.waiting = nil, nil
			if M.controller then M.controller.fail(message)
			else M.status = "stopped: " .. tostring(message) end
			M.operation = nil
		end
	end, { timeout = 20, type = "repeat" })
	hl.on("hyprland.shutdown", function()
		M.shutting_down = true
		if M.controller then M.controller.stopping = true end
	end)
end

function M.start(options)
	if M.controller then
		return M.controller
	end
	options = options or {}
	local launch, ignored, timing = M.validate_options(options)
	if options.enabled ~= true then
		M.status = "disabled (opt-in)"
		return nil
	end
	assert(hl.plugin and hl.plugin.window_session, "Native window-session plugin is not loaded")
	assert(
		type(hl.plugin.window_session.remap) == "function"
			and type(hl.plugin.window_session.capture_state) == "function"
			and type(hl.plugin.window_session.inspect_state) == "function"
			and type(hl.plugin.window_session.apply_state) == "function"
			and type(hl.plugin.window_session.raise_state) == "function"
			and type(hl.plugin.window_session.identity) == "function",
		"Restart Hyprland to load the updated window-session plugin"
	)
	local preserve = hl.get_config("dwindle.preserve_split")
	assert(preserve == true or preserve == 1, "Enable dwindle.preserve_split for exact restoration")
	local runtime = assert(os.getenv("XDG_RUNTIME_DIR"))
	local signature = assert(os.getenv("HYPRLAND_INSTANCE_SIGNATURE"))
	local dir = state_dir()
	-- A private directory protects all snapshot/temp files, irrespective of umask.
	local file, marker = dir .. "/current.tsv", runtime .. "/hyprcachy-window-session-" .. hex(signature) .. ".native"
	local saved = read(file)
	if saved and saved:match("^hyprcachy%-window%-session%-v%d+\n") and saved:sub(1, #header) ~= header then
		M.last_archive = assert(file_task("archive", file))
		saved = nil -- Preserve the old bytes, but never interpret a different format.
	end
	local cycle_file = dir .. "/cycle.tsv"
	local trees
	local c = { desktops = M.desktops(false) }
	local autostarts = M.desktops(true)
	-- Explicit replay may reopen login opt-outs; ignored windows remain excluded.
	local cycle_launch = {}
	for app, value in pairs(launch) do
		if value ~= false then
			cycle_launch[app] = value
		end
	end
	local function issue(label)
		c.issues[label] = (c.issues[label] or 0) + 1
	end
	local function report(text, incomplete)
		M.last_restore, c.reported = text, true
		print("Window session: " .. text)
		local ok, err = pcall(function()
			-- Use the desktop's notification server (Quickshell), not Hyprland's overlay.
			hl.exec_cmd(
				"/usr/bin/notify-send --app-name='Window Session' --urgency=normal --expire-time="
					.. (incomplete and 12000 or 5000)
					.. " -- "
					.. quote(incomplete and "Session restore incomplete" or "Session restored")
					.. " "
					.. quote(text)
			)
		end)
		if not ok then
			print("Window session: notification failed: " .. tostring(err))
		end
	end
	local function begin_restore(text, manual)
		local records, layout, fullscreen = M.decode(text)
		for _, tree in pairs(layout) do
			local valid, err = hl.plugin.window_session.validate(tree)
			assert(valid, err)
		end
		local pending = {}
		for _, record in ipairs(records) do
			if not ignored[record.class] then
				pending[#pending + 1] = record
			end
		end
		M.restoring = true -- Window rules must not relocate windows while replay owns placement.
		M.fullscreen_layouts = {}
		c.fullscreen, c.records, c.reloading = fullscreen, pending, false
		c.total, c.issues, c.reported = #pending, {}, false
		for _, record in ipairs(pending) do
			if record.tiled_fallback then
				issue("tiled fullscreen fallback: " .. record.class)
				local tree = layout[record.workspace]
				if tree then
					-- Keep the saved subtree; the newly tiled window needs its own leaf.
					tree = "H1 " .. tree .. " L" .. record.slot
					local valid = hl.plugin.window_session.validate(tree)
					layout[record.workspace] = valid and tree or nil
					if not valid then
						issue("fallback exceeds tree limits: " .. record.workspace)
					end
				end
			end
			if not record.floating and not layout[record.workspace] then
				c.issues["no saved layout for workspace " .. record.workspace] = 1
			end
		end
		trees = layout
		c.launch = manual and cycle_launch or launch
		c.seconds, c.changed = 0, 0
		c.pending, c.used, c.attempted, c.matches = pending, {}, {}, {}
		c.stopping, c.finished = false, false
		c.topology, c.last, c.autostarts, c.closing = nil, nil, nil, nil
	end
	begin_restore(saved)
	c.autostarts = autostarts
	if read(marker) then
		c.pending, trees, c.total, c.reloading = {}, {}, 0, true
	else
		if saved then
			write(dir .. "/previous.tsv", saved)
		end
		write(marker, "started\n") -- Config reloads must not launch/restore twice.
	end
	M.controller = c
	if M.last_archive then
		report("Incompatible snapshot archived at " .. M.last_archive
			.. ". No saved layout was restored; starting fresh recording.", true)
	end
	function M.save()
		assert(not c.cycling, "Session snapshot is protected: " .. M.status)
		local current, _, layout, _, fullscreen = M.capture(ignored, launch, c.desktops)
		write(file, M.encode(current, layout, fullscreen))
	end
	function M.cycle()
		assert(c.finished and not c.stopping and not c.cycling, "Wait for recording before cycling: " .. M.status)
		local current, _, layout, windows, fullscreen = M.capture(ignored, cycle_launch, c.desktops)
		assert(#M.capture_errors == 0, "Cannot safely cycle: " .. table.concat(M.capture_errors, "; "))
		for _, record in ipairs(current) do
			assert(M.command(record.class, cycle_launch, c.desktops, record.command), "No launch recipe for " .. record.class)
		end
		local closing, actions = {}, {}
		for _, window in ipairs(windows) do
			if eligible(window, ignored) then
				closing[tostring(window.stable_id)] = true
				actions[#actions + 1] = hl.dsp.window.close({ window = window })
			end
		end
		assert(#actions > 0, "No session-managed windows to close")
		local text = M.encode(current, layout, fullscreen)
		-- Keep a separate recovery copy: config reloads and later recording cannot overwrite it.
		write(cycle_file, text)
		write(file, text)
		begin_restore(text, true)
		c.cycling, c.closing = true, closing
		-- Login autostarts do not run again for an explicit in-session replay.
		c.autostarts = {}
		M.status = "closing: waiting up to 60 seconds; recovery snapshot: " .. cycle_file
		for _, action in ipairs(actions) do
			local ok, err = pcall(dispatch, action)
			if not ok then
				c.stopping = true
				M.status = "stopped: close failed: " .. tostring(err) .. "; use restore_cycle()"
				report("Cycle stopped: window close failed; snapshot kept. See status; use restore_cycle().", true)
				error(M.status)
			end
		end
		return M.status
	end
	function M.restore_cycle()
		assert(c.stopping or (c.finished and not c.cycling), "A restore or close operation is still active")
		local text = assert(read(cycle_file), "No cycle recovery snapshot exists")
		begin_restore(text, true)
		c.cycling, c.autostarts = true, {}
		M.status = "restoring cycle snapshot"
		return M.status
	end
	function c.tick()
		if c.stopping then
			return
		end
		c.seconds = c.seconds + 1
		if c.closing then
			local remaining = 0
			for _, window in ipairs(hl.get_windows()) do
				if c.closing[tostring(window.stable_id)] then
					remaining = remaining + 1
				end
			end
			if remaining > 0 then
				if c.seconds >= 60 then
					c.stopping = true
					M.status = "stopped: close timed out; recording paused; use restore_cycle()"
					report("Cycle stopped: " .. remaining .. " windows did not close; snapshot kept. Use restore_cycle().", true)
				else
					M.status = "closing: " .. remaining .. " windows remaining"
				end
				return
			end
			c.closing, c.seconds, c.changed = nil, 0, 0
		end
		if not c.finished and (#c.pending > 0 or next(c.matches)) and c.seconds <= timing.restore_timeout then
			local windows, live = {}, {}
			for _, window in ipairs(hl.get_windows()) do
				live[tostring(window.stable_id)] = true
				if eligible(window, ignored) then
					windows[#windows + 1] = window
				end
			end
			-- Loading windows may be replaced several times before the final client appears.
			for slot, match in pairs(c.matches) do
				if not live[match.id] then
					c.pending[#c.pending + 1] = match.record
					c.matches[slot], c.used[match.id] = nil, nil
				end
			end
			local pairs
			pairs, c.pending = M.pair(c.pending, windows, c.used, c.seconds >= timing.launch_delay)
			for _, pair in ipairs(pairs) do
				local ok, err = pcall(M.place, pair[1], pair[2])
				if ok then
					c.matches[pair[1].slot] = { id = tostring(pair[2].stable_id), record = pair[1] }
					-- An observed app is already starting; do not launch another copy during a window gap.
					c.attempted[pair[1].class] = true
				end
				if not ok then
					issue("placement failed: " .. pair[1].class .. ": " .. tostring(err))
					print("Window session: placement failed: " .. tostring(err))
				end
			end
			if c.seconds >= timing.launch_delay and #c.pending > 0 then
				assert(c.autostarts, "Autostart discovery has not completed")
				for _, record in ipairs(c.pending) do
					local app = record.class
					if not c.attempted[app] then
						c.attempted[app] = true
						local exists = c.autostarts[app:lower()]
						for _, window in ipairs(windows) do
							if class(window) == app then
								exists = true
							end
						end
						-- ponytail: one launch per app, not per saved window. Let apps restore their own sessions.
						local command = not exists and not ignored[app] and M.command(app, c.launch, c.desktops, record.command)
						if command then
							hl.exec_cmd(command)
						end
					end
				end
			end
			M.status = "restoring: " .. #c.pending .. " unmatched; " .. (timing.restore_timeout - c.seconds) .. "s remaining"
			return
		end
		if not c.finished then
			c.finished = true
			-- Re-resolve windows: a matched window may have closed during startup.
			local live, bindings = {}, {}
			for _, window in ipairs(hl.get_windows()) do
				live[tostring(window.stable_id)] = window
			end
			for slot, match in pairs(c.matches) do
				if live[match.id] then
					bindings[slot] = match.id
				else
					issue("missing: " .. match.record.class)
				end
			end
			for name, tree in pairs(trees) do
				local ws = hl.get_workspace(name)
				if ws then
					local restored, err = hl.plugin.window_session.restore(ws.id, tree, bindings)
					if not restored then
						issue("layout failed: workspace " .. name .. ": " .. tostring(err))
						print("Window session: tree not restored: " .. tostring(err))
					end
				else
					issue("missing workspace: " .. name)
				end
			end
			-- Fullscreen is applied only after the underlying tiled tree is restored.
			for _, match in pairs(c.matches) do
				local window, r = live[match.id], match.record
				if window and (r.fullscreen ~= 0 or r.client ~= 0) then
					local ok, err = pcall(
						dispatch,
						hl.dsp.window.fullscreen_state({
							window = window,
							internal = r.fullscreen,
							client = r.client,
							action = "set",
						})
					)
					if not ok then
						issue("fullscreen failed: " .. r.class .. ": " .. tostring(err))
						print("Window session: fullscreen failed: " .. tostring(err))
					end
				end
			end
			local floating = {}
			for _, match in pairs(c.matches) do
				if live[match.id] and match.record.floating then
					floating[#floating + 1] = match
				end
			end
			table.sort(floating, function(a, b) return a.record.ext.z < b.record.ext.z end)
			for _, match in ipairs(floating) do
				local ok, err = hl.plugin.window_session.raise_state(match.id, match.record.state)
				if not ok then
					issue("stacking failed: " .. match.record.class .. ": " .. tostring(err))
					print("Window session: stacking failed: " .. tostring(err))
				end
			end
			for _, record in ipairs(c.pending) do
				issue("unmatched: " .. record.class)
			end
			if c.reloading then
				-- Recover checkpoint metadata without replaying placement or fullscreen on config reload.
				local groups = {}
				for _, record in ipairs(c.records) do
					groups[record.workspace] = groups[record.workspace] or {}
					table.insert(groups[record.workspace], record)
				end
				for name, records in pairs(groups) do
					local windows = {}
					for _, window in pairs(live) do
						if eligible(window, ignored) and window.workspace.config_name == name then windows[#windows + 1] = window end
					end
					table.sort(windows, function(a, b) return a.stable_id < b.stable_id end)
					local matched = M.pair(records, windows, {}, true, true)
					for _, pair in ipairs(matched) do bindings[pair[1].slot] = tostring(pair[2].stable_id) end
				end
			end
			for _, origin in ipairs(M.restore_fullscreen(c.fullscreen, bindings, live)) do
				issue("fullscreen baseline skipped: " .. origin)
				print("Window session: fullscreen baseline could not be verified: " .. origin)
			end
			c.cycling, M.restoring = false, false
			if c.total > 0 then
				local details = {}
				for label, count in pairs(c.issues) do
					details[#details + 1] = label .. (count > 1 and " (" .. count .. ")" or "")
				end
				table.sort(details)
				if #details == 0 then
					report("Restored all " .. c.total .. " windows and saved layout/state.", false)
				else
					report("Restore incomplete: " .. table.concat(details, "; "), true)
				end
			end
		end
		if c.seconds % 5 ~= 0 then
			return
		end
		local current, topology, layout, _, fullscreen = M.capture(ignored, launch, c.desktops)
		if topology ~= c.topology then
			c.topology, c.changed = topology, c.seconds
		end
		local text = M.encode(current, layout, fullscreen)
		-- ponytail: topology debounce, not an atomic logout snapshot. Explicit save supports empty desktops.
		if #current > 0 and c.seconds - c.changed >= timing.stability_delay and text ~= c.last then
			write(file, text)
			c.last = text
		end
		M.status = "recording: " .. #current .. " windows"
		if #M.capture_errors > 0 then
			M.status = M.status .. "; skipped: " .. table.concat(M.capture_errors, "; ")
		end
	end
	c.fail = function(err)
		c.stopping = true
		M.status = "stopped: " .. tostring(err)
		print("Window session: " .. M.status)
		if M.operation then
			report("Session " .. M.operation .. " failed. Check status before closing applications or logging out.", true)
		elseif c.total > 0 and not c.reported then
			report("Restore stopped by an error; not all state was restored. Check status and Hyprland logs.", true)
		end
	end
	M.status = "started"
	return c
end

-- Executed only in the worker's private Lua state, with no compositor APIs installed.
function M.file_work(operation, ...)
	assert(file_worker, "File operations belong to the worker")
	if operation == "read" then return read(...)
	elseif operation == "write" then return write(...)
	elseif operation == "archive" then return assert(hl.plugin.window_session.archive_snapshot(...))
	elseif operation == "desktops" then return M.desktops(...)
	elseif operation == "encode" then return M.encode(...)
	elseif operation == "decode" then return M.decode(...)
	elseif operation == "commands" then
		local results = {}
		for i, request in ipairs((...)) do
			local command, err = hl.plugin.window_session.process_command(request.pid)
			results[i] = { command = command, error = err }
		end
		return results
	end
	error("Unknown file operation")
end

return M
