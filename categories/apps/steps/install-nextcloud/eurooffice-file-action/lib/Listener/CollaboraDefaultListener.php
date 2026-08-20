<?php

declare(strict_types=1);

namespace OCA\TwinboxEuroofficeAction\Listener;

use OCA\TwinboxEuroofficeAction\DirectEditing\EuroOfficeDirectEditor;
use OCP\DirectEditing\IManager;
use OCP\DirectEditing\RegisterDirectEditorEvent;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;

/**
 * @template-implements IEventListener<RegisterDirectEditorEvent>
 */
final class CollaboraDefaultListener implements IEventListener
{
    public function __construct(private IManager $directEditingManager)
    {
    }

    public function handle(Event $event): void
    {
        if (!($event instanceof RegisterDirectEditorEvent)) {
            return;
        }

        $editors = $this->directEditingManager->getEditors();
        if (!isset($editors['eurooffice'], $editors['richdocuments'])) {
            return;
        }

        $event->register(new EuroOfficeDirectEditor($editors['richdocuments']));
    }
}
