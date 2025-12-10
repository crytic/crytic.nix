{
  description = "Crytic Toolbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    utils.url = "github:numtide/flake-utils";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
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
          commitHash ? "0ec2946474fed4523bf91cb1f11f0b75a3a4bc76",
          version ? "1.1.0",
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
            setuptools
          ];
        });

        mkCryticCompile = {
          commitHash ? "3c83210d8387e56535bde588b071fe1573ca494a",
          version ? "0.3.10",
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
          propagatedBuildInputs = with pyPkgs; [
            solc-select
            cbor2
            pycryptodome
            setuptools
            toml
          ];
        });

        mkSlither = {
          commitHash ? "f571b6b666d22045ae27dd1fc99024e3f951f1ee",
          version ? "0.11.3",
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
            url = "https://github.com/crytic/cloudexec";
            rev = commitHash;
            allRefs = true;
          };
          nativeBuildInputs = [
            pkgs.go_1_23
          ];
          ldflags = [
            "-X main.Version=${version}"
            "-X main.Commit=${commitHash}"
            "-X main.Date=now"
          ];
        };

        mkMedusa = {
          commitHash ? "929651d9dae228c89035acc9cb7b3720577e565a",
          version ? "1.3.1",
          vendorHash ? "sha256-Tt7ZoEjurGSEmkqEsM04s3Nsny7YSH+DLwProdvwASY=",
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
          commitHash ? "e871c88b08a906b513f820c93a77610a56ae00bb",
        }: (
          builtins.getFlake "github:crytic/echidna/${commitHash}"
        ).packages.${system}.echidna;

        mkNecessist = {
          commitHash ? "b95fc237129c9f96e77d552592ed2cedcb6a62aa",
          version ? "2.1.2",
          src_override ? null,
        }: pkgs.rustPlatform.buildRustPackage rec {
          pname = "necessist";
          inherit version;
          src = if src_override != null then src_override else builtins.fetchGit {
            url = "https://github.com/trailofbits/necessist";
            rev = commitHash;
            allRefs = true;
          };
          cargoBuildFlags = "-p necessist";
          cargoLock = {
            lockFile = "${src}/Cargo.lock";
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
          commitHash ? "d7cab442befa336f9de10f7bf13de028261b328e",
          version ? "0.1.0",
          src_override ? null,
        }: pkgs.rustPlatform.buildRustPackage rec {
          pname = "roundme";
          inherit version;
          src = if src_override != null then src_override else builtins.fetchGit {
            url = "https://github.com/crytic/roundme";
            rev = commitHash;
            allRefs = true;
          };
          cargoBuildFlags = "-p roundme";
          cargoLock = {
            lockFile = "${src}/Cargo.lock";
          };
          nativeBuildInputs = with pkgs; [
            rustTools
            pkg-config
          ];
          # buildInputs = with pkgs; [
          #   openssl
          #   curl
          # ];
          # OPENSSL_NO_VENDOR = 1;
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
              name = "weaudit"; publisher = "trailofbits"; version = "1.3.1";
              sha256 = "sha256-xmiJVrpX+b9FeSDxDEKoP1HhJsISvqX7wAmplOkLiG4=";
            } {
              name = "sarif-explorer"; publisher = "trailofbits"; version = "1.3.0";
              sha256 = "sha256-e3iVk8M2B0WCJqpHc1Smcol5S6lP9GRRjNXAGwrN5ho=";
            } {
              name = "flowbookmark"; publisher = "DeepakPahawa"; version = "5.0.0";
              sha256 = "sha256-iLMEZR3yT0Ua1TJxQlEFXe6RH+vaCF8h9JUjXY5EOjg=";
            } {
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
        slither = lib.mkSlither {};
        solc-select = lib.mkSolcSelect {};
        necessist = lib.mkNecessist {};
        roundme = lib.mkRoundme {};
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
        buildInputs = [];
      };

    }
  );
}
