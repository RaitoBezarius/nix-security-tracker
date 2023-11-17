{ pkgs, ... }:

let inherit (pkgs) callPackage stdenvNoCC;

in {
  overlays = [
    (final: _: {
      security-tracker =
        (callPackage ./nix/pkgs/security-tracker { }).overrideAttrs (oldAttrs: {
          passthru = (oldAttrs.passthru or { }) // {
            static = stdenvNoCC.mkDerivation {
              pname = "security-tracker-static";
              inherit (oldAttrs) version;

              phases = [ "installPhase" ];

              nativeBuildInputs = [ final.security-tracker ];

              installPhase = ''
                export DJANGO_SETTINGS_MODULE="tracker.settings"
                mkdir -p $out

                cat <<EOF > settings.ini
                [secrets]
                  SECRET_KEY = dontusethisorgetfired
                  DATABASE_URL = sqlite://
                [deployment]
                  STATIC_ROOT = $out
                EOF

                export NST_SETTINGS_PATH=./settings.ini
                django-admin collectstatic
              '';
            };
          };

        });
    })
  ];

  modulePath = builtins.toString ./nix/modules/security-tracker.nix;
}
