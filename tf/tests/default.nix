{pkgs}:
pkgs.runCommand "cloudflare-variable-validation" {
  nativeBuildInputs = [pkgs.python3 pkgs.opentofu];
} ''
  mkdir -p source/tf/{cloudflare-apps,cloudflare-dns,cloudflare-platform,modules/cloudflare,tests}
  cp ${../cloudflare-apps/variables.tf} source/tf/cloudflare-apps/variables.tf
  cp ${../cloudflare-dns/variables.tf} source/tf/cloudflare-dns/variables.tf
  cp ${../cloudflare-platform/variables.tf} source/tf/cloudflare-platform/variables.tf
  cp ${../modules/cloudflare/variables.tf} source/tf/modules/cloudflare/variables.tf
  cp ${./test_variables.py} source/tf/tests/test_variables.py
  python3 -B source/tf/tests/test_variables.py -v
  touch "$out"
''
