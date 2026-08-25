#!/usr/bin/env bash
set -euo pipefail

NEXTCLOUD_ROOT="${NEXTCLOUD_ROOT:-/var/www/html}"
AUTHENTIK_API_BASE="${AUTHENTIK_API_BASE:-http://authentik-server.authentik.svc.cluster.local/api/v3}"
AUTHENTIK_ADMINS_GROUP="${AUTHENTIK_ADMINS_GROUP:-admins}"
NEXTCLOUD_ADMIN_GROUP="${NEXTCLOUD_ADMIN_GROUP:-admin}"
NEXTCLOUD_BREAK_GLASS_USER="${NEXTCLOUD_BREAK_GLASS_USER:-admin}"

: "${AUTHENTIK_API_TOKEN:?missing AUTHENTIK_API_TOKEN}"
export AUTHENTIK_API_BASE AUTHENTIK_ADMINS_GROUP NEXTCLOUD_ADMIN_GROUP NEXTCLOUD_BREAK_GLASS_USER

cd "$NEXTCLOUD_ROOT"

php <<'PHP'
<?php
declare(strict_types=1);

$authentikApiBase = rtrim((string) getenv('AUTHENTIK_API_BASE'), '/');
$authentikToken = (string) getenv('AUTHENTIK_API_TOKEN');
$authentikAdminsGroup = (string) getenv('AUTHENTIK_ADMINS_GROUP');
$nextcloudAdminGroup = (string) getenv('NEXTCLOUD_ADMIN_GROUP');
$breakGlassUser = (string) getenv('NEXTCLOUD_BREAK_GLASS_USER');

function log_line(string $message): void {
    fwrite(STDOUT, '[' . gmdate('Y-m-d H:i:s') . '] ' . $message . PHP_EOL);
}

function fail(string $message): never {
    fwrite(STDERR, '[' . gmdate('Y-m-d H:i:s') . '] ERROR: ' . $message . PHP_EOL);
    exit(1);
}

function api_get(string $path): array {
    global $authentikApiBase, $authentikToken;

    $context = stream_context_create([
        'http' => [
            'method' => 'GET',
            'header' => [
                'Accept: application/json',
                'Authorization: Bearer ' . $authentikToken,
            ],
            'ignore_errors' => true,
            'timeout' => 30,
        ],
    ]);
    $body = @file_get_contents($authentikApiBase . $path, false, $context);
    $statusLine = $http_response_header[0] ?? '';
    if (!preg_match('/\s2\d\d\s/', $statusLine)) {
        fail('Authentik API GET ' . $path . ' failed: ' . ($statusLine ?: 'no HTTP status'));
    }
    $decoded = json_decode((string) $body, true);
    if (!is_array($decoded)) {
        fail('Authentik API GET ' . $path . ' returned invalid JSON');
    }
    return $decoded;
}

function occ_json(string $command): array {
    $output = [];
    $exitCode = 0;
    exec('php occ ' . $command . ' 2>/dev/null', $output, $exitCode);
    if ($exitCode !== 0) {
        fail('occ ' . $command . ' failed');
    }
    $decoded = json_decode(implode("\n", $output), true);
    if (!is_array($decoded)) {
        fail('occ ' . $command . ' returned invalid JSON');
    }
    return $decoded;
}

function occ_run(string $command): void {
    $output = [];
    $exitCode = 0;
    exec('php occ ' . $command . ' >/dev/null 2>&1', $output, $exitCode);
    if ($exitCode !== 0) {
        fail('occ ' . $command . ' failed');
    }
}

function lower_email(?string $email): string {
    return strtolower(trim((string) $email));
}

$groupSearch = api_get('/core/groups/?search=' . rawurlencode($authentikAdminsGroup) . '&page_size=200');
$authentikGroup = null;
foreach (($groupSearch['results'] ?? []) as $group) {
    if (($group['name'] ?? '') === $authentikAdminsGroup) {
        $authentikGroup = $group;
        break;
    }
}
if (!is_array($authentikGroup)) {
    fail('Authentik group "' . $authentikAdminsGroup . '" was not found');
}

$groupId = (string) ($authentikGroup['pk'] ?? $authentikGroup['id'] ?? $authentikGroup['uuid'] ?? '');
if ($groupId === '') {
    fail('Could not determine Authentik group ID for "' . $authentikAdminsGroup . '"');
}

$groupDetail = api_get('/core/groups/' . rawurlencode($groupId) . '/');
$adminEmails = [];
foreach (($groupDetail['users_obj'] ?? []) as $user) {
    $email = lower_email($user['email'] ?? '');
    if ($email !== '') {
        $adminEmails[$email] = true;
    }
}
foreach (($groupDetail['users'] ?? []) as $userId) {
    $user = api_get('/core/users/' . rawurlencode((string) $userId) . '/');
    $email = lower_email($user['email'] ?? '');
    if ($email !== '') {
        $adminEmails[$email] = true;
    }
}

$users = occ_json('user:list --output=json');
$checked = 0;
$added = 0;
$removed = 0;
$skipped = 0;

foreach (array_keys($users) as $userId) {
    $userId = (string) $userId;
    $info = occ_json('user:info ' . escapeshellarg($userId) . ' --output=json');
    $backend = (string) ($info['backend'] ?? '');
    $email = lower_email($info['email'] ?? '');
    $groups = is_array($info['groups'] ?? null) ? $info['groups'] : [];
    $isNextcloudAdmin = in_array($nextcloudAdminGroup, $groups, true);

    if ($userId === $breakGlassUser) {
        $skipped++;
        continue;
    }
    if ($backend !== 'user_oidc') {
        $skipped++;
        continue;
    }
    if ($email === '') {
        $skipped++;
        continue;
    }

    $checked++;
    $shouldBeAdmin = isset($adminEmails[$email]);

    if ($shouldBeAdmin && !$isNextcloudAdmin) {
        occ_run('group:adduser ' . escapeshellarg($nextcloudAdminGroup) . ' ' . escapeshellarg($userId));
        $added++;
    } elseif (!$shouldBeAdmin && $isNextcloudAdmin) {
        occ_run('group:removeuser ' . escapeshellarg($nextcloudAdminGroup) . ' ' . escapeshellarg($userId));
        $removed++;
    }
}

log_line(
    'Nextcloud admin sync complete: '
    . count($adminEmails) . ' Authentik admin email(s), '
    . $checked . ' OIDC user(s) checked, '
    . $added . ' added, '
    . $removed . ' removed, '
    . $skipped . ' skipped'
);
PHP
