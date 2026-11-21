{lib}: let
  nginxDeclarationPolicy = import ./declaration-policy.nix {inherit lib;};
  rateLimitProfileType = nginxDeclarationPolicy.rateLimitProfileType;
in {
  portOptions = {
    nginxHostNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Optional hostnames to serve through the repo-managed nginx reverse proxy for this port.";
    };

    upstreams = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Optional explicit upstream host:port targets for nginx proxying. When unset, nginx derives a local upstream from the exposed port.";
    };

    rootRedirect = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            description = "Path nginx should redirect exact root requests to.";
          };

          status = lib.mkOption {
            type = lib.types.enum [
              301
              302
              303
              307
              308
            ];
            default = 307;
            description = "HTTP redirect status for exact root requests.";
          };
        };
      });
      default = null;
      description = "Optional redirect nginx should apply to exact root requests before proxying other paths.";
    };

    nginxRoutes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          serverName = lib.mkOption {
            type = lib.types.str;
            description = "Hostname on the shared nginx listener that should mount this route.";
          };

          path = lib.mkOption {
            type = lib.types.str;
            description = "Path prefix on that hostname that should mount this exposed port.";
          };

          stripPath = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether nginx should strip the configured path prefix before proxying.";
          };

          useUpstreamCsp = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "If true, suppress nginx's global Content-Security-Policy for this route so the upstream's CSP (e.g. with per-request nonces) passes through. Other security headers remain applied.";
          };

          useUpstreamReferrer = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "If true, suppress nginx's global Referrer-Policy for this route so the upstream's Referrer-Policy passes through. Other security headers remain applied.";
          };

          useUpstreamPermissionsPolicy = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "If true, suppress nginx's global Permissions-Policy for this route so the upstream's Permissions-Policy passes through. Other security headers remain applied.";
          };

          upstreamProtocol = lib.mkOption {
            type = lib.types.enum [
              "http"
              "https"
            ];
            default = "http";
            description = "Protocol nginx should use when proxying to this route.";
          };

          upstreamHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional origin host for the Host header when nginx proxies to this route.";
          };

          upstreamTlsName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "auto";
            description = "TLS SNI name for HTTPS nginx upstream routes. \"auto\" derives it from upstreamHost when upstreamHost is host-only; null disables SNI.";
          };

          upstreamCaCertificate = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "CA bundle nginx should use to verify this HTTPS upstream route. When null, upstream certificate verification is not enabled by the nginx renderer.";
          };

          location = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional full nginx location match expression, such as '= /api/upload' or '~ ^/api/.*/upload$'. When set, path is still used for route-local rewrite and cookie path defaults.";
          };

          proxyBufferSize = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional nginx proxy_buffer_size override for this route when upstream response headers are larger than nginx's default buffer.";
          };

          proxyBuffering = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Optional nginx proxy_buffering override for streaming upstream responses.";
          };

          proxyReadTimeout = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional nginx proxy_read_timeout override for long-running upstream responses.";
          };

          proxySendTimeout = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional nginx proxy_send_timeout override for long-running upstream requests.";
          };

          proxyRequestBuffering = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Optional nginx proxy_request_buffering override for streaming large request bodies to the upstream.";
          };

          clientMaxBodySize = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional nginx client_max_body_size override for uploads to this route.";
          };

          rateLimit = lib.mkOption {
            type = lib.types.nullOr rateLimitProfileType;
            default = null;
            description = "Optional ingress rate-limit policy override for this route. When unset, the parent exposed port policy is used.";
          };

          proxyCookiePath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional replacement path for nginx proxy_cookie_path. Defaults to the served route prefix.";
          };

          proxyRedirects = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                from = lib.mkOption {
                  type = lib.types.str;
                  description = "Upstream Location value or nginx proxy_redirect pattern to rewrite.";
                };

                to = lib.mkOption {
                  type = lib.types.str;
                  description = "Replacement Location value for nginx proxy_redirect.";
                };
              };
            });
            default = [];
            description = "Additional nginx proxy_redirect rewrites to apply before the default path-preserving redirect rewrite.";
          };
        };
      });
      default = [];
      description = "Optional nginx routes that mount this exposed port under a path on an existing shared hostname.";
    };

    rateLimit = lib.mkOption {
      type = lib.types.nullOr rateLimitProfileType;
      default = null;
      description = "Ingress rate-limit policy for this exposed port. When unset, the shared nginx default rate-limit profile is used.";
    };

    useUpstreamCsp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, suppress nginx's global Content-Security-Policy for the derived root vhost so the upstream's CSP (e.g. with per-request nonces) passes through. Other security headers remain applied.";
    };

    useUpstreamReferrer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, suppress nginx's global Referrer-Policy for the derived root vhost so the upstream's Referrer-Policy passes through. Other security headers remain applied.";
    };

    useUpstreamPermissionsPolicy = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, suppress nginx's global Permissions-Policy for the derived root vhost so the upstream's Permissions-Policy passes through. Other security headers remain applied.";
    };

    proxyBufferSize = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional nginx proxy_buffer_size override for this exposed port when upstream response headers are larger than nginx's default buffer.";
    };

    proxyBuffering = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Optional nginx proxy_buffering override for streaming upstream responses.";
    };

    proxyReadTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional nginx proxy_read_timeout override for long-running upstream responses.";
    };

    proxySendTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional nginx proxy_send_timeout override for long-running upstream requests.";
    };

    proxyConnectTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional nginx stream proxy_connect_timeout override for TCP/UDP exposed ports.";
    };

    proxyTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional nginx stream proxy_timeout override for TCP/UDP exposed ports.";
    };

    upstreamCaCertificate = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "CA bundle nginx should use to verify this HTTPS upstream. When null, upstream certificate verification is not enabled by the nginx renderer.";
    };

    clientMaxBodySize = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional nginx client_max_body_size override for uploads to this exposed port.";
    };

    proxyCookiePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional replacement path for nginx proxy_cookie_path. Defaults to the served route prefix.";
    };

    proxyRedirects = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          from = lib.mkOption {
            type = lib.types.str;
            description = "Upstream Location value or nginx proxy_redirect pattern to rewrite.";
          };

          to = lib.mkOption {
            type = lib.types.str;
            description = "Replacement Location value for nginx proxy_redirect.";
          };
        };
      });
      default = [];
      description = "Additional nginx proxy_redirect rewrites to apply before the default path-preserving redirect rewrite.";
    };
  };

  stackOptions = {
    nginxDefaultHost = lib.mkOption {
      type = lib.types.str;
      default = "host.containers.internal";
      description = "Default upstream host for nginx proxy vhosts derived from this stack's instances.";
    };
  };
}
