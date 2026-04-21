{outputs}: {
  pvl-a1 = ''
    profile default {
      output "${outputs.a1.name}" enable position 0,0
    }

    profile home-sg-lguw {
      output "${outputs.a1.name}" enable position 0,320
      output "${outputs.lg-uw3840.name}" enable position 2048,0
    }

    # Keep wildcard extras last so they do not outrank precise matches.

    profile default-extra {
      output "${outputs.a1.name}" enable position 0,0
      output "*" enable
    }

    profile home-sg-lguw-extra {
      output "${outputs.a1.name}" enable position 0,320
      output "${outputs.lg-uw3840.name}" enable position 2048,0
      output "*" enable
    }
  '';
}
