{
  description = "Crytic Toolbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    utils.url = "github:numtide/flake-utils";
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
            pkgs.go_1_22
          ];
          ldflags = [
            "-X main.Version=${version}"
            "-X main.Commit=${commitHash}"
            "-X main.Date=now"
          ];
        };

        mkMedusa = {
          commitHash ? "ef1f31d2ffacd5c5a120d42e6fb22b9ea76e0b99",
          version ? "1.2.1",
          vendorHash ? "sha256-utOYL3f4+cpTBHqeuWtd07K1ytLR5cUaZ1hsTEcjpBQ=",
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
          commitHash ? "aff20b7c643f7346c9b97de5e369cab303aa6eb3",
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
            hediet.vscode-drawio
            yzhang.markdown-all-in-one
          ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [{
              name = "weaudit"; publisher = "trailofbits"; version = "1.2.1";
              sha256 = "sha256-DZn+0ASrT+FxzN+jyMi6W1Dj2AOpbDzA7NBTlzhWM6w=";
            } {
              name = "sarif-explorer"; publisher = "trailofbits"; version = "1.2.9";
              sha256 = "sha256-ilNPBW7MYzwm9vwbfnjrDQ0y4NGDFaz3uVt+NN/WDX4=";
            } {
              name = "flowbookmark"; publisher = "DeepakPahawa"; version = "5.0.0";
              sha256 = "sha256-iLMEZR3yT0Ua1TJxQlEFXe6RH+vaCF8h9JUjXY5EOjg=";
            } {
              name = "solidity"; publisher = "juanblanco"; version = "0.0.184";
              sha256 = "sha256-2JFngoGb5MSPqr+DfIgmMckcjZtNPfSxnHJ31qQuyPU=";
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
          pkgs.git
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
