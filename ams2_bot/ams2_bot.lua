local addon_storage = ...

-- Grab config.
local config = addon_storage.config

-- Enable debugging prints?
local debug = false

-- Various times, move to config?
local TICK_UPDATE_DELTA_MS = 1000
local ACTIVE_AUTOSAVE_DELTA_MS = 2 * 60 * 1000
local IDLE_AUTOSAVE_DELTA_MS = 15 * 60 * 1000


-- Current state
local connected_to_steam = false
local server_state = "Idle"
local session_manager_state = "Idle"
local session_game_state = "None"
local session_stage = nil
local locase_session_stage = nil
local session_stage_change_time = nil
local current_history = nil
local current_history_stage = nil
local last_update_time = nil
local last_save_time = nil


-- "Forward declarations" of all local functions, to prevent issues with definition vs calling order.
-- Please maintain this in the same order as the function definitions.
-- Yes, it does not look nice, and if the names here do not match the actual function names exactly, the mismatching definitions will become global functions.
-- Yes, Lua is an ugly language.

local start
local tick
-- local autokick
local update_member_ping
local handle_member_attributes
local addon_callback

local member_ping_sum = {}
local member_ping_count = {}
local member_ping_warning = {}
local member_ping_avg = {}
local counter = 0
local seconds = config.grab_seconds
local warnings = config.warnings


local to_kick = {}


-- Start AMS2_BOT
function start()

	last_update_time = GetServerUptimeMs()	
	
end

function autokick( refId )
	local now = GetServerUptimeMs() 	
	if to_kick[ refId ] == nil then
		to_kick[ refId ] = now + 10000
		if debug then print( "ams2_bot: Added " .. refId .. " to autokick batch." ) end
	end
	
end

-- Regular update tick.
function tick()
	-- print( "ams2_bot: Tick" )
	-- If we have members to kick for high ping, process them here.
	local now = GetServerUptimeMs() 
	for refId, time in pairs( to_kick ) do
		if now >= time then	
			if debug then print( "ams2_bot: Kicking " .. refId )	end	
			KickMember( refId )
			to_kick[ refId ] = nil
		end
	end
	-- No-op until started
	if not last_update_time then
		return
	end
	-- Check time elapsed, process only after 1s
	local now = GetServerUptimeMs()
	local delta_ms = now - last_update_time
	if delta_ms < TICK_UPDATE_DELTA_MS then
		return
	end
	local delta_secs = delta_ms / 1000
	last_update_time = now

	
end
-- Update history member's setup.
function update_member_ping( member )
	if config.BOT_HighPingKicker then
		counter = counter + 1 
		if member.attributes.Ping > 0 and counter == seconds then
			counter = 1
			if member_ping_count[ member.refid ] == nil then
				member_ping_count[ member.refid ] = 1
				member_ping_avg[ member.refid ] = member.attributes.Ping
				member_ping_sum[ member.refid ] = member.attributes.Ping
				member_ping_warning[ member.refid ] = 0	
				else
					member_ping_count[ member.refid ] = member_ping_count[ member.refid ] + 1
			end
			
			member_ping_sum[ member.refid ] = member_ping_sum[ member.refid ] + member.attributes.Ping
			member_ping_avg[ member.refid ] = member_ping_sum[ member.refid ] / member_ping_count[ member.refid ]
		
			if member_ping_avg[ member.refid ] >= config.ping_limit_ms then
					member_ping_warning[ member.refid ] = member_ping_warning[ member.refid ] + 1
					SendChatToMember( member.refid,  "[AMS2_BOT] Warning " .. member_ping_warning[ member.refid ] .. " of " .. warnings .. ", AVG Ping is " .. math.floor(math.abs(member_ping_avg[ member.refid ])) ..'ms. Limit is ' ..  config.ping_limit_ms .. 'ms.' )
			end
			if member_ping_warning[ member.refid ] >= warnings then
				SendChatToMember( member.refid,  "[AMS2_BOT] You're being kicked for high ping, avg " .. math.floor(math.abs(member_ping_avg[ member.refid ])) ..'ms. Limit is ' ..  config.ping_limit_ms .. 'ms.')
				SendChatToMember( member.refid,  "[AMS2_BOT] Please check running apps, background processes etc before joining again. Bye")
				autokick( member.refid )
				if debug then print( "ams2_bot: Adding " .. member.refid .. " to autokick..") end	
			end
		end
	end	
end

-- Server state changes.
function handle_server_state_change( old_state, new_state )
	server_state = new_state
	if new_state == "Starting" then
		start()
	end
end

-- Member attribute changes.
function handle_member_attributes( refid, attribute_names )
	local member = session.members[ refid ]
	if member then
		update_member_ping( member )		
	end
end

-- Main addon callback
function addon_callback( callback, ... )

	-- Regular tick
	if callback == Callback.Tick then
		tick()
	end

	-- Member attribute changes.
	if callback == Callback.MemberAttributesChanged then
		local refid, attribute_names = ...		
		handle_member_attributes( refid, attribute_names )
	end

end

RegisterCallback( addon_callback )
EnableCallback( Callback.Tick )
EnableCallback( Callback.MemberAttributesChanged )

-- EOF --
