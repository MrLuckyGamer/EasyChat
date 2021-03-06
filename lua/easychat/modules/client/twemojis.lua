local DISCORD_LOOKUP_TABLE_URL = "https://raw.githubusercontent.com/Cynosphere/emojis.json/master/emojis.json"

local FOLDER = "easychat/emojis/twemojis"
file.CreateDir(FOLDER, "DATA")

local UNCACHED = false
local PROCESSING = true

local lookup
do
	local function generate_lookup_table(data)
		lookup = {}

		for line in data:gmatch("[^\r\n]+") do
			local tbl = lookup
			for str in line:gmatch("[a-f0-9][a-f0-9]+") do
				local num = assert(tonumber(str, 16))
				local t = tbl[num] or {}
				tbl[num] = t
				tbl = t
			end
		end

		return lookup
	end

	local start_time = SysTime()
	local data = file.Read(("%s/%s"):format(FOLDER, "twemojis.txt"), "DATA")
	if data and #data > 100 and data:find("\n", 50, true) then
		EasyChat.Print("Loaded twemoji from FS", generate_lookup_table(data), SysTime() - start_time)
	else
		http.Fetch("http://g1.metastruct.net:20080/twemojis.txt.lzma", function(data, _, _, code)
			if code ~= 200 then return end

			data = util.Decompress(data)
			if not data or #data < 100 or not data:find("\n") then return end

			file.Write(("%s/%s"):format(FOLDER, "twemojis.txt"), data)
			local ret = generate_lookup_table(data)
			if not ret or not next(ret) then return end

			EasyChat.Print("Loaded twitter emoji list")
		end)
	end
end

local variant_selector_16 = 0xFE0F
local function twemojify_unsafe(str)
	if not lookup then return nil, "not loaded" end

	local look = lookup
	local seq
	local res = {}
	local lastend = 1

	for char_pos, code_point in utf8.codes(str) do
		if code_point <= 128 then
			-- do not emojify numbers
			code_point = -1
		end

		lastend = lastend or char_pos
		local found_twemoji_part = look[code_point]

		if not found_twemoji_part and seq then
			if code_point ~= variant_selector_16 then
				local beginning = seq[1][1]
				table.insert(res, str:sub(lastend, beginning - 1))
				table.insert(res, seq)
				lastend = char_pos

				seq = nil
				look = lookup
				found_twemoji_part = look[code_point]
			end
		end

		if found_twemoji_part then
			seq = seq or {}
			table.insert(seq, { char_pos, code_point })
			look = look[code_point]
		end
	end

	if seq then
		local beginning = seq[1][1]
		table.insert(res, str:sub(lastend, beginning - 1))
		table.insert(res, seq)
		lastend = nil
	end

	if next(res) then
		if res[1] == "" then
			table.remove(res, 1)
		end
	end

	if next(res) then
		if lastend then
			table.insert(res, str:sub(lastend, -1))
		end

		return res
	end

	return nil, "no emojis"
end

local function twemojify(str)
	local ok, ret, ret2 = pcall(twemojify_unsafe, str)
	if not ok then
		str = utf8.force(str)
		ok, ret, ret2 = xpcall(twemojify_unsafe, debug.traceback, str)
		if not ok then error(ret) end
	end

	return ret, ret2
end

local function get_twemoji_code_points(str)
	local tbl, err = twemojify(str)
	if not tbl or not tbl[1] or tbl[2] then return end

	local res = {}
	for _, v in pairs(tbl[1]) do
		table.insert(res, v[2])
	end

	return res
end

local function material_data(mat)
	return Material("../data/" .. mat)
end

local queue = {}
local function queue_exec()
	local q = queue[1]
	if not q then return end

	local url, suc, fail = unpack(q)
	http.Fetch(url,function(...)
		table.remove(queue,1)
		queue_exec()
		return suc(...)
	end, function(...)
		table.remove(queue,1)
		queue_exec()
		return fail(...)
	end)
end

local function fetch(url, succ, fail)
	local asking = next(queue)
	table.insert(queue, { url, succ, fail })
	if asking then return end

	queue_exec()
end

local cache = {}
local discord_lookup = {}
http.Fetch(DISCORD_LOOKUP_TABLE_URL, function(body)
	local tbl = util.JSONToTable(body)
	if not tbl then
		EasyChat.Print(true, "Could not get the lookup table for twemojis")
		return
	end

	for _, v in ipairs(tbl) do
		local name = v.name
		discord_lookup[name] = v.codes:lower():Replace(" ", "-")
		cache[name] = UNCACHED
	end
end, function(err)
	EasyChat.Print(true, "Could not get the lookup table for twemojis")
end)

local function get_twemoji_url(name)
	return ("https://twemoji.maxcdn.com/v/latest/72x72/%s.png"):format(discord_lookup[name])
