/*
The Pvl repository identity check for the shared PostgreSQL extension-policy
helper. It uses Pvl's current image tag and synthetic extension targets to
exercise policy rendering; it neither registers a host consumer nor asserts
the live database catalogs.
*/
{pkgs}: let
  postgresExtensions = import ../../../services/postgres/extensions.nix {inherit pkgs;};
  policy = postgresExtensions.mkTimescalePolicy {
    imageTag = "pg18.6-ts2.30.1";
    extensions = {
      vector = "0.8.6";
      postgis = {
        target = "3.6.5";
        upgradeFrom = ["3.6.3" "3.6.4"];
      };
    };
  };
  invalidUpgradeFrom = builtins.tryEval (builtins.deepSeq (postgresExtensions.mkTimescalePolicy {
      imageTag = "pg18.6-ts2.30.1";
      extensions.postgis = {
        target = "3.6.5";
        upgradeFrom = ["3.6.5"];
      };
    })
    true);
  duplicateTarget = builtins.tryEval (builtins.deepSeq (postgresExtensions.mkTimescalePolicy {
      imageTag = "pg18.6-ts2.30.1";
      extensions.timescaledb = {
        target = "2.30.1";
      };
    })
    true);
  unknownField = builtins.tryEval (builtins.deepSeq (postgresExtensions.mkTimescalePolicy {
      imageTag = "pg18.6-ts2.30.1";
      extensions.vector = {
        target = "0.8.6";
        upgrade_from = ["0.8.2"];
      };
    })
    true);
  runner = postgresExtensions.mkRunner {
    name = "pvl-postgres-extensions-policy-fixture";
    container = "postgres_postgres_1";
    inherit policy;
  };
in {
  pvl-postgres-extensions-policy = assert policy.image == "docker.io/timescale/timescaledb-ha:pg18.6-ts2.30.1";
  assert policy.postgresMajor == 18;
  assert policy.extensions.timescaledb.target == "2.30.1";
  assert !(policy.extensions.timescaledb ? upgradeFrom);
  assert policy.extensions.vector.target == "0.8.6";
  assert !(policy.extensions.vector ? upgradeFrom);
  assert policy.extensions.postgis.target == "3.6.5";
  assert policy.extensions.postgis.upgradeFrom == ["3.6.3" "3.6.4"];
  assert !invalidUpgradeFrom.success;
  assert !duplicateTarget.success;
  assert !unknownField.success;
    pkgs.runCommand "pvl-postgres-extensions-policy-test" {} ''
      test -x ${runner}/bin/pvl-postgres-extensions-policy-fixture
      touch "$out"
    '';
}
