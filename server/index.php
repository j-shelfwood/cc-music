<?php

/**
 * cc-music — Self-hosted ComputerCraft streaming music server
 * Audio extraction via yt-api.p.rapidapi.com (bypasses YouTube bot-detection)
 * Requires: ffmpeg, PHP 8.x with popen enabled
 */

// No PHP execution timeout — streams can take many minutes
set_time_limit(0);

// RapidAPI key — set via env var or fallback to hardcoded
define('RAPIDAPI_KEY', getenv('RAPIDAPI_KEY') ?: '2d30b881bamsh14ffce6e60a7887p1de9bdjsne76d89970609');
define('RAPIDAPI_HOST', 'yt-api.p.rapidapi.com');

// Security: sanitize video ID to prevent shell injection
function sanitize_video_id(string $id): ?string {
    return preg_match('/^[a-zA-Z0-9_-]{11}$/', $id) ? $id : null;
}

// Replace non-extended-ASCII characters (mirrors original JS behaviour)
function replace_non_ascii(string $str): string {
    $replacements = [
        "\xe2\x80\x94" => '-',   // em dash
        "\xe2\x80\x93" => '-',   // en dash
        "\xe2\x80\x98" => "'",   // left single quote
        "\xe2\x80\x99" => "'",   // right single quote
        "\xe2\x80\x9c" => '"',   // left double quote
        "\xe2\x80\x9d" => '"',   // right double quote
        "\xe2\x80\xa6" => '...', // ellipsis
        "\xe2\x80\xa2" => '·',   // bullet
    ];
    $str = strtr($str, $replacements);
    return preg_replace('/[^\x00-\xFF]/u', '?', $str);
}

// Format seconds to H:MM:SS or MM:SS
function to_hms(int $seconds): string {
    $h = (int) floor($seconds / 3600);
    $m = (int) floor(($seconds % 3600) / 60);
    $s = $seconds % 60;
    if ($h > 0) {
        return sprintf('%d:%02d:%02d', $h, $m, $s);
    }
    return sprintf('%d:%02d', $m, $s);
}

// Call the RapidAPI yt-api endpoint and return decoded JSON
function rapidapi_get(string $path): ?array {
    $url  = 'https://' . RAPIDAPI_HOST . $path;
    $cmd  = implode(' ', [
        'curl', '-sf', '--max-time', '15',
        '-H', escapeshellarg('x-rapidapi-key: ' . RAPIDAPI_KEY),
        '-H', escapeshellarg('x-rapidapi-host: ' . RAPIDAPI_HOST),
        escapeshellarg($url),
    ]);
    $body = shell_exec($cmd);
    if (!$body) return null;
    return json_decode($body, true) ?: null;
}

// Pick the best audio-only stream URL from a /dl response
// Prefers itag 140 (m4a 128k), falls back to any audio/mp4, then audio/webm
function best_audio_url(array $data): ?string {
    $adaptive = $data['adaptiveFormats'] ?? [];

    // Prefer itag 140 (audio/mp4 medium quality ~130kbps)
    foreach ($adaptive as $f) {
        if (($f['itag'] ?? '') == 140 && !empty($f['url'])) return $f['url'];
    }
    // Any audio/mp4
    foreach ($adaptive as $f) {
        if (str_starts_with($f['mimeType'] ?? '', 'audio/mp4') && !empty($f['url'])) return $f['url'];
    }
    // Any audio/webm
    foreach ($adaptive as $f) {
        if (str_starts_with($f['mimeType'] ?? '', 'audio/webm') && !empty($f['url'])) return $f['url'];
    }
    // Last resort: muxed format 18
    foreach ($data['formats'] ?? [] as $f) {
        if (!empty($f['url'])) return $f['url'];
    }
    return null;
}

// Build a result item from RapidAPI video/info or search entry
function build_item(array $entry): array {
    $seconds  = (int)($entry['lengthSeconds'] ?? 0);
    $duration = $seconds > 0 ? to_hms($seconds) : '?:??';
    $channel  = replace_non_ascii($entry['channelTitle'] ?? '');
    $artist   = preg_replace('/ - Topic$/', '', $channel);
    return [
        'id'     => $entry['id'] ?? $entry['videoId'] ?? '',
        'name'   => replace_non_ascii($entry['title'] ?? 'Unknown'),
        'artist' => $duration . ' · ' . $artist,
    ];
}

// ─── Route: ?id=<video_id>&offset=<bytes> ── Stream audio as DFPWM ─────────────
//
// Fetches a direct CDN audio URL from RapidAPI (no yt-dlp, no bot-check),
// then pipes it through ffmpeg to produce DFPWM segments.
// Each request returns SEGMENT_BYTES of DFPWM starting at `offset`.
// X-More / X-Next-Offset headers signal continuation to the CC client.
//
// SEGMENT_BYTES = 448KB ≈ 74 seconds at 48kHz DFPWM (6KB/s).

