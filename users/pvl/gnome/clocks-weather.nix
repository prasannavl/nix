{lib, ...}: let
  g = lib.gvariant;

  cities = rec {
    singapore = {
      city = "Singapore";
      code = "WSAP";
      enabled = true;
      p1 = [0.023852838928353343 1.8136879868485383];
      p2 = [0.022568084612667797 1.8126262332513803];
    };

    newYork = {
      city = "New York";
      code = "KNYC";
      enabled = true;
      p1 = [0.71180344078725644 (-1.2909618758762367)];
      p2 = [0.71059804659265924 (-1.2916478949920254)];
    };

    chennai = {
      city = "Chennai";
      code = "VOMM";
      enabled = true;
      p1 = [0.22689280275926285 1.3994631660730223];
      p2 = [0.22834723798482726 1.4012084953250166];
    };

    utc = {
      city = "Coordinated Universal Time (UTC)";
      code = "@UTC";
      enabled = true;
      p1 = [];
      p2 = [];
    };

    london = {
      city = "London";
      code = "EGWU";
      enabled = true;
      p1 = [0.89971722940307675 (-0.007272211034407213)];
      p2 = [0.89971722940307675 (-0.007272211034407213)];
    };

    sanFrancisco = {
      city = "San Francisco";
      code = "KOAK";
      enabled = true;
      p1 = [0.65832848982162007 (-2.133408063190589)];
      p2 = [0.65832848982162007 (-2.133408063190589)];
    };
  };

  mkAdd = pairs: [(g.mkTuple (map g.mkDouble pairs))];

  loc = {
    city,
    code,
    enabled,
    p1,
    p2,
  }:
    g.mkTuple [
      (g.mkUint32 2)
      (g.mkVariant (g.mkTuple [
        city
        code
        enabled
        (mkAdd p1)
        (mkAdd p2)
      ]))
    ];

  mkLocations = cities: map (city: g.mkVariant (loc city)) cities;
  mkClockEntry = city: [
    (g.mkDictionaryEntry "location" (g.mkVariant (loc city)))
  ];

  worldClockCities = [
    cities.singapore
    cities.newYork
    cities.chennai
    cities.utc
    cities.london
    cities.sanFrancisco
  ];

  weatherCities = [(builtins.head worldClockCities)];
in {
  dconf.settings = {
    "org/gnome/shell/world-clocks" = {
      locations = mkLocations worldClockCities;
    };

    "org/gnome/shell/weather" = {
      automatic-location = true;
      locations = mkLocations weatherCities;
    };

    "org/gnome/clocks" = {
      world-clocks = map mkClockEntry worldClockCities;
    };

    "org/gnome/Weather" = {
      locations = mkLocations weatherCities;
    };
  };
}
