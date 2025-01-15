
# Crytic flake.nix

## Getting Started

Make sure nix is installed and that `nix-command` and `flakes` features are enabled. The [Determinate Systems nix-installer](https://determinate.systems/nix-installer/) will automatically enable these features and is the recommended approach. If nix is already installed without these features enabled, you can run the following commands to enable them.

```
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' > ~/.config/nix/nix.conf
```

## Direct Usage

Once you have nix installed, you can run the following to use slither without installing anything globally; like a single-serving virtualenv. The first time this is run, it will take time as slither's dependencies (eg crytic-compile) are downloaded and the project is built, but subsequent runs will execute almost instantly without requiring any further downloads. More info re [nix run](https://determinate.systems/posts/nix-run/).

`nix run git+ssh://git@github.com/crytic/crytic.nix#slither -- --help`

You can use the following just command to install slither globally via your `nix profile`. This installation is hooked up to a new copy of required dependencies, so it'll take care of the `crytic-compile` dependency w/out any risk of conflict w an existing global crytic-compile installation.

`just install slither`

You can also build the slither executable and run it directly.

`just build slither && ./result/bin/slither --help`

Supported tools:
- cloudexec
- crytic-compile
- echidna
- medusa
- slither
- solc-select
- vscode (including weaudit, sarif explorer, and other generic extensions that are helpful for auditors)

## Usage via other flakes

This crytic.nix flake, when used as an input to an "audit toolbox" flake in your audit repository, provides 2 collections of utilities:
- `crytic.packages.${system}.supported-tool`: the default version of some supported tool, as specified by the flake in this repo.
- `crytic.lib.${system}.mkSupportedTool`: a function that generates some supported tool from inputs such as a `commitHash`, `version`, and instances of each crytic dependency.

Usage in an audit repo might look something like the following:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/856556b164d56f63434d2dd3e954f00f4b3a075f"; # v24.05 on 240912
    utils.url = "github:numtide/flake-utils/b1d9ab70662946ef0850d488da1c9019f3a9752a"; # main on 240311
    foundry.url = "github:shazow/foundry.nix/monthly";
    crytic.url = "github:crytic/crytic.nix";
    crytic.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: with inputs;
    utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs { inherit system; overlays = [ foundry.overlay ]; };

      # Use a specific commit of crytic compile that has some hotfix or extra debug logs
      crytic-compile = crytic.lib.${system}.mkCryticCompile {
          commitHash = "0e5457afa28723fb39c419c4d0e3e2097d4235a8";
          version = "PR411"; # human-readable label eg which PR this commit is from
      };

    in rec {

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # misc dev deps from nixpkgs
            yarn
            foundry-bin
            # crytic audit tools
            crytic.packages.${system}.solc-select
            crytic-compile
            # use our custom version of crytic-compile in slither
            crytic.lib.${system}.mkSlither {
              inherit crytic-compile;
            };
            crytic.packages.${system}.echidna
            crytic.packages.${system}.medusa
            (crytic.lib.${system}.mkVscode {
              extensions = with pkgs.vscode-extensions; [
                vscodevim.vim # Add more vscode extensions like so
              ];
            })
          ];
        };

      }
    );
}
```

The above flake provides a development environment for auditing which includes:
- yarn + foundry for building/testing smart contracts. A specific version of foundry could be set by pinning the foundry input.
- the default version of solc-select, echidna, and medusa.
- a specific commit of crytic-compile, tagged with a human-readable version label
- the default version of slither but using our custom crytic-compile as a dependency

