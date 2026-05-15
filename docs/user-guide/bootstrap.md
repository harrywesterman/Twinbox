# Proxmox Bootstrap

The bootstrap step is the first real Twinbox action. You run it from the
Proxmox side, and it creates the Management VM that hosts the rest of the
workflow.

## What this step does

- Creates the Management VM
- Prepares the Docker-based runtime on that VM
- Hands off to the web wizard once the environment is ready

## What the user should see

![Twinbox Proxmox bootstrap wizard](../assets/user-guide/bootstrap/wizard.png)

## Notes

- Keep this step short and explicit.
- Avoid mixing cluster design choices into the bootstrap page.
- Use the page to show users exactly what they should expect on the host.
