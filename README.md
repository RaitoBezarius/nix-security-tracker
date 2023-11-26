This is a testcase for the local nix security scanner tool.

Its purpose is to discover shortcomings in the tool (of which in this early
phase of its development there will be many), and help inform which
improvements would be most helpful.

This testcase describes a minimal NixOS configuration similar to what you'd
get from `nixos-generate-config` with little further customization, against the
revision of nixos-unstable described in the `flake.lock`.

To reproduce the result in `out.txt`:
* use version 99431855fc642116a5f3a9051e13ff8c96e544c3 of the tool
* use version bfd53a882a15136e0feb8f4a561011e16a742fb0 of the CVE db
* `nix build` this configuration
* `sbomnix result/ --type runtime`
* `CVENix /path/to/sbom.cdx.json`
