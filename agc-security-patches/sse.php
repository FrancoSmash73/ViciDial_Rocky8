<?php
// ROCKY10-AGC-SECURITY-PATCH-v1 - see CLAUDE.md "agc web files - known applied fixes"
header('Content-Type: text/event-stream');
header('Cache-Control: no-cache');

$time = date('r');

// SSE 'retry' field must be a bare non-negative integer (milliseconds per the
// spec) — never echo raw request input into the stream body. Reject anything
// that isn't a plain int in a sane range and fall back to a 1 second retry.
$refresh_interval = filter_input(INPUT_GET, 'refresh_interval', FILTER_VALIDATE_INT, [
    'options' => ['min_range' => 100, 'max_range' => 3600000, 'default' => 1000],
]);

echo "retry: {$refresh_interval}\n";
echo "data: The server time is: {$time}\n\n";
flush();
?>