
default_branch := "dev"

build tool="slither":
  nix build .#{{tool}}

build-all:
  just build cloudexec
  just build crytic-compile
  just build echidna
  just build medusa
  just build slither
  just build solc-select
  just build vscode

install tool="slither":
  just build {{tool}}
  echo nix profile remove $(nix profile list | grep {{tool}} | cut -d " " -f 1)
  nix profile remove $(nix profile list | grep {{tool}} | cut -d " " -f 1)
  echo nix profile install ./result
  nix profile install ./result

uninstall tool="slither":
  echo nix profile remove $(nix profile list | grep {{tool}} | cut -d " " -f 1) # BEWARE: fragile
  nix profile remove $(nix profile list | grep {{tool}} | cut -d " " -f 1)

reinstall tool="slither":
  just uninstall {{tool}}
  just install {{tool}}

code:
  codium .
