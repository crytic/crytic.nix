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
          # latest release tag from https://github.com/crytic/solc-select/releases
          commitHash ? "00467c3de8f4d1b8aeb4d6fab54c8d7ea5573e67",
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
          # latest release tag from https://github.com/crytic/crytic-compile/releases
          commitHash ? "46ab5fda85dc967c0896720c0c3d744bb588f8c3",
          # latest version from https://github.com/crytic/crytic-compile/releases
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
          # latest release tag from https://github.com/crytic/slither/releases
          commitHash ? "3b6811f0e0b2a3107d4a3938dd67f300b72f472c",
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
          # latest release tag from https://github.com/crytic/cloudexec/releases
          commitHash ? "cbba8d81e4b64f5d0634e728c339101a53d373cd",
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
          # latest release tag from https://github.com/crytic/medusa/releases
          commitHash ? "540a483b7a2a35b0a6d210aeb6ae6015aa7a0f62",
          # latest version from https://github.com/crytic/medusa/releases
          version ? "1.5.1",
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
          # latest release tag from https://github.com/crytic/echidna/releases
          commitHash ? "7cbb32f3ff558d8e0b6e249c199831915c971d76",
          # version set by upstream flake.nix
        }: (
          builtins.getFlake "github:crytic/echidna/${commitHash}"
        ).packages.${system}.echidna;

        mkMewt = {
          # latest release tag from https://github.com/trailofbits/mewt/releases
          commitHash ? "e545284d2d8914f83d40b67882ed104ae073c555",
          # latest version from https://github.com/trailofbits/mewt/releases
          version ? "3.1.0",
        }: (
          builtins.getFlake "github:trailofbits/mewt/${commitHash}"
        ).packages.${system}.mewt;

        mkMuton = {
          # latest release tag from https://github.com/trailofbits/muton/releases
          commitHash ? "00b4aca72b7cc81f0961b0a9536109342410294f",
          # latest version from https://github.com/trailofbits/muton/releases
          version ? "3.1.0",
        }: (
          builtins.getFlake "github:trailofbits/muton/${commitHash}"
        ).packages.${system}.muton;

        mkNecessist = {
          # latest release tag from https://github.com/trailofbits/necessist/releases
          commitHash ? "069949411dddbf2380308fc6688be560144f9140",
          # latest version from https://github.com/trailofbits/necessist/releases
          version ? "2.2.0",
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
          # latest release tag from https://github.com/crytic/roundme/releases
          commitHash ? "95a61b71fac3bc21a26abc1b0b4fa29ab8f789a3",
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

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          python3
          git
          just
        ];
      };

    }
  );
}
