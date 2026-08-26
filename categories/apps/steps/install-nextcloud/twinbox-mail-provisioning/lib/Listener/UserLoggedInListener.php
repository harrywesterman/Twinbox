<?php

declare(strict_types=1);

namespace OCA\TwinboxMailProvisioning\Listener;

use OCA\TwinboxMailProvisioning\BackgroundJob\ProvisionMailAccountJob;
use OCP\BackgroundJob\IJobList;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\User\Events\UserLoggedInEvent;
use Psr\Log\LoggerInterface;

/**
 * @template-implements IEventListener<UserLoggedInEvent>
 */
class UserLoggedInListener implements IEventListener
{
    public function __construct(
        private IJobList $jobList,
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
        $backend = strtolower(trim($user->getBackendClassName()));

        if ($domain === '' || $email === '' || !str_ends_with($email, '@' . $domain)) {
            return;
        }

        if ($backend !== 'user_oidc' && !str_contains($backend, 'user_oidc')) {
            return;
        }

        $this->jobList->add(ProvisionMailAccountJob::class, [
            'uid' => $user->getUID(),
            'email' => $email,
            'displayName' => $user->getDisplayName() ?: $email,
        ]);

        $this->logger->info('Queued Twinbox Mail provisioning for OIDC user', [
            'app' => 'twinbox_mail_provisioning',
            'uid' => $user->getUID(),
            'email' => $email,
        ]);
    }
}
