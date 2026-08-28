{
  description = "wrq - a local-first research paper library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        homeModules.default = { config, lib, pkgs, ... }:
          let
            cfg = config.programs.wrq;
          in
          {
            options.programs.wrq = {
              enable = lib.mkEnableOption "wrq research paper library";

              package = lib.mkOption {
                type = lib.types.package;
                default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.default;
                defaultText = lib.literalExpression
                  "inputs.wrq.packages.${pkgs.stdenv.hostPlatform.system}.default";
                description = "The wrq package to install.";
              };

              path = lib.mkOption {
                type = lib.types.str;
                default = "~/papers";
                description = "Root of the local wrq paper library.";
              };
            };

            config = lib.mkIf cfg.enable {
              home.packages = [ cfg.package ];
              home.sessionVariables.WRQ_PATH = cfg.path;
            };
          };

        # Compatibility for Home Manager configurations using the older output
        # name. New configurations should use homeModules.default.
        homeManagerModules.default = inputs.self.homeModules.default;
      };

      perSystem = { self', pkgs, ... }:
        let
          runtimeDeps = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.xdg-utils
          ];

          package = pkgs.stdenvNoCC.mkDerivation {
            pname = "wrq";
            version = builtins.replaceStrings [ "\n" ] [ "" ]
              (builtins.readFile ./VERSION);
            src = inputs.self;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall

              install -Dm755 wrq.rb "$out/libexec/wrq/wrq.rb"
              cp -R lib "$out/libexec/wrq/lib"
              makeWrapper ${pkgs.ruby_3_3}/bin/ruby "$out/bin/wrq" \
                --add-flags "$out/libexec/wrq/wrq.rb" \
                ${pkgs.lib.optionalString pkgs.stdenv.isLinux
                  "--prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}"}

              runHook postInstall
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              "$out/bin/wrq" --version
            '';

            meta = {
              description = "Local-first command-line library for research papers";
              homepage = "https://github.com/mohamedsobhi777/wrq";
              license = pkgs.lib.licenses.mit;
              mainProgram = "wrq";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        in
        {
          packages = {
            default = package;
            wrq = package;
          };

          apps.default = {
            type = "app";
            program = "${self'.packages.default}/bin/wrq";
          };

          checks.package = self'.packages.default;
        };
    };
}
