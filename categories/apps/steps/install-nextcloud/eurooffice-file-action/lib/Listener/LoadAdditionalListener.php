<?php

declare(strict_types=1);

namespace OCA\TwinboxEuroofficeAction\Listener;

use OCA\Files\Event\LoadAdditionalScriptsEvent;
use OCA\TwinboxEuroofficeAction\AppInfo\Application;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\Util;

/**
 * @template-implements IEventListener<LoadAdditionalScriptsEvent>
 */
class LoadAdditionalListener implements IEventListener
{
    public function handle(Event $event): void
    {
        if (!($event instanceof LoadAdditionalScriptsEvent)) {
            return;
        }

        Util::addScript(Application::APP_ID, 'main', 'files');
    }
}
