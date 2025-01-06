{
  description = "Crytic Toolbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/856556b164d56f63434d2dd3e954f00f4b3a075f"; # v24.05 on 240912
    utils.url = "github:numtide/flake-utils/b1d9ab70662946ef0850d488da1c9019f3a9752a"; # 240311
  };

  outputs = inputs: with inputs;
    utils.lib.eachDefaultSystem (system: let

      pyVersion = "python312";
      python = pkgs.${pyVersion};
      pyPkgs = pkgs.${pyVersion + "Packages"};
      skipTests = { doCheck = false; checkPhase = "true"; checkInputs = []; };
      pyCommon = skipTests // {
        format = "pyproject";
        # Chill out re dependency versions
        pythonRelaxDeps = true; nativeBuildInputs = with pyPkgs; [ pkgs.git pythonRelaxDepsHook ];
      };
      pkgs = import nixpkgs { inherit system; };
      noCheck = drv: drv.overridePythonAttrs (old: skipTests // old);

    in rec {

      lib = {

        mkSolcSelect = {
          commitHash ? "8072a3394bdc960c0f652fb72e928a7eae3631da",
          version ? "1.0.4",
          src ? null,
        }: pyPkgs.buildPythonPackage (pyCommon // {
          pname = "solc-select";
          inherit version;
          src = if src != null then src else builtins.fetchGit {
            url = "git+ssh://git@github.com/crytic/solc-select";
            rev = commitHash;
            allRefs = true;
          };
          propagatedBuildInputs = with pyPkgs; [
            packaging
            pycryptodome
            setuptools
          ];
        });

        mkCryticCompile = {
          commitHash ? "20df04f37af723eaa7fa56dc2c80169776f3bc4d",
          version ? "0.3.7",
          src ? null,
          solc-select ? packages.solc-select,
        }: pyPkgs.buildPythonPackage (pyCommon // {
          pname = "crytic-compile";
          inherit version;
          src = if src != null then src else builtins.fetchGit {
            url = "git+ssh://git@github.com/crytic/crytic-compile";
            rev = commitHash;
            allRefs = true;
          };
          propagatedBuildInputs = with pyPkgs; [
            solc-select
            cbor2
            pycryptodome
            setuptools
            toml
          ];
        });

        mkSlither = {
          commitHash ? "aeeb2d368802844733671e35200b30b5f5bdcf5c",
          version ? "0.10.4",
          src ? null,
          solc-select ? packages.solc-select,
          crytic-compile ? packages.crytic-compile,
        }: pyPkgs.buildPythonPackage (pyCommon // {
          pname = "slither";
          inherit version;
          src = if src != null then src else builtins.fetchGit {
            url = "git+ssh://git@github.com/crytic/slither";
            rev = commitHash;
            allRefs = true;
          };
          propagatedBuildInputs = with pyPkgs; [
            solc-select
            crytic-compile
            deepdiff
            eth-abi
            eth-typing
            eth-utils
            numpy
            packaging
            prettytable
            pycryptodome
            pytest
            pytest-cov
            setuptools
          ];
          postPatch = ''
            echo "web3 dependency depends on ipfs which is bugged, removing it from the listed deps"
            sed -i 's/"web3>=6.20.2, <7",//' setup.py
            echo "openai dependency is bugged, removing it from the listed deps"
            sed -i 's/"openai",//' setup.py
          '';
        });

        mkCloudexec = {
          commitHash ? "cbba8d81e4b64f5d0634e728c339101a53d373cd",
          version ? "0.2.0",
          src ? null,
          vendorHash ? "sha256-xiiMcjo+hRllttjYXB3F2Ms2gX43r7/qgwxr4THNhsk=",
        }: pkgs.buildGoModule {
          inherit version vendorHash;
          pname = "cloudexec";
          src = if src != null then src else builtins.fetchGit {
            url = "git+ssh://git@github.com/crytic/cloudexec";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = [
            pkgs.git
            pkgs.go_1_21
          ];
          ldflags = [
            "-X main.Version=${version}"
            "-X main.Commit=${commitHash}"
            "-X main.Date=now"
          ];
        };

        mkMedusa = {
          commitHash ? "c58a72f2f9072c7b31d6a16f4771449e00607e4b",
          version ? "0.1.8",
          vendorHash ? "sha256-12Xkg5dzA83HQ2gMngXoLgu1c9KGSL6ly5Qz/o8U++8=",
          src ? null,
          crytic-compile ? packages.crytic-compile,
        }: pkgs.buildGoModule {
          pname = "medusa";
          inherit version vendorHash;
          src = if src != null then src else builtins.fetchGit {
            url = "git+ssh://git@github.com/crytic/medusa";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = [
            crytic-compile
            pkgs.solc
            pkgs.nodejs
          ];
          doCheck = false; # tests require `npm install` which can't run in isolated build env
        };

        mkEchidna = {
          commitHash ? "6d5ac38f9132938210c325d17fd6672543dfc9c4",
        }: (
          builtins.getFlake "github:crytic/echidna/${commitHash}"
        ).packages.${system}.echidna;

        mkVscode = {
          extensions ? [],
        }: pkgs.vscode-with-extensions.override {
          vscode = pkgs.vscodium;
          vscodeExtensions = with pkgs.vscode-extensions; extensions ++ [
            jnoortheen.nix-ide
            mads-hartmann.bash-ide-vscode
            ms-python.python
            naumovs.color-highlight
            oderwat.indent-rainbow
            yzhang.markdown-all-in-one
          ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [{
              name = "weaudit"; publisher = "trailofbits"; version = "1.1.0";
              sha256 = "sha256-XHif6JzZJvQiToIn3mnBznp9ct8wlWOyBVncHU4ZDgo=";
            } {
              name = "sarif-explorer"; publisher = "trailofbits"; version = "1.2.4";
              sha256 = "sha256-BwJEapf0HRaUKHxA5V8QDAv3dEDGSxlE9a7dOnaN4h4=";
            } {
              name = "flowbookmark"; publisher = "DeepakPahawa"; version = "5.0.0";
              sha256 = "sha256-iLMEZR3yT0Ua1TJxQlEFXe6RH+vaCF8h9JUjXY5EOjg=";
            } {
              name = "solidity"; publisher = "juanblanco"; version = "0.0.174";
              sha256 = "sha256-+fHycRl++Ate7NoQFaLmHynWNC+T4zjsPlFwvpnEMrk=";
            }
          ];
        };

      };

      packages = {
        cloudexec = lib.mkCloudexec {};
        crytic-compile = lib.mkCryticCompile {};
        echidna = lib.mkEchidna {};
        medusa = lib.mkMedusa {};
        slither = lib.mkSlither {};
        solc-select = lib.mkSolcSelect {};
        vscode = lib.mkVscode {};
      };

      apps = {
        cloudexec = { program = "${packages.cloudexec}/bin/cloudexec"; type = "app"; };
        crytic-compile = { program = "${packages.crytic-compile}/bin/crytic-compile"; type = "app"; };
        echidna = { program = "${packages.echidna}/bin/echidna"; type = "app"; };
        medusa = { program = "${packages.medusa}/bin/medusa"; type = "app"; };
        slither = { program = "${packages.slither}/bin/slither"; type = "app"; };
        solc-select = { program = "${packages.solc-select}/bin/solc-select"; type = "app"; };
        vscode = { program = "${packages.vscode}/bin/vscode"; type = "app"; };
      };

      devShells.default = pkgs.mkShell {
        buildInputs = with packages; [
          cloudexec
          crytic-compile
          echidna
          medusa
          slither
          solc-select
          vscode
        ];
      };

    }
  );
}
