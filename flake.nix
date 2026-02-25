{
  description = "Crytic Toolbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    utils.url = "github:numtide/flake-utils";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: with inputs;
    utils.lib.eachDefaultSystem (system: let

      pyVersion = "python312";
      python = pkgs.${pyVersion};
      # Custom Python package set with overrides for problematic packages
      pyPkgs = pkgs.${pyVersion + "Packages"}.override {
        overrides = self: super: {
          # setproctitle tests segfault on macOS during fork tests
          # See: https://github.com/dvarrazzo/py-setproctitle/issues/133
          setproctitle = super.setproctitle.overridePythonAttrs (old: {
            doCheck = false;
            checkPhase = "true";
          });
        };
      };
      skipTests = { doCheck = false; checkPhase = "true"; checkInputs = []; };
      pyCommon = skipTests // {
        format = "pyproject";
        # Chill out re dependency versions
        pythonRelaxDeps = true; nativeBuildInputs = with pyPkgs; [ pythonRelaxDepsHook ];
      };
      pkgs = import nixpkgs { inherit system; };
      noCheck = drv: drv.overridePythonAttrs (old: skipTests // old);

      fenixPkgs = fenix.packages.${system};
      rustTools = with fenixPkgs; combine [
        stable.completeToolchain
        fenixPkgs.targets.x86_64-unknown-linux-gnu.stable.rust-std
        fenixPkgs.targets.aarch64-unknown-linux-gnu.stable.rust-std
      ];

    in rec {

      lib = {

        mkSolcSelect = {
          # latest commit from https://github.com/crytic/solc-select/commits/master/
          commitHash ? "eb64a7aae8cfee8df87fafd0e304b57b703bd48d",
          # latest version from https://github.com/crytic/solc-select/releases
          version ? "1.2.0",
          src ? null,
        }: pyPkgs.buildPythonPackage (pyCommon // {
          pname = "solc-select";
          inherit version;
          src = if src != null then src else builtins.fetchGit {
            url = "https://github.com/crytic/solc-select";
            rev = commitHash;
            allRefs = true;
          };
          propagatedBuildInputs = with pyPkgs; [
            packaging
            pycryptodome
            requests
            setuptools
          ];
        });

        mkCryticCompile = {
          # latest commit from https://github.com/crytic/crytic-compile/commits/master
          commitHash ? "08ee45443f7a661a3087d1b17502739d123ac0f9",
          # latest version from https://github.com/crytic/crytic-compile/commits/master/
          version ? "0.3.11",
          src ? null,
          solc-select ? packages.solc-select,
        }: pyPkgs.buildPythonPackage (pyCommon // {
          pname = "crytic-compile";
          inherit version;
          src = if src != null then src else builtins.fetchGit {
            url = "https://github.com/crytic/crytic-compile";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = (pyCommon.nativeBuildInputs or []) ++ (with pyPkgs; [
            uv-build
          ]);
          propagatedBuildInputs = with pyPkgs; [
            solc-select
            cbor2
            pycryptodome
            setuptools
            toml
          ];
        });

        mkSlither = {
          # latest commit from https://github.com/crytic/slither/commits/master/
          commitHash ? "675c4468eb6637fd04ea4cd865faeb6425e243b4",
          # latest version from https://github.com/crytic/slither/releases
          version ? "0.11.5",
          src ? null,
          solc-select ? packages.solc-select,
          crytic-compile ? packages.crytic-compile,
        }: pyPkgs.buildPythonPackage (pyCommon // {
          pname = "slither";
          inherit version;
          src = if src != null then src else builtins.fetchGit {
            url = "https://github.com/crytic/slither";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = (pyCommon.nativeBuildInputs or []) ++ (with pyPkgs; [
            hatchling
          ]);
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
            web3
          ];
          postPatch = ''
            echo "openai dependency is bugged, removing it from the listed deps"
            sed -i 's/"openai",//' pyproject.toml
          '';
        });

        mkCloudexec = {
          # latest commit from https://github.com/crytic/cloudexec/commits/main/
          commitHash ? "414f793e5b309611362ea2e1704836f94c2e397c",
          # latest version from https://github.com/crytic/cloudexec/releases
          version ? "0.2.0",
          src ? null,
          vendorHash ? "sha256-xiiMcjo+hRllttjYXB3F2Ms2gX43r7/qgwxr4THNhsk=",
        }: pkgs.buildGoModule {
          inherit version vendorHash;
          pname = "cloudexec";
          src = if src != null then src else builtins.fetchGit {
            url = "https://github.com/crytic/cloudexec";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = [
            pkgs.go
          ];
          ldflags = [
            "-X main.Version=${version}"
            "-X main.Commit=${commitHash}"
            "-X main.Date=now"
          ];
        };

        mkMedusa = {
          # latest commit from https://github.com/crytic/medusa/commits/master/
          commitHash ? "1f322bd1eed610d90b43d8882db4d60d6ad03bae",
          # latest version from https://github.com/crytic/medusa/releases
          version ? "1.5.0",
          vendorHash ? "sha256-r4p49cnObkugiEvGZx6bgXhjMbS5tMdfJsAJ7KzWW10=",
          src ? null,
          crytic-compile ? packages.crytic-compile,
          slither ? packages.slither,
        }: pkgs.buildGoModule {
          pname = "medusa";
          inherit version vendorHash;
          src = if src != null then src else builtins.fetchGit {
            url = "https://github.com/crytic/medusa";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = [
            crytic-compile
            slither
            pkgs.solc
            pkgs.nodejs_22
          ];
          doCheck = false; # tests require `npm install` which can't run in isolated build env
        };

        mkEchidna = {
          # latest commit from https://github.com/crytic/echidna/commits/master/
          commitHash ? "f946d3638eab3fa3bcb75d7f6cf5e08a2f1c63b6",
          # version set by upstream flake.nix
        }: (
          builtins.getFlake "github:crytic/echidna/${commitHash}"
        ).packages.${system}.echidna;

        mkMewt = {
          # latest commit from https://github.com/trailofbits/mewt/commits/main/
          commitHash ? "f21bab01bf5ab6b5b95572b67af0e78c8c82a363",
          # latest version from https://github.com/trailofbits/mewt/tags
          version ? "2.0.1",
        }: (
          builtins.getFlake "github:trailofbits/mewt/${commitHash}"
        ).packages.${system}.mewt;

        mkMuton = {
          # latest commit from https://github.com/trailofbits/muton/commits/main/
          commitHash ? "9f1a48aeafc1e866c2d68cf9e1f2e00d2424d24d",
          # latest version from https://github.com/trailofbits/muton/tags
          version ? "2.0.1",
        }: (
          builtins.getFlake "github:trailofbits/muton/${commitHash}"
        ).packages.${system}.muton;

        mkNecessist = {
          # latest commit from https://github.com/trailofbits/necessist/commits/master/
          commitHash ? "27a28a4fe5ed7029ff98929b432a52a690196586",
          # latest version from https://github.com/trailofbits/necessist/releases
          version ? "2.1.2",
          src ? null,
        }: let
          effectiveSrc = if src != null then src else builtins.fetchGit {
            url = "https://github.com/trailofbits/necessist";
            rev = commitHash;
            allRefs = true;
          };
        in pkgs.rustPlatform.buildRustPackage {
          pname = "necessist";
          inherit version;
          src = effectiveSrc;
          cargoBuildFlags = "-p necessist";
          cargoLock = {
            lockFile = "${effectiveSrc}/Cargo.lock";
          };
          nativeBuildInputs = with pkgs; [
            rustTools
            pkg-config
          ];
          buildInputs = with pkgs; [
            openssl
            sqlite
            curl
          ];
          OPENSSL_NO_VENDOR = 1;
          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
          doCheck = false;
        };

        mkRoundme = {
          # latest commit from https://github.com/crytic/roundme/commits/main/
          commitHash ? "d7cab442befa336f9de10f7bf13de028261b328e",
          # latest version from https://github.com/crytic/roundme/releases
          version ? "0.1.0",
          src ? null,
        }: let
          effectiveSrc = if src != null then src else builtins.fetchGit {
            url = "https://github.com/crytic/roundme";
            rev = commitHash;
            allRefs = true;
          };
        in pkgs.rustPlatform.buildRustPackage {
          pname = "roundme";
          inherit version;
          src = effectiveSrc;
          cargoBuildFlags = "-p roundme";
          cargoLock = {
            lockFile = "${effectiveSrc}/Cargo.lock";
          };
          nativeBuildInputs = with pkgs; [
            rustTools
            pkg-config
          ];
          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
          doCheck = false;
        };

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
            hediet.vscode-drawio
            yzhang.markdown-all-in-one
          ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [{
              # latest version from https://marketplace.visualstudio.com/items?itemName=trailofbits.weaudit
              name = "weaudit"; publisher = "trailofbits"; version = "1.3.1";
              sha256 = "sha256-xmiJVrpX+b9FeSDxDEKoP1HhJsISvqX7wAmplOkLiG4=";
            } {
              # latest version from https://marketplace.visualstudio.com/items?itemName=trailofbits.sarif-explorer
              name = "sarif-explorer"; publisher = "trailofbits"; version = "1.3.0";
              sha256 = "sha256-e3iVk8M2B0WCJqpHc1Smcol5S6lP9GRRjNXAGwrN5ho=";
            } {
              # latest version from https://marketplace.visualstudio.com/items?itemName=DeepakPahawa.flowbookmark
              name = "flowbookmark"; publisher = "DeepakPahawa"; version = "5.0.0";
              sha256 = "sha256-iLMEZR3yT0Ua1TJxQlEFXe6RH+vaCF8h9JUjXY5EOjg=";
            } {
              # latest version from https://marketplace.visualstudio.com/items?itemName=JuanBlanco.solidity
              name = "solidity"; publisher = "juanblanco"; version = "0.0.187";
              sha256 = "sha256-O0VGLSBu7FJruCUlZjL6l+sTiXJjY0woz3sMqVzyFhs=";
            }
          ];
        };

      };

      packages = {
        cloudexec = lib.mkCloudexec {};
        crytic-compile = lib.mkCryticCompile {};
        echidna = lib.mkEchidna {};
        medusa = lib.mkMedusa {};
        mewt = lib.mkMewt {};
        muton = lib.mkMuton {};
        necessist = lib.mkNecessist {};
        roundme = lib.mkRoundme {};
        slither = lib.mkSlither {};
        solc-select = lib.mkSolcSelect {};
        vscode = lib.mkVscode {};
      };

      apps = {
        cloudexec = { program = "${packages.cloudexec}/bin/cloudexec"; type = "app"; };
        crytic-compile = { program = "${packages.crytic-compile}/bin/crytic-compile"; type = "app"; };
        echidna = { program = "${packages.echidna}/bin/echidna"; type = "app"; };
        medusa = { program = "${packages.medusa}/bin/medusa"; type = "app"; };
        mewt = { program = "${packages.mewt}/bin/mewt"; type = "app"; };
        muton = { program = "${packages.muton}/bin/muton"; type = "app"; };
        necessist = { program = "${packages.necessist}/bin/necessist"; type = "app"; };
        roundme = { program = "${packages.roundme}/bin/roundme"; type = "app"; };
        slither = { program = "${packages.slither}/bin/slither"; type = "app"; };
        solc-select = { program = "${packages.solc-select}/bin/solc-select"; type = "app"; };
        vscode = { program = "${packages.vscode}/bin/vscode"; type = "app"; };
      };

    }
  );
}
