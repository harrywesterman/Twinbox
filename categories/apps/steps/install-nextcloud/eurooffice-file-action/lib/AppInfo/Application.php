<?php

declare(strict_types=1);

namespace OCA\TwinboxEuroofficeAction\AppInfo;

use OCA\Files\Event\LoadAdditionalScriptsEvent;
use OCA\TwinboxEuroofficeAction\Listener\CollaboraDefaultListener;
use OCA\TwinboxEuroofficeAction\Listener\LoadAdditionalListener;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\DirectEditing\RegisterDirectEditorEvent;

class Application extends App implements IBootstrap
{
    public const APP_ID = 'twinbox_eurooffice_action';

    public function __construct(array $urlParams = [])
    {
        parent::__construct(self::APP_ID, $urlParams);
    }

    public function register(IRegistrationContext $context): void
    {
        $context->registerEventListener(
            LoadAdditionalScriptsEvent::class,
            LoadAdditionalListener::class,
        );
        $context->registerEventListener(
            RegisterDirectEditorEvent::class,
            CollaboraDefaultListener::class,
        );
    }

    public function boot(IBootContext $context): void
    {
    }
}
