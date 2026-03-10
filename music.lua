-- cc-music v3
-- Self-hosted ComputerCraft streaming music
-- https://github.com/j-shelfwood/cc-music
local api_base_url = "https://cc-music.shelfwood.co/api/"
local version = "3.0"

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

local monitor = peripheral.find("monitor")

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

    -- Progress display
    elapsed  = 0,         -- seconds played this track
    duration = 0,         -- total seconds (parsed from artist string), 0 = unknown

    -- Status flags
    is_loading    = false, -- waiting for first segment of a new track
    is_buffering  = false, -- waiting for a subsequent segment mid-track
    is_error      = false,
    error_message = nil,   -- server error message to display in row 5

    -- Search
    last_search     = nil,
    last_search_url = nil,
    search_results  = nil,
    search_error    = false,
    search_page     = 0,
    waiting_input   = false,

    -- UI
    action_result = nil,  -- index into search_results for overlay, or nil
    queue_scroll  = 0,    -- top visible queue index (0-based)
}

-- ─── Constants ─────────────────────────────────────────────────────────────────

local CHUNK_SIZE      = 16 * 1024
local RESULTS_PER_PAGE = 5
local CTRL_ROW  = 7
local VOL_ROW   = 9
local SEP_ROW   = 10
local QUEUE_ROW = 11
local LOOP_COL  = 16

-- ─── Helpers ───────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function truncate(s, maxlen)
    if #s <= maxlen then return s end
    return s:sub(1, maxlen - 2) .. ".."
end

local function shuffleTable(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

local function volPercent()
    return math.floor(100 * (S.volume / 3) + 0.5)
end

local function fmtTime(secs)
    secs = math.floor(secs)
    local m = math.floor(secs / 60)
    local s = secs % 60
    return string.format("%d:%02d", m, s)
end

-- Parse duration in seconds from the "3:45 · Artist" artist field.
-- Returns 0 if not parseable.
local function parseDuration(artist_str)
    if not artist_str then return 0 end
    local h, m, s = artist_str:match("^(%d+):(%d+):(%d+)")
    if h then return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) end
    local m2, s2 = artist_str:match("^(%d+):(%d+)")
    if m2 then return tonumber(m2)*60 + tonumber(s2) end
    return 0
end

local function stopSpeakers()
    for _, sp in ipairs(speakers) do sp.stop() end
    os.queueEvent("playback_stopped")
end

local function queueEvent(e) os.queueEvent(e) end

-- ─── Terminal drawing helpers ──────────────────────────────────────────────────

local function twrite(x, y, text, fg, bg)
    term.setCursorPos(x, y)
    if fg then term.setTextColor(fg) end
    if bg then term.setBackgroundColor(bg) end
    term.write(text)
end

local function tfill(x, y, w, fg, bg, char)
    term.setCursorPos(x, y)
    if fg then term.setTextColor(fg) end
    if bg then term.setBackgroundColor(bg) end
    term.write(string.rep(char or " ", w))
end

local function button(x, y, label, active)
    term.setCursorPos(x, y)
    term.setTextColor(active and colors.black or colors.white)
    term.setBackgroundColor(active and colors.cyan or colors.gray)
    term.write(label)
end

-- ─── Header ───────────────────────────────────────────────────────────────────

local function drawHeader()
    tfill(1, 1, S.W, colors.white, colors.black)
    twrite(2, 1, "cc-music", colors.cyan, colors.black)

    local tabs = {" Now Playing ", " Search "}
    local tx = S.W
    for i = #tabs, 1, -1 do
        tx = tx - #tabs[i]
        term.setCursorPos(tx + 1, 1)
        term.setTextColor(S.tab == i and colors.black or colors.lightGray)
        term.setBackgroundColor(S.tab == i and colors.cyan or colors.black)
        term.write(tabs[i])
    end

    tfill(1, 2, S.W, colors.cyan, colors.cyan)
end

-- ─── Now Playing tab ──────────────────────────────────────────────────────────

