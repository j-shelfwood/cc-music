-- cc-music audio module
-- Handles HTTP segment fetching and speaker playback.

local M = {}

function M.init(S, speakers, signalRedraw)

    local api_base_url = "https://cc-music.shelfwood.co/api/"
    local version      = "3.0"
    local CHUNK_SIZE   = 16 * 1024
    local CHUNKS_PER_SEG = math.floor(458752 / CHUNK_SIZE) -- = 28

    -- ── Helpers ──────────────────────────────────────────────────────────────

    local function stopSpeakers()
        for _, sp in ipairs(speakers) do sp.stop() end
        os.queueEvent("playback_stopped")
    end

    -- ── Speaker playback ─────────────────────────────────────────────────────

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

    -- ── Segment request ──────────────────────────────────────────────────────

    local function requestSegment(id, offset)
        local url = api_base_url .. "?v=" .. version
                    .. "&id=" .. textutils.urlEncode(id)
                    .. "&offset=" .. offset
        S.last_download_url = url
        http.request({url = url, binary = true})
    end

    -- ── Audio loop ───────────────────────────────────────────────────────────

    local function audioLoop()
        while true do
            if S.playing and S.now_playing then
                local this_id = S.now_playing.id

                if S.playing_id ~= this_id then
                    S.playing_id      = this_id
                    S.audio_offset    = 0
                    S.audio_has_more  = false
                    S.segment_ready   = false
                    S.chunk_in_seg    = 0
                    S.seg_count       = 0
                    S.decoder         = require("cc.audio.dfpwm").make_decoder()
                    requestSegment(S.playing_id, 0)
                    S.is_loading = true
                    signalRedraw()
                    os.queueEvent("audio_update")

                elseif S.segment_ready then
                    while true do
                        local chunk = S.player_handle:read(CHUNK_SIZE)

                        if not chunk then
                            S.player_handle:close()
                            S.segment_ready  = false
                            S.chunk_in_seg   = 0

                            if S.audio_has_more and S.playing and S.playing_id == this_id then
                                requestSegment(S.playing_id, S.audio_offset)
                                S.is_buffering = true
                                signalRedraw()
                                break
                            end

                            -- Track ended — advance queue
                            if S.looping == 2 or (S.looping == 1 and #S.queue == 0) then
                                S.playing_id   = nil
                                S.audio_offset = 0
                                S.elapsed      = 0
                            elseif S.looping == 1 and #S.queue > 0 then
                                table.insert(S.queue, S.now_playing)
                                S.now_playing  = table.remove(S.queue, 1)
                                S.playing_id   = nil
                                S.audio_offset = 0
                                S.elapsed      = 0
                                S.duration     = S.parseDuration(S.now_playing.artist)
                            elseif #S.queue > 0 then
                                S.now_playing  = table.remove(S.queue, 1)
                                S.playing_id   = nil
                                S.audio_offset = 0
                                S.elapsed      = 0
                                S.duration     = S.parseDuration(S.now_playing.artist)
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
                                S.chunk_in_seg  = 0
                                S.seg_count     = 0
                            end
                            signalRedraw()
                            break
                        end

                        local decoded = S.decoder(chunk)

                        -- Elapsed: CHUNK_SIZE bytes @ 6000 bytes/sec (48kHz DFPWM)
                        S.elapsed      = S.elapsed + CHUNK_SIZE / 6000
                        S.chunk_in_seg = S.chunk_in_seg + 1

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
                    os.queueEvent("audio_update")
                end
            end

            os.pullEvent("audio_update")
        end
    end

    -- ── HTTP loop ────────────────────────────────────────────────────────────

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
                        S.chunk_in_seg    = 0
                        S.seg_count       = S.seg_count + 1
                        signalRedraw()
                        os.queueEvent("audio_update")
                    end
                end,
                function()
                    local _, url, fail_handle = os.pullEvent("http_failure")

                    if url == S.last_search_url then
                        S.search_error = true
                        signalRedraw()
                    elseif url == S.last_download_url then
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
                        os.queueEvent("audio_update")
                    end
                end
            )
        end
    end

    return {
        audioLoop = audioLoop,
        httpLoop  = httpLoop,
        stopSpeakers = stopSpeakers,
    }
end

return M
