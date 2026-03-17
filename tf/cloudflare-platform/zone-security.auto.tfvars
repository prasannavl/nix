zone_security_settings                   = {}
zone_certificate_packs                   = {}
zone_universal_ssl_settings              = {}
zone_total_tls                           = {}
zone_authenticated_origin_pulls_settings = {}

# Common SSL/HTTPS examples:
#
# zone_security_settings = {
#   "example.com" = {
#     settings = [
#       { setting_id = "ssl", value = "strict" },
#       { setting_id = "always_use_https", value = "on" },
#       { setting_id = "automatic_https_rewrites", value = "on" },
#       { setting_id = "min_tls_version", value = "1.2" }
#     ]
#   }
# }
