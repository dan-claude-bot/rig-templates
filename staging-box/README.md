# staging-box

The server tenant from box#69: user `ops`, no agent, sshd hardened, docker
from rig's mechanism. Its data is [`template.env`](template.env).

## Minting it

box 0.11.0 retires box's own `staging-box` template (heavy-duty/box#253,
members 7 and 12). This role already supplies the `ops` user; the two things
box's template added on top, autostart and a required VM, are now flags on
`box new`:

    box new --name staging-box --size medium --autostart --require-vm

Then converge this role onto it with rig. The tailnet workload join stays
operator-run (`box shell`, then `rig bootstrap workload-server`), because
that step holds a credential.
