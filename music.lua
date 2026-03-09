-- cc-music v3
-- Self-hosted ComputerCraft streaming music
-- https://github.com/j-shelfwood/cc-music
local api_base_url = "https://cc-music.shelfwood.co/api/"
local version = "3.0"

-- ─── Peripheral discovery ──────────────────────────────────────────────────────

local function findAllSpeakers()
    local found = {}
    local seen = {}
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name)
        if t == "speaker" and not seen[name] then
            seen[name] = true
            table.insert(found, peripheral.wrap(name))
        end
        -- wired modem: scan its network
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

local W, H = term.getSize()
local tab = 1  -- 1 = Now Playing, 2 = Search

-- Playback
local playing       = false
local now_playing   = nil
local queue         = {}
local looping       = 0   -- 0=off 1=queue 2=song
local shuffle       = false
local volume        = 1.5

-- Internal playback state
local CHUNK_SIZE        = 16 * 1024  -- bytes per audio read
local dfpwm             = require("cc.audio.dfpwm")
local playing_id        = nil
local last_download_url = nil
local playing_status    = 0
local is_loading        = false
local is_error          = false
local player_handle     = nil
local decoder           = dfpwm.make_decoder()  -- reset per track to clear filter state
local needs_next_chunk  = 0
local audio_buffer      = nil
local audio_offset      = 0   -- byte offset for segmented download
local audio_seg_offset  = 0   -- offset of the segment currently being fetched (cache key)
local audio_has_more    = false  -- server signalled more segments follow

-- Search
local last_search       = nil
local last_search_url   = nil
local search_results    = nil
local search_error      = false
local search_page       = 0   -- 0-indexed, 5 per page
local RESULTS_PER_PAGE  = 5
local waiting_input     = false

-- Song action overlay
local action_result     = nil  -- index into search_results, or nil

-- Queue interaction
local queue_scroll      = 0   -- top visible queue index (0-based)

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
    return math.floor(100 * (volume / 3) + 0.5)
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
    local fg = active and colors.black or colors.white
    local bg = active and colors.cyan  or colors.gray
    term.setCursorPos(x, y)
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.write(label)
end

-- ─── Header row ───────────────────────────────────────────────────────────────

local function drawHeader()
    -- Row 1: dark header bar
    tfill(1, 1, W, colors.white, colors.black)
    twrite(2, 1, "cc-music", colors.cyan, colors.black)

    -- Tab buttons right-aligned
    local tabs = {" Now Playing ", " Search "}
    local tx = W
    for i = #tabs, 1, -1 do
        tx = tx - #tabs[i]
        local active = (tab == i)
        term.setCursorPos(tx + 1, 1)
        term.setTextColor(active and colors.black or colors.lightGray)
        term.setBackgroundColor(active and colors.cyan or colors.black)
        term.write(tabs[i])
    end

    -- Row 2: cyan accent line
    tfill(1, 2, W, colors.cyan, colors.cyan)
end

-- ─── Now Playing tab ──────────────────────────────────────────────────────────

local CTRL_ROW   = 7
local VOL_ROW    = 9
local SEP_ROW    = 10
local QUEUE_ROW  = 11
local LOOP_COL   = 16  -- fixed start column for loop button
-- SHUF_COL is dynamic: LOOP_COL + len(loop_label) + 1