local function drawNowPlaying()
    term.setBackgroundColor(colors.black)

    -- Rows 3-4: track title and artist
    if S.now_playing then
        twrite(2, 3, truncate(S.now_playing.name,   S.W - 2), colors.white,     colors.black)
        twrite(2, 4, truncate(S.now_playing.artist, S.W - 2), colors.lightGray, colors.black)
    else
        twrite(2, 3, "Nothing playing", colors.lightGray, colors.black)
        tfill( 2, 4, S.W - 2, colors.black, colors.black)
    end

    -- Row 5: progress / status
    tfill(2, 5, S.W - 2, colors.black, colors.black)
    if S.is_error then
        local err_text = S.error_message
            and truncate(S.error_message, S.W - 2)
            or "Network error — skip or retry"
        twrite(2, 5, err_text, colors.red, colors.black)
    elseif S.is_loading then
        twrite(2, 5, "Loading...", colors.gray, colors.black)
    elseif S.is_buffering then
        twrite(2, 5, "Buffering...", colors.gray, colors.black)
    elseif S.playing and S.now_playing then
        local elapsed_str = fmtTime(S.elapsed)
        local progress
        if S.duration > 0 then
            progress = elapsed_str .. " / " .. fmtTime(S.duration)
        else
            progress = elapsed_str
        end
        twrite(2, 5, progress, colors.cyan, colors.black)
    end

    -- Row 6: blank
    tfill(1, 6, S.W, colors.black, colors.black)

    -- Row 7: transport controls
    tfill(1, CTRL_ROW, S.W, colors.black, colors.black)
    local has_track = S.now_playing ~= nil or #S.queue > 0
    if S.playing then
        button(2, CTRL_ROW, " Stop ", true)
    else
        term.setCursorPos(2, CTRL_ROW)
        term.setTextColor(has_track and colors.white or colors.gray)
        term.setBackgroundColor(colors.gray)
        term.write(" Play ")
    end

    term.setCursorPos(9, CTRL_ROW)
    term.setTextColor(has_track and colors.white or colors.gray)
    term.setBackgroundColor(colors.gray)
    term.write(" Skip ")

    local loop_labels = {[0]=" Loop ",[1]=" Loop Q ",[2]=" Loop 1 "}
    local shuf_col = LOOP_COL + #loop_labels[S.looping] + 1
    button(LOOP_COL, CTRL_ROW, loop_labels[S.looping], S.looping ~= 0)
    button(shuf_col, CTRL_ROW, " Shuf ", S.shuffle)

    -- Row 8: blank
    tfill(1, 8, S.W, colors.black, colors.black)

    -- Row 9: volume bar
    local bar_w = S.W - 10
    local filled = math.floor(bar_w * (S.volume / 3) + 0.5)
    term.setCursorPos(2, VOL_ROW)
    term.setTextColor(colors.cyan)
    term.setBackgroundColor(colors.black)
    for i = 1, bar_w do
        term.write(i <= filled and "\x7c" or "-")
    end
    twrite(bar_w + 3, VOL_ROW, "Vol " .. volPercent() .. "%  ", colors.lightGray, colors.black)

    -- Row 10: separator
    term.setCursorPos(1, SEP_ROW)
    term.setTextColor(colors.gray)
    term.setBackgroundColor(colors.black)
    term.write(string.rep("-", S.W))

    -- Row 11+: queue
    tfill(1, QUEUE_ROW, S.W, colors.black, colors.black)
    if #S.queue == 0 then
        twrite(2, QUEUE_ROW, "Queue empty", colors.gray, colors.black)
    else
        local cq_label = " Clear queue "
        twrite(S.W - #cq_label, QUEUE_ROW, cq_label, colors.lightGray, colors.gray)
        twrite(2, QUEUE_ROW, "Up next (" .. #S.queue .. "):", colors.lightGray, colors.black)

        local visible = S.H - QUEUE_ROW
        for i = 1, math.min(visible, #S.queue) do
            local qi = i + S.queue_scroll
            if qi > #S.queue then break end
            local row = QUEUE_ROW + i
            tfill(1, row, S.W, colors.black, colors.black)
            local rm = "[x]"
            twrite(S.W - #rm + 1, row, rm, colors.red, colors.black)
            twrite(2, row, truncate(S.queue[qi].name, S.W - #rm - 3), colors.white, colors.black)
        end

        local drawn = math.min(visible, #S.queue)
        for r = QUEUE_ROW + drawn + 1, S.H do
            tfill(1, r, S.W, colors.black, colors.black)
        end
    end
end

-- ─── Search tab ───────────────────────────────────────────────────────────────

local function visibleResults()
    if not S.search_results then return {} end
    local start = S.search_page * RESULTS_PER_PAGE + 1
    local stop  = math.min(start + RESULTS_PER_PAGE - 1, #S.search_results)
    local out = {}
    for i = start, stop do out[#out + 1] = {item = S.search_results[i], idx = i} end
    return out
end

local function drawSearch()
    term.setBackgroundColor(colors.black)

    local box_bg = S.waiting_input and colors.white or colors.lightGray
    local box_fg = S.waiting_input and colors.black or colors.gray
    for row = 3, 5 do tfill(2, row, S.W - 2, box_fg, box_bg) end
    twrite(3, 4, truncate(S.last_search or "Search for a song or paste a YouTube URL...", S.W - 4),
           S.waiting_input and colors.black or colors.gray, box_bg)

    tfill(1, 6, S.W, colors.black, colors.black)
    if S.search_results and #S.search_results > RESULTS_PER_PAGE then
        local total_pages = math.ceil(#S.search_results / RESULTS_PER_PAGE)
        twrite(2, 6, "Page " .. (S.search_page + 1) .. "/" .. total_pages, colors.gray, colors.black)
        if S.search_page > 0 then
            button(S.W - 14, 6, " < Prev ", false)
        end
        if S.search_page < total_pages - 1 then
            button(S.W - 6, 6, " Next >", false)
        end
    end

    local vis = visibleResults()
    for i = 1, RESULTS_PER_PAGE do
        local base_row = 7 + (i - 1) * 2
        tfill(1, base_row,     S.W, colors.black, colors.black)
        tfill(1, base_row + 1, S.W, colors.black, colors.black)
        if vis[i] then
            twrite(2, base_row,     truncate(vis[i].item.name,   S.W - 2), colors.white,     colors.black)
            twrite(2, base_row + 1, truncate(vis[i].item.artist, S.W - 2), colors.lightGray, colors.black)
        end
    end

    local last_result_row = 7 + RESULTS_PER_PAGE * 2
    for r = last_result_row, S.H do tfill(1, r, S.W, colors.black, colors.black) end

    if not S.search_results then
        tfill(1, 7, S.W, colors.black, colors.black)
        if S.search_error then
            twrite(2, 7, "Network error", colors.red, colors.black)
        elseif S.last_search_url then
            twrite(2, 7, "Searching...", colors.lightGray, colors.black)
        else
            twrite(2, 7, "Tip: paste YouTube video or playlist URLs", colors.gray, colors.black)
        end
    end

    if S.action_result then
        local item = S.search_results[S.action_result]
        local panel_top = S.H - 5
        for r = panel_top, S.H do tfill(1, r, S.W, colors.black, colors.gray) end
        twrite(2, panel_top,     truncate(item.name,   S.W - 2), colors.white,     colors.gray)
        twrite(2, panel_top + 1, truncate(item.artist, S.W - 2), colors.lightGray, colors.gray)
        button(2,       panel_top + 3, " Play now ",  true)
        button(13,      panel_top + 3, " Play next ", false)
        button(25,      panel_top + 3, " + Queue ",   false)
        button(S.W - 8, panel_top + 3, " Cancel ",    false)
    end
end

-- ─── Redraw ────────────────────────────────────────────────────────────────────

local function redrawScreen()
    if S.waiting_input then return end
    S.W, S.H = term.getSize()
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()
    drawHeader()
    if S.tab == 1 then drawNowPlaying() else drawSearch() end
end

-- ─── Monitor display ───────────────────────────────────────────────────────────

local function drawMonitor()
    if not monitor then return end
    pcall(function()
        local mw, mh = monitor.getSize()
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        pcall(function()
            monitor.setTextScale(mw >= 30 and 1.5 or 1)
            mw, mh = monitor.getSize()
        end)

        local function mwrite(x, y, text, fg, bg)
            monitor.setCursorPos(x, y)
            if fg then monitor.setTextColor(fg) end
            if bg then monitor.setBackgroundColor(bg) end
            monitor.write(text)
        end
        local function mfill(y, fg, bg)
            monitor.setCursorPos(1, y)
            monitor.setTextColor(fg)
            monitor.setBackgroundColor(bg)
            monitor.write(string.rep(" ", mw))
        end

        mfill(1, colors.black, colors.cyan)
        mwrite(2, 1, "cc-music", colors.black, colors.cyan)
        if mh < 4 then return end
        mfill(2, colors.cyan, colors.cyan)

        if not S.now_playing then
            mwrite(2, 3, "Nothing playing", colors.lightGray, colors.black)
            return
        end

        mwrite(2, 3, "NOW PLAYING", colors.cyan, colors.black)
        mwrite(2, 4, truncate(S.now_playing.name,   mw - 2), colors.white,     colors.black)
        if mh >= 5 then
            mwrite(2, 5, truncate(S.now_playing.artist, mw - 2), colors.lightGray, colors.black)
        end
        if mh >= 7 then
            local status
            if S.is_loading   then status = "Loading..."
            elseif S.is_buffering then status = "Buffering..."
            elseif S.is_error then status = "Error"
            elseif S.playing  then
                status = fmtTime(S.elapsed)
                if S.duration > 0 then status = status .. "/" .. fmtTime(S.duration) end
            else
                status = "Paused"
            end
            mwrite(2, 7, status .. "  Vol:" .. volPercent() .. "%", colors.gray, colors.black)
        end
        if mh >= 9 and #S.queue > 0 then
            mwrite(2, 9, "Up next:", colors.lightGray, colors.black)
            for i = 1, math.min(3, #S.queue) do
                if 9 + i <= mh then
                    mwrite(2, 9 + i, truncate(i .. ". " .. S.queue[i].name, mw - 2), colors.gray, colors.black)
                end
            end
        end
    end)
end

local function monitorLoop()
    if not monitor then
        while true do os.pullEvent("redraw_monitor") end
    end
    drawMonitor()
    while true do
        os.pullEvent("redraw_monitor")
        drawMonitor()
    end
end

local function signalRedraw()
    queueEvent("redraw_screen")
    queueEvent("redraw_monitor")
end

-- ─── Queue / playback helpers ──────────────────────────────────────────────────

local function enqueueItem(item)
    if S.shuffle and #S.queue > 0 then
        table.insert(S.queue, math.random(#S.queue + 1), item)
    else
        table.insert(S.queue, item)
    end
end

local function enqueuePlaylist(playlist, front)
    local items = playlist.playlist_items
    if front then
        for i = #items, 1, -1 do table.insert(S.queue, 1, items[i]) end
    else
        for i = 1, #items do enqueueItem(items[i]) end
    end
end

local function startTrack(item)
    S.elapsed  = 0
    S.duration = parseDuration(item.artist)
end

local function playNow(item_or_playlist)
    stopSpeakers()
    S.playing       = true
    S.is_error      = false
    S.error_message = nil
    S.playing_id    = nil
    S.queue      = {}

    if item_or_playlist.type == "playlist" then
        local items = item_or_playlist.playlist_items
        S.now_playing = items[1]
        for i = 2, #items do enqueueItem(items[i]) end
    else
        S.now_playing = item_or_playlist
    end
    startTrack(S.now_playing)
    queueEvent("audio_update")
end

local function skipTrack()
    if not S.now_playing and #S.queue == 0 then return end
    S.is_error      = false
    S.error_message = nil
    if S.playing then stopSpeakers() end
    if #S.queue > 0 then
        if S.looping == 1 and S.now_playing then table.insert(S.queue, S.now_playing) end
        S.now_playing = table.remove(S.queue, 1)
        S.playing_id  = nil
        startTrack(S.now_playing)
    else
        S.now_playing = nil
        S.playing     = false
        S.is_loading  = false
        S.playing_id  = nil
        S.elapsed     = 0
        S.duration    = 0
    end
    queueEvent("audio_update")
end

-- ─── Audio: speaker playback ───────────────────────────────────────────────────

local function playChunkOnSpeakers(buf)
    local fns = {}
    for i, sp in ipairs(speakers) do
        local sp_ref  = sp
        local sp_name = peripheral.getName(sp_ref)
        fns[i] = function()
            if #speakers > 1 then
                if sp_ref.playAudio(buf, S.volume) then
                    parallel.waitForAny(
                        function()
                            repeat until select(2, os.pullEvent("speaker_audio_empty")) == sp_name
                        end,
                        function() os.pullEvent("playback_stopped") end
                    )
                    if not S.playing or S.playing_id ~= sp_name then return end
                end
            else
                while not sp_ref.playAudio(buf, S.volume) do
                    parallel.waitForAny(
                        function()
                            repeat until select(2, os.pullEvent("speaker_audio_empty")) == sp_name
                        end,
                        function() os.pullEvent("playback_stopped") end
                    )
                    if not S.playing then return end
                end
            end
        end
    end
    return pcall(parallel.waitForAll, table.unpack(fns))
end

-- ─── Audio loop ────────────────────────────────────────────────────────────────

local function requestSegment(id, offset)
    local url = api_base_url .. "?v=" .. version
                .. "&id=" .. textutils.urlEncode(id)
                .. "&offset=" .. offset
    S.last_download_url = url
    http.request({url = url, binary = true})
end

local function audioLoop()
    while true do
        if S.playing and S.now_playing then
            local this_id = S.now_playing.id

            if S.playing_id ~= this_id then
                S.playing_id      = this_id
                S.audio_offset    = 0
                S.audio_has_more  = false
                S.segment_ready   = false
                S.decoder         = dfpwm.make_decoder()
                requestSegment(S.playing_id, 0)
                S.is_loading = true
                signalRedraw()
                queueEvent("audio_update")

            elseif S.segment_ready then
                while true do
                    local chunk = S.player_handle:read(CHUNK_SIZE)

                    if not chunk then
                        S.player_handle:close()
                        S.segment_ready = false

                        if S.audio_has_more and S.playing and S.playing_id == this_id then
                            requestSegment(S.playing_id, S.audio_offset)
                            S.is_buffering = true
                            signalRedraw()
                            break
                        end

                        -- Track ended — advance queue
                        if S.looping == 2 or (S.looping == 1 and #S.queue == 0) then
                            S.playing_id = nil
                            S.audio_offset = 0
                            S.elapsed = 0
                        elseif S.looping == 1 and #S.queue > 0 then
                            table.insert(S.queue, S.now_playing)
                            S.now_playing  = table.remove(S.queue, 1)
                            S.playing_id   = nil
                            S.audio_offset = 0
                            startTrack(S.now_playing)
                        elseif #S.queue > 0 then
                            S.now_playing  = table.remove(S.queue, 1)
                            S.playing_id   = nil
                            S.audio_offset = 0
                            startTrack(S.now_playing)
                        else
                            S.now_playing   = nil
                            S.playing       = false
                            S.playing_id    = nil
                            S.audio_offset  = 0
                            S.is_loading    = false
                            S.is_buffering  = false
                            S.is_error      = false
                            S.error_message = nil
                            S.elapsed       = 0
                            S.duration      = 0
                        end
                        signalRedraw()
                        break
                    end

                    local decoded = S.decoder(chunk)

                    -- Elapsed time: each CHUNK_SIZE bytes = CHUNK_SIZE/6000 seconds
                    -- DFPWM at 48kHz = 6000 bytes/sec
                    S.elapsed = S.elapsed + CHUNK_SIZE / 6000

                    local ok = playChunkOnSpeakers(decoded)
                    if not ok then
                        S.playing       = false
                        S.playing_id    = nil
                        S.segment_ready = false
                        S.is_error      = true
                        signalRedraw()
                        break
                    end

                    if not S.playing or S.playing_id ~= this_id then break end
                end
                queueEvent("audio_update")
            end
        end

        os.pullEvent("audio_update")
    end
end

-- ─── HTTP loop ─────────────────────────────────────────────────────────────────

local function httpLoop()
    while true do
        parallel.waitForAny(
            function()
                local _, url, handle = os.pullEvent("http_success")

                if url == S.last_search_url then
                    S.search_results = textutils.unserialiseJSON(handle.readAll())
                    handle.close()
                    S.search_page = 0
                    signalRedraw()
                elseif url == S.last_download_url then
                    local headers     = handle.getResponseHeaders()
                    local has_more    = (headers and headers["X-More"] == "1")
                    local next_offset = tonumber(headers and headers["X-Next-Offset"]) or S.audio_offset
                    local data = handle.readAll()
                    handle.close()
                    local fh = { _data = data, _pos = 1,
                                 read  = function(self, n)
                                     if self._pos > #self._data then return nil end
                                     local s = self._data:sub(self._pos, self._pos + n - 1)
                                     self._pos = self._pos + #s
                                     return #s > 0 and s or nil
                                 end,
                                 close = function() end }
                    S.audio_has_more  = has_more
                    S.audio_offset    = next_offset
                    S.is_loading      = false
                    S.is_buffering    = false
                    S.player_handle   = fh
                    S.segment_ready   = true
                    signalRedraw()
                    queueEvent("audio_update")
                end
            end,
            function()
                local _, url, fail_handle = os.pullEvent("http_failure")

                if url == S.last_search_url then
                    S.search_error = true
                    signalRedraw()
                elseif url == S.last_download_url then
                    -- Try to extract server error message from the failure handle
                    local err_msg = nil
                    if fail_handle then
                        pcall(function()
                            local code = fail_handle.getResponseCode and fail_handle:getResponseCode()
                            local body = fail_handle.readAll and fail_handle:readAll()
                            if body and #body > 0 then
                                err_msg = (code and ("[" .. code .. "] ") or "") .. body
                            elseif code then
                                err_msg = "HTTP " .. code
                            end
                            fail_handle:close()
                        end)
                    end
                    S.is_loading    = false
                    S.is_buffering  = false
                    S.is_error      = true
                    S.error_message = err_msg
                    S.playing       = false
                    S.playing_id    = nil
                    signalRedraw()
                    queueEvent("audio_update")
                end
            end
        )
    end
end

-- ─── UI event handlers ─────────────────────────────────────────────────────────

local function handleNowPlayingMouse(x, y)
    if y == CTRL_ROW then
        if x >= 2 and x <= 7 then
            -- Play / Stop
            if S.playing then
                S.playing    = false
                S.is_loading = false
                S.is_buffering = false
                S.is_error   = false
                stopSpeakers()
                S.playing_id = nil
            elseif S.now_playing ~= nil then
                S.playing_id    = nil
                S.playing       = true
                S.is_error      = false
                S.error_message = nil
            elseif #S.queue > 0 then
                S.now_playing   = table.remove(S.queue, 1)
                S.playing_id    = nil
                S.playing       = true
                S.is_error      = false
                S.error_message = nil
                startTrack(S.now_playing)
            end
            queueEvent("audio_update")

        elseif x >= 9 and x <= 14 then
            skipTrack()

        else
            local loop_labels = {[0]=" Loop ",[1]=" Loop Q ",[2]=" Loop 1 "}
            local loop_end = LOOP_COL + #loop_labels[S.looping] - 1
            local shuf_col = loop_end + 2
            local shuf_end = shuf_col + #" Shuf " - 1
            if x >= LOOP_COL and x <= loop_end then
                S.looping = (S.looping + 1) % 3
            elseif x >= shuf_col and x <= shuf_end then
                S.shuffle = not S.shuffle
                if S.shuffle and #S.queue > 1 then shuffleTable(S.queue) end
            end
        end

    elseif y == VOL_ROW then
        local bar_w = S.W - 10
        if x >= 2 and x <= bar_w + 1 then
            S.volume = clamp((x - 2) / (bar_w - 1) * 3, 0, 3)
        end

    elseif y == QUEUE_ROW and #S.queue > 0 then
        local cq_label = " Clear queue "
        if x >= S.W - #cq_label then
            S.queue = {}
            S.queue_scroll = 0
        end

    elseif y > QUEUE_ROW and #S.queue > 0 then
        local qi = (y - QUEUE_ROW) + S.queue_scroll
        if qi >= 1 and qi <= #S.queue then
            local rm = "[x]"
            if x >= S.W - #rm + 1 then
                table.remove(S.queue, qi)
                S.queue_scroll = clamp(S.queue_scroll, 0, math.max(0, #S.queue - 1))
            end
        end
    end
end

local function handleSearchMouse(x, y)
    if S.action_result then
        local panel_top = S.H - 5
        if y == panel_top + 3 then
            local item = S.search_results[S.action_result]
            if x >= 2 and x <= 11 then
                S.action_result = nil
                playNow(item)
            elseif x >= 13 and x <= 23 then
                S.action_result = nil
                if item.type == "playlist" then enqueuePlaylist(item, true)
                else table.insert(S.queue, 1, item) end
                queueEvent("audio_update")
            elseif x >= 25 and x <= 33 then
                S.action_result = nil
                if item.type == "playlist" then enqueuePlaylist(item, false)
                else enqueueItem(item) end
                queueEvent("audio_update")
            elseif x >= S.W - 8 then
                S.action_result = nil
            end
        elseif y < panel_top then
            S.action_result = nil
        end
        return
    end

    if y >= 3 and y <= 5 then
        S.waiting_input = true
        return
    end

    if y == 6 and S.search_results and #S.search_results > RESULTS_PER_PAGE then
        local total_pages = math.ceil(#S.search_results / RESULTS_PER_PAGE)
        if x >= S.W - 14 and x <= S.W - 7 and S.search_page > 0 then
            S.search_page = S.search_page - 1
        elseif x >= S.W - 6 and S.search_page < total_pages - 1 then
            S.search_page = S.search_page + 1
        end
        return
    end

    if S.search_results then
        local vis = visibleResults()
        for i, entry in ipairs(vis) do
            local base_row = 7 + (i - 1) * 2
            if y == base_row or y == base_row + 1 then
                S.action_result = entry.idx
                return
            end
        end
    end
end

local function doSearch(query)
    S.search_results = nil
    S.search_error   = false
    S.search_page    = 0
    if query and #query > 0 then
        S.last_search = query
        -- URLs must not be double-encoded — only encode non-URL queries
        local encoded = query:match("^https?://") and query or textutils.urlEncode(query)
        S.last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. encoded
        http.request(S.last_search_url)
    else
        S.last_search     = nil
        S.last_search_url = nil
    end
end

-- ─── UI loop ───────────────────────────────────────────────────────────────────

local function uiLoop()
    S.W, S.H = term.getSize()
    redrawScreen()

    while true do
        if S.waiting_input then
            parallel.waitForAny(
                function()
                    for row = 3, 5 do
                        term.setCursorPos(2, row)
                        term.setBackgroundColor(colors.white)
                        term.setTextColor(colors.black)
                        term.clearLine()
                    end
                    term.setCursorPos(3, 4)
                    local input = read()
                    S.waiting_input = false
                    doSearch(input)
                    signalRedraw()
                end,
                function()
                    while S.waiting_input do
                        local _, _, cx, cy = os.pullEvent("mouse_click")
                        if cy < 3 or cy > 5 then
                            S.waiting_input = false
                            signalRedraw()
                            break
                        end
                    end
                end
            )
        else
            parallel.waitForAny(
                function()
                    local _, btn, x, y = os.pullEvent("mouse_click")
                    if btn ~= 1 then return end
                    if y == 1 and S.action_result == nil then
                        S.tab = x < S.W / 2 and 1 or 2
                        signalRedraw()
                        return
                    end
                    if S.tab == 1 then handleNowPlayingMouse(x, y)
                    else handleSearchMouse(x, y) end
                    signalRedraw()
                end,
                function()
                    local _, btn, x, y = os.pullEvent("mouse_drag")
                    if btn == 1 and S.tab == 1 and y == VOL_ROW then
                        local bar_w = S.W - 10
                        if x >= 2 and x <= bar_w + 1 then
                            S.volume = clamp((x - 2) / (bar_w - 1) * 3, 0, 3)
                            signalRedraw()
                        end
                    end
                end,
                function()
                    local _, dir, _, y = os.pullEvent("mouse_scroll")
                    if S.tab == 1 and y >= QUEUE_ROW and #S.queue > 0 then
                        S.queue_scroll = clamp(S.queue_scroll + dir, 0, math.max(0, #S.queue - 1))
                        signalRedraw()
                    elseif S.tab == 2 and S.search_results then
                        local total_pages = math.ceil(#S.search_results / RESULTS_PER_PAGE)
                        S.search_page = clamp(S.search_page + dir, 0, total_pages - 1)
                        signalRedraw()
                    end
                end,
                function()
                    -- 1-second timer for progress display tick
                    local timer_id = os.startTimer(1)
                    while true do
                        local ev, id = os.pullEvent("timer")
                        if id == timer_id then
                            if S.playing and S.now_playing and not S.is_loading and not S.is_buffering then
                                signalRedraw()
                            end
                            timer_id = os.startTimer(1)
                        end
                    end
                end,
                function()
                    os.pullEvent("redraw_screen")
                    redrawScreen()
                end
            )
        end
    end
end

-- ─── Run ───────────────────────────────────────────────────────────────────────

local startup_args = {...}
if #startup_args > 0 then
    doSearch(table.concat(startup_args, " "))
end

parallel.waitForAny(uiLoop, audioLoop, httpLoop, monitorLoop)
