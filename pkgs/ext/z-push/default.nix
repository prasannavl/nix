{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  version = "2.7.6";
in
  stdenvNoCC.mkDerivation {
    pname = "z-push";
    inherit version;

    src = fetchurl {
      url = "https://github.com/Z-Hub/Z-Push/archive/refs/tags/${version}.tar.gz";
      hash = "sha256-cca6O8HfzzgZ3FdBRU7qWNsTlnzIE0l/YP71QuHYcJE=";
    };

    patches = [
      ./caldav-response-filter.patch
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

    meta = {
      description = "Open source implementation of Microsoft Exchange ActiveSync";
      homepage = "https://z-push.org/";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.all;
    };
  }
