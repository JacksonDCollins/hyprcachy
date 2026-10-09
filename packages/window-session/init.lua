-- Call once from the startup configuration; native loading triggers a second config pass.
return function(options)
	assert(type(options) == "table", "Expected window-session configuration table")
	hl.plugin.load("/usr/lib/hyprcachy/window-session/window-session.so")
	if hl.plugin.window_session and hl.plugin.window_session.config then
		hl.plugin.window_session.config(options)
	end
end
