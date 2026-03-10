-- cc-music v4
-- Self-hosted ComputerCraft streaming music
-- https://github.com/j-shelfwood/cc-music

local dfpwm = require("cc.audio.dfpwm")

-- ─── Peripheral discovery ──────────────────────────────────────────────────────

local function findAllSpeakers()
    local found, seen = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name)
        if t == "speaker" and not seen[name] then
            seen[name] = true
            table.insert(found, peripheral.wrap(name))
        end
        if t == "modem" then
            local modem = peripheral.wrap(name)
            if modem and modem.getNamesRemote then
                for _, rname in ipairs(modem.getNamesRemote()) do
                    if modem.getTypeRemote(rname) == "speaker" and not seen[rname] then
                        seen[rname] = true
                        table.insert(found, peripheral.wrap(rname))
                    end
                end
            end
        end
    end
    return found
end

local speakers = findAllSpeakers()
if #speakers == 0 then
    error("No speakers found. Connect a speaker directly or via wired modem.", 0)
end

-- ─── Helpers ───────────────────────────────────────────────────────────────────

local function parseDuration(artist_str)
    if not artist_str then return 0 end
    local h, m, s = artist_str:match("^(%d+):(%d+):(%d+)")
    if h then return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) end
    local m2, s2 = artist_str:match("^(%d+):(%d+)")
    if m2 then return tonumber(m2)*60 + tonumber(s2) end
    return 0
end

-- ─── State ─────────────────────────────────────────────────────────────────────

local S = {
    -- Screen
    W = 0, H = 0,
    tab = 1,              -- 1 = Now Playing, 2 = Search

    -- Playback (user-facing)
    playing     = false,
    now_playing = nil,
    queue       = {},
    looping     = 0,      -- 0=off 1=queue 2=song
    shuffle     = false,
    volume      = 1.5,

    -- Playback (internal)
    playing_id        = nil,
    segment_ready     = false,
    player_handle     = nil,
    decoder           = dfpwm.make_decoder(),
    audio_offset      = 0,
    audio_has_more    = false,
    last_download_url = nil,

    -- Progress
    elapsed      = 0,    -- seconds played this track
    duration     = 0,    -- total seconds (parsed from artist string), 0 = unknown
    chunk_in_seg = 0,    -- chunks decoded in current segment
    seg_count    = 0,    -- segments fetched this track

    -- Status flags
    is_loading    = false,
    is_buffering  = false,
    is_error      = false,
    error_message = nil,

    -- Search
    last_search     = nil,
    last_search_url = nil,
    search_results  = nil,
    search_error    = false,
    search_page     = 0,
    waiting_input   = false,

    -- UI
    action_result = nil,
    queue_scroll  = 0,

    -- Shared helper used by audio.lua for queue advancement after track end
    parseDuration = parseDuration,

    -- startup_query: set before parallel.waitForAny so uiLoop can pick it up
    startup_query = nil,
}

-- ─── Load modules ──────────────────────────────────────────────────────────────

-- stopSpeakers is implemented in audio.lua but needed by ui.lua.
-- Use a forwarding stub so ui.lua can call it before audio is fully initialised.
local stopSpeakers_ref = {}
local function stopSpeakers()
    if stopSpeakers_ref.fn then stopSpeakers_ref.fn() end
end

local ui_mod    = require("ui")
local audio_mod = require("audio")

local ui    = ui_mod.init(S, speakers, stopSpeakers)
local audio = audio_mod.init(S, speakers, ui.signalRedraw)

-- Wire the real stopSpeakers into the stub
stopSpeakers_ref.fn = audio.stopSpeakers

-- ─── Startup search ────────────────────────────────────────────────────────────

local startup_args = {...}
if #startup_args > 0 then
    S.startup_query = table.concat(startup_args, " ")
end

-- ─── Run ───────────────────────────────────────────────────────────────────────

parallel.waitForAny(ui.uiLoop, ui.monitorLoop, audio.audioLoop, audio.httpLoop)
