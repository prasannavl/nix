{...}: {
  boot.kernel.sysctl = {
    # inotify
    "fs.inotify.max_queued_events" = 16384;
    "fs.inotify.max_user_instances" = 4096;
    "fs.inotify.max_user_watches" = 1048576;
  };
}
