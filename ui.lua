-- cc-music UI module
-- Terminal and monitor drawing, input handling, UI loops.

local M = {}

function M.init(S, speakers, stopSpeakers)

    local CHUNK_SIZE     = 16 * 1024
    local CHUNKS_PER_SEG = math.floor(458752 / CHUNK_SIZE) -- = 28
    local RESULTS_PER_PAGE = 5
    local CTRL_ROW  = 8
    local VOL_ROW   = 10
    local SEP_ROW   = 11
    local QUEUE_ROW = 12
    local LOOP_COL  = 16

    -- ── Helpers ──────────────────────────────────────────────────────────────

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

    local function parseDuration(artist_str)
        if not artist_str then return 0 end
        local h, m, s = artist_str:match("^(%d+):(%d+):(%d+)")
        if h then return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) end
        local m2, s2 = artist_str:match("^(%d+):(%d+)")
        if m2 then return tonumber(m2)*60 + tonumber(s2) end
        return 0
    end

    -- ── Terminal drawing helpers ──────────────────────────────────────────────

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

    -- ── Header ────────────────────────────────────────────────────────────────

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

    -- ── Now Playing tab ───────────────────────────────────────────────────────

    local function drawNowPlaying()
        term.setBackgroundColor(colors.black)

        -- Rows 3-4: title and artist
        if S.now_playing then
            twrite(2, 3, truncate(S.now_playing.name,   S.W - 2), colors.white,     colors.black)
            twrite(2, 4, truncate(S.now_playing.artist, S.W - 2), colors.lightGray, colors.black)
        else
            twrite(2, 3, "Nothing playing", colors.lightGray, colors.black)
            tfill( 2, 4, S.W - 2, colors.black, colors.black)
        end

        -- Row 5: progress bar / status
        tfill(1, 5, S.W, colors.black, colors.black)
        if S.is_error then
            local err_text = S.error_message
                and truncate(S.error_message, S.W - 2)
                or "Network error — skip or retry"
            twrite(2, 5, err_text, colors.red, colors.black)
        elseif S.is_loading then
            twrite(2, 5, "Loading...", colors.gray, colors.black)
        elseif S.is_buffering then
            twrite(2, 5, "Buffering seg " .. (S.seg_count + 1) .. "...", colors.gray, colors.black)
        elseif S.playing and S.now_playing then
            local elapsed_str = fmtTime(S.elapsed)
            if S.duration > 0 then
                -- progress bar + time
                local bar_w  = S.W - 22
                local filled = math.max(0, math.min(bar_w, math.floor(bar_w * S.elapsed / S.duration)))
                term.setCursorPos(2, 5)
                term.setTextColor(colors.cyan)
                term.setBackgroundColor(colors.black)
                term.write("[")
                for i = 1, bar_w do
                    term.write(i <= filled and "\x7c" or "-")
                end
                term.write("] ")
                term.write(elapsed_str .. " / " .. fmtTime(S.duration))
            else
                twrite(2, 5, elapsed_str, colors.cyan, colors.black)
            end
        end

        -- Row 6: chunk/segment counter
        tfill(1, 6, S.W, colors.black, colors.black)
        if S.playing and S.now_playing and not S.is_loading and not S.is_buffering and not S.is_error then
            local info = "Chunk " .. S.chunk_in_seg .. "/" .. CHUNKS_PER_SEG
                      .. "   Seg " .. S.seg_count
            twrite(2, 6, info, colors.gray, colors.black)
        end

        -- Row 7: blank
        tfill(1, 7, S.W, colors.black, colors.black)

        -- Row 8: transport controls
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

        -- Row 9: blank
        tfill(1, 9, S.W, colors.black, colors.black)

        -- Row 10: volume bar
        local bar_w = S.W - 10
        local filled = math.floor(bar_w * (S.volume / 3) + 0.5)
        term.setCursorPos(2, VOL_ROW)
        term.setTextColor(colors.cyan)
        term.setBackgroundColor(colors.black)
        for i = 1, bar_w do
            term.write(i <= filled and "\x7c" or "-")
        end
        twrite(bar_w + 3, VOL_ROW, "Vol " .. volPercent() .. "%  ", colors.lightGray, colors.black)

        -- Row 11: separator
        term.setCursorPos(1, SEP_ROW)
        term.setTextColor(colors.gray)
        term.setBackgroundColor(colors.black)
        term.write(string.rep("-", S.W))

        -- Row 12+: queue
        tfill(1, QUEUE_ROW, S.W, colors.black, colors.black)
        if #S.queue == 0 then
            twrite(2, QUEUE_ROW, "Queue empty  —  search YouTube on the Search tab", colors.gray, colors.black)
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

    -- ── Search tab ────────────────────────────────────────────────────────────

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

        -- Search box border (rows 3-5)
        local inner_w = S.W - 4  -- 2 margin each side
        if S.waiting_input then
            -- Active: white background, cursor prompt
            twrite(2, 3, "+" .. string.rep("-", inner_w) .. "+", colors.gray, colors.black)
            tfill(2, 4, inner_w + 2, colors.black, colors.white)
            twrite(3, 4, "> ", colors.gray, colors.white)
            twrite(2, 5, "+" .. string.rep("-", inner_w) .. "+", colors.gray, colors.black)
        else
            -- Inactive: dim border, clickable hint
            twrite(2, 3, "+" .. string.rep("-", inner_w) .. "+", colors.gray, colors.black)
            tfill(2, 4, inner_w + 2, colors.gray, colors.lightGray)
            local placeholder = S.last_search or "Search YouTube or paste a URL..."
            twrite(3, 4, "> " .. truncate(placeholder, inner_w - 2), colors.gray, colors.lightGray)
            twrite(2, 5, "+" .. string.rep("-", inner_w) .. "+", colors.gray, colors.black)
        end

        -- Row 6: hint / status / pagination
        tfill(1, 6, S.W, colors.black, colors.black)
        if S.waiting_input then
            twrite(2, 6, "[Enter] search  [click outside] cancel", colors.gray, colors.black)
        elseif S.search_results and #S.search_results > RESULTS_PER_PAGE then
            local total_pages = math.ceil(#S.search_results / RESULTS_PER_PAGE)
            twrite(2, 6, "Page " .. (S.search_page + 1) .. "/" .. total_pages, colors.gray, colors.black)
            if S.search_page > 0 then
                button(S.W - 14, 6, " < Prev ", false)
            end
            if S.search_page < total_pages - 1 then
                button(S.W - 6, 6, " Next >", false)
            end
        elseif not S.search_results then
            if S.search_error then
                twrite(2, 6, "Network error", colors.red, colors.black)
            elseif S.last_search_url then
                twrite(2, 6, "Searching...", colors.lightGray, colors.black)
            else
                twrite(2, 6, "Tip: paste a YouTube URL or type to search", colors.gray, colors.black)
            end
        end

        -- Results (rows 7+)
        local vis = visibleResults()
        for i = 1, RESULTS_PER_PAGE do
            local base_row = 7 + (i - 1) * 2
            tfill(1, base_row,     S.W, colors.black, colors.black)
            tfill(1, base_row + 1, S.W, colors.black, colors.black)
            if vis[i] then
                twrite(2, base_row,     truncate(vis[i].item.name,   S.W - 2), colors.white,     colors.black)
                -- Artist row with right-aligned [play] hint
                local artist_str = truncate(vis[i].item.artist, S.W - 10)
                twrite(2, base_row + 1, artist_str, colors.lightGray, colors.black)
                twrite(S.W - 6, base_row + 1, " [play]", colors.gray, colors.black)
            end
        end

        local last_result_row = 7 + RESULTS_PER_PAGE * 2
        for r = last_result_row, S.H do tfill(1, r, S.W, colors.black, colors.black) end

        -- Action panel overlay
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

    -- ── Redraw ────────────────────────────────────────────────────────────────

    local function redrawScreen()
        if S.waiting_input then return end
        S.W, S.H = term.getSize()
        term.setCursorBlink(false)
        term.setBackgroundColor(colors.black)
        term.clear()
        drawHeader()
        if S.tab == 1 then drawNowPlaying() else drawSearch() end
    end

    local function signalRedraw()
        os.queueEvent("redraw_screen")
        os.queueEvent("redraw_monitor")
    end

    -- ── Monitor ───────────────────────────────────────────────────────────────

    local monitor = peripheral.find("monitor")
    local monitor_side = monitor and peripheral.getName(monitor) or nil

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

            -- Row 1: header + touch buttons
            mfill(1, colors.black, colors.cyan)
            mwrite(2, 1, "cc-music", colors.black, colors.cyan)
            -- Touch zone: [||] play/pause at mw-6..mw-4, [>>] skip at mw-3..mw
            local pp_label = S.playing and "[||]" or "[ >]"
            mwrite(mw - 7, 1, pp_label, colors.black, S.playing and colors.orange or colors.green)
            mwrite(mw - 3, 1, "[>>]", colors.black, colors.gray)

            if mh < 4 then return end
            mfill(2, colors.cyan, colors.cyan)

            if not S.now_playing then
                mwrite(2, 3, "Nothing playing", colors.lightGray, colors.black)
                mwrite(2, 4, "Use terminal to search", colors.gray, colors.black)
                return
            end

            mwrite(2, 3, "NOW PLAYING", colors.cyan, colors.black)
            mwrite(2, 4, truncate(S.now_playing.name,   mw - 2), colors.white,     colors.black)
            if mh >= 5 then
                mwrite(2, 5, truncate(S.now_playing.artist, mw - 2), colors.lightGray, colors.black)
            end
            if mh >= 7 then
                local status
                if S.is_loading     then status = "Loading..."
                elseif S.is_buffering then status = "Buffering seg " .. (S.seg_count + 1) .. "..."
                elseif S.is_error   then status = "Error"
                elseif S.playing    then
                    status = fmtTime(S.elapsed)
                    if S.duration > 0 then status = status .. " / " .. fmtTime(S.duration) end
                else
                    status = "Paused"
                end
                mwrite(2, 7, status .. "   Vol:" .. volPercent() .. "%", colors.gray, colors.black)
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

    -- ── Queue / playback helpers ──────────────────────────────────────────────

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
        S.queue         = {}

        if item_or_playlist.type == "playlist" then
            local items = item_or_playlist.playlist_items
            S.now_playing = items[1]
            for i = 2, #items do enqueueItem(items[i]) end
        else
            S.now_playing = item_or_playlist
        end
        startTrack(S.now_playing)
        os.queueEvent("audio_update")
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
        os.queueEvent("audio_update")
    end

    local function doSearch(query)
        local api_base_url = "https://cc-music.shelfwood.co/api/"
        local version      = "3.0"
        S.search_results = nil
        S.search_error   = false
        S.search_page    = 0
        if query and #query > 0 then
            S.last_search = query
            local encoded = query:match("^https?://") and query or textutils.urlEncode(query)
            S.last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. encoded
            http.request(S.last_search_url)
        else
            S.last_search     = nil
            S.last_search_url = nil
        end
    end

    -- ── Mouse handlers ────────────────────────────────────────────────────────

    local function handleNowPlayingMouse(x, y)
        if y == CTRL_ROW then
            if x >= 2 and x <= 7 then
                -- Play / Stop
                if S.playing then
                    S.playing      = false
                    S.is_loading   = false
                    S.is_buffering = false
                    S.is_error     = false
                    stopSpeakers()
                    S.playing_id   = nil
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
                os.queueEvent("audio_update")

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
                    os.queueEvent("audio_update")
                elseif x >= 25 and x <= 33 then
                    S.action_result = nil
                    if item.type == "playlist" then enqueuePlaylist(item, false)
                    else enqueueItem(item) end
                    os.queueEvent("audio_update")
                elseif x >= S.W - 8 then
                    S.action_result = nil
                end
            elseif y < panel_top then
                S.action_result = nil
            end
            return
        end

        -- Search box rows 3-5: click anywhere to activate input
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

    -- ── Monitor loop (display + touch) ────────────────────────────────────────

    local function monitorLoop()
        if not monitor then
            while true do os.pullEvent("redraw_monitor") end
        end
        drawMonitor()
        while true do
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "redraw_monitor" then
                drawMonitor()
            elseif ev == "monitor_touch" and p1 == monitor_side then
                -- p2=x, p3=y
                local mw = select(1, monitor.getSize())
                if p3 == 1 then
                    -- play/pause zone
                    if p2 >= mw - 7 and p2 <= mw - 4 then
                        if S.playing then
                            S.playing      = false
                            S.is_loading   = false
                            S.is_buffering = false
                            stopSpeakers()
                            S.playing_id   = nil
                        elseif S.now_playing then
                            S.playing_id    = nil
                            S.playing       = true
                            S.is_error      = false
                            S.error_message = nil
                        end
                        os.queueEvent("audio_update")
                        signalRedraw()
                    -- skip zone
                    elseif p2 >= mw - 3 and p2 <= mw then
                        skipTrack()
                        signalRedraw()
                    end
                end
            end
        end
    end

    -- ── UI loop ───────────────────────────────────────────────────────────────

    local function uiLoop()
        S.W, S.H = term.getSize()

        -- Handle startup search argument
        if S.startup_query then
            S.tab = 2
            doSearch(S.startup_query)
            S.startup_query = nil
        end

        redrawScreen()

        while true do
            if S.waiting_input then
                parallel.waitForAny(
                    function()
                        -- Draw active input box
                        local inner_w = S.W - 4
                        twrite(2, 3, "+" .. string.rep("-", inner_w) .. "+", colors.gray, colors.black)
                        tfill(2, 4, inner_w + 2, colors.black, colors.white)
                        twrite(3, 4, "> ", colors.gray, colors.white)
                        twrite(2, 5, "+" .. string.rep("-", inner_w) .. "+", colors.gray, colors.black)
                        twrite(2, 6, "[Enter] search  [click outside] cancel", colors.gray, colors.black)
                        term.setCursorPos(5, 4)
                        term.setCursorBlink(true)
                        term.setBackgroundColor(colors.white)
                        term.setTextColor(colors.black)
                        local input = read()
                        term.setCursorBlink(false)
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

    return {
        uiLoop       = uiLoop,
        monitorLoop  = monitorLoop,
        signalRedraw = signalRedraw,
    }
end

return M
