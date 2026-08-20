# Nextcloud EuroOffice file-action compatibility design

## Goal

Keep Collabora as the default editor for office files and add a visible **Open in EuroOffice** action to the Files three-dot menu.

## Problem

EuroOffice 11.0.1 declares compatibility with Nextcloud 34 but its client module still depends on the removed `OCA`, `OCP`, and `OC` globals. The module aborts before it registers the modern Files action, so its documented context-menu action is absent.

## Chosen design

Twinbox will ship a small Nextcloud companion app. It uses the supported `@nextcloud/files` API to register one action for EuroOffice-supported document types. The action opens the existing EuroOffice route in a new tab, while Collabora remains the normal file-click handler.

The companion app is installed and enabled by the existing Nextcloud bootstrap and is packaged reproducibly from Twinbox source. It does not patch files owned by the EuroOffice app, so upgrades of either product do not silently overwrite the fix.

## Verification

Automated tests will assert that the companion app is included in the bootstrap and uses the modern Files action API. Live verification will confirm both editor workloads are healthy and that the file menu contains **Open in EuroOffice** for a DOCX file.
