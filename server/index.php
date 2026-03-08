<?php

/**
 * cc-music — Self-hosted ComputerCraft streaming music server
 * Requires: yt-dlp, ffmpeg, PHP 8.x with popen enabled
 */

// No PHP execution timeout — streams can take many minutes
set_time_limit(0);

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
    // Replace remaining non-Latin-1 characters with '?'
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

// Run yt-dlp and parse its newline-delimited JSON output
function ytdlp_json(string $args): array {
    $cmd = 'yt-dlp --no-warnings ' . $args . ' 2>/dev/null';
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

// Build a result item array from yt-dlp entry data
function build_item(array $entry): array {
    $duration = isset($entry['duration']) ? to_hms((int)$entry['duration']) : '?:??';
    $channel   = isset($entry['channel']) ? replace_non_ascii($entry['channel']) : '';
    $uploader  = isset($entry['uploader']) ? replace_non_ascii($entry['uploader']) : $channel;
    // Strip " - Topic" suffix (auto-generated music channels)
    $artist = preg_replace('/ - Topic$/', '', $uploader ?: $channel);

    return [
        'id'     => $entry['id'],
        'name'   => replace_non_ascii($entry['title'] ?? 'Unknown'),
        'artist' => $duration . ' · ' . $artist,
    ];
}

// ─── Route: ?id=<video_id> ── Stream audio as DFPWM ───────────────────────────

if (isset($_GET['id'])) {
    $id = sanitize_video_id(trim($_GET['id']));
    if (!$id) {
        http_response_code(400);
        echo 'Bad request';
        exit;
    }

    $url = 'https://www.youtube.com/watch?v=' . $id;

    // Pipe: yt-dlp (best audio, stdout) → ffmpeg (dfpwm 48kHz mono, stdout)
    $cmd = implode(' ', [
        'yt-dlp',
        '--no-warnings',
        '-f', 'bestaudio',
        '-o', '-',
        '--quiet',
        escapeshellarg($url),
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

    header('Content-Type: application/octet-stream');
    header('Cache-Control: no-cache');
    header('X-Accel-Buffering: no'); // Disable nginx buffering if present

    $handle = popen($cmd, 'r');
    if (!$handle) {
        http_response_code(500);
        echo 'Error 500';
        exit;
    }

    // Stream in 16KB chunks — matches the CC:Tweaked Lua client chunk size
    while (!feof($handle)) {
        $chunk = fread($handle, 16384);
        if ($chunk !== false) {
            echo $chunk;
            flush();
        }
    }

    pclose($handle);
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
        $entries = ytdlp_json('--dump-json --no-playlist ' . escapeshellarg('https://www.youtube.com/watch?v=' . $video_id));
        $results = array_map('build_item', array_filter($entries, fn($e) => isset($e['id'])));
        echo json_encode(array_values($results));
        exit;
    }

    // Match YouTube playlist URL
    if (preg_match('#[?&]list=([a-zA-Z0-9_-]{34})#', $search, $m)) {
        $playlist_id = $m[1];
        $entries = ytdlp_json('--dump-json --flat-playlist ' . escapeshellarg('https://www.youtube.com/playlist?list=' . $playlist_id));

        if (empty($entries)) {
            echo json_encode([]);
            exit;
        }

        // First entry may be the playlist meta — filter to actual video entries
        $items = array_filter($entries, fn($e) => isset($e['id']) && isset($e['title']));
        $playlist_items = array_map('build_item', array_values($items));

        // Use first item's channel as playlist author fallback
        $first = reset($entries);
        $playlist_title = replace_non_ascii($first['playlist_title'] ?? $first['title'] ?? 'Playlist');
        $channel = replace_non_ascii($first['channel'] ?? $first['uploader'] ?? '');

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

    // Otherwise: keyword search (top 5 results)
    $entries = ytdlp_json(
        '--dump-json --flat-playlist --no-playlist ' .
        escapeshellarg('ytsearch5:' . $search)
    );

    $results = array_map('build_item', array_filter($entries, fn($e) => isset($e['id']) && isset($e['title'])));
    echo json_encode(array_values($results));
    exit;
}

// ─── Fallback ─────────────────────────────────────────────────────────────────

http_response_code(400);
echo 'Bad request';
