--[[

Simple server rotation using LibRotate.

The configuration:
- persist_index: If true, the addon will save the rotation index, and continue the rotation after server restart.
                 If false, the rotation will start from the first setup after server restart
- default: Default setup. See sms_rotate.txt and lib_rotate.lua for more information about the setup format.
- rotation: Array of setups to rotate. Each setup will be created as combination of the default setup, overridden by the index-th setup from rotation.

Persistent data:
- index: Index of rotation, used so the rotation continues after server restart, rather than starting
         from the first element, if enabled. Delete the data file to restart the rotation

--]]

-- Version 0.4.6

local debug = false
local addon_storage = ...
local config = addon_storage.config
config.persist_index = config.persist_index or false


local addon_data = addon_storage.data
if type( addon_data.vehicles ) ~= "table" then addon_data.vehicles = {} end
local avehicles = addon_data.vehicles
if type( addon_data.classes ) ~= "table" then addon_data.classes = {} end
local aclasses = addon_data.classes
if type( addon_data.tracks ) ~= "table" then addon_data.tracks = {} end
local atracks = addon_data.tracks

if type( config.weather ) ~= "table" then config.weather = {} end
if type( config.weather_weight ) ~= "table" then config.weather_weight = {} end
if type( config.default ) ~= "table" then config.default = {} end
if type( config.rotation ) ~= "table" then config.rotation = {} end
if type( config.vehicle_classes_with_lights ) ~= "table" then config.vehicle_classes_with_lights = {} end
table.sort(config.vehicle_classes_with_lights, sort_alphabetical)
if type( config.flags ) ~= "table" then config.flags = {} end

config.enable_dynamic_weather_system = config.enable_dynamic_weather_system or false
config.dynamic_weather_forecast = config.dynamic_weather_forecast or "Clear"
config.dynamic_weather_probability = config.dynamic_weather_probability or 0
config.full_dynamic_system = config.full_dynamic_system or false

local probablity_weather_type = ""
local probablity_value = 0
if config.enable_dynamic_weather_system then 	
	probablity_weather_type = config.dynamic_weather_forecast	
	probablity_value = math.ceil(config.dynamic_weather_probability)
end

local dynamic_vehicles = config.enable_dynamic_vehicles or true
local dynamic_vehicle_classes = config.enable_dynamic_vehicle_classes or false
local dynamic_vehicle_multiclass = config.enable_dynamic_multi_classes or false
local dynamic_vehicle_multiclass_slots = config.enable_dynamic_multi_classes_count or false

if dynamic_vehicle_classes then 
	dynamic_vehicle_classes = true 
	dynamic_vehicles = false 
end

if dynamic_vehicle_multiclass then 
	dynamic_vehicle_classes = false 
	dynamic_vehicles = false 
end

local multiclass_slots = config.enable_dynamic_multi_classes_count or 1
if dynamic_vehicle_multiclass_slots > 10 then multiclass_slots = 10 end
if dynamic_vehicle_multiclass_slots < 1 then multiclass_slots = 0 end

local welcome_msg = config.welcome_msg or 'Welcome to my server!'
local chatname = ""
local chattrack = ""
local chatvalue = ""
local session_current_state = ""
local session_current_stage = ""
local session_previous_state = ""
local session_previous_stage = ""
local tracks = 0
local chat_track_count = 0
local chat_vehicle_count = 0
local chat_classes_count = 0
local admins = {}
local members = {}
local ai = 0
local vehicle_multiclass = {}
local pvc = 0
local enabled_classes = {}
local enabled_classes = {}
local vehicle_class_count = 0
local enabled_vehicles = {}
local vehicle_count = 0
local enabled_tracks = {}
local enabled_track_count = 0
local has_lights = false
local weatherstore = {}
local weatherstore_count = 0
local lib_rotation = LibRotate.new( config.default )
local rotation_ok = true
local wwt = 0
local practice_fixed_slots = config.practice_fixed_slots or false
local qualify_fixed_slots = config.qualify_fixed_slots or false
local race_fixed_slots = config.race_fixed_slots or false
-- This is used when race is in laps, not timed. 
-- This aids the race start time for cars without lights to avoid night racing at dusk
local avg_laptime_mins = 3

-- ******** GENERIC/BASE FUNCTIONS *********
local function seed()
	local s = math.ceil((string.reverse((os.time() * os.clock()) / math.pi)*1000000000))
	return math.randomseed(s)
end
-- Initial run of seed
seed()

