{...}: {
  config.systemd.tmpfiles.rules = [
    "d /var/lib/pvl/media 0750 pvl pvl -"
    "d /var/lib/pvl/media/audiobooks 0750 pvl pvl -"
    "d /var/lib/pvl/media/books 0750 pvl pvl -"
    "d /var/lib/pvl/media/documents 0750 pvl pvl -"
    "d /var/lib/pvl/media/movies 0750 pvl pvl -"
    "d /var/lib/pvl/media/music 0750 pvl pvl -"
    "d /var/lib/pvl/media/podcasts 0750 pvl pvl -"
    "d /var/lib/pvl/media/shows 0750 pvl pvl -"
    "d /var/lib/pvl/media/videos 0750 pvl pvl -"
  ];
}