end

local function get_twemoji_url_codepoints(tbl)
	local formatted = {}
	for _, num in pairs(tbl) do
		table.insert(formatted, ("%x"):format(num))
	end

	return ("https://twemoji.maxcdn.com/v/latest/72x72/%s.png"):format(table.concat(formatted, "-"))
end

local function to_hex(str)
    return str:gsub(".", function(char)
        return ("%02X"):format(char:byte())
    end)
end

local function get_twemoji(name, code_point)
	if not discord_lookup[name] then
		code_point = code_point or get_twemoji_code_points(name)
		if code_point then
			name = to_hex(name)
		else
			return false
		end
	end

	local c = cache[name]
	if c == nil and code_point then
		c = false
	end

	if c then
		if c == PROCESSING then return end
		return c
	else
		if c == nil then return false end
	end

	-- Otherwise download dat shit
	cache[name] = PROCESSING

	local path = ("%s/%s.png"):format(FOLDER, name)
	local exists = file.Exists(path, "DATA")
	if exists then
		local mat = material_data(path)

		if not mat or mat:IsError() then
			EasyChat.Print(true, "Material found, but is error: ", name, "redownloading")
		else
			c = mat
			cache[name] = c
			return c
		end
	end

	local url = code_point and get_twemoji_url_codepoints(code_point) or get_twemoji_url(name)

	local function fail(err, isvariant)
		EasyChat.Print(true, "Http fetch failed for ", url, ": " .. tostring(err))

		-- bad hack
		if not isvariant then
			EasyChat.Print("Retrying without variant selector just in case...")
			fetch(url:Replace("-fe0f.png",".png"), function(data, len, hdr, code)
				if code ~= 200 and code ~= 404 then return fail(code, true) end

				file.Write(path, data)

				local mat = material_data(path)
				if not mat or mat:IsError() then
					EasyChat.Print(true, "Downloaded material, but is error: ", name)
					return
				end

				cache[name] = mat
			end, function(e) fail(e, true) end)
		end
	end

	fetch(url, function(data, len, hdr, code)
		if code ~= 200 then return fail(code) end

		file.Write(path, data)

		local mat = material_data(path)
		if not mat or mat:IsError() then
			EasyChat.Print(true, "Downloaded material, but is error: ", name)
			return
		end

		cache[name] = mat
	end, fail)
end

--[[-----------------------------------------------------------------------------
	Emoji Component

	Parses unicode and displays twemojis instead.
]]-------------------------------------------------------------------------------
local surface_SetMaterial = surface.SetMaterial

local twemoji_part = table.Copy(EasyChat.ChatHUD.Parts.emote)
twemoji_part.HasSetHeight = nil
twemoji_part.Usage = nil
twemoji_part.Examples = nil

function twemoji_part:Ctor(str)
	local em_components = str:Split(",")
	local name = em_components[1]
	self.Height = draw.GetFontHeight(self.HUD.DefaultFont)

	self:TryGetEmote(name)
	self:ComputeSize()

	return self
end

function twemoji_part:TryGetEmote(name)
	self.Invalid = true

	local code_points = get_twemoji_code_points(name)
	if not code_points then return end

	local succ, twemoji = pcall(get_twemoji, name, code_points)
	-- false indicates that the emote name does not exist for the provider
	if succ and twemoji ~= false then
		-- material was cached
		if type(twemoji) == "IMaterial" then
			self.SetEmoteMaterial = function() surface_SetMaterial(twemoji) end
			self.Invalid = nil
		-- we're still requesting
		elseif twemoji == nil then
			self.SetEmoteMaterial = function()
				local mat = get_twemoji(name, code_points)
				if mat then
					surface_SetMaterial(mat)
				end
			end
			self.Invalid = nil
		end
	end
end

local MAX_TWEMOJIS = 100
function twemoji_part:Normalize(str)
	local twemoji_data = twemojify(str)
	if not twemoji_data then return str end

	local twemojis = 0
	local t = {}
	for _, data in pairs(twemoji_data) do
		if not isstring(data) then
			twemojis = twemojis + 1
			if twemojis > MAX_TWEMOJIS then return str end

			local twemoji_chars = {}
			for _, char_data in pairs(data) do
				table.insert(twemoji_chars, char_data[2])
			end

			data = utf8.char(unpack(twemoji_chars))
			data = ("<twemoji=%s>"):format(data)
		end

		table.insert(t, data)
	end

	return table.concat(t, "")
end

EasyChat.ChatHUD:RegisterPart("twemoji", twemoji_part)
EasyChat.ChatHUD:RegisterEmoteProvider("twemojis", get_twemoji, 1)
EasyChat.AddEmoteLookupTable("twemojis", cache)

return "Twemojis"