define('SEGMENT_BYTES', 458752); // 448 * 1024

if (isset($_GET['id'])) {
    $id = sanitize_video_id(trim($_GET['id']));
    if (!$id) {
        http_response_code(400);
        echo 'Bad request';
        exit;
    }

    $offset = max(0, (int)($_GET['offset'] ?? 0));

    // Fetch stream URL from RapidAPI
    $data = rapidapi_get('/dl?id=' . $id . '&cgeo=US');
    if (!$data || ($data['status'] ?? '') !== 'OK') {
        http_response_code(500);
        echo 'RapidAPI error: ' . ($data['message'] ?? 'unknown');
        exit;
    }

    $stream_url = best_audio_url($data);
    if (!$stream_url) {
        http_response_code(500);
        echo 'No audio stream available';
        exit;
    }

    // Pipe: curl (CDN URL) → ffmpeg → DFPWM stdout
    $cmd = implode(' ', [
        'curl', '-sL', escapeshellarg($stream_url),
        '|',
        'ffmpeg',
        '-hide_banner',
        '-loglevel', 'error',
        '-i', 'pipe:0',
        '-f', 'dfpwm',
        '-ar', '48000',
        '-ac', '1',
        'pipe:1',
    ]);

    $handle = popen($cmd, 'r');
    if (!$handle) {
        http_response_code(500);
        echo 'Error 500';
        exit;
    }

    // Skip first $offset bytes (re-encode from start — stateless server)
    $skipped = 0;
    while ($skipped < $offset && !feof($handle)) {
        $want  = min(65536, $offset - $skipped);
        $chunk = fread($handle, $want);
        if ($chunk === false) break;
        $skipped += strlen($chunk);
    }

    // Read up to SEGMENT_BYTES
    $sent = 0;
    $body = '';
    while ($sent < SEGMENT_BYTES && !feof($handle)) {
        $want  = min(16384, SEGMENT_BYTES - $sent);
        $chunk = fread($handle, $want);
        if ($chunk === false) break;
        $body .= $chunk;
        $sent += strlen($chunk);
    }

    $has_more = !feof($handle);
    pclose($handle);

    if ($sent === 0) {
        http_response_code(500);
        echo 'Stream failed (no audio data)';
        exit;
    }

    header('Content-Type: application/octet-stream');
    header('Cache-Control: no-cache');
    header('X-Accel-Buffering: no');
    if ($has_more) {
        header('X-More: 1');
        header('X-Next-Offset: ' . ($offset + $sent));
    }

    echo $body;
    exit;
}

// ─── Route: ?search=<query> ── Search or resolve YouTube URL ─────────────────

if (isset($_GET['search'])) {
    $search = trim($_GET['search']);

    header('Content-Type: application/json; charset=latin1');

    // Match single YouTube video URL
    if (preg_match(
        '#(?:https?://)?(?:www\.|m\.|music\.)?(?:youtube\.com|youtu\.be).*?(?:v=|embed/|v/|youtu\.be/)([a-zA-Z0-9_-]{11})#',
        $search,
        $m
    )) {
        $video_id = $m[1];
        $data = rapidapi_get('/video/info?id=' . $video_id);
        if ($data && isset($data['title'])) {
            echo json_encode([build_item($data)]);
        } else {
            echo json_encode([]);
        }
        exit;
    }

    // Match YouTube playlist URL
    if (preg_match('#[?&]list=([a-zA-Z0-9_-]{34})#', $search, $m)) {
        $playlist_id = $m[1];
        $data = rapidapi_get('/playlist?id=' . $playlist_id);

        if (empty($data['data'])) {
            echo json_encode([]);
            exit;
        }

        $playlist_items = array_values(array_map('build_item', $data['data']));
        $playlist_title = replace_non_ascii($data['title'] ?? 'Playlist');
        $channel        = replace_non_ascii($data['channelTitle'] ?? '');

        $result = [[
            'id'             => $playlist_id,
            'name'           => $playlist_title,
            'artist'         => 'Playlist · ' . count($playlist_items) . ' videos · ' . $channel,
            'type'           => 'playlist',
            'playlist_items' => $playlist_items,
        ]];

        echo json_encode($result);
        exit;
    }

    // Keyword search — top 5 results
    $data = rapidapi_get('/search?query=' . urlencode($search) . '&geo=US&lang=en&type=video');
    $items = [];
    foreach ($data['data'] ?? [] as $entry) {
        if (!isset($entry['videoId']) || !isset($entry['title'])) continue;
        $entry['id'] = $entry['videoId'];
        $items[] = build_item($entry);
        if (count($items) >= 5) break;
    }
    echo json_encode($items);
    exit;
}

// ─── Fallback ─────────────────────────────────────────────────────────────────

http_response_code(400);
echo 'Bad request';
