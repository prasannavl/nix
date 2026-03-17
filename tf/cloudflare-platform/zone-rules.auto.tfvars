rulesets   = {}
page_rules = {}

# Redirect example:
#
# rulesets = {
#   "example-com-https-redirect" = {
#     zone_name = "example.com"
#     name      = "HTTPS redirect"
#     kind      = "zone"
#     phase     = "http_request_dynamic_redirect"
#     rules = [
#       {
#         ref         = "redirect-http-to-https"
#         description = "Redirect plain HTTP to HTTPS"
#         expression  = "http.request.scheme eq \"http\""
#         enabled     = true
#         action      = "redirect"
#         action_parameters = {
#           from_value = {
#             status_code = 301
#             target_url = {
#               expression = "concat(\"https://\", http.host, http.request.uri.path)"
#             }
#             preserve_query_string = true
#           }
#         }
#       }
#     ]
#   }
# }
