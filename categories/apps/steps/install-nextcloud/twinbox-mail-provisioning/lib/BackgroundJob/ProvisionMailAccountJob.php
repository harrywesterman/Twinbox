<?php

declare(strict_types=1);

namespace OCA\TwinboxMailProvisioning\BackgroundJob;

use OCA\TwinboxMailProvisioning\Service\MailAccountProvisioner;
use OCP\AppFramework\Utility\ITimeFactory;
use OCP\BackgroundJob\QueuedJob;
use Psr\Log\LoggerInterface;
use Throwable;

class ProvisionMailAccountJob extends QueuedJob
{
    public function __construct(
        ITimeFactory $time,
        private MailAccountProvisioner $provisioner,
        private LoggerInterface $logger,
    ) {
        parent::__construct($time);
    }

    protected function run($argument): void
    {
        if (!is_array($argument)) {
            return;
        }

        $uid = trim((string) ($argument['uid'] ?? ''));
        $email = strtolower(trim((string) ($argument['email'] ?? '')));
        $displayName = trim((string) ($argument['displayName'] ?? $email));

        if ($uid === '' || $email === '') {
            return;
        }

        try {
            $this->provisioner->provision($uid, $email, $displayName);
        } catch (Throwable $error) {
            $this->logger->warning('Twinbox Mail provisioning failed', [
                'app' => 'twinbox_mail_provisioning',
                'uid' => $uid,
                'email' => $email,
                'exception' => $error,
            ]);
        }
    }
}
