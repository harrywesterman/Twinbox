<?php

declare(strict_types=1);

namespace OCA\TwinboxEuroofficeAction\DirectEditing;

use OCP\AppFramework\Http\Response;
use OCP\DirectEditing\IEditor;
use OCP\DirectEditing\IToken;

final class EuroOfficeDirectEditor implements IEditor
{
    public function __construct(private IEditor $collabora)
    {
    }

    public function getId(): string
    {
        return 'eurooffice';
    }

    public function getName(): string
    {
        return $this->collabora->getName();
    }

    public function getMimetypes(): array
    {
        return $this->collabora->getMimetypes();
    }

    public function getMimetypesOptional(): array
    {
        return $this->collabora->getMimetypesOptional();
    }

    public function getCreators(): array
    {
        return $this->collabora->getCreators();
    }

    public function isSecure(): bool
    {
        return $this->collabora->isSecure();
    }

    public function open(IToken $token): Response
    {
        return $this->collabora->open($token);
    }
}
