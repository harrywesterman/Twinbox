<?php

declare(strict_types=1);

namespace OCA\TwinboxMailProvisioning\Service;

use Psr\Log\LoggerInterface;
use RuntimeException;

class MailAccountProvisioner
{
    public function __construct(
        private MailuClient $mailuClient,
        private LoggerInterface $logger,
    ) {
    }

    public function provision(string $uid, string $email, string $displayName): void
    {
        if ($this->mailAccountExists($uid, $email)) {
            return;
        }

        if (!$this->mailuClient->mailboxExists($email)) {
            $this->logger->info('Twinbox Mailu mailbox is not available yet', [
                'app' => 'twinbox_mail_provisioning',
                'uid' => $uid,
                'email' => $email,
            ]);
            return;
        }

        $token = $this->mailuClient->createNextcloudToken($email);
        $this->createMailAccount($uid, $email, $displayName, $token);

        $this->logger->info('Twinbox Mail account provisioned', [
            'app' => 'twinbox_mail_provisioning',
            'uid' => $uid,
            'email' => $email,
        ]);
    }

    private function mailAccountExists(string $uid, string $email): bool
    {
        $output = $this->runOcc([
            'mail:account:export',
            $uid,
        ], true);

        return str_contains(strtolower($output), strtolower($email));
    }

    private function createMailAccount(string $uid, string $email, string $displayName, string $token): void
    {
        $this->runOcc([
            'mail:account:create',
            $uid,
            $displayName,
            $email,
            'mailu-dovecot.mailu.svc.cluster.local',
            '143',
            'none',
            $email,
            $token,
            'mailu-front.mailu.svc.cluster.local',
            '10025',
            'none',
            $email,
            $token,
            'password',
        ], false);
    }

    /**
     * @param list<string> $args
     */
    private function runOcc(array $args, bool $allowFailure): string
    {
        $command = 'php occ';
        foreach ($args as $arg) {
            $command .= ' ' . escapeshellarg($arg);
        }

        $output = [];
        $exitCode = 0;
        exec('cd /var/www/html && ' . $command . ' 2>/dev/null', $output, $exitCode);
        if ($exitCode !== 0 && !$allowFailure) {
            throw new RuntimeException('occ command failed: ' . implode(' ', array_slice($args, 0, 2)));
        }

        return implode("\n", $output);
    }
}
