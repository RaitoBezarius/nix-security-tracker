This is a testcase for the local nix security scanner tool.

Its purpose is to discover shortcomings in the tool (of which in this early
phase of its development there will be many), and help inform which
improvements would be most helpful.

This testcase describes a minimal NixOS configuration similar to what you'd
get from `nixos-generate-config` with little further customization, against the
revision of nixos-unstable described in the `flake.lock`.


