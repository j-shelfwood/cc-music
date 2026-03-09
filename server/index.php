<?php

/**
 * cc-music — Self-hosted ComputerCraft streaming music server
 * Requires: yt-dlp, ffmpeg, PHP 8.x with popen enabled
 */

// No PHP execution timeout — streams can take many minutes
set_time_limit(0);

define('RAPIDAPI_KEY',  getenv('RAPIDAPI_KEY')  ?: '2d30b881bamsh14ffce6e60a7887p1de9bdjsne76d89970609');
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

// Resolve which SOCKS5 proxy to use.
// Primary: Mac via Tailscale (residential IP) — socks5://100.113.252.30:40001
// Fallback: Cloudflare WARP — socks5://127.0.0.1:40000
// Detection: attempt a TCP connect with a 2-second timeout; if it fails, use WARP.
function resolve_proxy(): string {
    static $resolved = null;
    if ($resolved !== null) return $resolved;

    $mac_proxy  = getenv('YTDLP_PROXY_MAC')  ?: 'socks5://100.113.252.30:40001';
    $warp_proxy = getenv('YTDLP_PROXY_WARP') ?: 'socks5://127.0.0.1:40000';

    // Quick TCP probe: nc -z -w2 <host> <port>
    // Returns exit code 0 if port is open, non-zero otherwise.
    $host = '100.113.252.30';
    $port = 40001;
    $probe = shell_exec('nc -z -w2 ' . escapeshellarg($host) . ' ' . (int)$port . ' 2>/dev/null; echo $?');
    $resolved = (trim($probe) === '0') ? $mac_proxy : $warp_proxy;
    return $resolved;
}

// Call RapidAPI yt-api and return decoded JSON (curl-based, avoids PHP SSL issues)
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

// Run yt-dlp and parse its newline-delimited JSON output
function ytdlp_json(string $args): array {
    $proxy = resolve_proxy();
    $cmd   = 'yt-dlp --no-warnings --proxy ' . escapeshellarg($proxy) . ' ' . $args . ' 2>/dev/null';
    $output = shell_exec($cmd);
    if (!$output) return [];
    $results = [];
    foreach (explode("\n", trim($output)) as $line) {
        if (!$line) continue;
        $data = json_decode($line, true);
        if ($data) $results[] = $data;
    }
    return $results;
}

// Build a result item from a yt-dlp entry
function build_item_ytdlp(array $entry): array {
    $duration = isset($entry['duration']) ? to_hms((int)$entry['duration']) : '?:??';
    $channel  = isset($entry['channel']) ? replace_non_ascii($entry['channel']) : '';
    $uploader = isset($entry['uploader']) ? replace_non_ascii($entry['uploader']) : $channel;
    $artist   = preg_replace('/ - Topic$/', '', $uploader ?: $channel);
    return [
        'id'     => $entry['id'],
        'name'   => replace_non_ascii($entry['title'] ?? 'Unknown'),
        'artist' => $duration . ' · ' . $artist,
    ];
}

