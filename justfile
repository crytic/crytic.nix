
########################################
## Build

build tool="slither":
  nix build .#{{tool}}

build-all:
  just build cloudexec
  just build code
  just build crytic-compile
  just build echidna
  just build medusa
  just build mewt
  just build muton
  just build necessist
  just build roundme
  just build slither
  just build solc-select

########################################
## Update

update-check:
  python3 scripts/update_tool_pins.py --check

update:
  python3 scripts/update_tool_pins.py --apply --verify

########################################
## Install

install tool="slither":
  nix profile add .#{{tool}}

upgrade tool="slither":
  nix profile upgrade {{tool}}

uninstall tool="slither":
  nix profile remove {{tool}}
