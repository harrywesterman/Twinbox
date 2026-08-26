<?php

declare(strict_types=1);

namespace OCA\TwinboxMailProvisioning\Service;

use RuntimeException;

class MailuClient
{
    private const TOKEN_COMMENT = 'Nextcloud Mail';

    public function mailboxExists(string $email): bool
    {
        $status = $this->request('GET', '/user/' . rawurlencode($email))['status'];

        return $status === 200;
    }

    public function createNextcloudToken(string $email): string
    {
        $response = $this->request('POST', '/tokenuser/' . rawurlencode($email), [
            'comment' => self::TOKEN_COMMENT,
            'AuthorizedIP' => [],
        ]);

        if ($response['status'] < 200 || $response['status'] >= 300) {
            throw new RuntimeException('Mailu token API returned HTTP ' . $response['status']);
        }

        $decoded = json_decode($response['body'], true);
        if (!is_array($decoded) || trim((string) ($decoded['token'] ?? '')) === '') {
            throw new RuntimeException('Mailu token API did not return a token');
        }

        return trim((string) $decoded['token']);
    }

    /**
     * @return array{status:int, body:string}
     */
    private function request(string $method, string $path, ?array $body = null): array
    {
        $baseUrl = rtrim((string) getenv('TWINBOX_MAILU_API_BASE'), '/');
        $apiToken = trim((string) getenv('TWINBOX_MAILU_API_TOKEN'));

        if ($baseUrl === '' || $apiToken === '') {
            throw new RuntimeException('Twinbox Mailu API configuration is missing');
        }

        $headers = [
            'Accept: application/json',
            'Authorization: Bearer ' . $apiToken,
        ];
        $content = null;
        if ($body !== null) {
            $content = json_encode($body, JSON_THROW_ON_ERROR);
            $headers[] = 'Content-Type: application/json';
        }

        $context = stream_context_create([
            'http' => [
                'method' => $method,
                'header' => implode("\r\n", $headers),
                'content' => $content,
                'ignore_errors' => true,
                'timeout' => 20,
            ],
        ]);

        $responseBody = @file_get_contents($baseUrl . $path, false, $context);
        $statusLine = $http_response_header[0] ?? '';
        $status = preg_match('/\s(\d{3})\s/', $statusLine, $matches) ? (int) $matches[1] : 0;

        return [
            'status' => $status,
            'body' => (string) $responseBody,
        ];
    }
}
