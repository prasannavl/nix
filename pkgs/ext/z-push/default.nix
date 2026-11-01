{
  callPackage,
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  source = (import ./sources.nix).z-push;
  version = source.version;

  # AWL is only reachable through z-push's CalDAV include path, so it is built
  # inside this unit and reached as `pkgs.z-push.awl` instead of as its own
  # package or overlay attribute.
  awl = callPackage ./awl.nix {};
in
  stdenvNoCC.mkDerivation {
    pname = "z-push";
    inherit version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/archive/refs/tags/${version}.tar.gz";
      hash = source.hash;
    };

    patches = [
      ./caldav-response-filter.patch
      ./carddav-extensionless-sync-report.patch
      ./caldav-windows-timezone-names.patch
      ./caldav-preserve-fixed-offset-timezone.patch
      ./caldav-organizer-attendee-normalization.patch
      ./imap-meetingresponse-caldav-flag.patch
      ./imap-suppress-calendar-sendmail.patch
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/z-push
      cp -R src/. $out/share/z-push/
      runHook postInstall
    '';

    passthru = {awl = awl;};

    meta = {
      description = "Open source implementation of Microsoft Exchange ActiveSync";
      homepage = "https://z-push.org/";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.all;
    };
  }
