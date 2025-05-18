{
  description = "DevShell for MITRE Vulcan (Rails + PostgreSQL + Node)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    devshell.url = "github:numtide/devshell";
  };

  outputs = { self, nixpkgs, flake-utils, devshell }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
	  overlays = [ devshell.overlays.default ];
        };
      in {
        devShells.default = pkgs.devshell.mkShell {
          name = "vulcan-devshell";

          packages = with pkgs; [
            ruby
            nodejs_20
            yarn
            postgresql_16
            libffi
            libyaml
            zlib
            openssl
            pkg-config
            gnumake
            gcc
            git
            which
            foreman
          ];

          env = [
            {
              name = "RAILS_ENV";
              value = "development";
            }
            {
              name = "DATABASE_URL";
              value = "postgresql://localhost/vulcan_dev";
            }
          ];

          commands = [
            {
              name = "vulcan-gen-env";
              help = "Generate .env and .env-prod secrets";
              command = ''
                echo "[+] Generating .env and .env-prod..."

                if [ ! -f .env ]; then
                  echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)" > .env
                  echo "[✓] .env created"
                else
                  echo "[i] .env already exists"
                fi

                if [ ! -f .env-prod ]; then
                  cat <<EOF > .env-prod
SECRET_KEY_BASE=$(${pkgs.openssl}/bin/openssl rand -hex 64)
CIPHER_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -hex 64)
CIPHER_SALT=$(${pkgs.openssl}/bin/openssl rand -hex 32)
EOF
                  echo "[✓] .env-prod created"
                else
                  echo "[i] .env-prod already exists"
                fi
              '';
            }
            {
              name = "vulcan-setup";
              help = "Run initial setup (bin/setup)";
              command = "bin/setup";
            }
            {
              name = "vulcan-seed";
              help = "Seed the database (rails db:seed)";
              command = "rails db:seed";
            }
            {
              name = "vulcan-run";
              help = "Start the dev server via foreman";
              command = "foreman start -f Procfile.dev";
            }
          ];
        };
      });
}

