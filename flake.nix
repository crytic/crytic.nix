{
  description = "Crytic Toolbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    utils.url = "github:numtide/flake-utils";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";

    # Keep these aligned with tob.nix so downstream flakes can share the same
    # uv/pyproject packaging stack without redeclaring pins.
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: with inputs;
    utils.lib.eachDefaultSystem (system: let

      nixlib = nixpkgs.lib;
      pkgs = import nixpkgs { inherit system; };
      python = pkgs.python312;

      fenixPkgs = fenix.packages.${system};
      rustTools = with fenixPkgs; combine [
        stable.completeToolchain
        fenixPkgs.targets.x86_64-unknown-linux-gnu.stable.rust-std
        fenixPkgs.targets.aarch64-unknown-linux-gnu.stable.rust-std
      ];

    in rec {

      lib = rec {

        mkUvPyTool = {
          pname,
          url,
          commitHash,
          src ? null,
          sourcePreference ? "wheel",
        }: let
          effectiveSrc = if src != null then src else builtins.fetchGit {
            inherit url;
            rev = commitHash;
            allRefs = true;
          };
          workspace = uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = effectiveSrc;
          };
          overlay = workspace.mkPyprojectOverlay {
            inherit sourcePreference;
          };
          pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          }).overrideScope (
            nixlib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              overlay
            ]
          );
          venv = pythonSet.mkVirtualEnv "${pname}-env" workspace.deps.default;
        in pkgs.symlinkJoin {
          name = pname;
          paths = [ venv ];
        };

        mkSolcSelect = {
          # latest commit from https://github.com/crytic/solc-select/commits/dev/
          commitHash ? "edcbd33b2640366b6358a99e53436089299170e8",
          src ? null,
        }: mkUvPyTool {
          pname = "solc-select";
          url = "https://github.com/crytic/solc-select";
          inherit commitHash src;
        };

        mkCryticCompile = {
          # latest commit from https://github.com/crytic/crytic-compile/commits/master/
          commitHash ? "19934aa5b10837590b4ee1396a9266d0abd3ed8a",
          src ? null,
          solc-select ? packages.solc-select,
        }: mkUvPyTool {
          pname = "crytic-compile";
          url = "https://github.com/crytic/crytic-compile";
          inherit commitHash src;
        };

        mkSlither = {
          # latest release tag from https://github.com/crytic/slither/releases
          commitHash ? "3b6811f0e0b2a3107d4a3938dd67f300b72f472c",
          src ? null,
          solc-select ? packages.solc-select,
          crytic-compile ? packages.crytic-compile,
        }: mkUvPyTool {
          pname = "slither";
          url = "https://github.com/crytic/slither";
          inherit commitHash src;
        };

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
          # latest commit from https://github.com/trailofbits/necessist/commits/main/
          commitHash ? "b5f56d05522f8c237ec03a9776555e5f185ba7ff",
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

      apps = nixlib.mapAttrs (name: bin: {
        program = "${packages.${name}}/bin/${bin}";
        type = "app";
      }) {
        cloudexec = "cloudexec";
        crytic-compile = "crytic-compile";
        echidna = "echidna";
        medusa = "medusa";
        mewt = "mewt";
        muton = "muton";
        necessist = "necessist";
        roundme = "roundme";
        slither = "slither";
        solc-select = "solc-select";
        vscode = "vscode";
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