local function drawNowPlaying()
    term.setBackgroundColor(colors.black)

    -- Track info rows 3-5
    if now_playing then
        twrite(2, 3, truncate(now_playing.name,   W - 2), colors.white,     colors.black)
        twrite(2, 4, truncate(now_playing.artist, W - 2), colors.lightGray, colors.black)
    else
        twrite(2, 3, "Nothing playing", colors.lightGray, colors.black)
        tfill( 2, 4, W - 2, colors.black, colors.black)
    end

    -- Row 5: status
    tfill(2, 5, W - 2, colors.black, colors.black)
    if is_loading then
        twrite(2, 5, "Loading...", colors.gray, colors.black)
    elseif is_error then
        twrite(2, 5, "Network error — skip or retry", colors.red, colors.black)
    end

    -- Row 6: blank
    tfill(1, 6, W, colors.black, colors.black)

    -- Row 7: controls
    tfill(1, CTRL_ROW, W, colors.black, colors.black)
    local has_track = now_playing ~= nil or #queue > 0
    if playing then
        button(2, CTRL_ROW, " Stop ", true)
    else
        local fg = has_track and colors.white or colors.gray
        term.setCursorPos(2, CTRL_ROW)
        term.setTextColor(fg); term.setBackgroundColor(colors.gray)
        term.write(" Play ")
    end

    local skip_fg = has_track and colors.white or colors.gray
    term.setCursorPos(9, CTRL_ROW)
    term.setTextColor(skip_fg); term.setBackgroundColor(colors.gray)
    term.write(" Skip ")

    -- Loop button (3 states)
    local loop_labels = {[0]=" Loop ",[1]=" Loop Q ",[2]=" Loop 1 "}
    local loop_active = looping ~= 0
    local shuf_col = LOOP_COL + #loop_labels[looping] + 1
    button(LOOP_COL, CTRL_ROW, loop_labels[looping], loop_active)

    -- Shuffle button
    button(shuf_col, CTRL_ROW, " Shuf ", shuffle)

    -- Row 8: blank
    tfill(1, 8, W, colors.black, colors.black)

    -- Row 9: volume bar
    local bar_w = W - 10  -- leave room for "Vol 100%"
    local filled = math.floor(bar_w * (volume / 3) + 0.5)
    term.setCursorPos(2, VOL_ROW)
    term.setTextColor(colors.cyan)
    term.setBackgroundColor(colors.black)
    for i = 1, bar_w do
        if i <= filled then
            term.write("\x7c")  -- solid bar
        else
            term.write("-")
        end
    end
    twrite(bar_w + 3, VOL_ROW, "Vol " .. volPercent() .. "%  ", colors.lightGray, colors.black)

    -- Row 10: separator
    tfill(1, SEP_ROW, W, colors.black, colors.black)
    term.setCursorPos(1, SEP_ROW)
    term.setTextColor(colors.gray)
    term.setBackgroundColor(colors.black)
    term.write(string.rep("-", W))

    -- Row 11+: queue
    tfill(1, QUEUE_ROW, W, colors.black, colors.black)
    if #queue == 0 then
        twrite(2, QUEUE_ROW, "Queue empty", colors.gray, colors.black)
    else
        -- Clear queue button
        local cq_label = " Clear queue "
        twrite(W - #cq_label, QUEUE_ROW, cq_label, colors.lightGray, colors.gray)
        twrite(2, QUEUE_ROW, "Up next (" .. #queue .. "):", colors.lightGray, colors.black)

        local visible = H - QUEUE_ROW  -- rows available below header
        for i = 1, math.min(visible, #queue) do
            local qi = i + queue_scroll
            if qi > #queue then break end
            local row = QUEUE_ROW + i
            tfill(1, row, W, colors.black, colors.black)
            -- remove button at right
            local rm = "[x]"
            twrite(W - #rm + 1, row, rm, colors.red, colors.black)
            twrite(2, row, truncate(queue[qi].name, W - #rm - 3), colors.white, colors.black)
        end

        -- clear any rows below
        local drawn = math.min(visible, #queue)
        for r = QUEUE_ROW + drawn + 1, H do
            tfill(1, r, W, colors.black, colors.black)
        end
    end
end

-- ─── Search tab ───────────────────────────────────────────────────────────────

local function visibleResults()
    if not search_results then return {} end
    local start = search_page * RESULTS_PER_PAGE + 1
    local stop  = math.min(start + RESULTS_PER_PAGE - 1, #search_results)
    local out = {}
    for i = start, stop do out[#out + 1] = {item = search_results[i], idx = i} end
    return out
end

local function drawSearch()
    term.setBackgroundColor(colors.black)

    -- Search box rows 3-5
    local box_bg = waiting_input and colors.white or colors.lightGray
    local box_fg = waiting_input and colors.black or colors.gray
    for row = 3, 5 do tfill(2, row, W - 2, box_fg, box_bg) end
    twrite(3, 4, truncate(last_search or "Search for a song or paste a YouTube URL...", W - 4),
           waiting_input and colors.black or colors.gray,
           box_bg)

    -- Row 6: pagination controls (only when results exist)
    tfill(1, 6, W, colors.black, colors.black)
    if search_results and #search_results > RESULTS_PER_PAGE then
        local total_pages = math.ceil(#search_results / RESULTS_PER_PAGE)
        local pg_label = "Page " .. (search_page + 1) .. "/" .. total_pages
        twrite(2, 6, pg_label, colors.gray, colors.black)
        if search_page > 0 then
            button(W - 14, 6, " < Prev ", false)
        end
        if search_page < total_pages - 1 then
            button(W - 6, 6, " Next >", false)
        end
    end

    -- Rows 7+: results
    local vis = visibleResults()
    for i = 1, RESULTS_PER_PAGE do
        local base_row = 7 + (i - 1) * 2
        tfill(1, base_row,     W, colors.black, colors.black)
        tfill(1, base_row + 1, W, colors.black, colors.black)
        if vis[i] then
            twrite(2, base_row,     truncate(vis[i].item.name,   W - 2), colors.white,     colors.black)
            twrite(2, base_row + 1, truncate(vis[i].item.artist, W - 2), colors.lightGray, colors.black)
        end
    end

    -- Clear below results
    local last_result_row = 7 + RESULTS_PER_PAGE * 2
    for r = last_result_row, H do tfill(1, r, W, colors.black, colors.black) end

    if not search_results then
        tfill(1, 7, W, colors.black, colors.black)
        if search_error then
            twrite(2, 7, "Network error", colors.red, colors.black)
        elseif last_search_url then
            twrite(2, 7, "Searching...", colors.lightGray, colors.black)
        else
            twrite(2, 7, "Tip: paste YouTube video or playlist URLs", colors.gray, colors.black)
        end
    end

    -- Action overlay (bottom panel)
    if action_result then
        local item = search_results[action_result]
        local panel_top = H - 5
        for r = panel_top, H do tfill(1, r, W, colors.black, colors.gray) end
        twrite(2, panel_top,     truncate(item.name,   W - 2), colors.white,     colors.gray)
        twrite(2, panel_top + 1, truncate(item.artist, W - 2), colors.lightGray, colors.gray)
        button(2,      panel_top + 3, " Play now ", true)
        button(13,     panel_top + 3, " Play next ", false)
        button(25,     panel_top + 3, " + Queue ", false)
        button(W - 8,  panel_top + 3, " Cancel ", false)
    end
end

-- ─── Main redraw ───────────────────────────────────────────────────────────────

local function redrawScreen()
    if waiting_input then return end
    W, H = term.getSize()
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()
    drawHeader()
    if tab == 1 then
        drawNowPlaying()
    else
        drawSearch()
    end
end

-- ─── Monitor display ───────────────────────────────────────────────────────────

local function drawMonitor()
    if not monitor then return end
    local ok, err = pcall(function()
        local mw, mh = monitor.getSize()
        monitor.setBackgroundColor(colors.black)
        monitor.clear()

        -- Try to fit text scale
        -- (setTextScale only valid 0.5-5; skip error if not advanced monitor)
        pcall(function()
            if mw >= 30 then
                monitor.setTextScale(1.5)
                mw, mh = monitor.getSize()
            else
                monitor.setTextScale(1)
                mw, mh = monitor.getSize()
            end
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

        -- Header
        mfill(1, colors.black, colors.cyan)
        mwrite(2, 1, "cc-music", colors.black, colors.cyan)

        if mh < 4 then return end

        mfill(2, colors.cyan, colors.cyan)

        if not now_playing then
            mwrite(2, 3, "Nothing playing", colors.lightGray, colors.black)
            return
        end

        -- Track info
        local title  = truncate(now_playing.name,   mw - 2)
        local artist = truncate(now_playing.artist, mw - 2)
        mwrite(2, 3, "NOW PLAYING", colors.cyan, colors.black)
        mwrite(2, 4, title,         colors.white, colors.black)
        if mh >= 5 then
            mwrite(2, 5, artist, colors.lightGray, colors.black)
        end

        if mh >= 7 then
            -- Status / volume
            local status = playing and "Playing" or "Paused"
            if is_loading then status = "Loading..." end
            if is_error   then status = "Error" end
            mwrite(2, 7, status .. "  Vol: " .. volPercent() .. "%", colors.gray, colors.black)
        end

        if mh >= 9 and #queue > 0 then
            mwrite(2, 9, "Up next:", colors.lightGray, colors.black)
            for i = 1, math.min(3, #queue) do
                if 9 + i <= mh then
                    mwrite(2, 9 + i, truncate(i .. ". " .. queue[i].name, mw - 2),
                           colors.gray, colors.black)
                end
            end
        end
    end)
    -- silently ignore monitor errors (disconnected etc.)
end

local function monitorLoop()
    if not monitor then
        -- no monitor — just sleep forever, don't block other loops
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

-- ─── Queue helpers ─────────────────────────────────────────────────────────────

local function enqueueItem(item)
    if shuffle and #queue > 0 then
        local pos = math.random(#queue + 1)
        table.insert(queue, pos, item)
    else
        table.insert(queue, item)
    end
end

local function enqueuePlaylist(playlist, front)
    local items = playlist.playlist_items
    if front then
        for i = #items, 1, -1 do table.insert(queue, 1, items[i]) end
    else
        for i = 1, #items do enqueueItem(items[i]) end
    end
end

local function playNow(item_or_playlist)
    stopSpeakers()
    playing    = true
    is_error   = false
    playing_id = nil
    queue      = {}

    if item_or_playlist.type == "playlist" then
        local items = item_or_playlist.playlist_items
        now_playing = items[1]
        for i = 2, #items do enqueueItem(items[i]) end
    else
        now_playing = item_or_playlist
    end
    queueEvent("audio_update")
end

local function skipTrack()
    if not now_playing and #queue == 0 then return end
    is_error = false
    if playing then stopSpeakers() end
    if #queue > 0 then
        if looping == 1 and now_playing then table.insert(queue, now_playing) end
        now_playing = table.remove(queue, 1)
        playing_id  = nil
    else
        now_playing = nil
        playing     = false
        is_loading  = false
        playing_id  = nil
    end
    queueEvent("audio_update")
end

-- ─── UI loop ───────────────────────────────────────────────────────────────────

local function handleNowPlayingClick(x, y)
    if y == CTRL_ROW then
        -- Play/Stop (cols 2-7)
        if x >= 2 and x <= 7 then
            if playing then
                playing = false
                stopSpeakers()
                playing_id = nil
                is_loading = false
                is_error   = false
            elseif now_playing ~= nil then
                playing_id = nil
                playing    = true
                is_error   = false
            elseif #queue > 0 then
                now_playing = table.remove(queue, 1)
                playing_id  = nil
                playing     = true
                is_error    = false
            end
            queueEvent("audio_update")

        -- Skip (cols 9-14)
        elseif x >= 9 and x <= 14 then
            skipTrack()

        -- Loop button: LOOP_COL to LOOP_COL + label_len - 1
        else
            local loop_labels = {[0]=" Loop ",[1]=" Loop Q ",[2]=" Loop 1 "}
            local loop_end  = LOOP_COL + #loop_labels[looping] - 1
            local shuf_col  = loop_end + 2
            local shuf_end  = shuf_col + #" Shuf " - 1
            if x >= LOOP_COL and x <= loop_end then
                looping = (looping + 1) % 3
            elseif x >= shuf_col and x <= shuf_end then
                shuffle = not shuffle
                if shuffle and #queue > 1 then shuffleTable(queue) end
            end
        end

    elseif y == VOL_ROW then
        -- Volume bar (cols 2 to bar_w+1)
        local bar_w = W - 10
        if x >= 2 and x <= bar_w + 1 then
            volume = clamp((x - 2) / (bar_w - 1) * 3, 0, 3)
        end

    elseif y == QUEUE_ROW and #queue > 0 then
        -- Clear queue button (right side)
        local cq_label = " Clear queue "
        if x >= W - #cq_label then
            queue = {}
            queue_scroll = 0
        end

    elseif y > QUEUE_ROW and #queue > 0 then
        -- Queue item rows
        local qi = (y - QUEUE_ROW) + queue_scroll
        if qi >= 1 and qi <= #queue then
            local rm = "[x]"
            if x >= W - #rm + 1 then
                -- remove this item
                table.remove(queue, qi)
                queue_scroll = clamp(queue_scroll, 0, math.max(0, #queue - 1))
            end
        end
    end
end

local function handleSearchClick(x, y)
    if action_result then
        -- Action panel interactions (bottom 6 rows)
        local panel_top = H - 5
        if y == panel_top + 3 then
            local item = search_results[action_result]
            if x >= 2 and x <= 11 then
                -- Play now
                action_result = nil
                playNow(item)
            elseif x >= 13 and x <= 23 then
                -- Play next
                action_result = nil
                if item.type == "playlist" then
                    enqueuePlaylist(item, true)
                else
                    table.insert(queue, 1, item)
                end
                queueEvent("audio_update")
            elseif x >= 25 and x <= 33 then
                -- Add to queue
                action_result = nil
                if item.type == "playlist" then
                    enqueuePlaylist(item, false)
                else
                    enqueueItem(item)
                end
                queueEvent("audio_update")
            elseif x >= W - 8 then
                action_result = nil
            end
        elseif y < panel_top then
            action_result = nil  -- click outside panel = cancel
        end
        return
    end

    -- Search box
    if y >= 3 and y <= 5 then
        waiting_input = true
        return
    end

    -- Pagination buttons (row 6)
    if y == 6 and search_results and #search_results > RESULTS_PER_PAGE then
        local total_pages = math.ceil(#search_results / RESULTS_PER_PAGE)
        if x >= W - 14 and x <= W - 7 and search_page > 0 then
            search_page = search_page - 1
        elseif x >= W - 6 and search_page < total_pages - 1 then
            search_page = search_page + 1
        end
        return
    end

    -- Result rows
    if search_results then
        local vis = visibleResults()
        for i, entry in ipairs(vis) do
            local base_row = 7 + (i - 1) * 2
            if y == base_row or y == base_row + 1 then
                action_result = entry.idx
                return
            end
        end
    end
end

local function doSearch(query)
    if query and #query > 0 then
        last_search     = query
        last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(query)
        http.request(last_search_url)
        search_results  = nil
        search_error    = false
        search_page     = 0
    else
        last_search     = nil
        last_search_url = nil
        search_results  = nil
        search_error    = false
        search_page     = 0
    end
end

local function uiLoop()
    redrawScreen()

    while true do
        if waiting_input then
            -- Input mode for search
            parallel.waitForAny(
                function()
                    -- Draw active search box
                    for row = 3, 5 do
                        term.setCursorPos(2, row)
                        term.setBackgroundColor(colors.white)
                        term.setTextColor(colors.black)
                        term.clearLine()
                    end
                    term.setCursorPos(3, 4)
                    local input = read()
                    waiting_input = false
                    doSearch(input)
                    signalRedraw()
                end,
                function()
                    -- Allow clicking outside box to cancel input
                    while waiting_input do
                        local _, _, cx, cy = os.pullEvent("mouse_click")
                        if cy < 3 or cy > 5 then
                            waiting_input = false
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

                    -- Tab switching (row 1)
                    if y == 1 and action_result == nil then
                        if x < W / 2 then
                            tab = 1
                        else
                            tab = 2
                        end
                        signalRedraw()
                        return
                    end

                    if tab == 1 then
                        handleNowPlayingClick(x, y)
                    else
                        handleSearchClick(x, y)
                    end
                    signalRedraw()
                end,
                function()
                    -- Volume drag on now-playing tab
                    local _, btn, x, y = os.pullEvent("mouse_drag")
                    if btn == 1 and tab == 1 and y == VOL_ROW then
                        local bar_w = W - 10
                        if x >= 2 and x <= bar_w + 1 then
                            volume = clamp((x - 2) / (bar_w - 1) * 3, 0, 3)
                            signalRedraw()
                        end
                    end
                end,
                function()
                    -- Scroll wheel for queue (tab 1) or results (tab 2)
                    local _, dir, x, y = os.pullEvent("mouse_scroll")
                    if tab == 1 and y >= QUEUE_ROW and #queue > 0 then
                        queue_scroll = clamp(queue_scroll + dir, 0, math.max(0, #queue - 1))
                        signalRedraw()
                    elseif tab == 2 and search_results then
                        local total_pages = math.ceil(#search_results / RESULTS_PER_PAGE)
                        search_page = clamp(search_page + dir, 0, total_pages - 1)
                        signalRedraw()
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

-- ─── Segment cache ─────────────────────────────────────────────────────────────
--
-- Stores raw DFPWM segment files on the computer's local filesystem.
-- Layout:
--   .cc-music/<video_id>/<offset>        -- raw binary segment
--   .cc-music/<video_id>/<offset>.meta   -- "1" if X-More, next offset on second line
--   .cc-music/index                      -- newline-separated video IDs, oldest first
--
-- Max MAX_CACHED_TRACKS tracks kept; oldest evicted when limit exceeded.
-- Each track can be up to ~10 segments (≈4.5MB) but we don't cap per-track size.

local CACHE_DIR        = ".cc-music"
local MAX_CACHED_TRACKS = 10

local function cachePath(id, offset)
    return CACHE_DIR .. "/" .. id .. "/" .. offset
end

local function cacheMetaPath(id, offset)
    return cachePath(id, offset) .. ".meta"
end

local function cacheReadIndex()
    local f = fs.open(CACHE_DIR .. "/index", "r")
    if not f then return {} end
    local ids = {}
    local line = f.readLine()
    while line do
        if #line > 0 then ids[#ids + 1] = line end
        line = f.readLine()
    end
    f.close()
    return ids
end

local function cacheWriteIndex(ids)
    fs.makeDir(CACHE_DIR)
    local f = fs.open(CACHE_DIR .. "/index", "w")
    if not f then return end
    for _, id in ipairs(ids) do f.writeLine(id) end
    f.close()
end

local function cacheTouchTrack(id)
    -- Move id to the end (most-recently-used), evict oldest if over limit
    local ids = cacheReadIndex()
    -- Remove existing entry
    local new = {}
    for _, v in ipairs(ids) do
        if v ~= id then new[#new + 1] = v end
    end
    new[#new + 1] = id
    -- Evict oldest entries if over limit
    while #new > MAX_CACHED_TRACKS do
        local evict = table.remove(new, 1)
        if fs.exists(CACHE_DIR .. "/" .. evict) then
            fs.delete(CACHE_DIR .. "/" .. evict)
        end
    end
    cacheWriteIndex(new)
end

local function cacheHasSegment(id, offset)
    return fs.exists(cachePath(id, offset))
end

local function cacheReadMeta(id, offset)
    local f = fs.open(cacheMetaPath(id, offset), "r")
    if not f then return false, offset end
    local has_more   = f.readLine() == "1"
    local next_off   = tonumber(f.readLine()) or offset
    f.close()
    return has_more, next_off
end

local function cacheWriteSegment(id, offset, data, has_more, next_offset)
    fs.makeDir(CACHE_DIR .. "/" .. id)
    local f = fs.open(cachePath(id, offset), "wb")
    if not f then return end
    f.write(data)
    f.close()
    local mf = fs.open(cacheMetaPath(id, offset), "w")
    if not mf then return end
    mf.writeLine(has_more and "1" or "0")
    mf.writeLine(tostring(next_offset))
    mf.close()
    cacheTouchTrack(id)
end

local function cacheOpenSegment(id, offset)
    -- Returns a file handle compatible with player_handle (.read / .close)
    return fs.open(cachePath(id, offset), "rb")
end

-- ─── Audio loop ────────────────────────────────────────────────────────────────

local function requestSegment(id, offset)
    audio_seg_offset = offset
    -- Serve from cache if available
    if cacheHasSegment(id, offset) then
        local fh = cacheOpenSegment(id, offset)
        if fh then
            local has_more, next_off = cacheReadMeta(id, offset)
            audio_has_more = has_more
            audio_offset   = next_off
            is_loading     = false
            player_handle  = fh
            playing_status = 1
            cacheTouchTrack(id)
            signalRedraw()
            queueEvent("audio_update")
            return
        end
        -- Cache file unreadable — fall through to HTTP
    end
    local url = api_base_url .. "?v=" .. version
                .. "&id=" .. textutils.urlEncode(id)
                .. "&offset=" .. offset
    last_download_url = url
    http.request({url = url, binary = true})
end

local function audioLoop()
    while true do
        if playing and now_playing then
            local this_id = now_playing.id

            if playing_id ~= this_id then
                playing_id       = this_id
                audio_offset     = 0
                audio_seg_offset = 0
                audio_has_more   = false
                playing_status   = 0
                needs_next_chunk = 1
                decoder          = dfpwm.make_decoder()  -- fresh state per track
                requestSegment(playing_id, 0)
                is_loading = true
                signalRedraw()
                queueEvent("audio_update")

            elseif playing_status == 1 and needs_next_chunk == 1 then
                while true do
                    local chunk = player_handle.read(CHUNK_SIZE)

                    if not chunk then
                        -- Segment exhausted
                        player_handle.close()
                        needs_next_chunk = 0

                        if audio_has_more and playing and playing_id == this_id then
                            -- More segments: fetch next, stay on same track
                            playing_status   = 0
                            needs_next_chunk = 1
                            requestSegment(playing_id, audio_offset)
                            is_loading = true
                            signalRedraw()
                            break
                        end

                        -- Track truly ended
                        if looping == 2 or (looping == 1 and #queue == 0) then
                            playing_id   = nil  -- replay same song
                            audio_offset = 0
                        elseif looping == 1 and #queue > 0 then
                            table.insert(queue, now_playing)
                            now_playing  = table.remove(queue, 1)
                            playing_id   = nil
                            audio_offset = 0
                        elseif #queue > 0 then
                            now_playing  = table.remove(queue, 1)
                            playing_id   = nil
                            audio_offset = 0
                        else
                            now_playing  = nil
                            playing      = false
                            playing_id   = nil
                            audio_offset = 0
                            is_loading   = false
                            is_error     = false
                        end
                        signalRedraw()
                        break
                    end

                    audio_buffer = decoder(chunk)

                    -- Play on all speakers in parallel, using current volume upvalue
                    local fns = {}
                    for i, sp in ipairs(speakers) do
                        local sp_ref  = sp
                        local sp_name = peripheral.getName(sp_ref)
                        fns[i] = function()
                            if #speakers > 1 then
                                if sp_ref.playAudio(audio_buffer, volume) then
                                    parallel.waitForAny(
                                        function()
                                            repeat until select(2, os.pullEvent("speaker_audio_empty")) == sp_name
                                        end,
                                        function() os.pullEvent("playback_stopped") end
                                    )
                                    if not playing or playing_id ~= this_id then return end
                                end
                            else
                                while not sp_ref.playAudio(audio_buffer, volume) do
                                    parallel.waitForAny(
                                        function()
                                            repeat until select(2, os.pullEvent("speaker_audio_empty")) == sp_name
                                        end,
                                        function() os.pullEvent("playback_stopped") end
                                    )
                                    if not playing or playing_id ~= this_id then return end
                                end
                            end
                            if not playing or playing_id ~= this_id then return end
                        end
                    end

                    local ok, _ = pcall(parallel.waitForAll, table.unpack(fns))
                    if not ok then
                        -- Speaker error — stop playback cleanly
                        playing          = false
                        playing_id       = nil
                        needs_next_chunk = 0
                        is_error         = true
                        signalRedraw()
                        break
                    end

                    if not playing or playing_id ~= this_id then break end
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

                if url == last_search_url then
                    search_results = textutils.unserialiseJSON(handle.readAll())
                    handle.close()
                    search_page = 0
                    signalRedraw()
                elseif url == last_download_url then
                    local headers     = handle.getResponseHeaders()
                    local has_more    = (headers and headers["X-More"] == "1")
                    local next_offset = tonumber(headers and headers["X-Next-Offset"]) or audio_offset
                    -- Read all bytes so we can write to cache; HTTP handles can't be re-read
                    local data = handle.readAll()
                    handle.close()
                    cacheWriteSegment(playing_id, audio_seg_offset, data, has_more, next_offset)
                    local fh = cacheOpenSegment(playing_id, audio_seg_offset)
                    if not fh then
                        -- Cache write failed (disk full?) — fall back to in-memory string handle
                        fh = { _data = data, _pos = 1,
                               read  = function(self, n)
                                   if self._pos > #self._data then return nil end
                                   local s = self._data:sub(self._pos, self._pos + n - 1)
                                   self._pos = self._pos + #s
                                   return #s > 0 and s or nil
                               end,
                               close = function() end }
                    end
                    audio_has_more = has_more
                    audio_offset   = next_offset
                    is_loading     = false
                    player_handle  = fh
                    playing_status = 1
                    signalRedraw()
                    queueEvent("audio_update")
                end
            end,
            function()
                local _, url = os.pullEvent("http_failure")

                if url == last_search_url then
                    search_error = true
                    signalRedraw()
                elseif url == last_download_url then
                    is_loading = false
                    is_error   = true
                    playing    = false
                    playing_id = nil
                    signalRedraw()
                    queueEvent("audio_update")
                end
            end
        )
    end
end

-- ─── Run ───────────────────────────────────────────────────────────────────────

-- If launched with a URL or search term (e.g. mpm startup cc-music <url>)
-- trigger an immediate search before the event loops start.
-- shell.run word-splits args, so multi-word terms arrive as separate varargs.
local startup_args = {...}
if #startup_args > 0 then
    doSearch(table.concat(startup_args, " "))
end

parallel.waitForAny(uiLoop, audioLoop, httpLoop, monitorLoop)
