# staging-box

The server tenant from box#69: user `ops`, no agent, sshd hardened, docker
from rig's mechanism. Its data is [`template.env`](template.env).

## Minting it

box 0.11.0 retires box's own `staging-box` template (heavy-duty/box#253,
members 7 and 12). The two things that template added on top of a plain box,
autostart and a required VM, are now flags on `box new`:

    box new --name staging-box --size medium --autostart --require-vm

Then converge from a root shell in the box (`box root staging-box`):

    rig bootstrap staging-box

`template.env` names the tenant (`USER="ops"`), and rig creates it when it is
absent (heavy-duty/rig#230; box 0.11.0 seeds no users). `USER_SUDO="nopasswd"`
gives `ops` the passwordless sudo a self-converging server keeps (box#177's
other half), and `SWAP_SIZE="4G"` lays the swap box no longer does. All three
need rig 0.4.1 or later.

The tailnet workload join stays operator-run (`box root staging-box`, then
`rig bootstrap workload-server`), because that step holds a credential.
