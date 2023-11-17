{ config, pkgs, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.services.security_tracker;

  configSource = with lib.generators;
    toINI {
      mkKeyValue = mkKeyValueDefault {
        mkValueString = v:
          if builtins.isBool v then
            (if v then "True" else "False")
          else
            mkValueStringDefault { } v;
      } "=";
    } cfg.settings;

  configFile = pkgs.writeText "settings.ini" configSource;

  trackerEnv = {
    NST_SETTINGS_PATH = toString configFile;
    DJANGO_SETTINGS_MODULE = "tracker.settings";
  } // lib.optionalAttrs cfg.useLocalDatabase {
    DATABASE_URL = "postgresql:///${user}"; # Rely on trusted authentication.
  };

  srcPath = if (cfg.sourcePath == null) then
    pkgs.security-tracker.src
  else
    cfg.sourcePath;

  user = "security_tracker";

  serviceConfig = rec {
    User = user;
    Group = user;

    StateDirectory = "security-tracker";
    StateDirectoryMode = "0755";
    WorkingDirectory = "/var/lib/${StateDirectory}";

    Type = "oneshot";
    StandardOutput = "journal+console";
  };
in {
  options.services.security_tracker = {
    enable = mkEnableOption "the nix security tracker webserver.";
    devMode = mkEnableOption "the development mode (non-production setup)";

    # TLS
    useTLS = mkEnableOption "TLS on the web server";
    useACME = mkEnableOption
      "Let's Encrypt for TLS certificates delivery (require a public domain name)";
    forceTLS = mkEnableOption "Redirect HTTP on HTTPS";
    sslCertificate = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to server SSL certificate.";
    };
    sslCertificateKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to server SSL certificate key.";
    };

    staticRoot = mkOption {
      type = types.package;
      default = pkgs.security-tracker.static;
      description = ''
        In **production** mode, the package to use for static data, which will be used as static root.
        Note that, as its name indicates it, static data never change during the lifecycle of the service.
        As a result, static root is read-only.
        It can only be changed through changes in the static derivation.
      '';
    };
    sourcePath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        In **production** mode, the package to use for source, is the security tracker package.
        As a result, the source is read-only.
        Though, in editable mode, a mutable path can be passed, e.g. /run/security-tracker.
      '';
    };
    envPackage = mkOption {
      type = types.package;
      default = pkgs.security-tracker.env;
      description = ''
        This is the security tracker Python's environment: its dependencies.
      '';
    };
    appPackage = mkOption {
      type = types.package;
      default = pkgs.security-tracker;
      description = ''
        This is the Security Tracker Python's application for production deployment.
      '';
    };
    allowedHosts = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1" "localhost" ]
        ++ lib.optionals (cfg.domainName != null) [ cfg.domainName ];
      example = [ "127.0.0.1" "steinsgate.dev" ];
      description = ''
        List of allowed hosts (Django parameter).
      '';
    };
    settings = mkOption {
      type = types.submodule {
        freeformType = with types; attrsOf (attrsOf anything);
      };
      example = ''
        {
          debug = { DEBUG_VUE_JS = false; };
          sentry = { DSN = "<some dsn>"; };
        }
      '';
      description = ''
        The settings for Mangaki which will be turned into a settings.ini.
        Most of the public parameters can be configured directly from the service.

        It will be deep merged otherwise.
      '';
    };
    nginx = {
      enable = mkOption {
        type = types.bool;
        default = !cfg.devMode;
        description = ''
          This will use NGINX as a web server which will reverse proxy the uWSGI endpoint.

          Disable it if you want to put your own web server.
        '';
      };
    };
    lifecycle = {
      performInitialMigrations = mkOption {
        type = types.bool;
        default = true;
        description = ''
          This will create a systemd oneshot for initial migration.
          This is 99 % of the case what you want.

          Though, you might want to handle migrations yourself (in case of already created DBs).
        '';
      };
    };
    useLocalDatabase = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to let this service create automatically a sensible PostgreSQL database locally.

        You want this disabled whenever you have an external PostgreSQL database.
      '';
    };
    domainName = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "security.nixos.org";
      description = ''
        The domain to use for the service in production mode.

        In development mode, this is not needed.
        If you really want, you can use some /etc/hosts to point to the VM IP.
        e.g. mangaki.dev → <VM IP>
        Useful to test production mode locally.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.useLocalDatabase
          -> (lib.hasAttr "SECRET_FILE" cfg.settings.secrets
            || lib.hasAttr "URL" (cfg.settings.database or { }));
        message =
          "If local database is not used, either a secret file with a database URI or the database URI must be set.";
      }
      {
        assertion = cfg.useTLS -> (cfg.useACME
          || (cfg.sslCertificate != null && cfg.sslCertificateKey != null));
        message =
          "If TLS is enabled, either use Let's Encrypt or provide your own certificates.";
      }
      {
        assertion = cfg.useACME -> cfg.domainName != null;
        message =
          "If ACME is used, a domain name must be set, otherwise ACME will fail.";
      }
      {
        assertion = !cfg.devMode -> cfg.domainName != null;
        message =
          "If production mode is enabled, a domain name must be set, otherwise NGINX cannot be configured.";
      }
      {
        assertion = !cfg.devMode -> cfg.settings.secrets ? "SECRET_KEY"
          || cfg.settings.secrets ? "SECRET_FILE";
        message =
          "If production mode is enabled, either a secret file or a secret key must be set in secrets, otherwise Mangaki will not start.";
      }
    ];

    warnings = lib.concatLists [
      (lib.optional (!cfg.lifecycle.performInitialMigrations)
        "You disabled initial migration setup, this can have unexpected effects.")
      ((lib.optional (!cfg.devMode -> cfg.settings.secrets.SECRET_KEY
        == "CHANGE_ME" && !(cfg.settings.secrets ? "SECRET_FILE")))
        "You are deploying a production (${
          if (cfg.domainName == null) then
            "no domain name set"
          else
            cfg.domainName
        }) instance with a default secret key. The server will be vulnerable.")
      (lib.optional (!cfg.devMode -> (!(cfg.settings.secrets ? "SECRET_FILE")
        || cfg.settings.secrets.SECRET_FILE == null))
        "You are deploying a production (${
          if (cfg.domainName == null) then
            "no domain name set"
          else
            cfg.domainName
        }) instance with no secret file. Some secrets may end up in the Nix store which is world-readable.")
    ];

    environment.systemPackages = [ cfg.envPackage ];
    environment.variables = {
      inherit (trackerEnv) NST_SETTINGS_PATH DJANGO_SETTINGS_MODULE;
    };

    services = {
      security_tracker.settings = {
        debug = { DEBUG = lib.mkDefault cfg.devMode; };

        secrets = { };
      } // lib.optionalAttrs cfg.useLocalDatabase {
        database.URL = lib.mkDefault "postgresql://";
      } // lib.optionalAttrs (!cfg.devMode) {
        deployment = {
          MEDIA_ROOT = lib.mkDefault "/var/lib/security_tracker/media";
          STATIC_ROOT = lib.mkDefault "${cfg.staticRoot}";
          DATA_ROOT = lib.mkDefault "/var/lib/security_tracker/data";
        };

        hosts = {
          ALLOWED_HOSTS =
            lib.mkDefault (lib.concatStringsSep "," cfg.allowedHosts);
        };
      };

      postgresql = mkIf cfg.useLocalDatabase {
        enable = cfg.useLocalDatabase; # PostgreSQL set.
        ensureUsers = [{
          name = "security_tracker";
          ensurePermissions = {
            "DATABASE security_tracker" = "ALL PRIVILEGES";
          };
        }]; # Tracker user set.
        initialScript = pkgs.writeText "security_tracker-postgresql-init.sql" ''
          CREATE DATABASE security_tracker;
          \c security_tracker
          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          CREATE EXTENSION IF NOT EXISTS unaccent;
        ''; # Extensions & Tracker database set.
      };

      # Set up NGINX.
      nginx = mkIf (!cfg.devMode) {
        enable = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedGzipSettings = true;
        recommendedTlsSettings = cfg.useTLS;

        virtualHosts."${cfg.domainName}" = {
          enableACME = cfg.useTLS && cfg.useACME;
          sslCertificate =
            if cfg.useTLS && !cfg.useACME then cfg.sslCertificate else null;
          sslCertificateKey =
            if cfg.useTLS && !cfg.useACME then cfg.sslCertificateKey else null;
          forceSSL = cfg.useTLS && cfg.forceTLS;
          addSSL = cfg.useTLS && !cfg.forceTLS;
          locations."/static/" = { alias = "${cfg.staticRoot}/"; };
          locations."/" = {
            extraConfig = ''
              uwsgi_pass unix:/var/lib/security-tracker/uwsgi.sock;
              include ${config.services.nginx.package}/conf/uwsgi_params;
            '';
          };
        };
      };

      # Set up uWSGI
      uwsgi = mkIf (!cfg.devMode) {
        enable = true;
        user = "root"; # For privilege dropping.
        group = "root";
        plugins = [ "python3" ];
        instance = {
          type = "emperor";
          vassals = {
            security_tracker = {
              type = "normal";
              http = ":8000";
              socket = "/var/lib/security-tracker/uwsgi.sock";
              pythonPackages = _: [ cfg.appPackage ];
              env = lib.mapAttrsToList (n: v: "${n}=${v}") trackerEnv;
              module = "wsgi:application";
              chdir = "${srcPath}/mangaki/mangaki";
              pyhome = "${cfg.appPackage}";
              master = true;
              vacuum = true;
              processes = 2;
              harakiri = 20;
              max-requests = 5000;
              chmod-socket = 664; # 664 is already too weak…
              uid = "mangaki";
              gid = "nginx";
            };
          };
        };
      };
    };

    systemd = {
      services = {
        # systemd oneshot for initial migration.
        security-tracker-init-db = {
          after = [ "postgresql.service" ];
          requires = [ "postgresql.service" ];
          before = mkIf (!cfg.devMode) [ "uwsgi.service" ];
          wantedBy = [ "multi-user.target" ];

          description =
            "Initialize Security Tracker database for the first time";
          path = [ cfg.envPackage ];
          environment = trackerEnv;

          inherit serviceConfig;

          script = ''
            # Initialize database
            if [ ! -f .initialized ]; then
              django-admin migrate
              django-admin ingest_bulk_cve

              touch .initialized
            fi
          '';
        };

        security-tracker-migrate-db = {
          after = [ "postgresql.service" "security-tracker-init-db.service" ];
          requires =
            [ "postgresql.service" "security-tracker-init-db.service" ];
          before = mkIf (!cfg.devMode) [ "uwsgi.service" ];
          wantedBy = [ "multi-user.target" ];

          description = "Migrate Security Tracker database (idempotent)";
          path = [ cfg.envPackage ];
          environment = trackerEnv;

          inherit serviceConfig;

          script = ''
            django-admin migrate
          '';
        };

        security-tracker-delta = {
          after = [ "postgresql.service" ];
          requires = [ "postgresql.service" ];
          wantedBy = [ "multi-user.target" ];

          description = "Update CVE database with yesterday's data.";
          path = [ cfg.envPackage ];
          environment = trackerEnv;

          inherit serviceConfig;

          # Let the CVE list be updated
          startAt = "*-*-* 03:00:00 UTC";

          script = ''
            django-admin ingest_delta_cve "$(TZ="UTC" date -d "yesterday" +"%Y-%m-%d")"
          '';
        };
      };

      timers = { };
    };

    users = {
      users.security_tracker = {
        group = "security_tracker";
        description = "Security tracker user";
        isSystemUser = true;
      };

      groups.security_tracker = { };
    };
  };
}
