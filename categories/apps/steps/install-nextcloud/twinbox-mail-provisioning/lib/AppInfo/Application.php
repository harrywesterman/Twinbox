<?php

declare(strict_types=1);

namespace OCA\TwinboxMailProvisioning\AppInfo;

use OCA\TwinboxMailProvisioning\Listener\UserLoggedInListener;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\User\Events\UserLoggedInEvent;

class Application extends App implements IBootstrap
{
    public const APP_ID = 'twinbox_mail_provisioning';

    public function __construct(array $urlParams = [])
    {
        parent::__construct(self::APP_ID, $urlParams);
    }

    public function register(IRegistrationContext $context): void
    {
        $context->registerEventListener(
            UserLoggedInEvent::class,
            UserLoggedInListener::class,
        );
    }

    public function boot(IBootContext $context): void
    {
    }
}
