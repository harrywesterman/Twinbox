<?php

declare(strict_types=1);

namespace OCA\TwinboxEuroofficeAction\AppInfo;

use OCA\Files\Event\LoadAdditionalScriptsEvent;
use OCA\TwinboxEuroofficeAction\Listener\LoadAdditionalListener;
use OCP\AppFramework\App;
use OCP\EventDispatcher\IEventDispatcher;

class Application extends App
{
    public const APP_ID = 'twinbox_eurooffice_action';

    public function __construct(array $urlParams = [])
    {
        parent::__construct(self::APP_ID, $urlParams);

        $this->getContainer()->get(IEventDispatcher::class)->addServiceListener(
            LoadAdditionalScriptsEvent::class,
            LoadAdditionalListener::class,
        );
    }
}
