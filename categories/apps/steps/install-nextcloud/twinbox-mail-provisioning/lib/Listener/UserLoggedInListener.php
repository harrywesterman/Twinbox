<?php

declare(strict_types=1);

namespace OCA\TwinboxMailProvisioning\Listener;

use OCA\TwinboxMailProvisioning\BackgroundJob\ProvisionMailAccountJob;
use OCA\TwinboxMailProvisioning\Service\MailAccountProvisioner;
use OCP\BackgroundJob\IJobList;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\User\Events\UserLoggedInEvent;
use Psr\Log\LoggerInterface;
use Throwable;

/**
 * @template-implements IEventListener<UserLoggedInEvent>
 */
class UserLoggedInListener implements IEventListener
{
    public function __construct(
        private IJobList $jobList,
        private MailAccountProvisioner $provisioner,
        private LoggerInterface $logger,
    ) {
    }

    public function handle(Event $event): void
    {
        if (!($event instanceof UserLoggedInEvent)) {
            return;
        }

        $user = $event->getUser();
        $email = strtolower(trim((string) $user->getEMailAddress()));
        $domain = strtolower(trim((string) getenv('TWINBOX_MAIL_DOMAIN')));

        if ($domain === '' || $email === '' || !str_ends_with($email, '@' . $domain)) {
            return;
        }

        if ($user->getUID() === 'admin') {
            return;
        }

        $argument = [
            'uid' => $user->getUID(),
            'email' => $email,
            'displayName' => $user->getDisplayName() ?: $email,
        ];

        try {
            $this->provisioner->provision($argument['uid'], $argument['email'], $argument['displayName']);
            return;
        } catch (Throwable $error) {
            $this->logger->warning('Immediate Twinbox Mail provisioning failed; queued retry', [
                'app' => 'twinbox_mail_provisioning',
                'uid' => $argument['uid'],
                'email' => $argument['email'],
                'exception' => $error,
            ]);
        }

        $this->jobList->add(ProvisionMailAccountJob::class, [
            'uid' => $argument['uid'],
            'email' => $argument['email'],
            'displayName' => $argument['displayName'],
        ]);

        $this->logger->info('Queued Twinbox Mail provisioning for user', [
            'app' => 'twinbox_mail_provisioning',
            'uid' => $argument['uid'],
            'email' => $argument['email'],
        ]);
    }
}