local function starts_with(str, start)
	return str:sub(1, #start) == start
 end
 
local function random_number(lower, upper)	
	local rn = 0
	local r = 0
	local rl = math.ceil(lower * math.pi)
	local ru = math.ceil(upper * math.pi)
	local rns = math.random(rl, ru)
	while r < rns do
		rn = math.random(lower, upper)
		r = r + 1
	end
	return rn
end

local function print_pairs( tbl )
	for k,v in pairs(tbl) do 
		if debug then log("Key: " .. k .. ", Value: " .. v) end
	end
end

local function print_ipairs( tbl )
	for k,v in pairs(tbl) do 
		if debug then log("Key: " .. k .. ", Value: " .. v) end
	end
end

local function sort_alphabetical(a, b) 
	return a:lower() < b:lower() 
end

local function log( text )
	local text = text or ''
	local ts = ''
	ts = tostring("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] [DRB]: " .. text)
	return print(ts)
end


local function is_admin( refid, steamid )
	local rs = false
	local a = tostring(config.ingame_admins_steamids)
	for steam_id in string.gmatch(a, '([^,]+)') do
		if steam_id == tostring(steamid) then
			admins[refid] = tostring(steamid)
			if debug then log("Admin updated with " .. refid .. ", " .. tostring(steamid)) end
			rs = true			
		end
	    if debug then log("Admins listed are: " .. steam_id) end
	end
	return rs
end

local function rotations()
	local count = 0
	for _ in pairs( config.rotation ) do count = count + 1 end
	if count == 0 then count = 1 end
	return count

end

local function session_stages()
	local count = 0
	if config.practice_length_mins > 0 then count = count + 1 end
	if config.qualify_length_mins > 0 then count = count + 1 end
	if config.race_length > 0 then count = count + 1 end
	if debug then log("Session stages = " .. count) end
	return count

end

local function random_slots( session_slots_max )
	local slots = math.floor(math.random(1, session_slots_max))
	return slots
end

local function flags()
	local sf = nil
	for i,v in pairs( config.flags ) do 
		if sf == nil then
			sf = (v) 
		else
			sf = (sf .. "," .. v)
		end		
	end
	return sf
end

-- Randomise rotation index and find the setup.
local setup = setup or {}
if not config.full_dynamic_system then
	local rotation_count = rotations()
	if #config.rotation > 0 then
		addon_data.index = random_number(1, rotation_count)
		setup = config.rotation[ addon_data.index ]
	end
end

-- ******** VEHICLE DATA AND FUNCTIONS *********
local function update_vehicles()
	for i,v in ipairs(lists.vehicles.list) do
		-- print(v.id)
		i = v.name
		if avehicles[i] == nil then
			avehicles[i] = {}
			avehicles[i].enabled = true	
			avehicles[i].class = v.class
			avehicles[i].id = v.id			
		else 
			avehicles[i].class = v.class
			avehicles[i].id = v.id
		end
	end
	table.sort(avehicles, sort_alphabetical)
	SavePersistentData()
end
update_vehicles()

local function update_enabled_vehicles()
	local count = 0
	for i,v in pairs( avehicles ) do
		if avehicles[i].enabled then
			count = count + 1
			enabled_vehicles[count] = i
		end	
	end
	vehicle_count = count
	chat_vehicle_count = count
	return count
end
update_enabled_vehicles()

local function random_vehicle( vid )	
	vname = enabled_vehicles[vid]
	vn = avehicles[vname].id
	return vn
end

-- ******** VEHICLE CLASS DATA AND FUNCTIONS *********
local function update_classes()
	for k,v in pairs(name_to_vehicle_class) do
		-- print(k)
		i = v.name
		if aclasses[i] == nil then
			aclasses[i] = {}
			aclasses[i].enabled = true			
		end
	end
	table.sort(aclasses, sort_alphabetical)
	SavePersistentData()	
end
update_classes()

local function enabled_vehicle_class()
	local count = 0
	for i,v in pairs( aclasses ) do
		if aclasses[i].enabled then
			count = count + 1
			enabled_classes[count] = i
		end	
	end
	vehicle_class_count = count
	chat_classes_count = count
	if config.enable_dynamic_multi_classes and (vehicle_class_count < multiclass_slots) then
		multiclass_slots = vehicle_class_count
		log("Enabled classes is less than Multiclass slots. Max Multiclass slots has been set to " .. vehicle_class_count)
	end
end
enabled_vehicle_class()

local function random_vehicle_class( vcid )
	if debug then log("Class Number = " .. vcid .. " out of " .. vehicle_class_count) end
	return enabled_classes[vcid]
end

local function random_multi_vehicle_class()
	local stop = false
	local mcvcid = 0
	repeat
		mcvcid = random_number(1,vehicle_class_count)
		local mclass = enabled_classes[mcvcid] 
		if vehicle_multiclass[mclass] == nil then
			vehicle_multiclass[mclass] = {}
			stop = true
		end
	until stop == true
	return enabled_classes[mcvcid] 
end

local function track_type( text, find )
	local n = tostring(text):lower()
	local f = find:lower()
	if string.find(n, f) == nil then 
		return false
	else
		return true
	end
end


-- ******** TRACK DATA AND FUNCTIONS *********
local function update_tracks()
	for k,v in pairs(name_to_track) do
		local type = 'Circuit'
		k = v.name
		if track_type(k, "RX") then type = "RallyCross" 
		elseif track_type(k, "DIRT") then type = "RallyCross" 
		elseif track_type(k, "KART") or track_type(k, "Ortona") or track_type(k, "Stage") then type = "Karting" 
		elseif track_type(k, "OVAL") then type = "Oval" 
		elseif track_type(k, "AIRPORT") then type = "Airport"
		elseif track_type(k, "STT") then type = "SuperTrophyTrucks"
		end

		if atracks[k] == nil then
			atracks[k] = {}
			atracks[k].enabled = true
			atracks[k].type = type
			atracks[k].gridsize = v.gridsize
			atracks[k].default_year = v.default_year
		else
			atracks[k].type = type
			atracks[k].gridsize = v.gridsize
			atracks[k].default_year = v.default_year
		end
	end
	table.sort(atracks, sort_alphabetical)
	SavePersistentData()

end
update_tracks()

local function update_enabled_tracks()
	local count = 0
	for i,v in pairs( atracks ) do
		if atracks[i].enabled then
			count = count + 1
			enabled_tracks[count] = i
		end	
	end
	enabled_track_count = count
	chat_track_count = count
end
update_enabled_tracks()

local function random_track( tid )
	return enabled_tracks[tid]
end


-- ******** WEATHER DATA AND FUNCTIONS *********
if debug then log(probablity_value .. "% change of " .. probablity_weather_type ) end
local per_factor = 0

local function weather_types()
	local count = 0
	for _ in pairs( config.weather ) do count = count + 1 end
	return count
end

local function weather_table_add_weight_accum()
	table.sort( config.weather, function (k1, k2) return k1.id < k2.id end )
	local accum = 0
	local pwtw = 0
	local pwt = ''
	for i,v in ipairs(config.weather) do 
		if config.weather_weight[ v.name ] then
			local w = config.weather_weight[ v.name ]
			accum = accum + w
			config.weather[i].weight = w
			config.weather[i].accum_weight = accum
			if v.name == probablity_weather_type then
				pwtw = w
				if debug then log('Found Probability Weather Type in Weatherstore and has a weight of ' .. pwtw) end
			end
			if w > 0 then
				pwt = v.name
			end
		end		
	end	
	if pwtw == 0 then
		probablity_weather_type = pwt
		if debug then log('Probability Weather Type not in Weatherstore. Will now be ' .. probablity_weather_type) end
	end
end

local function weather_weights_total()
	local weather_weights_sum = 0
	for name, weight in pairs( config.weather_weight ) do
		weather_weights_sum = weather_weights_sum + config.weather_weight[ name ]
	end
	if debug then log("Weather weight sum = " .. weather_weights_sum .. ".Per Factor is 100 / wws = " .. 100/weather_weights_sum) end	
	per_factor = 100 / weather_weights_sum
	wwt = weather_weights_sum
	return weather_weights_sum
end

local function probablity_weather_type_index( probablity_weather_type )
	for i, name in ipairs( config.weather ) do
		if config.weather[i].name == probablity_weather_type then
			return config.weather[i].id
		end
	end
end

local function probablity_weather_type_range_value( probablity_weather_type )
	for i, name in ipairs( config.weather ) do
		if config.weather[i].name == probablity_weather_type then
			return config.weather[i].range
		end
	end
end

local function weather_type_selector( weather, slot, session )
	local weather = weather
	local d = 1
	local slot_weather = 'MediumCloud'
	if session == nil then session = 'unknown' end
	if weather == nil then 
		weather = "MediumCloud" 
		log("oops...no weather supplied to weather_type_selector for " .. slot .. " slot for stage " .. session .. ". using default of " .. weather .. ".")
	end	
	-- TODO: Work out better back and forth selector 
	local direction = math.ceil(random_number(1,500) / 100)
	if direction == 1 then d = -2 end
	if direction == 2 then d = -1 end
	if direction == 3 then d = 0 end
	if direction == 4 then d = 1 end
	if direction == 5 then d = 2 end
	for i,v in ipairs( weatherstore ) do
		if v.name == weather then
			if (i <= probablity_weather_type_index(probablity_weather_type)) and (d > 0) then
				d = d * -1
			end
			i = i + d
			if i < 1 then 
				i = i + 2 
			elseif i > weatherstore_count then
				i = i - 2 
			end
			slot_weather = weatherstore[i].name	
		end
	end
	if debug then log(weather ..  " passed in for slot " .. slot .. " for stage " .. session .. ", direction " .. d) end
	return slot_weather
end 

local function weather_store_create()
	local ni = 0
	for i,v in ipairs(config.weather) do 		
		if config.weather[i].weight > 0  then 
			ni = ni + 1 
			weatherstore[ni] = {}
			weatherstore[ni].name = v.name
			weatherstore[ni].weight	 = v.weight
			weatherstore[ni].accum_weight	 = v.accum_weight
			weatherstore[ni].range	 = v.range
			weatherstore_count = ni			
		end
	end	
	if debug then
		print("Index# 	Name 		Weight 		AccumW 		Range")
		for i,v in ipairs(weatherstore) do
			print(i, v.name, v.weight, v.accum_weight, v.range)-- print(i .. "    " .. weatherstore[i].name .. "    " .. weatherstore[i].weight .. "    " .. weatherstore[i].accum_weight .. "    " .. weatherstore[i].range)
		end
	end	
end


local function weather_table_add_probability_ranges(probablity_weather_type,probablity_value )
	local ar = 1
	if config.full_dynamic_system == true then 
		ar = config.dynamic_weather_probability_sessions
	else
		ar = rotations()
	end
	local as = session_stages()	
	local wi = probablity_weather_type_index(probablity_weather_type)
	local dwr = probablity_weather_type_range_value( probablity_weather_type )
	local baserwr = (100-(probablity_value / ar ))
	local post_rwr_factor = (1 - (baserwr/100)) / (wwt - config.weather[wi].accum_weight)
	local rwr = baserwr / dwr
	local aww = 0
	if debug then 
		log("Rotations = " .. ar .. ". Sessions = " .. as .. ". Weather Index # = " .. wi .. ". Weather Range Value = " .. dwr .. ". probablity_value = " .. probablity_value .. "RWR Value is 100 - (pv / ( Rotations + Sessions)) / WeatherRangeValue = " .. rwr)
		log(" Total weather weight - dwr = " .. wwt .. " and ".. dwr)
	end
	for i,v in ipairs(config.weather) do 
		if config.weather[i].weight > 0 then		
			if config.weather[i].id <= wi  then
				config.weather[i].range = config.weather[i].range * rwr
			elseif  config.weather[i].id > wi  then	
				local ww = 	config.weather[i].weight
				aww = aww + ww
				config.weather[i].range = (aww * post_rwr_factor) * 100 + baserwr
			end
		end
	end	
	weather_store_create()
end

local function weather_table_add_default_ranges( per_factor )
	local ar = 0
	for i,v in ipairs(config.weather) do 
		ar = ar + ( config.weather[i].weight * per_factor )
		if config.weather[i].weight == 0 then
			config.weather[i].range = 999
		else
			config.weather[i].range = ar
		end
	end	
end

local function weather_randomiser()
	local selected_weather = 'LightCloud'
	local rwn = 0
	local ni = 0
	rwn = random_number(1,100)
	for i, v in ipairs(weatherstore) do
		local range = weatherstore[i].range
		ni = i + 1
		local nr = weatherstore[ni].range
		if rwn > range and rwn <= nr then
			selected_weather = weatherstore[ni].name
			if debug then log("Random Weather # of " .. rwn .. " is > " .. range .. ' [ ' .. weatherstore[i].name .. ' ] but <= ' .. nr  .. ' [ ' .. weatherstore[ni].name .. ']. Weather is ' .. selected_weather)	end		
			break
		elseif rwn <= range then			
			selected_weather = weatherstore[i].name
			if debug then log("Random Weather # of " .. rwn .. " is <= " .. range .. ' [ ' .. weatherstore[i].name .. ' ]. Weather is ' .. selected_weather) end
			break
		end
	end	
	return selected_weather
end


local function verify_setups()
	rotation_ok = true
	if config.full_dynamic_system == true then
		log( "Rotation disabled. Using Dynamic Selectors for sessions indefinitely" )
		rotation_ok = true
		return
	end

	if #config.rotation == 0 then
		log( "No rotation defined in config, will only apply the defaults" )
		rotation_ok = false
		return
	end

	if ( session.next_attributes.ServerControlsSetup == 0 ) then
		log( "Using scripted setup rotation while the server is not configured to control the game's setup. Make sure to set \"controlGameSetup\" in the server config." )
		rotation_ok = false
	end

	for index,setup in ipairs( config.rotation ) do
		if not lib_rotation:verify_setup( setup ) then
			log( "Setup at index " .. index .. " contains errors!" )
			rotation_ok = false
		end
	end
	if not rotation_ok then
		log( "Rotation setups contain errors, rotation addon disabled" )
	end
end

-- The main "rotate to next setup" function
local function advance_next_setup( v )
	local session_to_apply = v or 0
	if debug then log("Session: " .. session_to_apply) end
	if not rotation_ok then
		return
	end
	local attributes = lib_rotation:merge_setup( setup )
	-- local progression_values = {1,5,10,15,20,25,30,35,40,45,50,55,60}
	local pstage = false
	local qstage = false
	local rstage = false
	local practice_ingame_duration = nil
	local qualify_ingame_duration = nil
	local race_ingame_duration = nil
	local init_pslot_weather = ""
	local init_qslot_weather = ""
	local init_rslot_weather = ""
	
	-- Apply Weather Variables to Race
	-- Apply the setup	
	local sflags = flags()	
	attributes.PracticeWeatherSlots = 0
	attributes.QualifyWeatherSlots = 0
	attributes.RaceWeatherSlots = 0
	local normalise_progression = 1
	if config.practice_time_progression < 0 then config.practice_time_progression = 0 end
	if config.qualify_time_progression  < 0 then config.qualify_time_progression  = 0 end
	if config.race_time_progression  < 0 then config.race_time_progression  = 0 end
	-- Vehicle Randomiser
	if dynamic_vehicles then
		local rvnc = vehicle_count
		local rvn = random_number(1,rvnc)
		local vn = random_vehicle(rvn)
		chatvalue = tostring(vn)
		local vc = avehicles[vname].class
		has_lights = false
		if debug then 
			log("VC=".. rvnc .. " RVN=" .. rvn .. " VN=".. vname )
			log(normalize_session_attribute("VehicleModelId", vn))
		end
		sflags = (sflags .. ",FORCE_IDENTICAL_VEHICLES")
		attributes.VehicleModelId =  normalize_vehicle( vn )
		attributes.ServerControlsVehicle = 1
		for i,v in pairs(config.vehicle_classes_with_lights) do
			if v == vc then
				has_lights = true
				if debug then log(vc .. " has lights!") end	
			end	
		end	
	end

	-- Vehicle Class Randomiser
	if dynamic_vehicle_classes then
		local rvcc = vehicle_class_count
		local rvcr = random_number(1, rvcc)	
		has_lights = false
		if rvcr == pvc then
			rvcr = random_number(1, rvcc)
		else
			pvc = rvcr
		end
		local vcn = random_vehicle_class(rvcr)
		chatvalue = tostring( vcn )
		if debug then 
			log("VRC= ".. rvcc .. " RVCN=" .. rvcr .. " VCN=".. vcn )
			log(normalize_vehicle_class( vcn ))
		end
		attributes.ServerControlsVehicle = 0
		attributes.ServerControlsVehicleClass = 1
		sflags = (sflags .. ",FORCE_SAME_VEHICLE_CLASS")
		attributes.VehicleClassId = normalize_vehicle_class( vcn )
		for i,v in pairs(config.vehicle_classes_with_lights) do
			if v == vcn then
				has_lights = true
				if debug then log(vcn .. " has lights!") end	
			end	
		end			
	end

	-- Multi Vehicle Class Randomiser
	if dynamic_vehicle_multiclass then
		attributes.ServerControlsVehicle = 0
		attributes.ServerControlsVehicleClass = 1
		sflags = (sflags .. ",FORCE_MULTI_VEHICLE_CLASS")
		local mcslots = multiclass_slots	
		if multiclass_slots	== 0 then 
			mcslots = random_number(1,multiclass_slots)
		end
		chatvalue = tostring( mcslots .. 'classes ' )
	    attributes.MultiClassSlots = mcslots
	    attributes.VehicleClassId  = normalize_vehicle_class( random_multi_vehicle_class() )
	    if mcslots > 1 then attributes.MultiClassSlot1 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 2 then attributes.MultiClassSlot2 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 3 then attributes.MultiClassSlot3 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 4 then attributes.MultiClassSlot4 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 5 then attributes.MultiClassSlot5 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 6 then attributes.MultiClassSlot6 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 7 then attributes.MultiClassSlot7 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 8 then attributes.MultiClassSlot8 = normalize_vehicle_class( random_multi_vehicle_class() ) end
	    if mcslots > 9 then attributes.MultiClassSlot9 = normalize_vehicle_class( random_multi_vehicle_class() ) end
		-- Clear Multiclass checker
		vehicle_multiclass = {}
	end

	-- Track attributes
	-- Reload default Gridsize
	attributes.GridSize = config.default.GridSize
	attributes.MaxPlayers = config.default.MaxPlayers
	local rtnc = enabled_track_count
	local rtn = random_number(1,rtnc)
	local tn = random_track(rtn)
	chattrack = tostring(tn)
	if debug then 
		log("TC= ".. rtnc .. " RTN=" .. rtn .. " TN=".. tn )
		log(normalize_session_attribute("TrackId", tn))
	end
	attributes.TrackId = normalize_session_attribute("TrackId", tn)		
	local track = id_to_track[ attributes.TrackId ]
	if not track then
		log( "[ERROR]: Verify setup warning: Unknown track id '" .. attributes.TrackId .. "' used in the setup" )
	end
	if track.gridsize < attributes.GridSize then
		local checker = 1
		log( "WARNING: Track " .. track.name .. "' (id " .. track.id .. ") has grid size limited to " .. track.gridsize ..
			", rerunning track selector." )
		while true do
			rtn = random_number(1,rtnc)
			tn = random_track(rtn)
			attributes.TrackId = normalize_session_attribute("TrackId", tn)
			track = id_to_track[ attributes.TrackId ]
			if track.gridsize >= attributes.GridSize then
				break
			end
		end				
	end	
	-- Assign date defaults
	attributes.RaceDateDay = track.default_day
	attributes.RaceDateMonth = track.default_month
	attributes.RaceDateYear = track.default_year
	config.practice_weather_slots_max = math.min(config.practice_weather_slots_max or 1, 4)
	-- Practice attributes
	if (config.practice_length_mins <= 0) then attributes.PracticeLength = 0 else attributes.PracticeLength = config.practice_length_mins end
	if (config.practice_length_mins > 0) and (config.practice_weather_slots_max <= 4) then
		pstage = true
		local pprog = config.practice_time_progression
		local pslots_max = config.practice_weather_slots_max
		local pslots = 1
		if practice_fixed_slots then pslots = pslots_max else pslots = random_number(1,pslots_max) end
		attributes.PracticeWeatherSlots = pslots
		if config.enable_dynamic_weather_system then
			-- Set the progression value
			if pprog > 2 and pprog <= 60 then
				normalise_progression = math.ceil(pprog / 5) * 5
			elseif pprog == 1 then
				normalise_progression = 1			
			end 
		end
		-- Set the attributes using the progression rate assigned previously
		if pprog > 0 and pprog <=60 then 
			attributes.PracticeDateProgression = normalise_progression 
		elseif pprog == 0 then
			attributes.PracticeDateProgression = 1
			attributes.PracticeWeatherProgression = 0
		else
			normalise_progression = math.ceil( ( (pslots * config.dynamic_weather_slot_duration) / attributes.PracticeLength) / 5) * 5			
			attributes.PracticeDateProgression = normalise_progression	
			attributes.PracticeWeatherProgression = attributes.PracticeDateProgression
		end 
		practice_ingame_duration = math.ceil(((normalise_progression * attributes.PracticeLength)))
		if debug then 
			log("Practice Slots = " .. pslots .. ", Realtime mins = ".. attributes.PracticeLength .. ", Ingame mins = ".. practice_ingame_duration ..", Progression rate of " .. normalise_progression .. "x")
			log("Practice Duration in hours is " .. practice_ingame_duration/60)
		end
		if config.enable_dynamic_weather_system then			
			local init_pslot = random_number(1,tonumber(pslots))
			local init_pslot_weather = weather_randomiser()
			if init_pslot_weather ~= nil then
				if init_pslot == 1 then 
					attributes.PracticeWeatherSlot1 = init_pslot_weather
					attributes.PracticeWeatherSlot2 = weather_type_selector(init_pslot_weather, 2, "Practice")
					attributes.PracticeWeatherSlot3 = weather_type_selector(attributes.PracticeWeatherSlot2, 3, "Practice")
					attributes.PracticeWeatherSlot4 = weather_type_selector(attributes.PracticeWeatherSlot3, 4, "Practice")
				end
				if init_pslot == 2 then 					
					attributes.PracticeWeatherSlot2 = init_pslot_weather
					attributes.PracticeWeatherSlot1 = weather_type_selector(init_pslot_weather, 1, "Practice")
					attributes.PracticeWeatherSlot3 = weather_type_selector(init_pslot_weather, 3, "Practice")
					attributes.PracticeWeatherSlot4 = weather_type_selector(attributes.PracticeWeatherSlot3, 4, "Practice")
				end
				if init_pslot == 3 then 
					attributes.PracticeWeatherSlot3 = init_pslot_weather
					attributes.PracticeWeatherSlot2 = weather_type_selector(init_pslot_weather,  2, "Practice")
					attributes.PracticeWeatherSlot4 = weather_type_selector(init_pslot_weather,  4, "Practice")		
					attributes.PracticeWeatherSlot1 = weather_type_selector(attributes.PracticeWeatherSlot2,  1, "Practice")
					
				end
				if init_pslot == 4 then 
					attributes.PracticeWeatherSlot4 = init_pslot_weather
					attributes.PracticeWeatherSlot3 = weather_type_selector(init_pslot_weather,  3, "Practice")		
					attributes.PracticeWeatherSlot2 = weather_type_selector(attributes.PracticeWeatherSlot3,  2, "Practice")
					attributes.PracticeWeatherSlot1 = weather_type_selector(attributes.PracticeWeatherSlot2,  1, "Practice")
				end
			end	
			if debug then
				log("PRACTICE - Time: " .. attributes.PracticeLength .. 
					", Slots: " .. attributes.PracticeWeatherSlots .. 
					" S1: " .. attributes.PracticeWeatherSlot1 .. 
					" S2: " .. attributes.PracticeWeatherSlot2 ..
					" S3: " .. attributes.PracticeWeatherSlot3 ..
					" S4: " .. attributes.PracticeWeatherSlot4)				
			end		
		end
	end
	-- Qualify Stage attributes
	-- Reset normalise_progression
	normalise_progression = 1
	config.qualify_weather_slots_max = math.min(config.qualify_weather_slots_max or 1, 4)
	if (config.qualify_length_mins <= 0) then attributes.QualifyLength = 0 else attributes.QualifyLength = config.qualify_length_mins end
	if (config.qualify_length_mins > 0) and (config.qualify_weather_slots_max <= 4) then
		qstage = true
		local qprog = config.qualify_time_progression
		local qslots_max = config.qualify_weather_slots_max
		local qslots = 1
		if qualify_fixed_slots then qslots = qslots_max else qslots = random_number(1,qslots_max) end
		attributes.QualifyWeatherSlots = qslots
		if qprog > 2 and qprog <= 60 and config.enable_dynamic_weather_system then
			normalise_progression = math.ceil(qprog / 5) * 5
		elseif qprog >= 2 and config.enable_dynamic_weather_system then
			normalise_progression = 2
		end 
		if qprog > 0 and qprog <= 60 then 
			attributes.QualifyDateProgression = normalise_progression 
		elseif qprog == 0 then
			attributes.QualifyDateProgression = 1
			attributes.QualifyWeatherProgression = 0
		else
			normalise_progression = math.ceil( ( (qslots * config.dynamic_weather_slot_duration) / attributes.QualifyLength) / 5) * 5			
			attributes.QualifyDateProgression = normalise_progression	
			attributes.QualifyWeatherProgression = attributes.QualifyDateProgression
		end 
		qualify_ingame_duration = math.ceil(((normalise_progression * attributes.QualifyLength)))
		if debug then 
			log("Qualify Slots = " .. qslots .. ", Realtime mins = ".. attributes.QualifyLength .. ", Ingame mins = ".. qualify_ingame_duration ..", Progression rate of " .. normalise_progression .. "x")
			log("Qualify Duration in hours is " .. qualify_ingame_duration/60)
		end	
		if config.enable_dynamic_weather_system then
			local init_qslot = random_number(1,qslots)
			local init_qslot_weather = weather_randomiser()
			if init_qslot_weather ~= nil then
				if init_qslot == 1 then
					attributes.QualifyWeatherSlot1 = init_qslot_weather
					attributes.QualifyWeatherSlot2 = weather_type_selector(init_qslot_weather, 2, "Qualify")
					attributes.QualifyWeatherSlot3 = weather_type_selector(attributes.QualifyWeatherSlot2, 3, "Qualify")
					attributes.QualifyWeatherSlot4 = weather_type_selector(attributes.QualifyWeatherSlot3, 4, "Qualify")
				end
				if init_qslot == 2 then 					
					attributes.QualifyWeatherSlot2 = init_qslot_weather
					attributes.QualifyWeatherSlot1 = weather_type_selector(init_qslot_weather, 1, "Qualify")
					attributes.QualifyWeatherSlot3 = weather_type_selector(init_qslot_weather, 3, "Qualify")
					attributes.QualifyWeatherSlot4 = weather_type_selector(attributes.QualifyWeatherSlot3, 4, "Qualify")
				end
				if init_qslot == 3 then 
					attributes.QualifyWeatherSlot3 = init_qslot_weather					
					attributes.QualifyWeatherSlot2 = weather_type_selector(init_qslot_weather,  2, "Qualify")
					attributes.QualifyWeatherSlot4 = weather_type_selector(init_qslot_weather,  4, "Qualify")
					attributes.QualifyWeatherSlot1 = weather_type_selector(attributes.QualifyWeatherSlot2,  1, "Qualify")
				end
				if init_qslot == 4 then 
					attributes.QualifyWeatherSlot4 = init_qslot_weather	
					attributes.QualifyWeatherSlot3 = weather_type_selector(init_qslot_weather,  3, "Qualify")
					attributes.QualifyWeatherSlot2 = weather_type_selector(attributes.QualifyWeatherSlot3,  2, "Qualify")
					attributes.QualifyWeatherSlot1 = weather_type_selector(attributes.QualifyWeatherSlot2,  1, "Qualify")
				end

				if debug then 
					log("QUALIFY - Time: " .. attributes.QualifyLength .. 
					", Slots: " .. attributes.QualifyWeatherSlots .. 
					" S1: " .. attributes.QualifyWeatherSlot1 .. 
					" S2: " .. attributes.QualifyWeatherSlot2 ..
					" S3: " .. attributes.QualifyWeatherSlot3 ..
					" S4: " .. attributes.QualifyWeatherSlot4)
				end
			end		
		end
	end
	-- Race1 Stage attributes
	-- Reset normalise_progression
	normalise_progression = 1
	config.race_weather_slots_max = math.min(config.race_weather_slots_max or 1, 4)
	if (config.race_length <= 0) then attributes.RaceLength = 0 else attributes.RaceLength = config.race_length end
	if (config.race_length > 0) and (config.race_weather_slots_max <= 4) then
		rstage = true
		local rl = nil
		local rprog = config.race_time_progression
		local rslots_max = config.race_weather_slots_max
		local rslots = 1
		if race_fixed_slots then rslots = rslots_max else rslots = random_number(1,rslots_max) end
		attributes.RaceWeatherSlots = rslots
		if rprog >= 2 and rprog <= 60 and config.enable_dynamic_weather_system then
			normalise_progression = math.ceil(rprog / 5) * 5
		elseif rprog >= 0 and rprog < 2 and config.enable_dynamic_weather_system then
			normalise_progression = 1
		end 
		if rprog > 0 and rprog <= 60 then 
			attributes.RaceDateProgression = normalise_progression 
		elseif rprog == 0 then
			attributes.RaceDateProgression = 1
			attributes.RaceWeatherProgression = 0
		else
			normalise_progression = math.ceil( ( (rslots * config.dynamic_weather_slot_duration) / attributes.RaceLength) / 5) * 5			
			attributes.RaceDateProgression = normalise_progression	
			attributes.RaceWeatherProgression = attributes.RaceDateProgression
		end 
		race_ingame_duration = math.ceil(((normalise_progression * attributes.RaceLength * avg_laptime_mins)))
		if debug then 
			log("Race Slots = " .. rslots .. ", Realtime mins = ".. attributes.RaceLength .. ", Ingame mins = ".. race_ingame_duration ..", Progression rate of " .. normalise_progression .. "x")
			log("Race Duration in hours is " .. race_ingame_duration/60)
		end			
		if not config.race_timed then
			rl = attributes.RaceLength * avg_laptime_mins	
			if debug then log("Race is laps") end	
		else
			sflags = (sflags .. ",TIMED_RACE")
			rl = attributes.RaceLength
			if debug then log("Race is timed") end
		end
		race_ingame_duration = math.ceil(((normalise_progression * rl) / 60))
		if config.enable_dynamic_weather_system == true then
			local init_rslot = random_number(1,rslots)
			local init_rslot_weather = weather_randomiser()
			if init_rslot_weather ~= nil then
				if init_rslot == 1 then 
					attributes.RaceWeatherSlot1 = init_rslot_weather
					attributes.RaceWeatherSlot2 = weather_type_selector(init_rslot_weather, 2, "Race")
					attributes.RaceWeatherSlot3 = weather_type_selector(attributes.RaceWeatherSlot2, 3, "Race")
					attributes.RaceWeatherSlot4 = weather_type_selector(attributes.RaceWeatherSlot3, 4, "Race")
				end
				if init_rslot == 2 then 
					attributes.RaceWeatherSlot2 = init_rslot_weather
					attributes.RaceWeatherSlot1 = weather_type_selector(init_rslot_weather, 1, "Race")					
					attributes.RaceWeatherSlot3 = weather_type_selector(init_rslot_weather, 3, "Race")
					attributes.RaceWeatherSlot4 = weather_type_selector(attributes.RaceWeatherSlot3, 4, "Race")
				end
				if init_rslot == 3 then
					attributes.RaceWeatherSlot3 = init_rslot_weather 					
					attributes.RaceWeatherSlot2 = weather_type_selector(init_rslot_weather,  2, "Race")					
					attributes.RaceWeatherSlot4 = weather_type_selector(init_rslot_weather,  4, "Race")
					attributes.RaceWeatherSlot1 = weather_type_selector(attributes.RaceWeatherSlot2,  1, "Race")
				end
				if init_rslot == 4 then 
					attributes.RaceWeatherSlot4 = init_rslot_weather	
					attributes.RaceWeatherSlot3 = weather_type_selector(init_rslot_weather,  3, "Race")
					attributes.RaceWeatherSlot2 = weather_type_selector(attributes.RaceWeatherSlot3,  2, "Race")
					attributes.RaceWeatherSlot1 = weather_type_selector(attributes.RaceWeatherSlot2,  1, "Race")
				end		

				if debug then 
					log("RACE - Time: " .. attributes.RaceLength .. 
					", Slots: " .. attributes.RaceWeatherSlots .. 
					" S1: " .. attributes.RaceWeatherSlot1 .. 
					" S2: " .. attributes.RaceWeatherSlot2 ..
					" S3: " .. attributes.RaceWeatherSlot3 ..
					" S4: " .. attributes.RaceWeatherSlot4)
				end
			end		
		end
	end
	
	if config.use_current_date and not config.use_dynamic_date then
		attributes.RaceDateDay = tonumber(os.date("%d"))
		attributes.RaceDateMonth = tonumber(os.date("%m"))
		attributes.RaceDateYear = tonumber(os.date("%Y"))
	elseif not config.use_current_date and config.use_dynamic_date then
		local d, m, y, start, now, rand, newdate, rd, rm, ry, timediff
		d = attributes.RaceDateDay
		m = attributes.RaceDateMonth
		y = attributes.RaceDateYear
		start = os.time({year=y, month=m, day=d})
		now = tonumber(os.time(os.date('*t')))
		timediff = now - start
		rand = tonumber(math.random(timediff))
		newdate = now - rand
		rd = tonumber(os.date('%d', newdate))
		rm = tonumber(os.date('%m', newdate))
		ry = tonumber(os.date('%Y', newdate))
		attributes.RaceDateDay = rd
		attributes.RaceDateMonth = rm
		attributes.RaceDateYear = ry		
	end

	if config.dynamic_race_timeframe then
		local s = config.dynamic_race_earliest_start_hour
		local e = config.dynamic_race_latest_start_hour
		local hour = 0	
		if has_lights and config.enable_night_races then
			if debug then log("Has Lights and Night Races Enabled!") end
			s = s
			e = 23
		end
		if rstage then
			if not has_lights then
				-- If has no lights, reduce the risk of racing into the darkenss by changing the end hour by the ingame race duration time
				e = e - math.ceil(race_ingame_duration)				
			end
			hour = math.random(s,e)			
			attributes.RaceDateHour = hour
			e = hour
			if debug then log("Race Stage Start Hour is " .. hour .. " and Ends around " .. hour + (race_ingame_duration)) end
		end		
		if qstage then
			hour = math.random(s,e)			
			attributes.QualifyDateHour = hour
			e = hour
			if debug then log("Qualify Stage Start Hour is " .. hour .. " for " .. qualify_ingame_duration .. " minutes.") end
		end
		if pstage then
			hour = math.random(s,e)
			attributes.PracticeDateHour = hour
			if debug then log("Practice Stage Start Hour is " .. hour .. " for " .. practice_ingame_duration .. " minutes.") end
		end		
		
	end	
	attributes.Flags = normalize_session_flags( SessionFlags, sflags )
	if ai > 31 then ai = 31 end
	if ai > 0 and ai < 32 then
		sflags = (sflags .. ",FILL_SESSION_WITH_AI")
		attributes.MaxPlayers = attributes.GridSize - ai
		log("AI is now " .. ai)
		log("Session Flags now :" .. sflags)
		log("Max Players is now " .. attributes.MaxPlayers)
	end
	if session_to_apply == 1 then
		SetSessionAttributes( attributes )
		if debug then log("Setting Current Session Attrs") end
	else
		log("Setting Next Session Attrs")		
		SetNextSessionAttributes( attributes )	
	end	
	if debug then
		log("Final Flags passed to librotate: " .. sflags )
		for k, v in pairs( attributes ) do
			log("Current Session - Name: ".. k .. " Value: " .. v)
		end
	end
end

-- Startup
local function set_first_setup()
	if not rotation_ok then
		return
	end
	advance_next_setup()
end

config.send_setup = config.send_setup or {}
local send_setup = table.list_to_set( config.send_setup )
local send_when_returning_to_lobby = config.send_when_returning_to_lobby or false

-- Map from refid to send timer (GetServerUptimeMs)
local scheduled_sends = {}

-- Immediate send to given refid
local function send_now( refid )
	local attributes = session.attributes
	-- Send the message
	if welcome_msg then
		local s = config.announce_bot
		SendChatToMember( refid, s)		
		if config.send_combo_info then
			if dynamic_vehicles then
				local combos = tonumber(chat_track_count) * tonumber(chat_vehicle_count)
				s = tostring("[DRB]: " .. combos .. " combinations from " .. chat_track_count .. " tracks and " .. chat_vehicle_count .. " vehicles!")
				SendChatToMember( refid, s )
			end
			if dynamic_vehicle_classes then
				local combos = tonumber(chat_track_count) * tonumber(chat_classes_count)
				s = tostring("[DRB]: " .. combos .. " combinations from " .. chat_track_count .. " tracks and " .. chat_classes_count .. " vehicle classes!")
				SendChatToMember( refid, s )
			end	
		end
	end

	if #config.community_msg > 0 then
		local s = tostring("[DRB]: " .. tostring(config.community_msg) ..".")
		SendChatToMember( refid, s )
	end

	if #config.voice_chat_msg > 0 then
		local s = tostring("[DRB]: " .. tostring(config.voice_chat_msg) ..".")
		SendChatToMember( refid, s )
	end	

	-- Send race format.
	if config.send_setup_format then
		local phases = {}
		if attributes.PracticeLength ~= 0 then
			table.insert( phases, "practice (" .. attributes.PracticeLength .. " minutes)" )
		end
		if attributes.QualifyLength ~= 0 then
			table.insert( phases, "qualify (" .. attributes.QualifyLength .. " minutes)" )
		end
		if attributes.RaceLength ~= 0 then
			if ( attributes.Flags & SessionFlags.TIMED_RACE ) ~= 0 then
				table.insert( phases, "race (" .. attributes.RaceLength .. " mins)" )
			else
				table.insert( phases, "race (" .. attributes.RaceLength .. " laps)" )
			end
		end
		SendChatToMember( refid, "Race format: " .. table.concat( phases, ", " ) )
	end
end

-- The tick that processes all queued sends
local function tick()
	local now = GetServerUptimeMs()
	for refid,time in pairs( scheduled_sends ) do
		if now >= time then
			send_now( refid )
			scheduled_sends[ refid ] = nil
		end
	end
end

-- Request send to given refid, or all session members if refid is not specified.
local function send_motd_to( refid )
	local send_time = GetServerUptimeMs() + 2000
	if refid then
		scheduled_sends[ refid ] = send_time
	else
		for k,_ in pairs( session.members ) do
			scheduled_sends[ k ] = send_time
		end
	end
end

-- Main addon callback
local function addon_callback( callback, ... )	
	-- print( "name_to_track:" ); dump( attributes.next_attributes, "  " )
	-- print( "Damage:" ); dump( Damage, "  " )
	-- print( "SessionFlags:" ); dump( SessionFlags, "  " )
	-- print( "Callbacks:" ); dump( Callback, "  " )

	-- Set first setup in the list when the server starts.
	if callback == Callback.ServerStateChanged then
		local oldState, newState = ...
		if ( oldState == "Starting" ) and ( newState == "Running" ) then
			verify_setups()
			set_first_setup()
		end
		log( "Server state changed from " .. oldState .. " to " .. newState )
		-- print( "Server: " ); dump( server, "  " )
		-- print( "Session: " ); dump( session, "  " )
	end

	-- Handle session state changes. Note that Callback.SessionManagerStateChanged notifies about the session manager
	-- (just idle/allocating/running), which we are not interested in. Instead we use the log events.
	-- Lobby->Loading - we started current track, advance to next
	-- Session destroyed while in the Lobby - quit while in the lobby, also advance to next
	if callback == Callback.EventLogged then
		local event = ...	
		if ( event.type == "Session" ) and ( event.name == "StateChanged" ) then
			session_previous_state = session_current_state
			session_current_state = event.attributes.NewState	
			-- if ( event.attributes.PreviousState == "Lobby" ) and ( event.attributes.NewState == "Loading" ) then
			-- 	advance_next_setup()
			-- end
			if ( event.attributes.PreviousState ~= "None" ) and ( event.attributes.NewState == "Lobby" ) then
				advance_next_setup()
				if send_when_returning_to_lobby then
					send_motd_to()
				end
			end			
		elseif ( event.type == "Session" ) and ( event.name == "SessionDestroyed" ) then
			session_previous_state, session_current_state = 'SessionDestroyed'
			session_previous_stage, session_current_stage = 'SessionDestroyed'
				members = {}
				advance_next_setup()	
		end
		
		-- If event is from player, and is of message and player is in admin group
		if event.type == "Player" and (admins[event.refid] or session.members[ event.refid ].host) and event.name == "PlayerChat" then
			local chat_msg = event.attributes.Message
			if admins[event.refid] then
				if event.attributes.Message == "remtrack" then 
					local track = id_to_track[ session.attributes.TrackId ]
					local tn = tostring(track.name)
					atracks[tn].enabled = false
					SavePersistentData()
					SendChatToMember(event.refid, tn .. " has been disabled.")
					update_tracks()
					update_enabled_tracks()
					--atracks = addon_data.tracks				
					log("Admin disabled " .. tn .. " via ingame chat.")
				end
				if event.attributes.Message == "remclass" and dynamic_vehicle_classes then 
					local class = id_to_vehicle_class[ session.attributes.VehicleClassId ]
					local cn = tostring(class.name)
					aclasses[cn].enabled = false
					SavePersistentData()
					SendChatToMember(event.refid, cn .. " has been disabled." )
					update_classes()
					enabled_vehicle_class()
					-- aclasses = addon_data.classes
					log("Admin disabled " .. cn .. " via ingame chat.")
				end
				if event.attributes.Message == "remvehicle" and not dynamic_vehicle_classes then 
					local vehicle = id_to_vehicle[ session.attributes.VehicleId ]
					local vn = tostring(vehicle.name)
					avehicles[vn].enabled = false
					SavePersistentData()
					SendChatToMember(event.refid, vn .. " has been disabled." )
					update_vehicles()
					update_enabled_vehicles()
					-- avehicles = addon_data.vehicles
					log("Admin disabled " .. vn .. " via ingame chat.")
				end
			end
			if event.attributes.Message == "advance" then AdvanceSession(true) end
			if event.attributes.Message == "reset" then ServerRestart() end
			if event.attributes.Message == "+" then advance_next_setup(1) end
			if starts_with(chat_msg, "ai") then 				
				ai = tonumber(string.match(chat_msg, 'ai%s*(%S+)'))
				if ai_strength == nil then ai_strength = 100 end
				SendChatToMember( event.refid, ai .. " AI at " .. ai_strength .. "% effective next Lobby.")
				advance_next_setup()
			end	
			if starts_with(chat_msg, "sai") then 				
				ai_strength = tonumber(string.match(chat_msg, 'sai%s*(%S+)'))
				SendChatToMember( event.refid, "AI Strength :" .. ai_strength .. "% effective next Lobby.")
				advance_next_setup()
			end	
			if starts_with(chat_msg, "kp") then
				local p = string.match(chat_msg, 'kp %s*(%S+)')
				for k,v in pairs(members) do
					local n = members[k].name
					local a = members[k].is_admin
					if (n:lower() == p:lower()) and not a then
						KickMember(k)
						SendChatToAll("[Admin]: Kicked " .. n)
					elseif (n:lower() == p:lower()) and a then
						SendChatToAll("[Admin]: " .. n .. " can't be kicked.Is Admin.. ")
					elseif (n:lower() == p:lower()) and a then
						SendChatToMember(event.refid, "[Admin]: " .. n .. " not found..")
					end
				end
			end				
		end
		-- Check if player is an admin or not
		if event.type == "Player" and event.name == "PlayerJoined" then
			if debug then 
				log( "Event.Player.PlayerJoined: " ) 
				dump( event, "  " ) 
			end
			local refid = event.refid
			members[refid] = {}
			members[refid].name = event.attributes.Name
			members[refid].steamid = tostring(event.attributes.SteamId)
			members[refid].is_admin = is_admin(event.refid, event.attributes.SteamId)
			SendChatToMember( refid, "[DRB]: Admin/Host command skip via '+' available via in game chat.")
		end

		if event.type == "Player" and event.name == "PlayerLeft" then
			local refid = event.refid
			members[refid] = nil	
		end
	end	

	-- Regular tick
	if callback == Callback.Tick then
		tick()
	end
	-- Welcome new members.
	if callback == Callback.MemberStateChanged then
		local refid, _, new_state = ...
		if new_state == "Connected" then
			send_motd_to( refid )
		end
	end
end

-- Main
RegisterCallback( addon_callback )
EnableCallback( Callback.ServerStateChanged )
EnableCallback( Callback.EventLogged )
EnableCallback( Callback.Tick )
EnableCallback( Callback.SessionAttributesChanged )
EnableCallback( Callback.MemberStateChanged )
if send_when_returning_to_lobby then
	EnableCallback( Callback.EventLogged )
end

SavePersistentData()

-- Add weights to weather table
if config.enable_dynamic_weather_system then
	weather_table_add_weight_accum()
	-- Sum weights on weather table
	weather_weights_total()
	-- Add default weather range using factor
	weather_table_add_default_ranges(per_factor)
	-- Add probability ranges to weather table for randomiser to select from using weights
	weather_table_add_probability_ranges(probablity_weather_type, probablity_value)
end
-- EOF --
