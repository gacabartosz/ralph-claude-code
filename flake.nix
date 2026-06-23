{
  description = "Ralph for Claude Code — autonomous AI development loop with intelligent exit detection and rate limiting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Runtime dependencies placed on PATH for every Ralph command. Mirrors the
        # dependency set documented in install.sh (bash 4+, jq, git, node for the
        # Claude CLI, tmux for monitoring, plus the GNU coreutils/grep/sed Ralph
        # relies on for cross-platform behavior).
        runtimeDeps = with pkgs; [
          bashInteractive
          jq
          git
          nodejs
          tmux
          coreutils
          gnugrep
          gnused
        ];

        # command name -> entry script (same mapping as install.sh)
        ralph-claude-code = pkgs.stdenv.mkDerivation {
          pname = "ralph-claude-code";
          version = "0.11.5";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # Pure bash scripts: nothing to build or configure.
          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            runHook preInstall

            # Stage the whole tree so each script's SCRIPT_DIR-relative lookups
            # (lib/, templates/) resolve inside the Nix store.
            mkdir -p "$out/libexec/ralph" "$out/bin"
            cp -r . "$out/libexec/ralph/"
            chmod -R u+w "$out/libexec/ralph"

            # command -> backing script (mirrors install.sh's wrappers)
            declare -A cmds=(
              [ralph]=ralph_loop.sh
              [ralph-monitor]=ralph_monitor.sh
              [ralph-setup]=setup.sh
              [ralph-import]=ralph_import.sh
              [ralph-migrate]=migrate_to_ralph_folder.sh
              [ralph-enable]=ralph_enable.sh
              [ralph-enable-ci]=ralph_enable_ci.sh
              [ralph-stats]=ralph-stats.sh
            )

            for cmd in "''${!cmds[@]}"; do
              script="$out/libexec/ralph/''${cmds[$cmd]}"
              chmod +x "$script"
              makeWrapper "$script" "$out/bin/$cmd" \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
            done

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Autonomous AI development loop for Claude Code";
            homepage = "https://github.com/frankbria/ralph-claude-code";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "ralph";
          };
        };
      in
      {
        packages.default = ralph-claude-code;
        packages.ralph-claude-code = ralph-claude-code;

        # `nix run` / `nix run .#ralph` launches the loop.
        apps.default = {
          type = "app";
          program = "${ralph-claude-code}/bin/ralph";
        };

        # `nix develop` — runtime deps plus the test toolchain (bats, shellcheck).
        devShells.default = pkgs.mkShell {
          buildInputs = runtimeDeps ++ [ pkgs.bats pkgs.shellcheck ];
        };
      });
}
