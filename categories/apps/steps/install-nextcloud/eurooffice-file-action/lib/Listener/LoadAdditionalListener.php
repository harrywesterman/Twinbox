<?php

declare(strict_types=1);

namespace OCA\TwinboxEuroofficeAction\Listener;

use OCA\Files\Event\LoadAdditionalScriptsEvent;
use OCA\TwinboxEuroofficeAction\AppInfo\Application;
use OCP\Util;

class LoadAdditionalListener
{
    public function handle(LoadAdditionalScriptsEvent $event): void
    {
        Util::addScript(Application::APP_ID, 'main', 'files');
    }
}
