#
# “convenient” entry-point to refer to when needing a Nixpkgs.
#
# This is used both as a way to keep the existing code as-is,
# but also to ensure the trace for using the pinned Nixpkgs is used.
#
# The pinning is now managed using `npins`.
#
let
  inherit (import ./npins)
    nixpkgs
  ;
  # Parse the channel name and identifier out of the pinned Nixpkgs URL.
  # Handles both the legacy releases.nixos.org layout
  #   https://releases.nixos.org/nixos/<channel>/<full>/nixexprs.tar.xz
  # and the newer channels.nixos.org layout
  #   https://channels.nixos.org/<channel>/nixexprs.tar.xz
  segs = builtins.filter
    (x: builtins.isString x && x != "")
    (builtins.split "/" nixpkgs.url);
  isLegacy = builtins.elemAt segs 2 == "nixos";
  channelName = if isLegacy then builtins.elemAt segs 3 else builtins.elemAt segs 2;
  identifier = if isLegacy then builtins.elemAt segs 4 else builtins.elemAt segs 2;
in
builtins.trace "(Using pinned Nixpkgs; ${channelName} @ ${identifier})"
(import nixpkgs)