// Build a result item from a RapidAPI video/info or search entry
function build_item_rapidapi(array $entry): array {
    // /video/info → lengthSeconds (int); /search → lengthText (e.g. "3:34")
    if (isset($entry['lengthSeconds']) && (int)$entry['lengthSeconds'] > 0) {
        $duration = to_hms((int)$entry['lengthSeconds']);
    } elseif (!empty($entry['lengthText'])) {
        $duration = $entry['lengthText'];
    } else {
        $duration = '?:??';
    }
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
// Proxy chain (resolve_proxy):
//   1. Mac via Tailscale socks5://100.113.252.30:40001 — residential IP, bypasses bot-check
//   2. WARP socks5://127.0.0.1:40000 — Cloudflare IP, fallback when Mac offline
//
// SEGMENT_BYTES = 448KB ≈ 74 seconds at 48kHz DFPWM (6KB/s)

define('SEGMENT_BYTES', 458752); // 448 * 1024

// ─── Server-side DFPWM segment cache ─────────────────────────────────────────
//
// Caches converted DFPWM segments on the VPS to avoid re-downloading from
// YouTube for repeated plays / segment requests. Protects the 300 req/day
// yt-dlp quota.
//
// Layout:
//   /tmp/cc-music-cache/<id>/seg_<offset>       -- raw DFPWM binary
//   /tmp/cc-music-cache/<id>/seg_<offset>.meta  -- JSON: {has_more, next_offset}
//
// TTL: 7 days (cleaned up on cache hit, lazy expiry on write)

define('CACHE_DIR', '/tmp/cc-music-cache');
define('CACHE_TTL', 7 * 24 * 3600); // 7 days in seconds

function seg_cache_path(string $id, int $offset): string {
    return CACHE_DIR . '/' . $id . '/seg_' . $offset;
}

function seg_cache_meta_path(string $id, int $offset): string {
    return seg_cache_path($id, $offset) . '.meta';
}

function seg_cache_read(string $id, int $offset): ?array {
    $path = seg_cache_path($id, $offset);
    $meta = seg_cache_meta_path($id, $offset);

    if (!file_exists($path) || !file_exists($meta)) return null;

    // Expire stale entries
    if (filemtime($path) < time() - CACHE_TTL) {
        @unlink($path);
        @unlink($meta);
        return null;
    }

    $body = file_get_contents($path);
    $m    = json_decode(file_get_contents($meta), true);
    if ($body === false || !$m) return null;

    return ['body' => $body, 'has_more' => (bool)$m['has_more'], 'next_offset' => (int)$m['next_offset']];
}

function seg_cache_write(string $id, int $offset, string $body, bool $has_more, int $next_offset): void {
    $dir = CACHE_DIR . '/' . $id;
    if (!is_dir($dir)) mkdir($dir, 0755, true);

    file_put_contents(seg_cache_path($id, $offset), $body);
    file_put_contents(seg_cache_meta_path($id, $offset), json_encode([
        'has_more'    => $has_more,
        'next_offset' => $next_offset,
    ]));
}

if (isset($_GET['id'])) {
    $id = sanitize_video_id(trim($_GET['id']));
    if (!$id) {
        http_response_code(400);
        echo 'Bad request';
        exit;
    }

    $offset = max(0, (int)($_GET['offset'] ?? 0));

    // ── Cache hit ────────────────────────────────────────────────────────────
    $cached = seg_cache_read($id, $offset);
    if ($cached !== null) {
        header('Content-Type: application/octet-stream');
        header('Cache-Control: no-cache');
        header('X-Accel-Buffering: no');
        header('X-Cache: HIT');
        if ($cached['has_more']) {
            header('X-More: 1');
            header('X-Next-Offset: ' . $cached['next_offset']);
        }
        echo $cached['body'];
        exit;
    }

    // ── Cache miss: fetch from YouTube ───────────────────────────────────────
    $proxy  = resolve_proxy();

    $yt_cmd = implode(' ', [
        'yt-dlp', '--no-warnings',
        '--proxy', escapeshellarg($proxy),
        '-f', '251/140/bestaudio',
        '-o', '-',
        '--quiet',
        escapeshellarg('https://www.youtube.com/watch?v=' . $id),
    ]);

    $ffmpeg_args = implode(' ', [
        'ffmpeg',
        '-hide_banner',
        '-loglevel', 'error',
        '-i', 'pipe:0',
        '-f', 'dfpwm',
        '-ar', '48000',
        '-ac', '1',
        'pipe:1',
    ]);

    $cmd    = $yt_cmd . ' | ' . $ffmpeg_args;
    $handle = popen($cmd, 'r');

    if (!$handle) {
        http_response_code(500);
        echo 'Error 500';
        exit;
    }

    // Skip first $offset bytes
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

    $has_more    = !feof($handle);
    $next_offset = $offset + $sent;
    pclose($handle);

    if ($sent === 0) {
        http_response_code(500);
        echo 'Stream failed (bot check or unavailable video)';
        exit;
    }

    // Write to cache before responding
    seg_cache_write($id, $offset, $body, $has_more, $next_offset);

    header('Content-Type: application/octet-stream');
    header('Cache-Control: no-cache');
    header('X-Accel-Buffering: no');
    header('X-Cache: MISS');
    if ($has_more) {
        header('X-More: 1');
        header('X-Next-Offset: ' . $next_offset);
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
            echo json_encode([build_item_rapidapi($data)]);
        } else {
            // Fallback to yt-dlp
            $entries = ytdlp_json('--dump-json --no-playlist ' . escapeshellarg('https://www.youtube.com/watch?v=' . $video_id));
            $results = array_map('build_item_ytdlp', array_filter($entries, fn($e) => isset($e['id'])));
            echo json_encode(array_values($results));
        }
        exit;
    }

    // Match YouTube playlist URL
    if (preg_match('#[?&]list=([a-zA-Z0-9_-]{34})#', $search, $m)) {
        $playlist_id = $m[1];
        $data = rapidapi_get('/playlist?id=' . $playlist_id);

        if (!empty($data['data'])) {
            $playlist_items = array_values(array_map('build_item_rapidapi', $data['data']));
            $playlist_title = replace_non_ascii($data['title'] ?? 'Playlist');
            $channel        = replace_non_ascii($data['channelTitle'] ?? '');
        } else {
            // Fallback to yt-dlp
            $entries = ytdlp_json('--dump-json --flat-playlist ' . escapeshellarg('https://www.youtube.com/playlist?list=' . $playlist_id));
            $items   = array_filter($entries, fn($e) => isset($e['id']) && isset($e['title']));
            $playlist_items = array_values(array_map('build_item_ytdlp', $items));
            $first   = reset($entries);
            $playlist_title = replace_non_ascii($first['playlist_title'] ?? $first['title'] ?? 'Playlist');
            $channel = replace_non_ascii($first['channel'] ?? $first['uploader'] ?? '');
        }

        echo json_encode([[
            'id'             => $playlist_id,
            'name'           => $playlist_title,
            'artist'         => 'Playlist · ' . count($playlist_items) . ' videos · ' . $channel,
            'type'           => 'playlist',
            'playlist_items' => $playlist_items,
        ]]);
        exit;
    }

    // Keyword search — RapidAPI primary, yt-dlp fallback
    $data  = rapidapi_get('/search?query=' . urlencode($search) . '&geo=US&lang=en&type=video');
    $items = [];
    foreach ($data['data'] ?? [] as $entry) {
        if (!isset($entry['videoId']) || !isset($entry['title'])) continue;
        $entry['id'] = $entry['videoId'];
        $items[] = build_item_rapidapi($entry);
        if (count($items) >= 5) break;
    }

    if (empty($items)) {
        // Fallback to yt-dlp search
        $entries = ytdlp_json(
            '--dump-json --flat-playlist --no-playlist ' .
            escapeshellarg('ytsearch5:' . $search)
        );
        $items = array_values(array_map('build_item_ytdlp',
            array_filter($entries, fn($e) => isset($e['id']) && isset($e['title']))
        ));
    }

    echo json_encode($items);
    exit;
}

// ─── Fallback ─────────────────────────────────────────────────────────────────

http_response_code(400);
echo 'Bad request';
